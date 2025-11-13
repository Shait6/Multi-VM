
## Multi-Region Azure VM Backup Automation

Summary
- Deploys a standardized, multi‑region VM backup platform using Azure Recovery Services Vaults (RSVs), backup policies, and per‑region User Assigned Identities (UAIs).
- Automates RBAC and an optional DeployIfNotExists policy that protects tagged VMs, including starting remediation for existing VMs.
- Delivered as subscription‑scope Bicep plus CI/CD workflows for GitHub Actions and Azure DevOps.

Architecture (What gets created)
- Four resource groups (one per region): westeurope, northeurope, swedencentral, germanywestcentral.
- One RSV per region with geo‑redundant capability and cross‑region restore enabled.
- One backup policy per region with configurable frequency (Daily/Weekly/Both), retention, and schedule.
- One UAI per region, granted Backup Operator on its vault RG (least privilege for backup operations).
- Optional: Subscription‑scope policy assignment (DeployIfNotExists) using a UAI to enable backup for tagged VMs; remediation triggered automatically by script.

File Inventory (What each file does)
- `main.bicep`: Subscription‑scope orchestration. Creates RGs, RSVs, policies, UAIs, and RBAC per region. Outputs arrays of vault IDs, policy names/IDs, UAI IDs and principal IDs.
- `modules/recoveryVault.bicep`: Creates a Recovery Services Vault in a region with configurable SKU and public network access; restore settings are enabled for resiliency.
- `modules/backupPolicy.bicep`: Creates daily/weekly VM backup policies with parameterized schedule times, weekly days, and retention; outputs policy IDs and names.
- `modules/userAssignedIdentity.bicep`: Creates a UAI per region; outputs resource ID and principalId.
- `modules/roleAssignment.bicep`: Assigns the Backup Operator role to a UAI at the target RG scope; normalizes GUIDs to role definition IDs.
- `modules/backupAutoEnablePolicy.bicep`: Creates a DeployIfNotExists policy definition and assignment at subscription scope, attaches a UAI identity, and parameterizes tag, vault and policy values (loads rule from JSON).
- `modules/backupAuditPolicy.bicep`: Optional management‑group scope Audit policy module to report tagged VMs without backup (not used by default).
- `modules/autoEnablePolicy.rule.json`: Raw policy rule JSON with placeholders the module replaces (tag name/value, vault, policy, role ids).
- `scripts/Deploy-AutoEnablePolicySubscription.ps1`: Deploys the auto‑enable policy at subscription scope, attaches a UAI to the assignment, and starts remediation for existing non‑compliant VMs. Derives the UAI resource ID by region if not provided.
- `.github/workflows/github-action.yml`: GitHub Actions workflow to build Bicep, deploy `main.bicep` at subscription scope with parameters, capture outputs, and optionally deploy auto‑enable policy.
- `azure-pipelines.yml`: Azure DevOps pipeline mirroring the same flow (build, deploy, outputs, optional multi‑region remediation with tag filters).
- `.gitignore`: Ignores `bicep-build/` and ephemeral deployment/parameter JSONs.
- `bicep-build/`: Generated ARM JSON from Bicep build; used only for syntax validation (not deployed directly).

Parameters (Pipelines)
- Azure DevOps (`azure-pipelines.yml`): `subscriptionId`, `deploymentLocation`, `enableAutoRemediation`, `multiRegionAutoRemediation`, `policyBaselineRegion`, `backupFrequency`, `dailyRetentionDays`, `weeklyRetentionDays`, `weeklyBackupDaysOfWeekString`, `vmTagName`, `vmTagValue`.
- GitHub Actions (`.github/workflows/github-action.yml`): `subscriptionId`, `deploymentLocation`, `enableAutoRemediation`, `weeklyBackupDaysOfWeek`, `backupFrequency`, `dailyRetentionDays`, `weeklyRetentionDays`, `vmTagName`, `vmTagValue`.
- Weekly days strings are converted into arrays for the `weeklyBackupDaysOfWeek` Bicep parameter.

Outputs
- `vaultIds`, `backupPolicyNames`, `userAssignedIdentityIds`, `userAssignedIdentityPrincipalIds` are written to JSON by the pipelines for downstream consumption.

Prerequisites
Common
- Azure subscription with permissions: Owner or (Contributor + User Access Administrator) at subscription scope to create RGs, RSVs, identities, RBAC, and policies.
- Resource Provider registrations enabled for: `Microsoft.RecoveryServices`, `Microsoft.Authorization`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`.

GitHub Actions
- Secret `serivcon` containing an Azure federated or service principal credentials JSON usable by `azure/login@v2`.
- Repository permission to use OIDC or the service principal.

Azure DevOps (ADO)
- Service connection `bicep_deploy_SC` with access to the target subscription (Contributor + User Access Administrator recommended).
- Agent image `windows-latest` or equivalent with Azure CLI available (pipelines install Bicep if needed).

Quick Start (optional local validation)
```powershell
az account set --subscription <SUB_ID>
az bicep build --file main.bicep
az deployment sub create --name test-deploy --location westeurope --template-file main.bicep --parameters backupFrequency=Daily dailyRetentionDays=14 weeklyRetentionDays=30 weeklyBackupDaysOfWeek='["Sunday","Wednesday"]'
```

Notes
- The policy remediation step is initiated by `scripts/Deploy-AutoEnablePolicySubscription.ps1` and uses a UAI on the assignment. The script derives the UAI resource ID by convention (`/subscriptions/<sub>/resourceGroups/rsv-rg-<region>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-<region>`) unless explicitly provided.
- Legacy single‑region files may still exist in your working tree; they are not used by the pipelines and can be deleted safely.
