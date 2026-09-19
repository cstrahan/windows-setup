# Parses a key specification into console key events, using AutoHotkey v2's Send syntax
# (https://www.autohotkey.com/docs/v2/lib/Send.htm) so there's nothing new to learn:
#
#   'hello{Enter}'      type hello, then press Enter
#   '^s'                Ctrl+S            ('!' = Alt, '+' = Shift)
#   '{BS 3}'            Backspace 3 times
#   '{Ctrl down}jk{Ctrl up}'   hold Ctrl across several keys
#   '{Raw}^{Enter}'     type the characters ^{Enter} literally
#
# Literal text stays literal, including words like enter and tab: only braces and the modifier
# prefixes are special, and '{^}' '{!}' '{+}' '{#}' '{{}' '{}}' escape those.
#
# Output is one object per console INPUT_RECORD:
#   VirtualKey   VK_* code, or 0 for a character that isn't bound to a known key
#   CharCode     the UTF-16 code unit the app receives (0 for keys like the arrows)
#   ControlState dwControlKeyState (the Ctrl/Alt/Shift flags)
#   KeyDown      $true for the press, $false for the release
#
# This file has no side effects, so it can be dot-sourced and tested on its own
# (Test-ConsoleHarness.ps1 does exactly that).

# Console dwControlKeyState flags. Left-hand modifiers, which is what a real keyboard sends for
# the chords people actually type.
$script:RightAltPressed = 0x0001
$script:LeftAltPressed = 0x0002
$script:RightCtrlPressed = 0x0004
$script:LeftCtrlPressed = 0x0008
$script:ShiftPressed = 0x0010

# Only keys a console app can actually receive. Modifiers on their own are handled separately,
# and mouse, media and Win keys are rejected: nothing reaches a console app through them.
$script:KeyCodes = @{
    enter       = @(0x0D, "`r")
    return      = @(0x0D, "`r")
    escape      = @(0x1B, [char] 27)
    esc         = @(0x1B, [char] 27)
    space       = @(0x20, ' ')
    tab         = @(0x09, "`t")
    backspace   = @(0x08, [char] 8)
    bs          = @(0x08, [char] 8)
    delete      = @(0x2E, [char] 0)
    del         = @(0x2E, [char] 0)
    insert      = @(0x2D, [char] 0)
    ins         = @(0x2D, [char] 0)
    up          = @(0x26, [char] 0)
    down        = @(0x28, [char] 0)
    left        = @(0x25, [char] 0)
    right       = @(0x27, [char] 0)
    home        = @(0x24, [char] 0)
    end         = @(0x23, [char] 0)
    pgup        = @(0x21, [char] 0)
    pgdn        = @(0x22, [char] 0)
    capslock    = @(0x14, [char] 0)
    numlock     = @(0x90, [char] 0)
    scrolllock  = @(0x91, [char] 0)
    printscreen = @(0x2C, [char] 0)
    pause       = @(0x13, [char] 0)
    appskey     = @(0x5D, [char] 0)
}
# F1 is VK_F1 (0x70); the parentheses matter, as ',' binds tighter than '+'.
foreach ($number in 1..24) { $script:KeyCodes["f$number"] = @((0x6F + $number), [char] 0) }

# {Ctrl down} and friends: a console app never sees the modifier keys themselves, only their
# flags on other keys, so these set state rather than producing events of their own.
$script:ModifierNames = @{
    ctrl    = $script:LeftCtrlPressed
    control = $script:LeftCtrlPressed
    lctrl   = $script:LeftCtrlPressed
    rctrl   = $script:RightCtrlPressed
    alt     = $script:LeftAltPressed
    lalt    = $script:LeftAltPressed
    ralt    = $script:RightAltPressed
    shift   = $script:ShiftPressed
    lshift  = $script:ShiftPressed
    rshift  = $script:ShiftPressed
}

$script:PrefixModifiers = @{
    '^' = $script:LeftCtrlPressed
    '!' = $script:LeftAltPressed
    '+' = $script:ShiftPressed
}

function New-ConsoleKeyEvent {
    <#
    .SYNOPSIS
    Builds the press/release pair (or just one of them) for a single key.
    #>
    param(
        [int] $VirtualKey,
        [char] $Character,
        [int] $ControlState,
        [int] $Repeat = 1,
        # press (both events), down (press only) or up (release only).
        [ValidateSet('press', 'down', 'up')] [string] $State = 'press'
    )
    $states = switch ($State) {
        'press' { @($true, $false) }
        'down' { @($true) }
        'up' { @($false) }
    }
    foreach ($iteration in 1..$Repeat) {
        foreach ($keyDown in $states) {
            [pscustomobject]@{
                VirtualKey   = $VirtualKey
                CharCode     = [int] $Character
                ControlState = $ControlState
                KeyDown      = $keyDown
            }
        }
    }
}

function New-CharacterKeyEvent {
    <#
    .SYNOPSIS
    Builds the events for a literal character, applying whatever modifiers are in effect.

    .DESCRIPTION
    Unmodified characters are sent as pure character events (virtual key 0), which is what the
    harness has always done and what apps reading characters expect. With Ctrl or Alt held, the
    app looks at the virtual key too, so letters resolve to their own key: Ctrl+A is virtual key
    'A' carrying 0x01, the control character a real keyboard would produce.
    #>
    param([char] $Character, [int] $ControlState, [int] $Repeat = 1, [string] $State = 'press')

    $value = $Character
    $virtualKey = 0
    if ($ControlState -band $script:ShiftPressed) { $value = [char]::ToUpperInvariant($value) }
    $upper = [char]::ToUpperInvariant($value)
    if ($ControlState -band ($script:LeftCtrlPressed -bor $script:RightCtrlPressed)) {
        # Ctrl+@ through Ctrl+_ (which covers the letters) produce control characters.
        if ([int] $upper -ge 0x40 -and [int] $upper -le 0x5F) {
            $virtualKey = [int] $upper
            $value = [char] ([int] $upper - 0x40)
        }
    } elseif ($ControlState -band ($script:LeftAltPressed -bor $script:RightAltPressed)) {
        if ($upper -match '[A-Z0-9]') { $virtualKey = [int] $upper }
    }
    New-ConsoleKeyEvent -VirtualKey $virtualKey -Character $value -ControlState $ControlState -Repeat $Repeat -State $State
}

function Get-KeySpecToken {
    <#
    .SYNOPSIS
    Reads the brace token starting at $Index and returns its content and where it ends.
    #>
    param([string] $Spec, [int] $Index)

    # {{} and {}} are the escapes for the braces themselves, so their content is the char after '{'.
    if ($Index + 2 -lt $Spec.Length -and ($Spec[$Index + 1] -eq '{' -or $Spec[$Index + 1] -eq '}') -and $Spec[$Index + 2] -eq '}') {
        return [pscustomobject]@{ Content = [string] $Spec[$Index + 1]; End = $Index + 2 }
    }
    $close = $Spec.IndexOf('}', $Index + 1)
    if ($close -lt 0) {
        throw "unterminated '{' at position $Index in '$Spec'. To type a brace, use '{{}' or '{}}', or pass -Literal."
    }
    return [pscustomobject]@{ Content = $Spec.Substring($Index + 1, $close - $Index - 1); End = $close }
}

function ConvertFrom-KeySpec {
    <#
    .SYNOPSIS
    Converts an AutoHotkey-style key specification into console key events.

    .EXAMPLE
    ConvertFrom-KeySpec 'find{Enter}'

    .EXAMPLE
    ConvertFrom-KeySpec '{Enter}' -Literal   # the eight characters, not the key
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string] $Spec,
        # Send everything verbatim: no braces, no modifier prefixes. Same as a leading '{Raw}'.
        [switch] $Literal
    )

    $raw = [bool] $Literal
    $pending = 0   # modifiers from ^ ! + prefixes, applying to the next key only
    $held = 0      # modifiers held by {Ctrl down} until {Ctrl up}
    $index = 0
    $events = @(while ($index -lt $Spec.Length) {
        $character = $Spec[$index]

        if (-not $raw -and $character -eq '{') {
            $token = Get-KeySpecToken -Spec $Spec -Index $index
            $index = $token.End + 1
            $body = $token.Content.Trim()
            if (-not $body) { throw "empty '{}' in '$Spec'. To type braces, use '{{}' and '{}}'." }

            # A trailing repeat count or up/down state, as in {Tab 3} or {Ctrl down}.
            $name = $body
            $argument = $null
            if ($body -match '^(?<name>\S+)\s+(?<argument>\S+)$') {
                $name = $Matches['name']
                $argument = $Matches['argument']
            }
            $repeat = 1
            $state = 'press'
            if ($null -ne $argument) {
                if ($argument -match '^\d+$') { $repeat = [int] $argument }
                elseif ($argument -in 'down', 'up') { $state = $argument.ToLowerInvariant() }
                else { throw "'{$body}' in '$Spec': expected a repeat count or 'down'/'up', got '$argument'." }
            }

            # {Raw} and {Text} both mean "the rest is literal"; this harness has no use for the
            # difference (AHK's {Text} picks a different injection method).
            if ($name -in 'Raw', 'Text') { $raw = $true; continue }

            # The escapes for characters that would otherwise be syntax.
            if ($name.Length -eq 1 -and $name -in '{', '}', '^', '!', '+', '#') {
                New-CharacterKeyEvent -Character $name[0] -ControlState ($pending -bor $held) -Repeat $repeat -State $state
                $pending = 0
                continue
            }
            if ($name -match '^[Uu]\+(?<code>[0-9A-Fa-f]{1,6})$') {
                # Console input is UTF-16, so anything outside the BMP goes as its surrogate pair.
                $codePoint = [Convert]::ToInt32($Matches['code'], 16)
                if ($codePoint -gt 0x10FFFF) { throw "'{$name}' in '$Spec' is not a Unicode code point." }
                foreach ($unit in [char[]] [char]::ConvertFromUtf32($codePoint)) {
                    New-CharacterKeyEvent -Character $unit -ControlState ($pending -bor $held) -Repeat $repeat -State $state
                }
                $pending = 0
                continue
            }

            $modifier = $script:ModifierNames[$name.ToLowerInvariant()]
            if ($modifier) {
                if ($state -eq 'press') {
                    throw "'{$body}' in '$Spec': a console app only sees modifiers as flags on another key. Use '^x' for a chord, or '{$name down}' ... '{$name up}' to hold one."
                }
                if ($state -eq 'down') { $held = $held -bor $modifier } else { $held = $held -band (-bnot $modifier) }
                continue
            }

            $key = $script:KeyCodes[$name.ToLowerInvariant()]
            if (-not $key -and $name.Length -eq 1) {
                # A single character in braces is that character, which is how a repeat count or a
                # held state is put on one: {a 5}, {x down}.
                New-CharacterKeyEvent -Character $name[0] -ControlState ($pending -bor $held) -Repeat $repeat -State $state
                $pending = 0
                continue
            }
            if (-not $key) {
                throw "unknown key '{$name}' in '$Spec'. Known keys: $(($script:KeyCodes.Keys | Sort-Object) -join ', '). To type the text instead, pass -Literal or use '{Raw}'."
            }
            New-ConsoleKeyEvent -VirtualKey $key[0] -Character $key[1] -ControlState ($pending -bor $held) -Repeat $repeat -State $state
            $pending = 0
            continue
        }

        if (-not $raw -and $character -eq '#') {
            throw "'#' (Win) in '$Spec' can't reach a console app. Use '{#}' to type the character."
        }
        if (-not $raw -and $script:PrefixModifiers.ContainsKey([string] $character)) {
            $pending = $pending -bor $script:PrefixModifiers[[string] $character]
            $index++
            continue
        }

        $index++
        # A newline or tab in the text means the key, as it would if it were typed.
        if ($character -eq "`n" -or $character -eq "`r") {
            # A CRLF is one Enter, not two.
            if ($character -eq "`r" -and $index -lt $Spec.Length -and $Spec[$index] -eq "`n") { $index++ }
            New-ConsoleKeyEvent -VirtualKey 0x0D -Character "`r" -ControlState ($pending -bor $held)
        } elseif ($character -eq "`t") {
            New-ConsoleKeyEvent -VirtualKey 0x09 -Character "`t" -ControlState ($pending -bor $held)
        } else {
            New-CharacterKeyEvent -Character $character -ControlState ($pending -bor $held)
        }
        $pending = 0
    })

    if ($pending) { throw "'$Spec' ends with a modifier prefix that has no key after it." }
    # ',' keeps PowerShell from unrolling the array, so an empty specification stays empty and a
    # single event still arrives as a one-element array.
    return , $events
}
