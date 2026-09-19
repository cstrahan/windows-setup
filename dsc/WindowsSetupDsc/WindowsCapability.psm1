# WindowsCapability: installs or removes a Windows capability (Feature on Demand).

using module .\Common.psm1

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
