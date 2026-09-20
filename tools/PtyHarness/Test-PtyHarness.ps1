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

Test-Case 'the screen is the viewport, and -Scrollback is everything' {
    # More output than fits, so some of it has scrolled off.
    Use-Pty 'cmd.exe' 80 10 'Microsoft Windows' {
        param($session)
        Send-PtyKeys $session 'for /L %i in (1,1,30) do @echo line %i{Enter}' -SettleMilliseconds 1200 | Out-Null
        $visible = @(Get-PtyScreen $session -NonEmpty)
        $everything = @(Get-PtyScreen $session -Scrollback -NonEmpty)
        Assert-Equal $true ($visible.Count -le 10) "the viewport should fit the terminal, got $($visible.Count) rows"
        Assert-Equal $true ($everything.Count -gt $visible.Count) 'scrollback should hold more than the viewport'
        Assert-Equal $true (($everything -match '^line 1$') -ne $null) 'the first line should still be in scrollback'
        Assert-Equal $false (($visible -match '^line 1$') -ne $null) 'but it should have scrolled out of view'
        Assert-Equal $true (($visible -match '^line 30$') -ne $null) 'and the last line should be visible'
    }
}

Test-Case 'the terminal answers what a program asks it' {
    # Without this, a program that queries the terminal waits for a reply that never comes, and
    # the query itself can end up drawn on the screen (Neovim's XTGETTCAP did).
    $probe = Join-Path $PSScriptRoot 'QueryProbe.ps1'
    Use-Pty "pwsh -NoProfile -File `"$probe`"" 80 24 'ANSWER:' {
        param($session)
        $line = Get-PtyScreen $session -NonEmpty | Where-Object { $_ -match 'ANSWER:' } | Select-Object -First 1
        # A primary device attributes reply: ESC [ ? ... c
        Assert-Equal $true ($line -match 'ANSWER:<ESC>\[\?[0-9;]+c:END') "the program was told: '$line'"
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

# The preview is drawn in pieces, so match a complete SEL="item N" rather than the bare label:
# 'SEL=' can be on screen a frame before its value is.
function Get-Selection($Session) {
    $line = Get-PtyScreen $Session | Where-Object { $_ -match 'SEL="item \d+"' } | Select-Object -First 1
    if ($line -match 'SEL="(item \d+)"') { return $Matches[1] }
    return ''
}

# Waits for a fully drawn selection that differs from $Previous, and returns it. Waiting for a
# change rather than for the value the test expects keeps the assertion meaningful: if the
# application lands somewhere else, the test says so instead of polling until it agrees.
function Wait-Selection($Session, [string] $Previous = '', [int] $TimeoutSeconds = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $selection = Get-Selection $Session
        if ($selection -and $selection -ne $Previous) { return $selection }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "the selection stayed at '$Previous' for ${TimeoutSeconds}s"
}

Test-Case 'full-screen fzf takes the wheel and a click' {
    Use-Pty "pwsh -NoProfile -Command `"$items | fzf --preview 'echo SEL={}'`"" 100 24 'SEL="item' {
        param($session)
        $selected = Wait-Selection $session
        Assert-Equal 'item 1' $selected
        Send-PtyKeys $session '{WheelUp 5 10 5}' -SettleMilliseconds 200 | Out-Null
        $selected = Wait-Selection $session $selected
        Assert-Equal 'item 6' $selected 'five notches up the list'
        Send-PtyKeys $session '{Click 4 8}' -SettleMilliseconds 200 | Out-Null
        Assert-Equal 'item 14' (Wait-Selection $session $selected) 'clicking the row at index 8'
    }
}

Test-Case 'fzf --height takes the same events, by a different route' {
    # Aim inside the box: with --height the application draws in part of the screen, and events
    # outside it are ignored (which looks exactly like mouse being broken).
    Use-Pty "pwsh -NoProfile -Command `"$items | fzf --height 60% --preview 'echo SEL={}'`"" 100 30 'SEL="item' {
        param($session)
        $selected = Wait-Selection $session
        Assert-Equal 'item 1' $selected
        Send-PtyKeys $session '{WheelUp 5 10 4}' -SettleMilliseconds 200 | Out-Null
        Assert-Equal 'item 5' (Wait-Selection $session $selected)
    }
}

Complete-Tests
