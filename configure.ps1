#Requires -Version 7.2
<#
.SYNOPSIS
Stage 2 of the windows-setup bootstrap, run by bootstrap.ps1 in PowerShell 7.

.DESCRIPTION
Applies configuration\windows.dsc.yaml with winget configure, then any matching hardware
profiles (configuration\hardware.psd1), then sets up WSL 2 with uv and Ansible inside it.

Every step checks current state before acting, so this is safe to re-run. Some steps (enabling
WSL) need a restart; then it exits with 3010 and should be run again after restarting.

.PARAMETER SkipWinget
Don't apply the winget configuration or hardware profiles.

.PARAMETER SkipWsl
Don't set up WSL, or uv and Ansible inside it.

.PARAMETER Distro
The WSL distribution. Defaults to Ubuntu, which tracks the latest Ubuntu LTS.
#>
[CmdletBinding()]
param(
    [switch] $SkipWinget,
    [switch] $SkipWsl,
    [string] $Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$WingetConfig = Join-Path $Root 'configuration\windows.dsc.yaml'
# Extra winget configurations applied only on matching hardware.
$HardwareProfiles = Join-Path $Root 'configuration\hardware.psd1'
# Our own DSC modules (WindowsSetupDsc). Passed as winget's --module-path, so modules winget
# downloads from the PowerShell Gallery also land here (they're git-ignored).
$DscModules = Join-Path $Root 'dsc'

$AnsibleCoreSpec = 'ansible-core>=2.19'
$AnsibleSpec = 'ansible>=12'  # the community collections, incl. ansible.windows
$RebootRequiredExitCode = 3010  # same meaning as msiexec's ERROR_SUCCESS_REBOOT_REQUIRED
$ScancodeMapKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
$CbsRebootPendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$WslFeatures = 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'
$WslProbeTimeout = 60  # seconds; a healthy `wsl --status` returns in well under this
$WslResetTimeout = 120

# Ask wsl.exe for UTF-8 output instead of UTF-16LE (older builds ignore it; see Invoke-Native).
$env:WSL_UTF8 = '1'

class RebootRequiredException : System.Exception {
    RebootRequiredException([string] $Message) : base($Message) { }
}

function Write-Step([string] $Message) {
    Write-Host "==> $Message"
}

# Runs a program. By default its output goes straight to the console (so interactive prompts
# work) and a non-zero exit code throws. -Capture collects stdout and stderr instead, decoding
# UTF-16LE (wsl.exe without WSL_UTF8) or UTF-8. -InputText is sent to stdin with LF line endings.
# With -TimeoutSeconds the program is killed after that long; ExitCode is then $null.
# Returns [pscustomobject]@{ ExitCode; Output }.
function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $FilePath,
        [Parameter(Position = 1)] [string[]] $ArgumentList = @(),
        [switch] $Capture,
        [string] $InputText,
        [int] $TimeoutSeconds = 0,
        [switch] $AllowFailure
    )
    $commandLine = (@($FilePath) + $ArgumentList) -join ' '
    if (-not $Capture) {
        Write-Host "  `$ $commandLine"
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $Capture
    $startInfo.RedirectStandardError = $Capture
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($Capture) {
        $stdout = [System.IO.MemoryStream]::new()
        $stderr = [System.IO.MemoryStream]::new()
        $copies = [System.Threading.Tasks.Task[]] @(
            $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $process.StandardError.BaseStream.CopyToAsync($stderr)
        )
    }
    if ($startInfo.RedirectStandardInput) {
        # (Not inline: inside a method call's parentheses, -replace's comma separates arguments.)
        $text = $InputText -replace "`r`n", "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    }
    if (-not $process.WaitForExit($(if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { -1 }))) {
        $process.Kill($true)
        if (-not $AllowFailure) { throw "$commandLine didn't finish within ${TimeoutSeconds}s" }
        return [pscustomobject]@{ ExitCode = $null; Output = '' }
    }
    $process.WaitForExit()  # also waits for the output to be fully read
    $output = ''
    if ($Capture) {
        [System.Threading.Tasks.Task]::WaitAll($copies)
        $output = (ConvertFrom-NativeOutput $stdout.ToArray()) + (ConvertFrom-NativeOutput $stderr.ToArray())
    }
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "$commandLine exited with $($process.ExitCode)$(if ($output) { ": $($output.Trim())" })"
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
}

function ConvertFrom-NativeOutput([byte[]] $Bytes) {
    if ([Array]::IndexOf($Bytes, [byte] 0) -ge 0) {
        return [System.Text.Encoding]::Unicode.GetString($Bytes)  # UTF-16LE
    }
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Test-Administrator {
    $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- winget configuration --------------------------------------------------------------

function Invoke-WingetConfiguration([string] $Path) {
    Write-Step "Applying winget configuration $([System.IO.Path]::GetRelativePath($Root, $Path))"
    # PSModulePath isn't inherited by winget's elevated configuration server; --module-path is.
    Invoke-Native winget.exe @('configure', '--file', $Path, '--module-path', $DscModules,
        '--accept-configuration-agreements', '--disable-interactivity') | Out-Null
}

# Windows' keyboard remapping, as hex ('' if unset). It only takes effect after a restart.
function Get-ScancodeMap {
    $value = Get-ItemProperty -Path $ScancodeMapKey -Name 'Scancode Map' -ErrorAction SilentlyContinue
    if (-not $value) { return '' }
    return [Convert]::ToHexString($value.'Scancode Map')
}

# --- hardware profiles -----------------------------------------------------------------

# Machine identity (Win32_ComputerSystemProduct) and the hardware IDs of present devices.
function Get-Hardware {
    $product = Get-CimInstance Win32_ComputerSystemProduct
    return [pscustomobject]@{
        Vendor  = $product.Vendor
        Model   = $product.Name
        Version = $product.Version
        Devices = @(Get-PnpDevice -PresentOnly | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
    }
}

# All criteria the profile gives must match; values are case-insensitive wildcards (-like).
function Test-HardwareProfile([hashtable] $HardwareProfile, $Hardware) {
    foreach ($key in 'Vendor', 'Model', 'Version') {
        if ($HardwareProfile.ContainsKey($key) -and -not ("$($Hardware.$key)" -like $HardwareProfile[$key])) {
            return $false
        }
    }
    if ($HardwareProfile.ContainsKey('Device') -and -not @($Hardware.Devices -like $HardwareProfile['Device'])) {
        return $false
    }
    return $true
}

function Invoke-HardwareConfiguration {
    $profiles = (Import-PowerShellDataFile -Path $HardwareProfiles).Profiles
    $hardware = Get-Hardware
    Write-Step "Hardware: $($hardware.Vendor) $($hardware.Model) ($($hardware.Version))"
    foreach ($hardwareProfile in $profiles) {
        if (Test-HardwareProfile $hardwareProfile $hardware) {
            Write-Step "Hardware profile matches: $($hardwareProfile.Name)"
            Invoke-WingetConfiguration (Join-Path (Split-Path $HardwareProfiles) $hardwareProfile.Config)
            if ($hardwareProfile.ContainsKey('Note')) {
                Write-Step "Note: $($hardwareProfile.Note)"
            }
        } else {
            Write-Step "Hardware profile doesn't match, skipping: $($hardwareProfile.Name)"
        }
    }
}

# --- WSL -------------------------------------------------------------------------------

# Via CIM rather than Get-WindowsOptionalFeature: Windows 10's Dism module fails under
# PowerShell 7 ("Class not registered"). InstallState 1 = enabled.
function Test-WslFeaturesEnabled {
    foreach ($name in $WslFeatures) {
        $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='$name'"
        if (-not $feature -or $feature.InstallState -ne 1) {
            return $false
        }
    }
    return $true
}

function Get-WslDistros {
    $result = Invoke-Native wsl.exe @('--list', '--quiet') -Capture -AllowFailure
    if ($result.ExitCode -ne 0) {  # also non-zero when no distros are installed
        return @()
    }
    return @($result.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WslDistroVersion([string] $Name) {
    $result = Invoke-Native wsl.exe @('--list', '--verbose') -Capture
    foreach ($line in ($result.Output -split "`r?`n" | Select-Object -Skip 1)) {
        $fields = -split ($line -replace '\*', ' ')
        if ($fields.Count -ge 3 -and $fields[0] -eq $Name) {
            return [int] $fields[-1]
        }
    }
    return $null
}

# Runs `wsl --status` with a timeout; returns Ok and Output.
function Get-WslStatus {
    $result = Invoke-Native wsl.exe @('--status') -Capture -TimeoutSeconds $WslProbeTimeout -AllowFailure
    if ($null -eq $result.ExitCode) {
        Write-Step "``wsl --status`` did not respond within ${WslProbeTimeout}s"
        return [pscustomobject]@{ Ok = $false; Output = '' }
    }
    if ($result.ExitCode -ne 0) {
        Write-Step "``wsl --status`` failed ($($result.ExitCode)): $($result.Output.Trim())"
    }
    return [pscustomobject]@{ Ok = $result.ExitCode -eq 0; Output = $result.Output }
}

# Force-restarts the WSL services: WSLService (Store WSL) and LxssManager (the optional
# component). A hung service is killed outright, but only if it has its svchost to itself.
# Nothing here blocks on a service, so a wedged one can't hang the script.
function Restart-WslServices {
    $deadline = (Get-Date).AddSeconds($WslResetTimeout)
    foreach ($name in 'WSLService', 'LxssManager') {
        $service = Get-CimInstance Win32_Service -Filter "Name='$name'"
        if (-not $service -or $service.ProcessId -eq 0) { continue }
        $shared = @(Get-CimInstance Win32_Service -Filter "ProcessId=$($service.ProcessId)").Count
        if ($shared -eq 1) {
            Stop-Process -Id $service.ProcessId -Force -ErrorAction SilentlyContinue
        } else {
            Stop-Service -Name $name -Force -NoWait -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-Service WSLService -ErrorAction SilentlyContinue)) { return }
    while ((Get-Service WSLService).Status -notin 'Stopped', 'Running' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    Invoke-Native sc.exe @('start', 'WSLService') -Capture -AllowFailure | Out-Null  # returns immediately
    while ((Get-Service WSLService).Status -ne 'Running' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
}

# Guards against a hung/crashed WSL service (e.g. 0x80080005 "Server execution failed").
function Assert-WslResponsive {
    $status = Get-WslStatus
    if ($status.Ok) { return }
    if ($status.Output -match 'WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED') {
        # The features can report "Enabled" while their installation still awaits a restart.
        if (Test-Path $CbsRebootPendingKey) {
            throw [RebootRequiredException]::new('WSL components are enabled but Windows must restart to finish installing them')
        }
        Invoke-Native wsl.exe @('--install', '--no-distribution') -AllowFailure | Out-Null
        throw [RebootRequiredException]::new('WSL optional components were (re)installed')
    }
    Write-Step 'WSL is unresponsive; restarting its services'
    Invoke-Native wsl.exe @('--shutdown') -Capture -TimeoutSeconds $WslProbeTimeout -AllowFailure | Out-Null
    Restart-WslServices
    if (-not (Get-WslStatus).Ok) {
        throw 'WSL is still unresponsive after restarting its services; reboot and re-run (see Troubleshooting in README.md)'
    }
}

function Initialize-Wsl([string] $Name) {
    Write-Step 'Ensuring WSL 2 is installed'
    if (-not (Test-WslFeaturesEnabled)) {
        # Enables the optional components and installs/updates the Store WSL package.
        $result = Invoke-Native wsl.exe @('--install', '--no-distribution') -AllowFailure
        Write-Step "wsl --install exited with $($result.ExitCode)"
        throw [RebootRequiredException]::new('WSL optional components were enabled')
    }
    # The Store-delivered WSL supports --version; the inbox wsl.exe does not.
    if ((Invoke-Native wsl.exe @('--version') -Capture -AllowFailure).ExitCode -ne 0) {
        Invoke-Native wsl.exe @('--update') | Out-Null
    }

    Assert-WslResponsive
    Invoke-Native wsl.exe @('--set-default-version', '2') | Out-Null

    if ($Name -notin (Get-WslDistros)) {
        Write-Step "Installing $Name. Create your Linux user when prompted; if you land in a Linux shell afterwards, type ``exit`` to continue."
        Invoke-Native wsl.exe @('--install', '--distribution', $Name) | Out-Null
        if ($Name -notin (Get-WslDistros)) {
            throw "$Name is still not registered with WSL"
        }
    }
    if ((Get-WslDistroVersion $Name) -ne 2) {
        Invoke-Native wsl.exe @('--set-version', $Name, '2') | Out-Null
    }
}

function Install-WslAnsible([string] $Name) {
    Write-Step "Ensuring uv and Ansible are installed in $Name"
    $script = @"
set -euo pipefail
export PATH="`$HOME/.local/bin:`$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
uv tool install '$AnsibleCoreSpec' --with '$AnsibleSpec'
ansible --version
"@
    # Fed over stdin to avoid Windows -> WSL command-line quoting issues.
    Invoke-Native wsl.exe @('--distribution', $Name, '--cd', '~', '--exec', 'bash', '-s') -InputText $script | Out-Null
}

# --- main ------------------------------------------------------------------------------

function Invoke-Configure {
    if (-not (Test-Administrator)) {
        throw 'must run elevated (use bootstrap.cmd, which elevates for you)'
    }
    if (-not $SkipWinget) {
        $scancodeMap = Get-ScancodeMap
        Invoke-WingetConfiguration $WingetConfig
        if ((Get-ScancodeMap) -ne $scancodeMap) {
            Write-Step 'Note: the keyboard remapping (Scancode Map) changed; it takes effect after a restart.'
        }
        Invoke-HardwareConfiguration
    }
    if (-not $SkipWsl) {
        Initialize-Wsl $Distro
        Install-WslAnsible $Distro
    }
    Write-Step 'Done'
}

# Dot-sourcing (`. .\configure.ps1`) only defines the functions, e.g. for testing.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Invoke-Configure
    exit 0
} catch [RebootRequiredException] {
    Write-Step "Reboot required ($($_.Exception.Message))"
    exit $RebootRequiredExitCode
} catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
