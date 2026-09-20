# PtyHarness (experimental)

Drives an interactive program through a Windows pseudo console (ConPTY) and renders the VT stream
it produces with [libghostty-vt](vendor/README.md), so the screen can be read back as text.

```powershell
Import-Module .\tools\PtyHarness

$session = Start-PtyApp -CommandLine 'nvim README.md' -Columns 120 -Rows 30 -Name editor
try {
    Wait-PtyText $session 'README'
    Send-PtyKeys $session 'G'                       # same key syntax as ConsoleHarness
    Set-PtySize $session -Columns 70 -Rows 20       # the app is told, and reflows
    Get-PtyScreen $session -NonEmpty
} finally {
    Stop-PtyApp $session
}
```

Sessions outlive the process that started them, as with ConsoleHarness: `-Name` labels one and
`Get-PtyApp -Name` picks it up later. `Start-PtyApp -RawLog` keeps every byte the program wrote,
which is how you find out what it actually asked the terminal for. The screen comes back as text,
as escape sequences, as an HTML page, or as structured runs with their colours — see
[Colours and styles](#colours-and-styles).

## Which harness to use

| | [ConsoleHarness](../ConsoleHarness/README.md) | PtyHarness |
|---|---|---|
| How the screen is read | conhost renders it; we read the character grid | we render the VT stream ourselves |
| Dependencies | none (Win32 only) | wasmtime, a vendored wasm and a console host, ~23 MB |
| Works before the machine is set up | yes | no |
| Mouse | injects `INPUT_RECORD`s or types SGR, per application | SGR only; the console host adapts |
| Fidelity | conhost's, including its quirks | a real terminal's: reflow, scrollback, styles |

ConsoleHarness remains the default: fewer moving parts, and it works on a machine that hasn't
been set up. Reach for this one when the thing under test depends on genuine terminal behaviour —
reflow, scrollback, VT semantics — rather than on conhost's rendering of it, or when you would
rather not care which mouse delivery an application wants.

## Two constraints that shaped this

**The host process must not have redirected standard handles.** A child attached to a pseudo
console only picks up the console's handles when its parent's own standard handles are console
handles. Give the host a redirected stdout and the child inherits *that* instead, so its output
never reaches the pty and the screen stays empty. The host therefore runs hidden, with its own
console, and logs to a file rather than to stdout.

**A pseudo console's byte stream belongs to whoever created it.** Nobody can attach later and
recover the state, the way any process can attach to a console and read conhost's grid. So a
session is a resident host process (`PtyHost.ps1`) that owns the pty and the emulator and answers
requests on a named pipe; the cmdlets are thin clients. Its parameters travel in a file, because a
command line with quotes in it does not survive being passed as a process argument.

## Mouse, and the console host

Mouse works, in both of fzf's renderers and in Neovim, with one delivery: SGR reports. The console
host adapts — it turns them into `INPUT_RECORD`s for an application that reads console input, and
passes them through for one that parses VT itself — which is a terminal's job, and why nothing
here needs to know which kind an application is.

That only holds with a **current console host**. `kernel32!CreatePseudoConsole` binds to the
machine's own conhost — 10.0.19041.1 here, which is Windows 10 2004, from 2020 — and it forwards
no mouse in either direction: a client enabling `ENABLE_MOUSE_INPUT` produced no request outward,
and injected reports produced no records. A newer host has the plumbing
(`src/host/getset.cpp:383` asks the terminal for mouse,
`src/terminal/parser/InputStateMachineEngine.cpp:402` converts the reports back).

Microsoft ships one for exactly this, and it is not a Windows Terminal thing:
**`Microsoft.Windows.Console.ConPTY`** on nuget.org, MIT, built from microsoft/terminal, described
as working "on all versions of Windows 10.0.17763.0 and above". It carries `conpty.dll`, whose
`ConptyCreatePseudoConsole` is `CreatePseudoConsole` against a bundled `OpenConsole.exe`. The
`pty-harness` workload fetches both into `lib\` with the hash pinned, and `Start-PtyProcess`
prefers them; `-ConsoleHost Inbox` forces kernel32's, and `$env:PTYHARNESS_CONPTY_DLL` points the
library somewhere else.

The difference, measured with one wheel event into full-screen fzf:

| Host | Selection |
|---|---|
| inbox conhost | `item 1` → `item 1` |
| `conpty.dll` + OpenConsole 1.24 | `item 1` → `item 6` |

This is what node-pty does too — it vendors the same two binaries — except that its `useConptyDll`
flag **defaults to false**, so anything using node-pty as it comes gets the inbox host and this
same gap. VS Code opts in.

Two things worth knowing:

- **conpty.dll falls back to the inbox conhost, silently.** `_ConsoleHostPath` in
  `winconpty.cpp` looks for `OpenConsole.exe` beside the loaded module, then in an architecture
  subdirectory (`x64\`), and if neither is there it quietly uses `conhost.exe` — costing mouse with
  no error anywhere. So `Get-ConptyLibraryPath` requires *both* files before reporting the library
  as usable, and a test asserts an `OpenConsole.exe` process is really serving the pty.
- **The library has to be loaded by full path first.** `lib\` is on no search path, so
  `Initialize-Conpty` calls `NativeLibrary.Load`; after that the bare `[DllImport("conpty.dll")]`
  in `PtyNative.cs` resolves to the module already in the process. Loading it from `lib\` is also
  what makes it find the `OpenConsole.exe` we fetched, since it resolves the host relative to its
  own module path.

Before this, the harness hosted the pty by hand — `\Device\ConDrv\Server` and its `\Reference`
child through `NtOpenFile`, `OpenConsole.exe --headless --signal --server`, resize packets down
the signal pipe — with the binary copied out of `C:\Program Files\WindowsApps` (Windows refuses to
execute anything in there from outside the package). `ConptyCreatePseudoConsole` does all of that,
so those 343 lines of interop went away. One trap from it is worth keeping, because the package
exposes the same structure through `ConptyPackPseudoConsole`: an `HPCON` is not a handle, it points
at a `{ hSignal, hPtyReference, hConPtyProcess }` struct, and passing a bare handle to
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` makes the OS read a bogus pointer and **crash the calling
process** (0xC0000005 inside `CreateProcessW`) rather than fail.

## The screen, and what has scrolled off

`Get-PtyScreen` returns the visible rows; `-Scrollback` returns everything the terminal still
holds, oldest first. The split isn't free: libghostty's formatter always emits history and
viewport together and doesn't pad blank rows, so the viewport can't be had by taking the last N
lines. What works is asking the terminal how many rows have scrolled off
(`GhosttyTerminalData.SCROLLBACK_ROWS`) and skipping that many — which reports 0 while an
application is on the alternate screen, so a full-screen program comes back whole.

## Answering what a program asks

Applications question the terminal — primary device attributes, XTVERSION, size and mode reports —
and expect answers on their input. The harness provides them: libghostty hands each reply to a
callback, the host queues it and writes it back to the pty after the write that produced it. Left
unanswered, a program can wait for a reply that never comes, and the query itself can end up drawn
on the screen (Neovim's `XTGETTCAP` did exactly that).

The callback is a host function in the module's own function table, since the wasm has no imports
to hang one on: wasmtime grows `__indirect_function_table` by one, and that index is the function
pointer. Two things about it are worth knowing, because both fail in the same unhelpful way:

- **The value passed to `ghostty_terminal_set` *is* the function pointer**, not a pointer to it.
  The header says "Pointer to the value to set", which is true of the other options but not of the
  callbacks: `setTyped` in ghostty's `terminal.zig` stores the argument itself. Passing a pointer
  to a cell holding the index makes libghostty call a wild table entry.
- **The callback's signature must match exactly** — `(i32, i32, i32, i32) -> ()` for
  `GhosttyTerminalWritePtyFn`, and the delegate must take `Caller` so it can reach memory without
  re-entering the store.

Get either wrong and **the process dies silently**: no exception, no wasmtime trap, no output.
That is worth knowing in itself, and it is not ghostty's doing — a four-line `.wat` module with a
deliberately mismatched `call_indirect` kills the process the same way.

## Colours and styles

`Get-PtyScreen -As` gives the same screen four ways. This is the harness's reason to exist as much
as mouse is: conhost's grid carries only legacy 4-bit attributes, so an application's 24-bit
colours are gone before ConsoleHarness could read them.

| `-As` | What comes back | What it's for |
|---|---|---|
| `Text` (default) | `string[]`, one per row | everything that doesn't care how it looked |
| `Vt` | one string of escape sequences | golden files, or replaying the screen elsewhere |
| `Html` | a whole page | looking at what an application drew |
| `Styled` | one object per row, each with `Runs` | assertions |

`Get-PtyStyleAt -Row -Column` answers about one position and reads only that row; `Find-PtyText
-Pattern -WithStyle` matches a regular expression against each row and hands back the runs each
match falls in. Rows and columns are zero-based, from the top-left of the viewport. `Text` and
`Vt` take `-Scrollback`; `Html` and `Styled` are the viewport only, and refuse it rather than
ignore it.

```powershell
(Find-PtyText $session 'error' -WithStyle).Runs[0].EffectiveForeground.Hex   # -> #cc6666
(Get-PtyScreen $session -As Styled)[3].Runs | Where-Object Bold
Get-PtyScreen $session -As Html | Set-Content screen.html
```

A run is a stretch of cells sharing every attribute: `Column`, `Text`, `Bold`, `Italic`, `Faint`,
`Blink`, `Inverse`, `Invisible`, `Strikethrough`, `Overline`, `Underline` (`None`, `Single`,
`Double`, `Curly`, `Dotted`, `Dashed`), and four colours. Trailing blanks that carry no styling are
dropped, so a short row is short; a coloured background reaching the edge is not blank and stays.

Three decisions behind it:

- **Raw and effective colour, both.** `Foreground`/`Background` are what the application wrote;
  `EffectiveForeground`/`EffectiveBackground` are what you would see, with the terminal's defaults
  filled in and `inverse` applied. Most assertions want the effective pair — a highlighted row is
  usually inverse rather than literally coloured — but the raw one is what proves an application
  used the default colour rather than an explicit match for it. Nothing else is folded in: `faint`
  and `invisible` stay flags, because a test asserting on the colour of invisible text wants the
  colour it was given.
- **Resolve the palette, keep the tag.** A colour is
  `{ Kind = Default | Palette | Rgb; Index; R; G; B; Hex }`. `palette:1` is not what a test wants to
  compare against, so the RGB is looked up — in the terminal's *active* palette, so an application
  that redefines a colour with OSC 4 is reported honestly.
- **Walk the cells in C#.** A 100x30 screen is 3000 cells and each needs a handful of calls into
  wasm. From PowerShell, with a ScriptMethod and a `ValueBox[]` per call, that crawls; from C# it
  is milliseconds. `GhosttyScreenReader.cs` does the whole walk and the run-coalescing, and returns
  plain objects that `ConvertTo-Json` sends over the pipe.

Two things about the libghostty side, since both cost time:

- **The render state's iterators are populated, not returned.** You make a row iterator and a
  row-cells container yourself, then hand each to `ghostty_render_state_get(ROW_ITERATOR)` /
  `ghostty_render_state_row_get(CELLS)` to be filled — so the out-parameter is a pointer to a cell
  holding the handle, never the handle itself (`render.zig` reads it as `out.* orelse`, i.e. it
  dereferences what you pass). Hand it the handle and it dereferences a bogus pointer, which is
  the same shape of mistake as the callback above.
- **`FG_COLOR` / `BG_COLOR` return `INVALID_VALUE` when there is no colour**, which is the normal
  case, not an error. They resolve the palette but do not apply `inverse` (`render.zig`,
  `rowCellsGetTypedInner`); that is the caller's job, and here it is done once so tests needn't.

**The HTML is ours, not libghostty's.** Its own HTML formatter looked like the obvious answer and
isn't, for two measured reasons: it emits the scrollback along with the viewport and can't be told
not to (the formatter resolves its optional selection once, at construction, so a viewport
selection would go stale as content scrolls), and it names palette colours as
`var(--vt-palette-N)` while defining none of them, so on its own every palette colour renders as
nothing. `-As Html` is therefore built from the same runs as `-As Styled`, where the colours are
already resolved and `inverse` already applied.

The same "emits history too" applies to `-As Vt`, which does come from the formatter: there the
rows are lines, each starting with its own `ESC[0m`, so the viewport is taken the way the text
path takes it — by dropping the rows the terminal says have scrolled off.

**Runs can be one cell wider than the escape sequences suggest.** The program's output reaches
libghostty through the console host, which renders it into its own grid and re-emits it, and a
space written after an attribute reset can come back carrying the old attribute. Assert on
`Text.Trim()` or on a run's colours rather than on exact run boundaries.

## Pieces

| File | What it does |
|---|---|
| `PtyHarness.psm1` | the cmdlets, and the encoder from key events to terminal bytes |
| `PtyHost.ps1` | the resident host: pty, emulator, named-pipe server |
| `PtyNative.ps1` | picks the console host, and wraps the interop |
| `PtyNative.cs` | ConPTY interop, against either `conpty.dll` or kernel32 |
| `Ghostty.ps1` | libghostty-vt in wasmtime: write bytes, read the screen, resize |
| `GhosttyReplySink.cs` | the callback that collects the terminal's answers to a program's queries |
| `GhosttyScreenReader.cs` | the cell walk: colours, attributes, and coalescing them into runs |
| `QueryProbe.ps1` | a fixture that asks the terminal a question and prints the answer |
| `ColourProbe.ps1` | a fixture that draws a screen with known colours and attributes |
| `vendor/` | the emulator itself, and where it came from |
| `lib/` | wasmtime and the console host, fetched by the `pty-harness` workload (gitignored) |

## Tests

```powershell
pwsh -File .	ools\PtyHarness\Test-PtyHarness.ps1
```

They run real programs (cmd.exe, fzf) under a pseudo console: keyboard, resize that the program
notices, colours and attributes in all four forms, session pickup from another process, cleanup,
and mouse in both fzf renderers. The mouse ones are skipped when fzf isn't on PATH, and everything
is skipped when the workload hasn't fetched wasmtime.
