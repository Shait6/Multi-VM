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
@description('Daily retention in days')
param dailyRetentionDays int = 14
@description('Weekly retention in days')
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
@allowed([ 'Enabled', 'Disabled' ])
@description('Public network access setting for vaults')
param publicNetworkAccess string = 'Enabled'
@description('Recovery Services Vault SKU name')
param vaultSkuName string = 'RS0'
@description('Recovery Services Vault SKU tier')
param vaultSkuTier string = 'Standard'

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

// Assign RBAC role to UAI on each RG (e.g., Backup Operator role)
var backupOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830' // Built-in Backup Operator role
module rbac './modules/roleAssignment.bicep' = [for (region, i) in regions: {
  name: 'roleAssignmentModule-${region}'
  scope: resourceGroup(rgNames[i])
  params: {
    principalId: uais[i].outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: backupOperatorRoleId
  }
  dependsOn: [uais[i]]
}]

// Export outputs as arrays for all regions
output vaultIds array = [for (region, i) in regions: vaults[i].outputs.vaultId]
output backupPolicyIds array = [for (region, i) in regions: policies[i].outputs.backupPolicyIds]
output backupPolicyNames array = [for (region, i) in regions: policies[i].outputs.backupPolicyNames]
output userAssignedIdentityIds array = [for (region, i) in regions: uais[i].outputs.identityResourceId]
output userAssignedIdentityPrincipalIds array = [for (region, i) in regions: uais[i].outputs.principalId]
