targetScope = 'subscription'

// List of regions to deploy to
var regions = [
  'westeurope'
  'northeurope'
  'swedencentral'
  'germanywestcentral'
]

// Resource group name pattern
var rgNames = [for region in regions: 'rsv-rg-${region}']

// Vault and UAI name patterns
var vaultNames = [for region in regions: 'rsv-${region}']
var uaiNames = [for region in regions: 'uai-${region}']
var backupPolicyNames = [for region in regions: 'backup-policy-${region}']

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

// Create resource groups in each region
resource rgs 'Microsoft.Resources/resourceGroups@2021-04-01' = [for (region, i) in regions: {
  name: rgNames[i]
  location: region
}]

// Deploy RSV, backup policy, UAI, and RBAC in each RG/region
module vaults './modules/recoveryVault.bicep' = [for (region, i) in regions: {
  name: 'recoveryVaultModule-${region}'
  scope: resourceGroup(rgNames[i])
  params: {
    vaultName: vaultNames[i]
    location: region
    publicNetworkAccess: publicNetworkAccess
    skuName: vaultSkuName
    skuTier: vaultSkuTier
  }
  dependsOn: [rgs[i]]
}]

module policies './modules/backupPolicy.bicep' = [for (region, i) in regions: {
  name: 'backupPolicyModule-${region}'
  scope: resourceGroup(rgNames[i])
  params: {
    vaultName: vaultNames[i]
    backupPolicyName: backupPolicyNames[i]
    backupFrequency: backupFrequency
    backupScheduleRunTimes: backupScheduleRunTimes
    weeklyBackupDaysOfWeek: weeklyBackupDaysOfWeek
    dailyRetentionDays: dailyRetentionDays
    weeklyRetentionDays: weeklyRetentionDays
    backupTimeZone: backupTimeZone
    instantRestoreRetentionDays: instantRestoreRetentionDays
    enableMonthlyRetention: enableMonthlyRetention
    monthlyRetentionMonths: monthlyRetentionMonths
    monthlyWeeksOfMonth: monthlyWeeksOfMonth
    monthlyDaysOfWeek: monthlyDaysOfWeek
    enableYearlyRetention: enableYearlyRetention
    yearlyRetentionYears: yearlyRetentionYears
    yearlyMonthsOfYear: yearlyMonthsOfYear
    yearlyWeeksOfMonth: yearlyWeeksOfMonth
    yearlyDaysOfWeek: yearlyDaysOfWeek
  }
  dependsOn: [vaults[i]]
}]

module uais './modules/userAssignedIdentity.bicep' = [for (region, i) in regions: {
  name: 'userAssignedIdentityModule-${region}'
  scope: resourceGroup(rgNames[i])
  params: {
    identityName: uaiNames[i]
    location: region
  }
  dependsOn: [vaults[i]]
}]

// Assign RBAC role to UAI at subscription scope (one assignment per UAI)
module rbacSub './modules/roleAssignmentSubscription.bicep' = [for (region, i) in regions: {
  name: 'roleAssignmentSubModule-${region}'
  params: {
    principalId: uais[i].outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: remediationRoleDefinitionId
  }
  dependsOn: [uais[i]]
}]

// Export outputs as arrays for all regions
output vaultIds array = [for (region, i) in regions: vaults[i].outputs.vaultId]
output backupPolicyIds array = [for (region, i) in regions: policies[i].outputs.backupPolicyIds]
output backupPolicyNames array = [for (region, i) in regions: policies[i].outputs.backupPolicyNames]
output userAssignedIdentityIds array = [for (region, i) in regions: uais[i].outputs.identityResourceId]
output userAssignedIdentityPrincipalIds array = [for (region, i) in regions: uais[i].outputs.principalId]
