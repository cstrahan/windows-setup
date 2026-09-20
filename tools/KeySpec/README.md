# KeySpec

Turns a string of keystrokes into input events, in [AutoHotkey v2's `Send`
syntax](https://www.autohotkey.com/docs/v2/lib/Send.htm): text is just text, and keys are named in
braces. Nothing here touches a console — it produces events, and a harness decides how to deliver
them — so it can be shared between harnesses and tested on its own.

```powershell
Import-Module .\tools\KeySpec
ConvertFrom-KeySpec 'find{Enter}'
ConvertFrom-KeySpec '{Enter}' -Literal   # the seven characters, not the key
```

`ConvertFrom-KeySpec` returns the events as **one array object**, so an empty specification stays
empty. Assign the result before piping it, or the pipeline treats the whole array as a single item.

## Syntax

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

Mouse coordinates stick: a token without them uses the last position, and `-1` means "nowhere has
been said", which the harness resolves (ConsoleHarness uses the middle of the window).

Words like `enter` and `tab` are text, so `ConvertFrom-KeySpec 'enter'` types five characters. For
a string where *nothing* should be syntax — a path, a variable, something an app printed — pass
`-Literal`, the counterpart to AutoHotkey's `SendText`.

Differences from AutoHotkey, because the target is a terminal rather than a window:

- `#` (Win) and the media and `{Blind}` features are rejected with an error: nothing reaches a
  terminal application through them.
- `{Ctrl}` on its own is an error. An app sees modifiers only as flags on another key, so use
  `^x` or `{Ctrl down}`…`{Ctrl up}`.
- `{Raw}` and `{Text}` mean the same thing here (AHK's `{Text}` only picks a different injection
  method). A newline in literal text is still Enter and a tab is still Tab.

## Events

One object per event, with `Type` telling them apart:

- **Key** — `VirtualKey`, `CharCode`, `ControlState` (the console `dwControlKeyState` flags) and
  `KeyDown`, which is one console `INPUT_RECORD` each.
- **Mouse** — `X`, `Y` (cells, relative to the visible window), `Button`, `Action`
  (`Down`/`Up`/`Move`/`Wheel`), `Notches`, `WheelAxis` and `ControlState`.

The key events are shaped for console input records, which is what the first consumer needed. A
pty-based harness will want the key's name and modifiers as well, to hand to an encoder; that's a
field to add when there's something to test it against.

## Tests

```powershell
pwsh -File .\tools\KeySpec\Test-KeySpec.ps1
```
