# NvidiaDriver: the latest NVIDIA display driver for the machine's GPU, from NVIDIA's own driver
# lookup (winget has no package for it).

# The lookup NVIDIA's client software uses: given a PCI device ID it returns the latest driver
# and its download URL. (Found in use by e.g. TinyNvidiaUpdateChecker and NVCleanstall.)
$script:LookupUri = 'https://gfwsl.geforce.com/nvidia_web_services/controller.gfeclientcontent.NG.php/com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
$script:DownloadDir = Join-Path $env:ProgramData 'windows-setup\nvidia'

# The first NVIDIA display adapter present, or $null.
function Get-NvidiaGpu {
    $device = Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
        Where-Object { @($_.HardwareID) -match '^PCI\\VEN_10DE&DEV_([0-9A-F]{4})' } |
        Select-Object -First 1
    if (-not $device) { return $null }
    $deviceId = ([regex]::Match((@($device.HardwareID) -join ' '), 'VEN_10DE&DEV_([0-9A-F]{4})')).Groups[1].Value
    $windowsVersion = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue).Data
    $provider = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_DriverProvider -ErrorAction SilentlyContinue).Data
    return [pscustomobject]@{
        Name           = $device.FriendlyName
        DeviceId       = $deviceId
        InstanceId     = $device.InstanceId
        # NVIDIA's version is the last five digits of the Windows one's last two parts:
        # 31.0.15.3713 -> 537.13. Without NVIDIA's driver (e.g. Microsoft Basic Display) it's $null.
        DriverVersion  = if ($provider -eq 'NVIDIA') { ConvertTo-NvidiaVersion $windowsVersion } else { $null }
    }
}

function ConvertTo-NvidiaVersion([string] $WindowsVersion) {
    if ($WindowsVersion -notmatch '^\d+\.\d+\.(\d+)\.(\d+)$') { return $null }
    $digits = $Matches[1] + $Matches[2].PadLeft(4, '0')
    if ($digits.Length -lt 5) { return $null }
    $digits = $digits.Substring($digits.Length - 5)
    return [version] ('{0}.{1}' -f [int] $digits.Substring(0, 3), [int] $digits.Substring(3))
}

# The latest driver for a GPU: Version and the standalone package's URL.
function Get-NvidiaLatestDriver([string] $DeviceId, [bool] $Studio) {
    $build = [Environment]::OSVersion.Version
    $isLaptop = [bool] (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)  # notebook vs desktop packages
    $crd = if ($Studio) { '1' } else { '0' }  # CRD: NVIDIA's name for the Studio branch
    $query = [ordered]@{
        dIDa = @("${DeviceId}_10DE"); osC = "$($build.Major).$($build.Minor)"; osB = "$($build.Build)"; is6 = '1'
        lg = '1033'; iLp = $(if ($isLaptop) { '1' } else { '0' }); prvMd = '0'; gcV = '3.27.0.112'; gIsB = '1'
        dch = '1'; upCRD = $crd; isCRD = $crd
    } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Uri ($script:LookupUri + [uri]::EscapeDataString($query)) -TimeoutSec 60 -ErrorAction Stop
    $driver = $response.DriverAttributes
    if (-not $driver -or -not $driver.Version -or -not $driver.DownloadURLAdmin) {
        throw "NVIDIA's driver lookup returned no driver for device $DeviceId"
    }
    if ($response.criteria.IsSupported.state -ne 'true') {
        throw "NVIDIA's driver lookup says device $DeviceId isn't supported"
    }
    return [pscustomobject]@{ Version = [version] $driver.Version; Name = $driver.Name; Url = $driver.DownloadURLAdmin }
}

# Runs an installer and waits for it, with Windows PowerShell's own PSModulePath, in case it runs
# powershell.exe internally (PowerShell 7's breaks 5.1's core modules; see WindowsSetup.DriverInstaller).
function Start-InstallerProcess([string] $FilePath, [string[]] $Arguments) {
    $saved = $env:PSModulePath
    $env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    try {
        return Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    } finally {
        $env:PSModulePath = $saved
    }
}

# Ensures the machine's NVIDIA GPU has the latest Game Ready (or Studio) driver. The package is
# NVIDIA's standard one (driver, HD Audio, PhysX and the NVIDIA App), installed silently. On
# machines without an NVIDIA GPU this does nothing.
[DscResource()]
class NvidiaDriver {
    [DscProperty(Key)]
    [ValidateSet('Yes')]
    [string] $IsSingleInstance

    # Track NVIDIA's Studio branch instead of Game Ready.
    [DscProperty()]
    [bool] $Studio

    [DscProperty(NotConfigurable)]
    [string] $Gpu

    [DscProperty(NotConfigurable)]
    [string] $InstalledVersion

    [DscProperty(NotConfigurable)]
    [string] $LatestVersion

    [NvidiaDriver] Get() {
        $current = [NvidiaDriver]::new()
        $current.IsSingleInstance = 'Yes'
        $current.Studio = $this.Studio
        $adapter = Get-NvidiaGpu
        if ($adapter) {
            $current.Gpu = "$($adapter.Name) ($($adapter.DeviceId))"
            $current.InstalledVersion = "$($adapter.DriverVersion)"
            $current.LatestVersion = "$((Get-NvidiaLatestDriver $adapter.DeviceId $this.Studio).Version)"
        }
        return $current
    }

    [bool] Test() {
        $adapter = Get-NvidiaGpu
        if (-not $adapter) { return $true }
        try {
            $latest = Get-NvidiaLatestDriver $adapter.DeviceId $this.Studio
        } catch {
            # Offline or the service changed: don't fail the whole run over an update check if a
            # driver is installed at all.
            if ($adapter.DriverVersion) {
                Write-Warning "Couldn't check for a newer NVIDIA driver: $($_.Exception.Message)"
                return $true
            }
            throw
        }
        return $adapter.DriverVersion -and $adapter.DriverVersion -ge $latest.Version
    }

    [void] Set() {
        if ($this.Test()) { return }  # DSC v3 calls Set() without testing first
        $adapter = Get-NvidiaGpu
        $latest = Get-NvidiaLatestDriver $adapter.DeviceId $this.Studio
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
        $package = Join-Path $script:DownloadDir (Split-Path ([uri] $latest.Url).AbsolutePath -Leaf)
        try {
            $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows it down badly
            Invoke-WebRequest -Uri $latest.Url -OutFile $package -UseBasicParsing -ErrorAction Stop
            # NVIDIA publishes no checksums; the package is Authenticode-signed by NVIDIA.
            $signature = Get-AuthenticodeSignature -LiteralPath $package
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=NVIDIA Corporation(,|$)') {
                throw "$package isn't validly signed by NVIDIA ($($signature.Status): $($signature.SignerCertificate.Subject))"
            }
            # -s: silent, with the default components; -noreboot: leave restarting to the user.
            $process = Start-InstallerProcess $package @('-s', '-noreboot')
            $installed = (Get-NvidiaGpu).DriverVersion
            if ($installed -ge $latest.Version) {
                if ($process.ExitCode -ne 0) {
                    Write-Warning "NVIDIA's installer exited with $($process.ExitCode); the driver is $installed. A restart may be needed."
                }
            } else {
                throw "NVIDIA's installer exited with $($process.ExitCode), and the driver is still $installed (wanted $($latest.Version)). Logs: $env:ProgramData\NVIDIA Corporation\Installer2"
            }
        } finally {
            Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        }
    }
}
