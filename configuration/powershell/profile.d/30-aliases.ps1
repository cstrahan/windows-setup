# windows-setup: managed file, copied from configuration\powershell\profile.d. Edits are overwritten.
#
# Aliases. Each is only defined when its target exists, and never replaces an alias you've set
# yourself in a later snippet (-Force is deliberately not used for names PowerShell doesn't own).

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias -Name vi -Value nvim -Scope Global
}
