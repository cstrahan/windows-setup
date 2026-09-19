# PrecisionTouchpad: per-user precision touchpad settings.

using module WindowsSetup.Common

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
        if ($this.Test()) { return }  # DSC v3 calls Set() without testing first
        if (-not (Set-TouchpadState (Get-TouchpadDesired $this))) {
            # Shown by dsc as a warning; hardware profiles also print a note.
            Write-Warning 'Touchpad settings saved; they take effect at the next sign-in (applying them immediately needs Windows 11 24H2 or later).'
        }
    }
}
