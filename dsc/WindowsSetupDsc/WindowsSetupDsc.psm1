# Class-based DSC resources for `winget configure`, which runs them in its own embedded
# PowerShell 7 host.

enum Ensure {
    Absent
    Present
}

# On Windows 10 the Dism module fails natively under PowerShell 7 ("Class not registered"),
# so load it through the Windows PowerShell 5.1 compatibility layer instead.
function Import-CompatDism {
    $loaded = Get-Module Dism
    if ($loaded -and $loaded.Path -notlike '*remoteIpMoProxy*') {
        Remove-Module Dism -Force
        $loaded = $null
    }
    if (-not $loaded) {
        Import-Module Dism -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
    }
}

function Get-CapabilityState([string] $Name) {
    Import-CompatDism
    $capability = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
    if (-not $capability -or -not $capability.Name) {
        throw "Windows capability '$Name' not found"
    }
    # Objects come back deserialized from the compat session; stringify the enum.
    return "$($capability.State)"
}

# Ensures a Windows capability (Features on Demand, e.g. OpenSSH.Client~~~~0.0.1.0) is
# installed or removed.
[DscResource()]
class WindowsCapability {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty()]
    [Ensure] $Ensure = [Ensure]::Present

    # e.g. Installed, NotPresent, InstallPending
    [DscProperty(NotConfigurable)]
    [string] $State

    [WindowsCapability] Get() {
        $current = [WindowsCapability]::new()
        $current.Name = $this.Name
        $current.State = Get-CapabilityState $this.Name
        $current.Ensure = if ($current.State -eq 'Installed') { [Ensure]::Present } else { [Ensure]::Absent }
        return $current
    }

    [bool] Test() {
        return $this.Get().Ensure -eq $this.Ensure
    }

    [void] Set() {
        Import-CompatDism
        if ($this.Ensure -eq [Ensure]::Present) {
            Add-WindowsCapability -Online -Name $this.Name -ErrorAction Stop | Out-Null
        } else {
            Remove-WindowsCapability -Online -Name $this.Name -ErrorAction Stop | Out-Null
        }
    }
}

# --- Precision touchpad ----------------------------------------------------------------

# Two mechanisms, chosen per machine:
# - Windows 11 24H2+: SPI_GET/SETTOUCHPADPARAMETERS with TOUCHPAD_PARAMETERS_V1. Documented,
#   covers every setting, and applies immediately.
# - Older Windows: the per-user registry values the Settings app uses. They take effect at the
#   next sign-in; restarting the touchpad device or Explorer doesn't apply them. Only settings
#   whose registry value was checked against the Windows 10 Settings app are supported there.
$script:TouchpadKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'

# TOUCHPAD_PARAMETERS_V1 is 48 bytes: versionNumber at offset 0, then (among system-info fields
# we don't touch) a bitfield of on/off user settings at offset 16 and a UINT per numeric setting.
$script:TouchpadParametersSize = 48
$script:TouchpadFlagsOffset = 16

# On/off settings: their bit at TouchpadFlagsOffset, their registry value on older Windows
# (0 = clear, 0xFFFFFFFF = set; $null = no known equivalent), and, where not Enabled/Disabled,
# their property values when the bit is set / clear.
$script:TouchpadFlags = [ordered]@{
    AllowActiveWhenMousePresent = @{ Bit = 0; Registry = 'LeaveOnWithMouse' }
    FeedbackEnabled             = @{ Bit = 1; Registry = $null }
    Taps                        = @{ Bit = 2; Registry = 'TapsEnabled' }
    TapAndDrag                  = @{ Bit = 3; Registry = 'TapAndDrag' }
    TwoFingerTap                = @{ Bit = 4; Registry = 'TwoFingerTapEnabled' }
    RightClickZone              = @{ Bit = 5; Registry = 'RightClickZoneEnabled' }
    HonorMouseAccelSetting      = @{ Bit = 6; Registry = $null }
    Pan                         = @{ Bit = 7; Registry = 'PanEnabled' }
    Zoom                        = @{ Bit = 8; Registry = 'ZoomEnabled' }
    # scrollDirectionReversed. Windows' default is "Down motion scrolls up"; the registry value
    # is 0xFFFFFFFF for "Down motion scrolls down" (checked against Settings on Windows 10).
    ScrollDirection             = @{ Bit = 9; Registry = 'ScrollDirection'; OnValue = 'DownMotionScrollsDown'; OffValue = 'DownMotionScrollsUp' }
}

# Numeric settings: their UINT's offset, their registry value on older Windows ($null = no known
# equivalent), and their valid range. SensitivityLevel is exposed by name (TouchpadSensitivityLevels).
$script:TouchpadNumbers = [ordered]@{
    SensitivityLevel      = @{ Offset = 20; Registry = 'AAPThreshold'; Min = 0; Max = 4 }
    CursorSpeed           = @{ Offset = 24; Registry = 'CursorSpeed';  Min = 1; Max = 20 }  # Windows 10's slider shows half this
    FeedbackIntensity     = @{ Offset = 28; Registry = $null;          Min = 0; Max = 100 }
    ClickForceSensitivity = @{ Offset = 32; Registry = $null;          Min = 0; Max = 100 }
    RightClickZoneWidth   = @{ Offset = 36; Registry = $null;          Min = 0; Max = 100 }
    RightClickZoneHeight  = @{ Offset = 40; Registry = $null;          Min = 0; Max = 100 }
}

# TOUCHPAD_SENSITIVITY_LEVEL, in order (0-4); AAPThreshold uses the same numbers.
$script:TouchpadSensitivityLevels = @('MostSensitive', 'HighSensitivity', 'MediumSensitivity', 'LowSensitivity', 'LeastSensitive')

function Initialize-SpiInterop {
    if (-not ('WindowsSetupDsc.NativeMethods' -as [type])) {
        Add-Type -Namespace WindowsSetupDsc -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, byte[] pvParam, uint fWinIni);
'@
    }
}

# TOUCHPAD_PARAMETERS_V1 from SPI_GETTOUCHPADPARAMETERS, or $null where that isn't supported.
function Get-TouchpadParameters {
    Initialize-SpiInterop
    $SPI_GETTOUCHPADPARAMETERS = 0x00AE
    $buffer = [byte[]]::new($script:TouchpadParametersSize)
    [BitConverter]::GetBytes([uint32] 1).CopyTo($buffer, 0)  # versionNumber: TOUCHPAD_PARAMETERS_VERSION_1
    if (-not [WindowsSetupDsc.NativeMethods]::SystemParametersInfoW($SPI_GETTOUCHPADPARAMETERS, $buffer.Length, $buffer, 0)) {
        return $null
    }
    return , $buffer
}

function Set-TouchpadParameters([byte[]] $Buffer) {
    $SPI_SETTOUCHPADPARAMETERS = 0x00AF
    $SPIF_UPDATEINIFILE_SENDCHANGE = 0x3
    if (-not [WindowsSetupDsc.NativeMethods]::SystemParametersInfoW($SPI_SETTOUCHPADPARAMETERS, $Buffer.Length, $Buffer, $SPIF_UPDATEINIFILE_SENDCHANGE)) {
        throw "SPI_SETTOUCHPADPARAMETERS failed (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
}

function ConvertTo-TouchpadFlagValue([string] $Name, [bool] $IsSet) {
    # Index explicitly: member access like $flag.Clear would find Hashtable's Clear() method.
    $flag = $script:TouchpadFlags[$Name]
    if ($IsSet) {
        if ($flag['OnValue']) { return $flag['OnValue'] } else { return 'Enabled' }
    }
    if ($flag['OffValue']) { return $flag['OffValue'] } else { return 'Disabled' }
}

function ConvertTo-TouchpadNumberValue([string] $Name, [uint32] $Number) {
    if ($Name -eq 'SensitivityLevel') {
        return $script:TouchpadSensitivityLevels[$Number]
    }
    return [int] $Number
}

function ConvertFrom-TouchpadNumberValue([string] $Name, $Value) {
    if ($Name -eq 'SensitivityLevel') {
        return [uint32] [array]::IndexOf($script:TouchpadSensitivityLevels, $Value)
    }
    return [uint32] $Value
}

# Current settings by property name. Settings that can't be read here (never set, or no known
# registry equivalent on older Windows) are absent.
function Get-TouchpadState {
    $state = @{}
    $buffer = Get-TouchpadParameters
    if ($buffer) {
        $flags = [BitConverter]::ToUInt32($buffer, $script:TouchpadFlagsOffset)
        foreach ($name in $script:TouchpadFlags.Keys) {
            $state[$name] = ConvertTo-TouchpadFlagValue $name (($flags -shr $script:TouchpadFlags[$name].Bit) -band 1)
        }
        foreach ($name in $script:TouchpadNumbers.Keys) {
            $state[$name] = ConvertTo-TouchpadNumberValue $name ([BitConverter]::ToUInt32($buffer, $script:TouchpadNumbers[$name].Offset))
        }
        return $state
    }

    $values = Get-ItemProperty -Path $script:TouchpadKey -ErrorAction SilentlyContinue
    foreach ($name in $script:TouchpadFlags.Keys) {
        $valueName = $script:TouchpadFlags[$name].Registry
        if ($valueName -and $null -ne $values.$valueName) {
            $state[$name] = ConvertTo-TouchpadFlagValue $name ($values.$valueName -ne 0)
        }
    }
    foreach ($name in $script:TouchpadNumbers.Keys) {
        $valueName = $script:TouchpadNumbers[$name].Registry
        if ($valueName -and $null -ne $values.$valueName) {
            $state[$name] = ConvertTo-TouchpadNumberValue $name ([uint32] $values.$valueName)
        }
    }
    return $state
}

# Applies the given settings (property name -> value). Returns $true if they took effect
# immediately, $false if they apply at the next sign-in.
function Set-TouchpadState([System.Collections.IDictionary] $Desired) {
    $buffer = Get-TouchpadParameters
    if ($buffer) {
        $flags = [uint64] [BitConverter]::ToUInt32($buffer, $script:TouchpadFlagsOffset)
        foreach ($name in $Desired.Keys) {
            if ($script:TouchpadFlags.Contains($name)) {
                $mask = [uint64] 1 -shl $script:TouchpadFlags[$name].Bit
                $isSet = $Desired[$name] -eq (ConvertTo-TouchpadFlagValue $name $true)
                $flags = if ($isSet) { $flags -bor $mask } else { $flags -band ([uint64] 0xFFFFFFFF -bxor $mask) }
            } else {
                $number = ConvertFrom-TouchpadNumberValue $name $Desired[$name]
                [BitConverter]::GetBytes($number).CopyTo($buffer, $script:TouchpadNumbers[$name].Offset)
            }
        }
        [BitConverter]::GetBytes([uint32] $flags).CopyTo($buffer, $script:TouchpadFlagsOffset)
        Set-TouchpadParameters $buffer
        return $true
    }

    $unsupported = @($Desired.Keys | Where-Object {
        -not ($script:TouchpadFlags[$_].Registry -or $script:TouchpadNumbers[$_].Registry)
    })
    if ($unsupported) {
        throw "Touchpad setting(s) $($unsupported -join ', ') need Windows 11 24H2 or later (SPI_SETTOUCHPADPARAMETERS)"
    }
    if (-not (Test-Path $script:TouchpadKey)) {
        New-Item -Path $script:TouchpadKey | Out-Null
    }
    foreach ($name in $Desired.Keys) {
        if ($script:TouchpadFlags.Contains($name)) {
            $valueName = $script:TouchpadFlags[$name].Registry
            $data = if ($Desired[$name] -eq (ConvertTo-TouchpadFlagValue $name $true)) { -1 } else { 0 }  # -1 is stored as 0xFFFFFFFF
        } else {
            $valueName = $script:TouchpadNumbers[$name].Registry
            $data = [int] (ConvertFrom-TouchpadNumberValue $name $Desired[$name])
        }
        Set-ItemProperty -Path $script:TouchpadKey -Name $valueName -Type DWord -Value $data
    }
    return $false
}

# The settings a PrecisionTouchpad instance manages, by property name.
function Get-TouchpadDesired($resource) {
    $desired = [ordered]@{}
    foreach ($name in $script:TouchpadFlags.Keys) {
        if ($resource.$name) { $desired[$name] = $resource.$name }
    }
    if ($resource.SensitivityLevel) {
        $desired['SensitivityLevel'] = $resource.SensitivityLevel
    }
    foreach ($name in @($script:TouchpadNumbers.Keys | Where-Object { $_ -ne 'SensitivityLevel' })) {
        $value = $resource.$name
        if ($value -eq -1) { continue }
        $range = $script:TouchpadNumbers[$name]
        if ($value -lt $range.Min -or $value -gt $range.Max) {
            throw "$name must be $($range.Min)-$($range.Max) (or -1 to leave it unmanaged), not $value"
        }
        $desired[$name] = $value
    }
    return $desired
}

# Precision touchpad settings for the current user (Settings > Devices > Touchpad), covering
# every user setting in TOUCHPAD_PARAMETERS_V1. Settings left unset (or -1 for numbers) aren't
# managed. On Windows 11 24H2+ changes apply immediately. On older Windows they apply at the
# next sign-in, and settings marked "Windows 11 24H2+" below fail with an error there.
[DscResource()]
class PrecisionTouchpad {
    # Touchpad settings are per user, not per device; always 'Yes'.
    [DscProperty(Key)]
    [ValidateSet('Yes')]
    [string] $IsSingleInstance

    # "Leave touchpad on when a mouse is connected"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $AllowActiveWhenMousePresent

    # Haptic feedback, on touchpads that support it. Windows 11 24H2+.
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $FeedbackEnabled

    # "Tap with a single finger to single-click"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $Taps

    # "Tap twice and drag to multi-select"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $TapAndDrag

    # "Tap with two fingers to right-click"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $TwoFingerTap

    # "Press the lower right corner of the touchpad to right-click"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $RightClickZone

    # Touchpad cursor motion honors the mouse acceleration setting ("Enhance pointer
    # precision"); when disabled, acceleration always applies. Windows 11 24H2+.
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $HonorMouseAccelSetting

    # "Drag two fingers to scroll"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $Pan

    # "Pinch to zoom"
    [DscProperty()]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $Zoom

    # "Scrolling direction". Windows' default is DownMotionScrollsUp.
    [DscProperty()]
    [ValidateSet('DownMotionScrollsUp', 'DownMotionScrollsDown')]
    [string] $ScrollDirection

    # "Touchpad sensitivity": how much touchpad input is suppressed after typing.
    [DscProperty()]
    [ValidateSet('MostSensitive', 'HighSensitivity', 'MediumSensitivity', 'LowSensitivity', 'LeastSensitive')]
    [string] $SensitivityLevel

    # "Change the cursor speed", 1-20 (Windows 10's slider shows half this, 1-10).
    [DscProperty()]
    [int] $CursorSpeed = -1

    # Haptic feedback intensity, 0-100. Windows 11 24H2+.
    [DscProperty()]
    [int] $FeedbackIntensity = -1

    # Haptic click force sensitivity, 0-100. Windows 11 24H2+.
    [DscProperty()]
    [int] $ClickForceSensitivity = -1

    # Right-click zone size as a percentage of the touchpad, 1-100 (0 = the device's default).
    # Windows 11 24H2+.
    [DscProperty()]
    [int] $RightClickZoneWidth = -1

    [DscProperty()]
    [int] $RightClickZoneHeight = -1

    [PrecisionTouchpad] Get() {
        $current = [PrecisionTouchpad]::new()
        $current.IsSingleInstance = 'Yes'
        $state = Get-TouchpadState
        foreach ($name in $state.Keys) {
            # Values outside what the properties accept (e.g. an unexpected level) stay unset.
            try { $current.$name = $state[$name] } catch { }
        }
        return $current
    }

    [bool] Test() {
        $state = Get-TouchpadState
        $desired = Get-TouchpadDesired $this
        foreach ($name in $desired.Keys) {
            if (-not $state.ContainsKey($name) -or "$($state[$name])" -ne "$($desired[$name])") {
                return $false
            }
        }
        return $true
    }

    [void] Set() {
        if (-not (Set-TouchpadState (Get-TouchpadDesired $this))) {
            # winget doesn't surface this; hardware profiles print a note instead.
            Write-Warning 'Touchpad settings saved; they take effect at the next sign-in (applying them immediately needs Windows 11 24H2 or later).'
        }
    }
}

# --- Go --------------------------------------------------------------------------------

# 'go1.27.1' / '1.27.1' -> [version] 1.27.1
function ConvertTo-GoVersion([string] $Version) {
    return [version] ($Version -replace '^go', '')
}

# The installed Go, per its MSI's entry in Programs and Features (winget's GoLang.Go package
# uses the same MSI).
function Get-GoInstall {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Go Programming Language*' -and $_.DisplayVersion } |
        Sort-Object { ConvertTo-GoVersion $_.DisplayVersion } -Descending |
        Select-Object -First 1 |
        ForEach-Object {
            [pscustomobject]@{ Version = ConvertTo-GoVersion $_.DisplayVersion; ProductCode = $_.PSChildName }
        }
}

# The latest stable release's Windows MSI, from go.dev's release list. (winget's GoLang.Go
# package can lag upstream releases by days.)
function Get-GoLatestRelease {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $releases = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' -ErrorAction Stop
    $release = $releases | Where-Object stable |
        Sort-Object { ConvertTo-GoVersion $_.version } -Descending |
        Select-Object -First 1
    $file = $release.files |
        Where-Object { $_.os -eq 'windows' -and $_.arch -eq $arch -and $_.kind -eq 'installer' } |
        Select-Object -First 1
    if (-not $file) {
        throw "go.dev lists no Windows $arch installer for $($release.version)"
    }
    return [pscustomobject]@{
        Version  = ConvertTo-GoVersion $release.version
        FileName = $file.filename
        Url      = "https://go.dev/dl/$($file.filename)"
        Sha256   = $file.sha256
    }
}

function Invoke-Msiexec([string[]] $Arguments) {
    $process = Start-Process -FilePath msiexec.exe -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        Write-Warning 'msiexec: a restart is required to finish the installation'
    } elseif ($process.ExitCode -ne 0) {
        throw "msiexec $($Arguments -join ' ') failed with exit code $($process.ExitCode)"
    }
}

function Install-GoRelease($release) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "windows-setup-go-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $msi = Join-Path $dir $release.FileName
    $log = Join-Path $dir 'msiexec.log'

    $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows it down badly
    Invoke-WebRequest -Uri $release.Url -OutFile $msi -UseBasicParsing -ErrorAction Stop
    $hash = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
    if ($hash -ne $release.Sha256) {
        throw "Checksum mismatch for $($release.FileName): go.dev lists $($release.Sha256), downloaded $hash"
    }
    try {
        Invoke-Msiexec @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"")
    } catch {
        throw "$_ (log: $log)"  # keep the directory for the log
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# Ensures Go is installed from go.dev's official Windows MSI, optionally keeping it on the
# latest stable release and/or at least a given version.
[DscResource()]
class GoLang {
    # Only one Go install is managed; always 'Yes'.
    [DscProperty(Key)]
    [ValidateSet('Yes')]
    [string] $IsSingleInstance

    [DscProperty()]
    [Ensure] $Ensure = [Ensure]::Present

    # Upgrade whenever go.dev has a newer stable release.
    [DscProperty()]
    [bool] $UseLatest

    # Oldest acceptable version, e.g. 1.27.1.
    [DscProperty()]
    [string] $MinimumVersion

    [DscProperty(NotConfigurable)]
    [string] $InstalledVersion

    [GoLang] Get() {
        $current = [GoLang]::new()
        $current.IsSingleInstance = 'Yes'
        $installed = Get-GoInstall
        $current.Ensure = if ($installed) { [Ensure]::Present } else { [Ensure]::Absent }
        $current.InstalledVersion = if ($installed) { "$($installed.Version)" } else { $null }
        return $current
    }

    [bool] Test() {
        $installed = Get-GoInstall
        if ($this.Ensure -eq [Ensure]::Absent) {
            return -not $installed
        }
        if (-not $installed) {
            return $false
        }
        if ($this.MinimumVersion -and $installed.Version -lt (ConvertTo-GoVersion $this.MinimumVersion)) {
            Write-Verbose "Go $($installed.Version) is older than $($this.MinimumVersion)"
            return $false
        }
        if ($this.UseLatest) {
            $latest = (Get-GoLatestRelease).Version
            if ($installed.Version -lt $latest) {
                Write-Verbose "Go $($installed.Version) is older than the latest stable, $latest"
                return $false
            }
        }
        return $true
    }

    [void] Set() {
        $installed = Get-GoInstall
        if ($this.Ensure -eq [Ensure]::Absent) {
            if ($installed) {
                Invoke-Msiexec @('/x', $installed.ProductCode, '/qn', '/norestart')
            }
            return
        }

        $release = Get-GoLatestRelease
        if ($this.MinimumVersion -and $release.Version -lt (ConvertTo-GoVersion $this.MinimumVersion)) {
            throw "The latest stable Go on go.dev ($($release.Version)) is older than MinimumVersion $($this.MinimumVersion)"
        }
        if ($installed -and $installed.Version -ge $release.Version) {
            return
        }
        # Go's MSI declares <MajorUpgrade> with a fixed per-arch UpgradeCode, so installing a
        # newer one replaces the old version in the same transaction (rolled back on failure).
        # winget's GoLang.Go manifest relies on the same thing (UpgradeBehavior: install).
        Install-GoRelease $release
    }
}

# --- Git for Windows -------------------------------------------------------------------

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
