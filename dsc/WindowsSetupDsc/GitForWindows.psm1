# GitForWindows: Git for Windows via winget, with pinned installer choices.

using module .\Common.psm1

$script:GitUninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1'

# GitForWindows property -> the name Git's (Inno Setup) installer records that choice under,
# as "Inno Setup CodeFile: <name>" in the uninstall key. The installer takes the property name
# itself on the command line, e.g. /o:SSHOption=ExternalOpenSSH.
$script:GitOptionNames = [ordered]@{
    EditorOption             = 'Editor Option'
    CustomEditorPath         = 'Custom Editor Path'
    DefaultBranchOption      = 'Default Branch Option'
    PathOption               = 'Path Option'
    SSHOption                = 'SSH Option'
    CURLOption               = 'CURL Option'
    CRLFOption               = 'CRLF Option'
    BashTerminalOption       = 'Bash Terminal Option'
    GitPullBehaviorOption    = 'Git Pull Behavior Option'
    UseCredentialManager     = 'Use Credential Manager'
    PerformanceTweaksFSCache = 'Performance Tweaks FSCache'
    EnableSymlinks           = 'Enable Symlinks'
    EnableFSMonitor          = 'Enable FSMonitor'
}

# Microsoft.WinGet.Client is a dependency of Microsoft.WinGet.DSC, so winget downloads it
# (into --module-path) whenever the configuration uses a WinGetPackage resource.
function Import-WinGetClient {
    if (-not (Get-Module Microsoft.WinGet.Client)) {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    }
}

function Get-GitInstallState {
    $props = Get-ItemProperty -Path $script:GitUninstallKey -ErrorAction SilentlyContinue
    if (-not $props) {
        return $null
    }
    $options = @{}
    foreach ($name in $script:GitOptionNames.Keys) {
        $options[$name] = $props."Inno Setup CodeFile: $($script:GitOptionNames[$name])"
    }
    return [pscustomobject]@{
        Location   = $props.InstallLocation
        Version    = $props.DisplayVersion
        Components = @(Resolve-GitComponents ("$($props.'Inno Setup: Selected Components')" -split ','))
        Options    = $options
    }
}

# Sorted, de-duplicated, with parents implied by children (ext\shellhere implies ext), since
# that's how the installer records them.
function Resolve-GitComponents([string[]] $Components) {
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($component in $Components | Where-Object { $_ }) {
        $parts = $component.Trim() -split '\\'
        for ($i = 1; $i -le $parts.Count; $i++) {
            [void] $set.Add($parts[0..($i - 1)] -join '\')
        }
    }
    return @($set)
}

function Test-GitUpdateAvailable([string] $Id) {
    Import-WinGetClient
    $package = Get-WinGetPackage -Id $Id -MatchOption Equals -ErrorAction Stop | Select-Object -First 1
    return [bool] ($package -and $package.IsUpdateAvailable)
}

# Describes how the machine differs from the desired state; empty when it matches.
function Get-GitDrift($desired) {
    $state = Get-GitInstallState
    if (-not $state) {
        return @('Git is not installed')
    }
    $drift = @()
    if ($desired.UseLatest -and (Test-GitUpdateAvailable $desired.Id)) {
        $drift += "an update is available for $($state.Version)"
    }
    foreach ($name in $script:GitOptionNames.Keys) {
        $want = $desired.$name
        if ($want -and $state.Options[$name] -ne $want) {
            $drift += "${name}: '$($state.Options[$name])' -> '$want'"
        }
    }
    if ($null -ne $desired.Components) {
        $want = Resolve-GitComponents $desired.Components
        if (Compare-Object $state.Components $want) {
            $drift += "Components: '$($state.Components -join ',')' -> '$($want -join ',')'"
        }
    }
    return $drift
}

# Run silently, the installer cancels (instead of prompting) if anything from the install
# directory is running, e.g. a Git Bash window. Fail up front with a useful message.
function Assert-GitNotInUse($state) {
    if (-not $state -or -not $state.Location) {
        return
    }
    $root = $state.Location.TrimEnd('\') + '\'
    $inUse = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($inUse) {
        $list = ($inUse | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join ', '
        throw "Git for Windows is in use by: $list. Close them (e.g. Git Bash windows) and re-run."
    }
}

function Get-GitInstallerArguments($desired) {
    $arguments = @()
    if ($null -ne $desired.Components) {
        $arguments += "/COMPONENTS=`"$((Resolve-GitComponents $desired.Components) -join ',')`""
    }
    foreach ($name in $script:GitOptionNames.Keys) {
        if ($desired.$name) {
            $arguments += "/o:$name=`"$($desired.$name)`""
        }
    }
    return $arguments -join ' '
}

# Ensures Git for Windows is installed via winget with the given installer choices: Explorer
# integration, editor, SSH, line endings, and so on. Choices left unset aren't managed.
# Drift in any managed choice re-runs the installer with them.
[DscResource()]
class GitForWindows {
    # The winget package id.
    [DscProperty(Key)]
    [string] $Id

    [DscProperty()]
    [Ensure] $Ensure = [Ensure]::Present

    # Upgrade when winget has a newer version.
    [DscProperty()]
    [bool] $UseLatest

    # Installer components to select; anything not listed is deselected. E.g. ext\shellhere
    # ("Open Git Bash here"), ext\guihere, gitlfs, assoc, assoc_sh, windowsterminal,
    # icons\desktop, autoupdate, scalar.
    [DscProperty()]
    [string[]] $Components

    [DscProperty()]
    [ValidateSet('Nano', 'VIM', 'Notepad++', 'VisualStudioCode', 'VisualStudioCodeInsiders',
        'SublimeText', 'Atom', 'VSCodium', 'Notepad', 'Wordpad', 'MicrosoftEdit', 'CustomEditor')]
    [string] $EditorOption

    [DscProperty()]
    [string] $CustomEditorPath

    [DscProperty()]
    [string] $DefaultBranchOption

    [DscProperty()]
    [ValidateSet('BashOnly', 'Cmd', 'CmdTools')]
    [string] $PathOption

    [DscProperty()]
    [ValidateSet('OpenSSH', 'ExternalOpenSSH', 'Plink')]
    [string] $SSHOption

    [DscProperty()]
    [ValidateSet('OpenSSL', 'WinSSL')]
    [string] $CURLOption

    [DscProperty()]
    [ValidateSet('CRLFAlways', 'LFOnly', 'CRLFCommitAsIs')]
    [string] $CRLFOption

    [DscProperty()]
    [ValidateSet('MinTTY', 'ConHost')]
    [string] $BashTerminalOption

    [DscProperty()]
    [ValidateSet('Merge', 'Rebase', 'FFOnly')]
    [string] $GitPullBehaviorOption

    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $UseCredentialManager

    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $PerformanceTweaksFSCache

    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $EnableSymlinks

    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $EnableFSMonitor

    [DscProperty(NotConfigurable)]
    [string] $InstalledVersion

    [GitForWindows] Get() {
        $current = [GitForWindows]::new()
        $current.Id = $this.Id
        $state = Get-GitInstallState
        if (-not $state) {
            $current.Ensure = [Ensure]::Absent
            return $current
        }
        $current.Ensure = [Ensure]::Present
        $current.InstalledVersion = $state.Version
        $current.Components = $state.Components
        foreach ($name in $state.Options.Keys) {
            # Older installers recorded values the ValidateSets no longer accept (e.g. 'Core').
            try { $current.$name = $state.Options[$name] } catch { }
        }
        return $current
    }

    [bool] Test() {
        if ($this.Ensure -eq [Ensure]::Absent) {
            return -not (Get-GitInstallState)
        }
        $drift = @(Get-GitDrift $this)
        $drift | ForEach-Object { Write-Verbose "Git for Windows: $_" }
        return $drift.Count -eq 0
    }

    [void] Set() {
        Import-WinGetClient
        $state = Get-GitInstallState
        if ($this.Ensure -eq [Ensure]::Absent) {
            if ($state) {
                $result = Uninstall-WinGetPackage -Id $this.Id -MatchOption Equals -Mode Silent -ErrorAction Stop
                if ($result.Status -ne 'Ok') { throw "Uninstalling $($this.Id) failed: $($result.Status) ($($result.ExtendedErrorCode))" }
            }
            return
        }

        Assert-GitNotInUse $state
        $params = @{
            Id          = $this.Id
            MatchOption = 'Equals'
            Source      = 'winget'
            Mode        = 'Silent'
            Custom      = Get-GitInstallerArguments $this
        }
        if ($state -and $this.UseLatest -and (Test-GitUpdateAvailable $this.Id)) {
            $result = Update-WinGetPackage @params -ErrorAction Stop
        } elseif ($state) {
            # Same version: reinstall to apply the changed choices.
            $result = Install-WinGetPackage @params -Force -ErrorAction Stop
        } else {
            $result = Install-WinGetPackage @params -ErrorAction Stop
        }
        if ($result.Status -ne 'Ok') {
            throw "Installing $($this.Id) failed: $($result.Status) (extended error $($result.ExtendedErrorCode), installer exit code $($result.InstallerErrorCode))"
        }
    }
}
