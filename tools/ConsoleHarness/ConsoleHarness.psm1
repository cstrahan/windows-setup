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
# Key specifications are parsed here rather than in the worker, so a bad specification fails
# immediately with a useful message instead of as a worker exit code.
. (Join-Path $PSScriptRoot 'KeySpec.ps1')

function Start-ConsoleApp {
    <#
    .SYNOPSIS
    Starts a command in its own hidden console and returns a session to drive it.

    .EXAMPLE
    $session = Start-ConsoleApp -Command 'fzf' -WorkingDirectory C:\repo
    #>
    [CmdletBinding()]
    param(
        # PowerShell to run in the console, e.g. 'fzf' or '. $PROFILE; fdg'.
        [Parameter(Mandatory)] [string] $Command,
        [string] $WorkingDirectory = $PWD.Path,
        [int] $Width = 120,
        [int] $Height = 30,
        # Written to this file by the command, for whatever it produces on stdout.
        [string] $OutputPath
    )

    $prologue = "mode con: cols=$Width lines=$Height | Out-Null; Set-Location -LiteralPath '$($WorkingDirectory -replace "'", "''")'"
    $body = if ($OutputPath) { "$Command | Out-File -LiteralPath '$($OutputPath -replace "'", "''")'" } else { $Command }
    $process = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NoLogo', '-Command', "$prologue; $body"
    )
    return [pscustomobject]@{
        PSTypeName  = 'ConsoleHarness.Session'
        Process     = $process
        Id          = $process.Id
        OutputPath  = $OutputPath
        ScreenPath  = [IO.Path]::Combine([IO.Path]::GetTempPath(), "console-harness-$($process.Id).txt")
    }
}

function Get-ConsoleScreen {
    <#
    .SYNOPSIS
    Returns the console's visible lines, as the app has drawn them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session,
        # Drop blank lines, which is usually what you want for matching.
        [switch] $NonEmpty
    )
    process {
        if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
        Invoke-Worker -Session $Session
        $lines = @(Get-Content -LiteralPath $Session.ScreenPath -ErrorAction SilentlyContinue)
        if ($NonEmpty) { $lines = @($lines | Where-Object { $_.Trim() }) }
        return $lines
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
        [int] $SettleMilliseconds = 250
    )
    return Send-KeyEvents -Session $Session -SettleMilliseconds $SettleMilliseconds `
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
    param($Session, [object[]] $KeyEvents, [int] $SettleMilliseconds)
    if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
    Invoke-Worker -Session $Session -KeyEvents $KeyEvents -SettleMilliseconds $SettleMilliseconds
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
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] [PSTypeName('ConsoleHarness.Session')] $Session)
    process {
        if (-not $Session.Process.HasExited) { Stop-Process -Id $Session.Id -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Session.ScreenPath) { [IO.File]::Delete($Session.ScreenPath) }
    }
}

function Invoke-Worker {
    param(
        $Session,
        [object[]] $KeyEvents = @(),
        [int] $SettleMilliseconds = 250
    )
    $arguments = @('-NoProfile', '-NoLogo', '-File', $script:WorkerPath,
        '-TargetPid', $Session.Id, '-ScreenPath', $Session.ScreenPath,
        '-SettleMilliseconds', $SettleMilliseconds)
    # The events go through a file: a command line would need a delimiter, and any delimiter is a
    # character that then can't be typed (a comma-joined list used to swallow commas in text).
    $eventPath = $null
    if ($KeyEvents.Count) {
        $eventPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "console-harness-keys-$($Session.Id).json")
        # -Depth keeps ConvertTo-Json from truncating longer key sequences.
        [IO.File]::WriteAllText($eventPath, (ConvertTo-Json -InputObject $KeyEvents -Depth 3 -Compress))
        $arguments += @('-KeyEventPath', $eventPath)
    }
    try {
        $errors = & pwsh @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "console worker failed (exit code $LASTEXITCODE): $(($errors | ForEach-Object { "$_" }) -join ' ')"
        }
    } finally {
        if ($eventPath -and (Test-Path -LiteralPath $eventPath)) { [IO.File]::Delete($eventPath) }
    }
}

Export-ModuleMember -Function Start-ConsoleApp, Get-ConsoleScreen, Send-ConsoleKeys, Send-ConsoleText, Wait-ConsoleText, Stop-ConsoleApp
