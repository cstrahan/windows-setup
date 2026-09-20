# ConPTY interop: start a program attached to a pseudo console and get its byte streams.
#
# Windows' pseudo console (Windows 10 1809+) is what a terminal emulator uses: the program thinks
# it has a console, and we get the VT stream it draws with, rather than a rendered character grid.
# That's the whole difference from ConsoleHarness, which reads conhost's grid instead.
#
# Two hosts are possible. CreatePseudoConsole uses the machine's inbox conhost, which on Windows
# 10 has no mouse plumbing; Windows Terminal ships OpenConsole.exe and hosts its pty with that,
# which is why mouse works there. Start-PtyProcess prefers OpenConsole when it can be found.
#
# Dot-source this; it defines Start-PtyProcess, Resize-PtyProcess and Stop-PtyProcess.

# The interop lives in .cs files next to this one and compiles as one assembly: PtyNativeOpenConsole
# needs the structs in PtyNative, and Add-Type can only see types from other files compiled with it.
if (-not ('PtyHarness.Native' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'PtyNative.cs'), (Join-Path $PSScriptRoot 'PtyNativeOpenConsole.cs')
}

function Get-OpenConsolePath {
    <#
    .SYNOPSIS
    Returns a runnable OpenConsole.exe, copying Windows Terminal's out of its package if needed.

    .DESCRIPTION
    Windows Terminal ships the console host that knows how to do mouse, but it lives in the
    package directory, where Windows refuses to execute it for anyone outside the package
    ("Access is denied"). So it is copied next to the harness and run from there. The copy is
    refreshed when Terminal's version changes, and never committed - it is Microsoft's binary,
    already on this machine.

    $env:PTYHARNESS_CONSOLE_HOST overrides all of this.
    #>
    [CmdletBinding()]
    param()

    if ($env:PTYHARNESS_CONSOLE_HOST) { return $env:PTYHARNESS_CONSOLE_HOST }
    if ($script:OpenConsolePath) { return $script:OpenConsolePath }

    # Appx doesn't load in PowerShell 7 ("Operation is not supported on this platform"), so ask
    # Windows PowerShell, which is always there. Listing WindowsApps directly needs permissions an
    # ordinary user hasn't got.
    $installed = powershell.exe -NoProfile -Command "(Get-AppxPackage Microsoft.WindowsTerminal | Sort-Object Version | Select-Object -Last 1).InstallLocation" 2>$null
    if (-not $installed) { return $null }
    $source = Join-Path $installed.Trim() 'OpenConsole.exe'
    if (-not (Test-Path -LiteralPath $source)) { return $null }

    $local = Join-Path (Join-Path $PSScriptRoot 'lib') 'OpenConsole.exe'
    $sourceVersion = (Get-Item -LiteralPath $source).VersionInfo.FileVersion
    $localVersion = if (Test-Path -LiteralPath $local) { (Get-Item -LiteralPath $local).VersionInfo.FileVersion } else { $null }
    if ($localVersion -ne $sourceVersion) {
        [void] (New-Item -ItemType Directory -Force -Path (Split-Path -Parent $local))
        Copy-Item -LiteralPath $source -Destination $local -Force
    }
    $script:OpenConsolePath = $local
    return $local
}

function Start-PtyProcess {
    <#
    .SYNOPSIS
    Starts a command attached to a new pseudo console.

    .EXAMPLE
    $pty = Start-PtyProcess -CommandLine 'pwsh -NoLogo' -Columns 120 -Rows 30
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CommandLine,
        [string] $WorkingDirectory = $PWD.Path,
        [int] $Columns = 120,
        [int] $Rows = 30,
        # OpenConsole is Windows Terminal's host and handles mouse; Inbox is whatever
        # CreatePseudoConsole gives us. Auto takes OpenConsole when it can be found.
        [ValidateSet('Auto', 'OpenConsole', 'Inbox')] [string] $ConsoleHost = 'Auto'
    )
    $hostPath = if ($ConsoleHost -ne 'Inbox') { Get-OpenConsolePath } else { $null }
    if ($ConsoleHost -eq 'OpenConsole' -and -not $hostPath) {
        throw 'OpenConsole.exe was not found. It ships with Windows Terminal; set $env:PTYHARNESS_CONSOLE_HOST to point at one.'
    }
    if ($hostPath) {
        $pty = [PtyHarness.OpenConsoleHost]::Start($hostPath, $CommandLine, $WorkingDirectory, [short] $Columns, [short] $Rows)
        Add-Member -InputObject $pty -NotePropertyName ConsoleHost -NotePropertyValue $hostPath -Force
        return $pty
    }
    $pty = [PtyHarness.Native]::Start($CommandLine, $WorkingDirectory, [short] $Columns, [short] $Rows)
    Add-Member -InputObject $pty -NotePropertyName ConsoleHost -NotePropertyValue 'inbox' -Force
    return $pty
}

function Resize-PtyProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty, [Parameter(Mandatory)] [int] $Columns, [Parameter(Mandatory)] [int] $Rows)
    # A hosted pty is resized by a packet down its signal pipe; ResizePseudoConsole only knows
    # about consoles the kernel32 path created.
    if ($Pty -is [PtyHarness.HostedPty]) {
        [PtyHarness.OpenConsoleHost]::Resize($Pty, [short] $Columns, [short] $Rows)
    } else {
        [PtyHarness.Native]::Resize($Pty, [short] $Columns, [short] $Rows)
    }
}

function Test-PtyProcessExited {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty)
    if ($Pty -is [PtyHarness.HostedPty]) { return [PtyHarness.OpenConsoleHost]::HasExited($Pty) }
    return [PtyHarness.Native]::HasExited($Pty)
}

function Stop-PtyProcessTree {
    param([int] $Id)
    # Children first, or killing the parent reparents them and they keep running. The program we
    # start is often a shell that then runs the thing under test, so the tree matters.
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)) {
        Stop-PtyProcessTree -Id ([int] $child.ProcessId)
    }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

function Stop-PtyProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty)
    if ($Pty.ProcessId) { Stop-PtyProcessTree -Id $Pty.ProcessId }
    if ($Pty -is [PtyHarness.HostedPty]) {
        [PtyHarness.OpenConsoleHost]::Stop($Pty)
    } else {
        [PtyHarness.Native]::Stop($Pty)
    }
}
