@description('Name of the user assigned identity to create')
param identityName string
@description('Location for the identity')
param location string

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: identityName
  location: location
}

output identityResourceId string = uai.id
output principalId string = uai.properties.principalId
