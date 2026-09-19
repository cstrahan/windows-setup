# Attaches to another process's console to read its screen and send it keys. Runs as its own
# process because a process can only be attached to one console at a time (and this one gives up
# its own with FreeConsole).
#
# Reading the console's character grid means conhost has already done the work of interpreting the
# app's VT output (cursor moves, redraws, alternate buffer), so there's no terminal emulation here.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $TargetPid,
    # Where the screen is written, one line per row.
    [Parameter(Mandatory)] [string] $ScreenPath,
    # Keys to send first, comma-separated: a key name (see $KeyNames) or literal text.
    [string] $Keys = '',
    # Milliseconds to wait after sending keys, before reading the screen.
    [int] $SettleMilliseconds = 250
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace ConsoleHarness -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
[StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct CONSOLE_SCREEN_BUFFER_INFO {
  public COORD Size; public COORD CursorPosition; public ushort Attributes; public SMALL_RECT Window; public COORD MaximumWindowSize; }
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buffer, uint length, COORD coord, out uint read);
[StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
  public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode;
  public char UnicodeChar; public uint dwControlKeyState; }
[StructLayout(LayoutKind.Explicit)] public struct INPUT_RECORD {
  [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent; }
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buffer, uint length, out uint written);
'@

# name -> virtual key code, character, control key state. Ctrl+<letter> is the letter's code with
# LEFT_CTRL_PRESSED and the matching control character, which is what a real Ctrl press sends.
$LEFT_CTRL = 0x0008
$LEFT_ALT = 0x0002
$KeyNames = @{
    enter     = @(0x0D, "`r", 0)
    tab       = @(0x09, "`t", 0)
    esc       = @(0x1B, [char] 27, 0)
    backspace = @(0x08, [char] 8, 0)
    space     = @(0x20, ' ', 0)
    up        = @(0x26, [char] 0, 0)
    down      = @(0x28, [char] 0, 0)
    left      = @(0x25, [char] 0, 0)
    right     = @(0x27, [char] 0, 0)
    home      = @(0x24, [char] 0, 0)
    end       = @(0x23, [char] 0, 0)
    pageup    = @(0x21, [char] 0, 0)
    pagedown  = @(0x22, [char] 0, 0)
    delete    = @(0x2E, [char] 0, 0)
}

function New-KeyRecords([int] $VirtualKey, [char] $Character, [int] $ControlState) {
    foreach ($down in 1, 0) {
        $record = New-Object ConsoleHarness.Native+INPUT_RECORD
        $record.EventType = 1  # KEY_EVENT
        $key = New-Object ConsoleHarness.Native+KEY_EVENT_RECORD
        $key.bKeyDown = $down
        $key.wRepeatCount = 1
        $key.wVirtualKeyCode = $VirtualKey
        $key.UnicodeChar = $Character
        $key.dwControlKeyState = $ControlState
        $record.KeyEvent = $key
        $record
    }
}

function ConvertTo-KeyRecords([string] $Spec) {
    $name = $Spec.Trim().ToLowerInvariant()
    if ($KeyNames.ContainsKey($name)) {
        $definition = $KeyNames[$name]
        return New-KeyRecords $definition[0] $definition[1] $definition[2]
    }
    if ($name -match '^(ctrl|alt)-(.)$') {
        $modifier = if ($Matches[1] -eq 'ctrl') { $LEFT_CTRL } else { $LEFT_ALT }
        $letter = $Matches[2].ToUpperInvariant()
        $character = if ($modifier -eq $LEFT_CTRL -and $letter -match '[A-Z]') {
            [char] ([int] [char] $letter - 64)  # Ctrl+A = 0x01
        } else {
            [char] $Matches[2]
        }
        return New-KeyRecords ([int] [char] $letter) $character $modifier
    }
    # Anything else is typed literally, character by character.
    return $Spec.ToCharArray() | ForEach-Object { New-KeyRecords 0 $_ 0 }
}

[void] [ConsoleHarness.Native]::FreeConsole()
if (-not [ConsoleHarness.Native]::AttachConsole([uint32] $TargetPid)) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "AttachConsole($TargetPid) failed: $([ComponentModel.Win32Exception]::new($code).Message)"
}

# GENERIC_READ | GENERIC_WRITE as a uint32: PowerShell parses 0xC0000000 as a negative Int32.
$access = [uint32] 3221225472
$FILE_SHARE_READ_WRITE = 3
$OPEN_EXISTING = 3
# Not $out/$in: PowerShell variable names are case-insensitive, so those would clobber parameters.
$screenHandle = [ConsoleHarness.Native]::CreateFileW('CONOUT$', $access, $FILE_SHARE_READ_WRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
$inputHandle = [ConsoleHarness.Native]::CreateFileW('CONIN$', $access, $FILE_SHARE_READ_WRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)

if ($Keys) {
    $records = @(foreach ($spec in $Keys -split ',') { ConvertTo-KeyRecords $spec })
    $written = 0
    if (-not [ConsoleHarness.Native]::WriteConsoleInputW($inputHandle, [ConsoleHarness.Native+INPUT_RECORD[]] $records, [uint32] $records.Count, [ref] $written)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "WriteConsoleInput failed: $([ComponentModel.Win32Exception]::new($code).Message)"
    }
    Start-Sleep -Milliseconds $SettleMilliseconds
}

$info = New-Object ConsoleHarness.Native+CONSOLE_SCREEN_BUFFER_INFO
if (-not [ConsoleHarness.Native]::GetConsoleScreenBufferInfo($screenHandle, [ref] $info)) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "GetConsoleScreenBufferInfo failed: $([ComponentModel.Win32Exception]::new($code).Message)"
}

# Only the visible window, not the whole scrollback buffer.
$width = $info.Size.X
$lines = foreach ($row in $info.Window.Top..$info.Window.Bottom) {
    $buffer = New-Object char[] $width
    $coord = New-Object ConsoleHarness.Native+COORD
    $coord.X = 0
    $coord.Y = [short] $row
    $read = 0
    [void] [ConsoleHarness.Native]::ReadConsoleOutputCharacterW($screenHandle, $buffer, [uint32] $width, $coord, [ref] $read)
    (-join $buffer).TrimEnd()
}
[IO.File]::WriteAllText($ScreenPath, ($lines -join "`r`n"))
