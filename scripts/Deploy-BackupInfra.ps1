param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$Regions = $env:DEPLOY_REGIONS,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$WeeklyDaysCsv = $env:WEEKLY_DAYS,
  [string]$RetentionProfile = $env:RETENTION_PROFILE,
  [string]$BackupTime = $env:BACKUP_TIME,
  [string]$BackupTimeZone = $env:BACKUP_TZ,
  [string]$InstantRestoreDays = $env:INSTANT_RESTORE_DAYS
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { throw 'SUBSCRIPTION_ID is required.' }
if (-not $DeploymentLocation) { $DeploymentLocation = 'westeurope' }
if (-not $BackupFrequency) { $BackupFrequency = 'Weekly' }

az account set --subscription $SubscriptionId

$days = if ($WeeklyDaysCsv) { $WeeklyDaysCsv.Split(',') | ForEach-Object { $_.Trim() } } else { @('Sunday','Wednesday') }
$instant = [int]($InstantRestoreDays | ForEach-Object { if($_){$_} else {2} })
if ($BackupFrequency -eq 'Weekly') { $instant = 5 }

# Parse composite retention profile DailyDays|WeeklyWeeks|YearlyYears|TagName|TagValue
$parts = $RetentionProfile.Split('|')
if ($parts.Count -lt 5) { throw "Invalid retentionProfile format '$RetentionProfile'. Expected Daily|Weekly|Yearly|TagName|TagValue (e.g. 14|30|0|backup|true)." }
$dailyRetention   = [int]$parts[0]
$weeklyWeeks      = [int]$parts[1]
$yearlyYears      = [int]$parts[2]
$tagName          = $parts[3]
$tagValue         = $parts[4]
if ($dailyRetention -lt 7) { throw "dailyRetentionDays ($dailyRetention) must be >= 7" }
if ($weeklyWeeks -lt 1)   { throw "weeklyRetentionWeeks ($weeklyWeeks) must be >= 1" }
$weeklyRetentionDays = $weeklyWeeks * 7
$enableYearly = $yearlyYears -gt 0

Write-Host "Computed instant restore retention days (parameter): $instant"
Write-Host "Parsed profile -> DailyDays=$dailyRetention WeeklyWeeks=$weeklyWeeks YearlyYears=$yearlyYears TagName=$tagName TagValue=$tagValue (enableYearly=$enableYearly)"

$roleGuid = 'b24988ac-6180-42a0-ab88-20f7382dd24c' # Contributor
Write-Host "Selected remediation role: Contributor ($roleGuid)"

$paramObj = @{
  backupFrequency        = @{ value = $BackupFrequency }
  dailyRetentionDays     = @{ value = $dailyRetention }
  weeklyRetentionDays    = @{ value = $weeklyRetentionDays }
  # ensure weekly days are emitted as a JSON array (ARM expects array not comma-separated string)
  weeklyBackupDaysOfWeek = @{ value = @($days) }
  backupScheduleRunTimes = @{ value = @($BackupTime) }
  backupTimeZone         = @{ value = $BackupTimeZone }
  instantRestoreRetentionDays = @{ value = $instant }
  enableMonthlyRetention = @{ value = $false }
  enableYearlyRetention  = @{ value = $enableYearly }
  yearlyRetentionYears   = @{ value = $yearlyYears }
  remediationRoleDefinitionId = @{ value = $roleGuid }
}

# Write full ARM template parameter file structure so Azure CLI/ARM receives proper types
$paramFile = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  'contentVersion' = '1.0.0.0'
  'parameters' = $paramObj
}

$paramFile | ConvertTo-Json -Depth 10 | Out-File main-params.json -Encoding utf8

$deployName = "multi-region-backup-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "Starting deployment $deployName with frequency=$BackupFrequency days=$WeeklyDaysCsv"

# Pre-create the single central resource group (Bicep will also create it, but this ensures it exists)
try {
  $rgName = "rsv-rg-central"
  $rgLocation = "westeurope"
  Write-Host "Ensuring resource group exists: $rgName (location: $rgLocation)"
  try {
    $exists = az group exists -n $rgName | ConvertFrom-Json
    if (-not $exists) {
      az group create -n $rgName -l $rgLocation -o none
      Write-Host "Created resource group: $rgName"
    } else {
      Write-Host "Resource group already exists: $rgName"
    }
  } catch {
    Write-Warning "Failed to ensure resource group $($rgName): $($_.Exception.Message)"
  }
} catch {
  Write-Warning "Failed to create pre-provision resource group: $($_.Exception.Message)"
}

try {
  az deployment sub create --name $deployName --location $DeploymentLocation --template-file main.bicep --parameters @main-params.json -o json > deployment.json
} catch {
  Write-Host "Deployment failed; collecting diagnostics..."
  az deployment sub show --name $deployName -o json > deployment-show.json 2>$null
  az deployment operation sub list --name $deployName -o json > deployment-operations.json 2>$null
  if (Test-Path deployment.json) { Get-Content deployment.json | Write-Host }
  throw
}

$outputs = az deployment sub show --name $deployName --query properties.outputs -o json | ConvertFrom-Json
$outputs | ConvertTo-Json -Depth 10 | Out-File deployment-outputs.json -Encoding utf8
Write-Host "Outputs saved -> deployment-outputs.json"

# Emit GitHub step outputs if available
if ($env:GITHUB_OUTPUT) {
  "vmTagName=$tagName"  | Out-File -FilePath $env:GITHUB_OUTPUT -Append
  "vmTagValue=$tagValue" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
