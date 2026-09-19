# Downloads windows-setup (default: main), caches it by commit, and runs its bootstrap. Meant to be
# run straight from GitHub in Windows PowerShell:
#
#   irm https://raw.githubusercontent.com/cstrahan/windows-setup/main/install.ps1 | iex
#
# To pass options (-Ref, -CacheDir) or bootstrap arguments (e.g. -SkipWsl):
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cstrahan/windows-setup/main/install.ps1))) -SkipWsl
#
# Runs in Windows PowerShell 5.1. Everything is inside a script block so nothing leaks into the
# caller's session (iex runs code there), and it never calls `exit`, which would close the
# caller's window.
& {
    param(
        # Branch, tag or commit to install.
        [string] $Ref = 'main',
        # Where extracted copies are cached, one directory per commit.
        [string] $CacheDir = (Join-Path $env:LOCALAPPDATA 'windows-setup')
    )
    # Any other arguments ($args) are passed through to bootstrap.ps1.

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest's progress bar slows 5.1 down badly
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repo = 'cstrahan/windows-setup'
    $keep = 3  # most recently used commits to keep in the cache
    $headers = @{ 'User-Agent' = 'windows-setup-install' }

    try {
        Write-Host "==> Resolving $repo@$Ref"
        $sha = "$(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$Ref" `
            -Headers ($headers + @{ Accept = 'application/vnd.github.sha' }))".Trim()
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            throw "unexpected commit id from GitHub: '$sha'"
        }
        $dir = Join-Path $CacheDir $sha

        # A directory only appears once its archive is fully extracted, so its presence means
        # it's complete.
        if (Test-Path (Join-Path $dir 'bootstrap.ps1')) {
            Write-Host "==> Using cached $($sha.Substring(0, 12)) in $dir"
        } else {
            Write-Host "==> Downloading $($sha.Substring(0, 12))"
            New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
            $zip = Join-Path $CacheDir "$sha.zip"
            $staging = Join-Path $CacheDir "$sha.partial"
            Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$repo/zip/$sha" -OutFile $zip -Headers $headers
            if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $staging
            # The archive holds a single top-level directory, <repo>-<sha>.
            $top = @(Get-ChildItem -LiteralPath $staging -Directory)
            if ($top.Count -ne 1) { throw "unexpected archive layout in $zip" }
            Move-Item -LiteralPath $top[0].FullName -Destination $dir
            Remove-Item -LiteralPath $staging -Recurse -Force
            Remove-Item -LiteralPath $zip -Force
        }
        (Get-Item -LiteralPath $dir).LastWriteTime = Get-Date  # for pruning by recent use

        Get-ChildItem -LiteralPath $CacheDir -Directory |
            Where-Object { $_.Name -match '^[0-9a-f]{40}$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $keep |
            ForEach-Object {
                Write-Host "==> Removing old cached copy $($_.Name.Substring(0, 12))"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }

        Write-Host '==> Running bootstrap'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'bootstrap.ps1') @args
        if ($LASTEXITCODE -ne 0) {
            Write-Host "==> bootstrap exited with $LASTEXITCODE" -ForegroundColor Yellow
        }
    } catch {
        $message = "$_"
        # GitHub API errors come back as JSON; show just their message.
        if ($_.ErrorDetails -and $_.ErrorDetails.Message -match '^\s*\{') {
            $message = ($_.ErrorDetails.Message | ConvertFrom-Json).message
        }
        Write-Host "install failed: $message" -ForegroundColor Red
    }
} @args
