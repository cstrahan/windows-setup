# windows-setup: managed file, copied from configuration\powershell\profile.d. Edits are overwritten.
#
# PSFzf: Ctrl+T inserts paths, Ctrl+R searches history with fzf. Both replace PSReadLine bindings,
# so this needs an interactive host with PSReadLine loaded. PSFzf is installed for PowerShell 7
# only (Windows PowerShell 5.1 ships PSReadLine 2.0, older than PSFzf's key handlers expect), so
# this no-ops there.

if ($PSVersionTable.PSVersion.Major -lt 7) { return }
if (-not (Get-Module PSReadLine)) { return }  # non-interactive host
if (-not (Get-Module PSFzf -ListAvailable)) { return }
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { return }

Import-Module PSFzf

$options = @{
    PSReadlineChordProvider       = 'Ctrl+t'
    PSReadlineChordReverseHistory = 'Ctrl+r'
}
# -EnableFd makes PSFzf's own file and directory searches use fd (it walks the file system itself
# when a search is directory-scoped, where FZF_DEFAULT_COMMAND doesn't apply).
if (Get-Command fd -ErrorAction SilentlyContinue) { $options.EnableFd = $true }
Set-PsFzfOption @options
