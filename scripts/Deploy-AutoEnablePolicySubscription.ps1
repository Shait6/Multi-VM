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

    [Parameter(Mandatory=$false)]
    [string]$VaultName = '',

    [Parameter(Mandatory=$false)]
    [string]$VaultResourceGroup = '',

    [Parameter(Mandatory=$false)]
    [bool]$CreateVault = $false
)

try {
    Select-AzSubscription -SubscriptionId $SubscriptionId

    if ($CreateVault) {
        if ([string]::IsNullOrEmpty($VaultName) -or [string]::IsNullOrEmpty($VaultResourceGroup)) {
            Write-Error "When CreateVault is true, VaultName and VaultResourceGroup must be provided."
            exit 1
        }

        Write-Host "Ensuring resource group '$VaultResourceGroup' exists in subscription $SubscriptionId"
        $rg = Get-AzResourceGroup -Name $VaultResourceGroup -ErrorAction SilentlyContinue
        if (-not $rg) { New-AzResourceGroup -Name $VaultResourceGroup -Location $Location | Out-Null }

        Write-Host "Creating Recovery Services Vault '$VaultName' in resource group '$VaultResourceGroup'"
        $vaultTemplate = @"
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.RecoveryServices/vaults",
      "apiVersion": "2025-02-01",
      "name": "${VaultName}",
      "location": "${Location}",
      "properties": {
        "publicNetworkAccess": "Enabled"
      },
      "sku": {
        "name": "RS0",
        "tier": "Standard"
      }
    }
  ]
}
"@

        New-AzResourceGroupDeployment -ResourceGroupName $VaultResourceGroup -TemplateParameterObject @{ } -TemplateFile ([System.IO.Path]::GetTempFileName()) -TemplateParameterFile $null -TemplateObject (ConvertFrom-Json $vaultTemplate) -Mode Incremental | Out-Null
    }

    Write-Host "Deploying subscription-scoped DeployIfNotExists policy"
    $deploymentName = "autopolicy-deploy-$((Get-Date).ToString('yyyyMMddHHmmss'))"

    $params = @{
        policyName = 'deployifnotexists-enable-vm-backup'
        policyAssignmentName = "enable-vm-backup-assignment"
        vmTagName = $VmTagName
        vmTagValue = $VmTagValue
        vaultName = $VaultName
        vaultResourceGroup = $VaultResourceGroup
        backupPolicyName = $BackupPolicyName
    }

    New-AzSubscriptionDeployment -Name $deploymentName -Location $Location -TemplateFile "$(System.DefaultWorkingDirectory)/modules/backupAutoEnablePolicy.bicep" -TemplateParameterObject $params | Write-Output

    Write-Host "Subscription-scoped auto-enable policy deployment finished"
} catch {
    Write-Error "Failed to deploy auto-enable policy: $_"
    exit 1
}
