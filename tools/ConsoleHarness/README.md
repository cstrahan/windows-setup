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
