# WebFile: a file fetched from a URL, verified against a SHA-256, and placed somewhere. With
# ArchiveMember, the download is a zip (a .nupkg counts) and one file is taken out of it.
#
# Downloads are cached by their hash under %LOCALAPPDATA%\windows-setup\downloads, so several
# resources taking different members out of one archive fetch it once, and a re-run fetches
# nothing. Everything here is per-user, so this needs no elevation.

# What was put there, and from what: this is how Test() knows the file is the one asked for
# without re-downloading the archive to hash it.
function Get-MarkerPath([string] $Destination) { return "$Destination.webfile.json" }

function Read-Marker([string] $Destination) {
    $path = Get-MarkerPath $Destination
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { return $null }
}

function Get-CacheDirectory {
    $path = Join-Path $env:LOCALAPPDATA 'windows-setup\downloads'
    if (-not (Test-Path -LiteralPath $path)) { [void] (New-Item -ItemType Directory -Force -Path $path) }
    return $path
}

[DscResource()]
class WebFile {
    # Where the file ends up. Also the key: one resource per file placed.
    [DscProperty(Key)]
    [string] $Destination

    [DscProperty(Mandatory)]
    [string] $Uri

    # Of the downloaded file, before any extraction.
    [DscProperty(Mandatory)]
    [string] $Sha256

    # A path inside the downloaded zip, e.g. 'runtimes/win-x64/native/wasmtime.dll'. Without it,
    # the download itself is the file.
    [DscProperty()]
    [string] $ArchiveMember

    [DscProperty(NotConfigurable)]
    [string] $Status

    [string] Describe() {
        return "$($this.Uri)$(if ($this.ArchiveMember) { "!$($this.ArchiveMember)" })"
    }

    [string] CheckState() {
        if (-not (Test-Path -LiteralPath $this.Destination)) { return 'missing' }
        $marker = Read-Marker $this.Destination
        if (-not $marker) { return 'unmanaged' }
        if ($marker.Sha256 -ne $this.Sha256 -or $marker.Uri -ne $this.Uri -or $marker.ArchiveMember -ne $this.ArchiveMember) {
            return 'stale'
        }
        return 'current'
    }

    [string] Fetch() {
        $cached = Join-Path (Get-CacheDirectory) $this.Sha256.ToLowerInvariant()
        if (Test-Path -LiteralPath $cached) {
            $have = (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash
            if ($have -eq $this.Sha256) { return $cached }
            Remove-Item -LiteralPath $cached -Force
        }
        $temporary = "$cached.partial"
        # Invoke-WebRequest's progress rendering is slow and would go to the adapter's stdout.
        # Assigned, not saved and restored: a class method can't read the caller's preference
        # variables ("Variable is not assigned in the method"), and this local one covers the rest
        # of the method.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $this.Uri -OutFile $temporary -UseBasicParsing -ErrorAction Stop
        $downloaded = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($downloaded -ne $this.Sha256) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            throw "$($this.Uri) hashed $downloaded, expected $($this.Sha256). Either the pin is out of date or the download is not what it claims to be."
        }
        Move-Item -LiteralPath $temporary -Destination $cached -Force
        return $cached
    }

    [WebFile] Get() {
        $current = [WebFile]::new()
        $current.Destination = $this.Destination
        $current.Uri = $this.Uri
        $current.Sha256 = $this.Sha256
        $current.ArchiveMember = $this.ArchiveMember
        $current.Status = $this.CheckState()
        return $current
    }

    [bool] Test() {
        return $this.CheckState() -eq 'current'
    }

    [void] Set() {
        if ($this.Test()) { return }

        $archive = $this.Fetch()
        $directory = Split-Path -Parent $this.Destination
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            [void] (New-Item -ItemType Directory -Force -Path $directory)
        }

        if ($this.ArchiveMember) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                # Zip entries use forward slashes; accept either spelling from the caller.
                $wanted = $this.ArchiveMember -replace '\\', '/'
                $entry = $zip.Entries | Where-Object { $_.FullName -eq $wanted }
                if (-not $entry) {
                    throw "$($this.Uri) has no member '$wanted'. It holds $($zip.Entries.Count) entries, e.g. $(($zip.Entries | Select-Object -First 3 -ExpandProperty FullName) -join ', ')."
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $this.Destination, $true)
            } finally {
                $zip.Dispose()
            }
        } else {
            Copy-Item -LiteralPath $archive -Destination $this.Destination -Force
        }

        @{
            Uri           = $this.Uri
            Sha256        = $this.Sha256
            ArchiveMember = $this.ArchiveMember
            Written       = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-MarkerPath $this.Destination) -Encoding utf8
    }
}
