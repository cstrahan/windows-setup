# Stage 1 bootstrap, in Windows PowerShell 5.1 (all a fresh Windows 10 has). Start it
# unelevated; it refuses to run otherwise. Two sections:
# - unelevated: per-user installs that should belong to the user (Scoop)
# - elevated (it relaunches itself with UAC): make sure winget works and is current, install or
#   update DSC v3 and PowerShell 7, then hand off to configure.ps1 (stage 2) in PowerShell 7.
# Safe to re-run; every step checks before acting.
#
# Any arguments are passed through to configure.ps1 (e.g. -SkipWsl, -Distro Debian).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RebootRequiredExitCode = 3010
$WingetUpdateNotApplicable = 0x8A15002B  # `winget upgrade`: already the latest version
$MinWingetVersion = [version] '1.6'
$Pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$VCRedistKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
# Scoop apps to install for the user, in the unelevated section.
$ScoopApps = @('mise', 'neovim')
$relaunched = $args -contains '--elevated-relaunch'
$passthru = @($args | Where-Object { $_ -ne '--elevated-relaunch' })

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Retries a network operation with exponential backoff (2s, 4s, ...). HTTP 4xx errors aren't
# retried: they won't go away. (Idea from microsoft/WindowsDeveloperConfig's invoke-retry.ps1.)
function Invoke-WithRetry([scriptblock] $Action, [string] $Name, [int] $Attempts = 3) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Action
        } catch {
            $status = $null
            if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
                $status = [int] $_.Exception.Response.StatusCode
            }
            if ($attempt -ge $Attempts -or ($status -ge 400 -and $status -lt 500)) { throw }
            $delay = [int] [Math]::Pow(2, $attempt)
            Write-Host "==> $Name failed ($($_.Exception.Message)); retrying in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

# Makes this (elevated) window's console UTF-8, so winget's spinner and progress-bar glyphs
# render instead of turning into mojibake under Windows PowerShell 5.1's default code page. The
# code page also carries over to configure.ps1. Only for the elevated window, which is ours; the
# original window is the user's terminal. (From microsoft/WindowsDeveloperConfig.)
function Set-Utf8Console {
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [Console]::OutputEncoding = $utf8
        $global:OutputEncoding = $utf8
        & cmd.exe /c 'chcp 65001 >nul'
    } catch {
        Write-Host "==> warning: couldn't switch the console to UTF-8: $($_.Exception.Message)"
    }
}

function Initialize-Winget {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return }
    # On a fresh install, App Installer is often present but not yet registered for the user.
    Write-Host '==> Registering App Installer (winget)...'
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is still unavailable. Update "App Installer" from the Microsoft Store, then re-run.'
    }
}

# Right after winget upgrades itself, launching it can briefly fail (WinError 1920) while the new
# package registers, so retry for up to a minute.
function Get-WingetVersion {
    for ($attempt = 1; ; $attempt++) {
        try {
            # Capture everything: `| Select-Object -First 1` would stop the pipeline early, which
            # in 5.1 leaves $LASTEXITCODE holding the previous command's exit code.
            $output = @(& winget.exe --version)
            if ($LASTEXITCODE -eq 0 -and $output) { return "$($output[0])".Trim() }
        } catch {
            if ($attempt -ge 12) { throw }
        }
        if ($attempt -ge 12) { throw 'winget --version kept failing' }
        Write-Host '==> winget not ready yet; retrying in 5s'
        Start-Sleep -Seconds 5
    }
}

# A current winget matters beyond packages: App Installer also provides the Microsoft.WinGet/*
# DSC v3 resources the configurations use.
function Update-Winget {
    Write-Host '==> Ensuring winget is up to date'
    $before = Get-WingetVersion
    & winget.exe upgrade --id Microsoft.AppInstaller --exact --source winget `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    # Upgrading winget replaces the running winget, which then typically exits with E_ABORT,
    # so judge success by the version afterwards.
    $after = Get-WingetVersion
    if ($after -ne $before) {
        Write-Host "==> winget upgraded: $before -> $after"
    } elseif ($code -ne 0 -and $code -ne $WingetUpdateNotApplicable) {
        Write-Host ('==> warning: upgrading App Installer failed (0x{0:X8}); continuing with winget {1}' -f $code, $after) -ForegroundColor Yellow
    }
    if ([version] ($after.TrimStart('v') -replace '-.*$', '') -lt $MinWingetVersion) {
        throw "winget $after is too old; need $MinWingetVersion or later"
    }
    Write-Host "==> winget $after"
}

# A registry value, or $null if the key or the value doesn't exist. (Not Get-ItemPropertyValue:
# in 5.1 it throws for a missing value even with -ErrorAction SilentlyContinue.)
function Get-RegistryValue([string] $Path, [string] $Name) {
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties[$Name]) { return $item.$Name }
    return $null
}

# winget's installer and configuration components use the Visual C++ 2015+ x64 runtime, which
# App Installer doesn't always bring along (per microsoft/WindowsDeveloperConfig's
# enable-winget-configure.ps1). Cheap to make sure of.
function Initialize-VCRedist {
    if ((Get-RegistryValue $VCRedistKey 'Installed') -eq 1) { return }
    Write-Host '==> Installing the Visual C++ 2015+ x64 runtime'
    & winget.exe install --id Microsoft.VCRedist.2015+.x64 --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $WingetUpdateNotApplicable) {
        throw ('installing the Visual C++ runtime failed (winget exited with 0x{0:X8})' -f $LASTEXITCODE)
    }
}

# DSC v3 (dsc.exe, an MSIX with an app execution alias) applies configure.ps1's configurations.
# Its Microsoft.WinGet/Package resource comes with App Installer, not with DSC, hence the check.
function Initialize-Dsc {
    Write-Host '==> Ensuring DSC v3 (dsc) is installed and up to date'
    $verb = if (Get-Command dsc.exe -ErrorAction SilentlyContinue) { 'upgrade' } else { 'install' }
    & winget.exe $verb --id Microsoft.DSC --exact --source winget `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    if (-not (Get-Command dsc.exe -ErrorAction SilentlyContinue)) {
        throw "dsc isn't installed (winget $verb Microsoft.DSC exited with $code)"
    }
    if ($code -ne 0 -and $code -ne $WingetUpdateNotApplicable) {
        Write-Host ('==> warning: winget {0} Microsoft.DSC exited with 0x{1:X8}; continuing' -f $verb, $code) -ForegroundColor Yellow
    }
    $output = @(& dsc.exe --version)
    Write-Host "==> $($output -join ' ')"
    $ErrorActionPreference = 'Continue'  # in 5.1, redirected stderr would otherwise throw
    $resources = @(& dsc.exe resource list Microsoft.WinGet/Package 2>$null)
    if (-not (($resources -join "`n") -match 'Microsoft\.WinGet/Package')) {
        throw ('dsc has no Microsoft.WinGet/Package resource; it comes with App Installer (winget), which ' +
            'is too old. Update "App Installer" from the Microsoft Store, then re-run.')
    }
}
# Updated here rather than in a DSC configuration: configure.ps1 runs in it, and the
# installer can't replace a running pwsh.
function Initialize-PowerShell {
    Write-Host '==> Ensuring PowerShell 7 is installed and up to date'
    $verb = if (Test-Path $Pwsh) { 'upgrade' } else { 'install' }
    # The MSI, not winget's default MSIX: the MSIX build is per-user and sandboxed (some file
    # system and registry locations are virtualized), which doesn't suit a setup tool.
    & winget.exe $verb --id Microsoft.PowerShell --exact --source winget --installer-type wix --scope machine `
        --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    if (-not (Test-Path $Pwsh)) {
        throw "PowerShell 7 isn't installed (winget $verb exited with $code)"
    }
    if ($code -ne 0 -and $code -ne $WingetUpdateNotApplicable) {
        # E.g. an open pwsh window blocking the upgrade; the installed version still works.
        Write-Host ('==> warning: winget {0} Microsoft.PowerShell exited with 0x{1:X8}; continuing' -f $verb, $code) -ForegroundColor Yellow
    }
    Write-Host "==> PowerShell $(& $Pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
}

# Scoop installs per user (to ~\scoop, or $env:SCOOP) and should be owned by the user, so it's
# installed in the unelevated section. The installer runs as a separate `powershell -File`, so
# its `exit` on failure ends only itself, with a meaningful exit code.
function Install-Scoop {
    $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $shim = Join-Path $scoopDir 'shims\scoop.ps1'
    # The installer's own test is whether a `scoop` command exists; if so it declines (with exit
    # code 0), so treat that as installed too.
    if ((Test-Path $shim) -or (Get-Command scoop -ErrorAction SilentlyContinue)) { return }

    Write-Host '==> Installing Scoop'
    $installer = Join-Path $env:TEMP "install-scoop-$PID.ps1"
    Invoke-WithRetry -Name 'Downloading the Scoop installer' {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://get.scoop.sh' -OutFile $installer
    }
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0 -or -not (Test-Path $shim)) {
        throw "Scoop's installer failed (exit code $code)"
    }
}

# Installs Scoop apps that aren't installed yet (it doesn't update installed ones). Runs Scoop as
# a separate `powershell -File` on its shim: right after Scoop's own install it isn't on this
# process's PATH yet, and scoop.ps1 can call `exit`.
function Install-ScoopApps {
    $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    foreach ($app in $ScoopApps) {
        if (Test-Path (Join-Path $scoopDir "apps\$app\current")) { continue }
        Write-Host "==> scoop install $app"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scoopDir 'shims\scoop.ps1') install $app
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $scoopDir "apps\$app\current"))) {
            throw "scoop install $app failed (exit code $LASTEXITCODE)"
        }
    }
}

# Unelevated section: per-user things that should be installed as the user, not as admin.
function Invoke-UnelevatedSection {
    Install-Scoop
    Install-ScoopApps
}

# Elevated section: everything else. Sets $script:exitCode to configure.ps1's exit code.
# (Not a return value: that would also capture all the programs' output, which must reach the
# console.)
function Invoke-ElevatedSection {
    Set-Utf8Console
    Initialize-Winget
    Update-Winget
    Initialize-VCRedist
    Initialize-Dsc
    Initialize-PowerShell

    Write-Host '==> Handing off to configure.ps1'
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'configure.ps1') @passthru
    $script:exitCode = $LASTEXITCODE
}

# Dot-sourcing (`. .\bootstrap.ps1`) only defines the functions, e.g. for testing.
if ($MyInvocation.InvocationName -eq '.') { return }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not $relaunched) {
    # The contract: the bootstrap is started unelevated, runs the unelevated section, then
    # relaunches itself elevated for the rest.
    if (Test-Admin) {
        Write-Host ('bootstrap must be started from a normal (non-elevated) prompt: it installs some things ' +
            'as you, then asks for elevation itself. (With UAC turned off, every prompt is elevated; ' +
            'turn UAC on to use this.)') -ForegroundColor Red
        exit 1
    }
    try {
        Invoke-UnelevatedSection
    } catch {
        Write-Host "bootstrap failed: $_" -ForegroundColor Red
        exit 1
    }
    Write-Host '==> Requesting elevation...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '--elevated-relaunch') +
        @($passthru | ForEach-Object { "`"$_`"" })
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

$exitCode = 1
try {
    if (-not (Test-Admin)) {
        throw '--elevated-relaunch is for the bootstrap''s own elevated relaunch; run bootstrap without it'
    }
    Invoke-ElevatedSection
    if ($exitCode -eq $RebootRequiredExitCode) {
        # "Shut down" with Fast Startup enabled doesn't finish pending component installs.
        Write-Host 'A reboot is required. Use Restart (not Shut down), then run bootstrap again to continue.' -ForegroundColor Yellow
    }
} catch {
    Write-Host "bootstrap failed: $_" -ForegroundColor Red
} finally {
    # The elevated window closes on exit; keep it open so the output can be read (unless the
    # output is going to a file, as when testing).
    if (-not [Console]::IsOutputRedirected) { Read-Host 'Press Enter to close' | Out-Null }
}
exit $exitCode
