# Runs every tools\<module>\Test-*.ps1 and fails if any of them does.
#
#   pwsh -File tools\Test-Tools.ps1
#   pwsh -File tools\Test-Tools.ps1 -Name KeySpec      # just one
[CmdletBinding()]
param(
    # Only run the tests under tools\<Name>.
    [string] $Name,
    # Passed through to each test script that accepts it (ConsoleHarness).
    [switch] $SkipConsole
)

$ErrorActionPreference = 'Stop'

$scripts = Get-ChildItem -LiteralPath $PSScriptRoot -Directory |
    Where-Object { -not $Name -or $_.Name -eq $Name } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'Test-*.ps1' -ErrorAction SilentlyContinue }

if (-not $scripts) { throw "no test scripts found$(if ($Name) { " for '$Name'" })" }

$failed = @()
foreach ($script in $scripts) {
    Write-Host "=== $($script.Directory.Name)\$($script.Name)" -ForegroundColor Cyan
    $arguments = @('-NoProfile', '-File', $script.FullName)
    # Only pass -SkipConsole to scripts that declare it.
    if ($SkipConsole -and (Select-String -LiteralPath $script.FullName -Pattern '\$SkipConsole' -Quiet)) {
        $arguments += '-SkipConsole'
    }
    & pwsh @arguments
    if ($LASTEXITCODE -ne 0) { $failed += $script.Name }
    Write-Host ''
}

if ($failed) {
    Write-Host "failed: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'Everything passed.' -ForegroundColor Green
