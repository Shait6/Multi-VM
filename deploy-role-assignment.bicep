@description('Principal object id (GUID) to give the role to')
param principalId string

@description('Role definition id or resource id of the role definition. If only a GUID is provided it will be converted to a subscription-scoped roleDefinition resource id.')
param roleDefinitionId string

@description('Principal type for the role assignment. Typical values: ServicePrincipal, User, Group')
param principalType string = 'ServicePrincipal'

module roleAssign './modules/roleAssignment.bicep' = {
  name: 'roleAssignmentModule'
  params: {
    principalId: principalId
    roleDefinitionId: roleDefinitionId
    principalType: principalType
  }
}

output roleAssignmentId string = roleAssign.outputs.roleAssignmentId
