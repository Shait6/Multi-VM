param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
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
$repoParamsPath = Join-Path -Path (Get-Location) -ChildPath 'parameters\main.parameters.json'
$repoJson = $null
if (Test-Path $repoParamsPath) {
  try {
    $repoJson = Get-Content -Raw -Path $repoParamsPath | ConvertFrom-Json
  } catch {
    Write-Warning "Failed to read repo parameters from ${repoParamsPath}: $($_.Exception.Message)"
  }
}

if (-not $RetentionProfile -and $repoJson) {
  # Prefer an explicit composite value if present
  if ($repoJson.parameters -and $repoJson.parameters.retentionProfile -and $repoJson.parameters.retentionProfile.value) {
    $RetentionProfile = $repoJson.parameters.retentionProfile.value
    Write-Host "Using retentionProfile from repo parameters: $RetentionProfile"
  } else {
    # Construct composite from individual repo parameter values where available
    $d = 14; $w = 30; $y = 0; $tn = 'backup'; $tv = 'true'
    try { if ($repoJson.parameters.dailyRetentionDays -and $repoJson.parameters.dailyRetentionDays.value) { $d = $repoJson.parameters.dailyRetentionDays.value } } catch {}
    try { if ($repoJson.parameters.weeklyRetentionDays -and $repoJson.parameters.weeklyRetentionDays.value) { $w = $repoJson.parameters.weeklyRetentionDays.value } } catch {}
    try { if ($repoJson.parameters.yearlyRetentionYears -and $repoJson.parameters.yearlyRetentionYears.value) { $y = $repoJson.parameters.yearlyRetentionYears.value } } catch {}
    # Tag name/value default; Start-BackupRemediation expects VM tag name/value coming from the composite profile
    try {
      if ($repoJson.parameters.vmTagName -and $repoJson.parameters.vmTagName.value) { $tn = $repoJson.parameters.vmTagName.value }
      if ($repoJson.parameters.vmTagValue -and $repoJson.parameters.vmTagValue.value) { $tv = $repoJson.parameters.vmTagValue.value }
    } catch {}
    $RetentionProfile = "${d}|${w}|${y}|${tn}|${tv}"
    Write-Host "Constructed retentionProfile from repo parameters: $RetentionProfile"
  }
}

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
  weeklyBackupDaysOfWeek = @{ value = $days }
  backupScheduleRunTimes = @{ value = @($BackupTime) }
  backupTimeZone         = @{ value = $BackupTimeZone }
  instantRestoreRetentionDays = @{ value = $instant }
  enableMonthlyRetention = @{ value = $false }
  enableYearlyRetention  = @{ value = $enableYearly }
  yearlyRetentionYears   = @{ value = $yearlyYears }
  remediationRoleDefinitionId = @{ value = $roleGuid }
}
$merged = @{
  "$schema" = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters = @{}
}

if ($repoJson) {
  try {
    if ($repoJson.parameters) {
      foreach ($p in $repoJson.parameters.PSObject.Properties.Name) {
        $merged.parameters[$p] = $repoJson.parameters.$p
      }
    }
  } catch {
    Write-Warning "Failed to parse repo parameters file ${repoParamsPath}: $($_.Exception.Message)"
  }
}

foreach ($k in $paramObj.Keys) {
  $val = $paramObj[$k].value
  $merged.parameters[$k] = @{ value = $val }
}

$merged | ConvertTo-Json -Depth 10 | Out-File main-params.json -Encoding utf8

$deployName = "multi-region-backup-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "Starting deployment $deployName with frequency=$BackupFrequency days=$WeeklyDaysCsv"

$compiledTemplate = Join-Path -Path (Get-Location) -ChildPath 'bicep-build\main.json'
$templateFile = if (Test-Path $compiledTemplate) { $compiledTemplate } else { Join-Path -Path (Get-Location) -ChildPath 'main.bicep' }

try {
  az deployment sub create --name $deployName --location $DeploymentLocation --template-file $templateFile --parameters @main-params.json -o json > deployment.json
} catch {
  Write-Host "Deployment failed; collecting diagnostics..."
  az deployment sub show --name $deployName -o json > deployment-show.json 2>$null
  az deployment operation sub list --name $deployName -o json > deployment-operations.json 2>$null
  if (Test-Path deployment.json) { Get-Content deployment.json | Write-Host }

  # If we attempted using a compiled template, try a fallback to deploy from the source Bicep file.
  if ($templateFile -ne (Join-Path -Path (Get-Location) -ChildPath 'main.bicep')) {
    Write-Warning "Compiled template deployment failed; attempting fallback deploy using source Bicep file 'main.bicep'."
    try {
      az deployment sub create --name "${deployName}-fallback" --location $DeploymentLocation --template-file (Join-Path -Path (Get-Location) -ChildPath 'main.bicep') --parameters @main-params.json -o json > deployment-fallback.json
      Write-Host "Fallback deployment succeeded (outputs saved to deployment-fallback.json)"
      return
    } catch {
      Write-Warning "Fallback deployment also failed: $($_.Exception.Message)"
      az deployment sub show --name "${deployName}-fallback" -o json > deployment-show-fallback.json 2>$null
      az deployment operation sub list --name "${deployName}-fallback" -o json > deployment-operations-fallback.json 2>$null
    }
  }

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
