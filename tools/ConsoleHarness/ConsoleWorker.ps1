# Attaches to another process's console to drive it and read it back. Runs as its own process
# because a process can only be attached to one console at a time (and this one gives up its own
# with FreeConsole).
#
# Reading the console's character grid means conhost has already done the work of interpreting the
# app's VT output (cursor moves, redraws, alternate buffer), so there's no terminal emulation here.
#
# One invocation does at most: resize, move the view, send input, wait, read the screen, report
# state. The module builds the request; this script only carries it out. Nothing may be written to
# the host: after AttachConsole, PowerShell's output would be drawn into the target app's screen.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $TargetPid,
    # Where the screen text is written, one line per row.
    [Parameter(Mandatory)] [string] $ScreenPath,
    # Where the console's state is written as JSON.
    [Parameter(Mandatory)] [string] $StatePath,
    # JSON request; see Invoke-Worker in ConsoleHarness.psm1.
    [string] $RequestPath = ''
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
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleScreenBufferSize(IntPtr h, COORD size);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleWindowInfo(IntPtr h, bool absolute, ref SMALL_RECT window);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buffer, uint length, COORD coord, out uint read);
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
public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buffer, uint length, out uint written);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", SetLastError = true)] public static extern bool GetClientRect(IntPtr h, out RECT r);
[DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

$KEY_EVENT = 1
$MOUSE_EVENT = 2
# dwEventFlags
$MOUSE_MOVED = 0x0001
$MOUSE_WHEELED = 0x0004
$MOUSE_HWHEELED = 0x0008
# dwButtonState
$MouseButtonBits = @{ Left = 0x0001; Right = 0x0002; Middle = 0x0004; X1 = 0x0008; X2 = 0x0010 }
# Console input modes
$ENABLE_WINDOW_INPUT = 0x0008
$ENABLE_MOUSE_INPUT = 0x0010
$ENABLE_QUICK_EDIT_MODE = 0x0040
$ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
# dwControlKeyState, as KeySpec.ps1 sets it
$CtrlFlags = 0x000C
$AltFlags = 0x0003
$ShiftFlag = 0x0010

function New-KeyRecord {
    param([int] $VirtualKey, [int] $CharCode, [int] $ControlState, [bool] $KeyDown)
    $record = New-Object ConsoleHarness.Native+INPUT_RECORD
    $record.EventType = $KEY_EVENT
    $key = New-Object ConsoleHarness.Native+KEY_EVENT_RECORD
    $key.bKeyDown = [int] $KeyDown
    $key.wRepeatCount = 1
    $key.wVirtualKeyCode = [ushort] $VirtualKey
    $key.UnicodeChar = [char] $CharCode
    $key.dwControlKeyState = [uint32] $ControlState
    $record.KeyEvent = $key
    return $record
}

function New-MouseRecord {
    param([int] $X, [int] $Y, [int64] $ButtonState, [int] $ControlState, [int] $Flags)
    $record = New-Object ConsoleHarness.Native+INPUT_RECORD
    $record.EventType = $MOUSE_EVENT
    $mouse = New-Object ConsoleHarness.Native+MOUSE_EVENT_RECORD
    $position = New-Object ConsoleHarness.Native+COORD
    $position.X = [short] $X
    $position.Y = [short] $Y
    $mouse.dwMousePosition = $position
    $mouse.dwButtonState = [uint32] $ButtonState
    $mouse.dwControlKeyState = [uint32] $ControlState
    $mouse.dwEventFlags = [uint32] $Flags
    $record.MouseEvent = $mouse
    return $record
}

function Get-SgrModifiers {
    param([int] $ControlState)
    $code = 0
    if ($ControlState -band $ShiftFlag) { $code += 4 }
    if ($ControlState -band $AltFlags) { $code += 8 }
    if ($ControlState -band $CtrlFlags) { $code += 16 }
    return $code
}

function ConvertTo-SgrSequence {
    <#
    .SYNOPSIS
    Renders a mouse event as an SGR sequence (ESC[<button;column;rowM), which is what an app in
    virtual-terminal input mode is listening for. Coordinates are 1-based.
    #>
    param($MouseEvent, [int] $Column, [int] $Row, [string] $HeldButton)

    $sgrButtons = @{ Left = 0; Middle = 1; Right = 2; X1 = 128; X2 = 129 }
    $final = 'M'
    $code = switch ($MouseEvent.Action) {
        'Wheel' {
            if ($MouseEvent.WheelAxis -eq 'Horizontal') {
                if ($MouseEvent.Notches -gt 0) { 67 } else { 66 }
            } else {
                if ($MouseEvent.Notches -gt 0) { 64 } else { 65 }
            }
        }
        'Move' {
            # 3 is "no button"; +32 marks motion, so a drag reports the button being held.
            $base = if ($HeldButton) { $sgrButtons[$HeldButton] } else { 3 }
            $base + 32
        }
        'Up' { $final = 'm'; $sgrButtons[$MouseEvent.Button] }
        default { $sgrButtons[$MouseEvent.Button] }
    }
    $code += Get-SgrModifiers -ControlState $MouseEvent.ControlState
    return "$([char] 27)[<$code;$Column;$Row$final"
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
# Not $out/$in: PowerShell variable names are case-insensitive, so those would clobber parameters,
# and $input is an automatic variable (the pipeline enumerator).
$screenHandle = [ConsoleHarness.Native]::CreateFileW('CONOUT$', $access, $FILE_SHARE_READ_WRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
$inputHandle = [ConsoleHarness.Native]::CreateFileW('CONIN$', $access, $FILE_SHARE_READ_WRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)

function Get-BufferInfo {
    $info = New-Object ConsoleHarness.Native+CONSOLE_SCREEN_BUFFER_INFO
    if (-not [ConsoleHarness.Native]::GetConsoleScreenBufferInfo($screenHandle, [ref] $info)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetConsoleScreenBufferInfo failed: $([ComponentModel.Win32Exception]::new($code).Message)"
    }
    return $info
}

$request = if ($RequestPath) { Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json } else { $null }

# --- resize ------------------------------------------------------------------------------------
if ($request.resize) {
    $info = Get-BufferInfo
    $width = if ($request.resize.width) { [int] $request.resize.width } else { $info.Size.X }
    $height = if ($request.resize.height) { [int] $request.resize.height } else { $info.Window.Bottom - $info.Window.Top + 1 }
    # An app on the alternate screen buffer (a full-screen TUI: Neovim, fzf) has no scrollback, and
    # conhost keeps that buffer exactly the size of the window: asking for a taller one fails with
    # "the parameter is incorrect". Its signature is a buffer that already matches the window.
    $alternateBuffer = [int] $info.Size.Y -eq ($info.Window.Bottom - $info.Window.Top + 1)
    $bufferHeight = if ($alternateBuffer) { $height }
        elseif ($request.resize.bufferHeight) { [int] $request.resize.bufferHeight }
        else { [Math]::Max([int] $info.Size.Y, $height) }
    $size = New-Object ConsoleHarness.Native+COORD
    $size.X = [short] $width
    $size.Y = [short] [Math]::Max($bufferHeight, $height)

    function Set-Window([int] $Width, [int] $Height, [string] $Step) {
        $rect = New-Object ConsoleHarness.Native+SMALL_RECT
        $rect.Left = 0; $rect.Top = 0; $rect.Right = [short] ($Width - 1); $rect.Bottom = [short] ($Height - 1)
        if (-not [ConsoleHarness.Native]::SetConsoleWindowInfo($screenHandle, $true, [ref] $rect)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SetConsoleWindowInfo(${Width}x${Height}) failed while $Step`: $([ComponentModel.Win32Exception]::new($code).Message)"
        }
    }

    function Set-SizeByWindow([int] $Cols, [int] $Rows) {
        <#
        .SYNOPSIS
        Resizes the console by resizing conhost's own window, the way dragging its corner would.

        .DESCRIPTION
        This is the only route that works while an app holds the alternate screen buffer: conhost
        then answers every SetConsoleScreenBufferSize and SetConsoleWindowInfo with
        ERROR_INVALID_HANDLE, but still reflows for a window resize (and tells the app). The cell
        size comes from the current client area rather than the font, which avoids a second API and
        is exact: 960px / 120 columns = 8.
        #>
        $hwnd = [ConsoleHarness.Native]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { throw 'there is no console window to resize' }
        # Converge rather than compute once: the window's chrome changes underneath us. Shrinking a
        # console can take its scrollbar away, which frees ~2 columns of client area, so a single
        # measurement lands a few columns short.
        foreach ($attempt in 1..5) {
            $current = Get-BufferInfo
            $currentCols = $current.Window.Right - $current.Window.Left + 1
            $currentRows = $current.Window.Bottom - $current.Window.Top + 1
            if ($currentCols -eq $Cols -and $currentRows -eq $Rows) { return }

            $windowRect = New-Object ConsoleHarness.Native+RECT
            $clientRect = New-Object ConsoleHarness.Native+RECT
            [void] [ConsoleHarness.Native]::GetWindowRect($hwnd, [ref] $windowRect)
            [void] [ConsoleHarness.Native]::GetClientRect($hwnd, [ref] $clientRect)
            $clientWidth = $clientRect.Right - $clientRect.Left
            $clientHeight = $clientRect.Bottom - $clientRect.Top
            # The cell size comes from the client area rather than the font: one API fewer, and
            # exact (960px / 120 columns = 8).
            $cellWidth = [Math]::Max(1, [int] ($clientWidth / $currentCols))
            $cellHeight = [Math]::Max(1, [int] ($clientHeight / $currentRows))
            $windowWidth = $windowRect.Right - $windowRect.Left
            $windowHeight = $windowRect.Bottom - $windowRect.Top
            # Aim by the difference from where we are, so the chrome cancels out.
            $targetWidth = $windowWidth + ($Cols - $currentCols) * $cellWidth
            $targetHeight = $windowHeight + ($Rows - $currentRows) * $cellHeight
            # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE: only the size changes.
            $flags = [uint32] (0x0002 -bor 0x0004 -bor 0x0010)
            if (-not [ConsoleHarness.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, $targetWidth, $targetHeight, $flags)) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "SetWindowPos failed: $([ComponentModel.Win32Exception]::new($code).Message)"
            }
            # conhost applies the resize on its own thread, so give it time to land.
            foreach ($poll in 1..10) {
                Start-Sleep -Milliseconds 100
                $after = Get-BufferInfo
                if (($after.Window.Right - $after.Window.Left + 1) -ne $currentCols -or
                    ($after.Window.Bottom - $after.Window.Top + 1) -ne $currentRows) { break }
            }
        }
        $after = Get-BufferInfo
        throw "the console stayed at $($after.Window.Right - $after.Window.Left + 1)x$($after.Window.Bottom - $after.Window.Top + 1) instead of ${Cols}x${Rows}"
    }

    # A window can never be larger than its buffer, in either dimension, so the order depends on
    # which way each one is going: shrink the window first, then the buffer, then grow the window.
    # An app on the alternate screen buffer refuses all of it, so fall back to the window route,
    # which is also the only way to change its size at all.
    $currentWidth = $info.Window.Right - $info.Window.Left + 1
    $currentHeight = $info.Window.Bottom - $info.Window.Top + 1
    try {
        if ($alternateBuffer) { throw 'the app is on the alternate screen buffer' }
        Set-Window -Width ([Math]::Min($currentWidth, $width)) -Height ([Math]::Min($currentHeight, $height)) -Step 'making room'
        if (-not [ConsoleHarness.Native]::SetConsoleScreenBufferSize($screenHandle, $size)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SetConsoleScreenBufferSize($width, $($size.Y)) failed: $([ComponentModel.Win32Exception]::new($code).Message)"
        }
        Set-Window -Width $width -Height $height -Step 'resizing'
    } catch {
        Set-SizeByWindow -Cols $width -Rows $height
    }
}

# --- scroll the view ---------------------------------------------------------------------------
if ($null -ne $request.view) {
    $info = Get-BufferInfo
    $height = $info.Window.Bottom - $info.Window.Top + 1
    $top = switch ($request.view.mode) {
        'home' { 0 }
        'end' { $info.Size.Y - $height }
        'lines' { $info.Window.Top + [int] $request.view.lines }
        default { [int] $request.view.top }
    }
    $top = [Math]::Max(0, [Math]::Min([int] $top, $info.Size.Y - $height))
    $window = New-Object ConsoleHarness.Native+SMALL_RECT
    $window.Left = $info.Window.Left
    $window.Right = $info.Window.Right
    $window.Top = [short] $top
    $window.Bottom = [short] ($top + $height - 1)
    if (-not [ConsoleHarness.Native]::SetConsoleWindowInfo($screenHandle, $true, [ref] $window)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetConsoleWindowInfo(top $top) failed: $([ComponentModel.Win32Exception]::new($code).Message)"
    }
}

# --- input -------------------------------------------------------------------------------------
$mode = 0
[void] [ConsoleHarness.Native]::GetConsoleMode($inputHandle, [ref] $mode)
$vtInput = [bool] ($mode -band $ENABLE_VIRTUAL_TERMINAL_INPUT)
# SGR sequences by default: that is what a modern terminal application expects, and it is what
# the console's own input mode cannot tell us (an app can parse SGR itself without ever setting
# ENABLE_VIRTUAL_TERMINAL_INPUT, as fzf's light renderer does). Record is for apps that read
# console input records instead; see the harness README for which is which.
$delivery = if ($request.mouseDelivery -eq 'record') { 'Record' } else { 'Vt' }

$events = @($request.events)
if ($events.Count) {
    $info = Get-BufferInfo
    $centreX = [int] (($info.Window.Right - $info.Window.Left) / 2)
    $centreY = [int] (($info.Window.Bottom - $info.Window.Top) / 2)
    $heldButtons = 0
    $heldButton = ''   # which one, for SGR's drag reporting
    $records = [Collections.Generic.List[object]]::new()
    # Not $event: that's an automatic variable in PowerShell's eventing.
    foreach ($inputEvent in $events) {
        if ($inputEvent.Type -eq 'Key') {
            $records.Add((New-KeyRecord -VirtualKey $inputEvent.VirtualKey -CharCode $inputEvent.CharCode -ControlState $inputEvent.ControlState -KeyDown ([bool] $inputEvent.KeyDown)))
            continue
        }
        # Mouse. Coordinates arrive relative to the visible window, which is what the screen text
        # is indexed by; -1 means "wherever it was", and nowhere means the middle.
        $windowX = if ([int] $inputEvent.X -ge 0) { [int] $inputEvent.X } else { $centreX }
        $windowY = if ([int] $inputEvent.Y -ge 0) { [int] $inputEvent.Y } else { $centreY }
        $bit = if ($inputEvent.Button -eq 'None') { 0 } else { $MouseButtonBits[$inputEvent.Button] }
        switch ($inputEvent.Action) {
            'Down' { $heldButtons = $heldButtons -bor $bit; $heldButton = $inputEvent.Button }
            'Up' { $heldButtons = $heldButtons -band (-bnot $bit); $heldButton = '' }
        }
        if ($delivery -eq 'Vt') {
            $sequence = ConvertTo-SgrSequence -MouseEvent $inputEvent -Column ($windowX + 1) -Row ($windowY + 1) -HeldButton $heldButton
            foreach ($character in $sequence.ToCharArray()) {
                $records.Add((New-KeyRecord -VirtualKey 0 -CharCode ([int] $character) -ControlState 0 -KeyDown $true))
                $records.Add((New-KeyRecord -VirtualKey 0 -CharCode ([int] $character) -ControlState 0 -KeyDown $false))
            }
            continue
        }
        $bufferX = $windowX + $info.Window.Left
        $bufferY = $windowY + $info.Window.Top
        switch ($inputEvent.Action) {
            'Wheel' {
                $flags = if ($inputEvent.WheelAxis -eq 'Horizontal') { $MOUSE_HWHEELED } else { $MOUSE_WHEELED }
                # The delta is the high word of dwButtonState, 120 per notch. Build it in 64-bit:
                # in Int32, 65176 -shl 16 overflows to a negative that won't cast to uint32.
                $delta = 120 * [int] $inputEvent.Notches
                $state = ((([int64] $delta) -band 0xFFFF) -shl 16) -bor $heldButtons
                $records.Add((New-MouseRecord -X $bufferX -Y $bufferY -ButtonState $state -ControlState $inputEvent.ControlState -Flags $flags))
            }
            'Move' {
                $records.Add((New-MouseRecord -X $bufferX -Y $bufferY -ButtonState $heldButtons -ControlState $inputEvent.ControlState -Flags $MOUSE_MOVED))
            }
            default {
                $records.Add((New-MouseRecord -X $bufferX -Y $bufferY -ButtonState $heldButtons -ControlState $inputEvent.ControlState -Flags 0))
            }
        }
    }

    $written = 0
    $array = [ConsoleHarness.Native+INPUT_RECORD[]] $records.ToArray()
    if (-not [ConsoleHarness.Native]::WriteConsoleInputW($inputHandle, $array, [uint32] $array.Length, [ref] $written)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "WriteConsoleInput failed: $([ComponentModel.Win32Exception]::new($code).Message)"
    }
}

if ($request.settleMilliseconds) { Start-Sleep -Milliseconds ([int] $request.settleMilliseconds) }

# --- read --------------------------------------------------------------------------------------
$info = Get-BufferInfo
$width = $info.Size.X
$readMode = if ($request.read.mode) { $request.read.mode } else { 'window' }
switch ($readMode) {
    'buffer' { $first = 0; $count = $info.Size.Y }
    'range' {
        $first = [Math]::Max(0, [int] $request.read.row)
        $count = if ($request.read.rows) { [int] $request.read.rows } else { $info.Window.Bottom - $info.Window.Top + 1 }
    }
    default { $first = $info.Window.Top; $count = $info.Window.Bottom - $info.Window.Top + 1 }
}
$count = [Math]::Max(0, [Math]::Min($count, $info.Size.Y - $first))

$lines = foreach ($row in 0..([Math]::Max($count - 1, 0))) {
    if ($count -eq 0) { break }
    $buffer = New-Object char[] $width
    $coord = New-Object ConsoleHarness.Native+COORD
    $coord.X = 0
    $coord.Y = [short] ($first + $row)
    $read = 0
    [void] [ConsoleHarness.Native]::ReadConsoleOutputCharacterW($screenHandle, $buffer, [uint32] $width, $coord, [ref] $read)
    (-join $buffer).TrimEnd()
}
[IO.File]::WriteAllText($ScreenPath, (@($lines) -join "`r`n"))

# --- state -------------------------------------------------------------------------------------
$state = @{
    BufferWidth    = [int] $info.Size.X
    BufferHeight   = [int] $info.Size.Y
    WindowLeft     = [int] $info.Window.Left
    WindowTop      = [int] $info.Window.Top
    WindowWidth    = [int] ($info.Window.Right - $info.Window.Left + 1)
    WindowHeight   = [int] ($info.Window.Bottom - $info.Window.Top + 1)
    MaxWindowWidth = [int] $info.MaximumWindowSize.X
    MaxWindowHeight = [int] $info.MaximumWindowSize.Y
    CursorX        = [int] $info.CursorPosition.X
    CursorY        = [int] $info.CursorPosition.Y
    InputMode      = '0x{0:x}' -f $mode
    MouseInput     = [bool] ($mode -band $ENABLE_MOUSE_INPUT)
    VtInput        = $vtInput
    WindowInput    = [bool] ($mode -band $ENABLE_WINDOW_INPUT)
    QuickEdit      = [bool] ($mode -band $ENABLE_QUICK_EDIT_MODE)
    MouseDelivery  = $delivery
    FirstRow       = [int] $first
    RowCount       = [int] $count
}
[IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject $state -Compress))
