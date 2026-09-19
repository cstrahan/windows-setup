# Stage 1 bootstrap, in Windows PowerShell 5.1 (all a fresh Windows 10 has): elevate, make sure
# winget works and is current, install or update PowerShell 7, then hand off to configure.ps1
# (stage 2) in PowerShell 7. Safe to re-run; every step checks before acting.
#
# Any arguments are passed through to configure.ps1 (e.g. -SkipWsl, -Distro Debian).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RebootRequiredExitCode = 3010
$WingetUpdateNotApplicable = 0x8A15002B  # `winget upgrade`: already the latest version
$MinWingetVersion = [version] '1.6'  # `winget configure` went GA in 1.6
$Pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$relaunched = $args -contains '--elevated-relaunch'
$passthru = @($args | Where-Object { $_ -ne '--elevated-relaunch' })

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

# winget configure downloads the latest DSC modules from the PowerShell Gallery, and
# Microsoft.WinGet.DSC only loads in the PowerShell host of a matching winget: e.g. winget 1.9
# hosts PowerShell 7.2 (.NET 6), while current Microsoft.WinGet.DSC needs .NET 8.
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

# Updated here rather than in the winget configuration: configure.ps1 runs in it, and the
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

if (-not (Test-Admin)) {
    Write-Host '==> Requesting elevation...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '--elevated-relaunch') +
        @($passthru | ForEach-Object { "`"$_`"" })
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

$exitCode = 1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Initialize-Winget
    Update-Winget
    Initialize-PowerShell

    Write-Host '==> Handing off to configure.ps1'
    & $Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'configure.ps1') @passthru
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq $RebootRequiredExitCode) {
        # "Shut down" with Fast Startup enabled doesn't finish pending component installs.
        Write-Host 'A reboot is required. Use Restart (not Shut down), then run bootstrap again to continue.' -ForegroundColor Yellow
    }
} catch {
    Write-Host "bootstrap failed: $_" -ForegroundColor Red
} finally {
    # The elevated window closes on exit; keep it open so the output can be read.
    if ($relaunched) { Read-Host 'Press Enter to close' | Out-Null }
}
exit $exitCode
