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

## Mouse: which delivery an application wants

Mouse events go one of two ways, and they are not interchangeable:

| `-MouseDelivery` | What is sent | Who wants it |
|---|---|---|
| `Vt` (default) | SGR reports typed into the input buffer, e.g. `ESC[<65;41;11M` | anything that parses VT itself: Neovim, fzf in `--height` mode |
| `Record` | `MOUSE_EVENT` records written with `WriteConsoleInput` | apps that read console input records: anything built on tcell, which includes full-screen fzf |

**SGR is the default** because that is what a modern terminal application expects. There is no
auto-detection: the console's input mode looks like a clue but isn't one, because an application
can parse SGR sequences from its own input without ever setting `ENABLE_VIRTUAL_TERMINAL_INPUT` —
fzf's light renderer does exactly that. The harness cannot see what the application wrote outward,
so it cannot know. When mouse events appear to be ignored, try the other delivery.

### Known application quirks

Record what you learn here; it is cheaper than rediscovering it.

| Application | Delivery | Notes |
|---|---|---|
| Neovim | `Vt` | Routes by position: with a vertical split, a wheel at column 20 scrolls the left window and one at column 90 the right. |
| fzf, full screen | `Record` | Uses the tcell renderer (`//go:build tcell || windows`), which reads console records. SGR would arrive as a bare `ESC`, which fzf takes as abort and exits. |
| fzf, `--height` | `Vt` | Uses its light renderer, which enables `?1000h`/`?1006h` itself and parses SGR out of its input buffer (`src/tui/light.go`). Console records are ignored. |

fzf chooses between the two at startup — `terminal.go` picks `NewFullscreenRenderer` when it is
full screen and `NewLightRenderer` otherwise — so the same program wants different delivery
depending on one command-line flag. Expect other applications to have their own opinion.

### Aim inside the application's box

Mouse events land at character cells of the visible window, 0-based, matching the row indices
`Get-ConsoleScreen` returns — not pixels, and there is no `CoordMode`. An application ignores
events outside the area it drew, which looks exactly like "mouse doesn't work":

```powershell
# Find out where it actually is, rather than guessing.
$screen = Get-ConsoleScreen $session
for ($i = 0; $i -lt $screen.Count; $i++) { '{0,3}: {1}' -f $i, $screen[$i] }
```

With `--height 60%` in a 30-row console, fzf drew its list in rows 1-14 and its prompt at row 16;
wheel events aimed at row 20 were below the box and correctly ignored.

### How this was established

- **Injected records really are delivered.** A test app that enables mouse input and logs every
  record it reads (`InputSink.ps1`) saw ours exactly as sent:
  `MOUSE pos=7,3 buttons=0xff100000 flags=0x4` for a wheel, press/release pairs for a click. A
  small tcell program reported the same events as `buttons=512` (tcell's `WheelDown`), which is
  the library fzf uses — so when an application does nothing, look at the application, the
  delivery and the coordinates, in that order.
- **The wheel delta lives in the high word of `dwButtonState`**, 120 per notch, negative for
  scrolling down. Two arithmetic traps in PowerShell: build it in 64-bit, because
  `65176 -shl 16` overflows `Int32` into a negative that won't cast to `uint32`; and a delta that
  encodes to `0x00000000` is silently ignored by the application rather than rejected.

### Aside: why fzf's mouse works in Windows Terminal

Windows Terminal does not use this machine's console host. It ships `OpenConsole.exe`
1.21.2502.04001 and launches that as its pty host — `src/winconpty/winconpty.cpp:45-58` in the
terminal source returns "the path to either conhost.exe or the side-by-side OpenConsole",
preferring the bundled one — while this machine's inbox `conhost.exe` is 10.0.19041.1.

The newer host has mouse plumbing the old one lacks, in both directions: `src/host/getset.cpp:383`
asks the terminal for mouse (`ESC[?1003;1006h`) when a client turns on `ENABLE_MOUSE_INPUT`, and
`src/terminal/parser/InputStateMachineEngine.cpp:402` turns SGR reports back into `INPUT_RECORD`
mouse events. Measured against the inbox host, through a pty, neither half happens: enabling
`ENABLE_MOUSE_INPUT` produced no request outward, and injected SGR reports produced no records
(they arrived as literal keystrokes). That matters for `tools\PtyHarness`, which inherits the old
host from `CreatePseudoConsole`; it does not affect this harness, which injects into the console
directly.

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
