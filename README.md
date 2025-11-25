
````markdown

## Multi-Region Azure VM Backup Automation (AVM-based)

### 1. Overview
This repository automates enabling Azure Backup for Virtual Machines across multiple regions using Bicep and Azure Verified Modules (AVM). The solution creates per-region Recovery Services Vaults (RSVs), backup policies, a single User Assigned Identity (UAI) used for remediation, and a custom DeployIfNotExists policy that is assigned per-region to remediate tagged VMs.

Key changes in this branch:
- Core infra (vaults, UAIs, role assignments, resource-groups) now use Azure Verified Modules (AVM) instead of local module implementations. That reduces maintenance and aligns with community-approved patterns.
- Parameter defaults are centralized in `parameters/main.parameters.json`. CI and deployment scripts merge runtime overrides with these defaults.
- The custom policy and its per-region assignment remain local (`modules/assignCustomCentralBackupPolicy.bicep`) because the remediation contains environment-specific nested templates.

---

## Table of contents

1. Quick snapshot
2. Architecture (logical view)
3. Repository layout
4. How this works now (AVM + parameters)
5. Quick start — local and CI
6. Parameters and pipeline notes
7. Troubleshooting & AVM restore guidance
8. Recommended hardening
9. Contributing & support

---

## 1 — Quick snapshot

- Target: Automatically enable Azure Backup for VMs tagged with a configurable tag name/value, across multiple regions.
- Deployment: `main.bicep` (subscription scope) orchestrates AVM registry modules to create vaults, policies, a single UAI and RBAC.
- Remediation: `Custom-CentralVmBackup-AnyOS` (custom policy) is created and assigned per-region. `DeployIfNotExists` remediation uses the UAI.

This branch focuses on making the template deterministic, centralizing defaults, and using AVM modules for core resources.

---

## 2 — Architecture (logical view)

```
                      +-------------------------+
                      |   CI (GitHub / ADO)    |
                      +-----------+-------------+
                                  |
                                  v
                    +-------------------------------+
                    | Subscription / main.bicep     |
                    | - calls AVM modules           |
                    | - parameters supplied from    |
                    |   parameters/main.parameters.json
                    +-------------------------------+
                                  |
      +---------------------------+---------------------------+
      |                                                       |
      v                                                       v
  Recovery Services Vault (rsv-<region>)                 Azure Policy
  - backup policies (daily/weekly)                       - Custom DeployIfNotExists
  - protectedItems                                       - Assignment per region
                                                        (uses UAI as identity)
```

High-level differences vs. the previous approach:
- AVM registry modules are used for resource-groups, vaults, managed identities and role assignments.
- Parameter defaults live in `parameters/main.parameters.json` and are merged by `scripts/Deploy-BackupInfra.ps1` with any runtime overrides from CI.

---

## 3 — Repository layout

- `main.bicep` — subscription-scoped orchestrator that declares parameters and invokes AVM modules.
- `parameters/main.parameters.json` — centralized defaults used by CI and the deploy script.
- `modules/assignCustomCentralBackupPolicy.bicep` — subscription-scoped policy assignment for the custom DeployIfNotExists policy (kept local).
- `modules/backupAuditPolicy.bicep` — audit-only policy module (local).
- `policy-definitions/` — `customCentralVmBackup.rules.json` (rules-only, preferred) and `customCentralVmBackup.full.json` (full definition for az rest PUT when preserving expressions).
- `scripts/Deploy-BackupInfra.ps1` — builds Bicep (CI does this) and deploys; it now merges repo parameter defaults with runtime overrides and prefers the compiled `bicep-build/main.json` when present.
- `scripts/Start-BackupRemediation.ps1` — assigns the policy per-region and triggers remediations; it uses the local assignment module and UAI.
- `Pipeline/azure-pipelines.yml` & `.github/workflows/github-action.yml` — CI definitions that run build and deploy stages.

---

## 4 — How this works now (AVM + centralized params)

1. CI or local developer runs `az bicep build --file main.bicep --outdir bicep-build`.
   - This step attempts to restore AVM artifacts from the public registry (`br:mcr.microsoft.com/bicep/avm/...`) and will surface restore errors (BCP192) early.

2. The deployment step runs `scripts/Deploy-BackupInfra.ps1` which:
   - Loads defaults from `parameters/main.parameters.json` (if present).
   - Overlays runtime-provided values (CI inputs or env vars) onto those defaults.
   - Writes a merged `main-params.json` and then deploys using `bicep-build/main.json` when available (CI path) or `main.bicep` as fallback.

3. `main.bicep` invokes AVM modules for resource-groups, Recovery Services Vaults and their `backupPolicies` parameter, the User Assigned Identity, and subscription-scope role assignment.

4. After infra is created, the CI job (or `Start-BackupRemediation.ps1`) creates the `Custom-CentralVmBackup-AnyOS` policy definition (from the rules JSON) and then assigns it per-region using `modules/assignCustomCentralBackupPolicy.bicep` (local module). The assignment uses the resolved `backupPolicyId` to target the correct vault policy.

Notes about parameters vs. declarations:
- `main.bicep` declares the parameters (types and descriptions) but defaults are intentionally removed for centralized control. The values live in `parameters/main.parameters.json` so CI and pipelines can be the single source of truth.

---

## 5 — Quick start — local and CI

Prerequisites
- `az cli` and login (local); CI runners already provide Azure CLI.
- Azure subscription with sufficient permissions for deployments, RBAC and policy operations.
- Ensure `parameters/main.parameters.json` contains the values you want for default behavior in non-interactive runs.

Local quick run (recommended to test compilation and parameter merge):

```powershell
# Build and generate merged params via the script
pwsh .\scripts\Deploy-BackupInfra.ps1 -SubscriptionId <SUB_ID> -DeploymentLocation westeurope -BackupFrequency Weekly

# Inspect merged parameters
Get-Content -Raw .\main-params.json | ConvertFrom-Json | ConvertTo-Json -Depth 5

# Optionally run a subscription-scope what-if or create command (use caution)
az deployment sub what-if --name demo --location westeurope --template-file bicep-build\main.json --parameters @main-params.json
```

CI (GitHub Actions or Azure DevOps)
- Both pipelines run `az bicep build --file main.bicep --outdir bicep-build` as a syntax/restore step and then run the deploy script which merges params and deploys the compiled template.
- GitHub Actions workflow note: confirm the secret used by `azure/login@v2` exists (`AZURE_CREDENTIALS` or your chosen secret). The workflow currently references a secret named `serivcon` — verify that name or replace it with your secret name.

Runtime overrides from CI
- Use workflow/pipeline inputs for values you want to change at dispatch-time (e.g., `deploymentLocation`, `backupFrequency`, `retentionProfile`). The deploy script overlays these over `parameters/main.parameters.json`.

---

## 6 — Parameters and pipeline notes

Centralized defaults: `parameters/main.parameters.json` — edit this file to change the repo-wide default behavior (schedules, retention, soft-delete, tags, SKU, etc.).

Dispatch-level overrides:
- Pass the small number of values that vary per-run via pipeline inputs (examples in `.github/workflows/github-action.yml` and `Pipeline/azure-pipelines.yml`). The deploy script will merge them into `main-params.json` before deployment.

Recommended parameter split:
- Keep in `parameters/main.parameters.json`: retention policy details, schedule times, softDeleteSettings, vault SKUs, tags, remediation role definition id.
- Keep as CI inputs (dispatch): `subscriptionId`, `deploymentLocation`, `backupFrequency`, `remediationRegions`, `enableAutoRemediation`.

Using the compiled artifact
- CI will produce `bicep-build/main.json`. `Deploy-BackupInfra.ps1` prefers that compiled file so the deploy step is deterministic and avoids double compilation.

---

## 7 — Troubleshooting & AVM restore guidance

Common blocker: AVM artifact restore failures during `az bicep build` (error BCP192). This indicates the requested AVM artifact tag is not present in the public registry or registry access is blocked.

Steps to diagnose and fix AVM restore problems:
1. Run a focused build locally to reproduce restore errors and see the HTTP details:

```powershell
az bicep build --file main.bicep --outdir bicep-build --no-progress
```

2. Inspect the failure line for the `br:mcr.microsoft.com/bicep/avm/...:tag` reference. Try a few actions:
- Verify the tag referenced in `main.bicep` matches the published tag in the AVM GitHub repo for that module (sometimes `version.json` in the repo differs from the published registry tag which may include patch versions).
- Try a patch variant of the tag (e.g., `0.11.1` vs `0.11`).
- If your environment uses a proxy or has restricted egress, allowlist MCR (`mcr.microsoft.com`) or ensure the CI runner can reach the registry.

3. If you determine a stable published tag, pin that exact tag in `main.bicep` for the module reference.

4. If you prefer to temporarily bypass AVM while debugging, restore the archived local module implementation and point `main.bicep` back to it until AVM tags are pinned.

Policy & nested template notes
- The custom policy contains a nested deployment template that relies on `field()` expressions. We keep the `customCentralVmBackup.full.json` file and the `Start-BackupRemediation.ps1` script uses `az rest` PUT when needed to preserve the exact JSON (avoids expression mangling).

---

## 8 — Recommended hardening

- Use GitHub secret `AZURE_CREDENTIALS` or a properly named secret for `azure/login@v2`. Confirm the action references your secret name.
- Use a service principal with scoped permissions for CI; avoid using full owner where not necessary.
- Consider a release gating process that pins AVM versions once validated in a test subscription and then promotes the pinned tags to main production runs.

---

## 9 — Contributing & support

- To propose AVM version updates, create a branch that updates the module tag(s) in `main.bicep`, push and run the CI (the `az bicep build` step will validate restore). If the build succeeds, run deploy in a test subscription.
- To change default behavior, update `parameters/main.parameters.json` and open a PR describing the change.
- For troubleshooting help, include the `az bicep build` output and the exact `br:` references that failed to restore.

````
- Least-privilege path: remediation runs through UAIs, enabling stronger access controls over time.



Prerequisites
