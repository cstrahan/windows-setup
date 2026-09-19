# DriverInstaller: a vendor's driver installer (.exe), pinned by SHA-256, run silently when a
# device it's for has an older driver. For packages that should go through their own installer
# (e.g. Intel's graphics driver); plain INF packages are DriverPackage's job.

$script:DownloadDir = Join-Path $env:ProgramData 'windows-setup\installers'

# Present devices with a hardware ID matching any pattern (-like wildcards), and their driver
# version from the device itself ($null without a driver).
function Get-TargetDevices([string[]] $HardwareIds) {
    foreach ($device in Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue) {
        $ids = @($device.HardwareID) | Where-Object { $_ }
        if (-not @($ids | Where-Object { $id = $_; @($HardwareIds | Where-Object { $id -like $_ }).Count })) { continue }
        $version = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue).Data
        [pscustomobject]@{
            Name          = if ($device.FriendlyName) { $device.FriendlyName } else { $device.InstanceId }
            DriverVersion = if ($version) { [version] $version } else { $null }
        }
    }
}

# Runs an installer and waits for it, with Windows PowerShell's own PSModulePath: installers that
# run powershell.exe internally would otherwise inherit PowerShell 7's, and 5.1 then can't load
# its core modules. (Intel's graphics package checks its files with Get-FileHash that way, and
# failed with "the file integrity check failed" before this.)
function Start-InstallerProcess([string] $FilePath, [string[]] $Arguments) {
    $saved = $env:PSModulePath
    $env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    try {
        $parameters = @{ FilePath = $FilePath; Wait = $true; PassThru = $true }
        if ($Arguments) { $parameters.ArgumentList = $Arguments }
        return Start-Process @parameters
    } finally {
        $env:PSModulePath = $saved
    }
}

# Ensures every present device matching HardwareIds has at least Version, running the pinned
# installer otherwise. Matches nothing on other hardware, so it does nothing there.
[DscResource()]
class DriverInstaller {
    [DscProperty(Key)]
    [string] $Name

    # Hardware ID patterns (PowerShell -like), e.g. PCI\VEN_8086&DEV_9A60*.
    [DscProperty(Mandatory)]
    [string[]] $HardwareIds

    # The driver version the installer brings, as Device Manager shows it.
    [DscProperty(Mandatory)]
    [string] $Version

    [DscProperty(Mandatory)]
    [string] $Uri

    [DscProperty(Mandatory)]
    [string] $Sha256

    # Silent-install arguments.
    [DscProperty()]
    [string[]] $Arguments = @()

    # Exit codes meaning success, and "installed, restart needed" (warned about). Either way the
    # devices are checked afterwards, so a success code alone can't mask a failed install.
    [DscProperty()]
    [int[]] $SuccessExitCodes = @(0)

    [DscProperty()]
    [int[]] $RestartExitCodes = @(3010)

    [DscProperty(NotConfigurable)]
    [string[]] $OutdatedDevices

    [object[]] GetOutdated() {
        $wanted = [version] $this.Version
        return @(Get-TargetDevices $this.HardwareIds | Where-Object { -not $_.DriverVersion -or $_.DriverVersion -lt $wanted })
    }

    [DriverInstaller] Get() {
        $current = [DriverInstaller]::new()
        foreach ($property in 'Name', 'HardwareIds', 'Version', 'Uri', 'Sha256', 'Arguments', 'SuccessExitCodes', 'RestartExitCodes') {
            $current.$property = $this.$property
        }
        $current.OutdatedDevices = @($this.GetOutdated() | ForEach-Object {
            "$($_.Name): $(if ($_.DriverVersion) { $_.DriverVersion } else { 'none' }) -> $($this.Version)"
        })
        return $current
    }

    [bool] Test() {
        return -not $this.GetOutdated()
    }

    [void] Set() {
        if ($this.Test()) { return }  # DSC v3 calls Set() without testing first
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
        $installer = Join-Path $script:DownloadDir (Split-Path ([uri] $this.Uri).AbsolutePath -Leaf)
        try {
            $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows it down badly
            Invoke-WebRequest -Uri $this.Uri -OutFile $installer -UseBasicParsing -ErrorAction Stop
            $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
            if ($hash -ne $this.Sha256.ToUpperInvariant()) {
                throw "Checksum mismatch for $($this.Uri): expected $($this.Sha256), downloaded $hash"
            }
            $process = Start-InstallerProcess $installer $this.Arguments
            $code = $process.ExitCode
            if ($code -in $this.RestartExitCodes) {
                Write-Warning "$($this.Name): installed; a restart is needed to finish (exit code $code)."
            } elseif ($code -notin $this.SuccessExitCodes) {
                throw "$($this.Name): the installer exited with $code"
            }
        } finally {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
        $still = $this.GetOutdated()
        if ($still) {
            throw ("$($this.Name): the installer finished, but these devices don't have $($this.Version): " +
                (($still | ForEach-Object { "$($_.Name) ($(if ($_.DriverVersion) { $_.DriverVersion } else { 'none' }))" }) -join '; '))
        }
    }
}
