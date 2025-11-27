
## Multi-Region Azure VM Backup Automation

### 1. Overview
This repository provides a policy-driven, multi-region Azure Backup automation that centrally enables backups for tagged VMs. The current implementation uses a single shared User Assigned Identity (UAI) — created deterministically in the first selected region — to run remediation across all targeted regions. The orchestration uses subscription-scoped Bicep with reusable modules and simple PowerShell scripts for deployment and remediation.

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

- Target: Automatically enable Azure Backup for VMs tagged with a configurable tag name/value across multiple regions.
- Deployment: `main.bicep` (subscription scope) creates regional Recovery Services Vaults, backup policies and a single shared UAI used for remediation.
- Remediation: A custom DeployIfNotExists policy (`Custom-CentralVmBackup-AnyOS`) is assigned and remediation jobs are triggered via `Start-BackupRemediation.ps1`.

Use case: central, auditable backup enablement without manual per-VM operations.

---

## 2 — Why this design (architecture rationale)

- Regional vaults for data locality and predictable recovery behavior.
- Policy-driven remediation (DeployIfNotExists) for declarative, auditable, idempotent remediation runs.
- Single shared UAI for remediation: reduces identity sprawl and simplifies RBAC management while preserving auditability.
- Reusable Bicep modules and small, deterministic scripts for CI and local usage.

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
                    | - create policies              |
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

- `main.bicep` — subscription-scoped orchestration
- `modules/` — Bicep modules: `recoveryVault`, `backupPolicy`, `userAssignedIdentity`, `roleAssignment`, `assignCustomCentralBackupPolicy`, `backupAuditPolicy`
- `policy-definitions/` — `customCentralVmBackup.rules.json` and `customCentralVmBackup.full.json`
- `scripts/` — PowerShell helpers:
  - `Deploy-BackupInfra.ps1` — builds and deploys `main.bicep`; it pre-creates regional resource groups (`rsv-rg-<region>`) to avoid nested deployment failures.
  - `Start-BackupRemediation.ps1` — deterministic remediation: ensures a single UAI exists (creates it in the first selected region if missing), ensures necessary RBAC, assigns the custom policy and triggers remediations across regions.
- `Pipeline/` and `.github/workflows/` — CI definitions for GitHub Actions and Azure DevOps

Notes:
- The repository no longer creates multiple per-region UAIs; the single shared UAI pattern is used to simplify role management and auditing.
- Compiled artifacts are ignored and the scripts are designed to be deterministic and idempotent.

---

## 5 — Quick start

Prereqs: `az cli` (with Bicep support), an Azure principal with rights to create resource groups, identities and role assignments (or an Owner-level principal for initial runs).

1) Authenticate and set subscription (local):

```powershell
az login
az account set --subscription <SUB_ID>
```

2) Build & deploy infra (subscription scope):

```powershell
# optional: build arm artifact
az bicep build --file main.bicep --outfile bicep-build\main.json

# create RGs and deploy subscription deployment (pass regions if you want multiple regions)
.\scripts\Deploy-BackupInfra.ps1 -SubscriptionId <SUB_ID> -DeploymentLocation westeurope -Regions "westeurope,northeurope" -RetentionProfile "14|30|0|backup|true" -BackupTime "01:00"
```

3) Trigger remediation (uses the single shared UAI):

```powershell
.\scripts\Start-BackupRemediation.ps1 -SubscriptionId <SUB_ID> -Regions "westeurope,northeurope" -DeploymentLocation westeurope -BackupFrequency Daily -TagName backup -TagValue true -Verbose
```

Notes:
- `Deploy-BackupInfra.ps1` will pre-create `rsv-rg-<region>` resource groups and then run the subscription deployment; this reduces nested deployment failures.
- `Start-BackupRemediation.ps1` will ensure a single UAI exists in the first region you pass and will create it (and attempt to create the subscription-level role assignment) if missing. If you prefer explicit infra-only flows, run `Deploy-BackupInfra.ps1` first and then remediation.

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
- GitHub Actions and Azure DevOps pipelines orchestrate the same steps; pass `Regions` and `retentionProfile` through pipeline variables.

---

## 7 — Troubleshooting & validation

- If a deployment shows `ResourceGroupNotFound`, re-run `Deploy-BackupInfra.ps1` with the correct `-Regions` parameter; the script now pre-creates `rsv-rg-<region>` groups.
- If remediation fails with `FailedIdentityOperation`, ensure the shared UAI exists and has the required role at subscription scope. `Start-BackupRemediation.ps1` will attempt to create the UAI and a subscription role assignment if permitted by the caller.
- Use `az deployment sub show --name <deployName> --query properties.outputs -o json` to inspect deployment outputs (the subscription deployment emits `userAssignedIdentityIds` and other outputs).

Validation tips:
- Confirm resource groups: `az group list --query "[?starts_with(name,'rsv-')].name" -o tsv`
- Confirm identity exists: `az identity show -g rsv-rg-westeurope -n uai-westeurope -o json`
- Confirm policy assignment: `az policy assignment show -n enable-vm-backup-anyos-westeurope -o json`

---

## 8 — Recommended hardening

- Use least-privilege principals in CI; allow the deployment principal permission to create the UAI and to create a role assignment, or have a separate security process to create the subscription role assignment for the UAI.
- Lock down vault networking (private endpoints / firewall rules) according to your security posture; Bicep module supports public network settings.

---

## 9 — Summary

This repository delivers a compact, policy-driven automation to ensure tagged VMs are protected with Azure Backup across regions. The key operational decisions in the current implementation are:

- Single shared UAI (created in the first selected region) used to run remediation across all regions.
- Subscription-scoped Bicep orchestration that creates/vets regional resource groups and vaults.
- Deterministic, idempotent PowerShell scripts for infra deployment and remediation.

If you want me to add a short `README` section with examples for CI (GitHub Actions / Azure DevOps) showing the minimum variables to pass, I can append that quickly.


