@description('Principal object id (GUID) to give the role to')
param principalId string
@description('Principal type for the role assignment. Useful to avoid replication ambiguity when principal was just created. Typical values: ServicePrincipal, User, Group')
param principalType string = 'ServicePrincipal'
@description('Role definition id or resource id of the role definition. If only a GUID is provided it will be converted to a subscription-scoped roleDefinition resource id.')
param roleDefinitionId string

// Normalize roleDefinitionId: if user passed a GUID, convert to subscriptionResourceId
var roleDefIdResolved = contains(roleDefinitionId, '/') ? roleDefinitionId : subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)

// produce a deterministic name for the role assignment
var roleAssignmentName = guid(resourceGroup().id, principalId, roleDefIdResolved)

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: roleAssignmentName
  scope: resourceGroup()
  properties: {
    roleDefinitionId: roleDefIdResolved
    principalId: principalId
    principalType: principalType
  }
}

output roleAssignmentId string = roleAssignment.id
