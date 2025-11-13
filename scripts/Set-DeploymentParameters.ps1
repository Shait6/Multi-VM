# Main parameters script for VM Backup deployment
param(
    [string]$Location,
    [string]$SubscriptionId,
    [string]$VaultName = "rsv-backup-$($env:resourceSuffix)",
    [string]$BackupPolicyName = "DefaultPolicy",
    [int]$DailyRetentionDays = 14,
    [int]$WeeklyRetentionDays = 30,
    [array]$WeeklyBackupDaysOfWeek = @("Sunday","Wednesday"),
    [array]$BackupScheduleRunTimes = @("01:00"),
    [string]$BackupFrequency = 'Daily',
    [switch]$IncludeLocation,
    [string]$VaultSkuName = 'RS0',
    [string]$VaultSkuTier = 'Standard'
)

# Create parameter hashtable
$parameters = @{
    vaultName = $VaultName
    backupPolicyName = $BackupPolicyName
    weeklyBackupDaysOfWeek = $WeeklyBackupDaysOfWeek
        # Use time-of-day strings (HH:mm or HH:mm:ss) rather than full ISO datetimes to match Recovery Services API expectations
        backupScheduleRunTimes = $BackupScheduleRunTimes
    vaultSkuName = $VaultSkuName
    vaultSkuTier = $VaultSkuTier
}

# Optionally include location in the parameters file. Many workflows prefer to pass location via CLI or leave it out.
if ($IncludeLocation) {
    $parameters['location'] = $Location
}

# Normalize schedule run times to HH:mm:ss (provider commonly accepts time-of-day with seconds)
$normalizedTimes = @()
foreach ($entry in $parameters['backupScheduleRunTimes']) {
    if ($null -eq $entry) {
        Write-Host "Warning: null entry found in backupScheduleRunTimes; passing through."
        $normalizedTimes += $entry
        continue
    }

    # Try parse as DateTime and format to HH:mm:ss
    try {
        $dt = [DateTime]::Parse($entry)
        $normalizedTimes += $dt.ToString('HH:mm:ss')
        continue
    } catch {
        # Not a parseable DateTime string
    }

    # If it already matches HH:mm or HH:mm:ss, normalize to HH:mm:ss
    if ($entry -match '^[0-9]{1,2}:[0-9]{2}$') {
        $parts = $entry.Split(':')
        $hh = [int]$parts[0]
        $mm = [int]$parts[1]
        if ($hh -ge 0 -and $hh -lt 24 -and $mm -ge 0 -and $mm -lt 60) {
            $normalizedTimes += ('{0:00}:{1:00}:00' -f $hh, $mm)
            continue
        }
    }

    if ($entry -match '^[0-9]{1,2}:[0-9]{2}:[0-9]{2}$') {
        # Validate ranges and keep as-is
        $parts = $entry.Split(':')
        $hh = [int]$parts[0]
        $mm = [int]$parts[1]
        $ss = [int]$parts[2]
        if ($hh -ge 0 -and $hh -lt 24 -and $mm -ge 0 -and $mm -lt 60 -and $ss -ge 0 -and $ss -lt 60) {
            $normalizedTimes += ('{0:00}:{1:00}:{2:00}' -f $hh, $mm, $ss)
            continue
        }
    }

    Write-Host "Warning: could not parse backupScheduleRunTimes entry '$entry' - passing through raw value and provider will validate."
    $normalizedTimes += $entry
}

$parameters['backupScheduleRunTimes'] = $normalizedTimes

# Normalize weeklyBackupDaysOfWeek values to Title case and validate known day names
$validDays = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
$normalizedDays = @()
foreach ($d in $parameters['weeklyBackupDaysOfWeek']) {
    if ($null -eq $d) { continue }
    $nd = ($d.ToString()).Trim()
    # Title case (first letter uppercase, rest lowercase)
    $nd = ($nd.Substring(0,1).ToUpper() + $nd.Substring(1).ToLower())
    if ($validDays -contains $nd) {
        $normalizedDays += $nd
    } else {
        Write-Host "Warning: unknown day name '$d' in weeklyBackupDaysOfWeek; will pass through raw value."
        $normalizedDays += $d
    }
}
$parameters['weeklyBackupDaysOfWeek'] = $normalizedDays

# Always emit backupFrequency and retention days so ARM template receives explicit values
$parameters['backupFrequency'] = $BackupFrequency
$parameters['dailyRetentionDays'] = $DailyRetentionDays
$parameters['weeklyRetentionDays'] = $WeeklyRetentionDays

# Convert to JSON
$parametersJson = @{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{}
}

foreach ($key in $parameters.Keys) {
    $parametersJson.parameters[$key] = @{
        value = $parameters[$key]
    }
}

# Output the JSON
$parametersJson | ConvertTo-Json -Depth 10 | Out-File "main.parameters.json"