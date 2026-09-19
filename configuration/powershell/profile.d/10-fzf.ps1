# windows-setup: managed file, copied from configuration\powershell\profile.d. Edits are overwritten.
#
# fzf defaults. fd and ripgrep are faster than the default find/dir walk and respect .gitignore;
# either is used if present. PSFzf reads FZF_DEFAULT_COMMAND for its file searches (see 20-psfzf.ps1),
# and plain `fzf` uses all of these.

if (Get-Command fzf -ErrorAction SilentlyContinue) {
    if (Get-Command fd -ErrorAction SilentlyContinue) {
        $env:FZF_DEFAULT_COMMAND = 'fd --type f --hidden --follow --exclude .git'
        $env:FZF_CTRL_T_COMMAND = $env:FZF_DEFAULT_COMMAND
        $env:FZF_ALT_C_COMMAND = 'fd --type d --hidden --follow --exclude .git'
    } elseif (Get-Command rg -ErrorAction SilentlyContinue) {
        $env:FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob !.git'
        $env:FZF_CTRL_T_COMMAND = $env:FZF_DEFAULT_COMMAND
    }

    if (-not $env:FZF_DEFAULT_OPTS) {
        $env:FZF_DEFAULT_OPTS = '--height 40% --layout=reverse --border --info=inline'
    }
}
