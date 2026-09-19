# ConsoleHarness

Drives an interactive console app and reads what it drew, so terminal UIs (fzf pickers, Neovim,
prompts) can be tested from a script.

```powershell
Import-Module .\tools\ConsoleHarness

$session = Start-ConsoleApp -Command '. "$HOME\.config\powershell\profile.d\40-fzf-functions.ps1"; _fzf_select_path'
try {
    Wait-ConsoleText $session 'Files> '                  # instead of sleeping
    Send-ConsoleKeys $session 'psfzf'                    # type
    $screen = Send-ConsoleKeys $session 'ctrl-s'         # a chord; returns the redrawn screen
    $screen -match 'Directories> '
} finally {
    Stop-ConsoleApp $session                             # always, even after a failure
}
```

`Send-ConsoleKeys` takes key names (`enter`, `tab`, `esc`, `backspace`, `space`, `up`, `down`,
`left`, `right`, `home`, `end`, `pageup`, `pagedown`, `delete`), `ctrl-<letter>` / `alt-<letter>`
chords, or literal text.

## How it works

The app runs in its own hidden console. Each call spawns a short-lived worker
(`ConsoleWorker.ps1`) that attaches to that console with `AttachConsole` and then:

- reads the visible character grid with `ReadConsoleOutputCharacter`;
- injects keys with `WriteConsoleInput`.

conhost has already turned the app's escape sequences into that grid, so there's no terminal
emulation here, and input doesn't depend on which window has focus. The worker is a separate
process because a process can only be attached to one console at a time.

## Limits

- Text only: no colours, no cursor shape. It sees the rendering, not the byte stream.
- Console apps only (it's not a GUI automation tool).
- Transient messages can be missed. With Neovim, `noice` shows `:version` and similar in a popup
  that fades, so assert on lasting UI state instead.
- Each call costs a worker start (~0.2 s), so poll with `Wait-ConsoleText` rather than in a tight
  loop.
