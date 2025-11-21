targetScope = 'subscription'

@description('Policy assignment name')
param policyAssignmentName string
@description('Azure location for the policy assignment (VM location)')
param assignmentLocation string
@description('Resource ID of the User Assigned Identity used for remediation')
param assignmentIdentityId string

@description('Custom backup policy definition ID (created from customCentralVmBackup.json)')
param customPolicyDefinitionId string

@description('VM tag name included in scope (e.g. backup)')
param vmTagName string = 'backup'
@description('VM tag value included in scope (e.g. true)')
param vmTagValue string = 'true'

@description('Recovery Services Vault name in this region')
param vaultName string
@description('Backup policy name in the vault')
param backupPolicyName string

// Vault resource group follows deployment convention 'rsv-rg-<region>' where assignmentLocation == region
var vaultRgName = 'rsv-rg-${assignmentLocation}'

// Construct the full resourceId of the backup policy (includes subscription and resource group)
// This module targets subscription scope, so use subscriptionResourceId to include the resource group correctly
// Build the fully qualified resourceId for the backup policy in the regional vault.
// Use resourceId(subscriptionId, resourceGroupName, resourceType, name...) so the resource group is included.
// Construct canonical resource Id: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.RecoveryServices/vaults/{vaultName}/backupPolicies/{policyName}
var backupPolicyIdResolved = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${vaultRgName}/providers/Microsoft.RecoveryServices/vaults/${vaultName}/backupPolicies/${backupPolicyName}'

resource policyAssign 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: policyAssignmentName
  location: assignmentLocation
  properties: {
    displayName: 'Enable VM backup (Custom Any OS) - ${assignmentLocation}'
    description: 'Assign custom policy to back up any tagged VMs to the regional vault using specified backup policy.'
    policyDefinitionId: customPolicyDefinitionId
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
