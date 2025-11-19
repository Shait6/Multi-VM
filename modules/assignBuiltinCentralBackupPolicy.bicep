targetScope = 'subscription'

@description('Policy assignment name')
param policyAssignmentName string
@description('Azure location for the policy assignment and VM evaluation (must match VM location)')
param assignmentLocation string
@description('Resource ID of the User Assigned Identity to execute the DeployIfNotExists remediation')
param assignmentIdentityId string

@description('VM tag name to include policy scope (e.g. "backup")')
param vmTagName string = 'backup'
@description('Included VM tag value (e.g. "true"). Built-in policy expects an array; we wrap this single value.')
param vmTagValue string = 'true'

@description('Recovery Services Vault name for this region')
param vaultName string
@description('Backup policy name to apply (must exist in the specified vault)')
param backupPolicyName string

var builtinPolicyId = '/providers/Microsoft.Authorization/policyDefinitions/345fa903-145c-4fe1-8bcd-93ec2adccde8'
var backupPolicyIdResolved = subscriptionResourceId('Microsoft.RecoveryServices/vaults/backupPolicies', vaultName, backupPolicyName)

resource policyAssign 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: policyAssignmentName
  location: assignmentLocation
  properties: {
    displayName: 'Enable VM backup (Built-in) - ${assignmentLocation}'
    description: 'Assign built-in policy to back up tagged VMs to the regional vault using the specified policy.'
    policyDefinitionId: builtinPolicyId
    parameters: {
      vaultLocation: { value: assignmentLocation }
      inclusionTagName: { value: vmTagName }
      inclusionTagValue: { value: [ vmTagValue ] }
      backupPolicyId: { value: backupPolicyIdResolved }
      effect: { value: 'DeployIfNotExists' }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${assignmentIdentityId}': {}
    }
  }
}

output policyAssignmentId string = policyAssign.id
