
## Multi-Region Azure VM Backup Automation

This solution deploys Azure Recovery Services Vaults (RSVs), backup policies, and User Assigned Identities (UAIs) across four regions with automated RBAC and optional policy-based auto‑remediation for tagged VMs. It is implemented with Bicep templates and CI/CD pipelines (Azure DevOps & GitHub Actions).

### Current Architecture
- 4 Resource Groups (one per region) and 4 RSVs.
- Backup policies (Daily / Weekly / Both) per vault with configurable retention & schedule.
- One UAI per region granted Backup Operator on its vault resource group.
- DeployIfNotExists policy + remediation to enable backup for tagged VMs.
- Optional audit policy (management group scope) via `backupAuditPolicy.bicep`.
 - Policy assignment uses a User Assigned Identity (UAI) and remediation is automatically started by the deployment script.

### Core Files
- `main.bicep` – Orchestrates multi-region RGs, RSVs, policies, identities, RBAC & outputs.
- `modules/` – `recoveryVault.bicep`, `backupPolicy.bicep`, `userAssignedIdentity.bicep`, `roleAssignment.bicep`, `backupAutoEnablePolicy.bicep`, `backupAuditPolicy.bicep`, `autoEnablePolicy.rule.json`.
- `scripts/Deploy-AutoEnablePolicySubscription.ps1` – Subscription-scope auto-enable policy deployment; attaches a UAI to the policy assignment and starts remediation for existing non-compliant VMs.
	(Audit policy script and separate audit pipeline removed as unused; `modules/backupAuditPolicy.bicep` remains available if audit coverage is reintroduced.)
- CI: `azure-pipelines.yml`, `.github/workflows/github-action.yml`, optional `azure-pipelines-audit.yml`.

### Removed Legacy Files
Parameter generation, manual vault replication, manual per-VM enable scripts and older subscription wrappers have been deleted to reduce clutter. CI now passes parameters inline.

### CI/CD Parameters (Azure DevOps)
`subscriptionId`, `deploymentLocation`, `enableAutoRemediation`, `multiRegionAutoRemediation`, `policyBaselineRegion`, `backupFrequency`, `dailyRetentionDays`, `weeklyRetentionDays`, `weeklyBackupDaysOfWeekString`, `vmTagName`, `vmTagValue`.

### CI/CD Inputs (GitHub Actions)
`subscriptionId`, `deploymentLocation`, `enableAutoRemediation`, `weeklyBackupDaysOfWeek`, `backupFrequency`, `dailyRetentionDays`, `weeklyRetentionDays`, `vmTagName`, `vmTagValue`.

Weekly days strings are converted to arrays and passed to the Bicep `weeklyBackupDaysOfWeek` parameter.

### Outputs
`vaultIds`, `backupPolicyNames`, `userAssignedIdentityIds`, `userAssignedIdentityPrincipalIds` – persisted to JSON in each pipeline for downstream use.

### Quick Local Test
```powershell
az account set --subscription <SUB_ID>
az bicep build --file main.bicep
az deployment sub create --name test-deploy --location westeurope --template-file main.bicep --parameters backupFrequency=Daily dailyRetentionDays=14 weeklyRetentionDays=30 weeklyBackupDaysOfWeek='["Sunday","Wednesday"]'
```

### Optional: Deploy Auto‑Enable Policy Manually
```powershell
pwsh ./scripts/Deploy-AutoEnablePolicySubscription.ps1 -SubscriptionId <SUB_ID> -Location westeurope -VmTagName backup -VmTagValue true -BackupPolicyName backup-policy-westeurope -VaultName rsv-westeurope -VaultResourceGroup rsv-rg-westeurope
```

### Failure Diagnostics (Azure DevOps)
Failed deployments produce `deployment-show.json` and `deployment-operations.json` containing provider status messages for troubleshooting.

### Extensibility Ideas
- Add daily schedule time parameterization per region.
- Publish outputs as pipeline artifacts.
- Introduce retention tiers per environment (prod vs dev).

---
All legacy, unused files have been removed. The repository now contains only active multi‑region deployment and policy automation assets.
