param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION,
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [string]$CustomPolicyDefinitionName = 'Custom-CentralVmBackup',
  [bool]$AutoCreateUai = $true
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
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup" --description "Any tagged VM in region backed up to vault using specified policy." --rules $rulesFile --params $paramsFile --mode Indexed -o none
          } else {
            az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup" --description "Any tagged VM in region backed up to vault using specified policy." --rules $rulesFile --mode Indexed -o none
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
              az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --params $tmpParams --mode Indexed -o none
            } else {
              az policy definition create --name $CustomPolicyDefinitionName --display-name "Central VM Backup" --description "Any tagged VM in region backed up to vault using specified policy." --rules $tmpRules --mode Indexed -o none
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

$targetRegions = if ([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { @($Regions.Split(',') | ForEach-Object { $_.Trim() }) }
Write-Host "Regions: $($targetRegions -join ', ') | Tag=${TagName}=${TagValue} | Freq=${BackupFrequency}"

# Ensure a single shared UAI exists in the first selected region and use it for all assignments.
Write-Host "Ensuring single shared UAI exists and is usable..."
$sharedUaiId = $null
$firstRegion = if ($targetRegions -and $targetRegions.Count -gt 0) { $targetRegions[0] } else { $DeploymentLocation }

# Coerce to string and normalize before using in resource names
$firstRegion = [string]$firstRegion
$firstRegion = $firstRegion.Trim().ToLower()
$vaultRg = "rsv-rg-$firstRegion"
$uaiName = "uai-$firstRegion"
  if ($firstRegion.Length -lt 3) {
    Write-Error "Selected region value '$firstRegion' looks invalid or truncated. Provide a full Azure region name (e.g. 'westeurope' or 'northeurope'). Exiting."; exit 1
  }
  # Validate against available Azure locations to catch typos
  try {
    $locCheck = az account list-locations --query "[?name=='$firstRegion'] | [0].name" -o tsv 2>$null
    if (-not $locCheck) {
      Write-Error "Azure region '$firstRegion' is not available for this subscription or is misspelled. Confirm available regions with 'az account list-locations -o table'. Exiting."; exit 1
    }
  } catch {
    Write-Warning "Unable to validate Azure location via CLI (az). Proceeding optimistically but you may encounter region errors: $($_.Exception.Message)"
  }

try {
  # Ensure resource group exists
  $rg = $null
  try { $rg = az group show -n $vaultRg -o json 2>$null | ConvertFrom-Json } catch { $rg = $null }
  if (-not $rg) {
    Write-Host "Creating resource group $vaultRg in $firstRegion..."
    az group create -n $vaultRg -l $firstRegion -o none
  }

  # Ensure identity exists (create if missing)
  $ident = $null
  try { $ident = az identity show -g $vaultRg -n $uaiName -o json 2>$null | ConvertFrom-Json } catch { $ident = $null }
  if (-not $ident) {
    Write-Host "Creating user-assigned identity '$uaiName' in resource group '$vaultRg'..."
    $createdJson = az identity create -g $vaultRg -n $uaiName -o json
    $ident = $createdJson | ConvertFrom-Json
  }
  if ($ident -and $ident.id) { $sharedUaiId = $ident.id }

  # Ensure remediation role assignment exists at subscription scope for the identity principal
  if ($ident -and $ident.principalId) {
    $roleGuid = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    try {
      # attempt idempotent creation; ignore conflict
      az role assignment create --assignee-object-id $ident.principalId --role $roleGuid --scope "/subscriptions/$SubscriptionId" -o none 2>$null
    } catch {
      Write-Warning "Role assignment create returned: $($_.Exception.Message)" 
    }
  }

  if (-not $sharedUaiId) { throw 'Failed to determine or create shared UAI id' }
} catch {
  Write-Error "Unable to ensure shared UAI: $($_.Exception.Message)"; exit 1
}

foreach ($r in $targetRegions) {
  $vaultName = "rsv-$r"
  $vaultRg   = "rsv-rg-$r"
  $base      = "backup-policy-$r"
  if ($BackupFrequency -eq 'Weekly' -or $BackupFrequency -eq 'Both') { $policyName = "$base-weekly" } else { $policyName = "$base-daily" }
  $assignName = "enable-vm-backup-$r"
  $uaiId = $sharedUaiId
  $customDefId = ''
  try { $customDefId = az policy definition show -n $CustomPolicyDefinitionName --query id -o tsv } catch { Write-Warning "Failed to resolve custom policy definition $($CustomPolicyDefinitionName): $($_.Exception.Message)" }
  if (-not $customDefId) { Write-Warning "Skipping region $r (custom policy definition not found)"; continue }
  try {
    az deployment sub create --name "assign-policy-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/assignCustomCentralBackupPolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId=$uaiId customPolicyDefinitionId=$customDefId vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName backupPolicyName=$policyName -o none
  } catch {
    Write-Warning "Assignment deployment failed for ${r}: $($_.Exception.Message)"
  }

  # Fetch the assignment id (if created) and log the resolved backupPolicyId from the deployment outputs for debugging
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

  $remName = "remediate-vm-backup-$r"
  Write-Host "Triggering remediation $remName"
  az policy remediation create -n $remName --policy-assignment $assignId --resource-discovery-mode ReEvaluateCompliance --location-filters $r -o none
}

Write-Host "Remediation triggers submitted. You can monitor jobs in Policy -> Remediations."
