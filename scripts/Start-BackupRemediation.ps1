param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [string]$CustomPolicyDefinitionName = 'Custom-CentralVmBackup-AnyOS'
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) {
  try { $SubscriptionId = az account show --query id -o tsv } catch { throw 'SubscriptionId is required (env SUBSCRIPTION_ID not set and unable to infer current account).' }
} else {
  az account set --subscription $SubscriptionId
}

# Ensure custom policy definition exists (minimal behavior)
$policyRulesPath = Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.rules.json'
try {
  $existingDefId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv 2>$null
} catch { $existingDefId = $null }
if (-not $existingDefId) {
  if (Test-Path $policyRulesPath) {
    az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Assign central backup policy to tagged VMs." --rules $policyRulesPath --mode Indexed -o none
  } else {
    Write-Error "Policy rules file not found: $policyRulesPath. Please add the rules file to create the policy."
    exit 1
  }
}

$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }
Write-Host "Regions: $($targetRegions -join ', ') | Tag=${TagName}=${TagValue} | Freq=${BackupFrequency}"

# Load repository parameters file (expects explicit name arrays)
$repoParamsPath = Join-Path -Path (Get-Location) -ChildPath 'parameters\main.parameters.json'
if (-not (Test-Path $repoParamsPath)) { Write-Error "Parameters file not found: $repoParamsPath. Please provide explicit name arrays."; exit 1 }
$repoJson = Get-Content -Raw -Path $repoParamsPath | ConvertFrom-Json

foreach ($r in $targetRegions) {
  $idx = $targetRegions.IndexOf($r)
  # Read required arrays positionally
  try { $vaultName = $repoJson.parameters.vaultNames.value[$idx] } catch { Write-Warning "vaultNames array missing or index $idx out of range; skipping $r."; continue }
  try { $vaultRg = $repoJson.parameters.rgNames.value[$idx] } catch { Write-Warning "rgNames array missing or index $idx out of range; skipping $r."; continue }
  try { $bpPrefix = $repoJson.parameters.backupPolicyNames.value[$idx] } catch { Write-Warning "backupPolicyNames array missing or index $idx out of range; skipping $r."; continue }
  try { $uaiName = $repoJson.parameters.uaiNames.value[$idx] } catch { Write-Warning "uaiNames array missing or index $idx out of range; skipping $r."; continue }

  $policyName = if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { "$bpPrefix-weekly" } else { "$bpPrefix-daily" }
  $assignName = "enable-vm-backup-anyos-$r"

  $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"
  $uaiId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$uaiName"

  # Basic existence checks
  try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json } catch { $bp = $null }
  if (-not $bp) { Write-Warning "Backup policy not found at $backupPolicyId; skipping region $r."; continue }
  try { $u = az resource show --ids $uaiId -o json 2>$null | ConvertFrom-Json } catch { $u = $null }
  if (-not $u) { Write-Warning "User Assigned Identity not found at $uaiId; skipping region $r."; continue }

  Write-Host "Assigning policy $assignName (vault=$vaultName, policy=$policyName)"
  $customDefId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv
  if (-not $customDefId) { Write-Warning "Custom policy definition not found: $CustomPolicyDefinitionName; skipping region $r"; continue }

  az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$customDefId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName -o none

  $assignId = az policy assignment show -n $assignName --query id -o tsv 2>$null
  if (-not $assignId) { Write-Warning "Assignment not found after deployment for $r; skipping remediation"; continue }

  $remName = "remediate-vm-backup-anyos-$r"
  Write-Host "Triggering remediation $remName"
  az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none
}

Write-Host "Remediation triggers submitted. Monitor Policy -> Remediations in the Portal."

$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }
Write-Host "Regions: $($targetRegions -join ', ') | Tag=${TagName}=${TagValue} | Freq=${BackupFrequency}"

# Load repository parameters file (if present) so we can honor explicit name arrays
$repoJson = $null
$repoParamsPath = Join-Path -Path (Get-Location) -ChildPath 'parameters\main.parameters.json'
if (Test-Path $repoParamsPath) {
  try { $repoJson = Get-Content -Raw -Path $repoParamsPath | ConvertFrom-Json } catch { $repoJson = $null }
}

foreach ($r in $targetRegions) {
  # Simple deterministic behavior: require explicit name arrays in parameters/main.parameters.json
  $idx = $targetRegions.IndexOf($r)
  if (-not $repoJson -or -not $repoJson.parameters) {
    Write-Warning "Parameters file not found or unreadable; remediation requires explicit name arrays. Skipping region $r."
    continue
  }

  # Read positional names from parameters; if any are missing, skip the region with a clear message
  try { $vaultName = $repoJson.parameters.vaultNames.value[$idx] } catch { Write-Warning "vaultNames array missing or index $idx out of range; skipping $r."; continue }
  try { $vaultRg = $repoJson.parameters.rgNames.value[$idx] } catch { Write-Warning "rgNames array missing or index $idx out of range; skipping $r."; continue }
  try { $bpPrefix = $repoJson.parameters.backupPolicyNames.value[$idx] } catch { Write-Warning "backupPolicyNames array missing or index $idx out of range; skipping $r."; continue }
  try { $uaiName = $repoJson.parameters.uaiNames.value[$idx] } catch { Write-Warning "uaiNames array missing or index $idx out of range; skipping $r."; continue }

  if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { $policyName = "$bpPrefix-weekly" } else { $policyName = "$bpPrefix-daily" }
  $assignName = "enable-vm-backup-anyos-$r"

  # Build the canonical ids
  $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"
  $uaiId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$uaiName"

  # Verify the backup policy and UAI exist before attempting assignment
  $bpExists = $false
  try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json; if ($bp) { $bpExists = $true } } catch {}
  if (-not $bpExists) { Write-Warning "Backup policy not found at $backupPolicyId; skipping region $r."; continue }

  $uaiExists = $false
  try { $u = az resource show --ids $uaiId -o json 2>$null | ConvertFrom-Json; if ($u) { $uaiExists = $true } } catch {}
  if (-not $uaiExists) { Write-Warning "User Assigned Identity not found at $uaiId; skipping region $r."; continue }

  Write-Host "Assigning custom ANY-OS policy $assignName (vault=$vaultName, policy=$policyName)"
  $customDefId = ''
  try { $customDefId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv } catch { Write-Warning "Failed to resolve custom policy definition $($CustomPolicyDefinitionName): $($_.Exception.Message)" }
  if (-not $customDefId) { Write-Warning "Skipping region $r (custom policy definition not found)"; continue }

  try {
    az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$customDefId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName -o none
  } catch {
    Write-Warning "Assignment deployment failed for ${r}: $($_.Exception.Message)"
  }

  # Fetch the assignment id (if created) and log the resolved backupPolicyId from the deployment outputs for debugging

    # Pre-check: resolve vault resource and backup policy path before attempting assignment.
    $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"
    $bpExists = $false
    try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json; if ($bp) { $bpExists = $true } } catch {}
    if (-not $bpExists) {
      Write-Warning "Backup policy resource not found at computed id: $backupPolicyId"
      Write-Host "Attempting to locate Recovery Services vault in subscription matching region token '$r' or vault name '$vaultName'..." -ForegroundColor Yellow
      try {
        $vaults = az resource list --resource-type "Microsoft.RecoveryServices/vaults" -o json 2>$null | ConvertFrom-Json
        if ($vaults -and $vaults.Count -gt 0) {
          # prefer exact name match, then contains region token
          $vaultMatch = $vaults | Where-Object { $_.name -eq $vaultName } | Select-Object -First 1
          if (-not $vaultMatch) { $vaultMatch = $vaults | Where-Object { $_.name -match $r -or $_.name -match 'rsv' } | Select-Object -First 1 }
          if ($vaultMatch) {
            $vaultName = $vaultMatch.name
            $vaultRg = $vaultMatch.resourceGroup
            $backupPolicyId = "/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"
            try { $bp = az resource show --ids $backupPolicyId -o json 2>$null | ConvertFrom-Json; if ($bp) { $bpExists = $true } } catch {}
            Write-Host "Located vault: $vaultName in RG: $vaultRg" -ForegroundColor Green
          }
        }
      } catch {
        Write-Warning "Vault discovery search failed: $($_.Exception.Message)"
      }
    }

    if (-not $bpExists) {
      Write-Warning "Unable to resolve backup policy for region $r. Computed id: $backupPolicyId. Skipping assignment."
      continue
    }

    # Ensure the assignment identity (UAI) exists; if not, try to locate one in the same resource group or subscription.
    $uaiExists = $false
    try { $u = az resource show --ids $uaiId -o json 2>$null | ConvertFrom-Json; if ($u) { $uaiExists = $true } } catch {}
    if (-not $uaiExists) {
      Write-Host "Assignment identity not found at guessed id: $uaiId. Searching in resource group $vaultRg and subscription..." -ForegroundColor Yellow
      try {
        # Try search in vault RG for managed identity
        $rgList = az resource list --resource-group $vaultRg --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" -o json 2>$null | ConvertFrom-Json
        if ($rgList -and $rgList.Count -gt 0) { $match = $rgList | Select-Object -First 1; $uaiId = $match.id; $uaiExists = $true }
      } catch {}
      if (-not $uaiExists) {
        try {
          $subList = az resource list --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" -o json 2>$null | ConvertFrom-Json
          if ($subList -and $subList.Count -gt 0) {
            # prefer name containing region token or 'rsv'
            $match = $subList | Where-Object { $_.name -match $r -or $_.name -match 'rsv' } | Select-Object -First 1
            if (-not $match) { $match = $subList | Select-Object -First 1 }
            if ($match) { $uaiId = $match.id; $uaiExists = $true }
          }
        } catch {}
      }
    }

    if (-not $uaiExists) {
      Write-Warning "Unable to resolve User Assigned Identity for region $r. Tried: guessed id and subscription search. Skipping assignment."
      continue
    }

    # Proceed to create the assignment now that both backup policy and identity are resolvable
    try {
      az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$customDefId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName -o none
    } catch {
      Write-Warning "Assignment deployment failed for ${r}: $($_.Exception.Message)"
    }
  try {
    $assignId = az policy assignment show -n $assignName --query id -o tsv
  } catch {}
  if ($assignId) {
    Write-Host "Assignment created: $assignId"
  } else {
    Write-Warning "Assignment not found after deployment for $r. Attempting to inspect deployment outputs..."
    try {
      # Show last subscription deployment outputs that match our assign name prefix
      $deployments = az deployment sub list --query "[?starts_with(name, 'assign-policy-$r')]|[0]" -o json | ConvertFrom-Json
        if ($deployments -and $deployments.properties -and $deployments.properties.outputs) {
        $outs = $deployments.properties.outputs
        $outsJson = ConvertTo-Json $outs -Depth 5
        Write-Host "Deployment outputs for assign-policy-${r}:"
        Write-Host $outsJson
      }
    } catch {
      Write-Warning "Unable to retrieve deployment outputs: $($_.Exception.Message)"
    }
  }

  $assignId = ''
  try { $assignId = az policy assignment show -n $assignName --query id -o tsv } catch {}
  if (-not $assignId) { Write-Warning "Assignment not found in $r; skipping remediation"; continue }

  $remName = "remediate-vm-backup-anyos-$r"
  Write-Host "Triggering remediation $remName"
  az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none
}

Write-Host "Remediation triggers submitted. You can monitor jobs in Policy -> Remediations."

# Cleanup transient files created during policy/inspection when NoArtifacts was requested
if ($transientFiles -and $transientFiles.Count -gt 0) {
  foreach ($f in $transientFiles) {
    try { if (Test-Path $f) { Remove-Item -Force -Path $f -ErrorAction SilentlyContinue } } catch {}
  }
  if ($writeArtifacts) { Write-Host "Transient artifact files cleaned: $($transientFiles -join ', ')" } else { Write-Host "Transient artifact files cleaned (no persisted artifacts due to -NoArtifacts)" }
}
