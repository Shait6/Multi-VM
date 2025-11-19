param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [string]$CustomPolicyDefinitionName = 'Custom-CentralVmBackup-AnyOS'
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) {
  try { $SubscriptionId = az account show --query id -o tsv } catch { throw 'SubscriptionId is required (env SUBSCRIPTION_ID not set and unable to infer current account).' }
} else {
  az account set --subscription $SubscriptionId
}

# Ensure custom policy definition exists (idempotent). If missing, create from JSON file.
$policyDefJsonPath = Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.json'
try {
  $existingDef = az policy definition show -n $CustomPolicyDefinitionName -o json 2>$null | ConvertFrom-Json
} catch { $existingDef = $null }
  if (-not $existingDef) {
    if (-not (Test-Path $policyDefJsonPath)) {
      Write-Warning "Custom policy definition JSON not found at $policyDefJsonPath"
    } else {
      Write-Host "Creating custom policy definition '$CustomPolicyDefinitionName' from $policyDefJsonPath" -ForegroundColor Cyan
      # Read JSON and extract policyRule and parameters if file contains 'properties' wrapper
      try {
        $raw = Get-Content -Raw -Path $policyDefJsonPath | ConvertFrom-Json
      } catch {
        Write-Warning "Failed to parse JSON file $($policyDefJsonPath): $($_.Exception.Message)"
        $raw = $null
      }
      if ($raw -and $raw.properties) {
        $rulesObj = $raw.properties.policyRule
        $paramsObj = $raw.properties.parameters
        $tmpRules = [System.IO.Path]::GetTempFileName() + '.json'
        $tmpParams = [System.IO.Path]::GetTempFileName() + '.json'
        $rulesObj | ConvertTo-Json -Depth 99 | Out-File -FilePath $tmpRules -Encoding utf8
        if ($paramsObj) { $paramsObj | ConvertTo-Json -Depth 99 | Out-File -FilePath $tmpParams -Encoding utf8 }
        try {
          if (Test-Path $tmpParams) {
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --params $tmpParams --mode Indexed -o none
          } else {
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --mode Indexed -o none
          }
        } catch {
          Write-Warning "Failed to create policy definition: $($_.Exception.Message)"
        } finally {
          if (Test-Path $tmpRules) { Remove-Item $tmpRules -Force }
          if (Test-Path $tmpParams) { Remove-Item $tmpParams -Force }
        }
      } else {
        # If file is already a rules object, pass it directly
        try {
          az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $policyDefJsonPath --mode Indexed -o none
        } catch {
          Write-Warning "Failed to create policy definition from $($policyDefJsonPath): $($_.Exception.Message)"
        }
      }
    }
  }

$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }
Write-Host "Regions: $($targetRegions -join ', ') | Tag=$TagName=$TagValue | Freq=$BackupFrequency"

foreach ($r in $targetRegions) {
  $vaultName = "rsv-$r"
  $vaultRg   = "rsv-rg-$r"
  $base      = "backup-policy-$r"
  if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { $policyName = "$base-weekly" } else { $policyName = "$base-daily" }
  $assignName = "enable-vm-backup-anyos-$r"
  $uaiId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-$r"

  Write-Host "Assigning custom ANY-OS policy $assignName (vault=$vaultName, policy=$policyName)"
  $customDefId = ''
  try { $customDefId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv } catch { Write-Warning "Failed to resolve custom policy definition $($CustomPolicyDefinitionName): $($_.Exception.Message)" }
  if (-not $customDefId) { Write-Warning "Skipping region $r (custom policy definition not found)"; continue }
  try {
    az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$customDefId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName -o none
  } catch {
    Write-Warning "Assignment deployment failed for ${r}: $($_.Exception.Message)"
  }

  $assignId = ''
  try { $assignId = az policy assignment show -n $assignName --query id -o tsv } catch {}
  if (-not $assignId) { Write-Warning "Assignment not found in $r; skipping remediation"; continue }

  $remName = "remediate-vm-backup-anyos-$r"
  Write-Host "Triggering remediation $remName"
  az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none
}

Write-Host "Remediation triggers submitted. You can monitor jobs in Policy -> Remediations."
