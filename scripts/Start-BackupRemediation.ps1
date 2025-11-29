param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [string]$CustomPolicyDefinitionName = 'Custom-CentralVmBackup'
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) {
  try { $SubscriptionId = az account show --query id -o tsv } catch { throw 'SubscriptionId required.' }
}
az account set --subscription $SubscriptionId

# Ensure policy definition exists
$policyRulesPath = Join-Path (Get-Location) 'policy-definitions/customCentralVmBackup.rules.json'
try {
  $defId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv 2>$null
} catch { $defId = $null }
if (-not $defId) {
  if (Test-Path $policyRulesPath) {
    az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup" --rules $policyRulesPath --mode Indexed -o none
    $defId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv
  } else { Write-Error "Policy rules missing: $policyRulesPath"; exit 1 }
}

# Load parameters
$repoParamsPath = Join-Path (Get-Location) 'parameters\\main.parameters.json'
if (-not (Test-Path $repoParamsPath)) { Write-Error "Parameters file missing: $repoParamsPath"; exit 1 }
$repoJson = Get-Content -Raw -Path $repoParamsPath | ConvertFrom-Json

# Regions
$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }

function Resolve-VaultRg {
  param([string]$VaultName, [string]$RegionToken)
  try {
    $vaults = az resource list --resource-type "Microsoft.RecoveryServices/vaults" -o json 2>$null | ConvertFrom-Json
    if ($vaults) {
      $match = $vaults | Where-Object { $_.name -eq $VaultName } | Select-Object -First 1
      if (-not $match) { $match = $vaults | Where-Object { $_.name -match $RegionToken -or $_.name -match 'rsv' } | Select-Object -First 1 }
      if ($match) { return @{ name = $match.name; resourceGroup = $match.resourceGroup } }
    }
  } catch {}
  return $null
}

foreach ($r in $targetRegions) {
  $idx = [Array]::IndexOf($targetRegions, $r)
  try { $vaultName = $repoJson.parameters.vaultNames.value[$idx] } catch { Write-Warning "vaultNames missing for $r"; continue }
  try { $vaultRg = $repoJson.parameters.rgNames.value[$idx] } catch { Write-Warning "rgNames missing for $r"; continue }
  try { $bpPrefix = $repoJson.parameters.backupPolicyNames.value[$idx] } catch { Write-Warning "backupPolicyNames missing for $r"; continue }
  try { $uaiName = $repoJson.parameters.uaiNames.value[$idx] } catch { Write-Warning "uaiNames missing for $r"; continue }

  $policyName = if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { "$bpPrefix-weekly" } else { "$bpPrefix-daily" }
  $assignName = "enable-vm-backup-$r"

  $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"
  $uaiId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$uaiName"

  $bp = $null
  try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json } catch {}
  if (-not $bp) {
    $vaultInfo = Resolve-VaultRg -VaultName $vaultName -RegionToken $r
    if ($vaultInfo) { $vaultName = $vaultInfo.name; $vaultRg = $vaultInfo.resourceGroup; $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"; try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json } catch {} }
  }
  if (-not $bp) { Write-Warning "backup policy not found: $backupPolicyId"; continue }

  $u = $null
  try { $u = az resource show --ids $uaiId -o json 2>$null | ConvertFrom-Json } catch {}
  if (-not $u) {
    try { $rgList = az resource list --resource-group $vaultRg --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" -o json 2>$null | ConvertFrom-Json; if ($rgList) { $match = $rgList | Where-Object { $_.name -match $uaiName -or $_.name -match $r } | Select-Object -First 1; if ($match) { $uaiId = $match.id; $u = $match } } } catch {}
    if (-not $u) { try { $subList = az resource list --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" -o json 2>$null | ConvertFrom-Json; if ($subList) { $match = $subList | Where-Object { $_.name -match $uaiName -or $_.name -match $r } | Select-Object -First 1; if ($match) { $uaiId = $match.id; $u = $match } } } catch {} }
  }
  if (-not $u) { Write-Warning "UAI not found for $r"; continue }

  try {
    az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$defId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName vaultResourceGroup=$vaultRg -o none
  } catch { Write-Warning "assignment deployment failed for $r"; continue }

  $assignId = $null
  try { $assignId = az policy assignment show -n $assignName --query id -o tsv } catch {}
  if (-not $assignId) { Write-Warning "assignment not found: $assignName"; continue }

  $remName = "remediate-vm-backup-$r"
  try {
    az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none
  } catch {
    if ($_.Exception.Message -match 'InvalidUpdateRemediationRequest') { Write-Host "remediation already active: $remName" } else { Write-Warning "remediation create failed for $r" }
  }

  Write-Host "assignment=$assignId remediation=$remName"
}
