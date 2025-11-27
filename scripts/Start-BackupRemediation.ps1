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

# Ensure custom policy definition exists (idempotent). If missing, create from JSON file.
$policyDefJsonPath = Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.json'
$policyFullJsonPath = Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.full.json'
try {
  $existingDef = az policy definition show -n $CustomPolicyDefinitionName -o json 2>$null | ConvertFrom-Json
} catch { $existingDef = $null }
  if (-not $existingDef) {
    # Prefer exact full-definition file if present. Use az rest PUT to send the JSON verbatim
    if (Test-Path $policyFullJsonPath) {
      Write-Host "Creating custom policy definition '$CustomPolicyDefinitionName' from full JSON $policyFullJsonPath via REST PUT (preserves policy expressions)" -ForegroundColor Cyan
      try {
        # Use @file syntax to send the JSON file verbatim and avoid PowerShell/CLI escaping issues
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyDefinitions/$CustomPolicyDefinitionName?api-version=2021-06-01"
        try {
          $rawJson = Get-Content -Raw -Path $policyFullJsonPath
          $resp = az rest --method put --uri $uri --body "$rawJson" -o none 2>&1
          if ($LASTEXITCODE -ne 0) { throw "az rest failed: $resp" }
        } catch {
          Write-Warning "az rest PUT failed: $($_.Exception.Message)"
        }

        # verify stored policyRule and inspect nested deployment template for 'field(' occurrences
        Write-Host "Fetching stored policyDefinition to verify policy expressions are preserved..." -ForegroundColor Cyan
        $stored = az policy definition show -n $CustomPolicyDefinitionName -o json | ConvertFrom-Json
        if ($stored -and $stored.properties -and $stored.properties.policyRule) {
          $pv = (ConvertTo-Json $stored.properties.policyRule -Depth 99)
          $tmpOut = [System.IO.Path]::GetTempFileName() + '.json'
          $pv | Out-File -FilePath $tmpOut -Encoding utf8
          Write-Host "Stored policyRule written to: $tmpOut"

          # Try to extract nested deployment.template inside then.details.deployment.properties.template
          $nested = $null
          try {
            $nested = $stored.properties.policyRule.then.details.deployment.properties.template
          } catch {
            $nested = $null
          }
          if ($nested) {
            $nestedJson = (ConvertTo-Json $nested -Depth 99)
            $nestedOut = [System.IO.Path]::GetTempFileName() + '.json'
            $nestedJson | Out-File -FilePath $nestedOut -Encoding utf8
            Write-Host "Nested deployment template written to: $nestedOut"
            if ($nestedJson -match "field\('\w+\'\)") {
              Write-Host "Detected policy 'field()' expressions inside nested template (expected)." -ForegroundColor Green
            } elseif ($nestedJson -match "field\(") {
              Write-Host "Detected 'field(' in nested template (pattern match)." -ForegroundColor Yellow
            } else {
              Write-Warning "No 'field(' expressions detected in nested template — this may indicate the policy engine won't be able to evaluate resource-specific values."
            }
          } else {
            Write-Warning "Unable to find nested deployment.template inside stored policyRule for inspection."
          }
        } else {
          Write-Warning "Policy definition created but unable to read back properties.policyRule."
        }
      } catch {
        Write-Warning "Failed to create policy definition via REST PUT: $($_.Exception.Message)"
      }
    } elseif (-not (Test-Path $policyDefJsonPath)) {
      Write-Warning "Custom policy definition JSON not found at $policyDefJsonPath and full JSON not present at $policyFullJsonPath"
    } else {
      Write-Host "Creating custom policy definition '$CustomPolicyDefinitionName' from $policyDefJsonPath (legacy/fallback path)" -ForegroundColor Cyan
      # Read JSON and extract policyRule and parameters if file contains 'properties' wrapper
      try {
        $raw = Get-Content -Raw -Path $policyDefJsonPath | ConvertFrom-Json
      } catch {
        Write-Warning "Failed to parse JSON file $($policyDefJsonPath): $($_.Exception.Message)"
        $raw = $null
      }
      if (Test-Path (Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.rules.json')) {
        # Prefer using rules-only file to avoid JSON re-serialization changing policy expressions
        $rulesFile = Join-Path -Path (Get-Location) -ChildPath 'policy-definitions/customCentralVmBackup.rules.json'
        $paramsFile = $null
        if ($raw -and $raw.properties -and $raw.properties.parameters) {
          $tmpParams = [System.IO.Path]::GetTempFileName() + '.json'
          $raw.properties.parameters | ConvertTo-Json -Depth 99 | Out-File -FilePath $tmpParams -Encoding utf8
          $paramsFile = $tmpParams
        }
        try {
          if ($paramsFile) {
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $rulesFile --params $paramsFile --mode Indexed -o none
          } else {
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $rulesFile --mode Indexed -o none
          }
        } catch {
          Write-Warning "Failed to create policy definition from $($rulesFile): $($_.Exception.Message)"
        } finally {
          if ($paramsFile -and (Test-Path $paramsFile)) { Remove-Item $paramsFile -Force }
        }
      } else {
        # Fallback: if no rules file present, attempt direct create from full JSON by extracting objects
        if ($raw -and $raw.properties) {
          $rulesObj = $raw.properties.policyRule
          $paramsObj = $raw.properties.parameters
          $tmpRules = [System.IO.Path]::GetTempFileName() + '.json'
          $tmpParams = [System.IO.Path]::GetTempFileName() + '.json'
          $rulesObj | ConvertTo-Json -Depth 99 | Out-File -FilePath $tmpRules -Encoding utf8
          if ($paramsObj) { $paramsObj | ConvertTo-Json -Depth 99 | Out-File -FilePath $tmpParams -Encoding utf8 }
          try {
            if (Test-Path $tmpParams) {
              az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --params $tmpParams --mode Indexed -o none
            } else {
              az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup (Any OS)" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --mode Indexed -o none
            }
          } catch {
            Write-Warning "Failed to create policy definition: $($_.Exception.Message)"
          } finally {
            if (Test-Path $tmpRules) { Remove-Item $tmpRules -Force }
            if (Test-Path $tmpParams) { Remove-Item $tmpParams -Force }
          }
        } else {
          Write-Warning "Policy definition JSON $($policyDefJsonPath) did not contain expected 'properties' object."
        }
      }
    }
  }

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
