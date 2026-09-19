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

    # Layout, plus keys for the preview pane: Ctrl+U/D half page, Ctrl+B/F page, Ctrl+G/H top and
    # bottom, Alt+W wrap, Ctrl+E hide. (Set FZF_DEFAULT_OPTS yourself to override all of this.)
    if (-not $env:FZF_DEFAULT_OPTS) {
        $env:FZF_DEFAULT_OPTS = @'
--height 60%
--layout=reverse
--cycle
--scroll-off=5
--border
--info=inline
--preview-window=right,60%,border-left
--bind ctrl-u:preview-half-page-up
--bind ctrl-d:preview-half-page-down
--bind ctrl-b:preview-page-up
--bind ctrl-f:preview-page-down
--bind ctrl-g:preview-top
--bind ctrl-h:preview-bottom
--bind alt-w:toggle-preview-wrap
--bind ctrl-e:toggle-preview
'@
    }
}
