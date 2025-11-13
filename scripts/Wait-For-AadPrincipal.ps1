param(
  [Parameter(Mandatory=$true)]
  [string]$PrincipalId,
  [Parameter(Mandatory=$false)]
  [int]$TimeoutSeconds = 120,
  [Parameter(Mandatory=$false)]
  [int]$PollIntervalSeconds = 5
)

# Requires Azure CLI logged in and set to the correct subscription
$start = Get-Date
$deadline = $start.AddSeconds($TimeoutSeconds)

Write-Host "Waiting up to $TimeoutSeconds seconds for AAD principal '$PrincipalId' to appear..."

while ((Get-Date) -lt $deadline) {
  try {
    $sp = az ad sp show --id $PrincipalId 2>$null | ConvertFrom-Json
    if ($sp) {
      Write-Host "Principal found: $PrincipalId"
      exit 0
    }
  } catch {
    # ignore and retry
  }
  Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Error "Timed out waiting for AAD principal $PrincipalId after $TimeoutSeconds seconds"
exit 1
