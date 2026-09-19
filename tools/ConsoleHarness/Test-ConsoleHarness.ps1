# Tests for ConsoleHarness. Run it with pwsh; it exits non-zero if anything failed.
#
#   pwsh -File tools\ConsoleHarness\Test-ConsoleHarness.ps1
#   pwsh -File tools\ConsoleHarness\Test-ConsoleHarness.ps1 -SkipConsole   # parser only, no fzf
#
# The parser cases are pure and fast; the console cases drive a real fzf in a hidden console, so
# they need fzf on PATH (the shell workload installs it) and take a few seconds.
[CmdletBinding()]
param([switch] $SkipConsole)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeySpec.ps1')

$script:Failures = 0

function Test-Case([string] $Name, [scriptblock] $Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-Equal($Expected, $Actual, [string] $Because = '') {
    if ($Expected -ne $Actual) {
        throw "expected '$Expected', got '$Actual'$(if ($Because) { " ($Because)" })"
    }
}

function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    try { & $Body } catch {
        if ("$_" -notmatch $Pattern) { throw "error did not match /$Pattern/: $_" }
        return
    }
    throw "expected an error matching /$Pattern/, but none was thrown"
}

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

Test-Case 'the literal mode behind Send-ConsoleText types braces and modifiers verbatim' {
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

Test-Case 'mistakes are reported, with a way out' {
    Assert-Throws { ConvertFrom-KeySpec '{Enter' } 'unterminated'
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } "unknown key '\{Entr\}'"
    Assert-Throws { ConvertFrom-KeySpec '{Entr}' } '-Literal'
    Assert-Throws { ConvertFrom-KeySpec '{Tab x}' } "expected a repeat count"
    Assert-Throws { ConvertFrom-KeySpec '{Ctrl}' } 'only sees modifiers'
    Assert-Throws { ConvertFrom-KeySpec '#r' } "can't reach a console app"
    Assert-Throws { ConvertFrom-KeySpec 'abc^' } 'modifier prefix'
}

if ($SkipConsole) {
    Write-Host "`nSkipping the console tests (-SkipConsole)."
} elseif (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Write-Host "`nSkipping the console tests: fzf isn't on PATH." -ForegroundColor Yellow
} else {
    Write-Host "`nDriving a real console (fzf)"
    Import-Module (Join-Path $PSScriptRoot 'ConsoleHarness.psd1') -Force

    # fzf over a fixed list, so the tests don't depend on the current directory.
    $items = 'alpha', 'beta,gamma', 'enter-the-void', 'delta'
    $command = "@('$($items -join "','")') | fzf"

    function Use-Fzf([scriptblock] $Body) {
        $session = Start-ConsoleApp -Command $command -WorkingDirectory $PSScriptRoot
        try {
            Wait-ConsoleText $session '^\s*>' | Out-Null
            & $Body $session
        } finally { Stop-ConsoleApp $session }
    }

    function Get-Query($Screen) {
        $line = $Screen | Where-Object { $_ -match '^\s*>' } | Select-Object -First 1
        return ($line -replace '^\s*>\s?', '').TrimEnd()
    }

    Test-Case 'text with a comma reaches the app intact' {
        Use-Fzf {
            param($session)
            Assert-Equal 'beta,gam' (Get-Query (Send-ConsoleKeys $session 'beta,gam' -SettleMilliseconds 400))
        }
    }

    Test-Case "'enter' is typed, not pressed" {
        Use-Fzf {
            param($session)
            Assert-Equal 'enter' (Get-Query (Send-ConsoleKeys $session 'enter' -SettleMilliseconds 400))
            Assert-Equal $false $session.Process.HasExited 'fzf should still be running'
        }
    }

    Test-Case '{Enter} accepts the selection and fzf exits' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'delta{Enter}' -SettleMilliseconds 600 | Out-Null
            Assert-Equal $true $session.Process.WaitForExit(3000) 'fzf should have exited'
        }
    }

    Test-Case 'a chord reaches the app: Ctrl+U clears the query' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
            Assert-Equal '' (Get-Query (Send-ConsoleKeys $session '^u' -SettleMilliseconds 400))
        }
    }

    Test-Case 'a repeat count reaches the app: {BS 3}' {
        Use-Fzf {
            param($session)
            Send-ConsoleKeys $session 'alpha' -SettleMilliseconds 400 | Out-Null
            Assert-Equal 'al' (Get-Query (Send-ConsoleKeys $session '{BS 3}' -SettleMilliseconds 400))
        }
    }

    Test-Case 'Send-ConsoleText types syntax characters' {
        Use-Fzf {
            param($session)
            Assert-Equal '^{Enter}' (Get-Query (Send-ConsoleText $session '^{Enter}' -SettleMilliseconds 400))
        }
    }

    Test-Case 'Send-ConsoleText does not press keys' {
        Use-Fzf {
            param($session)
            Send-ConsoleText $session 'enter{Enter}' -SettleMilliseconds 500 | Out-Null
            Assert-Equal $false $session.Process.HasExited 'fzf should still be running'
        }
    }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$script:Failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
