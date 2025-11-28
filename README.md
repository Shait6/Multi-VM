
## Multi-Region Azure VM Backup Automation

### 1. Overview
This repository implements a policy-driven, multi-region Azure Backup platform that enables and remediates protection for tagged Virtual Machines. The solution is designed for operational predictability, auditability and minimal identity sprawl. Key implementation choices include:

- A single shared User Assigned Managed Identity (UAI) created deterministically in the first selected region; this identity is used to perform remediation across all targeted regions.
- Subscription-scoped Bicep orchestration (`main.bicep`) built from modular components for vaults, backup policies and role assignments.
- Idempotent PowerShell helpers for infrastructure deployment and policy remediation suitable for CI or ad-hoc execution.

The README preserves an operator-friendly, stepwise layout while documenting the current deterministic behavior and operational prerequisites.

---

## Table of contents

1. Quick snapshot
2. Why this design (architecture rationale)
3. Architecture (logical view)
4. Repository layout (concise)
5. Quick start — local and CI
6. Parameters and pipeline notes
7. Troubleshooting & validation
8. Recommended hardening
9. Summary

---

## 1 — Quick snapshot

- Target: programmatic enablement of Azure Backup for Virtual Machines that match a configurable tag name/value, across one or more regions.
- Deployment: `main.bicep` (subscription scope) creates the regional Recovery Services Vaults (RSVs), backup policies and a single shared UAI used for remediation.
- Remediation: a custom `DeployIfNotExists` policy (`Custom-CentralVmBackup-AnyOS`) is assigned and remediation jobs are orchestrated by `Start-BackupRemediation.ps1`.

This approach provides centralized control, consistent vault and policy configuration per region, and auditable remediation operations.

---

## 2 — Why this design (architecture rationale)

- Regional RSVs: keep backup data co-located with VMs to meet recovery and compliance requirements.
- Policy-driven remediation: use Azure Policy `DeployIfNotExists` for declarative, auditable and repeatable remediation runs.
- Single shared UAI: minimizes managed identity proliferation and reduces RBAC management surface while preserving an auditable principal for remediation actions.
- Modular Bicep + deterministic scripts: enables reproducible deployments in CI and simpler operational troubleshooting.

---

## 3 — Architecture (logical view)

```
                      +-------------------------+
                      |   CI (GitHub / ADO)    |
                      +-----------+-------------+
                                  |
                                  v
                    +-------------------------------+
                    | Subscription / main.bicep     |
                    | - ensure rsv-rg-<region> Rgs  |
                    | - create rsv-<region> vaults  |
                    | - create policies & outputs   |
                    +-------------------------------+
                                  |
      +---------------------------+---------------------------+
      |                                                       |
      v                                                       v
  Recovery Services Vault (rsv-<region>)                 Azure Policy
  - backup policies (daily/weekly)                       - Custom DeployIfNotExists
  - protectedItems                                       - Assignment (uses single shared UAI)
```

---

## 4 — Repository layout (concise)

- `main.bicep` — subscription-scoped orchestration and outputs (vault IDs, policy IDs, UAI resource id/principal id).
- `modules/` — Bicep modules: `recoveryVault`, `backupPolicy`, `userAssignedIdentity`, `roleAssignment`, `assignCustomCentralBackupPolicy`, `backupAuditPolicy`.
- `policy-definitions/` — `customCentralVmBackup.rules.json` and `customCentralVmBackup.full.json` (policy artifacts).
- `scripts/` — PowerShell helpers:
  - `Deploy-BackupInfra.ps1` — builds/deploys `main.bicep`. The script pre-creates `rsv-rg-<region>` resource groups (to avoid nested deployment failures), supports a `-NoArtifacts` switch and central parameters file usage.
  - `Start-BackupRemediation.ps1` — creates/ensures the shared UAI (in the first region), attempts subscription-level role assignment (if caller has permission), assigns the custom policy and triggers remediations. The script supports `-NoArtifacts` and deterministic fallback resolution for the UAI.
- `parameters/` — centralized parameter file(s) such as `parameters/main.parameters.json` used by CI pipelines.
- `Pipeline/` and `.github/workflows/` — CI definitions for GitHub Actions and Azure DevOps.

Notes:
- The repository intentionally deploys a single shared UAI rather than multiple per-region UAIs to simplify RBAC and auditing.
- Avoid using stale compiled artifacts from `bicep-build/` in CI; the infra scripts can build Bicep on demand. If you keep `bicep-build/main.json`, ensure it is rebuilt after changes to `main.bicep`.

---

## 5 — Quick start

Prerequisites:
- Azure CLI with Bicep support (`az bicep install` if needed).
- An Azure principal with sufficient permissions to create resource groups, user assigned identities and (optionally) subscription role assignments. For initial provisioning, Owner or equivalent is recommended; for production, follow least-privilege guidance.

1) Authenticate and set subscription (local):

```powershell
az login
az account set --subscription <SUB_ID>
```

2) Build & deploy infrastructure (subscription scope):

```powershell
# Build (optional — the scripts will build if required)
az bicep build --file main.bicep --outfile bicep-build\main.json

# Deploy: the script pre-creates rsv resource groups and runs a subscription deployment
.\scripts\Deploy-BackupInfra.ps1 -SubscriptionId <SUB_ID> -DeploymentLocation westeurope -Regions "westeurope,northeurope" -RetentionProfile "14|30|0|backup|true" -BackupTime "01:00"
```

Notes: the `-NoArtifacts` switch prevents temporary artifacts from being written to disk when running in CI or when you want a cleaner run.

3) Trigger remediation (policy assignment + remediation runs):

```powershell
.\scripts\Start-BackupRemediation.ps1 -SubscriptionId <SUB_ID> -Regions "westeurope,northeurope" -DeploymentLocation westeurope -BackupFrequency Daily -TagName backup -TagValue true -Verbose
```

Operational guidance:
- Run `Deploy-BackupInfra.ps1` first to ensure RSVs and outputs exist; `Start-BackupRemediation.ps1` will attempt to create the shared UAI if it cannot be resolved, but role assignment creation requires permission.
- For CI, pass `Regions` and the `parameters/main.parameters.json` or explicit pipeline variables; the CI jobs in `Pipeline/` and `.github/workflows/` demonstrate patterns used by this project.

---

## 6 — Parameters and pipeline notes

Composite retention profile (convenience):

```
DailyDays|WeeklyWeeks|YearlyYears|TagName|TagValue
Example: 14|5|0|backup|true
```

Pipeline variables (high level):

| Parameter | Meaning |
|---|---|
| `Regions` | Comma-separated list of target regions (e.g., `westeurope,northeurope`) |
| `deploymentLocation` | Location for subscription deployment metadata (e.g., `westeurope`) |
| `backupFrequency` | `Daily` / `Weekly` / `Both` |
| `retentionProfile` | Composite retention + tag value (see above) |
| `enableAutoRemediation` | `true` to assign and trigger policy remediation |

CI integration:
- GitHub Actions and Azure DevOps pipelines included in this repo illustrate building, deploying and optionally running remediation. Use the centralized parameter file for predictable runs and to avoid embedding secrets in pipeline YAML.

---

## 7 — Troubleshooting & validation

- Resource group missing: if a deployment fails with `ResourceGroupNotFound`, confirm the `Regions` parameter and re-run `Deploy-BackupInfra.ps1`. The script pre-creates `rsv-rg-<region>` resource groups to reduce nested-deployment failures.
- Identity failures: `FailedIdentityOperation` typically indicates the caller lacks permission to create or use the UAI, or the identity was removed. `Start-BackupRemediation.ps1` contains deterministic fallback logic that will attempt to create the shared UAI and to create a subscription role assignment if the caller has the required permissions.
- Stale compiled artifacts: do not rely on an old `bicep-build/main.json` produced before recent edits to `main.bicep`. Rebuild the artifact after code changes or allow the deployment script to build from source.

Useful commands:

- Inspect subscription deployment outputs (deployment name used by `Deploy-BackupInfra.ps1`):
  `az deployment sub show --name <deployName> --query properties.outputs -o json`
- List RSV groups created by the solution:
  `az group list --query "[?starts_with(name,'rsv-')].name" -o tsv`
- Check User Assigned Identity:
  `az identity show -g rsv-rg-westeurope -n uai-westeurope -o json`
- Confirm policy assignment:
  `az policy assignment show -n enable-vm-backup-anyos-westeurope -o json`

---

## 8 — Recommended hardening

- Enforce least privilege: prefer a deployment principal scoped to the minimal operations required. For subscription-level role assignments you may use a privileged onboarding step handled by an operator or a separate security pipeline.
- Protect vault access: apply private endpoints, firewall rules, and network rules according to your security posture; the `recoveryVault` module supports configurable networking patterns.
- Audit and monitor remediation: use Azure Policy Insights and Activity Logs to track remediation operations performed by the shared UAI.

---

## 9 — Summary

This repository provides a pragmatic, auditable and repeatable pattern to ensure tagged VMs are protected by Azure Backup across regions. The primary operational choices are:

- A single shared UAI (created in the first selected region) to execute remediation in a controlled and auditable manner.
- Subscription-scoped Bicep orchestration for consistent RSV and policy provisioning.
- Deterministic PowerShell scripts with `-NoArtifacts` options suitable for CI runs and local execution.

If you would like, I can:

- add a short CI examples section showing the minimal pipeline variables required, or
- run a quick validation on the repository to detect any references to deprecated artifacts (e.g., stale compiled JSON in `bicep-build/`).


