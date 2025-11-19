targetScope = 'subscription'

// Fixed: removed unused name parameter; definition name is set directly in resource.

// Custom policy cloned from built-in 345fa903-145c-4fe1-8bcd-93ec2adccde8 but with OS/image filters removed to include any VM matching tag + location.
// This ensures newer images like Ubuntu 24.04 are not excluded.

resource customDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'Custom-CentralVmBackup-NoImageFilter'
  properties: {
    displayName: 'Configure backup on tagged VMs to a central vault (no image filter)'
    description: 'Deploy backup protection for any Azure VM with specified tag in the same location as the Recovery Services vault using the provided backup policy. Removes built-in image allow list so all OS versions (including newer Ubuntu releases) are included.'
    mode: 'Indexed'
    metadata: {
      category: 'Backup'
      source: 'custom'
      version: '1.0.0'
      originalBuiltIn: '/providers/Microsoft.Authorization/policyDefinitions/345fa903-145c-4fe1-8bcd-93ec2adccde8'
    }
    parameters: {
      vaultLocation: {
        type: 'String'
        metadata: {
          displayName: 'Location of VMs to protect'
          description: 'VM location. Must match vault region for backup.'
        }
      }
      inclusionTagName: {
        type: 'String'
        metadata: {
          displayName: 'Inclusion Tag Name'
          description: 'Tag name used to include VMs in backup scope.'
        }
        defaultValue: ''
      }
      inclusionTagValue: {
        type: 'Array'
        metadata: {
          displayName: 'Inclusion Tag Values'
          description: 'Tag value(s) used to include VMs in backup scope.'
        }
      }
      backupPolicyId: {
        type: 'String'
        metadata: {
          displayName: 'Backup Policy ID'
          description: 'Resource ID of Azure VM backup policy in the target vault.'
        }
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Deploy or audit the policy.'
        }
        allowedValues: [ 'DeployIfNotExists', 'AuditIfNotExists', 'Disabled' ]
        defaultValue: 'DeployIfNotExists'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            field: 'location'
            equals: '[parameters(''vaultLocation'')]'
          }
          {
            field: '[concat(''tags['', parameters(''inclusionTagName''), '']'')]'
            in: '[parameters(''inclusionTagValue'')]'
          }
        ]
      }
      then: {
        effect: '[parameters(''effect'')]'
        details: {
          roleDefinitionIds: [
            '/providers/microsoft.authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
            '/providers/microsoft.authorization/roleDefinitions/5e467623-bb1f-42f4-a55d-6e525e11384b'
          ]
          type: 'Microsoft.RecoveryServices/backupprotecteditems'
          deployment: {
            properties: {
              mode: 'incremental'
              template: {
                '$schema': 'http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#'
                contentVersion: '1.0.0.0'
                parameters: {
                  backupPolicyId: { type: 'String' }
                  fabricName: { type: 'String' }
                  protectionContainers: { type: 'String' }
                  protectedItems: { type: 'String' }
                  sourceResourceId: { type: 'String' }
                }
                resources: [
                  {
                    apiVersion: '2017-05-10'
                    name: '[concat(''DeployProtection-'', uniqueString(parameters(''protectedItems'')))]'
                    type: 'Microsoft.Resources/deployments'
                    resourceGroup: '[first(skip(split(parameters(''backupPolicyId''), ''/''), 4))]'
                    subscriptionId: '[first(skip(split(parameters(''backupPolicyId''), ''/''), 2))]'
                    properties: {
                      mode: 'Incremental'
                      template: {
                        '$schema': 'https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#'
                        contentVersion: '1.0.0.0'
                        parameters: {
                          backupPolicyId: { type: 'String' }
                          fabricName: { type: 'String' }
                          protectionContainers: { type: 'String' }
                          protectedItems: { type: 'String' }
                          sourceResourceId: { type: 'String' }
                        }
                        resources: [
                          {
                            type: 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'
                            name: '[concat(first(skip(split(parameters(''backupPolicyId''), ''/''), 8)), ''/'', parameters(''fabricName''), ''/'', parameters(''protectionContainers''), ''/'', parameters(''protectedItems''))]'
                            apiVersion: '2016-06-01'
                            properties: {
                              protectedItemType: 'Microsoft.Compute/virtualMachines'
                              policyId: '[parameters(''backupPolicyId'')]'
                              sourceResourceId: '[parameters(''sourceResourceId'')]'
                            }
                          }
                        ]
                      }
                      parameters: {
                        backupPolicyId: { value: '[parameters(''backupPolicyId'')]' }
                        fabricName: { value: 'Azure' }
                        protectionContainers: { value: '[concat(''iaasvmcontainer;iaasvmcontainerv2;'', resourceGroup().name, '';'', field(''name''))]' }
                        protectedItems: { value: '[concat(''vm;iaasvmcontainerv2;'', resourceGroup().name, '';'', field(''name''))]' }
                        sourceResourceId: { value: '[concat(''/subscriptions/'', subscription().subscriptionId, ''/resourceGroups/'', resourceGroup().name, ''/providers/Microsoft.Compute/virtualMachines/'', field(''name''))]' }
                      }
                    }
                  }
                ]
              }
              parameters: {
                backupPolicyId: { value: '[parameters(''backupPolicyId'')]' }
                fabricName: { value: 'Azure' }
                protectionContainers: { value: '[concat(''iaasvmcontainer;iaasvmcontainerv2;'', resourceGroup().name, '';'', field(''name''))]' }
                protectedItems: { value: '[concat(''vm;iaasvmcontainerv2;'', resourceGroup().name, '';'', field(''name''))]' }
                sourceResourceId: { value: '[concat(''/subscriptions/'', subscription().subscriptionId, ''/resourceGroups/'', resourceGroup().name, ''/providers/Microsoft.Compute/virtualMachines/'', field(''name''))]' }
              }
            }
          }
        }
      }
    }
  }
}

output customPolicyDefinitionId string = customDef.id
