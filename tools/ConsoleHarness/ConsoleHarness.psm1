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
    Each element is either a key name (enter, tab, esc, backspace, space, up, down, left, right,
    home, end, pageup, pagedown, delete), a ctrl-<letter> or alt-<letter> chord, or literal text.

    .EXAMPLE
    Send-ConsoleKeys $session 'ctrl-s'
    Send-ConsoleKeys $session 'workloads', 'enter'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [PSTypeName('ConsoleHarness.Session')] $Session,
        [Parameter(Mandatory, Position = 1)] [string[]] $Keys,
        # How long to let the app redraw before reading the screen.
        [int] $SettleMilliseconds = 250
    )
    if ($Session.Process.HasExited) { throw "the console app (pid $($Session.Id)) has exited" }
    Invoke-Worker -Session $Session -Keys ($Keys -join ',') -SettleMilliseconds $SettleMilliseconds
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
        [string] $Keys = '',
        [int] $SettleMilliseconds = 250
    )
    $arguments = @('-NoProfile', '-NoLogo', '-File', $script:WorkerPath,
        '-TargetPid', $Session.Id, '-ScreenPath', $Session.ScreenPath,
        '-SettleMilliseconds', $SettleMilliseconds)
    if ($Keys) { $arguments += @('-Keys', $Keys) }
    $errors = & pwsh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "console worker failed (exit code $LASTEXITCODE): $(($errors | ForEach-Object { "$_" }) -join ' ')"
    }
}

Export-ModuleMember -Function Start-ConsoleApp, Get-ConsoleScreen, Send-ConsoleKeys, Wait-ConsoleText, Stop-ConsoleApp
