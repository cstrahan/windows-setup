# Tests for PtyHarness. These start real programs under a pseudo console, so they take a few
# seconds; the mouse ones need fzf on PATH (the shell workload installs it).
#
#   pwsh -File tools\PtyHarness\Test-PtyHarness.ps1
#   pwsh -File tools\PtyHarness\Test-PtyHarness.ps1 -SkipConsole   # skip everything that runs a program
[CmdletBinding()]
param([switch] $SkipConsole)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'TestSupport.ps1')

if ($SkipConsole) {
    Write-Host "`nSkipping the pty tests (-SkipConsole)."
    Complete-Tests
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib\Wasmtime.Dotnet.dll'))) {
    Write-Host "`nSkipping the pty tests: wasmtime is missing. Apply the pty-harness workload." -ForegroundColor Yellow
    Complete-Tests
}

Import-Module (Join-Path $PSScriptRoot 'PtyHarness.psd1') -Force
Write-Host 'Driving programs through a pseudo console'

function Use-Pty([string] $CommandLine, [int] $Columns, [int] $Rows, [string] $Ready, [scriptblock] $Body) {
    $session = Start-PtyApp -CommandLine $CommandLine -WorkingDirectory $PSScriptRoot -Columns $Columns -Rows $Rows
    try {
        Wait-PtyText $session $Ready -TimeoutSeconds 30 | Out-Null
        & $Body $session
    } finally { Stop-PtyApp $session }
}

Test-Case 'a program runs, takes keys, and its output is rendered' {
    Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
        param($session)
        Send-PtyKeys $session 'echo pty-harness-works{Enter}' -SettleMilliseconds 700 | Out-Null
        $screen = Get-PtyScreen $session -NonEmpty
        Assert-Equal $true (($screen -match '^pty-harness-works') -ne $null) "screen was: $($screen -join ' | ')"
    }
}

Test-Case 'the console host is Windows Terminal OpenConsole when it can be found' {
    Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
        param($session)
        $info = Get-PtyInfo $session
        # The inbox host works for everything except mouse, so this is a warning sign rather than
        # a hard requirement; the mouse tests below are what actually depend on it.
        Assert-Equal $true ($info.consoleHost -match 'OpenConsole|inbox') "host was '$($info.consoleHost)'"
    }
}

Test-Case 'resizing tells the program, which redraws for the new size' {
    Use-Pty 'cmd.exe' 80 24 'Microsoft Windows' {
        param($session)
        $state = Set-PtySize $session -Columns 60 -Rows 20 -SettleMilliseconds 500
        Assert-Equal 60 $state.columns
        Assert-Equal 20 $state.rows
        # Ask the program itself what size it thinks it has.
        Send-PtyKeys $session 'mode con{Enter}' -SettleMilliseconds 800 | Out-Null
        $screen = Get-PtyScreen $session -NonEmpty
        $columns = ($screen | Where-Object { $_ -match 'Columns:\s+(\d+)' } | Select-Object -First 1)
        Assert-Equal $true ($columns -match 'Columns:\s+60') "the program reported: '$columns'"
    }
}

Test-Case 'a session can be picked up by another process' {
    $session = Start-PtyApp -CommandLine 'cmd.exe' -WorkingDirectory $PSScriptRoot -Name 'pty-test' -Columns 80 -Rows 24
    try {
        Wait-PtyText $session 'Microsoft Windows' -TimeoutSeconds 30 | Out-Null
        $script = @"
Import-Module '$(Join-Path $PSScriptRoot 'PtyHarness.psd1')'
`$s = Get-PtyApp -Name 'pty-test'
Send-PtyKeys `$s 'echo from-another-process{Enter}' -SettleMilliseconds 700 | Out-Null
(Get-PtyScreen `$s -NonEmpty) -match '^from-another-process' | Select-Object -Last 1
"@
        $seen = & pwsh -NoProfile -NoLogo -Command $script | Select-Object -Last 1
        Assert-Equal $true ("$seen" -match 'from-another-process') "the other process saw: '$seen'"
    } finally { Stop-PtyApp $session }
}

Test-Case 'stopping a session leaves nothing behind' {
    $session = Start-PtyApp -CommandLine 'cmd.exe' -WorkingDirectory $PSScriptRoot -Name 'pty-test' -Columns 80 -Rows 24
    Wait-PtyText $session 'Microsoft Windows' -TimeoutSeconds 30 | Out-Null
    $hostId = $session.HostProcessId
    Stop-PtyApp $session
    Assert-Throws { Get-PtyApp -Name 'pty-test' } "no pty session named 'pty-test'"
    Assert-Equal $false (Test-Path -LiteralPath $session.RecordPath)
    Assert-Equal $null (Get-Process -Id $hostId -ErrorAction SilentlyContinue) 'the host should be gone'
}

if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Write-Host "  skipped the mouse tests: fzf isn't on PATH." -ForegroundColor Yellow
    Complete-Tests
}

# Mouse. Both fzf renderers are driven with the same SGR reports: the console host adapts, turning
# them into console records for the tcell renderer and passing them through for the light one.
# This only works with Windows Terminal's OpenConsole; the inbox host forwards no mouse at all.
$items = "1..40 | ForEach-Object { 'item ' + `$_ }"

function Get-Selection($Session) {
    $line = Get-PtyScreen $Session | Where-Object { $_ -match 'SEL=' } | Select-Object -First 1
    if ($line -match 'SEL="(.+?)"') { return $Matches[1] }
    return ''
}

Test-Case 'full-screen fzf takes the wheel and a click' {
    Use-Pty "pwsh -NoProfile -Command `"$items | fzf --preview 'echo SEL={}'`"" 100 24 'SEL=' {
        param($session)
        Assert-Equal 'item 1' (Get-Selection $session)
        Send-PtyKeys $session '{WheelUp 5 10 5}' -SettleMilliseconds 900 | Out-Null
        Assert-Equal 'item 6' (Get-Selection $session) 'five notches up the list'
        Send-PtyKeys $session '{Click 4 8}' -SettleMilliseconds 900 | Out-Null
        Assert-Equal 'item 14' (Get-Selection $session) 'clicking the row at index 8'
    }
}

Test-Case 'fzf --height takes the same events, by a different route' {
    # Aim inside the box: with --height the application draws in part of the screen, and events
    # outside it are ignored (which looks exactly like mouse being broken).
    Use-Pty "pwsh -NoProfile -Command `"$items | fzf --height 60% --preview 'echo SEL={}'`"" 100 30 'SEL=' {
        param($session)
        Assert-Equal 'item 1' (Get-Selection $session)
        Send-PtyKeys $session '{WheelUp 5 10 4}' -SettleMilliseconds 900 | Out-Null
        Assert-Equal 'item 5' (Get-Selection $session)
    }
}

Complete-Tests
