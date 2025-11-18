param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [switch]$RunBackupNow
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { throw 'SubscriptionId is required.' }
az account set --subscription $SubscriptionId

$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }
Write-Host "Regions: $($targetRegions -join ', ') | Tag=$TagName=$TagValue | Freq=$BackupFrequency"

foreach ($r in $targetRegions) {
  $vaultName = "rsv-$r"
  $vaultRg   = "rsv-rg-$r"
  $base      = "backup-policy-$r"
  if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { $policyName = "$base-weekly" } else { $policyName = "$base-daily" }
  $assignName = "enable-vm-backup-$r"
  $uaiId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-$r"

  Write-Host "Assigning policy $assignName (vault=$vaultName, policy=$policyName)"
  try {
    az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/backupAutoEnablePolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName vaultResourceGroup=$vaultRg backupPolicyName=$policyName -o none
  } catch {
    Write-Warning "Assignment deployment failed for ${r}: $($_.Exception.Message)"
  }

  $assignId = ''
  try { $assignId = az policy assignment show -n $assignName --query id -o tsv } catch {}
  if (-not $assignId) { Write-Warning "Assignment not found in $r; skipping remediation"; continue }

  $remName = "remediate-vm-backup-$r"
  Write-Host "Triggering remediation $remName"
  az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none

  if ($RunBackupNow) {
    Write-Host "Waiting briefly for remediation jobs to register protected items in vault $vaultName..."
    Start-Sleep -Seconds 60

    Write-Host "Querying protected items in vault $vaultName (region $r) for VMs tagged $TagName=$TagValue..."
    $protected = az backup protected-item list `
      --vault-name $vaultName `
      --resource-group $vaultRg `
      --backup-management-type AzureIaasVM `
      --query "[?contains(tolower(properties.sourceResourceId), 'providers/microsoft.compute/virtualmachines')].{id:id, sourceId:properties.sourceResourceId}" -o json | ConvertFrom-Json

    if (-not $protected) {
      Write-Host "No protected items found in $vaultName yet; skipping Backup Now for region $r."
      continue
    }

    foreach ($item in $protected) {
      $vmId = $item.sourceId
      $vm = az vm show --ids $vmId --query "{name:name, tags:tags}" -o json | ConvertFrom-Json
      if (-not $vm) { continue }

      $vmTags = $vm.tags
      if (-not $vmTags) { continue }

      if ($vmTags[$TagName] -ne $TagValue) { continue }

      Write-Host "Triggering Backup Now for VM $($vm.name) in region $r..."

      $parsed = $item.id -split '/'
      $containerName = $parsed[-3]
      $itemName = $parsed[-1]

      az backup protection backup-now `
        --vault-name $vaultName `
        --resource-group $vaultRg `
        --container-name $containerName `
        --item-name $itemName `
        --backup-management-type AzureIaasVM `
        --retain-until (Get-Date).AddDays(30).ToString('yyyy-MM-dd') `
        -o none
    }
  }
}

Write-Host "Remediation triggers submitted. You can monitor jobs in Policy -> Remediations."
