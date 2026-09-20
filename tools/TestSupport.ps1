# Minimal test helpers for the scripts under tools\. Dot-source it, write Test-Case blocks, and
# finish with Complete-Tests, which sets the exit code.
#
#   . (Join-Path $PSScriptRoot '..\TestSupport.ps1')
#   Test-Case 'it works' { Assert-Equal 2 (1 + 1) }
#   Complete-Tests
#
# There's no Pester here on purpose: Windows ships only Pester 3.4 (for Windows PowerShell), and
# these tools are meant to work on a machine that hasn't been set up yet.

$script:Failures = 0

function Test-Case([string] $Name, [scriptblock] $Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-Equal($Expected, $Actual, [string] $Because = '') {
    if ($Expected -ne $Actual) {
        throw "expected '$Expected', got '$Actual'$(if ($Because) { " ($Because)" })"
    }
}

function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    try { & $Body } catch {
        if ("$_" -notmatch $Pattern) { throw "error did not match /$Pattern/: $_" }
        return
    }
    throw "expected an error matching /$Pattern/, but none was thrown"
}

function Complete-Tests {
    Write-Host ''
    if ($script:Failures) {
        Write-Host "$script:Failures test(s) failed." -ForegroundColor Red
        exit 1
    }
    Write-Host 'All tests passed.' -ForegroundColor Green
    exit 0
}
