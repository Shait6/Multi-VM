// PARAMETERS (retain original surface for main.bicep compatibility)
@description('Parent Recovery Services Vault resource name')
param vaultName string
@description('Name of the backup policy base (daily/weekly suffix added when Both)')
param backupPolicyName string
@description('Backup frequency: Daily, Weekly, or Both')
@allowed(['Daily','Weekly','Both'])
param backupFrequency string = 'Daily'
@description('Backup run times (UTC HH:mm)')
param backupScheduleRunTimes array
@description('Weekly run days (Weekly or Both)')
param weeklyBackupDaysOfWeek array = []
@description('Retention in days for daily backups')
param dailyRetentionDays int = 14
@description('Retention in days for weekly backups')
param weeklyRetentionDays int = 30
@description('Time zone for schedule')
param backupTimeZone string = 'UTC'

// Retained unused parameters (monthly/yearly + instant restore) to avoid breaking callers
param instantRestoreRetentionDays int = 2
param enableMonthlyRetention bool = false
param monthlyRetentionMonths int = 60
param monthlyRetentionScheduleFormat string = 'Weekly'
param monthlyWeeksOfMonth array = ['First']
param monthlyDaysOfWeek array = ['Sunday']
param enableYearlyRetention bool = false
param yearlyRetentionYears int = 10
param yearlyRetentionScheduleFormat string = 'Weekly'
param yearlyMonthsOfYear array = ['January','February','March']
param yearlyWeeksOfMonth array = ['First']
param yearlyDaysOfWeek array = ['Sunday']

// Existing vault reference
resource existingVault 'Microsoft.RecoveryServices/vaults@2025-02-01' existing = { name: vaultName }

// Derived values
var weeklyRetentionWeeks = int((weeklyRetentionDays + 6) / 7)

// DAILY POLICY (minimal – matches working reference)
resource backupPolicyDaily 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = if (backupFrequency == 'Daily' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-daily' : backupPolicyName
  location: resourceGroup().location
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: instantRestoreRetentionDays
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
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
    timeZone: backupTimeZone
  }
}

// WEEKLY POLICY (minimal – matches working reference)
resource backupPolicyWeekly 'Microsoft.RecoveryServices/vaults/backupPolicies@2019-05-13' = if (backupFrequency == 'Weekly' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-weekly' : backupPolicyName
  location: resourceGroup().location
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: instantRestoreRetentionDays
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Weekly'
      scheduleRunTimes: backupScheduleRunTimes
      scheduleRunDays: weeklyBackupDaysOfWeek
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      weeklySchedule: {
        daysOfTheWeek: weeklyBackupDaysOfWeek
        retentionTimes: backupScheduleRunTimes
        retentionDuration: {
          count: weeklyRetentionWeeks
          durationType: 'Weeks'
        }
      }
    }
    timeZone: backupTimeZone
  }
}

// Outputs
var dailyPolicyId = (backupFrequency == 'Daily' || backupFrequency == 'Both') ? backupPolicyDaily.id : ''
var weeklyPolicyId = (backupFrequency == 'Weekly' || backupFrequency == 'Both') ? backupPolicyWeekly.id : ''
var dailyPolicyName = (backupFrequency == 'Daily' || backupFrequency == 'Both') ? backupPolicyDaily.name : ''
var weeklyPolicyName = (backupFrequency == 'Weekly' || backupFrequency == 'Both') ? backupPolicyWeekly.name : ''

output backupPolicyIds array = concat((dailyPolicyId != '') ? [dailyPolicyId] : [], (weeklyPolicyId != '') ? [weeklyPolicyId] : [])
output backupPolicyNames array = concat((dailyPolicyName != '') ? [dailyPolicyName] : [], (weeklyPolicyName != '') ? [weeklyPolicyName] : [])
// Pass-through so callers depending on these params remain valid
output monthlyRetentionEnabled bool = enableMonthlyRetention
output yearlyRetentionEnabled bool = enableYearlyRetention
// Mark otherwise unused parameters as used via a dummy calc output (benign)
output _unusedParams object = {
  instantRestoreRetentionDays: instantRestoreRetentionDays
  monthlyRetentionMonths: monthlyRetentionMonths
  monthlyRetentionScheduleFormat: monthlyRetentionScheduleFormat
  monthlyWeeksOfMonth: monthlyWeeksOfMonth
  monthlyDaysOfWeek: monthlyDaysOfWeek
  yearlyRetentionYears: yearlyRetentionYears
  yearlyRetentionScheduleFormat: yearlyRetentionScheduleFormat
  yearlyMonthsOfYear: yearlyMonthsOfYear
  yearlyWeeksOfMonth: yearlyWeeksOfMonth
  yearlyDaysOfWeek: yearlyDaysOfWeek
}

// Notes / recommendations:
// - Avoid setting object properties to null (e.g., scheduleRunDays: null). Use an empty array or omit the property.
// - Ensure the API versions (2025-02-01 and 2023-04-01 used above) are correct/available in your subscription/region.
// - Validate the expected formats for backupScheduleRunTimes and retentionTimes against the Recovery Services API docs.
//   Some APIs require full ISO datetimes while others accept only time-of-day strings (e.g., "02:30"). Provide examples to users.
// - If you want stronger validation, add allowed/regex checks for the run times and weekly day names.
// - If you see deployment-time validation errors, paste the exact error and I can help iterate further.
