param(
    [Parameter(Mandatory=$true)]
    [string]$VaultName,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$VMName,
    
    [Parameter(Mandatory=$true)]
    [string]$VMResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$BackupPolicyName
)

# Get the Recovery Services Vault
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $VaultResourceGroup
if (-not $vault) {
    Write-Error "Recovery Services Vault '$VaultName' not found in resource group '$VaultResourceGroup'"
    exit 1
}

# Get the Backup Policy
$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $BackupPolicyName -VaultId $vault.ID
if (-not $policy) {
    Write-Error "Backup Policy '$BackupPolicyName' not found in vault '$VaultName'"
    exit 1
}

# Check if VM exists
$vm = Get-AzVM -Name $VMName -ResourceGroupName $VMResourceGroup
if (-not $vm) {
    Write-Error "VM '$VMName' not found in resource group '$VMResourceGroup'"
    exit 1
}

try {
    # Enable backup for the VM
    Write-Host "Enabling backup for VM '$VMName'..."
    Enable-AzRecoveryServicesBackupProtection `
        -Policy $policy `
        -Name $VMName `
        -ResourceGroupName $VMResourceGroup `
        -VaultId $vault.ID

    Write-Host "Successfully enabled backup for VM '$VMName'"
} catch {
    Write-Error "Failed to enable backup for VM '$VMName': $_"
    exit 1
}