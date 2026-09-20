# PtyHarness: drive an interactive program through a pseudo console and read what it drew.
#
# Where ConsoleHarness attaches to a legacy console and reads the grid conhost renders, this runs
# the program under a ConPTY and renders the VT stream itself, with libghostty-vt. That costs a
# resident host process and two dependencies, and buys what a legacy console can't do: mouse for
# apps that only speak VT (fzf), reflow on resize, and a terminal that behaves like the one the
# user actually runs things in.
#
# The session is the host process; see PtyHost.ps1 for why it has to be one.

$script:HostScript = Join-Path $PSScriptRoot 'PtyHost.ps1'
$script:SessionDirectory = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'pty-harness')
# The same AutoHotkey-style syntax ConsoleHarness uses; only the delivery differs.
Import-Module (Join-Path $PSScriptRoot '..' 'KeySpec' 'KeySpec.psd1') -ErrorAction Stop

# Virtual key -> the escape sequence a terminal sends for it. Keys that produce a character carry
# it in the event instead, so only the ones that don't are listed.
$script:KeySequences = @{
    0x26 = '[A'; 0x28 = '[B'; 0x27 = '[C'; 0x25 = '[D'      # arrows
    0x24 = '[H'; 0x23 = '[F'                                 # home, end
    0x21 = '[5~'; 0x22 = '[6~'                               # page up, page down
    0x2D = '[2~'; 0x2E = '[3~'                               # insert, delete
    0x70 = 'OP'; 0x71 = 'OQ'; 0x72 = 'OR'; 0x73 = 'OS'       # F1-F4
    0x74 = '[15~'; 0x75 = '[17~'; 0x76 = '[18~'; 0x77 = '[19~'   # F5-F8
    0x78 = '[20~'; 0x79 = '[21~'; 0x7A = '[23~'; 0x7B = '[24~'   # F9-F12
}

function ConvertTo-PtyBytes {
    <#
    .SYNOPSIS
    Renders parsed key and mouse events as the bytes a terminal would send.

    .DESCRIPTION
    Keys become their characters or escape sequences, and the mouse becomes SGR reports
    (ESC[<button;column;rowM), which is what an application asks for with DECSET 1006.
    #>
    param([object[]] $Events)

    $escape = [char] 27
    $text = [Text.StringBuilder]::new()
    $heldButton = ''
    foreach ($item in $Events) {
        if ($item.Type -eq 'Key') {
            # One press produces one sequence; the release is a console notion, not a pty one.
            if (-not $item.KeyDown) { continue }
            $alt = [bool] ($item.ControlState -band 0x0003)
            if ($item.CharCode -ne 0) {
                $character = [char] $item.CharCode
                # Backspace: terminals expect DEL, which is what the key sends in a VT world.
                if ($item.CharCode -eq 8) { $character = [char] 0x7F }
                if ($alt) { [void] $text.Append($escape) }
                [void] $text.Append($character)
                continue
            }
            $sequence = $script:KeySequences[[int] $item.VirtualKey]
            if ($sequence) { [void] $text.Append($escape).Append($sequence) }
            continue
        }

        # Mouse, as SGR: button code, 1-based column and row, M for press and m for release.
        $buttons = @{ Left = 0; Middle = 1; Right = 2; X1 = 128; X2 = 129 }
        $final = 'M'
        $code = switch ($item.Action) {
            'Wheel' {
                if ($item.WheelAxis -eq 'Horizontal') {
                    if ($item.Notches -gt 0) { 67 } else { 66 }
                } else {
                    if ($item.Notches -gt 0) { 64 } else { 65 }
                }
            }
            'Move' {
                # 3 is "no button"; +32 marks motion, so a drag reports what is held.
                $base = if ($heldButton) { $buttons[$heldButton] } else { 3 }
                $base + 32
            }
            'Up' { $final = 'm'; $buttons[$item.Button] }
            default { $buttons[$item.Button] }
        }
        switch ($item.Action) {
            'Down' { $heldButton = $item.Button }
            'Up' { $heldButton = '' }
        }
        if ($item.ControlState -band 0x0010) { $code += 4 }    # shift
        if ($item.ControlState -band 0x0003) { $code += 8 }    # alt
        if ($item.ControlState -band 0x000C) { $code += 16 }   # ctrl
        $column = [Math]::Max(1, [int] $item.X + 1)
        $row = [Math]::Max(1, [int] $item.Y + 1)
        [void] $text.Append("$escape[<$code;$column;$row$final")
    }
    return [Text.Encoding]::UTF8.GetBytes($text.ToString())
}

function Invoke-HostRequest {
    param($Session, [hashtable] $Request, [int] $TimeoutMilliseconds = 5000)

    $client = [IO.Pipes.NamedPipeClientStream]::new('.', $Session.PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        try {
            $client.Connect($TimeoutMilliseconds)
        } catch {
            throw "the pty host for session '$($Session.Name)' (pid $($Session.HostProcessId)) is not answering: $_"
        }
        $writer = [IO.StreamWriter]::new($client, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        $writer.WriteLine(($Request | ConvertTo-Json -Depth 5 -Compress))
        $reader = [IO.StreamReader]::new($client, [Text.UTF8Encoding]::new($false))
        $line = $reader.ReadLine()
        if (-not $line) { throw 'the pty host closed the connection without answering' }
        $response = $line | ConvertFrom-Json
        if (-not $response.ok) { throw "the pty host refused the request: $($response.error)" }
        return $response
    } finally {
        $client.Dispose()
    }
}

function Start-PtyApp {
    <#
    .SYNOPSIS
    Starts a program under a new pseudo console and returns a session to drive it.

    .EXAMPLE
    $session = Start-PtyApp -CommandLine 'pwsh -NoLogo -NoProfile' -Name shell

    .EXAMPLE
    $session = Start-PtyApp -CommandLine 'fzf' -Columns 100 -Rows 30
    #>
    [CmdletBinding()]
    param(
        # A command line, as a terminal would run it: 'nvim README.md', not a script block.
        [Parameter(Mandatory, Position = 0)] [string] $CommandLine,
        [string] $WorkingDirectory = $PWD.Path,
        [int] $Columns = 120,
        [int] $Rows = 30,
        # A label to find this session by later: Get-PtyApp -Name <name>.
        [string] $Name,
        # Keep every byte the program writes in <session>.raw, for diagnosing what it asked the
        # terminal for. Get-PtyApp reports the path.
        [switch] $RawLog,
        [int] $TimeoutSeconds = 30
    )

    $existing = try { Get-PtyApp -Name $Name } catch { $null }
    if ($Name -and $existing) {
        throw "a pty session named '$Name' is already running (host pid $($existing.HostProcessId)). Stop it first, or pick another name."
    }

    [void] (New-Item -ItemType Directory -Force -Path $script:SessionDirectory)
    $token = [guid]::NewGuid().ToString('N')
    $pipeName = "pty-harness-$token"
    $readyPath = Join-Path $script:SessionDirectory "$token.ready"
    $logPath = Join-Path $script:SessionDirectory "$token.log"
    $startPath = Join-Path $script:SessionDirectory "$token.start.json"
    $rawLogPath = if ($RawLog) { Join-Path $script:SessionDirectory "$token.raw" } else { '' }
    @{
        PipeName         = $pipeName
        CommandLine      = $CommandLine
        WorkingDirectory = $WorkingDirectory
        Columns          = $Columns
        Rows             = $Rows
        ReadyPath        = $readyPath
        LogPath          = $logPath
        RawLogPath       = $rawLogPath
    } | ConvertTo-Json | Set-Content -LiteralPath $startPath -Encoding utf8

    # Hidden, and with nothing redirected: a child only inherits the pseudo console's handles
    # when its parent's own standard handles are console handles (see PtyHost.ps1).
    $process = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NoLogo', '-File', $script:HostScript, '-StartFile', $startPath
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($process.HasExited) {
            $log = if (Test-Path -LiteralPath $logPath) { (Get-Content -Raw -LiteralPath $logPath) } else { '(no log)' }
            throw "the pty host exited before it was ready (exit code $($process.ExitCode)).`n$log"
        }
        if ((Get-Date) -gt $deadline) { throw "the pty host did not start within ${TimeoutSeconds}s" }
        Start-Sleep -Milliseconds 50
    }

    $session = [pscustomobject]@{
        PSTypeName       = 'PtyHarness.Session'
        Name             = $Name
        PipeName         = $pipeName
        HostProcess      = $process
        HostProcessId    = $process.Id
        ProcessId        = [int] (Get-Content -Raw -LiteralPath $readyPath).Trim()
        CommandLine      = $CommandLine
        WorkingDirectory = $WorkingDirectory
        Columns          = $Columns
        Rows             = $Rows
        StartTime        = $process.StartTime
        RecordPath       = Join-Path $script:SessionDirectory "$token.json"
        LogPath          = $logPath
        StartPath        = $startPath
        RawLogPath       = $rawLogPath
    }
    $record = $session | Select-Object Name, PipeName, HostProcessId, ProcessId, CommandLine, WorkingDirectory, Columns, Rows, RecordPath, LogPath, StartPath, RawLogPath
    $record | Add-Member -NotePropertyName StartTime -NotePropertyValue $session.StartTime.ToString('o')
    $record | ConvertTo-Json | Set-Content -LiteralPath $session.RecordPath -Encoding utf8
    return $session
}

function Get-PtyApp {
    <#
    .SYNOPSIS
    Returns pty sessions that are still running, including ones started by an earlier process.

    .EXAMPLE
    $session = Get-PtyApp -Name shell
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)] [string] $Name, [int] $HostProcessId)

    $sessions = @()
    if (Test-Path -LiteralPath $script:SessionDirectory) {
        # Only session records: the directory also holds <token>.start.json, the host's
        # parameters, whose shape is different.
        $records = Get-ChildItem -LiteralPath $script:SessionDirectory -Filter '*.json' |
            Where-Object { $_.Name -match '^[0-9a-f]{32}\.json$' }
        $sessions = foreach ($file in $records) {
            $record = try { Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json } catch { $null }
            if (-not $record) { [IO.File]::Delete($file.FullName); continue }
            $process = Get-Process -Id $record.HostProcessId -ErrorAction SilentlyContinue
            # Process ids get reused, so the start time decides whether this is still the host.
            $recorded = [datetime] $record.StartTime
            if (-not $process -or $process.StartTime.ToUniversalTime() -ne $recorded.ToUniversalTime()) {
                [IO.File]::Delete($file.FullName)
                continue
            }
            [pscustomobject]@{
                PSTypeName       = 'PtyHarness.Session'
                Name             = $record.Name
                PipeName         = $record.PipeName
                HostProcess      = $process
                HostProcessId    = $record.HostProcessId
                ProcessId        = $record.ProcessId
                CommandLine      = $record.CommandLine
                WorkingDirectory = $record.WorkingDirectory
                Columns          = $record.Columns
                Rows             = $record.Rows
                StartTime        = $process.StartTime
                RecordPath       = $file.FullName
                LogPath          = $record.LogPath
                StartPath        = $record.StartPath
                RawLogPath       = $record.RawLogPath
            }
        }
    }

    $matching = @($sessions | Where-Object {
        (-not $Name -or $_.Name -eq $Name) -and (-not $HostProcessId -or $_.HostProcessId -eq $HostProcessId)
    })
    if (($Name -or $HostProcessId) -and -not $matching) {
        $running = if ($sessions) { ($sessions | ForEach-Object { "$($_.HostProcessId)$(if ($_.Name) { " ($($_.Name))" })" }) -join ', ' } else { 'none' }
        throw "no pty session $(if ($Name) { "named '$Name'" } else { "hosted by $HostProcessId" }) is running. Running: $running."
    }
    return $matching
}

function Get-PtyScreen {
    <#
    .SYNOPSIS
    Returns the screen as the program has drawn it: text by default, or with its colours.

    .DESCRIPTION
    -As Text (the default) gives one string per row: the visible rows, or with -Scrollback
    everything the terminal still holds, oldest first.

    The other three keep the colours and attributes, which conhost's grid cannot (it has only
    legacy 4-bit attributes), and all cover the viewport only:

    - Vt    the screen as escape sequences, for a golden file or for replaying it somewhere else.
    - Html  a whole page, palette and default colours included, for looking at what was drawn.
    - Styled  one object per row, each holding runs of cells that share every attribute. This is
      the one to assert against; see Get-PtyStyleAt and Find-PtyText for narrower questions.

    .EXAMPLE
    Get-PtyScreen $session -NonEmpty

    .EXAMPLE
    (Get-PtyScreen $session -As Styled)[3].Runs | Where-Object Bold

    .EXAMPLE
    Get-PtyScreen $session -As Html | Set-Content screen.html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('PtyHarness.Session')] $Session,
        [ValidateSet('Text', 'Vt', 'Html', 'Styled')] [string] $As = 'Text',
        # Include what has scrolled out of view. Text only: the rest are the viewport.
        [switch] $Scrollback,
        [switch] $NonEmpty
    )
    process {
        if ($NonEmpty -and $As -ne 'Text') { throw "-NonEmpty only applies to -As Text." }
        if ($Scrollback -and $As -notin 'Text', 'Vt') {
            throw "-Scrollback doesn't apply to -As $As, which reads the viewport."
        }
        if ($As -eq 'Styled' -or $As -eq 'Html') {
            $response = Invoke-HostRequest -Session $Session -Request @{ op = 'styled'; row = -1 }
            if ($As -eq 'Styled') { return @($response.styledRows) }
            return ConvertTo-PtyHtmlDocument -Response $response
        }
        $response = Invoke-HostRequest -Session $Session -Request @{
            op = 'screen'; scrollback = [bool] $Scrollback; format = $As
        }
        if ($As -eq 'Vt') { return @($response.lines) -join "`n" }
        $lines = @($response.lines)
        if ($NonEmpty) { $lines = @($lines | Where-Object { $_.Trim() }) }
        return $lines
    }
}

function ConvertTo-PtyHtmlDocument {
    <#
    .SYNOPSIS
    Renders styled rows as a page a browser can show.

    .DESCRIPTION
    Built from the same runs as -As Styled rather than from libghostty's own HTML, for two
    reasons: that formatter emits the scrollback along with the viewport and can't be told not
    to, and it names palette colours as var(--vt-palette-N) while defining none of them. Here the
    colours are already resolved and inverse is already applied, so the markup says what it means.
    #>
    param($Response)

    $rows = foreach ($row in @($Response.styledRows)) {
        $line = [Text.StringBuilder]::new()
        foreach ($run in @($row.Runs)) {
            # Runs know the column they start at; the gaps are the blanks that were trimmed out.
            $column = [int] $run.Column
            if ($line.Length -lt $column) { [void] $line.Append(' ', $column - $line.Length) }
            [void] $line.Append((ConvertTo-PtyHtmlRun -Run $run -Response $Response))
        }
        $line.ToString()
    }

    return @"
<!doctype html>
<html><head><meta charset="utf-8"><title>pty screen</title>
<style>
body { margin: 0; padding: 1rem; background: $($Response.background.Hex); color: $($Response.foreground.Hex); }
pre { margin: 0; font: 14px/1.2 Consolas, monospace; }
</style></head>
<body><pre>$($rows -join "`n")</pre></body></html>
"@
}

function ConvertTo-PtyHtmlRun {
    param($Run, $Response)

    $text = [Net.WebUtility]::HtmlEncode($Run.Text)
    $style = @()
    # Only what differs from the terminal's own colours, so the markup stays readable.
    if ($Run.EffectiveForeground.Hex -ne $Response.foreground.Hex) { $style += "color:$($Run.EffectiveForeground.Hex)" }
    if ($Run.EffectiveBackground.Hex -ne $Response.background.Hex) { $style += "background-color:$($Run.EffectiveBackground.Hex)" }
    if ($Run.Bold) { $style += 'font-weight:bold' }
    if ($Run.Italic) { $style += 'font-style:italic' }
    if ($Run.Faint) { $style += 'opacity:0.6' }
    if ($Run.Invisible) { $style += 'visibility:hidden' }
    $decorations = @()
    if ($Run.Underline -ne 'None') { $decorations += 'underline' }
    if ($Run.Strikethrough) { $decorations += 'line-through' }
    if ($Run.Overline) { $decorations += 'overline' }
    if ($decorations) { $style += "text-decoration:$($decorations -join ' ')" }

    if (-not $style) { return $text }
    return "<span style=""$($style -join ';')"">$text</span>"
}

function Get-PtyStyleAt {
    <#
    .SYNOPSIS
    Returns the run of cells covering one position, with its colours and attributes.

    .DESCRIPTION
    Rows and columns are zero-based and count from the top-left of the viewport. Returns nothing
    when that position is past the end of what the program drew.

    .EXAMPLE
    (Get-PtyStyleAt $session -Row 0 -Column 4).EffectiveForeground.Hex
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory)] [int] $Row,
        [Parameter(Mandatory)] [int] $Column
    )
    # Only the row asked for is read, so this stays cheap enough to call in a loop.
    $response = Invoke-HostRequest -Session $Session -Request @{ op = 'styled'; row = $Row }
    $rows = @($response.styledRows)
    if (-not $rows) { return }
    foreach ($run in @($rows[0].Runs)) {
        if ($Column -ge $run.Column -and $Column -lt ($run.Column + $run.Text.Length)) { return $run }
    }
}

function Find-PtyText {
    <#
    .SYNOPSIS
    Finds text on the screen and says where it is - and, with -WithStyle, how it looks.

    .DESCRIPTION
    Matches a regular expression against each row of the viewport and returns one object per
    match: Row, Column, Text, and with -WithStyle the runs the match overlaps. A match that is
    drawn in one colour throughout has exactly one run.

    .EXAMPLE
    Find-PtyText $session 'error' -WithStyle | ForEach-Object { $_.Runs[0].EffectiveForeground.Hex }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [string] $Pattern,
        # Include the styled runs the match falls in.
        [switch] $WithStyle
    )
    $response = Invoke-HostRequest -Session $Session -Request @{ op = 'styled'; row = -1 }
    foreach ($row in @($response.styledRows)) {
        $runs = @($row.Runs)
        # Rebuild the row's text from its runs: each one knows the column it starts at, so the
        # gaps between them are the blanks that were trimmed out.
        $line = [Text.StringBuilder]::new()
        foreach ($run in $runs) {
            if ($line.Length -lt $run.Column) { [void] $line.Append(' ', $run.Column - $line.Length) }
            [void] $line.Append($run.Text)
        }
        foreach ($match in [regex]::Matches($line.ToString(), $Pattern)) {
            $result = [ordered]@{ Row = $row.Y; Column = $match.Index; Text = $match.Value }
            if ($WithStyle) {
                $last = $match.Index + $match.Length
                $result['Runs'] = @($runs | Where-Object {
                    $_.Column -lt $last -and ($_.Column + $_.Text.Length) -gt $match.Index
                })
            }
            [pscustomobject] $result
        }
    }
}

function Get-PtyInfo {
    <#
    .SYNOPSIS
    Reports the size of the terminal, the program's process id, and whether it has exited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('PtyHarness.Session')] $Session)
    process { return Invoke-HostRequest -Session $Session -Request @{ op = 'info' } }
}

function Send-PtyKeys {
    <#
    .SYNOPSIS
    Sends keys (and mouse events), then returns the screen once it has settled.

    .DESCRIPTION
    Keys use AutoHotkey v2's Send syntax, the same as ConsoleHarness; see the KeySpec module.
    Unlike a legacy console, everything here reaches the program as a byte stream, so mouse
    events work for any application that asks for them.

    .EXAMPLE
    Send-PtyKeys $session 'find{Enter}'

    .EXAMPLE
    Send-PtyKeys $session '{WheelDown 40 10 3}'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string[]] $Keys,
        [int] $SettleMilliseconds = 250
    )
    $events = [Collections.Generic.List[object]]::new()
    foreach ($spec in $Keys) { $events.AddRange([object[]] (ConvertFrom-KeySpec -Spec $spec)) }
    return Send-PtyBytes -Session $Session -Bytes (ConvertTo-PtyBytes -Events $events.ToArray()) -SettleMilliseconds $SettleMilliseconds
}

function Send-PtyText {
    <#
    .SYNOPSIS
    Types text verbatim: nothing in it is syntax.

    .EXAMPLE
    Send-PtyText $session 'C:\src\a,b{x}^y'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string[]] $Text,
        [int] $SettleMilliseconds = 250
    )
    $events = [Collections.Generic.List[object]]::new()
    foreach ($spec in $Text) { $events.AddRange([object[]] (ConvertFrom-KeySpec -Spec $spec -Literal)) }
    return Send-PtyBytes -Session $Session -Bytes (ConvertTo-PtyBytes -Events $events.ToArray()) -SettleMilliseconds $SettleMilliseconds
}

function Send-PtyBytes {
    <#
    .SYNOPSIS
    Sends raw bytes to the program, for sequences the key syntax doesn't cover.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [byte[]] $Bytes,
        [int] $SettleMilliseconds = 250
    )
    [void] (Invoke-HostRequest -Session $Session -Request @{ op = 'send'; bytes = [Convert]::ToBase64String($Bytes) })
    if ($SettleMilliseconds -gt 0) { Start-Sleep -Milliseconds $SettleMilliseconds }
    return Get-PtyScreen -Session $Session
}

function Wait-PtyText {
    <#
    .SYNOPSIS
    Waits until the screen matches a pattern, and returns it. Use it instead of sleeping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [string] $Pattern,
        [int] $TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $screen = Get-PtyScreen -Session $Session
        if ($screen -match $Pattern) { return $screen }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "timed out after ${TimeoutSeconds}s waiting for /$Pattern/. Screen was:`n$(($screen | Where-Object { $_.Trim() }) -join "`n")"
}

function Set-PtySize {
    <#
    .SYNOPSIS
    Resizes the terminal. The program is told, and redraws for the new size.

    .EXAMPLE
    Set-PtySize $session -Columns 80 -Rows 25
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory)] [int] $Columns,
        [Parameter(Mandatory)] [int] $Rows,
        [int] $SettleMilliseconds = 250
    )
    process {
        $response = Invoke-HostRequest -Session $Session -Request @{ op = 'resize'; columns = $Columns; rows = $Rows }
        if ($SettleMilliseconds -gt 0) { Start-Sleep -Milliseconds $SettleMilliseconds }
        return $response
    }
}

function Stop-PtyApp {
    <#
    .SYNOPSIS
    Stops the program and its host. Always run this, even after a failure.

    .EXAMPLE
    Stop-PtyApp -All
    #>
    [CmdletBinding(DefaultParameterSetName = 'Session')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Session')] [PSTypeName('PtyHarness.Session')] $Session,
        [Parameter(Mandatory, ParameterSetName = 'All')] [switch] $All
    )
    process {
        $targets = if ($All) { Get-PtyApp } else { @($Session) }
        foreach ($target in $targets) {
            # Ask first: the host closes the pseudo console, which is how a program is told its
            # terminal has gone.
            try { [void] (Invoke-HostRequest -Session $target -Request @{ op = 'stop' } -TimeoutMilliseconds 1000) } catch { }
            $process = Get-Process -Id $target.HostProcessId -ErrorAction SilentlyContinue
            if ($process) {
                if (-not $process.WaitForExit(2000)) { Stop-Process -Id $target.HostProcessId -Force -ErrorAction SilentlyContinue }
            }
            foreach ($path in $target.RecordPath, $target.LogPath, $target.StartPath, $target.RawLogPath) {
                if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Export-ModuleMember -Function Start-PtyApp, Get-PtyApp, Get-PtyScreen, Get-PtyStyleAt, Find-PtyText,
    Get-PtyInfo, Send-PtyKeys, Send-PtyText, Send-PtyBytes, Wait-PtyText, Set-PtySize, Stop-PtyApp
