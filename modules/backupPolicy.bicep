@description('Parent Recovery Services Vault resource name')
param vaultName string

@description('Name of the backup policy')
param backupPolicyName string

@description('Backup frequency: Daily, Weekly, or Both')
@allowed([
  'Daily'
  'Weekly'
  'Both'
])
param backupFrequency string = 'Daily'

@description('Backup run times (UTC). Example: [ "02:30", "14:00" ] or full ISO times depending on API expectations.')
param backupScheduleRunTimes array

@description('Weekly run days (used when backupFrequency == "Weekly"). Example: [ "Sunday", "Wednesday" ]')
param weeklyBackupDaysOfWeek array = []

@description('Retention in days for daily backups')
param dailyRetentionDays int = 14

@description('Retention in days for weekly backups')
param weeklyRetentionDays int = 30

// Reference existing vault as parent
resource existingVault 'Microsoft.RecoveryServices/vaults@2025-02-01' existing = {
  name: vaultName
}

// Create daily policy when requested (or when 'Both' selected)
resource backupPolicyDaily 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = if (backupFrequency == 'Daily' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-daily' : backupPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      // Do NOT set scheduleRunDays to null. Use an array (empty array is acceptable) or omit the property.
      scheduleRunTimes: backupScheduleRunTimes
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: backupScheduleRunTimes
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
    }
    timeZone: 'UTC'
  }
}

// Create weekly policy when requested (or when 'Both' selected)
resource backupPolicyWeekly 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = if (backupFrequency == 'Weekly' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-weekly' : backupPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Weekly'
      scheduleRunTimes: backupScheduleRunTimes
      scheduleRunDays: weeklyBackupDaysOfWeek
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      weeklySchedule: {
        retentionTimes: backupScheduleRunTimes
        retentionDuration: {
          count: weeklyRetentionDays
          durationType: 'Days'
        }
      }
    }
    timeZone: 'UTC'
  }
}

// Safer outputs: build component values and filter out empty strings so we don't output placeholders.
var dailyPolicyId = (backupFrequency == 'Daily' || backupFrequency == 'Both') ? backupPolicyDaily.id : ''
var weeklyPolicyId = (backupFrequency == 'Weekly' || backupFrequency == 'Both') ? backupPolicyWeekly.id : ''

var dailyPolicyName = (backupFrequency == 'Daily' || backupFrequency == 'Both') ? backupPolicyDaily.name : ''
var weeklyPolicyName = (backupFrequency == 'Weekly' || backupFrequency == 'Both') ? backupPolicyWeekly.name : ''

// Use concat with conditional arrays to avoid emitting empty-string placeholders.
output backupPolicyIds array = concat(
  (dailyPolicyId != '') ? [dailyPolicyId] : [],
  (weeklyPolicyId != '') ? [weeklyPolicyId] : []
)

output backupPolicyNames array = concat(
  (dailyPolicyName != '') ? [dailyPolicyName] : [],
  (weeklyPolicyName != '') ? [weeklyPolicyName] : []
)

// Notes / recommendations:
// - Avoid setting object properties to null (e.g., scheduleRunDays: null). Use an empty array or omit the property.
// - Ensure the API versions (2025-02-01 and 2023-04-01 used above) are correct/available in your subscription/region.
// - Validate the expected formats for backupScheduleRunTimes and retentionTimes against the Recovery Services API docs.
//   Some APIs require full ISO datetimes while others accept only time-of-day strings (e.g., "02:30"). Provide examples to users.
// - If you want stronger validation, add allowed/regex checks for the run times and weekly day names.
// - If you see deployment-time validation errors, paste the exact error and I can help iterate further.
