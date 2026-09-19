# windows-setup: managed file, copied from configuration\powershell\profile.d. Edits are overwritten.
#
# mise activation: puts the active tool versions on PATH and hooks directory changes, so per-project
# versions (mise.toml) apply. Runs first, so later snippets see mise's tools.
#
# PowerShell 7 only: on Windows PowerShell 5.1 `mise activate` warns "chpwd functionality requires
# PowerShell version 7 or higher". There, mise's shims (on the user PATH) provide the same tools,
# without per-directory switching.

if ($PSVersionTable.PSVersion.Major -lt 7) { return }
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) { return }

(& mise activate pwsh) | Out-String | Invoke-Expression
