# windows-setup: managed file, copied from configuration\powershell\profile.d. Edits are overwritten.
#
# fzf pickers: `fdg` finds files/directories (Ctrl+S switches), `rgg` searches file contents with
# ripgrep, then both offer what to do with the result. Bound to Ctrl+F and Ctrl+G.
# (Adapted from https://dev.to/kengotoda/using-fzf-on-windows-297j-style posts on fzf in PowerShell:
# the preview no longer branches per keystroke, and the Windows-only `sleep` debounce is gone.)
#
# fzf runs its own child processes through cmd.exe on Windows (11 ms to start, vs ~200 ms for pwsh
# with --with-shell), so the --bind/--preview commands below are cmd syntax: `^` escapes fzf's
# action parentheses, and %FZF_PROMPT% is the current prompt, which is how the toggle knows its
# mode. Each mode sets a static --preview with change-preview, so previews stay a single fast
# process.

if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { return }

$script:FdFiles = 'fd --type file --follow --hidden --exclude .git'
$script:FdDirectories = 'fd --type directory --follow --hidden --exclude .git'
$script:PreviewFile = 'bat --color=always --style=plain {}'
$script:PreviewDirectory = 'eza -T --colour=always --icons=always {}'
# One preview command for both modes: fzf expands {} per item, and exports the current prompt as
# %FZF_PROMPT%, which is how it knows which mode it's in.
$script:Preview = "if `"%FZF_PROMPT%`"==`"Files> `" ($script:PreviewFile) else ($script:PreviewDirectory)"
$script:RgPrefix = 'rg --column --line-number --no-heading --color=always --smart-case'

# Ctrl+S toggles files <-> directories: the prompt (which the preview reads back as %FZF_PROMPT%)
# and the source command.
#
# The preview can't be switched here with change-preview: fzf expands placeholders in a transform's
# *command* before running it, so `{}` would be replaced by whatever is selected at the moment
# Ctrl+S is pressed, and the preview would stay stuck on that item. Hence the conditional in
# $script:Preview below, which runs per item. (The other way is to hide the braces from fzf as
# `^{^}`, which cmd's echo then strips back to `{}`, as the ripgrep toggle does for `{q}`.)
$script:PathToggle = 'ctrl-s:transform:if "%FZF_PROMPT%"=="Files> " ' +
    "(echo ^change-prompt^(Directories^> ^)^+^reload^($script:FdDirectories^)) " +
    "else (echo ^change-prompt^(Files^> ^)^+^reload^($script:FdFiles^))"

# Ctrl+S freezes ripgrep's results and switches to fzf's own matching over them (and back), keeping
# each mode's query in a temp file.
$script:MatchToggle = 'ctrl-s:transform:if "%FZF_PROMPT%"=="1. ripgrep> " ' +
    '(echo ^unbind^(change^)^+^change-prompt^(2. fzf^> ^)^+^enable-search^+^transform-query:echo ^{q^} ^> %TEMP%\rg-fzf-r ^& type %TEMP%\rg-fzf-f) ' +
    'else (echo ^rebind^(change^)^+^change-prompt^(1. ripgrep^> ^)^+^disable-search^+^transform-query:echo ^{q^} ^> %TEMP%\rg-fzf-f ^& type %TEMP%\rg-fzf-r)'

# What to do with the path fzf returned. rg results look like `path:line:column:text`, so the line
# number is kept and used where it helps (nvim opens at that line).
function _fzf_open_path {
    param([string] $Selection)

    if ([string]::IsNullOrWhiteSpace($Selection)) { return }  # Esc in fzf

    $path, $line = $Selection, $null
    if ($Selection -match '^(?<path>.+?):(?<line>\d+):') {
        $path = $Matches.path
        $line = [int] $Matches.line
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "no such path: $path"
        return
    }

    $actions = [ordered] @{
        'nvim'      = { if ($line) { nvim "+$line" -- $path } else { nvim -- $path } }
        'bat'       = { if (Get-Command bat -ErrorAction SilentlyContinue) { bat -- $path } else { Get-Content -LiteralPath $path } }
        'cd'        = {
            $directory = if (Test-Path -LiteralPath $path -PathType Leaf) { Split-Path -LiteralPath $path -Parent } else { $path }
            Set-Location -LiteralPath $directory
        }
        'copy path' = { (Resolve-Path -LiteralPath $path).Path | Set-Clipboard }
        'reveal'    = { explorer.exe '/select,', (Resolve-Path -LiteralPath $path).Path }
        'echo'      = { (Resolve-Path -LiteralPath $path).Path }
        'remove'    = { Remove-Item -LiteralPath $path -Recurse -Confirm }
    }

    $choice = $actions.Keys | fzf --prompt 'Command> ' --height 40% --no-preview
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    & $actions[$choice]
}

# Files, with Ctrl+S switching to directories (and the preview to a tree).
function _fzf_select_path {
    Invoke-Expression $script:FdFiles | fzf --prompt 'Files> ' `
        --header-first `
        --header 'CTRL-S: switch between files and directories' `
        --bind $script:PathToggle `
        --preview $script:Preview
}

# Content search: ripgrep re-runs on every keystroke; Ctrl+S freezes the results and switches to
# fzf's own fuzzy matching over them (and back), keeping each mode's query.
function _fzf_select_match {
    param([string] $Query = '')

    $rg = $script:RgPrefix
    '' | fzf --ansi --disabled --query $Query `
        --bind "start:reload:$rg {q}" `
        --bind "change:reload:$rg {q} || rem" `
        --bind $script:MatchToggle `
        --color 'hl:-1:underline,hl+:-1:underline:reverse' `
        --delimiter ':' `
        --prompt '1. ripgrep> ' `
        --header-first `
        --header 'CTRL-S: switch between ripgrep and fzf' `
        --preview 'bat --color=always {1} --highlight-line {2} --style=plain' `
        --preview-window 'up,60%,border-bottom,+{2}+3/3'
}

function fdg {
    _fzf_open_path (_fzf_select_path)
}

function rgg {
    param([string] $Query = '')
    _fzf_open_path (_fzf_select_match $Query)
}

# Ctrl+F / Ctrl+G run them from an empty prompt (both are unbound in PSReadLine by default). The
# command is inserted and accepted, so it lands in history like anything else.
if (Get-Module PSReadLine) {
    foreach ($binding in @{ 'Ctrl+f' = 'fdg'; 'Ctrl+g' = 'rgg' }.GetEnumerator()) {
        $command = $binding.Value
        Set-PSReadLineKeyHandler -Key $binding.Key -ScriptBlock {
            param($key, $argument)
            [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($command)
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }.GetNewClosure()
    }
}
