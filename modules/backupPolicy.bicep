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
// Convert times to ISO 8601 Z (as seen in working templates)
var isoRunTimes = [for t in backupScheduleRunTimes: (contains(t, 'T') ? t : '2016-09-21T${t}:00Z')]
// Clamp daily instant restore to 1..5; weekly must be 5 (enforced below)
var dailyInstantRestoreDays = min(max(instantRestoreRetentionDays, 1), 5)

// DAILY POLICY
resource backupPolicyDaily 'Microsoft.RecoveryServices/vaults/backupPolicies@2025-02-01' = if (backupFrequency == 'Daily' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-daily' : backupPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V1'
    instantRPDetails: {}
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: isoRunTimes
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: isoRunTimes
        retentionDuration: {
          count: dailyRetentionDays
          durationType: 'Days'
        }
      }
    }
    tieringPolicy: {
      ArchivedRP: {
        tieringMode: 'DoNotTier'
        duration: 0
        durationType: 'Invalid'
      }
    }
    instantRpRetentionRangeInDays: dailyInstantRestoreDays
    timeZone: backupTimeZone
  }
}

// WEEKLY POLICY 
resource backupPolicyWeekly 'Microsoft.RecoveryServices/vaults/backupPolicies@2025-02-01' = if (backupFrequency == 'Weekly' || backupFrequency == 'Both') {
  parent: existingVault
  name: backupFrequency == 'Both' ? '${backupPolicyName}-weekly' : backupPolicyName
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V1'
    instantRPDetails: {}
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Weekly'
      scheduleRunDays: weeklyBackupDaysOfWeek
      scheduleRunTimes: isoRunTimes
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      weeklySchedule: {
        daysOfTheWeek: weeklyBackupDaysOfWeek
        retentionTimes: isoRunTimes
        retentionDuration: {
          count: weeklyRetentionWeeks
          durationType: 'Weeks'
        }
      }
      monthlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        retentionScheduleWeekly: {
          daysOfTheWeek: monthlyDaysOfWeek
          weeksOfTheMonth: monthlyWeeksOfMonth
        }
        retentionTimes: isoRunTimes
        retentionDuration: {
          count: monthlyRetentionMonths
          durationType: 'Months'
        }
      }
      yearlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        monthsOfYear: yearlyMonthsOfYear
        retentionScheduleWeekly: {
          daysOfTheWeek: yearlyDaysOfWeek
          weeksOfTheMonth: yearlyWeeksOfMonth
        }
        retentionTimes: isoRunTimes
        retentionDuration: {
          count: yearlyRetentionYears
          durationType: 'Years'
        }
      }
    }
    tieringPolicy: {
      ArchivedRP: {
        tieringMode: 'DoNotTier'
        duration: 0
        durationType: 'Invalid'
      }
    }
    // Azure requires 5 days when schedule is Weekly
    instantRpRetentionRangeInDays: 5
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
