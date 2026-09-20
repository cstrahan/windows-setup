# Test fixture: a console app that enables mouse input and writes every input record it reads to a
# log, so tests can assert on what actually arrived rather than on another app's reaction to it.
# Quits when it reads 'q'.
#
#   Start-ConsoleApp -Command "& '<path>\InputSink.ps1' -LogPath '<log>'"
#   Wait-ConsoleText $session 'INPUT SINK READY'
param(
    [Parameter(Mandatory)] [string] $LogPath,
    # Add ENABLE_VIRTUAL_TERMINAL_INPUT, to stand in for an app like Neovim.
    [switch] $VirtualTerminalInput
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Sink -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint mode);
[StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
  public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode;
  public char UnicodeChar; public uint dwControlKeyState; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSE_EVENT_RECORD {
  public COORD dwMousePosition; public uint dwButtonState; public uint dwControlKeyState; public uint dwEventFlags; }
[StructLayout(LayoutKind.Explicit)] public struct INPUT_RECORD {
  [FieldOffset(0)] public ushort EventType;
  [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
  [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent; }
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool ReadConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] buffer, uint length, out uint read);
'@

$handle = [Sink.Native]::GetStdHandle(-10)   # STD_INPUT_HANDLE
# ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS, without line input or echo.
$mode = [uint32] (0x0010 -bor 0x0008 -bor 0x0080)
if ($VirtualTerminalInput) { $mode = $mode -bor 0x0200 }
[void] [Sink.Native]::SetConsoleMode($handle, $mode)
Write-Host 'INPUT SINK READY'

$buffer = New-Object Sink.Native+INPUT_RECORD[] 64
while ($true) {
    $read = 0
    if (-not [Sink.Native]::ReadConsoleInputW($handle, $buffer, 64, [ref] $read)) { break }
    foreach ($index in 0..([int] $read - 1)) {
        $record = $buffer[$index]
        $line = switch ($record.EventType) {
            1 { "KEY down=$($record.KeyEvent.bKeyDown) vk=0x$('{0:x2}' -f $record.KeyEvent.wVirtualKeyCode) char=0x$('{0:x2}' -f [int] $record.KeyEvent.UnicodeChar) state=0x$('{0:x}' -f $record.KeyEvent.dwControlKeyState)" }
            2 { "MOUSE pos=$($record.MouseEvent.dwMousePosition.X),$($record.MouseEvent.dwMousePosition.Y) buttons=0x$('{0:x8}' -f $record.MouseEvent.dwButtonState) flags=0x$('{0:x}' -f $record.MouseEvent.dwEventFlags)" }
            4 { "RESIZE to $($record.MouseEvent.dwMousePosition.X)x$($record.MouseEvent.dwMousePosition.Y)" }
            default { "OTHER type=$($record.EventType)" }
        }
        $line | Add-Content -LiteralPath $LogPath
        if ($record.EventType -eq 1 -and $record.KeyEvent.bKeyDown -and $record.KeyEvent.UnicodeChar -eq 'q') { return }
    }
}
