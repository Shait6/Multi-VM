# Create or update resource group
param(
    [string]$ResourceGroupName,
    [string]$Location
)

$rg = Get-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Output "Creating resource group $ResourceGroupName in $Location"
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location
} else {
    Write-Output "Resource group $ResourceGroupName already exists"
}