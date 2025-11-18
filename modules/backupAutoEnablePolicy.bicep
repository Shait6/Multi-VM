targetScope = 'subscription'

@description('Name for the custom DeployIfNotExists policy definition')
param policyName string = 'deployifnotexists-enable-vm-backup'
@description('Name for the policy assignment')
param policyAssignmentName string = 'enable-vm-backup-assignment'
@description('Azure location for the policy assignment (required when using identity at subscription scope)')
param assignmentLocation string = 'westeurope'
@description('Resource ID of the User Assigned Identity to execute the DeployIfNotExists remediation')
param assignmentIdentityId string

@description('VM tag name to filter which VMs the policy applies to (e.g. "backup")')
param vmTagName string = 'backup'
@description('VM tag value to match (e.g. "true")')
param vmTagValue string = 'true'

@description('Recovery Services Vault name to use when enabling backup')
param vaultName string
@description('Resource group of the Recovery Services Vault')
param vaultResourceGroup string
@description('Backup policy name to apply when enabling backup')
param backupPolicyName string

// Role required to perform remediation (Contributor covers backup operations)
var roleDefinitionIds = [subscriptionResourceId('Microsoft.Authorization/roleDefinitions','b24988ac-6180-42a0-ab88-20f7382dd24c')]

// Load the policy rule from an external JSON file and substitute placeholders.
var rawPolicyRule = loadTextContent('./autoEnablePolicy.rule.json')

// Compute the full policy ID for the selected vault/policy
var backupPolicyIdResolved = subscriptionResourceId('Microsoft.RecoveryServices/vaults/backupPolicies', vaultName, backupPolicyName)

var policyRule = json(
  replace(
    replace(
      replace(
        replace(
          replace(
            replace(
              replace(
                replace(rawPolicyRule, '__TAGNAME__', vmTagName),
                '__BACKUP_POLICY_ID__', backupPolicyIdResolved
              ),
              '__TAGVALUE__', vmTagValue
            ),
            '__ROLEDEFID__', roleDefinitionIds[0]
          ),
          '__VAULT_NAME__', vaultName
        ),
        '__VAULT_RG__', vaultResourceGroup
      ),
      '__BACKUP_POLICY__', backupPolicyName
    ),
    '__REGION__', assignmentLocation
  )
)

resource policyDef 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: policyName
  properties: {
    displayName: 'DeployIfNotExists: enable VM backup for tagged VMs'
    policyType: 'Custom'
    mode: 'Indexed'
    description: 'If a virtual machine with the specified tag does not have a Recovery Services protected item, deploy an ARM template to enable backup using the specified vault and policy.'
    metadata: {
      category: 'Backup'
      version: '1.0'
      createdBy: 'VM_Backup_Solution'
    }
    policyRule: policyRule
    details: {
    evaluationDelay: 'AfterProvisioning'
  }
}

resource policyAssign 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: policyAssignmentName
  location: assignmentLocation
  properties: {
    displayName: 'Enable VM backup for tagged VMs - ${assignmentLocation}'
    description: 'Assign DeployIfNotExists policy to enable VM backup for VMs with the tag.'
    policyDefinitionId: policyDef.id
    parameters: {}
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${assignmentIdentityId}': {}
    }
  }
}

output policyDefinitionId string = policyDef.id
output policyAssignmentId string = policyAssign.id
