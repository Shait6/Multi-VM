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
@description('Enable Backup soft-delete (protects recovery points)')
param enableSoftDelete bool = false
@description('Backup storage redundancy for the vault (LocallyRedundant | GeoRedundant | ZoneRedundant). GeoRedundant recommended for production')
@allowed([
  'LocallyRedundant'
  'GeoRedundant'
  'ZoneRedundant'
])
param backupStorageRedundancy string = 'GeoRedundant'
 

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: vaultName
  location: location
  sku: {
    name: skuName
    tier: skuTier
    
  }
  properties: union({
    publicNetworkAccess: publicNetworkAccess
    restoreSettings: {
      crossSubscriptionRestoreSettings: {
        crossSubscriptionRestoreState: 'Enabled'
      }
    }
  }, enableSoftDelete ? { softDeleteFeatureState: 'Enabled' } : {}, 
  // Use the provider-supported property for Recovery Services Vault backup storage replication.
  // 'storageModelType' is the property used by the Recovery Services Vault resource to indicate
  // redundancy type (for example: 'GeoRedundant' or 'LocallyRedundant').
  { storageModelType: backupStorageRedundancy })
}

output vaultId string = recoveryServicesVault.id
output vaultName string = recoveryServicesVault.name
output softDeleteEnabled bool = enableSoftDelete
output backupStorageRedundancy string = backupStorageRedundancy
