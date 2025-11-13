
This repository automates deploying Recovery Services Vaults and Backup Policies for Azure VMs, and optionally enables automatic remediation so tagged VMs (for example those with tag `backup=true`) get protected automatically. The solution is intended to run from either GitHub Actions or Azure DevOps, and is built with Bicep + Azure CLI.

What's included (short)

How the solution works (high level)
1. Generate parameters: `scripts/Set-DeploymentParameters.ps1` builds `main.parameters.json` from inputs and normalizes values (times, days, retention counts).
2. Validate & build: CI runs `az bicep build` and an ARM/Bicep validate to catch template issues early.
3. Group deployment: `main.bicep` deploys the Recovery Services Vault and backup policy resources into the chosen resource group and location. It also creates a user-assigned identity and returns its resource id and principal id as outputs.
4. Role assignment: CI ensures the UAI has the needed RBAC on the vault resource group (so remediation can create protected items).
5. Subscription assignment & remediation: CI deploys a custom DeployIfNotExists policy (via `modules/backupAutoEnablePolicy.bicep`) and a `Microsoft.PolicyInsights/remediations` resource to protect tagged VMs.

File map — what each file does (short and human)

	- `recoveryVault.bicep` — creates (or references) the Recovery Services Vault in the target RG and location.
	- `backupPolicy.bicep` — creates Daily and/or Weekly backup policy resources, with retention and schedule settings.
	- `userAssignedIdentity.bicep` — creates the user-assigned managed identity used by policy remediations; outputs resource id and principal id.
	- `roleAssignment.bicep` — helper to give the UAI Contributor rights on the vault RG (so remediation can create protected items).
	- (Removed legacy template) `deploy-policy-subscription.bicep` now superseded by `modules/backupAutoEnablePolicy.bicep` + remediation.
	- `backupAutoEnablePolicy.bicep` / `autoEnablePolicy.rule.json` — policy definition template and rule JSON used by the workflows to create the DeployIfNotExists definition (the workflow replaces placeholders like vault name and role definition id before creating the policy).

	- `Set-DeploymentParameters.ps1` — central parameter generator (normalize schedule times/days, compute retention values, write `main.parameters.json`).
	- `Wait-For-AadPrincipal.ps1` — helper to poll AAD until a service principal for the UAI exists (used to avoid PrincipalNotFound timing errors).
	- `Deploy-AutoEnablePolicySubscription.ps1` / `Deploy-AuditPolicy.ps1` — subscription-scope policy deployments (auto-enable and audit flows).
	- (Removed legacy scripts) `Create-ResourceGroup.ps1`, `Deploy-Backup.ps1`, `Enable-VMBackup.ps1`, `Configure-VaultReplication.ps1` — replaced by multi-region template & automated policy remediation.

	- `.github/workflows/deploy.yml` — GitHub Actions: parameter generation, bicep build validation, group deployment, role assignment for the UAI, and a subscription deployment to create the policy assignment/remediation. Implemented to avoid shell quoting/path mangling on Windows runners by using PowerShell for param file creation and passing the parameters file to `az`.
	- `azure-pipelines.yml` — Azure DevOps: mirrors the same flow using `AzurePowerShell@5` and `AzureCLI@2` tasks. The pipeline also writes a parameters JSON and uses PowerShell inline scripts for steps that pass resource ids.
	- `azure-pipelines-audit.yml` — an optional pipeline for management-group scoped audits (keeps audits separate from infra deployment).

Important operational notes and gotchas

Quick validation steps (local)
1) Regenerate parameters (PowerShell):

```powershell
.
\scripts\Set-DeploymentParameters.ps1 `
	-Location 'eastus' `
	-SubscriptionId '<SUB_ID>' `
	-VaultName 'rsv-backup-test' `
	-BackupPolicyName 'DefaultPolicy' `
	-DailyRetentionDays 14 `
	-WeeklyRetentionDays 30 `
	-BackupScheduleRunTimes @('01:00') `
	-WeeklyBackupDaysOfWeek @('Sunday','Wednesday') `
	-IncludeLocation
```

2) Validate the group deployment (PowerShell-safe parameters quoting):

```powershell
az account set --subscription <SUB_ID>
az deployment group validate --resource-group <RG_NAME> --template-file main.bicep --parameters "@main.parameters.json"
```

If validation fails, capture the full JSON output for the failing operation (the provider `statusMessage`) and use it to pinpoint which property the Recovery Services API expects.

Troubleshooting tips

How to extend or adapt

# Multi-Region Azure VM Backup Automation

This solution automates the deployment of Azure Recovery Services Vaults (RSVs), backup policies, and User Assigned Identities (UAIs) across multiple regions, with full RBAC and policy automation for VM backup protection. It is designed for use with Azure DevOps or GitHub Actions, and is built with modular Bicep templates and PowerShell scripts.

## What this solution does

- **Creates 4 resource groups** (one per region: westeurope, northeurope, swedencentral, germanywestcentral).
- **Deploys 1 Recovery Services Vault per region** (geo-redundant storage, cross-region restore enabled).
- **Deploys 1 backup policy per RSV** (daily and weekly retention, customizable schedule).
- **Deploys 1 User Assigned Identity per region** (UAI, for policy remediation and automation).
- **Assigns RBAC (Backup Operator) to each UAI** on its respective vault resource group.
- **Implements policy and remediation** to auto-enable backup for tagged VMs (DeployIfNotExists pattern).
- **Provides audit policy** for management group-level compliance.
- **Includes modular Bicep and PowerShell scripts** for parameter generation, deployment, and troubleshooting.
- **Supports CI/CD pipelines** for both Azure DevOps and GitHub Actions.

## How it works

1. **Parameter generation:** `scripts/Set-DeploymentParameters.ps1` builds `main.parameters.json` from your inputs, normalizing times, days, and retention.
2. **Multi-region deployment:** `main.bicep` deploys 4 resource groups, 4 RSVs, 4 backup policies, and 4 UAIs, wiring everything together with RBAC and outputs.
3. **Policy automation:** Policy modules and scripts enable DeployIfNotExists for tagged VMs, and audit policies for compliance.
4. **CI/CD integration:** Pipelines in Azure DevOps and GitHub Actions automate validation, deployment, and policy assignment.

## File map

- `main.bicep` — Orchestrates multi-region deployment of RGs, RSVs, backup policies, UAIs, and RBAC.
- `main.parameters.json` — Generated by `Set-DeploymentParameters.ps1` for parameterized deployments.
- `modules/` — Modular Bicep files for RSV, backup policy, UAI, RBAC, policy, and audit.
- `scripts/` — PowerShell scripts for parameter generation, deployment, troubleshooting, and policy automation.
- `.github/workflows/` and `azure-pipelines.yml` — CI/CD pipelines for GitHub Actions and Azure DevOps.

## Key features

- **Multi-region, multi-vault, multi-UAI**: Standardizes backup protection across 4 Azure regions.
- **Geo-redundant storage and cross-region restore**: Each RSV is configured for maximum resiliency.
- **Daily and weekly backup retention**: Policies are customizable and standardized via modules.
- **RBAC automation**: Each UAI is granted Backup Operator on its vault RG only (least privilege).
- **Policy-driven auto-protection**: DeployIfNotExists policy and remediation for tagged VMs.
- **Audit and compliance**: Management group-level audit policy for backup coverage.
- **Extensible and modular**: Add more regions, policies, or automation as needed.

## Usage notes

- Deploy at the **subscription scope** for full multi-region automation.
- Vaults are regional: VMs must be protected by a vault in the same region.
- All scripts and pipelines are designed for idempotency and safe re-runs.
- Ensure your deployment identity has sufficient permissions (Policy Contributor, User Access Admin, etc.).

## CI/CD Parameters

Azure DevOps (`azure-pipelines.yml`) parameters:

- `subscriptionId`: Target subscription GUID.
- `deploymentLocation`: Metadata location for subscription-scope deployment (does not restrict resource regions).
- `enableAutoRemediation`: `'true'|'false'` to deploy the auto-enable policy job.
- `multiRegionAutoRemediation`: If `'true'`, creates auto-enable policy per region; otherwise only baseline region.
- `policyBaselineRegion`: Region used when `multiRegionAutoRemediation` is false.
- `backupFrequency`: `Daily|Weekly|Both` controls which policy types are deployed.
- `dailyRetentionDays`: Integer retention for daily points.
- `weeklyRetentionDays`: Integer retention for weekly points.
- `weeklyBackupDaysOfWeekString`: Comma-separated list of weekly backup days (e.g. `Sunday,Wednesday`).
- `vmTagName` / `vmTagValue`: Tag selector for VMs to auto-remediate (default `backup=true`).

GitHub Actions workflow inputs:

- `subscriptionId`
- `deploymentLocation`
- `enableAutoRemediation`
- `weeklyBackupDaysOfWeek`: Comma-separated weekly days.
- `backupFrequency`
- `dailyRetentionDays`
- `weeklyRetentionDays`
- `vmTagName` / `vmTagValue`

Both pipelines build a transient parameters JSON (e.g. `bicep-params.json`, `main-params.json`) passed to `main.bicep`. Weekly days are converted into an array for the `weeklyBackupDaysOfWeek` Bicep parameter.

Deployment outputs captured:

- `vaultIds` — array of RSV resource IDs.
- `backupPolicyNames` — policy names per region.
- `userAssignedIdentityIds` — UAI resource IDs.
- `userAssignedIdentityPrincipalIds` — principal object IDs for RBAC/policy.

These outputs are written to `deployment-outputs.json` (Azure DevOps) or `gh-deployment-outputs.json` (GitHub) for downstream steps (e.g. reporting or additional policy assignments).

Failure diagnostics (Azure DevOps) dump `deployment-show.json` and `deployment-operations.json` on error. Extend similarly in GitHub by adding an error trap around `az deployment sub create` if desired.

## Quick start

1. Generate parameters:
   ```powershell
   .\scripts\Set-DeploymentParameters.ps1 -Location 'westeurope' -SubscriptionId '<SUB_ID>' -IncludeLocation
   ```
2. Deploy the solution:
   ```powershell
   az deployment sub create --location westeurope --template-file main.bicep --parameters "@main.parameters.json"
   ```
3. (Optional) Enable policy automation:
   ```powershell
   .\scripts\Deploy-AutoEnablePolicySubscription.ps1 -SubscriptionId '<SUB_ID>' -Location 'westeurope' -VmTagName 'backup' -VmTagValue 'true' -BackupPolicyName 'backup-policy-westeurope' -VaultName 'rsv-westeurope' -VaultResourceGroup 'rsv-rg-westeurope'
   ```

---
For more details, see the comments in each Bicep and script file.

If you'd like, I can help make any of the following small, safe edits:
- Make subscription deployment names unique per run to avoid location conflicts.
- Harden retries to only retry for identity-related errors.
- Add a short diagnostic output on failure that prints `az deployment sub operation list --name <deploy>` to capture provider `statusMessage` for debugging.

That's a concise overview — if you want, tell me which small change above to make and I'll apply it and validate the pipeline files.
