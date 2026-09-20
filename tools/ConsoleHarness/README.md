# ConsoleHarness

Drives an interactive console app and reads what it drew, so terminal UIs (fzf pickers, Neovim,
prompts) can be tested from a script.

```powershell
Import-Module .\tools\ConsoleHarness

$session = Start-ConsoleApp -Command '. "$HOME\.config\powershell\profile.d\40-fzf-functions.ps1"; _fzf_select_path'
try {
    Wait-ConsoleText $session 'Files> '                  # instead of sleeping
    Send-ConsoleKeys $session 'psfzf'                    # type
    $screen = Send-ConsoleKeys $session '^s'             # Ctrl+S; returns the redrawn screen
    $screen -match 'Directories> '
} finally {
    Stop-ConsoleApp $session                             # always, even after a failure
}
```

## Key syntax

Keys are written in [AutoHotkey v2's `Send` syntax](https://www.autohotkey.com/docs/v2/lib/Send.htm)
— `'find{Enter}'`, `'^s'`, `'{BS 3}'`, `'{Click 40 10}'`, `'{WheelDown 3}'` — which the
[KeySpec module](../KeySpec/README.md) parses and documents in full.

Words like `enter` and `tab` are text, so `Send-ConsoleKeys $session 'enter'` types five
characters. For a string where *nothing* should be syntax — a path, a variable, something the app
itself printed — use `Send-ConsoleText`, the counterpart to AutoHotkey's `SendText`:

```powershell
Send-ConsoleText $session 'C:\src\a,b{x}^y'
```

Several arguments are sent one after another with nothing in between, so
`Send-ConsoleKeys $s 'a', 'b'` and `Send-ConsoleKeys $s 'ab'` are the same thing. Mouse
coordinates are character cells of the visible window, matching the row indices
`Get-ConsoleScreen` returns; which apps can actually receive them is the next section.

## Mouse: two delivery paths, and which apps take which

An app can receive mouse input in one of two ways, and they are not interchangeable. Which one
applies is visible in the console's input mode (`Get-ConsoleInfo`):

| Input mode | How the app gets mouse | Apps seen doing this |
|---|---|---|
| `ENABLE_VIRTUAL_TERMINAL_INPUT` (`0x200`) | SGR escape sequences typed into the input buffer, e.g. `ESC[<65;41;11M` | Neovim (mode `0x208`) |
| `ENABLE_MOUSE_INPUT` (`0x10`), no VT | `MOUSE_EVENT` records written with `WriteConsoleInput` | fzf (mode `0x98`) |

`Send-ConsoleKeys` reads the mode and picks the path; `-MouseDelivery Record|Vt` overrides it.

This was worked out by experiment, and the details cost enough to be worth writing down:

- **Injected mouse records really are delivered.** A test app that enables mouse input and logs
  every record it reads (`ReadConsoleInput`) saw ours exactly as sent:
  `MOUSE pos=7,3 buttons=0xff100000 flags=0x4` for a wheel, press/release pairs for a click. So
  when an app does nothing, the app is ignoring them — the injection is not at fault.
- **The wheel delta lives in the high word of `dwButtonState`**, 120 per notch, negative for
  scrolling down. Two arithmetic traps in PowerShell: build it in 64-bit, because
  `65176 -shl 16` overflows `Int32` into a negative that won't cast to `uint32`; and a delta that
  encodes to `0x00000000` is silently ignored by the app rather than rejected.
- **Neovim ignores mouse records** (it runs with VT input), but acts on SGR sequences, and routes
  them by position: with a vertical split, a wheel at column 20 scrolled the left window only and
  one at column 90 the right window only.
- **fzf takes neither, in a hidden console.** It enables `ENABLE_MOUSE_INPUT`, yet ignored wheel,
  clicks, double-clicks and move-then-wheel, in the list, in the preview pane and outside its box
  alike. **Why is still open** — see the correction below. Its keyboard behaviour tests fine.
- Coordinates here are **character cells relative to the visible window**, 0-based, matching the
  row indices `Get-ConsoleScreen` returns — not pixels, and there is no `CoordMode` to change.

### Correction: why fzf's mouse works in Windows Terminal (2026-09-19)

An earlier version of this file claimed fzf gets mouse under Windows Terminal "because that's a
ConPTY with VT input". That was wrong, and the real reason is worth knowing, because it explains
what would have to change here.

**Windows Terminal does not use this machine's console host.** It ships its own and launches that
as the pty host — `src/winconpty/winconpty.cpp:45-58` in the terminal source returns "the path to
either conhost.exe or the side-by-side OpenConsole", preferring the bundled one:

| | |
|---|---|
| Bundled with Windows Terminal 1.21 | `OpenConsole.exe` 1.21.2502.04001 |
| This machine's inbox host | `conhost.exe` 10.0.19041.1 |

The modern host has mouse plumbing in both directions, and the old one does not:

- outbound (`src/host/getset.cpp:383`): when a client turns on `ENABLE_MOUSE_INPUT` with quick-edit
  off, the host sends `ESC[?1003;1006h` to the terminal, asking it to report mouse;
- inbound (`src/terminal/parser/InputStateMachineEngine.cpp:402`): SGR mouse reports become
  `INPUT_RECORD` mouse events, with no mouse-mode gate — only a passthrough when the client has
  virtual-terminal input enabled.

So under Windows Terminal, fzf receives mouse as ordinary console records, synthesised by
OpenConsole from the SGR reports WT sends it. Measured against the inbox host used by
`CreatePseudoConsole` on this machine, neither half happens: a client enabling `ENABLE_MOUSE_INPUT`
produced no `ESC[?1003;1006h`, and injected SGR reports produced no records at all (they arrived
as literal keystrokes). It is a version gap, not a design limit.

Two consequences:

- A pty harness only helps with fzf's mouse if it hosts the pty with **WT's OpenConsole.exe**, the
  way `winconpty` does (`--headless --width --height --signal --server`, child attached through
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`). Plain `CreatePseudoConsole` inherits the old host and
  the old behaviour. See `tools\PtyHarness`.
- **Why fzf ignores records injected here is still unknown.** Records demonstrably arrive, and
  under WT fzf acts on records of the same shape, so something about fzf's Windows input path is
  the missing piece rather than the injection.

## How it works

The app runs in its own hidden console. Each call spawns a short-lived worker
(`ConsoleWorker.ps1`) that attaches to that console with `AttachConsole` and then:

- reads the visible character grid with `ReadConsoleOutputCharacter`;
- injects keys with `WriteConsoleInput`.

conhost has already turned the app's escape sequences into that grid, so there's no terminal
emulation here, and input doesn't depend on which window has focus. The worker is a separate
process because a process can only be attached to one console at a time.

Key specifications are parsed by the [KeySpec module](../KeySpec/README.md) in the calling
process, so a typo is an immediate error rather than a worker exit code, and the worker only turns
events into `INPUT_RECORD`s. The
events travel in a temp file: a command line would need a delimiter, and any delimiter would be a
character that then couldn't be typed.

## Tests

```powershell
pwsh -File .\tools\Test-Tools.ps1                            # every tool's tests
pwsh -File .\tools\ConsoleHarness\Test-ConsoleHarness.ps1   # these drive a real fzf
```

`InputSink.ps1` is a fixture: a console app that logs every input record it reads, so the
tests can assert what actually arrived rather than how some other app reacted to it.

```powershell
pwsh -File .\tools\Test-Tools.ps1 -Name KeySpec              # just one module
```

## Limits

- Text only: no colours, no cursor shape. It sees the rendering, not the byte stream.
- Console apps only (it's not a GUI automation tool).
- Transient messages can be missed. With Neovim, `noice` shows `:version` and similar in a popup
  that fades, so assert on lasting UI state instead.
- Each call costs a worker start (~0.2 s), so poll with `Wait-ConsoleText` rather than in a tight
  loop.
