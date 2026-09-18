# Stage 1 bootstrap: elevate, make sure winget and uv are available, then hand off to
# configure.py (stage 2). Safe to re-run; every step checks before acting.
#
# Any arguments are passed through to configure.py (e.g. --skip-wsl, --distro Debian).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RebootRequiredExitCode = 3010
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

function Initialize-Uv {
    $uvBin = Join-Path $env:USERPROFILE '.local\bin'
    if (-not (Get-Command uv.exe -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $uvBin 'uv.exe'))) {
            Write-Host '==> Installing uv...'
            # Run in a child process: the installer may call `exit`, which would end this script.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
                "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://astral.sh/uv/install.ps1 | iex"
            if ($LASTEXITCODE -ne 0) { throw "uv installer failed (exit code $LASTEXITCODE)" }
        }
        # The installer updates the user PATH for future sessions; patch this one too.
        $env:Path = "$uvBin;$env:Path"
    }
    & uv.exe --version
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
    Initialize-Uv

    Write-Host '==> Handing off to configure.py'
    & uv.exe run --script (Join-Path $PSScriptRoot 'configure.py') @passthru
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
