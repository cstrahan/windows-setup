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

## Known gaps

- **`Get-PtyScreen` returns the scrollback as well as the viewport**: 20 lines of output in a
  10-row terminal comes back as 20 lines, oldest first. libghostty's formatter formats the whole
  screen, and blank rows are not padded, so the viewport can't be recovered by taking the last N
  lines. The fix is to pass the formatter a selection covering the viewport, built from
  `GHOSTTY_POINT_TAG_VIEWPORT` points through `ghostty_terminal_grid_ref`; the struct layouts come
  from `ghostty_type_json()`.
- **Terminal queries go unanswered.** An application that asks the terminal something gets no
  reply — Neovim's `XTGETTCAP` request ended up drawn on the screen as text. Replies come from
  `GHOSTTY_TERMINAL_OPT_WRITE_PTY`, which takes a **function pointer**, and the wasm module has no
  imports, so a host function cannot simply be handed to it. It is still possible: the module
  exports `__indirect_function_table`, and wasmtime can put a host function in a table slot, whose
  index is then the function pointer. Worth doing before this harness is trusted for real work.
- Colours and styles are discarded: the screen comes back as text.

## Pieces

| File | What it does |
|---|---|
| `PtyHarness.psm1` | the cmdlets, and the encoder from key events to terminal bytes |
| `PtyHost.ps1` | the resident host: pty, emulator, named-pipe server |
| `PtyNative.ps1` | picks the console host, and wraps the interop |
| `PtyNative.cs` | ConPTY through `CreatePseudoConsole` (the inbox host) |
| `PtyNativeOpenConsole.cs` | a pty hosted by Windows Terminal's OpenConsole, winconpty's way |
| `Ghostty.ps1` | libghostty-vt in wasmtime: write bytes, read the screen, resize |
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
