# The resident half of the pty harness: owns a pseudo console, feeds everything the program
# writes into libghostty-vt, and answers questions about the result over a named pipe.
#
# Why a resident process at all: a pseudo console's byte stream belongs to whoever created it.
# Unlike ConsoleHarness, where any process can attach to a console and read the grid conhost
# keeps, nobody else can reconstruct this state later. So one process holds it for the life of
# the session, and the cmdlets are thin clients.
#
# This process must NOT have its standard handles redirected. A child attached to a pseudo
# console only gets the console's handles when the parent's own are console handles; when the
# parent's stdout is a file or a pipe, the child inherits that instead and its output never
# reaches us. Start it hidden (it gets its own console) and let it log to a file, never to stdout.
[CmdletBinding()]
param(
    # Everything comes from a file: a command line with quotes in it does not survive being
    # passed as a process argument (Start-Process rewrites the quoting), and the command is
    # exactly the sort of string that has quotes in it.
    [Parameter(Mandatory)] [string] $StartFile
)

$ErrorActionPreference = 'Stop'

$start = Get-Content -Raw -LiteralPath $StartFile | ConvertFrom-Json
$PipeName = $start.PipeName
$CommandLine = $start.CommandLine
$WorkingDirectory = $start.WorkingDirectory
$Columns = [int] $start.Columns
$Rows = [int] $start.Rows
$ReadyPath = $start.ReadyPath
$LogPath = $start.LogPath
# Optional: every byte the program wrote, for working out what it actually asked the terminal
# for (which VT modes it enables, what it draws). Start-PtyApp -RawLog turns it on.
$RawLogPath = $start.RawLogPath

. (Join-Path $PSScriptRoot 'PtyNative.ps1')
. (Join-Path $PSScriptRoot 'Ghostty.ps1')

function Write-Log([string] $Message) {
    if (-not $LogPath) { return }
    "$((Get-Date).ToString('HH:mm:ss.fff'))  $Message" | Add-Content -LiteralPath $LogPath
}

$pty = $null
$terminal = $null
$pipe = $null
try {
    Write-Log "starting: $CommandLine ($Columns x $Rows)"
    $terminal = New-GhosttyTerminal -Columns $Columns -Rows $Rows
    $pty = Start-PtyProcess -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory -Columns $Columns -Rows $Rows
    Write-Log "child pid $($pty.ProcessId), console host $($pty.ConsoleHost)"

    $pipe = [IO.Pipes.NamedPipeServerStream]::new(
        $PipeName, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
    if ($ReadyPath) { Set-Content -LiteralPath $ReadyPath -Value $pty.ProcessId -Encoding utf8 }

    $buffer = [byte[]]::new(65536)
    $readTask = $pty.Output.ReadAsync($buffer, 0, $buffer.Length)
    $connectTask = $pipe.WaitForConnectionAsync()
    $exited = $false
    $running = $true

    while ($running) {
        # One thread owns the emulator, so output and requests take turns rather than locking.
        $index = [Threading.Tasks.Task]::WaitAny(@($readTask, $connectTask), 250)

        if ($index -eq 0) {
            $count = 0
            try { $count = $readTask.Result } catch { $count = 0 }
            if ($count -le 0) {
                # The pipe closed: the program has gone, but its screen is still worth reading.
                $exited = $true
                $readTask = [Threading.Tasks.Task]::Delay([Timespan]::FromMilliseconds(250)).ContinueWith({ 0 })
            } else {
                $chunk = [byte[]]::new($count)
                [Array]::Copy($buffer, $chunk, $count)
                if ($RawLogPath) {
                    $stream = [IO.File]::Open($RawLogPath, 'Append', 'Write', 'Read')
                    $stream.Write($chunk, 0, $chunk.Length)
                    $stream.Dispose()
                }
                $terminal.Write($chunk)
                # The terminal answers questions the program asked (device attributes, size and
                # mode reports); those answers go back in as if they had been typed.
                $replies = $terminal.TakeReplies()
                if ($replies.Length) {
                    Write-Log "answering $($replies.Length) byte(s) of terminal queries"
                    $pty.Input.Write($replies, 0, $replies.Length)
                    $pty.Input.Flush()
                }
                $readTask = $pty.Output.ReadAsync($buffer, 0, $buffer.Length)
            }
        } elseif ($index -eq 1) {
            try {
                $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
                $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 4096, $true)
                $writer.AutoFlush = $true
                $line = $reader.ReadLine()
                if ($line) {
                    $request = $line | ConvertFrom-Json
                    Write-Log "request: $($request.op)"
                    $response = @{ ok = $true }
                    switch ($request.op) {
                        'screen' {
                            $response['lines'] = @($terminal.GetScreen([bool] $request.scrollback))
                        }
                        'send' {
                            if ($request.bytes) {
                                $bytes = [Convert]::FromBase64String($request.bytes)
                                $pty.Input.Write($bytes, 0, $bytes.Length)
                                $pty.Input.Flush()
                            }
                        }
                        'resize' {
                            Resize-PtyProcess -Pty $pty -Columns $request.columns -Rows $request.rows
                            $terminal.Resize($request.columns, $request.rows)
                        }
                        'info' { }
                        'stop' { $running = $false }
                        default { $response = @{ ok = $false; error = "unknown request '$($request.op)'" } }
                    }
                    if ($response.ok) {
                        $response['columns'] = $terminal.Columns
                        $response['rows'] = $terminal.Rows
                        $response['processId'] = $pty.ProcessId
                        $response['consoleHost'] = "$($pty.ConsoleHost)"

                        $response['exited'] = $exited -or (Test-PtyProcessExited $pty)
                    }
                    $writer.WriteLine(($response | ConvertTo-Json -Depth 5 -Compress))
                }
                $reader.Dispose()
                $writer.Dispose()
            } catch {
                Write-Log "request failed: $_"
            } finally {
                if ($pipe.IsConnected) { $pipe.Disconnect() }
                $connectTask = $pipe.WaitForConnectionAsync()
            }
        }
    }
} catch {
    Write-Log "host failed: $_`n$($_.ScriptStackTrace)"
    throw
} finally {
    Write-Log 'stopping'
    if ($terminal) { $terminal.Dispose() }
    if ($pty) { Stop-PtyProcess $pty }
    if ($pipe) { $pipe.Dispose() }
    if ($ReadyPath -and (Test-Path -LiteralPath $ReadyPath)) { Remove-Item -LiteralPath $ReadyPath -Force }
}
