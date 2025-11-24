
## Multi-Region Azure VM Backup Automation

### 1. Overview
This solution deploys and manages a standardized multi‑region Azure VM backup platform. It creates per‑region Recovery Services Vaults (RSVs), daily/weekly backup policies (optionally both for future use), user‑assigned identities (UAIs), and role assignments. A DeployIfNotExists policy will automatically enable backup for tagged virtual machines, with remediation executed on demand.

# Multi-Region Azure VM Backup

High-quality, policy-driven automation to centrally enable Azure Backup for Virtual Machines across multiple regions. This repository contains Bicep modules, policy definitions and automation scripts to:

- Deploy per-region Recovery Services Vaults (RSVs) and backup policies
- Create User Assigned Identities (UAIs) and RBAC assignments for remediation
- Register a custom DeployIfNotExists policy to enable backup for tagged VMs
- Trigger idempotent remediation runs from CI (GitHub Actions or Azure DevOps)

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
9. Contributing & support

---

## 1 — Quick snapshot

- Target: Automatically enable Azure Backup for VMs tagged with a configurable tag name/value, across multiple regions.
- Deployment: Bicep (`main.bicep`) at subscription scope creates vaults, backup policies, UAIs and RBAC.
- Remediation: A custom policy `Custom-CentralVmBackup-AnyOS` is assigned per-region; `DeployIfNotExists` creates protected items in the vault.

Use case: central, auditable backup enablement without hand‑operating backups for each VM.

---

## 2 — Why this design (architecture rationale)

- Per-region Recovery Services Vaults
  - Data locality and latency — backups are stored in a vault within the same region as the VMs.
  - Vault-scoped backup policies make policy selection and policy id resolution deterministic.

- Policy-driven remediation (DeployIfNotExists)
  - Declarative and auditable: Azure Policy identifies non-compliant VMs and runs remediation jobs that create protected items.
  - Idempotent: repeatable remediation avoids duplicate resources.

- Custom any‑OS policy
  - Avoids being blocked by image allow-lists (important for new distro versions). Ensures broader coverage of VMs.

- User Assigned Identity for remediation
  - Runs remediation under an identity you control and can audit via Azure AD and role assignments.

- Bicep modules and scripts
  - Reusable building blocks and simple CI integration (GitHub Actions / Azure DevOps).

---

## 3 — Architecture (logical view)

ASCII diagram (high level):

```
                      +-------------------------+
                      |   CI (GitHub / ADO)    |
                      +-----------+-------------+
                                  |
                                  v
                    +-------------------------------+
                    | Subscription / main.bicep     |
                    | - create rsv-rg-<region> Rgs  |
                    | - create rsv-<region> vaults  |
                    | - create policies & UAIs      |
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

---

## 4 — Repository layout (concise)

- `main.bicep` — subscription-scoped orchestration
- `modules/` — Bicep modules (vault, backupPolicy, userAssignedIdentity, roleAssignment, assignCustomCentralBackupPolicy, backupAuditPolicy)
- `policy-definitions/` — `customCentralVmBackup.rules.json` (rules) and `customCentralVmBackup.full.json` (full definition)
- `scripts/` — PowerShell helpers:
  - `Deploy-BackupInfra.ps1` — builds and deploys `main.bicep`
  - `Start-BackupRemediation.ps1` — assigns policy and triggers remediation (includes wait/check logic)
- `Pipeline/` and `.github/workflows/` — Azure DevOps & GitHub Actions CI definitions

---

## 5 — Quick start

Prereq: `az cli`, logged-in, and subscription context set. CI runners provide these.

1) Authenticate and set subscription (local):

```powershell
az login
az account set --subscription <SUB_ID>
```

2) Build & deploy infra (subscription scope):

```powershell
az bicep build --file main.bicep
az deployment sub create --name multi-region-backup --location westeurope --template-file main.bicep --parameters \
  backupFrequency=Weekly backupScheduleRunTimes='["23:00"]' backupTimeZone=UTC
```

3) Create policy definition (optional; pipeline can create it):

```powershell
az policy definition create --name Custom-CentralVmBackup-AnyOS --display-name "Central VM Backup (Any OS)" \
  --rules policy-definitions/customCentralVmBackup.rules.json --mode Indexed
```

4) Trigger remediation (after infra completes):

```powershell
./scripts/Start-BackupRemediation.ps1 -SubscriptionId <SUB_ID> -Regions 'westeurope' -TagName 'backup' -TagValue 'true'
```

Notes:
- The pipeline files (`.github/workflows/github-action.yml` and `Pipeline/azure-pipelines.yml`) orchestrate the same steps and will create the policy definition and trigger remediation when `enableAutoRemediation` is set to `true`.

---

## 6 — Parameters and pipeline notes

Composite retention profile (convenience):

```
DailyDays|WeeklyWeeks|YearlyYears|TagName|TagValue
Example: 14|5|0|backup|true
```

Main pipeline variables (high level):

| Parameter | Meaning |
|---|---|
| `deploymentLocation` | Metadata location for subscription-scoped deployment (e.g., `westeurope`) |
| `backupFrequency` | `Daily` / `Weekly` / `Both` |
| `retentionProfile` | Composite retention + tag value (see above) |
| `backupScheduleTimeString` | Daily/weekly run time (HH:mm) |
| `enableAutoRemediation` | `true` to assign and trigger policy remediation |

CI integration:
- GitHub Actions: `.github/workflows/github-action.yml` — accepts the composite `retentionProfile` and other inputs.
- Azure DevOps: `Pipeline/azure-pipelines.yml` — same stages, pipeline variables.

Important: the `Start-BackupRemediation.ps1` script now waits for the vault resource group and policy to exist before attempting assignment.

---

## 9 — Summary

**Repository layout**
- `main.bicep` — Orchestrates subscription-scoped deployment: creates per-region resource groups (`rsv-rg-<region>`), Recovery Services Vaults (`rsv-<region>`), backup policy modules, UAIs, and RBAC.
- `modules/recoveryVault.bicep` — Creates a Recovery Services Vault with chosen SKU and network settings.
- `modules/backupPolicy.bicep` — Builds daily/weekly (or both) backup policies and outputs policy IDs and names.
- `modules/userAssignedIdentity.bicep` — Creates per-region UAIs and exposes principal IDs.
- `modules/roleAssignmentSubscription.bicep` — Assign Contributor (or configured role) to the UAI at subscription scope.
- `modules/assignCustomCentralBackupPolicy.bicep` — Creates a subscription-scoped policy assignment of the custom DeployIfNotExists policy and passes the vault/policy ID into the policy parameters.
- `modules/backupAuditPolicy.bicep` — Creates an audit-only policy to report unprotected VMs (non-enforcing).
- `policy-definitions/customCentralVmBackup.rules.json` — Policy rules (preferred for `az policy definition create` to preserve expressions).
- `policy-definitions/customCentralVmBackup.full.json` — Full policy definition JSON (useful for `az rest` PUT when exact JSON must be preserved).
- `scripts/Deploy-BackupInfra.ps1` — Wrapper script that builds Bicep and deploys `main.bicep` with parsed parameters.
- `scripts/Start-BackupRemediation.ps1` — Creates per-region policy assignment and triggers remediation run(s). Includes waiting logic to ensure vaults/policies exist before assigning.
- `Pipeline/azure-pipelines.yml` & `.github/workflows/github-action.yml` — CI definitions. Both support deploying infra, creating the policy definition, and optionally triggering remediation.

**What the solution provides**
- Automatic enforcement: VMs tagged with the configured name/value are detected and remediated automatically.
- Multi-region parity: consistent vault and policy configuration across regions.
- Auditability: Azure Policy assignments and remediation jobs are visible in the Portal and logs.
- Reusability: Bicep modules and scripts can be adapted for other policy-based remediation scenarios.
- Least-privilege path: remediation runs through UAIs, enabling stronger access controls over time.

Prerequisites
- Azure subscription and a principal with Owner or equivalent rights to create RBAC and policy assignments.
- Registered providers: `Microsoft.RecoveryServices`, `Microsoft.ManagedIdentity`, `Microsoft.Authorization`, `Microsoft.PolicyInsights`.
- Azure CLI installed where you run scripts (CI runners include this). Bicep support is required (`az bicep install` will be used by the scripts if missing).
- For GitHub Actions: an Azure credential secret that `azure/login@v2` can use (e.g., `AZURE_CREDENTIALS`).
- For Azure DevOps: a service connection with subscription scope allowing deployments and role assignments.

Pipeline usage
- GitHub Actions: `/.github/workflows/github-action.yml` accepts the composite `retentionProfile` and other inputs. The workflow builds Bicep, deploys infra, creates the policy definition, and optionally runs remediation.
- Azure DevOps: `Pipeline/azure-pipelines.yml` performs the same three stages (Build & Deploy, Deploy Policy Definition, Remediate) and exposes pipeline variables to control behavior.


