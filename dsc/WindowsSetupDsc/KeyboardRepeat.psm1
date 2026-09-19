# KeyboardRepeat: per-user keyboard repeat delay and rate.

using module .\Common.psm1

# Setting name -> SPI_GET*/SPI_SET* actions, its value under HKCU\Control Panel\Keyboard (a
# string), and its valid range.
$script:KeyboardRepeatSettings = [ordered]@{
    RepeatDelay = @{ Get = 0x0016; Set = 0x0017; Registry = 'KeyboardDelay'; Min = 0; Max = 3 }   # SPI_GET/SETKEYBOARDDELAY
    RepeatRate  = @{ Get = 0x000A; Set = 0x000B; Registry = 'KeyboardSpeed'; Min = 0; Max = 31 }  # SPI_GET/SETKEYBOARDSPEED
}

# Live (in-session) and saved (registry) values of one setting.
function Get-KeyboardRepeatSetting([string] $Name) {
    Initialize-SpiInterop
    $setting = $script:KeyboardRepeatSettings[$Name]
    $live = [uint32] 0
    if (-not [WindowsSetupDsc.NativeMethods]::SystemParametersInfoW($setting['Get'], 0, [ref] $live, 0)) {
        throw "SystemParametersInfo(0x$('{0:X4}' -f $setting['Get'])) failed (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $saved = (Get-ItemProperty -Path 'HKCU:\Control Panel\Keyboard' -Name $setting['Registry'] -ErrorAction SilentlyContinue).($setting['Registry'])
    return [pscustomobject]@{ Live = [int] $live; Saved = if ($null -ne $saved) { [int] $saved } else { $null } }
}

function Set-KeyboardRepeatSetting([string] $Name, [int] $Value) {
    Initialize-SpiInterop
    $SPIF_UPDATEINIFILE_SENDCHANGE = 0x3  # apply now and save to the registry
    $setting = $script:KeyboardRepeatSettings[$Name]
    if (-not [WindowsSetupDsc.NativeMethods]::SystemParametersInfoW($setting['Set'], [uint32] $Value, [System.IntPtr]::Zero, $SPIF_UPDATEINIFILE_SENDCHANGE)) {
        throw "SystemParametersInfo(0x$('{0:X4}' -f $setting['Set'])) failed (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
}

# The settings a KeyboardRepeat instance manages, by name.
function Get-KeyboardRepeatDesired($resource) {
    $desired = [ordered]@{}
    foreach ($name in $script:KeyboardRepeatSettings.Keys) {
        $value = $resource.$name
        if ($value -eq -1) { continue }
        $range = $script:KeyboardRepeatSettings[$name]
        if ($value -lt $range['Min'] -or $value -gt $range['Max']) {
            throw "$name must be $($range['Min'])-$($range['Max']) (or -1 to leave it unmanaged), not $value"
        }
        $desired[$name] = $value
    }
    return $desired
}

# Keyboard character repeat for the current user (Control Panel > Keyboard > Speed). Applied
# immediately and saved, on any Windows version. Test checks both the live and the saved value,
# since something can change the live one without saving it.
[DscResource()]
class KeyboardRepeat {
    # Per user; always 'Yes'.
    [DscProperty(Key)]
    [ValidateSet('Yes')]
    [string] $IsSingleInstance

    # "Repeat delay": 0 (shortest, about 250 ms) to 3 (longest, about 1 s). Windows' default is 1.
    [DscProperty()]
    [int] $RepeatDelay = -1

    # "Repeat rate": 0 (slowest, about 2.5 per second) to 31 (fastest, about 30 per second).
    # Windows' default is 31.
    [DscProperty()]
    [int] $RepeatRate = -1

    [KeyboardRepeat] Get() {
        $current = [KeyboardRepeat]::new()
        $current.IsSingleInstance = 'Yes'
        foreach ($name in $script:KeyboardRepeatSettings.Keys) {
            $current.$name = (Get-KeyboardRepeatSetting $name).Live
        }
        return $current
    }

    [bool] Test() {
        $desired = Get-KeyboardRepeatDesired $this
        foreach ($name in $desired.Keys) {
            $current = Get-KeyboardRepeatSetting $name
            if ($current.Live -ne $desired[$name] -or $current.Saved -ne $desired[$name]) {
                return $false
            }
        }
        return $true
    }

    [void] Set() {
        $desired = Get-KeyboardRepeatDesired $this
        foreach ($name in $desired.Keys) {
            Set-KeyboardRepeatSetting $name $desired[$name]
        }
    }
}
