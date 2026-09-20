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

Test-Case 'every form of the screen is the viewport, not the history' {
    # libghostty's formatter emits history and viewport together, so Vt and Html would carry the
    # whole scrollback if nothing trimmed them.
    Use-Pty 'cmd.exe' 80 10 'Microsoft Windows' {
        param($session)
        Send-PtyKeys $session 'for /L %i in (1,1,30) do @echo line %i{Enter}' -SettleMilliseconds 1200 | Out-Null
        foreach ($form in 'Vt', 'Html') {
            $screen = Get-PtyScreen $session -As $form
            Assert-Equal $true ($screen -match 'line 30') "-As $form should show the last line"
            Assert-Equal $false ($screen -match 'line 1\D') "-As $form should not carry the scrollback"
        }
        $styled = @(Get-PtyScreen $session -As Styled)
        Assert-Equal 10 $styled.Count 'one entry per viewport row'
        # And Vt keeps the history when it is asked for.
        Assert-Equal $true ((Get-PtyScreen $session -As Vt -Scrollback) -match 'line 1\D') '-Scrollback should show it'
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

$colourProbe = Join-Path $PSScriptRoot 'ColourProbe.ps1'

Test-Case 'colours and attributes come back as styled runs' {
    Use-Pty "pwsh -NoProfile -File `"$colourProbe`"" 40 8 'READY' {
        param($session)
        $rows = @(Get-PtyScreen $session -As Styled)
        Assert-Equal 8 $rows.Count 'one entry per viewport row'

        $red = @($rows[1].Runs)[0]
        Assert-Equal 'red' $red.Text.Trim()
        Assert-Equal 'Palette' $red.Foreground.Kind
        Assert-Equal 1 $red.Foreground.Index 'SGR 31 is palette entry 1'
        Assert-Equal $true ($red.Foreground.Hex -match '^#[0-9a-f]{6}$') "palette should be resolved, got '$($red.Foreground.Hex)'"

        $rgb = @($rows[1].Runs) | Where-Object { $_.Text -eq 'bold-rgb' } | Select-Object -First 1
        Assert-Equal 'Rgb' $rgb.Foreground.Kind
        Assert-Equal '#0080ff' $rgb.Foreground.Hex
        Assert-Equal $true $rgb.Bold

        Assert-Equal 'Single' (@($rows[3].Runs)[0].Underline)

        # A plain row still reports the terminal's own colours, and says they are the default.
        $plain = @($rows[0].Runs)[0]
        Assert-Equal 'plain' $plain.Text
        Assert-Equal 'Default' $plain.Foreground.Kind
        Assert-Equal $plain.Foreground.Hex $plain.EffectiveForeground.Hex
    }
}

Test-Case 'inverse is resolved into the effective colours' {
    # A highlighted row is usually inverse rather than literally coloured, so a test that asks
    # "what does this look like" has to get the swap done for it.
    Use-Pty "pwsh -NoProfile -File `"$colourProbe`"" 40 8 'READY' {
        param($session)
        $rows = @(Get-PtyScreen $session -As Styled)
        $inverse = @($rows[2].Runs)[0]
        Assert-Equal $true $inverse.Inverse
        Assert-Equal $inverse.Background.Hex $inverse.EffectiveForeground.Hex 'inverse swaps the pair'
        Assert-Equal $inverse.Foreground.Hex $inverse.EffectiveBackground.Hex

        $background = @($rows[2].Runs) | Where-Object { $_.Background.Kind -eq 'Palette' } | Select-Object -First 1
        Assert-Equal 4 $background.Background.Index 'SGR 44 is palette entry 4'
    }
}

Test-Case 'a point query and a search report the style' {
    Use-Pty "pwsh -NoProfile -File `"$colourProbe`"" 40 8 'READY' {
        param($session)
        $at = Get-PtyStyleAt $session -Row 1 -Column 0
        Assert-Equal 'Palette' $at.Foreground.Kind 'the first cell of the red run'
        Assert-Equal $null (Get-PtyStyleAt $session -Row 0 -Column 39) 'past the end of what was drawn'

        $found = @(Find-PtyText $session 'bold-\w+' -WithStyle)
        Assert-Equal 1 $found.Count
        Assert-Equal 1 $found[0].Row
        Assert-Equal 8 $found[0].Column
        Assert-Equal 'bold-rgb' $found[0].Text
        Assert-Equal '#0080ff' @($found[0].Runs)[0].EffectiveForeground.Hex
    }
}

Test-Case 'the screen can be had as VT or as a page to look at' {
    Use-Pty "pwsh -NoProfile -File `"$colourProbe`"" 40 8 'READY' {
        param($session)
        $escape = [char] 27
        $vt = Get-PtyScreen $session -As Vt
        Assert-Equal $true ($vt -match "$escape\[38;2;0;128;255m") 'the RGB colour, as an escape sequence'
        Assert-Equal $true ($vt -match 'bold-rgb')

        $html = Get-PtyScreen $session -As Html
        Assert-Equal $true ($html -match 'color:#0080ff') 'the RGB colour, as CSS'
        Assert-Equal $true ($html -match 'font-weight:bold')
        # Palette colours are resolved, not left as the CSS variables libghostty would emit and
        # never define.
        Assert-Equal $true ($html -match 'color:#[0-9a-f]{6}[^>]*>red') 'the palette colour, resolved'
        Assert-Equal $true ($html -match '(?s)<html>.*</html>') 'a whole document, not a fragment'

        Assert-Throws { Get-PtyScreen $session -As Html -Scrollback } "doesn't apply to -As Html"
        Assert-Throws { Get-PtyScreen $session -As Vt -NonEmpty } '-NonEmpty only applies'
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

# Pin the shell fzf runs --preview with, so these tests don't depend on the environment they were
# started from. Run from git bash, SHELL is /bin/bash.exe: fzf treats that as a POSIX shell and
# converts the path with cygpath, which isn't on PATH when fzf was launched from pwsh, so the
# preview never runs and every assertion here times out with an empty selection. fzf's own tests
# pin it for the same reason. 'cmd' rather than 'pwsh' because the assertions expect cmd's
# quoting: fzf substitutes {} as "item 1", quotes included, and pwsh would strip them.
$env:SHELL = 'cmd'

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
