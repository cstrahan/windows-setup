# Tests for ConsoleHarness. Run it with pwsh; it exits non-zero if anything failed.
#
#   pwsh -File tools\ConsoleHarness\Test-ConsoleHarness.ps1
#   pwsh -File tools\ConsoleHarness\Test-ConsoleHarness.ps1 -SkipConsole   # parser only, no fzf
#
# The parser cases are pure and fast; the console cases drive a real fzf in a hidden console, so
# they need fzf on PATH (the shell workload installs it) and take a few seconds.
[CmdletBinding()]
param([switch] $SkipConsole)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeySpec.ps1')

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

# Renders parsed events compactly, for readable expectations: each key press as
# <modifiers>vk<code>:<character>, with '+' between a press and its release ('v' down, '^' up).
function Format-Events($Events) {
    $parts = foreach ($keyEvent in $Events) {
        $modifiers = ''
        if ($keyEvent.ControlState -band 0x000C) { $modifiers += 'C' }   # either Ctrl
        if ($keyEvent.ControlState -band 0x0003) { $modifiers += 'A' }   # either Alt
        if ($keyEvent.ControlState -band 0x0010) { $modifiers += 'S' }
        $character = if ($keyEvent.CharCode -eq 0) { '.' } else { '0x{0:x2}' -f $keyEvent.CharCode }
        '{0}{1}{2}:{3}' -f $(if ($keyEvent.KeyDown) { 'v' } else { '^' }), $modifiers, ('0x{0:x2}' -f $keyEvent.VirtualKey), $character
    }
    return $parts -join ' '
}

Write-Host 'Key specification parsing'

Test-Case 'plain text is typed literally' {
    Assert-Equal 'v0x00:0x68 ^0x00:0x68 v0x00:0x69 ^0x00:0x69' (Format-Events (ConvertFrom-KeySpec 'hi'))
}

Test-Case "words that name keys are still text" {
    # The bug this syntax was adopted to fix: 'enter' used to press Enter.
    Assert-Equal 10 (ConvertFrom-KeySpec 'enter').Count
    Assert-Equal 0x65 (ConvertFrom-KeySpec 'enter')[0].CharCode
}

Test-Case 'commas survive' {
    Assert-Equal 6 (ConvertFrom-KeySpec 'a,b').Count
    Assert-Equal 0x2C (ConvertFrom-KeySpec 'a,b')[2].CharCode
}

Test-Case '{Enter} presses the key' {
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '{Enter}'))
}

Test-Case 'key names are case-insensitive and have the usual aliases' {
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Enter}')) (Format-Events (ConvertFrom-KeySpec '{RETURN}'))
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Backspace}')) (Format-Events (ConvertFrom-KeySpec '{bs}'))
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Escape}')) (Format-Events (ConvertFrom-KeySpec '{Esc}'))
}

Test-Case '^s is Ctrl+S: virtual key S, control character 0x13' {
    Assert-Equal 'vC0x53:0x13 ^C0x53:0x13' (Format-Events (ConvertFrom-KeySpec '^s'))
}

Test-Case 'a modifier applies to the next key only' {
    Assert-Equal 'vC0x53:0x13 ^C0x53:0x13 v0x00:0x73 ^0x00:0x73' (Format-Events (ConvertFrom-KeySpec '^ss'))
}

Test-Case 'modifiers combine, and reach named keys' {
    Assert-Equal 'vCS0x0d:0x0d ^CS0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '^+{Enter}'))
}

Test-Case '+a is A' {
    Assert-Equal 'vS0x00:0x41 ^S0x00:0x41' (Format-Events (ConvertFrom-KeySpec '+a'))
}

Test-Case '!x is Alt+X, keeping the character' {
    Assert-Equal 'vA0x58:0x78 ^A0x58:0x78' (Format-Events (ConvertFrom-KeySpec '!x'))
}

Test-Case 'repeat counts' {
    Assert-Equal 6 (ConvertFrom-KeySpec '{BS 3}').Count
    Assert-Equal 10 (ConvertFrom-KeySpec '{a 5}').Count
}

Test-Case '{Ctrl down} holds Ctrl across keys, {Ctrl up} releases it' {
    Assert-Equal 'vC0x4a:0x0a ^C0x4a:0x0a vC0x4b:0x0b ^C0x4b:0x0b v0x00:0x6a ^0x00:0x6a' `
        (Format-Events (ConvertFrom-KeySpec '{Ctrl down}jk{Ctrl up}j'))
}

Test-Case 'braces and modifier characters can be typed' {
    Assert-Equal 'v0x00:0x7b ^0x00:0x7b v0x00:0x7d ^0x00:0x7d' (Format-Events (ConvertFrom-KeySpec '{{}{}}'))
    Assert-Equal 'v0x00:0x5e ^0x00:0x5e' (Format-Events (ConvertFrom-KeySpec '{^}'))
    # ':qa{!}{Enter}' in Neovim: an unescaped '!' would be Alt, and quietly send Alt+Enter.
    Assert-Equal 'v0x00:0x21 ^0x00:0x21 v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '{!}{Enter}'))
}

Test-Case '{Raw} makes the rest literal' {
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '^{Enter}' -Literal)) (Format-Events (ConvertFrom-KeySpec '{Raw}^{Enter}'))
    Assert-Equal 16 (ConvertFrom-KeySpec '{Raw}^{Enter}').Count   # the eight characters
}

Test-Case 'the literal mode behind Send-ConsoleText types braces and modifiers verbatim' {
    Assert-Equal 'v0x00:0x5e ^0x00:0x5e v0x00:0x7b ^0x00:0x7b' (Format-Events (ConvertFrom-KeySpec '^{' -Literal))
}

Test-Case 'newlines in text are Enter, and a CRLF is one press' {
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec "`r`n"))
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec "`n"))
}

Test-Case '{U+...} types a code point, outside the BMP too' {
    Assert-Equal 0x263A (ConvertFrom-KeySpec '{U+263A}')[0].CharCode
    Assert-Equal 4 (ConvertFrom-KeySpec '{U+1F600}').Count   # a surrogate pair, pressed and released
}

Test-Case 'an empty specification sends nothing' {
    Assert-Equal 0 (ConvertFrom-KeySpec '').Count
}

Test-Case 'mouse tokens carry position, button and action' {
    $events = ConvertFrom-KeySpec '{Click 40 10}'
    Assert-Equal 'Mouse' $events[0].Type
    Assert-Equal 3 $events.Count 'a move, then press and release'
    Assert-Equal 'Move' $events[0].Action
    Assert-Equal 40 $events[1].X
    Assert-Equal 10 $events[1].Y
    Assert-Equal 'Left' $events[1].Button
    Assert-Equal 'Down' $events[1].Action
    Assert-Equal 'Up' $events[2].Action
}

Test-Case 'the pointer sticks between tokens' {
    # {WheelDown} has no coordinates, so it happens where {Click} left the pointer.
    # Assign first: the result is returned as one array object, so piping it straight into
    # Where-Object would hand the whole array over as a single item.
    $all = ConvertFrom-KeySpec '{Click 40 10}{WheelDown}'
    $events = @($all | Where-Object { $_.Action -eq 'Wheel' })
    Assert-Equal 1 $events.Count
    Assert-Equal 40 $events[0].X
    Assert-Equal 10 $events[0].Y
    # With no coordinates at all, the worker fills in the middle of the window.
    Assert-Equal -1 (ConvertFrom-KeySpec '{WheelUp}')[0].X
}

Test-Case 'wheel tokens: direction, axis and count' {
    Assert-Equal -1 (ConvertFrom-KeySpec '{WheelDown}')[0].Notches
    Assert-Equal 1 (ConvertFrom-KeySpec '{WheelUp}')[0].Notches
    Assert-Equal 3 (ConvertFrom-KeySpec '{WheelDown 3}').Count 'one event per notch'
    Assert-Equal 'Horizontal' (ConvertFrom-KeySpec '{WheelRight}')[0].WheelAxis
    Assert-Equal 3 (ConvertFrom-KeySpec '{WheelDown 40 10 3}').Count
}

Test-Case 'click options: button, count, and move-only' {
    Assert-Equal 'Right' (ConvertFrom-KeySpec '{Click 5 5 Right}')[1].Button
    Assert-Equal 'Middle' (ConvertFrom-KeySpec '{MButton}')[0].Button
    Assert-Equal 5 (ConvertFrom-KeySpec '{Click 5 5 2}').Count 'a move plus two press/release pairs'
    $moveOnly = ConvertFrom-KeySpec '{Click 5 5 0}'
    Assert-Equal 1 $moveOnly.Count
    Assert-Equal 'Move' $moveOnly[0].Action
    Assert-Equal 'Down' (ConvertFrom-KeySpec '{LButton down}')[0].Action
}

Test-Case 'modifiers reach the mouse too' {
    Assert-Equal 8 (ConvertFrom-KeySpec '^{Click 5 5}')[1].ControlState 'LEFT_CTRL_PRESSED'
}

Test-Case 'keys and mouse can be mixed in one specification' {
    $events = ConvertFrom-KeySpec 'hi{Click 1 2}{Enter}'
    $types = ($events | ForEach-Object { $_.Type }) -join ''
    Assert-Equal 'KeyKeyKeyKeyMouseMouseMouseKeyKey' $types
}

Test-Case 'mistakes are reported, with a way out' {
    Assert-Throws { ConvertFrom-KeySpec '{Enter' } 'unterminated'
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } "unknown key '\{Entr\}'"
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } '-Literal'
    Assert-Throws { ConvertFrom-KeySpec '{Tab x}' } "expected a repeat count"
    Assert-Throws { ConvertFrom-KeySpec '{Ctrl}' } 'only sees modifiers'
    Assert-Throws { ConvertFrom-KeySpec '#r' } "can't reach a console app"
    Assert-Throws { ConvertFrom-KeySpec 'abc^' } 'modifier prefix'
}

if ($SkipConsole) {
    Write-Host "`nSkipping the console tests (-SkipConsole)."
} elseif (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Write-Host "`nSkipping the console tests: fzf isn't on PATH." -ForegroundColor Yellow
} else {
    Write-Host "`nDriving a real console (fzf)"
    Import-Module (Join-Path $PSScriptRoot 'ConsoleHarness.psd1') -Force

    # fzf over a fixed list, so the tests don't depend on the current directory.
    $items = 'alpha', 'beta,gamma', 'enter-the-void', 'delta'
    $command = "@('$($items -join "','")') | fzf"

    function Use-Fzf([scriptblock] $Body) {
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session '^\s*>' | Out-Null
            & $Body $session
        } finally { Stop-ConsoleApp $session }
    }

    function Get-Query($Screen) {
        $line = $Screen | Where-Object { $_ -match '^\s*>' } | Select-Object -First 1
        return ($line -replace '^\s*>\s?', '').TrimEnd()
    }

    Test-Case 'text with a comma reaches the app intact' {
        Use-Fzf {
            param($session)
            Assert-Equal 'beta,gam' (Get-Query (Send-ConsoleKeys $session 'beta,gam' -SettleMilliseconds 400))
        }
    }

    Test-Case "'enter' is typed, not pressed" {
        Use-Fzf {
            param($session)
            Assert-Equal 'enter' (Get-Query (Send-ConsoleKeys $session 'enter' -SettleMilliseconds 400))
            Assert-Equal $false $session.Process.HasExited 'fzf should still be running'
        }
    }

    Test-Case '{Enter} accepts the selection and fzf exits' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'delta{Enter}' -SettleMilliseconds 600 | Out-Null
            Assert-Equal $true $session.Process.WaitForExit(3000) 'fzf should have exited'
        }
    }

    Test-Case 'a chord reaches the app: Ctrl+U clears the query' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
            Assert-Equal '' (Get-Query (Send-ConsoleKeys $session '^u' -SettleMilliseconds 400))
        }
    }

    Test-Case 'a repeat count reaches the app: {BS 3}' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
            Assert-Equal 'al' (Get-Query (Send-ConsoleKeys $session '{BS 3}' -SettleMilliseconds 400))
        }
    }

    Test-Case 'Send-ConsoleText types syntax characters' {
        Use-Fzf {
            param($session)
            Assert-Equal '^{Enter}' (Get-Query (Send-ConsoleText $session '^{Enter}' -SettleMilliseconds 400))
        }
    }

    Test-Case 'another process can pick the session up and drive it' {
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot -Name 'harness-test'
        try {
            Wait-ConsoleText $session '^\s*>' | Out-Null
            Send-ConsoleKeys $session 'al' -SettleMilliseconds 400 | Out-Null
            # A separate process: it has only the name, and finds the running app from that.
            $script = @"
Import-Module '$(Join-Path $PSScriptRoot 'ConsoleHarness.psd1')'
`$s = Get-ConsoleApp -Name 'harness-test'
(Send-ConsoleKeys `$s 'pha' -SettleMilliseconds 400) -match '^\s*>' -replace '^\s*>\s?'
"@
            $seen = (& pwsh -NoProfile -NoLogo -Command $script | Select-Object -Last 1).TrimEnd()
            Assert-Equal 'alpha' $seen 'the other process should have typed onto the same query'
        } finally { Stop-ConsoleApp $session }
    }

    Test-Case 'stopping a session kills the app, not just its wrapper' {
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot
        Wait-ConsoleText $session '^\s*>' | Out-Null
        $descendants = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($session.Id)")
        Assert-Equal $true ($descendants.Count -gt 0) 'the wrapper should have a child'
        Stop-ConsoleApp $session
        $survivors = @($descendants | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        Assert-Equal 0 $survivors.Count 'no child should be left running'
    }

    Test-Case 'a stopped session is forgotten' {
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot -Name 'harness-test'
        Wait-ConsoleText $session '^\s*>' | Out-Null
        Stop-ConsoleApp $session
        Assert-Throws { Get-ConsoleApp -Name 'harness-test' } "no console app named 'harness-test'"
        Assert-Equal $false (Test-Path -LiteralPath $session.RecordPath) 'the record should be gone'
    }

    # The sink reports what actually arrived, so mouse and resize are asserted directly instead of
    # through some other app's reaction to them.
    function Use-Sink([switch] $VirtualTerminalInput, [scriptblock] $Body) {
        $log = Join-Path ([IO.Path]::GetTempPath()) "console-harness-sink-$([guid]::NewGuid().ToString('N')).log"
        $sink = Join-Path $PSScriptRoot 'InputSink.ps1'
        $command = "& '$sink' -LogPath '$log'" + $(if ($VirtualTerminalInput) { ' -VirtualTerminalInput' } else { '' })
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session 'INPUT SINK READY' -TimeoutSeconds 30 | Out-Null
            & $Body $session $log
        } finally {
            Stop-ConsoleApp $session
            Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'a wheel arrives as a mouse record, with position and delta' {
        Use-Sink {
            param($session, $log)
            Send-ConsoleKeys $session '{WheelDown 2 }' -SettleMilliseconds 100 | Out-Null   # at the centre
            Send-ConsoleKeys $session '{WheelUp 7 3 1}' -SettleMilliseconds 400 | Out-Null
            $mouse = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^MOUSE' })
            Assert-Equal 3 $mouse.Count 'two notches down, then one up'
            # 120 per notch, negative down: 0xff88 is -120 in the high word. flags 0x4 = wheeled.
            Assert-Equal $true ($mouse[0] -match 'buttons=0xff880000 flags=0x4') "got '$($mouse[0])'"
            Assert-Equal $true ($mouse[2] -match 'pos=7,3 buttons=0x00780000 flags=0x4') "got '$($mouse[2])'"
        }
    }

    Test-Case 'a click arrives as a move, a press and a release' {
        Use-Sink {
            param($session, $log)
            Send-ConsoleKeys $session '{Click 12 4 Right}' -SettleMilliseconds 400 | Out-Null
            $mouse = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^MOUSE' })
            Assert-Equal 3 $mouse.Count
            Assert-Equal $true ($mouse[0] -match 'pos=12,4 buttons=0x00000000 flags=0x1') "move: '$($mouse[0])'"
            Assert-Equal $true ($mouse[1] -match 'pos=12,4 buttons=0x00000002 flags=0x0') "press: '$($mouse[1])'"
            Assert-Equal $true ($mouse[2] -match 'pos=12,4 buttons=0x00000000 flags=0x0') "release: '$($mouse[2])'"
        }
    }

    Test-Case 'an app in virtual-terminal mode gets SGR sequences instead' {
        Use-Sink -VirtualTerminalInput {
            param($session, $log)
            $state = Get-ConsoleInfo $session
            Assert-Equal $true $state.VtInput
            Send-ConsoleKeys $session '{WheelDown 7 3 1}' -SettleMilliseconds 400 | Out-Null
            $characters = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^KEY down=1' } | ForEach-Object {
                if ($_ -match 'char=0x([0-9a-f]+)') { [char] [Convert]::ToInt32($Matches[1], 16) }
            })
            # SGR: button 65 is wheel-down, and the coordinates are 1-based.
            Assert-Equal "$([char] 27)[<65;8;4M" (-join $characters)
        }
    }

    Test-Case 'a resize reaches the app, and the state reports the new size' {
        Use-Sink {
            param($session, $log)
            $state = Set-ConsoleSize $session -Width 80 -Height 25 -SettleMilliseconds 400
            Assert-Equal 80 $state.WindowWidth
            Assert-Equal 25 $state.WindowHeight
            Assert-Equal $true ((Get-Content -LiteralPath $log) -match 'RESIZE to 80x' -ne $null) 'the app should see a resize event'
        }
    }

    Test-Case 'a full-screen app can be resized too, and reflows' {
        # fzf holds the alternate screen buffer, where conhost refuses SetConsoleScreenBufferSize
        # and SetConsoleWindowInfo, so this exercises the window-resize fallback.
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session '^\s*>' | Out-Null
            $state = Set-ConsoleSize $session -Width 80 -Height 20 -SettleMilliseconds 600
            Assert-Equal 80 $state.WindowWidth
            Assert-Equal 20 $state.WindowHeight
            $widest = (@(Get-ConsoleScreen $session) | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
            Assert-Equal $true ($widest -le 80) "the app redrew to $widest columns"
        } finally { Stop-ConsoleApp $session }
    }

    Test-Case 'Get-ConsoleInfo reports the console and its input mode' {
        Use-Sink {
            param($session, $log)
            $state = Get-ConsoleInfo $session
            Assert-Equal 120 $state.WindowWidth
            Assert-Equal 30 $state.WindowHeight
            Assert-Equal 1000 $state.BufferHeight 'the default buffer leaves room for scrollback'
            Assert-Equal $true $state.MouseInput
            Assert-Equal 'Record' $state.MouseDelivery 'no VT input, so records'
        }
    }

    Test-Case 'scrollback can be read and the view moved' {
        # 200 lines of output, then the app waits, so the buffer holds more than one screen.
        $session = Start-ConsoleApp -Command '1..200 | ForEach-Object { "line " + $_ }; $null = Read-Host' -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session 'line 200' -TimeoutSeconds 30 | Out-Null
            $state = Get-ConsoleInfo $session
            Assert-Equal $true ($state.WindowTop -gt 0) 'output should have scrolled the window down the buffer'

            $visible = @(Get-ConsoleScreen $session -NonEmpty)
            Assert-Equal $false ($visible -contains 'line 1') 'line 1 has scrolled off'

            $all = @(Get-ConsoleScreen $session -Scrollback -NonEmpty)
            Assert-Equal $true ($all -contains 'line 1') 'but it is still in the buffer'
            Assert-Equal $true ($all -contains 'line 200') ''

            $rows = @(Get-ConsoleScreen $session -FromRow ($state.WindowTop - 3) -Rows 3)
            Assert-Equal 3 $rows.Count
            Assert-Equal $true ($rows[0] -match '^line \d+$') "got '$($rows[0])'"

            $moved = Move-ConsoleView $session -Lines -10
            Assert-Equal ($state.WindowTop - 10) $moved.WindowTop
            $moved = Move-ConsoleView $session -Start
            Assert-Equal 0 $moved.WindowTop
            Assert-Equal 'line 1' (@(Get-ConsoleScreen $session -NonEmpty)[0])
            $moved = Move-ConsoleView $session -End
            Assert-Equal ($state.BufferHeight - $state.WindowHeight) $moved.WindowTop
        } finally { Stop-ConsoleApp $session }
    }

    Test-Case 'a command containing double quotes survives' {
        # Start-Process quoting used to mangle this into a call to Get-Item.
        $session = Start-ConsoleApp -Command '1..3 | ForEach-Object { "item " + $_ } | fzf' -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session 'item 3' | Out-Null
            Assert-Equal $true ((Get-ConsoleScreen $session -NonEmpty) -match 'item 2' -ne $null)
        } finally { Stop-ConsoleApp $session }
    }

    Test-Case 'Send-ConsoleText does not press keys' {
        Use-Fzf {
            param($session)
            Send-ConsoleText $session 'enter{Enter}' -SettleMilliseconds 500 | Out-Null
            Assert-Equal $false $session.Process.HasExited 'fzf should still be running'
        }
    }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$script:Failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
