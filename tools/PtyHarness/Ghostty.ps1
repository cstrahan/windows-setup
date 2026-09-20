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
    # The reply callback and the cell reader are compiled against wasmtime; each file says why it
    # can't be PowerShell. System.Collections has to be named: Add-Type builds against reference
    # assemblies, and without it the generic collections don't resolve. -IgnoreWarnings: the
    # binding targets net8.0 and this runtime is newer, which is only a warning.
    $references = @($managed, 'System.Collections')
    Add-Type -Path (Join-Path $PSScriptRoot 'GhosttyReplySink.cs') -ReferencedAssemblies $references `
        -IgnoreWarnings -WarningAction SilentlyContinue
    Add-Type -Path (Join-Path $PSScriptRoot 'GhosttyScreenReader.cs') -ReferencedAssemblies $references `
        -IgnoreWarnings -WarningAction SilentlyContinue
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
        # One formatter per output format (plain, VT, HTML), made when first asked for.
        Formatters = @{}
        # Reads cells with their colours and attributes; made when first asked for.
        Reader     = $null
        Columns    = $Columns
        Rows       = $Rows
        # Answers the terminal wants sent back to the program; the host drains these.
        Replies    = $null
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

    # Whatever the terminal answered since the last write, as bytes for the program's input.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name TakeReplies -Value {
        if (-not $this.Replies) { return [byte[]]::new(0) }
        return $this.Replies.Take()
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

    # A formatter for one GhosttyFormatterFormat (0 plain, 1 VT, 2 HTML), kept once it is made.
    #
    # GhosttyFormatterTerminalOptions, whose size and field offsets come from ghostty_type_json():
    # { u32 size; enum emit@4; bool unwrap@8; bool trim@9; GhosttyFormatterTerminalExtra extra@12;
    # const GhosttySelection* selection@36 } in 40 bytes. Zeroed means "the screen only, don't
    # unwrap"; extra stays zeroed so no palette, modes or cursor state is emitted with it.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name GetFormatter -Value {
        param([int] $Emit)
        if ($this.Formatters.ContainsKey($Emit)) { return $this.Formatters[$Emit] }
        $slot = $this.Call('ghostty_wasm_alloc_opaque', @())
        if (-not $slot) { throw 'libghostty-vt: out of memory allocating a handle slot' }
        $optionsSize = 40
        $options = $this.Call('ghostty_wasm_alloc', @($optionsSize))
        foreach ($offset in 0..($optionsSize - 1)) { $this.Memory.WriteByte($options + $offset, 0) }
        $this.Memory.WriteInt32($options, $optionsSize)
        $this.Memory.WriteInt32($options + 4, $Emit)
        $this.Memory.WriteByte($options + 9, 1)
        $this.Check($this.Call('ghostty_formatter_terminal_new', @(0, $slot, $this.Handle, $options)), 'ghostty_formatter_terminal_new')
        $formatter = $this.Call('ghostty_wasm_take_opaque', @($slot))
        [void] $this.Call('ghostty_wasm_free', @($options, $optionsSize))
        [void] $this.Call('ghostty_wasm_free_opaque', @($slot))
        $this.Formatters[$Emit] = $formatter
        return $formatter
    }

    # The whole screen in one of the formatter's formats, as a single string.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name FormatText -Value {
        param([int] $Emit)
        $formatter = $this.GetFormatter($Emit)
        $outPointer = $this.Call('ghostty_wasm_alloc', @(4))
        $outLength = $this.Call('ghostty_wasm_alloc', @(4))
        try {
            $this.Check($this.Call('ghostty_formatter_format_alloc', @($formatter, 0, $outPointer, $outLength)), 'ghostty_formatter_format_alloc')
            $pointer = $this.Memory.ReadInt32($outPointer)
            $length = $this.Memory.ReadInt32($outLength)
            if ($length -eq 0) { return '' }
            $text = $this.Memory.ReadString($pointer, $length, [Text.Encoding]::UTF8)
            [void] $this.Call('ghostty_free', @(0, $pointer, $length))
            return $text
        } finally {
            [void] $this.Call('ghostty_wasm_free', @($outPointer, 4))
            [void] $this.Call('ghostty_wasm_free', @($outLength, 4))
        }
    }

    # The screen as lines of text, as the app has drawn it: the visible rows by default, or
    # everything the terminal still holds with -Scrollback.
    #
    # The formatter always emits history and viewport together, oldest first, and does not pad
    # blank rows - so the viewport can't be had by taking the last N lines. It is whatever follows
    # the rows that have scrolled off, which the terminal will say (SCROLLBACK_ROWS).
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name GetScreen -Value {
        param([switch] $Scrollback, [int] $Emit = 0)
        $text = $this.FormatText($Emit)
        if ($text -eq '') { return @() }
        $lines = @($text -split "`r?`n")
        if ($Scrollback) { return $lines }
        $scrolledOff = $this.GetNumber(15)   # SCROLLBACK_ROWS
        if ($scrolledOff -le 0) { return $lines }
        if ($scrolledOff -ge $lines.Count) { return @() }
        return @($lines | Select-Object -Skip $scrolledOff)
    }

    # The viewport's cells with their colours and attributes, coalesced into runs. -1 reads every
    # row; a row number reads just that one.
    #
    # Unlike the text formatter this is the viewport by construction: the render state snapshots
    # what is visible, so there is no scrolled-off count to subtract.
    Add-Member -InputObject $terminal -MemberType ScriptMethod -Name GetStyled -Value {
        param([int] $Row = -1)
        if (-not $this.Reader) { $this.Reader = [PtyHarness.GhosttyScreenReader]::new($this.Instance) }
        return $this.Reader.Read($this.Handle, $Row)
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
        if ($this.Reader) { $this.Reader.Dispose(); $this.Reader = $null }
        foreach ($formatter in @($this.Formatters.Values)) { [void] $this.Call('ghostty_formatter_free', @($formatter)) }
        $this.Formatters.Clear()
        if ($this.Handle) { [void] $this.Call('ghostty_terminal_free', @($this.Handle)); $this.Handle = 0 }
    }

    # The terminal itself. Formatters and the cell reader are made on first use, so a session that
    # only ever reads text never builds a render state.
    $slot = $terminal.Call('ghostty_wasm_alloc_opaque', @())
    if (-not $slot) { throw 'libghostty-vt: out of memory allocating a handle slot' }
    $terminal.Check($terminal.Call('ghostty_terminal_new', @(0, $slot, $Columns, $Rows)), 'ghostty_terminal_new')
    $terminal.Handle = $terminal.Call('ghostty_wasm_take_opaque', @($slot))
    [void] $terminal.Call('ghostty_wasm_free_opaque', @($slot))

    # Answer the questions applications ask the terminal. The callback is a host function placed
    # in the module's function table, and its index is the function pointer.
    $table = $instance.GetTable('__indirect_function_table')
    if ($table) {
        $sink = [PtyHarness.GhosttyReplySink]::new()
        $callback = $sink.CreateFunction($store)
        # Grow returns the old size, which is where our function landed.
        $index = [int] $table.Grow(1, $callback)
        # The value IS the function pointer, not a pointer to it: ghostty_terminal_set takes
        # `?*const anyopaque` and stores it as the callback (see terminal.zig, setTyped). Passing
        # a pointer to a cell holding the index makes libghostty call a wild table entry, which
        # kills the process without a trap or an exception.
        $terminal.Check($terminal.Call('ghostty_terminal_set', @($terminal.Handle, 1, $index)), 'ghostty_terminal_set(WRITE_PTY)')
        $terminal.Replies = $sink
        # Keep the Function alive: collected, its table entry points at nothing.
        Add-Member -InputObject $terminal -NotePropertyName WritePtyCallback -NotePropertyValue $callback
    }

    return $terminal
}
