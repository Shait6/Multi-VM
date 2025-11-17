param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID,
  [string]$Regions = $env:REMEDIATION_REGIONS,            # Comma separated; blank -> deployment location
  [string]$DeploymentLocation = $env:DEPLOYMENT_LOCATION, # Fallback region
  [string]$BackupFrequency = $env:BACKUP_FREQUENCY,       # Daily|Weekly|Both (for policy name selection)
  [string]$TagName = $env:VM_TAG_NAME,
  [string]$TagValue = $env:VM_TAG_VALUE,
  [int]$WaitMinutes = [int]($env:WAIT_MINUTES | ForEach-Object { if($_){$_} else {0} }),
  [int]$MaxEvalPolls = 12,
  [int]$EvalPollSeconds = 45,
  [int]$MaxRemPolls = 20,
  [int]$RemPollSeconds = 30,
  [switch]$FailOnError
)

$ErrorActionPreference = 'Stop'

function Write-JsonSummary($summary) {
  $path = Join-Path -Path (Get-Location) -ChildPath 'backup-remediation-summary.json'
  $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding utf8
  Write-Host "Summary written -> $path"
}

function Get-AssignmentId($name) {
  try { (az policy assignment show -n $name -o json | ConvertFrom-Json).id } catch { $null }
}

function Get-PolicySummary($assignmentId, $subscriptionId) {
  try { az policy state summarize --subscription $subscriptionId --filter "PolicyAssignmentId eq '$assignmentId'" -o json | ConvertFrom-Json } catch { $null }
}

function Ensure-EvaluationReady($assignmentId, $subscriptionId) {
  for($i=0; $i -lt $MaxEvalPolls; $i++) {
    $sum = Get-PolicySummary $assignmentId $subscriptionId
    if($sum -and $sum.results -and $sum.results.nonCompliantResources -ge 0) { return $true }
    Write-Host "[Eval] Waiting for policy evaluation ($($i+1)/$MaxEvalPolls) ..."; Start-Sleep -Seconds $EvalPollSeconds
  }
  return $false
}

function Start-Remediation($assignmentId, $region) {
  $remName = "remediate-vm-backup-$region"
  Write-Host "Starting remediation task $remName (region=$region)"
  az policy remediation create -n $remName --policy-assignment $assignmentId --resource-discovery-mode ReEvaluateCompliance --location-filters $region -o none
  return $remName
}

function Wait-Remediation($remName) {
  for($i=0; $i -lt $MaxRemPolls; $i++) {
    try { $rem = az policy remediation show -n $remName -o json | ConvertFrom-Json } catch { $rem = $null }
    if($rem -and $rem.status -in @('Complete','Failed')) { return $rem }
    Write-Host "[Remediation] Polling status ($($i+1)/$MaxRemPolls) ..."; Start-Sleep -Seconds $RemPollSeconds
  }
  return $null
}

function List-ProtectedItems($vaultName, $vaultRg) {
  try {
    az backup protected-item list --vault-name $vaultName --resource-group $vaultRg --backup-management-type AzureIaasVM -o json | ConvertFrom-Json
  } catch { @() }
}

# --- MAIN ---
if(-not $SubscriptionId) { throw 'SubscriptionId is required.' }
az account set --subscription $SubscriptionId

if($WaitMinutes -gt 0) { Write-Host "Buffer wait $WaitMinutes minute(s) before remediation"; Start-Sleep -Seconds ($WaitMinutes*60) }

$targetRegions = if([string]::IsNullOrWhiteSpace($Regions)) { @($DeploymentLocation) } else { $Regions.Split(',') | ForEach-Object { $_.Trim() } }

Write-Host "Regions targeted: $($targetRegions -join ', ') | Tag=$TagName=$TagValue | Frequency=$BackupFrequency"

$summary = [System.Collections.Generic.List[object]]::new()

foreach($r in $targetRegions) {
  $vaultName = "rsv-$r"
  $vaultRg   = "rsv-rg-$r"
  $basePolicyName = "backup-policy-$r"
  if($BackupFrequency -eq 'Both') { $policyName = "$basePolicyName-weekly" } else { $policyName = $basePolicyName }
  $assignName = "enable-vm-backup-$r"

  Write-Host "--- Region: $r ---"
  Write-Host "Ensuring policy assignment $assignName (policy=$policyName vault=$vaultName)"

  # Deploy assignment (idempotent)
  try {
    az deployment sub create --name "policy-assign-$r-$(Get-Date -Format yyyyMMddHHmmss)" --location $r --template-file modules/backupAutoEnablePolicy.bicep --parameters policyAssignmentName=$assignName assignmentLocation=$r assignmentIdentityId="/subscriptions/$SubscriptionId/resourceGroups/$vaultRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-$r" vmTagName=$TagName vmTagValue=$TagValue vaultName=$vaultName vaultResourceGroup=$vaultRg backupPolicyName=$policyName -o none
  } catch {
    Write-Warning "Assignment deployment failed for $r: $($_.Exception.Message)"
  }

  $assignmentId = Get-AssignmentId $assignName
  if(-not $assignmentId) {
    $summary.Add([pscustomobject]@{ region=$r; status='assignment-missing'; protectedItems=0; remediation='not-started'; error='AssignmentNotFound' })
    if($FailOnError){ throw "Assignment not found for region $r" }
    continue
  }

  $evalReady = Ensure-EvaluationReady $assignmentId $SubscriptionId
  if(-not $evalReady) { Write-Warning "Evaluation not ready; proceeding with remediation anyway (ReEvaluateCompliance)." }

  $remName = Start-Remediation $assignmentId $r
  $remResult = Wait-Remediation $remName
  $remStatus = if($remResult){ $remResult.status } else { 'timeout' }

  $protected = List-ProtectedItems $vaultName $vaultRg
  $protectedCount = ($protected | Measure-Object).Count

  $err = $null
  if($remResult -and $remResult.status -eq 'Failed') { $err = ($remResult | ConvertTo-Json -Depth 6) }
  if(-not $remResult) { $err = 'RemediationPollTimeout' }

  $summary.Add([pscustomobject]@{ region=$r; status='completed'; evaluationReady=$evalReady; remediationStatus=$remStatus; protectedItems=$protectedCount; remediationName=$remName; error=$err })

  Write-Host "Region $r summary: remediationStatus=$remStatus protectedItems=$protectedCount"
}

Write-JsonSummary $summary

# Fail build if any failed and FailOnError switch provided
if($FailOnError -and ($summary | Where-Object { $_.remediationStatus -ne 'Complete' })) {
  Write-Error "One or more regional remediations failed."; exit 1
}
