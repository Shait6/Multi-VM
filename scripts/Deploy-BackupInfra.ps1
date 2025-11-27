param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$WeeklyDaysCsv = $env:WEEKLY_DAYS,
  [string]$RetentionProfile = $env:RETENTION_PROFILE,
  [string]$BackupTime = $env:BACKUP_TIME,
  [string]$BackupTimeZone = $env:BACKUP_TZ,
  [string]$InstantRestoreDays = $env:INSTANT_RESTORE_DAYS,
  [string]$ArtifactsDir = $env:ARTIFACTS_DIR
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { throw 'SUBSCRIPTION_ID is required.' }
if (-not $DeploymentLocation) { $DeploymentLocation = 'westeurope' }
if (-not $BackupFrequency) { $BackupFrequency = 'Weekly' }

az account set --subscription $SubscriptionId

$days = if ($WeeklyDaysCsv) { $WeeklyDaysCsv.Split(',') | ForEach-Object { $_.Trim() } } else { @('Sunday','Wednesday') }
$instant = [int]($InstantRestoreDays | ForEach-Object { if($_){$_} else {2} })
if ($BackupFrequency -eq 'Weekly') { $instant = 5 }

# Read optional repo parameters
$repoParamsPath = Join-Path -Path (Get-Location) -ChildPath 'parameters\main.parameters.json'
$repoJson = $null
if (Test-Path $repoParamsPath) {
  try { $repoJson = Get-Content -Raw -Path $repoParamsPath | ConvertFrom-Json } catch { $repoJson = $null }
}

# Compute retentionProfile parts (expects composite or will fall back to defaults)
if (-not $RetentionProfile -and $repoJson -and $repoJson.parameters -and $repoJson.parameters.retentionProfile -and $repoJson.parameters.retentionProfile.value) {
  $RetentionProfile = $repoJson.parameters.retentionProfile.value
}
if (-not $RetentionProfile) { $RetentionProfile = '14|30|0|backup|true' }
$parts = $RetentionProfile.Split('|')
$dailyRetention   = [int]$parts[0]
$weeklyWeeks      = [int]$parts[1]
$yearlyYears      = [int]$parts[2]
$tagName          = $parts[3]
$tagValue         = $parts[4]
$weeklyRetentionDays = $weeklyWeeks * 7
$enableYearly = $yearlyYears -gt 0

$paramObj = @{
  backupFrequency        = @{ value = $BackupFrequency }
  dailyRetentionDays     = @{ value = $dailyRetention }
  weeklyRetentionDays    = @{ value = $weeklyRetentionDays }
  weeklyBackupDaysOfWeek = @{ value = $days }
  backupScheduleRunTimes = @{ value = @($BackupTime) }
  backupTimeZone         = @{ value = $BackupTimeZone }
  instantRestoreRetentionDays = @{ value = $instant }
  enableMonthlyRetention = @{ value = $false }
  enableYearlyRetention  = @{ value = $enableYearly }
  yearlyRetentionYears   = @{ value = $yearlyYears }
}

$merged = @{
  "$schema" = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters = @{}
}

if ($repoJson -and $repoJson.parameters) {
  foreach ($p in $repoJson.parameters.PSObject.Properties.Name) { $merged.parameters[$p] = $repoJson.parameters.$p }
}
foreach ($k in $paramObj.Keys) { $merged.parameters[$k] = @{ value = $paramObj[$k].value } }

# Write minimal merged parameters to artifacts dir (default: TEMP)
if (-not $ArtifactsDir) { $ArtifactsDir = $env:TEMP }
if (-not (Test-Path $ArtifactsDir)) { New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null }
$paramsOut = Join-Path -Path $ArtifactsDir -ChildPath 'main-params.json'
$merged | ConvertTo-Json -Depth 10 | Out-File -FilePath $paramsOut -Encoding utf8

$deployName = "multi-region-backup-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "Starting deployment $deployName with frequency=$BackupFrequency days=$WeeklyDaysCsv"

$compiledTemplate = Join-Path -Path (Get-Location) -ChildPath 'bicep-build\main.json'
$templateFile = if (Test-Path $compiledTemplate) { $compiledTemplate } else { Join-Path -Path (Get-Location) -ChildPath 'main.bicep' }

try {
  az deployment sub create --name $deployName --location $DeploymentLocation --template-file $templateFile --parameters @$paramsOut -o none
  Write-Host "Deployment completed: $deployName"
} catch {
  Write-Error "Deployment failed: $($_.Exception.Message)"
  exit 1
}

# Emit GitHub step outputs if available
if ($env:GITHUB_OUTPUT) {
  "vmTagName=$tagName"  | Out-File -FilePath $env:GITHUB_OUTPUT -Append
  "vmTagValue=$tagValue" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
