# DriverPackage: device drivers from a vendor's zip, installed INF by INF with pnputil (rather than
# the vendor's setup program), so the result can be checked device by device.

# Downloaded packages, one directory per SHA-256, extracted in full. A directory only appears once
# its zip matched the hash and extracted (it's renamed into place), so its presence is enough.
$script:CacheRoot = Join-Path $env:ProgramData 'windows-setup\drivers'

function Get-DriverPackageFiles([string] $Uri, [string] $Sha256) {
    $dir = Join-Path $script:CacheRoot $Sha256.ToUpperInvariant()
    if (Test-Path -LiteralPath $dir) { return $dir }

    New-Item -ItemType Directory -Path $script:CacheRoot -Force | Out-Null
    $staging = "$dir.partial-$([guid]::NewGuid().ToString('N'))"
    $zip = "$staging.zip"
    try {
        $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows it down badly
        for ($attempt = 1; ; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $zip -UseBasicParsing -ErrorAction Stop
                break
            } catch {
                if ($attempt -ge 3) { throw "downloading $Uri failed: $($_.Exception.Message)" }
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
            }
        }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $Sha256.ToUpperInvariant()) {
            throw "Checksum mismatch for ${Uri}: expected $Sha256, downloaded $hash"
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        Rename-Item -LiteralPath $staging -NewName (Split-Path $dir -Leaf)
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $dir
}

# An INF's driver version (from DriverVer = date, version) and the device IDs its models list.
function Read-DriverInf([string] $Path) {
    $version = $null
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $line = ($line -split ';', 2)[0]  # INF comments start with ';'
        if ($line -match '^\s*DriverVer\s*=\s*[^,]*,\s*([0-9.]+)') {
            $version = [version] $Matches[1]
        }
        foreach ($match in [regex]::Matches($line, '(?i)\b(PCI|ACPI|HID|USB)\\[^\s,"]+')) {
            [void] $ids.Add($match.Value)
        }
    }
    if (-not $version) { throw "No DriverVer in $Path" }
    return [pscustomobject]@{ Path = $Path; Name = Split-Path $Path -Leaf; Version = $version; Ids = $ids }
}

# A device's current driver version, or $null if it has none. From the device's own property,
# not Win32_PnPSignedDriver: right after pnputil installed a driver, that WMI class still showed
# the device with a blank version.
function Get-DeviceDriverVersion([string] $InstanceId) {
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue
    if ($property -and $property.Data) { return [version] $property.Data }
    return $null
}

# Present devices that an INF lists (by hardware or compatible ID) whose current driver is older
# than the INF's, or that have none. -DriverVersion stands in for Get-DeviceDriverVersion in tests.
function Get-OutdatedDevices($Inf, $Devices, [scriptblock] $DriverVersion = { param($Id) Get-DeviceDriverVersion $Id }) {
    foreach ($device in $Devices) {
        $deviceIds = @($device.HardwareID) + @($device.CompatibleID) | Where-Object { $_ }
        if (-not @($deviceIds | Where-Object { $Inf.Ids.Contains($_) })) { continue }
        $current = & $DriverVersion $device.InstanceId
        if (-not $current -or $current -lt $Inf.Version) {
            [pscustomobject]@{
                Device  = if ($device.FriendlyName) { $device.FriendlyName } else { $device.InstanceId }
                Current = if ($current) { "$current" } else { 'none' }
                Inf     = $Inf.Name
                Wanted  = "$($Inf.Version)"
            }
        }
    }
}

# Ensures a vendor driver package's drivers (or newer) are on every present device they cover.
# Devices none of its INFs list are ignored, so on other hardware this does nothing.
[DscResource()]
class DriverPackage {
    # A label, e.g. 'Intel chipset (Tiger Lake PCH-H)'.
    [DscProperty(Key)]
    [string] $Name

    # The package's zip; pin it to a commit or release so it can't change underneath Sha256.
    [DscProperty(Mandatory)]
    [string] $Uri

    [DscProperty(Mandatory)]
    [string] $Sha256

    # The INFs to install, relative to the zip's root (its .cat and .sys files sit next to them).
    [DscProperty(Mandatory)]
    [string[]] $Infs

    # "device: current -> wanted (inf)" for each device that needs a driver update.
    [DscProperty(NotConfigurable)]
    [string[]] $OutdatedDevices

    [object[]] GetOutdated() {
        $root = Get-DriverPackageFiles $this.Uri $this.Sha256
        $devices = @(Get-PnpDevice -PresentOnly)
        $outdated = foreach ($relative in $this.Infs) {
            $path = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $path)) { throw "$relative isn't in $($this.Uri)" }
            Get-OutdatedDevices (Read-DriverInf $path) $devices
        }
        return @($outdated)
    }

    [DriverPackage] Get() {
        $current = [DriverPackage]::new()
        $current.Name = $this.Name
        $current.Uri = $this.Uri
        $current.Sha256 = $this.Sha256
        $current.Infs = $this.Infs
        $current.OutdatedDevices = @($this.GetOutdated() | ForEach-Object { "$($_.Device): $($_.Current) -> $($_.Wanted) ($($_.Inf))" })
        return $current
    }

    [bool] Test() {
        return -not $this.GetOutdated()
    }

    [void] Set() {
        $outdated = $this.GetOutdated()
        if (-not $outdated) { return }  # DSC v3 calls Set() without testing first
        $root = Get-DriverPackageFiles $this.Uri $this.Sha256
        foreach ($relative in $this.Infs) {
            $inf = Join-Path $root $relative
            if (-not @($outdated | Where-Object Inf -eq (Split-Path $inf -Leaf))) { continue }
            # Captured, not emitted: the adapter uses stdout. /install also updates matching
            # devices where this driver ranks best (Intel dates its INF-only chipset drivers
            # 1968 so they never outrank a real driver).
            $output = & pnputil.exe /add-driver $inf /install 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            if ($code -eq 3010) {
                Write-Warning "$(Split-Path $inf -Leaf): a restart is required to finish installing the driver."
            } elseif ($code -ne 0 -and $code -ne 259) {  # 259: added, but no device needed it
                throw "pnputil /add-driver $relative /install failed with exit code ${code}: $(($output | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' / ')"
            }
        }
        $still = $this.GetOutdated()
        if ($still) {
            throw ("Installed the drivers, but these devices still don't use them: " +
                (($still | ForEach-Object { "$($_.Device) ($($_.Current), wanted $($_.Wanted) from $($_.Inf))" }) -join '; '))
        }
    }
}
