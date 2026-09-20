# ConsoleHarness: drive an interactive console app (fzf, Neovim, a prompt) from a script and read
# what it drew, so terminal UIs can be tested without a human at the keyboard.
#
# How it works: the app runs in its own hidden console, and each call spawns a short-lived worker
# (ConsoleWorker.ps1) that attaches to that console with AttachConsole, reads the character grid
# with ReadConsoleOutputCharacter, and injects keys with WriteConsoleInput. conhost has already
# turned the app's VT output into that grid, so nothing here parses escape sequences, and input
# doesn't depend on window focus.
#
# Not for GUI apps, and not a terminal emulator: it sees the final rendering, not the byte stream.

$script:WorkerPath = Join-Path $PSScriptRoot 'ConsoleWorker.ps1'
# Sessions outlive the process that started them, so each one is recorded here and can be picked
# up again with Get-ConsoleApp. Screens live in the same place.
$script:SessionDirectory = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'console-harness')
# Key specifications are parsed in this process rather than in the worker, so a bad specification
# fails immediately with a useful message instead of as a worker exit code. The parser is its own
# module because it says nothing about consoles: a pty-based harness wants the same syntax.
Import-Module (Join-Path $PSScriptRoot '..' 'KeySpec' 'KeySpec.psd1') -ErrorAction Stop

function Start-ConsoleApp {
    <#
    .SYNOPSIS
    Starts a command in its own hidden console and returns a session to drive it.

    .EXAMPLE
    $session = Start-ConsoleApp -Command 'fzf' -WorkingDirectory C:\repo

    .EXAMPLE
    # The app keeps running after this process exits; -Name makes it easy to find again.
    Start-ConsoleApp -Command 'nvim README.md' -Name editor
    #>
    [CmdletBinding()]
    param(
        # PowerShell to run in the console, e.g. 'fzf' or '. $PROFILE; fdg'.
        [Parameter(Mandatory)] [string] $Command,
        [string] $WorkingDirectory = $PWD.Path,
        [int] $Width = 120,
        [int] $Height = 30,
        # Rows kept above the visible window, so Get-ConsoleScreen -Scrollback has something to
        # read. 'mode con:' can't do this: it sets the buffer height to the window height.
        [int] $BufferHeight = 1000,
        # Written to this file by the command, for whatever it produces on stdout.
        [string] $OutputPath,
        # A label to find this session by later: Get-ConsoleApp -Name <name>.
        [string] $Name
    )

    # Get-ConsoleApp throws when a name doesn't match, which here just means the name is free.
    $existing = try { Get-ConsoleApp -Name $Name } catch { $null }
    if ($Name -and $existing) {
        throw "a console app named '$Name' is already running (pid $($existing.Id)). Stop it first, or pick another name."
    }
    # Size through the API, not 'mode con:', which sets the buffer height to the window height and
    # so leaves no scrollback at all. Window first, then buffer: a window may not exceed its buffer.
    $prologue = "[Console]::SetWindowSize($Width, $Height); [Console]::SetBufferSize($Width, $([Math]::Max($BufferHeight, $Height))); " +
        "Set-Location -LiteralPath '$($WorkingDirectory -replace "'", "''")'"
    $body = if ($OutputPath) { "$Command | Out-File -LiteralPath '$($OutputPath -replace "'", "''")'" } else { $Command }
    # -EncodedCommand, because a command containing double quotes does not survive Start-Process's
    # argument quoting: '... { "item " + $_ }' arrived as a call to Get-Item.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$prologue; $body"))
    $process = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NoLogo', '-EncodedCommand', $encoded
    )
    $session = New-SessionObject -Process $process -Name $Name -Command $Command -WorkingDirectory $WorkingDirectory -OutputPath $OutputPath
    Save-Session -Session $session
    return $session
}

function Get-ConsoleApp {
    <#
    .SYNOPSIS
    Returns sessions that are still running, including ones started by an earlier process.

    .DESCRIPTION
    A console app outlives the PowerShell process that started it, so a session can be picked up
    later: this rebuilds it from the record Start-ConsoleApp wrote. Records whose process has gone
    (or whose id has been reused by something else) are pruned as they're found.

    .EXAMPLE
    Get-ConsoleApp                       # everything still running

    .EXAMPLE
    $session = Get-ConsoleApp -Name editor
    Send-ConsoleKeys $session ':w{Enter}'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Name,
        [int] $Id
    )

    if (-not (Test-Path -LiteralPath $script:SessionDirectory)) { $sessions = @() } else {
        # Only the session records: the directory also holds <pid>.state.json and screens.
        $records = Get-ChildItem -LiteralPath $script:SessionDirectory -Filter '*.json' |
            Where-Object { $_.Name -match '^\d+\.json$' }
        $sessions = foreach ($file in $records) {
            $record = try { Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json } catch { $null }
            if (-not $record) { [IO.File]::Delete($file.FullName); continue }
            $process = Get-Process -Id $record.Id -ErrorAction SilentlyContinue
            # Ids get reused, so the start time decides whether this is still the same process.
            # ConvertFrom-Json hands back a DateTime for an ISO-8601 string, so compare as dates:
            # comparing against a round-trip string would take every record for a stale one.
            $recorded = [datetime] $record.StartTime
            if (-not $process -or $process.StartTime.ToUniversalTime() -ne $recorded.ToUniversalTime()) {
                [IO.File]::Delete($file.FullName)
                if (Test-Path -LiteralPath $record.ScreenPath) { [IO.File]::Delete($record.ScreenPath) }
                continue
            }
            New-SessionObject -Process $process -Name $record.Name -Command $record.Command `
                -WorkingDirectory $record.WorkingDirectory -OutputPath $record.OutputPath
        }
    }

    $matching = @($sessions | Where-Object {
        (-not $Name -or $_.Name -eq $Name) -and (-not $Id -or $_.Id -eq $Id)
    })
    if (($Name -or $Id) -and -not $matching) {
        $running = if ($sessions) { ($sessions | ForEach-Object { "$($_.Id)$(if ($_.Name) { " ($($_.Name))" })" }) -join ', ' } else { 'none' }
        throw "no console app $(if ($Name) { "named '$Name'" } else { "with id $Id" }) is running. Running: $running."
    }
    return $matching
}

function New-SessionObject {
    param($Process, [string] $Name, [string] $Command, [string] $WorkingDirectory, [string] $OutputPath)
    return [pscustomobject]@{
        PSTypeName       = 'ConsoleHarness.Session'
        Process          = $Process
        Id               = $Process.Id
        Name             = $Name
        Command          = $Command
        WorkingDirectory = $WorkingDirectory
        OutputPath       = $OutputPath
        StartTime        = $Process.StartTime
        ScreenPath       = [IO.Path]::Combine($script:SessionDirectory, "$($Process.Id).screen.txt")
        StatePath        = [IO.Path]::Combine($script:SessionDirectory, "$($Process.Id).state.json")
        RecordPath       = [IO.Path]::Combine($script:SessionDirectory, "$($Process.Id).json")
    }
}

function Save-Session {
    param($Session)
    [void] (New-Item -ItemType Directory -Force -Path $script:SessionDirectory)
    $record = @{
        Id               = $Session.Id
        Name             = $Session.Name
        Command          = $Session.Command
        WorkingDirectory = $Session.WorkingDirectory
        OutputPath       = $Session.OutputPath
        # Round-trip format: this is what tells a reused id from the original process.
        StartTime        = $Session.StartTime.ToString('o')
        ScreenPath       = $Session.ScreenPath
    }
    [IO.File]::WriteAllText($Session.RecordPath, (ConvertTo-Json -InputObject $record -Compress))
}

function Get-ConsoleScreen {
    <#
    .SYNOPSIS
    Returns the console's lines, as the app has drawn them: the visible window by default, or any
    part of the buffer behind it.

    .EXAMPLE
    Get-ConsoleScreen $session                      # what's on screen now

    .EXAMPLE
    Get-ConsoleScreen $session -Scrollback          # the whole buffer, oldest row first

    .EXAMPLE
    Get-ConsoleScreen $session -FromRow 120 -Rows 10
    #>
    [CmdletBinding(DefaultParameterSetName = 'Window')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session,
        # The whole buffer, including what has scrolled off the top of the window.
        [Parameter(ParameterSetName = 'Scrollback')] [switch] $Scrollback,
        # A range of buffer rows. Row 0 is the oldest line the buffer still holds.
        [Parameter(Mandatory, ParameterSetName = 'Range')] [int] $FromRow,
        [Parameter(ParameterSetName = 'Range')] [int] $Rows = 0,
        # Drop blank lines, which is usually what you want for matching.
        [switch] $NonEmpty
    )
    process {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
        $read = switch ($PSCmdlet.ParameterSetName) {
            'Scrollback' { @{ mode = 'buffer' } }
            'Range' { @{ mode = 'range'; row = $FromRow; rows = $Rows } }
            default { @{ mode = 'window' } }
        }
        [void] (Invoke-Worker -Session $Session -Read $read)
        $lines = @(Get-Content -LiteralPath $Session.ScreenPath -ErrorAction SilentlyContinue)
        if ($NonEmpty) { $lines = @($lines | Where-Object { $_.Trim() }) }
        return $lines
    }
}

function Get-ConsoleInfo {
    <#
    .SYNOPSIS
    Reports the console's size, where the view sits in the buffer, the cursor, and what kind of
    input the app is listening for.

    .DESCRIPTION
    WindowTop is the scroll position: how far down the buffer the visible window starts.
    VtInput and MouseInput say which mouse delivery the app understands, which is what
    Send-ConsoleKeys picks between (MouseDelivery reports the choice).

    .EXAMPLE
    (Get-ConsoleInfo $session).WindowTop
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session)
    process {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
        return Invoke-Worker -Session $Session
    }
}

function Set-ConsoleSize {
    <#
    .SYNOPSIS
    Resizes the console, which the app sees as a resize event and redraws for.

    .EXAMPLE
    Set-ConsoleSize $session -Width 80 -Height 25    # does the app reflow?
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session,
        [int] $Width = 0,
        [int] $Height = 0,
        # Rows of scrollback to keep. Defaults to leaving the buffer as it is.
        [int] $BufferHeight = 0,
        # How long to let the app redraw before reading the screen back.
        [int] $SettleMilliseconds = 250
    )
    process {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
        return Invoke-Worker -Session $Session -SettleMilliseconds $SettleMilliseconds `
            -Resize @{ width = $Width; height = $Height; bufferHeight = $BufferHeight }
    }
}

function Move-ConsoleView {
    <#
    .SYNOPSIS
    Scrolls the visible window through the buffer, as dragging the scrollbar would.

    .DESCRIPTION
    This moves the view only; the app isn't told and doesn't care. New output from the app scrolls
    the view back to the bottom, as it does for a person scrolling a terminal.

    .EXAMPLE
    Move-ConsoleView $session -Lines -20      # back 20 rows

    .EXAMPLE
    Move-ConsoleView $session -Start          # the oldest rows the buffer holds
    #>
    [CmdletBinding(DefaultParameterSetName = 'Lines')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session,
        # Negative scrolls back, positive forward.
        [Parameter(Mandatory, ParameterSetName = 'Lines')] [int] $Lines,
        # An absolute buffer row for the top of the window.
        [Parameter(Mandatory, ParameterSetName = 'Top')] [int] $Top,
        # Not -Home: $Home is an automatic variable, and a parameter can't shadow it.
        [Parameter(Mandatory, ParameterSetName = 'Start')] [switch] $Start,
        [Parameter(Mandatory, ParameterSetName = 'End')] [switch] $End
    )
    process {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
        $view = switch ($PSCmdlet.ParameterSetName) {
            'Lines' { @{ mode = 'lines'; lines = $Lines } }
            'Top' { @{ mode = 'top'; top = $Top } }
            'Start' { @{ mode = 'home' } }
            'End' { @{ mode = 'end' } }
        }
        return Invoke-Worker -Session $Session -View $view
    }
}

function Send-ConsoleKeys {
    <#
    .SYNOPSIS
    Sends keys, then returns the screen after they've been processed.

    .DESCRIPTION
    Keys use AutoHotkey v2's Send syntax: text is typed literally, '{Enter}' and friends are keys,
    '^' '!' '+' hold Ctrl, Alt and Shift for the next key, and '{^}' '{{}' type those characters.
    A leading '{Raw}' makes the rest of the string literal; Send-ConsoleText does that for a whole
    string. Several arguments are sent one after another, with nothing inserted between them.

    .EXAMPLE
    Send-ConsoleKeys $session '^s'
    Send-ConsoleKeys $session 'workloads{Enter}'
    Send-ConsoleKeys $session ':qa{!}{Enter}'   # '!' is Alt, so type it as '{!}'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('ConsoleHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string[]] $Keys,
        # How long to let the app redraw before reading the screen.
        [int] $SettleMilliseconds = 250,
        # How mouse events are delivered. Auto reads the app's input mode and picks SGR sequences
        # for a virtual-terminal app, console records otherwise.
        [ValidateSet('Auto', 'Record', 'Vt')] [string] $MouseDelivery = 'Auto'
    )
    return Send-KeyEvents -Session $Session -SettleMilliseconds $SettleMilliseconds -MouseDelivery $MouseDelivery `
        -KeyEvents (ConvertTo-KeyEvents -Specs $Keys)
}

function Send-ConsoleText {
    <#
    .SYNOPSIS
    Types text verbatim, then returns the screen after it's been processed.

    .DESCRIPTION
    Nothing here is syntax: braces, '^', '!', '+' and commas are all just characters, so this is
    what to use for text that came from a variable, a path, or the app's own output. (A newline
    still means Enter and a tab still means Tab, as they would if the text were typed.)

    .EXAMPLE
    Send-ConsoleText $session '{Enter}'            # types the word, doesn't press the key

    .EXAMPLE
    Send-ConsoleText $session "$PWD\a,b^c"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('ConsoleHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string[]] $Text,
        # How long to let the app redraw before reading the screen.
        [int] $SettleMilliseconds = 250
    )
    return Send-KeyEvents -Session $Session -SettleMilliseconds $SettleMilliseconds `
        -KeyEvents (ConvertTo-KeyEvents -Specs $Text -Literal)
}

function ConvertTo-KeyEvents {
    param([string[]] $Specs, [switch] $Literal)
    # A list, not @(foreach ...): ConvertFrom-KeySpec returns each specification's events as one
    # array object, which a collecting @() would keep nested.
    $events = [Collections.Generic.List[object]]::new()
    foreach ($spec in $Specs) { $events.AddRange([object[]] (ConvertFrom-KeySpec -Spec $spec -Literal:$Literal)) }
    return , $events.ToArray()
}

function Send-KeyEvents {
    param($Session, [object[]] $KeyEvents, [int] $SettleMilliseconds, [string] $MouseDelivery = 'Auto')
    if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
    $state = Invoke-Worker -Session $Session -KeyEvents $KeyEvents -SettleMilliseconds $SettleMilliseconds -MouseDelivery $MouseDelivery
    # An app listening for neither kind of mouse input silently swallows it, which is a confusing
    # way to spend an afternoon.
    if (($KeyEvents | Where-Object { $_.Type -eq 'Mouse' }) -and -not $state.VtInput -and -not $state.MouseInput) {
        Write-Warning "the app (pid $($Session.Id)) has neither virtual-terminal nor mouse input enabled (mode $($state.InputMode)), so it will ignore mouse events."
    }
    return @(Get-Content -LiteralPath $Session.ScreenPath -ErrorAction SilentlyContinue)
}

function Wait-ConsoleText {
    <#
    .SYNOPSIS
    Waits until the screen contains a pattern, and returns the screen. Use it instead of sleeping.

    .EXAMPLE
    Wait-ConsoleText $session 'Files> '
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('ConsoleHarness.Session')] $Session,
        # Regular expression matched against each line.
        [Parameter(Mandatory, Position = 1)] [string] $Pattern,
        [int] $TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) exited while waiting for /$Pattern/" }
        $screen = Get-ConsoleScreen -Session $Session
        if ($screen -match $Pattern) { return $screen }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "timed out after ${TimeoutSeconds}s waiting for /$Pattern/. Screen was:`n$(($screen | Where-Object { $_.Trim() }) -join "`n")"
}

function Stop-ConsoleApp {
    <#
    .SYNOPSIS
    Stops the app (if it's still running) and cleans up. Always run this, even after a failure.

    .DESCRIPTION
    The whole process tree goes, not just the PowerShell wrapper: the app itself is a child of it
    (and with mise's shims, a grandchild), and killing only the wrapper leaves it running in a
    console nobody is attached to any more.

    .EXAMPLE
    Stop-ConsoleApp $session

    .EXAMPLE
    Stop-ConsoleApp -All      # everything this module has left running
    #>
    [CmdletBinding(DefaultParameterSetName = 'Session')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Session')] [PSTypeName('ConsoleHarness.Session')] $Session,
        [Parameter(Mandatory, ParameterSetName = 'All')] [switch] $All
    )
    process {
        $targets = if ($All) { Get-ConsoleApp } else { @($Session) }
        foreach ($target in $targets) {
            if (-not $target.Process.HasExited) { Stop-ProcessTree -Id $target.Id }
            foreach ($path in $target.ScreenPath, $target.StatePath, $target.RecordPath) {
                if ($path -and (Test-Path -LiteralPath $path)) { [IO.File]::Delete($path) }
            }
        }
    }
}

function Stop-ProcessTree {
    param([int] $Id)
    # Children first: killing the parent first would reparent them and leave them running.
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -Id ([int] $child.ProcessId)
    }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Invoke-Worker {
    <#
    .SYNOPSIS
    Runs one worker round trip: resize, scroll, send input, wait, read. Returns the console state.
    #>
    param(
        $Session,
        [object[]] $KeyEvents = @(),
        [int] $SettleMilliseconds = 0,
        [hashtable] $Resize,
        [hashtable] $View,
        [hashtable] $Read,
        [ValidateSet('Auto', 'Record', 'Vt')] [string] $MouseDelivery = 'Auto'
    )
    $request = @{
        settleMilliseconds = $SettleMilliseconds
        mouseDelivery      = $MouseDelivery.ToLowerInvariant()
        events             = @($KeyEvents)
    }
    if ($Resize) { $request['resize'] = $Resize }
    if ($View) { $request['view'] = $View }
    if ($Read) { $request['read'] = $Read }

    # The request goes through a file: a command line would need a delimiter, and any delimiter is
    # a character that then can't be typed (a comma-joined list used to swallow commas in text).
    $requestPath = [IO.Path]::Combine($script:SessionDirectory, "$($Session.Id).request.json")
    [void] (New-Item -ItemType Directory -Force -Path $script:SessionDirectory)
    # -Depth keeps ConvertTo-Json from truncating longer event sequences.
    [IO.File]::WriteAllText($requestPath, (ConvertTo-Json -InputObject $request -Depth 5 -Compress))
    $arguments = @('-NoProfile', '-NoLogo', '-File', $script:WorkerPath,
        '-TargetPid', $Session.Id, '-ScreenPath', $Session.ScreenPath,
        '-StatePath', $Session.StatePath, '-RequestPath', $requestPath)
    try {
        $errors = & pwsh @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "console worker failed (exit code $LASTEXITCODE): $(($errors | ForEach-Object { "$_" }) -join ' ')"
        }
        return (Get-Content -Raw -LiteralPath $Session.StatePath | ConvertFrom-Json)
    } finally {
        if (Test-Path -LiteralPath $requestPath) { [IO.File]::Delete($requestPath) }
    }
}

Export-ModuleMember -Function Start-ConsoleApp, Get-ConsoleApp, Get-ConsoleScreen, Get-ConsoleInfo,
    Set-ConsoleSize, Move-ConsoleView, Send-ConsoleKeys, Send-ConsoleText, Wait-ConsoleText, Stop-ConsoleApp
