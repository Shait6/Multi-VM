<#
Deletes transient diagnostic and deployment JSON files created during local testing.
Run from the repository root or provide `-RootPath` to target another folder.
#>
param(
    [string] $RootPath = (Get-Location).Path
)

$patterns = @(
    'deployment*.json',
    'deployment-*.json',
    'deployment-outputs.json',
    'deployment-operations.json',
    'deployment-fallback.json',
    '*-show.json',
    '*-whatif.json',
    '*.diagnostics.json'
)

Write-Host "Cleaning diagnostics under: $RootPath"
foreach ($p in $patterns) {
    Get-ChildItem -Path $RootPath -Recurse -Filter $p -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            Write-Host "Removed: $($_.FullName)"
        } catch {
            Write-Warning "Failed to remove $($_.FullName): $($_.Exception.Message)"
        }
    }
}

Write-Host "Cleanup complete."