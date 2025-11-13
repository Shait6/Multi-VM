param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$true)]
    [string]$Location,

    [Parameter(Mandatory=$true)]
    [string]$VmTagName,

    [Parameter(Mandatory=$true)]
    [string]$VmTagValue,

    [Parameter(Mandatory=$true)]
    [string]$BackupPolicyName,

  [Parameter(Mandatory=$true)]
    [string]$VaultName = '',

  [Parameter(Mandatory=$true)]
    [string]$VaultResourceGroup = '',

    [Parameter(Mandatory=$false)]
    [string]$AssignmentIdentityResourceId
)

try {
    Select-AzSubscription -SubscriptionId $SubscriptionId

    # Validate prerequisites: vault resource group and vault must already exist
    $rg = Get-AzResourceGroup -Name $VaultResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        throw "Vault resource group '$VaultResourceGroup' not found in subscription $SubscriptionId. Deploy the vault via main.bicep first."
    }
    $vault = Get-AzResource -ResourceGroupName $VaultResourceGroup -ResourceType "Microsoft.RecoveryServices/vaults" -Name $VaultName -ErrorAction SilentlyContinue
    if (-not $vault) {
        throw "Recovery Services Vault '$VaultName' not found in resource group '$VaultResourceGroup'. Deploy the vault via main.bicep first."
    }

    Write-Host "Deploying subscription-scoped DeployIfNotExists policy"
    $deploymentName = "autopolicy-deploy-$((Get-Date).ToString('yyyyMMddHHmmss'))"

    if ([string]::IsNullOrWhiteSpace($AssignmentIdentityResourceId)) {
      # Derive identity by convention: /subscriptions/<sub>/resourceGroups/rsv-rg-<region>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-<region>
      $AssignmentIdentityResourceId = "/subscriptions/$SubscriptionId/resourceGroups/rsv-rg-$Location/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-$Location"
      Write-Host "Using derived assignment identity: $AssignmentIdentityResourceId"
    }

    $params = @{
        policyName = 'deployifnotexists-enable-vm-backup'
        policyAssignmentName = "enable-vm-backup-assignment"
      assignmentLocation = $Location
      assignmentIdentityId = $AssignmentIdentityResourceId
        vmTagName = $VmTagName
        vmTagValue = $VmTagValue
        vaultName = $VaultName
        vaultResourceGroup = $VaultResourceGroup
        backupPolicyName = $BackupPolicyName
    }

      $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/backupAutoEnablePolicy.bicep'
      New-AzSubscriptionDeployment -Name $deploymentName -Location $Location -TemplateFile $modulePath -TemplateParameterObject $params | Write-Output

      Write-Host "Starting remediation for existing non-compliant VMs"
      $assignment = Get-AzPolicyAssignment -Name 'enable-vm-backup-assignment' -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue
      if ($null -ne $assignment) {
        $remediationName = "remediate-vm-backup-$Location"
        Start-AzPolicyRemediation -Name $remediationName -PolicyAssignmentId $assignment.Id -ResourceDiscoveryMode ExistingNonCompliant | Write-Output
        Write-Host "Remediation started: $remediationName"
      } else {
        Write-Warning "Policy assignment not found; remediation not started. Verify deployment success."
      }

    Write-Host "Subscription-scoped auto-enable policy deployment finished"
} catch {
    Write-Error "Failed to deploy auto-enable policy: $_"
    exit 1
}
