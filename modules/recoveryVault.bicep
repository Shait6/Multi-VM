@description('Name of the Recovery Services Vault')
param vaultName string
@description('Location for the vault')
param location string
@description('SKU name for the Recovery Services Vault (e.g. RS0)')
param skuName string = 'RS0'
@description('SKU tier for the Recovery Services Vault (e.g. Standard)')
param skuTier string = 'Standard'
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
 

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2025-02-01' = {
  name: vaultName
  location: location
  sku: {
    name: skuName
    tier: skuTier
    
  }
  properties: {
    publicNetworkAccess: publicNetworkAccess
    restoreSettings: {
      crossSubscriptionRestoreSettings: {
        crossSubscriptionRestoreState: 'Enabled'
      }
    }
  }
}
// This module does not configure backup storage replication. Recommended replication for production is GRS.

output vaultId string = recoveryServicesVault.id
output vaultName string = recoveryServicesVault.name
