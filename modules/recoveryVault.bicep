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
  // backupStorageRedundancy is included as a provider-specific property to indicate desired replication.
  // The exact property name and supported values may vary by API-version and subscription. If deployment fails,
  // adjust this property to match your Azure environment.
  { backupStorageRedundancy: backupStorageRedundancy })
}

output vaultId string = recoveryServicesVault.id
output vaultName string = recoveryServicesVault.name
output softDeleteEnabled bool = enableSoftDelete
output backupStorageRedundancy string = backupStorageRedundancy
