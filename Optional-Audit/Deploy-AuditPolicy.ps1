param(
    [Parameter(Mandatory=$true)]
    [string]$ManagementGroupId,

    [Parameter(Mandatory=$false)]
    [string]$PolicyName = "audit-vm-backup-policy",

    [Parameter(Mandatory=$false)]
    [string]$PolicyAssignmentName = "audit-vm-backup-assignment",

    [Parameter(Mandatory=$false)]
    [string]$VmTagName = 'backup',

    [Parameter(Mandatory=$false)]
    [string]$VmTagValue = 'true'
)

try {
    Write-Host "Targeting management group: $ManagementGroupId"

    $deploymentName = "auditpolicy-deploy-$((Get-Date).ToString('yyyyMMddHHmmss'))"

    Write-Host "Starting management-group-scoped deployment: $deploymentName"

    New-AzManagementGroupDeployment -ManagementGroupId $ManagementGroupId -Name $deploymentName -TemplateFile "$(System.DefaultWorkingDirectory)/modules/backupAuditPolicy.bicep" -TemplateParameterObject @{
        policyName = $PolicyName
        policyAssignmentName = $PolicyAssignmentName
        vmTagName = $VmTagName
        vmTagValue = $VmTagValue
    } | Write-Output

    Write-Host "Audit policy deployment finished"
} catch {
    Write-Error "Failed to deploy audit policy: $_"
    exit 1
}

