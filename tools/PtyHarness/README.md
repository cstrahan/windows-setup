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
| Mouse | injects `INPUT_RECORD`s directly | see below |
| Fidelity | conhost's, including its quirks | a real terminal's: reflow, scrollback, styles |

ConsoleHarness remains the default. Reach for this one when the thing under test depends on
genuine terminal behaviour rather than on conhost's rendering of it.

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

## Mouse: not yet, and not the reason to use this

Mouse events are encoded here (SGR reports, from the same `{Click}` / `{WheelDown}` syntax) but do
not reach applications, because `CreatePseudoConsole` binds to this machine's **inbox** console
host, which neither asks the terminal for mouse when a client enables `ENABLE_MOUSE_INPUT` nor
turns SGR reports back into mouse records. Windows Terminal doesn't use that host — it ships
`OpenConsole.exe` and launches it as its pty host, and that one does both. The measurements and
source references are in
[ConsoleHarness's README](../ConsoleHarness/README.md#aside-why-fzfs-mouse-works-in-windows-terminal).

Fixing it means hosting the pty the way `winconpty` does: create the `\Device\ConDrv\Server`
handle and its `\Reference` child, spawn WT's `OpenConsole.exe --headless --width --height
--signal --server`, and attach the child through `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. Not done.

Note what this is *not* worth doing for: **ConsoleHarness already drives mouse in both fzf
renderers and in Neovim**, by injecting into the console directly. This harness would only add the
cases where a pty is the point — an application that insists on a real terminal, or behaviour that
depends on genuine VT semantics rather than conhost's rendering of them.

## Known gaps

- `Get-PtyScreen` returns the formatter's whole active screen, which includes scrollback: a
  20-row terminal can come back with 55 rows. The viewport and the history need separating, and
  scrollback deserves its own parameter as in ConsoleHarness.
- **Terminal queries go unanswered.** libghostty-vt reports things like device attributes and
  size through `GHOSTTY_TERMINAL_OPT_WRITE_PTY`, which isn't wired to the pty's input yet, so an
  application that asks a question gets no reply — Neovim's `XTGETTCAP` request ended up drawn on
  the screen as text. This should be connected before the harness is trusted for real work.
- No tests of its own yet.

## Pieces

| File | What it does |
|---|---|
| `PtyHarness.psm1` | the cmdlets, and the encoder from key events to terminal bytes |
| `PtyHost.ps1` | the resident host: pty, emulator, named-pipe server |
| `PtyNative.ps1` | ConPTY interop (`CreatePseudoConsole`, pipes, process attributes) |
| `Ghostty.ps1` | libghostty-vt in wasmtime: write bytes, read the screen, resize |
| `vendor/` | the emulator itself, and where it came from |
| `lib/` | wasmtime, fetched by the `pty-harness` workload (gitignored) |
