# Tests for ConsoleHarness: these drive a real console, so they need fzf on PATH (the shell
# workload installs it) and take a few seconds. The key-specification parser has its own tests in
# tools\KeySpec\Test-KeySpec.ps1.
#
#   pwsh -File tools\ConsoleHarness\Test-ConsoleHarness.ps1
[CmdletBinding()]
param([switch] $SkipConsole)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'TestSupport.ps1')

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
            Send-ConsoleKeys $session '{WheelDown 2 }' -MouseDelivery Record -SettleMilliseconds 100 | Out-Null   # at the centre
            Send-ConsoleKeys $session '{WheelUp 7 3 1}' -MouseDelivery Record -SettleMilliseconds 400 | Out-Null
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
            Send-ConsoleKeys $session '{Click 12 4 Right}' -MouseDelivery Record -SettleMilliseconds 400 | Out-Null
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
            Assert-Equal $false $state.VtInput
            # The reported delivery is what was asked for, not a guess about the app: there is no
            # auto-detection, because an app can parse SGR without setting the VT input flag.
            Assert-Equal 'Vt' $state.MouseDelivery 'SGR is the default'
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

    # Mouse, against the application each delivery is for. Both use fzf's preview to read the
    # selection back, because the selection bar itself shows on every row of the character grid.
    function Use-FzfWithPreview([string] $Extra, [scriptblock] $Body) {
        $items = "1..40 | ForEach-Object { 'item ' + `$_ }"
        $session = Start-ConsoleApp -Command "$items | fzf $Extra --preview 'echo SEL={}'" `
            -WorkingDirectory $PSScriptRoot -Width 100 -Height 24
        try {
            Wait-ConsoleText $session 'SEL=' -TimeoutSeconds 30 | Out-Null
            & $Body $session
        } finally { Stop-ConsoleApp $session }
    }

    # Match a complete SEL="item N": the preview is drawn in pieces, so the label can be on
    # screen a frame before its value is.
    function Get-Selection($Session) {
        $line = Get-ConsoleScreen $Session | Where-Object { $_ -match 'SEL="item \d+"' } | Select-Object -First 1
        if ($line -match 'SEL="(item \d+)"') { return $Matches[1] }
        return ''
    }

    # Waits for a fully drawn selection that differs from $Previous. Waiting for a change rather
    # than for the value the test expects keeps the assertion meaningful: if the application lands
    # somewhere else, the test says so instead of polling until it agrees.
    function Wait-Selection($Session, [string] $Previous = '', [int] $TimeoutSeconds = 10) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            $selection = Get-Selection $Session
            if ($selection -and $selection -ne $Previous) { return $selection }
            Start-Sleep -Milliseconds 150
        } while ((Get-Date) -lt $deadline)
        throw "the selection stayed at '$Previous' for ${TimeoutSeconds}s"
    }

    Test-Case 'full-screen fzf takes mouse as console records (tcell)' {
        Use-FzfWithPreview '' {
            param($session)
            $selected = Wait-Selection $session
            Assert-Equal 'item 1' $selected
            Send-ConsoleKeys $session '{WheelUp 5 10 5}' -MouseDelivery Record -SettleMilliseconds 200 | Out-Null
            Assert-Equal 'item 6' (Wait-Selection $session $selected) 'five notches up the list'
        }
    }

    Test-Case 'a click selects the row it lands on' {
        Use-FzfWithPreview '' {
            param($session)
            # Aim at where the application actually drew, rather than at a guess.
            $screen = Get-ConsoleScreen $session
            $row = -1
            for ($index = 0; $index -lt $screen.Count; $index++) {
                if ($screen[$index] -match 'item 14') { $row = $index; break }
            }
            Assert-Equal $true ($row -ge 0) 'item 14 should be on screen'
            $selected = Get-Selection $session
            Send-ConsoleKeys $session "{Click 4 $row}" -MouseDelivery Record -SettleMilliseconds 200 | Out-Null
            Assert-Equal 'item 14' (Wait-Selection $session $selected)
        }
    }

    Test-Case 'fzf --height takes mouse as SGR instead (light renderer)' {
        Use-FzfWithPreview '--height 60%' {
            param($session)
            $selected = Wait-Selection $session
            Assert-Equal 'item 1' $selected
            # Record delivery is what this renderer ignores; Vt is what it reads. Nothing should
            # change here, so this one does have to wait out a fixed delay.
            Send-ConsoleKeys $session '{WheelUp 5 10 4}' -MouseDelivery Record -SettleMilliseconds 800 | Out-Null
            Assert-Equal 'item 1' (Get-Selection $session) 'console records are ignored here'
            Send-ConsoleKeys $session '{WheelUp 5 10 4}' -SettleMilliseconds 200 | Out-Null
            Assert-Equal 'item 5' (Wait-Selection $session $selected) 'the default (Vt) delivery works'
        }
    }

    Test-Case 'Send-ConsoleText does not press keys' {
        Use-Fzf {
            param($session)
            Send-ConsoleText $session 'enter{Enter}' -SettleMilliseconds 500 | Out-Null
            Assert-Equal $false $session.Process.HasExited 'fzf should still be running'
        }
    }
}

Complete-Tests
