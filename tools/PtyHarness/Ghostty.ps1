# A thin wrapper around libghostty-vt running in wasmtime: feed it the bytes coming out of a
# pseudo console, ask it what the screen says.
#
# The module is WebAssembly with zero imports, so hosting it needs nothing but the engine: no
# WASI, no callbacks. Calls are all flat i32s, and anything structured is a pointer into the
# module's linear memory, which we allocate with ghostty_wasm_alloc.
#
# Memory can move: an exported function that allocates may grow linear memory, so every access
# re-acquires the span rather than caching one.
#
# Not a PowerShell class: a class body resolves type literals like [Wasmtime.Engine] when the file
# is parsed, which is before anything has had the chance to load the assembly. Script methods
# resolve them when they run.
#
# Dot-source this; it defines New-GhosttyTerminal.

$script:GhosttyLibDirectory = Join-Path $PSScriptRoot 'lib'
$script:GhosttyWasmPath = Join-Path $PSScriptRoot 'vendor\ghostty-vt-small.wasm'

function Initialize-Wasmtime {
    <#
    .SYNOPSIS
    Loads the wasmtime assemblies, which the pty-harness workload puts in lib\.
    #>
    if ('Wasmtime.Engine' -as [type]) { return }
    $managed = Join-Path $script:GhosttyLibDirectory 'Wasmtime.Dotnet.dll'
    $native = Join-Path $script:GhosttyLibDirectory 'wasmtime.dll'
    foreach ($path in $managed, $native) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "$path is missing. The pty-harness workload fetches it: apply configuration\workloads\pty-harness.dsc.yaml (it needs no elevation)."
        }
    }
    # Load the engine first: the managed assembly p/invokes 'wasmtime', and a loose assembly has
    # no deps.json pointing at runtimes\win-x64\native, but a module already in the process
    # resolves by name.
    [void] [Runtime.InteropServices.NativeLibrary]::Load($native)
    Add-Type -Path $managed
}

function New-GhosttyTerminal {
    <#
    .SYNOPSIS
    Creates a terminal emulator of the given size.

    .EXAMPLE
    $terminal = New-GhosttyTerminal -Columns 80 -Rows 24
    $terminal.Write([Text.Encoding]::UTF8.GetBytes("hello"))
    $terminal.GetScreen()
    #>
    [CmdletBinding()]
    param([int] $Columns = 120, [int] $Rows = 30, [string] $WasmPath = $script:GhosttyWasmPath)

    Initialize-Wasmtime

    $engine = New-Object Wasmtime.Engine
    $moduleType = [type] 'Wasmtime.Module'
    $module = $moduleType::FromFile($engine, $WasmPath)
    $store = New-Object Wasmtime.Store $engine
    $linker = New-Object Wasmtime.Linker $engine
    $instance = $linker.Instantiate($store, $module)

    $terminal = [pscustomobject]@{
        PSTypeName = 'PtyHarness.GhosttyTerminal'
        Engine     = $engine
        Store      = $store
        Instance   = $instance
        Memory     = $instance.GetMemory('memory')
        Handle     = 0
        Formatter  = 0
        Columns    = $Columns
        Rows       = $Rows
    }

    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name Call -Value {
        param([string] $Name, [int[]] $Arguments)
        $function = $this.Instance.GetFunction($Name)
        if (-not $function) { throw "libghostty-vt has no export '$Name'" }
        $boxed = [Wasmtime.ValueBox[]]::new($Arguments.Length)
        for ($index = 0; $index -lt $Arguments.Length; $index++) {
            $boxed[$index] = [Wasmtime.ValueBox] $Arguments[$index]
        }
        $result = $function.Invoke($boxed)
        if ($null -eq $result) { return 0 }
        return [int] $result
    }

    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name Check -Value {
        param([int] $Result, [string] $What)
        # GHOSTTY_SUCCESS is 0; the other codes are in ghostty/vt/types.h.
        if ($Result -ne 0) { throw "$What failed: libghostty-vt result $Result" }
    }

    # Feeds output from the pty to the emulator.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name Write -Value {
        param([byte[]] $Bytes)
        if (-not $Bytes -or $Bytes.Length -eq 0) { return }
        $pointer = $this.Call('ghostty_wasm_alloc', @($Bytes.Length))
        if (-not $pointer) { throw 'libghostty-vt: out of memory writing to the terminal' }
        # Take the base pointer after the allocation, never before: allocating can grow linear
        # memory, which moves it. (PowerShell can't use the Span overloads at all: Span is a
        # ByRef-like type.)
        [Runtime.InteropServices.Marshal]::Copy($Bytes, 0, [IntPtr]::Add($this.Memory.GetPointer(), $pointer), $Bytes.Length)
        [void] $this.Call('ghostty_terminal_vt_write', @($this.Handle, $pointer, $Bytes.Length))
        [void] $this.Call('ghostty_wasm_free', @($pointer, $Bytes.Length))
    }

    # A number from the terminal: GhosttyTerminalData keys, e.g. 2 = ROWS, 15 = SCROLLBACK_ROWS.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name GetNumber -Value {
        param([int] $Key)
        $out = $this.Call('ghostty_wasm_alloc', @(8))
        try {
            foreach ($offset in 0..7) { $this.Memory.WriteByte($out + $offset, 0) }
            $this.Check($this.Call('ghostty_terminal_get', @($this.Handle, $Key, $out)), "ghostty_terminal_get($Key)")
            return $this.Memory.ReadInt32($out)
        } finally {
            [void] $this.Call('ghostty_wasm_free', @($out, 8))
        }
    }

    # The screen as lines of text, as the app has drawn it: the visible rows by default, or
    # everything the terminal still holds with -Scrollback.
    #
    # The formatter always emits history and viewport together, oldest first, and does not pad
    # blank rows - so the viewport can't be had by taking the last N lines. It is whatever follows
    # the rows that have scrolled off, which the terminal will say (SCROLLBACK_ROWS).
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name GetScreen -Value {
        param([switch] $Scrollback)
        $outPointer = $this.Call('ghostty_wasm_alloc', @(4))
        $outLength = $this.Call('ghostty_wasm_alloc', @(4))
        try {
            $this.Check($this.Call('ghostty_formatter_format_alloc', @($this.Formatter, 0, $outPointer, $outLength)), 'ghostty_formatter_format_alloc')
            $pointer = $this.Memory.ReadInt32($outPointer)
            $length = $this.Memory.ReadInt32($outLength)
            if ($length -eq 0) { return @() }
            $text = $this.Memory.ReadString($pointer, $length, [Text.Encoding]::UTF8)
            [void] $this.Call('ghostty_free', @(0, $pointer, $length))
            $lines = @($text -split "`r?`n")
            if ($Scrollback) { return $lines }
            $scrolledOff = $this.GetNumber(15)   # SCROLLBACK_ROWS
            if ($scrolledOff -le 0) { return $lines }
            if ($scrolledOff -ge $lines.Count) { return @() }
            return @($lines | Select-Object -Skip $scrolledOff)
        } finally {
            [void] $this.Call('ghostty_wasm_free', @($outPointer, 4))
            [void] $this.Call('ghostty_wasm_free', @($outLength, 4))
        }
    }

    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name Resize -Value {
        param([int] $Columns, [int] $Rows)
        # The pixel sizes are what an app sees from XTWINOPS and mode 2048 reports; 8x16 is the
        # cell conhost uses here, so anything that asks gets a sane answer.
        $this.Check($this.Call('ghostty_terminal_resize', @($this.Handle, $Columns, $Rows, 8, 16)), 'ghostty_terminal_resize')
        $this.Columns = $Columns
        $this.Rows = $Rows
    }

    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name Dispose -Value {
        if ($this.Formatter) { [void] $this.Call('ghostty_formatter_free', @($this.Formatter)); $this.Formatter = 0 }
        if ($this.Handle) { [void] $this.Call('ghostty_terminal_free', @($this.Handle)); $this.Handle = 0 }
    }

    # The terminal itself, and a formatter that reads its current state on every call.
    $slot = $terminal.Call('ghostty_wasm_alloc_opaque', @())
    if (-not $slot) { throw 'libghostty-vt: out of memory allocating a handle slot' }
    $terminal.Check($terminal.Call('ghostty_terminal_new', @(0, $slot, $Columns, $Rows)), 'ghostty_terminal_new')
    $terminal.Handle = $terminal.Call('ghostty_wasm_take_opaque', @($slot))

    # GhosttyFormatterTerminalOptions, whose size and field offsets come from ghostty_type_json():
    # { size_t size; enum emit; bool unwrap; bool trim; enum extra; const GhosttySelection* } in
    # 40 bytes. Zeroed means "emit text, don't unwrap, whole screen"; byte 9 is trim.
    $optionsSize = 40
    $options = $terminal.Call('ghostty_wasm_alloc', @($optionsSize))
    foreach ($offset in 0..($optionsSize - 1)) { $terminal.Memory.WriteByte($options + $offset, 0) }
    $terminal.Memory.WriteInt32($options, $optionsSize)
    $terminal.Memory.WriteByte($options + 9, 1)
    $terminal.Check($terminal.Call('ghostty_formatter_terminal_new', @(0, $slot, $terminal.Handle, $options)), 'ghostty_formatter_terminal_new')
    $terminal.Formatter = $terminal.Call('ghostty_wasm_take_opaque', @($slot))
    [void] $terminal.Call('ghostty_wasm_free', @($options, $optionsSize))
    [void] $terminal.Call('ghostty_wasm_free_opaque', @($slot))

    return $terminal
}
