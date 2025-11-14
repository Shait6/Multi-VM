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


@description('Instant Restore snapshot retention in days')
param instantRestoreRetentionDays int = 2

@description('Enable additional monthly retention tier (for weekly policy)')
param enableMonthlyRetention bool = false

@description('Monthly retention duration in months')
param monthlyRetentionMonths int = 60

@description('Monthly retention schedule format type')
@allowed([
  'Weekly'
])
param monthlyRetentionScheduleFormat string = 'Weekly'

@description('Monthly retention weeks of the month')
@allowed([
  'First'
  'Second'
  'Third'
  'Fourth'
  'Last'
])
param monthlyWeeksOfMonth array = [ 'First' ]

@description('Monthly retention days of the week')
@allowed([
  'Sunday'
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
  'Saturday'
])
param monthlyDaysOfWeek array = [ 'Sunday' ]

@description('Enable additional yearly retention tier (for weekly policy)')
param enableYearlyRetention bool = false

@description('Yearly retention duration in years')
param yearlyRetentionYears int = 10

@description('Yearly retention schedule format type')
@allowed([
  'Weekly'
])
param yearlyRetentionScheduleFormat string = 'Weekly'

@description('Yearly retention months of year')
@allowed([
  'January'
  'February'
  'March'
  'April'
  'May'
  'June'
  'July'
  'August'
  'September'
  'October'
  'November'
  'December'
])
param yearlyMonthsOfYear array = [ 'January', 'February', 'March' ]

@description('Yearly retention weeks of the month')
@allowed([
  'First'
  'Second'
  'Third'
  'Fourth'
  'Last'
])
param yearlyWeeksOfMonth array = [ 'First' ]

@description('Yearly retention days of the week')
@allowed([
  'Sunday'
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
  'Saturday'
])
param yearlyDaysOfWeek array = [ 'Sunday' ]

// Reference existing vault as parent
resource existingVault 'Microsoft.RecoveryServices/vaults@2025-02-01' existing = {
  name: vaultName
}

@description('Time zone for backup scheduling (e.g., "UTC")')
param backupTimeZone string = 'UTC'

// Weekly retention must be specified in Weeks; convert provided days to weeks (rounding up)
var weeklyRetentionWeeks = int((weeklyRetentionDays + 6) / 7)

// Create daily policy when requested (or when 'Both' selected)
resource backupPolicyDaily 'Microsoft.RecoveryServices/vaults/backupPolicies@2019-05-13' = if (backupFrequency == 'Daily' || backupFrequency == 'Both') {
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

// Create weekly policy when requested (or when 'Both' selected)
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
      scheduleRunDays: weeklyBackupDaysOfWeek
      scheduleRunTimes: backupScheduleRunTimes
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
      ...(enableMonthlyRetention ? {
        monthlySchedule: {
          retentionScheduleFormatType: monthlyRetentionScheduleFormat
          retentionScheduleWeekly: {
            daysOfTheWeek: monthlyDaysOfWeek
            weeksOfTheMonth: monthlyWeeksOfMonth
          }
          retentionTimes: backupScheduleRunTimes
          retentionDuration: {
            count: monthlyRetentionMonths
            durationType: 'Months'
          }
        }
      } : {})
      ...(enableYearlyRetention ? {
        yearlySchedule: {
          retentionScheduleFormatType: yearlyRetentionScheduleFormat
          monthsOfYear: yearlyMonthsOfYear
          retentionScheduleWeekly: {
            daysOfTheWeek: yearlyDaysOfWeek
            weeksOfTheMonth: yearlyWeeksOfMonth
          }
          retentionTimes: backupScheduleRunTimes
          retentionDuration: {
            count: yearlyRetentionYears
            durationType: 'Years'
          }
        }
      } : {})
    }
    timeZone: backupTimeZone
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
