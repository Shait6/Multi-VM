targetScope = 'subscription'

// List of regions to deploy to
var regions = [
  'westeurope'
  'northeurope'
  'swedencentral'
  'germanywestcentral'
]

// Naming configuration (compact convention: <prefix><sep><env><sep><regionCode>)
@description('Name prefix for resources (short)')
param namePrefix string = 'rsv'
@description('Environment tag (short, e.g., prod, np)')
param envTag string = 'np'
@description('Separator used between name segments')
param nameSep string = '-'
@description('Maximum length for generated names (will be truncated)')
param nameMaxLength int = 24
@description('Number of characters to take from region name to form a region code')
param regionShortLen int = 3

// Simple region code generation (first N characters, lowercased, no spaces)
var regionCodes = [for r in regions: toLower(substring(replace(r, ' ', ''), 0, regionShortLen))]

// Resource group, vault, UAI and policy name generation (keeps names compact and deterministic)
var rgNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}${envTag}${nameSep}${regionCodes[i]}', 0, min(nameMaxLength, length('${namePrefix}${nameSep}${envTag}${nameSep}${regionCodes[i]}')))]
var vaultNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}vault${nameSep}${regionCodes[i]}', 0, min(nameMaxLength, length('${namePrefix}${nameSep}vault${nameSep}${regionCodes[i]}')))]
var uaiNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}uai${nameSep}${regionCodes[i]}', 0, min(nameMaxLength, length('${namePrefix}${nameSep}uai${nameSep}${regionCodes[i]}')))]
var backupPolicyNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}bkp${nameSep}${regionCodes[i]}', 0, min(nameMaxLength, length('${namePrefix}${nameSep}bkp${nameSep}${regionCodes[i]}')))]

// Derived helper vars for backup policy construction (mirrors logic in modules/backupPolicy.bicep)
var isoRunTimes = [for t in backupScheduleRunTimes: (contains(t, 'T') ? t : '2016-09-21T${t}:00Z')]
var weeklyRetentionWeeks = int((weeklyRetentionDays + 6) / 7)
var dailyInstantRestoreDays = min(max(instantRestoreRetentionDays, 1), 5)

var monthlyScheduleObj = enableMonthlyRetention ? {
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
} : {}

var yearlyScheduleObj = enableYearlyRetention ? {
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
} : {}

var retentionPolicyWeekly = union({
  retentionPolicyType: 'LongTermRetentionPolicy'
  weeklySchedule: {
    daysOfTheWeek: weeklyBackupDaysOfWeek
    retentionTimes: isoRunTimes
    retentionDuration: {
      count: weeklyRetentionWeeks
      durationType: 'Weeks'
    }
  }
}, monthlyScheduleObj, yearlyScheduleObj)

// Build an array (per region) of backup policy objects compatible with AVM vault's `backupPolicies` parameter
var backupPoliciesPerRegion = [for (region, i) in regions: concat(
  (backupFrequency == 'Daily' || backupFrequency == 'Both') ? [
    {
      name: '${backupPolicyNames[i]}-daily'
      properties: {
        backupManagementType: 'AzureIaasVM'
        policyType: 'V1'
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
        instantRpRetentionRangeInDays: dailyInstantRestoreDays
        timeZone: backupTimeZone
      }
    }
  ] : [],
  (backupFrequency == 'Weekly' || backupFrequency == 'Both') ? [
    {
      name: '${backupPolicyNames[i]}-weekly'
      properties: {
        backupManagementType: 'AzureIaasVM'
        policyType: 'V1'
        schedulePolicy: {
          schedulePolicyType: 'SimpleSchedulePolicy'
          scheduleRunFrequency: 'Weekly'
          scheduleRunDays: weeklyBackupDaysOfWeek
          scheduleRunTimes: isoRunTimes
        }
        retentionPolicy: retentionPolicyWeekly
        instantRpRetentionRangeInDays: 5
        timeZone: backupTimeZone
      }
    }
  ] : []
)]

// Compute policy IDs/names based on the backupPolicies we handed to the vault module
// (policy ids/names can be derived if needed by running `az bicep build` and/or after deployment)

@description('Backup schedule run times (UTC HH:mm) applied to all region policies')
param backupScheduleRunTimes array
@description('Daily retention in days (>=7)')
@minValue(7)
param dailyRetentionDays int
@description('Weekly retention in days (>=7; converted to weeks internally)')
@minValue(7)
param weeklyRetentionDays int
@description('Days of week for weekly backups')
param weeklyBackupDaysOfWeek array
@allowed([ 'Daily', 'Weekly', 'Both' ])
@description('Backup frequency for VM policies across regions')
param backupFrequency string
@description('Backup schedule timezone (e.g., UTC)')
param backupTimeZone string
@description('Instant Restore snapshot retention in days')
param instantRestoreRetentionDays int
@description('Enable additional monthly retention tier (for weekly policy)')
param enableMonthlyRetention bool
@description('Monthly retention duration in months')
param monthlyRetentionMonths int
@description('Monthly retention weeks of the month')
param monthlyWeeksOfMonth array
@description('Monthly retention days of the week')
param monthlyDaysOfWeek array
@description('Enable additional yearly retention tier (for weekly policy)')
param enableYearlyRetention bool
@description('Yearly retention duration in years')
param yearlyRetentionYears int
@description('Yearly retention months of year')
param yearlyMonthsOfYear array
@description('Yearly retention weeks of the month')
param yearlyWeeksOfMonth array
@description('Yearly retention days of the week')
param yearlyDaysOfWeek array
@allowed([ 'Enabled', 'Disabled' ])
@description('Public network access setting for vaults')
param publicNetworkAccess string
@description('Recovery Services Vault SKU name')
param vaultSkuName string
@description('Recovery Services Vault SKU tier')
param vaultSkuTier string

@description('Role Definition ID or GUID for remediation identity ( Contributor )')
param remediationRoleDefinitionId string

// Soft-delete defaults for AVM
param softDeleteSettings object

// Default tags applied to vault resources
param tags object

// Create resource groups in each region using AVM `resource-group` module
module rgs 'br:mcr.microsoft.com/bicep/avm/res/resources/resource-group:0.4.0' = [for (region, i) in regions: {
  name: 'resourceGroupModule-${region}'
  scope: subscription()
  params: {
    name: rgNames[i]
    location: region
    tags: tags
  }
}]

// Deploy RSV, backup policy, UAI, and RBAC in each RG/region
module vaults 'br:mcr.microsoft.com/bicep/avm/res/recovery-services/vault:0.11.1' = [for (region, i) in regions: {
  name: 'recoveryVaultModule-${region}'
  scope: resourceGroup(rgNames[i])
  params: {
    // AVM required parameter
    name: vaultNames[i]
    // Optional but explicit: location and public network access
    location: region
    publicNetworkAccess: publicNetworkAccess
    // Backup configuration: default to GeoRedundant storage model (can be adjusted)
    backupConfig: {
      storageModelType: 'GeoRedundant'
      // softDeleteFeatureState is an AVM backupConfig property; keep Enabled to protect backups
      softDeleteFeatureState: 'Enabled'
    }
    // Soft-delete settings (shape matches AVM softDeleteSettings)
    softDeleteSettings: softDeleteSettings
    // Surface SKU info in tags so values are tracked and avoid unused-parameter warnings
    tags: union(tags, {
      vaultSkuName: vaultSkuName
      vaultSkuTier: vaultSkuTier
    })
    // Create backup policies via AVM vault module
    backupPolicies: backupPoliciesPerRegion[i]
  }
  dependsOn: [rgs[i]]
}]

// Backup policies are created by the AVM Recovery Services Vault module via `backupPolicies` parameter.
// We pass a per-region array constructed above.

// Deploy a single User Assigned Identity (UAI) in the first region only.
// Make this a single-element array module (copy-style) so any compiler-generated
// copyIndex usage is valid inside the module's deployment template.
module uai 'br:mcr.microsoft.com/bicep/avm/res/managed-identity/user-assigned-identity:0.4.0' = [for i in range(0, 1): {
  name: 'userAssignedIdentityModule-${regions[i]}'
  scope: resourceGroup(rgNames[i])
  params: {
    // AVM module expects `name` for the user-assigned identity
    name: uaiNames[i]
    location: regions[i]
    // preserve tags shape from top-level `tags` param if desired
    tags: tags
  }
  dependsOn: [vaults[0]]
}]

// Assign RBAC role to UAI at subscription scope (one assignment for the single UAI).
module rbacSub 'br:mcr.microsoft.com/bicep/avm/res/authorization/role-assignment/sub-scope:0.1.0' = {
  name: 'roleAssignmentSubModule-${regions[0]}'
  params: {
    principalId: uai[0].outputs.principalId
    // AVM parameter name is `roleDefinitionIdOrName`
    roleDefinitionIdOrName: remediationRoleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

// Export outputs as arrays for all regions
output vaultIds array = [for (region, i) in regions: vaults[i].outputs.resourceId]
// backup policy ids/names are created under each vault; derive them after build/deploy if needed
// Export the single UAI as single-element arrays to avoid breaking consumers
// `uai` is a single-element module array; expose outputs as arrays to keep
// consumers unchanged.
output userAssignedIdentityIds array = [for i in range(0, 1): uai[i].outputs.resourceId]
output userAssignedIdentityPrincipalIds array = [for i in range(0, 1): uai[i].outputs.principalId]
