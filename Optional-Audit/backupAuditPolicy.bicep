targetScope = 'managementGroup'

@description('Name for the custom policy definition')
param policyName string = 'audit-vm-backup-policy'
@description('Name for the policy assignment')
param policyAssignmentName string = 'audit-vm-backup-assignment'
// This module must be deployed at the target management group scope. The policy assignment will be created in the management group where the deployment runs.

@description('VM tag name to filter which VMs the policy applies to (e.g. "backup")')
param vmTagName string = 'backup'
@description('VM tag value to match (e.g. "enabled")')
param vmTagValue string = 'true'

var policyRuleJson = '{"if":{"allOf":[{"field":"type","equals":"Microsoft.Compute/virtualMachines"},{"field":"tags[\'${vmTagName}\']","equals":"${vmTagValue}"},{"not":{"exists":{"field":"Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems/name"}}}]},"then":{"effect":"audit"}}'

var policyRule = json(policyRuleJson)

resource policyDef 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: policyName
  properties: {
    displayName: 'Audit virtual machines without Azure Backup protection'
    policyType: 'Custom'
    mode: 'Indexed'
    description: 'Audits virtual machines that have a specific tag but do not have an associated Recovery Services protected item (backup).'
    metadata: {
      category: 'Backup'
      version: '1.0'
      createdBy: 'VM_Backup_Solution'
    }
    policyRule: policyRule
  }
}

resource policyAssign 'Microsoft.Authorization/policyAssignments@2021-06-01' = {
  name: policyAssignmentName
  properties: {
    displayName: 'Audit VMs without Azure Backup'
    description: 'Assignment of the custom policy that audits virtual machines that are not protected by Azure Backup.'
    policyDefinitionId: policyDef.id
  }
}

output policyDefinitionId string = policyDef.id
output policyAssignmentId string = policyAssign.id
