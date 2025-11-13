
## Multi-Region Azure VM Backup Automation

Overview
- Deploys a standardized, multi‑region VM backup platform using Azure Recovery Services Vaults (RSVs), backup policies, and per‑region User Assigned Identities (UAIs).
- Automates RBAC and an optional DeployIfNotExists policy that protects tagged VMs, including remediation for existing VMs.
- Delivered as subscription‑scope Bicep with CI/CD for GitHub Actions and Azure DevOps.

Architecture
- Four resource groups (one per region): `westeurope`, `northeurope`, `swedencentral`, `germanywestcentral`.
- One RSV per region; cross‑region restore and resilience settings applied (configurable via vault SKU and public network access).
- One backup policy per region with configurable frequency (`Daily` / `Weekly` / `Both`), schedule time + timezone, Instant Restore retention, and retention tiers:
	- Daily: Retention in days.
	- Weekly: Retention in weeks; supports optional Monthly and Yearly tiers to mirror the Azure Portal shape.
- One UAI per region, granted Backup Operator on the vault RG (scoped least‑privilege for backup operations).
- Optional: Subscription‑scope DeployIfNotExists policy to auto‑enable backup for tagged VMs, using the UAI; remediation can target baseline or all regions.

Key Policy Shape (Weekly)
- Uses the Recovery Services API accepted weekly shape:
	- `schedulePolicy.scheduleRunFrequency = Weekly`, `scheduleRunDays`, `scheduleRunTimes` as ISO with `Z` (UTC) like `2020-01-01T18:30:00Z`.
	- `scheduleWeeklyFrequency = 0`.
	- `instantRPDetails: {}`, `instantRpRetentionRangeInDays` set.
	- `tieringPolicy.ArchivedRP.tieringMode = DoNotTier`.
	- `timeZone` supplied (e.g., `UTC`).
	- Optional `monthlySchedule` and `yearlySchedule` blocks aligned with the Portal’s “Weekly” retention format.

CI/CD Workflows
- GitHub Actions: `.github/workflows/github-action.yml`
	- Builds Bicep for syntax check; deploys `main.bicep` at subscription scope with inputs; captures outputs; optionally deploys the auto‑enable policy.
- Azure DevOps: `azure-pipelines.yml`
	- Builds Bicep; deploys subscription scope with parameters; captures outputs; optional auto‑enable policy remediation across baseline or all regions.
	- Uses a UI pipeline variable `subscriptionId` (not a YAML parameter) for the Azure subscription.

Parameters and Inputs
- Common policy inputs (surfaced to both CI systems):
	- `backupFrequency` (`Daily` | `Weekly` | `Both`)
	- `dailyRetentionDays`
	- `weeklyRetentionDays` (converted to weeks)
	- `weeklyBackupDaysOfWeek` (comma separated → array)
	- `backupScheduleTime` / `backupScheduleTimeString` (HH:mm)
	- `backupTimeZone` (e.g., `UTC`)
	- `instantRestoreRetentionDays`
	- `enableMonthlyRetention`, `monthlyRetentionMonths`, `monthlyWeeksOfMonth`, `monthlyDaysOfWeek`
	- `enableYearlyRetention`, `yearlyRetentionYears`, `yearlyMonthsOfYear`, `yearlyWeeksOfMonth`, `yearlyDaysOfWeek`
- Remediation inputs:
	- `enableAutoRemediation`, `multiRegionAutoRemediation`, `policyBaselineRegion`, `vmTagName`, `vmTagValue`.

Prerequisites
- Azure (both CI systems)
	- Permissions: Owner or (Contributor + User Access Administrator) at subscription scope.
	- Resource providers: `Microsoft.RecoveryServices`, `Microsoft.Authorization`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`.
- GitHub Actions
	- Secret `AZURE_CREDENTIALS` containing Service Principal JSON for `azure/login@v2` (or OIDC setup with `clientId`, `tenantId`, `subscriptionId`).
- Azure DevOps
	- Service connection with access to the target subscription.
	- Define pipeline variable `subscriptionId` with your subscription GUID (Pipelines → Edit → Variables).
	- Hosted agent `windows-latest` (pipeline installs Bicep if missing).

How to Run
- GitHub Actions
	1) Go to Actions → “Deploy Multi-Region VM Backup” → Run workflow.
	2) Provide inputs or accept defaults (e.g., `backupFrequency`, `weeklyBackupDaysOfWeek`, `backupScheduleTime`, retention tiers).
	3) Ensure `AZURE_CREDENTIALS` is configured in repository secrets.
- Azure DevOps
	1) Set the `subscriptionId` variable in the pipeline UI.
	2) Queue a run; adjust YAML parameters like `backupFrequency`, weekly days string, schedule time, and retention.
	3) Toggle `enableAutoRemediation` to deploy the policy and remediate tagged VMs.

Outputs
- Both pipelines write `deployment-outputs.json`/`gh-deployment-outputs.json` with:
	- `vaultIds`, `backupPolicyNames`, `userAssignedIdentityIds`, `userAssignedIdentityPrincipalIds`.

File-by-File Guide
- Root
	- `main.bicep`: Subscription‑scope orchestration across the four regions.
		- Creates per‑region RGs: `rsv-rg-<region>`.
		- Modules: one RSV, one backup policy (Daily/Weekly/Both), one UAI, and RBAC (Backup Operator) per region.
		- Parameters: schedule time(s), timezone, frequency, daily/weekly retention, Instant Restore retention, and optional Monthly/Yearly retention blocks.
		- Outputs arrays of vault/policy/UAI identifiers.
	- `main.parameters.json`: Example parameter file (not used by CI; pipelines build a parameter object dynamically).
	- `azure-pipelines.yml`: Azure DevOps pipeline (build, deploy, outputs, optional remediation). Reads subscription from variable `$(subscriptionId)`.
	- `azure-pipelines-audit.yml`: Optional pipeline to deploy an Audit‑only policy (no auto‑enable) using `scripts/Deploy-AuditPolicy.ps1`.
	- `.github/workflows/github-action.yml`: GitHub workflow to deploy subscription‑scope Bicep and optional auto‑enable policy.
	- `bicep-build/`: Compiled ARM JSON output used for syntax checks.
- Modules (`modules/`)
	- `recoveryVault.bicep`: Creates RSV with SKU and network settings.
	- `backupPolicy.bicep`: VM policy resource(s):
		- Daily policy (`2023-04-01`) with daily retention.
		- Weekly policy (`2025-02-01`) with weekly retention, optional monthly/yearly tiers; uses ISO `Z` schedule times and includes `instantRPDetails`, `tieringPolicy`, `timeZone`.
	- `userAssignedIdentity.bicep`: Creates per‑region UAI and outputs IDs.
	- `roleAssignment.bicep`: Grants Backup Operator role to the UAI on the RG.
	- `backupAutoEnablePolicy.bicep`: Policy definition/assignment for DeployIfNotExists to enable backup on tagged VMs.
	- `backupAuditPolicy.bicep`: Audit‑only policy (no deployment). Useful for visibility at management group scope.
	- `autoEnablePolicy.rule.json`: Parameterized rule JSON consumed by the auto‑enable policy module.
- Scripts (`scripts/`)
	- `Deploy-AutoEnablePolicySubscription.ps1`: Deploys the DeployIfNotExists policy at subscription scope and starts remediation; uses UAI identity located in the region’s vault RG by convention unless overridden.
		- Requires the Recovery Services Vault and its resource group to already exist (provisioned by `main.bicep`). The script no longer creates vaults or resource groups.
	- `Deploy-AuditPolicy.ps1`: Deploys an Audit policy (management group scope).
	- `Deploy-Backup.ps1`: Example helper to run a subscription deployment with parameters.
	- `Enable-VMBackup.ps1`: Enables backup for a specific VM (manual tooling / examples).
	- `Create-ResourceGroup.ps1`: Helper to create RGs (not needed by CI since Bicep creates RGs).
	- `Wait-For-AadPrincipal.ps1`: Utility to wait for UAI/SP propagation before role assignment.
	- `Set-DeploymentParameters.ps1`: Utility to generate parameter files (CI builds inline JSON instead).
	- `Configure-VaultReplication.ps1`: Optional vault replication configuration.

Troubleshooting
- YAML errors in ADO: Ensure parameter blocks align; all list items start at the same column.
- GitHub login failing: Configure `AZURE_CREDENTIALS` secret (SP JSON) or set up OIDC properly.
- Policy validation errors (weekly): Use ISO `Z` times (e.g., `2020-01-01T18:30:00Z`), set `scheduleWeeklyFrequency: 0`, include `instantRPDetails: {}`, and `tieringPolicy.ArchivedRP.DoNotTier`.
- Missing permissions: Assign `User Access Administrator` to allow role assignments, and ensure the service connection has sufficient scope.
- No subscription in ADO: Set pipeline variable `subscriptionId` or rely on the service connection’s default subscription.

Local Validation (optional)
```powershell
az account set --subscription <SUB_ID>
az bicep build --file main.bicep
az deployment sub create --name test-deploy --location westeurope --template-file main.bicep --parameters \
	backupFrequency=Weekly \
	weeklyRetentionDays=30 \
	weeklyBackupDaysOfWeek='["Sunday","Wednesday"]' \
	backupScheduleRunTimes='["18:30"]' \
	backupTimeZone=UTC \
	instantRestoreRetentionDays=2 \
	enableMonthlyRetention=true \
	monthlyRetentionMonths=60 \
	monthlyWeeksOfMonth='["First"]' \
	monthlyDaysOfWeek='["Sunday"]' \
	enableYearlyRetention=true \
	yearlyRetentionYears=10 \
	yearlyMonthsOfYear='["January","February","March"]' \
	yearlyWeeksOfMonth='["First"]' \
	yearlyDaysOfWeek='["Sunday"]'
```

Notes
- The auto‑enable remediation uses a UAI on the policy assignment. The script derives the identity by convention: `/subscriptions/<sub>/resourceGroups/rsv-rg-<region>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-<region>`.
- `main.parameters.json` is provided as a reference; CI builds a parameter JSON inline for each run.
- The `Deploy-AutoEnablePolicySubscription.ps1` script no longer includes any path to create resource groups or vaults. Run the main deployment first so `rsv-rg-<region>` and `rsv-<region>` exist.
