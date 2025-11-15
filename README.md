
## Multi-Region Azure VM Backup Automation

### 1. Overview
This solution deploys and manages a standardized multi‑region Azure VM backup platform. It creates per‑region Recovery Services Vaults (RSVs), daily/weekly backup policies (optionally both), user‑assigned identities (UAIs), and role assignments. A DeployIfNotExists policy can automatically enable backup for tagged virtual machines, with remediation executed on demand.

### 2. Key Capabilities
- Multi‑region rollout (currently: `westeurope`, `northeurope`, `swedencentral`, `germanywestcentral`).
- Daily, Weekly, or Both policy creation with automatic shape alignment to the Azure API.
- Composite retention & tagging input (GitHub: `retentionProfile`, ADO: `retentionProfile` + separate tag params).
- Instant Restore logic: Weekly (and weekly portion of Both) always uses 5 days; Daily portion clamps 1–5.
- Optional monthly/yearly retention tiers (disabled by default; yearly enabled only when >0 supplied).
- Automated policy‑based remediation to protect tagged VMs.
- Role parameterization: choose `Contributor` (broad) or `Backup Contributor` (least‑privilege for backup) at dispatch/pipeline runtime.

### 3. Architecture Summary
Per region resource group `rsv-rg-<region>` hosts:
- Recovery Services Vault `rsv-<region>`
- Backup Policy resources: daily and/or weekly variants (weekly includes optional monthly/yearly tiers via union logic in Bicep).
- User Assigned Identity `uai-<region>` (used for policy remediation).
- Role assignment on the RG for the UAI using selected role definition.

Global (subscription‑scope) components:
- Subscription‑scope Bicep (`main.bicep`) orchestrates cross‑region deployment.
- Optional DeployIfNotExists policy & assignment (subscription‑scope) for auto‑enable backup.
- Audit‑only policy pipeline (Azure DevOps) for visibility without enforcement.

### 4. GitHub Workflow Dispatch Inputs (`.github/workflows/github-test.yml`)
- `subscriptionId`: Target subscription.
- `deploymentLocation`: Metadata deployment location (e.g., `westeurope`).
- `weeklyBackupDaysOfWeek`: Comma separated days (e.g., `Sunday,Wednesday`).
- `retentionProfile`: `DailyDays|WeeklyWeeks|YearlyYears|TagName|TagValue`. Example: `14|5|0|backup|true` (Yearly=0 disables yearly tier).
- `backupFrequency`: `Daily` | `Weekly` | `Both`.
- `backupScheduleTime`: Time of day (UTC HH:mm, e.g., `18:30`).
- `backupTimeZone`: Time zone string (e.g., `UTC`).
- `instantRestoreRetentionDays`: 1–5 (ignored for weekly; weekly forced to 5).
- `remediationRole`: `Contributor` | `BackupContributor` (maps to GUID).
- `enableAutoRemediation`: `true` to deploy & kick off remediation stage.

Derived at runtime:
- Tag name/value extracted from `retentionProfile` (positions 4 & 5).
- Yearly enable flag auto‑computed (`Yearly > 0`).

### 5. Azure DevOps Pipeline Parameters (`azure-pipelines.yml`)
- `deploymentLocation`, `backupFrequency`, `weeklyBackupDaysOfWeekString`, `backupScheduleTimeString`, `backupTimeZone`.
- `retentionProfile`: `DailyDays|WeeklyWeeks|YearlyYears` (no tag embedding; tags still separate in ADO).
- Tag parameters: `vmTagName`, `vmTagValue`.
- Remediation control: `enableAutoRemediation`, `multiRegionAutoRemediation`, `policyBaselineRegion`, `waitMinutesBeforeRemediation`.
- Role selection: `remediationRole` (same choices as GitHub).
- Monthly/Yearly tier toggles and settings still available individually for advanced use (monthly disabled by default; yearly disabled when Yearly=0).

Differences vs GitHub:
- GitHub embeds tags inside `retentionProfile`; ADO uses separate tag parameters.
- GitHub workflow sets outputs from step `deploy_backup`; ADO persists everything through inline Azure CLI script.
- ADO includes optional multi‑region remediation toggle; GitHub currently remediates only baseline deployment location.

### 6. Backup Policy Logic (`modules/backupPolicy.bicep`)
- Daily policy (`2025-02-01` API) with `scheduleRunTimes` (ISO conversion) and daily retention.
- Weekly policy (`2025-02-01` API) uses:
  - `scheduleRunFrequency=Weekly`, `scheduleRunDays`, ISO run times.
  - Weekly retention: pipelines accept weeks and convert to days for Bicep; in Bicep, weeklyRetentionDays must be >=7 (represents >=1 week).
  - Conditional monthly/yearly blocks built via `union()` only when enabled.
  - Instant restore retention forced to 5.
- Common fields: `policyType='V1'`, `instantRPDetails={}`, `tieringPolicy` set to `DoNotTier`.

### 7. Role Selection
`main.bicep` parameter `remediationRoleDefinitionId` defaults to Contributor GUID:
- Contributor: `b24988ac-6180-42a0-ab88-20f7382dd24c`
- Backup Contributor: `5e0bd9bd-7b93-4f78-a8b0-1f0f781f1493`
Switch via dispatch/pipeline to enforce least privilege once validated.

### 8. DeployIfNotExists Auto‑Enable Policy
- Definition & assignment in `modules/backupAutoEnablePolicy.bicep` using rule file `autoEnablePolicy.rule.json`.
- Effect deploys protected item resource if VM with tag lacks backup.
- Remediation started explicitly (GitHub second job, ADO remediation stage).

### 9. Repository Layout Summary
| Path | Purpose |
|------|---------|
| `main.bicep` | Orchestrates multi‑region deployment & RBAC |
| `modules/recoveryVault.bicep` | Creates RSV with SKU/network settings |
| `modules/backupPolicy.bicep` | Daily/Weekly (Both) VM backup policies |
| `modules/userAssignedIdentity.bicep` | Per‑region UAI resources |
| `modules/roleAssignment.bicep` | Role assignment for UAI |
| `modules/backupAutoEnablePolicy.bicep` | DeployIfNotExists enable backup policy |
| `modules/backupAuditPolicy.bicep` | Audit-only policy variant |
| `modules/autoEnablePolicy.rule.json` | Policy rule JSON template |
| `.github/workflows/github-test.yml` | GitHub dispatch workflow (composite retention + tags) |
| `azure-pipelines.yml` | ADO deploy & remediation pipeline |
| `azure-pipelines-audit.yml` | ADO audit-only pipeline |
| `scripts/*.ps1` | Helper scripts for policy deployment/remediation |

### 10. Prerequisites
Azure Subscription:
- Permissions: Owner or (Contributor + User Access Administrator) for role assignments & policy remediation.
- Providers registered: `Microsoft.RecoveryServices`, `Microsoft.ManagedIdentity`, `Microsoft.Authorization`, `Microsoft.PolicyInsights`.

Identity & Access:
- Service Principal or Managed Identity with sufficient scope (deployment + RBAC + policy).
- Tags: Ensure VMs to be protected have tag name/value matching composite or pipeline params.

Tools:
- Azure CLI (GitHub runner & ADO agent) — Bicep installed automatically if missing.
- PowerShell 7+ recommended locally for manual testing.

### 11. Quick Start (GitHub Actions)
1. Add secret for Azure login (e.g., `AZURE_CREDENTIALS`).
2. Run the workflow with default `retentionProfile=14|5|0|backup|true` and `backupFrequency=Weekly`.
3. (Optional) Enable remediation by setting `enableAutoRemediation=true`.
4. Confirm policies and vaults: Recovery Services Vault > Backup Policies.

### 12. Quick Start (Azure DevOps)
1. Create/verify service connection.
2. Set pipeline variable `subscriptionId`.
3. Queue pipeline with desired parameters (e.g., `backupFrequency=Both`, `retentionProfile=14|5|0`).
4. Enable `enableAutoRemediation=true` to start remediation stage after deploy.

### 13. Local Test Commands
```powershell
az account set --subscription <SUB_ID>
az bicep build --file main.bicep
az deployment sub create --name test-backup --location westeurope --template-file main.bicep --parameters \
  backupFrequency=Weekly \
  weeklyRetentionDays=35 \
  weeklyBackupDaysOfWeek='["Sunday","Wednesday"]' \
  backupScheduleRunTimes='["18:30"]' \
  backupTimeZone=UTC \
  instantRestoreRetentionDays=2 \
  enableYearlyRetention=false \
  enableMonthlyRetention=false \
  remediationRoleDefinitionId=b24988ac-6180-42a0-ab88-20f7382dd24c
```

### 14. Troubleshooting
- Weekly policy NO_PARAM errors: Remove yearly/monthly tiers (set Yearly=0) and verify ISO times; gradually re‑enable yearly.
- Invalid weekly retention (<1 week): Weekly policy requires retention of at least one full week; supply WeeklyWeeks >= 1 (pipelines convert to >=7 days).
- RoleDefinitionDoesNotExist: Switch back to Contributor; confirm GUID for Backup Contributor is present (`az role definition list --name "Backup Contributor"`).
- Remediation identity lacks permissions: Ensure role assignment succeeded and policy assignment identity’s UAI has Contributor/Backup Contributor on vault RG + target VM RG.
- GitHub outputs missing tags: Confirm `retentionProfile` has exactly 5 segments.
- Azure DevOps subscription not set: Define variable or rely on service connection default.

### 15. Design Notes
- Composite retention reduces input surface while preserving flexibility.
- Yearly tier disabled by default to avoid early validation failures; enable by setting non‑zero Yearly value.
- Weekly instant restore forced to 5 due to Azure platform requirement for weekly schedules.
- Role parameterization allows gradual shift to least privilege once validated.

### 16. Next Improvements (Future Roadmap)
- Add optional monthly retention to composite profile.
- Extend remediation to choose daily vs weekly policy when Both is deployed.
- Add validation regex for time format & day names.
- Integrate OIDC federation (GitHub) to remove SP secret.

---
If you encounter an unexpected deployment error, capture the failing nested deployment operations:
```powershell
az deployment operation group list --resource-group rsv-rg-westeurope --name backupPolicyModule-westeurope -o jsonc
```
Share the `statusMessage` snippet to iterate quickly.

