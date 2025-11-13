param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$Location,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultName,
    
    [Parameter(Mandatory=$true)]
    [string]$BackupPolicyName,
    
    [Parameter(Mandatory=$true)]
    [string]$BackupFrequency,
    
    [Parameter(Mandatory=$false)]
    [string]$VaultSkuName = 'RS0',

    [Parameter(Mandatory=$false)]
    [string]$VaultSkuTier = 'Standard'
)

# Deploy Bicep template with parameters
$deploymentName = "vmbackup-deployment-$($env:BUILD_BUILDID)"

New-AzResourceGroupDeployment `
    -Name $deploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile "../main.bicep" `
    -TemplateParameterFile "../main.parameters.json" `
    -location $Location `
    -vaultName $VaultName `
    -backupPolicyName $BackupPolicyName `
    -backupFrequency $BackupFrequency `
    -vaultSkuName $VaultSkuName `
    -vaultSkuTier $VaultSkuTier `
    