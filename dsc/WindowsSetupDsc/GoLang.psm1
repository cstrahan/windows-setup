# GoLang: Go from go.dev's official Windows MSI.

using module .\Common.psm1

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
