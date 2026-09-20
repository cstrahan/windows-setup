# ConPTY interop: start a program attached to a pseudo console and get its byte streams.
#
# Windows' pseudo console (Windows 10 1809+) is what a terminal emulator uses: the program thinks
# it has a console, and we get the VT stream it draws with, rather than a rendered character grid.
# That's the whole difference from ConsoleHarness, which reads conhost's grid instead.
#
# Which console host serves the pty is the thing that matters here. kernel32's CreatePseudoConsole
# binds to the machine's own conhost - 10.0.19041.1 on this laptop, from 2020 - which has no mouse
# plumbing at all: a client asking for mouse gets nothing, and injected reports produce nothing.
# Microsoft ships a current one for exactly this case, as the MIT-licensed
# Microsoft.Windows.Console.ConPTY package (conpty.dll plus OpenConsole.exe, built from
# microsoft/terminal). The pty-harness workload fetches it into lib\, and this prefers it.
#
# That is also what node-pty does, and so VS Code: it vendors the same two binaries and picks
# between kernel32 and conpty.dll with a `useConptyDll` flag. Its default is still kernel32, so
# anything using node-pty as it comes has the same gap.
#
# Dot-source this; it defines Start-PtyProcess, Resize-PtyProcess and Stop-PtyProcess.

if (-not ('PtyHarness.Native' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'PtyNative.cs')
}

$script:ConptyDirectory = Join-Path $PSScriptRoot 'lib'

function Get-ConptyLibraryPath {
    <#
    .SYNOPSIS
    Returns the redistributable conpty.dll if it is present and usable, otherwise $null.

    .DESCRIPTION
    conpty.dll looks for OpenConsole.exe next to itself, then in an architecture subdirectory,
    and if it finds neither it falls back to the inbox conhost (winconpty.cpp, _ConsoleHostPath).
    That fallback is silent and would cost us mouse, so both files are required here rather than
    just the library.

    $env:PTYHARNESS_CONPTY_DLL overrides the location.
    #>
    [CmdletBinding()]
    param()

    $library = if ($env:PTYHARNESS_CONPTY_DLL) { $env:PTYHARNESS_CONPTY_DLL } else { Join-Path $script:ConptyDirectory 'conpty.dll' }
    if (-not (Test-Path -LiteralPath $library)) { return $null }
    # Not $host: that is an automatic variable.
    $consoleHostExe = Join-Path (Split-Path -Parent $library) 'OpenConsole.exe'
    if (-not (Test-Path -LiteralPath $consoleHostExe)) { return $null }
    return $library
}

function Initialize-Conpty {
    <#
    .SYNOPSIS
    Loads conpty.dll so that PtyNative.cs's [DllImport("conpty.dll")] resolves to our copy.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    if ($script:ConptyLoaded) { return }
    # Loading by full path puts the module in the process under its plain name, which is what the
    # bare DllImport then finds; lib\ is on no search path. (Ghostty.ps1 loads wasmtime the same
    # way.) Loading the library is also what fixes OpenConsole's directory: conpty.dll resolves
    # the host relative to its own module path, so it finds the one we fetched beside it.
    [void] [Runtime.InteropServices.NativeLibrary]::Load($Path)
    $script:ConptyLoaded = $true
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
        # Conpty is the redistributable host from lib\ and handles mouse; Inbox is whatever
        # kernel32's CreatePseudoConsole gives us, which here forwards none. Auto takes Conpty
        # when the workload has fetched it.
        [ValidateSet('Auto', 'Conpty', 'Inbox')] [string] $ConsoleHost = 'Auto'
    )
    $library = if ($ConsoleHost -ne 'Inbox') { Get-ConptyLibraryPath } else { $null }
    if ($ConsoleHost -eq 'Conpty' -and -not $library) {
        throw "conpty.dll and OpenConsole.exe were not found in $script:ConptyDirectory. The pty-harness workload fetches them: apply configuration\workloads\pty-harness.dsc.yaml (it needs no elevation)."
    }
    if ($library) { Initialize-Conpty -Path $library }

    $pty = [PtyHarness.Native]::Start($CommandLine, $WorkingDirectory, [short] $Columns, [short] $Rows, [bool] $library)
    $description = if ($library) { $library } else { 'inbox' }
    Add-Member -InputObject $pty -NotePropertyName ConsoleHost -NotePropertyValue $description -Force
    return $pty
}

function Resize-PtyProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty, [Parameter(Mandatory)] [int] $Columns, [Parameter(Mandatory)] [int] $Rows)
    [PtyHarness.Native]::Resize($Pty, [short] $Columns, [short] $Rows)
}

function Test-PtyProcessExited {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pty)
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
    [PtyHarness.Native]::Stop($Pty)
}
