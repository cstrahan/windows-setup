# Tests for the KeySpec parser. Run it with pwsh (or powershell); nothing here touches a console.
#
#   pwsh -File tools\KeySpec\Test-KeySpec.ps1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'TestSupport.ps1')
Import-Module (Join-Path $PSScriptRoot 'KeySpec.psd1') -Force

# Renders parsed events compactly, for readable expectations: each key press as
# <modifiers>vk<code>:<character>, with '+' between a press and its release ('v' down, '^' up).
function Format-Events($Events) {
    $parts = foreach ($keyEvent in $Events) {
        $modifiers = ''
        if ($keyEvent.ControlState -band 0x000C) { $modifiers += 'C' }   # either Ctrl
        if ($keyEvent.ControlState -band 0x0003) { $modifiers += 'A' }   # either Alt
        if ($keyEvent.ControlState -band 0x0010) { $modifiers += 'S' }
        $character = if ($keyEvent.CharCode -eq 0) { '.' } else { '0x{0:x2}' -f $keyEvent.CharCode }
        '{0}{1}{2}:{3}' -f $(if ($keyEvent.KeyDown) { 'v' } else { '^' }), $modifiers, ('0x{0:x2}' -f $keyEvent.VirtualKey), $character
    }
    return $parts -join ' '
}

Write-Host 'Key specification parsing'

Test-Case 'plain text is typed literally' {
    Assert-Equal 'v0x00:0x68 ^0x00:0x68 v0x00:0x69 ^0x00:0x69' (Format-Events (ConvertFrom-KeySpec 'hi'))
}

Test-Case "words that name keys are still text" {
    # The bug this syntax was adopted to fix: 'enter' used to press Enter.
    Assert-Equal 10 (ConvertFrom-KeySpec 'enter').Count
    Assert-Equal 0x65 (ConvertFrom-KeySpec 'enter')[0].CharCode
}

Test-Case 'commas survive' {
    Assert-Equal 6 (ConvertFrom-KeySpec 'a,b').Count
    Assert-Equal 0x2C (ConvertFrom-KeySpec 'a,b')[2].CharCode
}

Test-Case '{Enter} presses the key' {
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '{Enter}'))
}

Test-Case 'key names are case-insensitive and have the usual aliases' {
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Enter}')) (Format-Events (ConvertFrom-KeySpec '{RETURN}'))
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Backspace}')) (Format-Events (ConvertFrom-KeySpec '{bs}'))
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '{Escape}')) (Format-Events (ConvertFrom-KeySpec '{Esc}'))
}

Test-Case '^s is Ctrl+S: virtual key S, control character 0x13' {
    Assert-Equal 'vC0x53:0x13 ^C0x53:0x13' (Format-Events (ConvertFrom-KeySpec '^s'))
}

Test-Case 'a modifier applies to the next key only' {
    Assert-Equal 'vC0x53:0x13 ^C0x53:0x13 v0x00:0x73 ^0x00:0x73' (Format-Events (ConvertFrom-KeySpec '^ss'))
}

Test-Case 'modifiers combine, and reach named keys' {
    Assert-Equal 'vCS0x0d:0x0d ^CS0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '^+{Enter}'))
}

Test-Case '+a is A' {
    Assert-Equal 'vS0x00:0x41 ^S0x00:0x41' (Format-Events (ConvertFrom-KeySpec '+a'))
}

Test-Case '!x is Alt+X, keeping the character' {
    Assert-Equal 'vA0x58:0x78 ^A0x58:0x78' (Format-Events (ConvertFrom-KeySpec '!x'))
}

Test-Case 'repeat counts' {
    Assert-Equal 6 (ConvertFrom-KeySpec '{BS 3}').Count
    Assert-Equal 10 (ConvertFrom-KeySpec '{a 5}').Count
}

Test-Case '{Ctrl down} holds Ctrl across keys, {Ctrl up} releases it' {
    Assert-Equal 'vC0x4a:0x0a ^C0x4a:0x0a vC0x4b:0x0b ^C0x4b:0x0b v0x00:0x6a ^0x00:0x6a' `
        (Format-Events (ConvertFrom-KeySpec '{Ctrl down}jk{Ctrl up}j'))
}

Test-Case 'braces and modifier characters can be typed' {
    Assert-Equal 'v0x00:0x7b ^0x00:0x7b v0x00:0x7d ^0x00:0x7d' (Format-Events (ConvertFrom-KeySpec '{{}{}}'))
    Assert-Equal 'v0x00:0x5e ^0x00:0x5e' (Format-Events (ConvertFrom-KeySpec '{^}'))
    # ':qa{!}{Enter}' in Neovim: an unescaped '!' would be Alt, and quietly send Alt+Enter.
    Assert-Equal 'v0x00:0x21 ^0x00:0x21 v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec '{!}{Enter}'))
}

Test-Case '{Raw} makes the rest literal' {
    Assert-Equal (Format-Events (ConvertFrom-KeySpec '^{Enter}' -Literal)) (Format-Events (ConvertFrom-KeySpec '{Raw}^{Enter}'))
    Assert-Equal 16 (ConvertFrom-KeySpec '{Raw}^{Enter}').Count   # the eight characters
}

Test-Case '-Literal types braces and modifiers verbatim' {
    Assert-Equal 'v0x00:0x5e ^0x00:0x5e v0x00:0x7b ^0x00:0x7b' (Format-Events (ConvertFrom-KeySpec '^{' -Literal))
}

Test-Case 'newlines in text are Enter, and a CRLF is one press' {
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec "`r`n"))
    Assert-Equal 'v0x0d:0x0d ^0x0d:0x0d' (Format-Events (ConvertFrom-KeySpec "`n"))
}

Test-Case '{U+...} types a code point, outside the BMP too' {
    Assert-Equal 0x263A (ConvertFrom-KeySpec '{U+263A}')[0].CharCode
    Assert-Equal 4 (ConvertFrom-KeySpec '{U+1F600}').Count   # a surrogate pair, pressed and released
}

Test-Case 'an empty specification sends nothing' {
    Assert-Equal 0 (ConvertFrom-KeySpec '').Count
}

Test-Case 'mouse tokens carry position, button and action' {
    $events = ConvertFrom-KeySpec '{Click 40 10}'
    Assert-Equal 'Mouse' $events[0].Type
    Assert-Equal 3 $events.Count 'a move, then press and release'
    Assert-Equal 'Move' $events[0].Action
    Assert-Equal 40 $events[1].X
    Assert-Equal 10 $events[1].Y
    Assert-Equal 'Left' $events[1].Button
    Assert-Equal 'Down' $events[1].Action
    Assert-Equal 'Up' $events[2].Action
}

Test-Case 'the pointer sticks between tokens' {
    # {WheelDown} has no coordinates, so it happens where {Click} left the pointer.
    # Assign first: the result is returned as one array object, so piping it straight into
    # Where-Object would hand the whole array over as a single item.
    $all = ConvertFrom-KeySpec '{Click 40 10}{WheelDown}'
    $events = @($all | Where-Object { $_.Action -eq 'Wheel' })
    Assert-Equal 1 $events.Count
    Assert-Equal 40 $events[0].X
    Assert-Equal 10 $events[0].Y
    # With no coordinates at all, the worker fills in the middle of the window.
    Assert-Equal -1 (ConvertFrom-KeySpec '{WheelUp}')[0].X
}

Test-Case 'wheel tokens: direction, axis and count' {
    Assert-Equal -1 (ConvertFrom-KeySpec '{WheelDown}')[0].Notches
    Assert-Equal 1 (ConvertFrom-KeySpec '{WheelUp}')[0].Notches
    Assert-Equal 3 (ConvertFrom-KeySpec '{WheelDown 3}').Count 'one event per notch'
    Assert-Equal 'Horizontal' (ConvertFrom-KeySpec '{WheelRight}')[0].WheelAxis
    Assert-Equal 3 (ConvertFrom-KeySpec '{WheelDown 40 10 3}').Count
}

Test-Case 'click options: button, count, and move-only' {
    Assert-Equal 'Right' (ConvertFrom-KeySpec '{Click 5 5 Right}')[1].Button
    Assert-Equal 'Middle' (ConvertFrom-KeySpec '{MButton}')[0].Button
    Assert-Equal 5 (ConvertFrom-KeySpec '{Click 5 5 2}').Count 'a move plus two press/release pairs'
    $moveOnly = ConvertFrom-KeySpec '{Click 5 5 0}'
    Assert-Equal 1 $moveOnly.Count
    Assert-Equal 'Move' $moveOnly[0].Action
    Assert-Equal 'Down' (ConvertFrom-KeySpec '{LButton down}')[0].Action
}

Test-Case 'modifiers reach the mouse too' {
    Assert-Equal 8 (ConvertFrom-KeySpec '^{Click 5 5}')[1].ControlState 'LEFT_CTRL_PRESSED'
}

Test-Case 'keys and mouse can be mixed in one specification' {
    $events = ConvertFrom-KeySpec 'hi{Click 1 2}{Enter}'
    $types = ($events | ForEach-Object { $_.Type }) -join ''
    Assert-Equal 'KeyKeyKeyKeyMouseMouseMouseKeyKey' $types
}

Test-Case 'mistakes are reported, with a way out' {
    Assert-Throws { ConvertFrom-KeySpec '{Enter' } 'unterminated'
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } "unknown key '\{Entr\}'"
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } '-Literal'
    Assert-Throws { ConvertFrom-KeySpec '{Tab x}' } "expected a repeat count"
    Assert-Throws { ConvertFrom-KeySpec '{Ctrl}' } 'only sees modifiers'
    Assert-Throws { ConvertFrom-KeySpec '#r' } "can't reach a console app"
    Assert-Throws { ConvertFrom-KeySpec 'abc^' } 'modifier prefix'
}

Complete-Tests
