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

`Send-ConsoleKeys` uses [AutoHotkey v2's `Send`
syntax](https://www.autohotkey.com/docs/v2/lib/Send.htm), so text is just text and keys are named
in braces:

| Written | Sends |
|---|---|
| `find me` | those characters, including spaces and commas |
| `{Enter}` | the Enter key. Also `{Tab}` `{Esc}` `{Space}` `{BS}` `{Del}` `{Ins}` `{Up}` `{Down}` `{Left}` `{Right}` `{Home}` `{End}` `{PgUp}` `{PgDn}` `{F1}`–`{F24}` |
| `^s` `!x` `+a` | Ctrl+S, Alt+X, Shift+A — the prefix applies to the next key only |
| `^{Enter}` | Ctrl+Enter |
| `{BS 3}` `{a 5}` | a repeat count |
| `{Ctrl down}jk{Ctrl up}` | holds a modifier across several keys |
| `{^}` `{!}` `{+}` `{#}` `{{}` `{}}` | those characters, typed |
| `{U+263A}` | a character by code point |
| `{Raw}…` | the rest of the string literally |
| `{Click 40 10}` | click at column 40, row 10 of the visible window |
| `{Click 40 10 Right}` `{Click 3}` `{Click 40 10 0}` | another button, a repeat count, or move without clicking |
| `{LButton down}` … `{LButton up}` | drag. Also `{RButton}` `{MButton}` `{XButton1}` `{XButton2}` |
| `{WheelDown 3}` `{WheelUp}` `{WheelLeft}` `{WheelRight}` | the wheel, one event per notch |

Mouse coordinates stick: a token without them uses the last position, and with none given at all,
the middle of the window. See below for which apps can receive them.

Words like `enter` and `tab` are text, so `Send-ConsoleKeys $session 'enter'` types five
characters. For a string where *nothing* should be syntax — a path, a variable, something the app
itself printed — use `Send-ConsoleText`, the counterpart to AutoHotkey's `SendText`:

```powershell
Send-ConsoleText $session 'C:\src\a,b{x}^y'
```

Several arguments are sent one after another with nothing in between, so
`Send-ConsoleKeys $s 'a', 'b'` and `Send-ConsoleKeys $s 'ab'` are the same thing.

Differences from AutoHotkey, all because the target is a console app rather than a window:

- `#` (Win) and the mouse, media and `{Blind}` features are rejected with an error: nothing
  reaches a console app through them.
- `{Ctrl}` on its own is an error. A console app sees modifiers only as flags on another key, so
  use `^x` or `{Ctrl down}`…`{Ctrl up}`.
- `{Raw}` and `{Text}` mean the same thing here, and so does `Send-ConsoleText` (AHK's `{Text}`
  and `SendText` only pick a different injection method). A newline in literal text is still
  Enter and a tab is still Tab, as they would be if the text were typed.

## Size, and the scrollback behind the window

```powershell
$info = Get-ConsoleInfo $session          # size, cursor, input mode, and WindowTop
Set-ConsoleSize $session -Width 80 -Height 25    # the app sees a resize event and reflows

Get-ConsoleScreen $session -Scrollback           # the whole buffer, oldest row first
Get-ConsoleScreen $session -FromRow 120 -Rows 10
Move-ConsoleView $session -Lines -20             # scroll back, as dragging the scrollbar would
Move-ConsoleView $session -Start                 # or -End, or -Top <row>
```

`WindowTop` is where the visible window sits in the buffer: the scroll position. Rows above it are
what has scrolled off. `Start-ConsoleApp -BufferHeight` sets how much of that is kept (1000 rows by
default); a full-screen app on the alternate screen buffer has none, by definition.

Resizing takes one of two routes, and `Set-ConsoleSize` picks for itself. Normally it resizes the
buffer and window directly. While an app holds the **alternate screen buffer** (Neovim, fzf),
conhost answers every `SetConsoleScreenBufferSize` and `SetConsoleWindowInfo` with
`ERROR_INVALID_HANDLE`, so it resizes conhost's own window instead, which still reflows and still
tells the app. That path converges over a few attempts rather than computing once: shrinking a
console can take its scrollbar away, which changes the window chrome mid-resize and otherwise
lands a few columns short.

## Sessions outlive the process that started them

The app runs in its own console, so it keeps running after the PowerShell process that started it
exits. Give it a name and pick it up later — from another script, another shell, or a later step
of the same job:

```powershell
Start-ConsoleApp -Command 'nvim README.md' -Name editor    # one process

$session = Get-ConsoleApp -Name editor                     # another process, later
Send-ConsoleKeys $session ':w{Enter}'
Stop-ConsoleApp $session
```

`Get-ConsoleApp` with no arguments lists everything still running, and prunes the records of
sessions that have ended. Records live in `%TEMP%\console-harness`, alongside the screens; a
recorded id that has been reused by an unrelated process is spotted by its start time and
discarded. `Stop-ConsoleApp -All` stops the lot, which is the way out of a script that failed
before its `finally`.

`Stop-ConsoleApp` kills the whole process tree. The app is a child of the PowerShell wrapper (and
a grandchild, when a mise shim is involved), so stopping only the wrapper would leave it running
in a console nothing is attached to.

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
  alike. Under Windows Terminal the same fzf handles all of those, because that's a ConPTY with
  VT input, where it gets SGR sequences. The legacy console host is the difference: conhost
  [doesn't forward wheel events to an app in alternate-screen mode](https://github.com/openai/codex/issues/12457),
  and [fzf's Windows notes](https://github.com/junegunn/fzf/wiki/Windows) target Windows Terminal.
  **So fzf's mouse behaviour can't be tested through this harness**; its keyboard behaviour can.
  Testing it would mean running the app under a ConPTY, which would also mean emulating a
  terminal to read the screen — the thing this design exists to avoid.
- Coordinates here are **character cells relative to the visible window**, 0-based, matching the
  row indices `Get-ConsoleScreen` returns — not pixels, and there is no `CoordMode` to change.

## How it works

The app runs in its own hidden console. Each call spawns a short-lived worker
(`ConsoleWorker.ps1`) that attaches to that console with `AttachConsole` and then:

- reads the visible character grid with `ReadConsoleOutputCharacter`;
- injects keys with `WriteConsoleInput`.

conhost has already turned the app's escape sequences into that grid, so there's no terminal
emulation here, and input doesn't depend on which window has focus. The worker is a separate
process because a process can only be attached to one console at a time.

Key specifications are parsed by `KeySpec.ps1` in the calling process, so a typo is an immediate
error rather than a worker exit code, and the worker only turns events into `INPUT_RECORD`s. The
events travel in a temp file: a command line would need a delimiter, and any delimiter would be a
character that then couldn't be typed.

## Tests

```powershell
pwsh -File .\tools\ConsoleHarness\Test-ConsoleHarness.ps1                 # parser + a real fzf
pwsh -File .\tools\ConsoleHarness\Test-ConsoleHarness.ps1 -SkipConsole    # parser only
```

## Limits

- Text only: no colours, no cursor shape. It sees the rendering, not the byte stream.
- Console apps only (it's not a GUI automation tool).
- Transient messages can be missed. With Neovim, `noice` shows `:version` and similar in a popup
  that fades, so assert on lasting UI state instead.
- Each call costs a worker start (~0.2 s), so poll with `Wait-ConsoleText` rather than in a tight
  loop.
