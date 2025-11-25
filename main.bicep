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
var rgNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}${envTag}${nameSep}${regionCodes[i]}', 0, nameMaxLength)]
var vaultNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}vault${nameSep}${regionCodes[i]}', 0, nameMaxLength)]
var uaiNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}uai${nameSep}${regionCodes[i]}', 0, nameMaxLength)]
var backupPolicyNames = [for (region, i) in regions: substring('${namePrefix}${nameSep}bkp${nameSep}${regionCodes[i]}', 0, nameMaxLength)]

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
param backupScheduleRunTimes array = [ '01:00' ]
@description('Daily retention in days (>=7)')
@minValue(7)
param dailyRetentionDays int = 14
@description('Weekly retention in days (>=7; converted to weeks internally)')
@minValue(7)
param weeklyRetentionDays int = 30
@description('Days of week for weekly backups')
param weeklyBackupDaysOfWeek array = [ 'Sunday', 'Wednesday' ]
@allowed([ 'Daily', 'Weekly', 'Both' ])
@description('Backup frequency for VM policies across regions')
param backupFrequency string = 'Daily'
@description('Backup schedule timezone (e.g., UTC)')
param backupTimeZone string = 'UTC'
@description('Instant Restore snapshot retention in days')
param instantRestoreRetentionDays int = 2
@description('Enable additional monthly retention tier (for weekly policy)')
param enableMonthlyRetention bool = false
@description('Monthly retention duration in months')
param monthlyRetentionMonths int = 60
@description('Monthly retention weeks of the month')
param monthlyWeeksOfMonth array = [ 'First' ]
@description('Monthly retention days of the week')
param monthlyDaysOfWeek array = [ 'Sunday' ]
@description('Enable additional yearly retention tier (for weekly policy)')
param enableYearlyRetention bool = false
@description('Yearly retention duration in years')
param yearlyRetentionYears int = 10
@description('Yearly retention months of year')
param yearlyMonthsOfYear array = [ 'January', 'February', 'March' ]
@description('Yearly retention weeks of the month')
param yearlyWeeksOfMonth array = [ 'First' ]
@description('Yearly retention days of the week')
param yearlyDaysOfWeek array = [ 'Sunday' ]
@allowed([ 'Enabled', 'Disabled' ])
@description('Public network access setting for vaults')
param publicNetworkAccess string = 'Enabled'
@description('Recovery Services Vault SKU name')
param vaultSkuName string = 'RS0'
@description('Recovery Services Vault SKU tier')
param vaultSkuTier string = 'Standard'

@description('Role Definition ID or GUID for remediation identity ( Contributor )')
param remediationRoleDefinitionId string = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// Soft-delete defaults for AVM
param softDeleteSettings object = {
  enhancedSecurityState: 'Enabled'
  softDeleteRetentionPeriodInDays: 14
  softDeleteState: 'Enabled'
}

// Default tags applied to vault resources
param tags object = {
  Environment: 'Non-Prod'
  'hidden-title': 'This is visible in the resource name'
  Role: 'DeploymentValidation'
}

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
// The remediation flow only needs one UAI with subscription-level permissions.
module uai 'br:mcr.microsoft.com/bicep/avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'userAssignedIdentityModule-${regions[0]}'
  scope: resourceGroup(rgNames[0])
  params: {
    // AVM module expects `name` for the user-assigned identity
    name: uaiNames[0]
    location: regions[0]
    // preserve tags shape from top-level `tags` param if desired
    tags: tags
  }
  dependsOn: [vaults[0]]
}

// Assign RBAC role to UAI on each RSV RG using provided remediationRoleDefinitionId
// Assign RBAC role to each UAI at subscription scope (one assignment per UAI)
// Create a single subscription-scope role assignment for the single UAI.
module rbacSub 'br:mcr.microsoft.com/bicep/avm/res/authorization/role-assignment/sub-scope:0.1.0' = {
  name: 'roleAssignmentSubModule-${regions[0]}'
  params: {
    principalId: uai.outputs.principalId
    // AVM parameter name is `roleDefinitionIdOrName`
    roleDefinitionIdOrName: remediationRoleDefinitionId
    principalType: 'ServicePrincipal'
  }
  
}

// Export outputs as arrays for all regions
output vaultIds array = [for (region, i) in regions: vaults[i].outputs.resourceId]
// backup policy ids/names are created under each vault; derive them after build/deploy if needed
// Export the single UAI as single-element arrays to avoid breaking consumers
output userAssignedIdentityIds array = [uai.outputs.resourceId]
output userAssignedIdentityPrincipalIds array = [uai.outputs.principalId]
