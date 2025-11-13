targetScope = 'subscription'

@description('Name of the policy assignment to create')
param assignmentName string
@description('Name of the policy definition (assumed to exist at subscription scope)')
param policyDefinitionName string
@description('Resource id of the user-assigned identity to use for the assignment (full resource id)')
param userAssignedIdentityId string
@description('Azure location for the policy assignment and remediation resources')
param policyDefinitionLocation string

// Resolve the policy definition id from the provided name
var policyDefinitionId = subscriptionResourceId('Microsoft.Authorization/policyDefinitions', policyDefinitionName)

resource assignment 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: assignmentName
  location: policyDefinitionLocation
  properties: {
    displayName: 'Enable VM backup for tagged VMs (assignment)'
    policyDefinitionId: policyDefinitionId
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
}

// Create a remediation that will apply the DeployIfNotExists remediation for existing non-compliant resources.
resource remediation 'Microsoft.PolicyInsights/remediations@2024-10-01' = {
  name: '${assignment.name}-remediation'
  properties: {
    policyAssignmentId: assignment.id
    // ExistingNonCompliant processes existing resources that are non-compliant and attempts remediation.
    resourceDiscoveryMode: 'ExistingNonCompliant'
  }
}

output policyAssignmentId string = assignment.id
output remediationId string = remediation.id
