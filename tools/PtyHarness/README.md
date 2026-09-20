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
which is how you find out what it actually asked the terminal for.

## Which harness to use

| | [ConsoleHarness](../ConsoleHarness/README.md) | PtyHarness |
|---|---|---|
| How the screen is read | conhost renders it; we read the character grid | we render the VT stream ourselves |
| Dependencies | none (Win32 only) | wasmtime + a vendored wasm, ~22 MB |
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

That only holds with **Windows Terminal's console host**. `CreatePseudoConsole` binds to the
machine's inbox conhost (10.0.19041.1 here), which forwards no mouse in either direction: a client
enabling `ENABLE_MOUSE_INPUT` produced no request outward and injected reports produced no records.
Windows Terminal doesn't use it either; it ships `OpenConsole.exe` (1.21.2502.04001) and launches
that as its pty host, which has the plumbing — `src/host/getset.cpp:383` asks the terminal for
mouse, `src/terminal/parser/InputStateMachineEngine.cpp:402` converts the reports back.

So `Start-PtyProcess` hosts the pty itself rather than calling `CreatePseudoConsole`, following
`winconpty`: open `\Device\ConDrv\Server` and its `\Reference` child through `NtOpenFile`, spawn
`OpenConsole.exe --headless --width --height --signal --server` with exactly four handles
inherited, then start the application with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. Resizes go down
the signal pipe as a packet, since `ResizePseudoConsole` only knows about consoles kernel32 made.

Two things that cost time, in case they come up again:

- **That attribute takes an `HPCON`, not a handle.** An `HPCON` points at a
  `{ hSignal, hPtyReference, hConPtyProcess }` struct, which the OS dereferences; passing the
  reference handle directly makes it read a bogus pointer and **crashes the calling process**
  (0xC0000005 inside `CreateProcessW`) rather than failing.
- **OpenConsole cannot be run from where Windows Terminal keeps it.** Executing anything inside
  `C:\Program Files\WindowsApps` from outside the package fails with "Access is denied", so
  `Get-OpenConsolePath` copies it next to the harness (`lib\OpenConsole.exe`, gitignored) and
  refreshes the copy when Terminal's version changes. `$env:PTYHARNESS_CONSOLE_HOST` overrides,
  and `Start-PtyProcess -ConsoleHost Inbox` uses `CreatePseudoConsole` instead.

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

## Planned: colours and styles

The screen currently comes back as text. libghostty has everything needed to do better, and this
is the design that was settled on (2026-09-19) before writing any of it.

**Three representations, very different costs.**

1. *Snapshot formats* — `Get-PtyScreen -As Html|Vt`. This is one field in the formatter options
   struct that is already built (`emit`, offset 4): `GhosttyFormatterFormat` is
   `PLAIN=0, VT=1, HTML=2`. Minutes of work. Good for golden-file tests and for looking at what an
   application drew (HTML opens in a browser); poor for assertions, since "is this red" becomes a
   regular expression over markup, and any unrelated style change rewrites the snapshot.
2. *Structured styled runs* — `Get-PtyScreen -Styled` returning, per row, runs of
   `{ Text, Foreground, Background, Bold, Italic, Underline, Inverse, ... }`. This is what makes a
   test read well: `(Get-PtyScreen $s -Styled | Where-Object { $_.Text -match 'error' }).Foreground.Rgb`.
3. *Point queries* — `Get-PtyStyleAt -Row -Column`, `Find-PtyText -Pattern -WithStyle`. Same
   bindings as (2) but only materialising what was asked for, which is where most assertions land.

Do (1) first because it is nearly free, then (2) and (3) together since they share all the work.

**Three decisions worth keeping.**

- **Raw and effective colour, both.** A highlighted row is often `inverse` rather than literally
  red-on-white, and a default foreground carries no colour at all. Expose `Foreground`/`Background`
  as the application wrote them *and* `EffectiveForeground`/`EffectiveBackground` with inverse and
  palette defaults resolved. Tests usually want the effective pair; the raw one is what proves an
  application used the default colour rather than an explicit match for it.
- **Resolve the palette, keep the tag.** A colour is `{ Kind = Default|Palette|Rgb; Index; R,G,B }`
  with RGB resolved through `ghostty_color_palette_default`, because `palette:1` is not what a test
  wants to assert against.
- **Extract in C#, not PowerShell.** A 100x30 screen is 3000 cells; walking them one at a time
  across the wasm boundary from PowerShell will crawl. It belongs beside `GhosttyReplySink.cs`,
  returning whole rows in one pass. `ghostty_cell_get_multi` / `ghostty_row_get_multi` and the
  render-state row iterators exist for exactly this.

**The ABI, already looked up** (from `ghostty_type_json()`, so it needn't be derived again):

| Type | Size | Fields |
|---|---|---|
| `GhosttyStyle` | 72 | `size@0`, `fg_color@8`, `bg_color@24`, `underline_color@40` (each `GhosttyStyleColor`), `bold@56`, `italic@57`, `faint@58`, `blink@59`, `inverse@60`, `invisible@61`, `strikethrough@62`, `overline@63`, `underline@64` (i32) |
| `GhosttyStyleColor` | 16 | `tag@0` (`NONE=0, PALETTE=1, RGB=2`), `value@8` |
| `GhosttyColorRgb` | 3 | `r@0, g@1, b@2` |
| `GhosttyCellsView` | 8 | `ptr@0`, `len@4` |

Relevant exports: `ghostty_cell_get(_multi)`, `ghostty_row_get(_multi)`, `ghostty_style_default`,
`ghostty_style_is_default`, `ghostty_color_rgb_get`, `ghostty_color_palette_default`, and
`ghostty_render_state_row_cells_*`.

**Why it belongs here and not in ConsoleHarness:** conhost's grid carries only legacy 4-bit
attributes, so an application's 24-bit colours are gone before that harness could read them.
Styles would be a real reason to reach for the pty.

## Pieces

| File | What it does |
|---|---|
| `PtyHarness.psm1` | the cmdlets, and the encoder from key events to terminal bytes |
| `PtyHost.ps1` | the resident host: pty, emulator, named-pipe server |
| `PtyNative.ps1` | picks the console host, and wraps the interop |
| `PtyNative.cs` | ConPTY through `CreatePseudoConsole` (the inbox host) |
| `PtyNativeOpenConsole.cs` | a pty hosted by Windows Terminal's OpenConsole, winconpty's way |
| `Ghostty.ps1` | libghostty-vt in wasmtime: write bytes, read the screen, resize |
| `GhosttyReplySink.cs` | the callback that collects the terminal's answers to a program's queries |
| `QueryProbe.ps1` | a fixture that asks the terminal a question and prints the answer |
| `vendor/` | the emulator itself, and where it came from |
| `lib/` | wasmtime, fetched by the `pty-harness` workload (gitignored) |

## Tests

```powershell
pwsh -File .	ools\PtyHarness\Test-PtyHarness.ps1
```

They run real programs (cmd.exe, fzf) under a pseudo console: keyboard, resize that the program
notices, session pickup from another process, cleanup, and mouse in both fzf renderers. The mouse
ones are skipped when fzf isn't on PATH, and everything is skipped when the workload hasn't
fetched wasmtime.
