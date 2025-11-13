@description('Location for all resources')
param location string
param vaultName string
param backupPolicyName string
param backupScheduleRunTimes array = [
  // Use time-of-day strings (HH:mm) for policy schedule times. Avoid full ISO datetimes which the
  // Recovery Services policy API may reject. Example: '01:00'
  '01:00'
]
@description('Retention in days for daily backups')
param dailyRetentionDays int = 14
@description('Retention in days for weekly backups')
param weeklyRetentionDays int = 30
param weeklyBackupDaysOfWeek array = [
  'Sunday'
  'Wednesday'
]

@allowed([
  'Daily'
  'Weekly'
  'Both'
])
@description('Backup frequency - choose Daily, Weekly or Both')
param backupFrequency string = 'Daily'

@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
@description('Recovery Services Vault SKU name (e.g. RS0)')
param vaultSkuName string = 'RS0'
@description('Recovery Services Vault SKU tier (e.g. Standard)')
param vaultSkuTier string = 'Standard'
// Recommended replication: GRS — set the vault replication manually after creation if needed.

// Deploy Recovery Services Vault using a module
module vaultModule './modules/recoveryVault.bicep' = {
  name: 'recoveryVaultModule'
  params: {
    vaultName: vaultName
    location: location
    publicNetworkAccess: publicNetworkAccess
    skuName: vaultSkuName
    skuTier: vaultSkuTier
  }
}

// Deploy Backup Policy using a module; depends on vault
module policyModule './modules/backupPolicy.bicep' = {
  name: 'backupPolicyModule'
  params: {
    vaultName: vaultName
    backupPolicyName: backupPolicyName
    backupFrequency: backupFrequency
    backupScheduleRunTimes: backupScheduleRunTimes
    weeklyBackupDaysOfWeek: weeklyBackupDaysOfWeek
    dailyRetentionDays: dailyRetentionDays
    weeklyRetentionDays: weeklyRetentionDays
  }
  dependsOn: [vaultModule]
}

// Create a User Assigned Identity in the same resource group to be used by subscription-scoped policy assignment
module uaiModule './modules/userAssignedIdentity.bicep' = {
  name: 'userAssignedIdentityModule'
  params: {
    identityName: '${vaultName}-backup-remediator'
    location: location
  }
  dependsOn: [vaultModule]
}

// Export module outputs
output vaultId string = vaultModule.outputs.vaultId
output backupPolicyIds array = policyModule.outputs.backupPolicyIds
output backupPolicyNames array = policyModule.outputs.backupPolicyNames
output userAssignedIdentityId string = uaiModule.outputs.identityResourceId
output userAssignedIdentityPrincipalId string = uaiModule.outputs.principalId
