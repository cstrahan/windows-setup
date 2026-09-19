#Requires -Version 7.2
<#
.SYNOPSIS
Stage 2 of the windows-setup bootstrap, run by bootstrap.ps1 in PowerShell 7.

.DESCRIPTION
Applies, with DSC v3 (dsc.exe), any matching hardware profiles (configuration\hardware.psd1), then
the selected workloads (configuration\workloads.psd1), then sets up WSL 2 with uv and Ansible
inside it.

Every step checks current state before acting, so this is safe to re-run. Installing the WSL
platform needs a restart; then it exits with 3010, and bootstrap.ps1 registers a logon task that
continues setup (with -Resumed) after the restart.

.PARAMETER SkipDsc
Don't apply the DSC configurations (hardware profiles and workloads).

.PARAMETER Workloads
Apply exactly these workloads (plus what they require, and the Always ones) instead of
workloads.psd1's Enabled list, e.g. -Workloads go,rust.

.PARAMETER ExcludeWorkloads
Leave these workloads out of the selection, e.g. -ExcludeWorkloads remote-desktop,taskbar.

.PARAMETER SkipWsl
Don't set up WSL, or uv and Ansible inside it.

.PARAMETER Distro
The WSL distribution. Defaults to Ubuntu, which tracks the latest Ubuntu LTS.

.PARAMETER Resumed
Set by the logon task bootstrap.ps1 registers when WSL needs a restart: this run follows that
restart. If WSL still isn't active and no restart is pending, it stops with a diagnosis instead
of asking for another restart.
#>
[CmdletBinding()]
param(
    [Alias('SkipWinget')] [switch] $SkipDsc,
    [string[]] $Workloads,
    [string[]] $ExcludeWorkloads,
    [switch] $SkipWsl,
    [string] $Distro = 'Ubuntu',
    [switch] $Resumed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
# Extra configurations applied only on matching hardware.
$HardwareProfiles = Join-Path $Root 'configuration\hardware.psd1'
# Workloads: everything else, one configuration each.
$WorkloadList = Join-Path $Root 'configuration\workloads.psd1'
# Our own class-based DSC resources, one module each (WindowsSetup.*). dsc's PowerShell adapter
# finds them through PSModulePath, which dsc inherits from this process.
$DscModules = Join-Path $Root 'dsc'

$AnsibleCoreSpec = 'ansible-core>=2.19'
$AnsibleSpec = 'ansible>=12'  # the community collections, incl. ansible.windows
$RebootRequiredExitCode = 3010  # same meaning as msiexec's ERROR_SUCCESS_REBOOT_REQUIRED
$ScancodeMapKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
$CbsRebootPendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$WslFeatures = 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'
$LxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$VirtualizationHelp = ('Turn on virtualization (Intel VT-x / AMD-V, sometimes "SVM") in the BIOS/UEFI settings, or, ' +
    'in a virtual machine, expose nested virtualization to it.')
$WslProbeTimeout = 60  # seconds; a healthy `wsl --status` returns in well under this
# Commands that should be on PATH afterwards: bootstrap.ps1's Scoop, plus the applied workloads'
# Commands.
$ExpectedCommands = [System.Collections.Generic.List[string]] @('scoop')
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
# UTF-16LE (wsl.exe without WSL_UTF8) or UTF-8; -CaptureStdout collects only stdout, leaving
# stderr (progress, warnings) on the console. -InputText is sent to stdin with LF line endings.
# With -TimeoutSeconds the program is killed after that long; ExitCode is then $null.
# Returns [pscustomobject]@{ ExitCode; Output }.
function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $FilePath,
        [Parameter(Position = 1)] [string[]] $ArgumentList = @(),
        [switch] $Capture,
        [switch] $CaptureStdout,
        [string] $InputText,
        [int] $TimeoutSeconds = 0,
        [switch] $AllowFailure
    )
    $commandLine = (@($FilePath) + $ArgumentList) -join ' '
    if (-not $Capture -and -not $CaptureStdout) {
        Write-Host "  `$ $commandLine"
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $Capture -or $CaptureStdout
    $startInfo.RedirectStandardError = $Capture
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = [System.IO.MemoryStream]::new()
    $stderr = [System.IO.MemoryStream]::new()
    $copies = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    if ($startInfo.RedirectStandardOutput) { $copies.Add($process.StandardOutput.BaseStream.CopyToAsync($stdout)) }
    if ($startInfo.RedirectStandardError) { $copies.Add($process.StandardError.BaseStream.CopyToAsync($stderr)) }
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
    if ($copies.Count) {
        [System.Threading.Tasks.Task]::WaitAll($copies.ToArray())
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

# --- preflight and post-checks ---------------------------------------------------------

function Test-Kernel32Export([string] $Name) {
    if (-not ('WindowsSetup.Kernel32' -as [type])) {
        Add-Type -Namespace WindowsSetup -Name Kernel32 -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string name);
[DllImport("kernel32.dll", CharSet = CharSet.Ansi, BestFitMapping = false)] public static extern IntPtr GetProcAddress(IntPtr module, string name);
'@
    }
    $kernel32 = [WindowsSetup.Kernel32]::GetModuleHandleW('kernel32.dll')
    return [WindowsSetup.Kernel32]::GetProcAddress($kernel32, $Name) -ne [IntPtr]::Zero
}

# Logs the machine's state up front; diagnostics only, never fails the run. (Idea from
# microsoft/WindowsDeveloperConfig's preflight.ps1.)
function Write-Preflight {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $winget = (Invoke-Native winget.exe @('--version') -Capture -AllowFailure).Output.Trim()
        $free = [Math]::Round((Get-PSDrive C).Free / 1GB, 1)
        Write-Step ("Preflight: $($os.Caption) $($version.DisplayVersion) (build $($version.CurrentBuild).$($version.UBR)), " +
            "winget $winget, PowerShell $($PSVersionTable.PSVersion), C: $free GB free")
    } catch {
        Write-Step "Preflight: couldn't collect everything: $($_.Exception.Message)"
    }
    # WSL's Remote Desktop client (used by WSLg to show Linux GUI apps) imports GetTempPath2W,
    # which Windows 10 only gained in its March 2025 updates.
    if (-not (Test-Kernel32Export 'GetTempPath2W')) {
        Write-Step ('Warning: Windows is missing its March 2025 or later cumulative updates (kernel32 has no ' +
            'GetTempPath2W), so WSLg cannot display Linux GUI apps. Install the latest updates from Windows Update.')
    }
    if (-not $SkipWsl -and -not (Test-VirtualizationAvailable)) {
        Write-Step ("Warning: hardware virtualization isn't available, so WSL 2 won't run. $VirtualizationHelp")
    }
}

# Windows installers update PATH in the registry, not in running processes, so reload it before
# looking for what they installed. PSModulePath is left alone: PowerShell 7 builds its own.
# (From microsoft/WindowsDeveloperConfig's refresh-path.ps1.)
function Update-SessionPath {
    foreach ($name in 'Path', 'PATHEXT') {
        $entries = @([Environment]::GetEnvironmentVariable($name, 'Machine'), [Environment]::GetEnvironmentVariable($name, 'User')) -split ';' |
            Where-Object { $_ } | Select-Object -Unique
        Set-Item -Path "env:$name" -Value ($entries -join ';')
    }
}

# Post-condition for the DSC stage: what it installed should now be usable.
function Assert-ExpectedCommands {
    Update-SessionPath
    $missing = @($ExpectedCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing) {
        throw "installed, but not found on PATH: $($missing -join ', ')"
    }
    Write-Step "On PATH: $($ExpectedCommands -join ', ')"
}

# --- DSC configurations ----------------------------------------------------------------

# Makes our modules visible to dsc's PowerShell adapter, which dsc starts with this environment.
function Initialize-DscModulePath {
    if (-not (Get-Command dsc.exe -ErrorAction SilentlyContinue)) {
        throw 'dsc.exe (Microsoft.DSC) is not on PATH; bootstrap.ps1 installs it'
    }
    if (($env:PSModulePath -split ';') -notcontains $DscModules) {
        $env:PSModulePath = "$DscModules;$env:PSModulePath"
    }
}

# Flattens dsc's per-resource results (Microsoft.DSC/Group nests its members' results).
function Get-DscResults($Results) {
    foreach ($entry in @($Results)) {
        if ($entry.result.PSObject.Properties['results']) {
            Get-DscResults $entry.result.results
        } else {
            $entry
        }
    }
}

# One line per changed resource, then a count of the unchanged ones. PowerShellScript steps also
# show what their setScript printed.
function Write-DscReport($Report) {
    $unchanged = 0
    foreach ($entry in Get-DscResults $Report.results) {
        $changed = @($entry.result.PSObject.Properties['changedProperties'] ? $entry.result.changedProperties : @()) |
            Where-Object { $_ }
        if (-not $changed) { $unchanged++; continue }
        Write-Host "  changed: $($entry.name) ($($entry.type)): $($changed -join ', ')"
        $after = $entry.result.PSObject.Properties['afterState'] ? $entry.result.afterState : $null
        if ($entry.type -like '*/PowerShellScript' -and $after -and $after.PSObject.Properties['output']) {
            foreach ($line in @($after.output) | Where-Object { $_ }) { Write-Host "    $line" }
        }
    }
    Write-Host "  unchanged: $unchanged resource(s)"
    foreach ($message in @($Report.PSObject.Properties['messages'] ? $Report.messages : @()) | Where-Object { $_ }) {
        Write-Host "  $($message.level): $($message.resourceName): $($message.message)"
    }
}

# Applies one configuration document. dsc's traces, warnings and progress go to stderr, straight to
# the console; its JSON result (stdout) becomes the summary.
function Invoke-DscConfiguration([string] $Path) {
    Write-Step "Applying $([System.IO.Path]::GetRelativePath($Root, $Path))"
    $result = Invoke-Native dsc.exe @('config', 'set', '--file', $Path, '--output-format', 'json') -CaptureStdout -AllowFailure
    $report = $null
    if ($result.Output.Trim()) {
        try { $report = $result.Output | ConvertFrom-Json } catch { Write-Host $result.Output }
    }
    if ($report) { Write-DscReport $report }
    if ($result.ExitCode -ne 0 -or ($report -and $report.hadErrors)) {
        throw "dsc config set failed for $([System.IO.Path]::GetFileName($Path)) (exit code $($result.ExitCode)); see the errors above"
    }
}

# --- workloads -------------------------------------------------------------------------

# The workloads to apply: the Always ones, then Names, each after the ones it Requires
# (depth-first), without duplicates, and none of Exclude. Excluding an Always workload, or one a
# selected workload requires, is an error rather than a silently partial setup.
function Resolve-Workloads([hashtable] $Definitions, [string[]] $Names, [string[]] $Exclude = @()) {
    $known = { param([string] $Name)
        if (-not $Definitions.ContainsKey($Name)) {
            throw "unknown workload '$Name' (known: $(($Definitions.Keys | Sort-Object) -join ', '))"
        }
    }
    $excluded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Exclude) {
        & $known $name
        if ($Definitions[$name]['Always']) { throw "workload '$name' is always applied and can't be excluded" }
        [void] $excluded.Add($name)
    }
    $ordered = [System.Collections.Generic.List[string]]::new()
    $inProgress = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $visit = {
        param([string] $Name, [string[]] $Chain)
        $Name = $Name.ToLowerInvariant()
        if ($ordered.Contains($Name)) { return }
        & $known $Name
        if ($excluded.Contains($Name)) {
            if ($Chain) { throw "workload '$($Chain[-1])' requires '$Name', which is excluded; exclude '$($Chain[-1])' too, or keep '$Name'" }
            return
        }
        if (-not $inProgress.Add($Name)) { throw "workload cycle: $((@($Chain) + $Name) -join ' -> ')" }
        foreach ($required in @($Definitions[$Name]['Requires'])) { & $visit $required (@($Chain) + $Name) }
        $ordered.Add($Name)
    }
    $always = @($Definitions.Keys | Where-Object { $Definitions[$_]['Always'] } | Sort-Object)
    foreach ($name in @($always) + @($Names)) { & $visit $name @() }
    return , $ordered.ToArray()
}

# From bootstrap.cmd, -Workloads a,b arrives as one argument, "a,b".
function Split-NameList([string[]] $Names) {
    return @($Names -split ',' | ForEach-Object Trim | Where-Object { $_ })
}

function Invoke-WorkloadConfiguration {
    $list = Import-PowerShellDataFile -Path $WorkloadList
    $names = if ($null -ne $Workloads) { Split-NameList $Workloads } else { @($list.Enabled) }
    $ordered = Resolve-Workloads $list.Workloads $names (Split-NameList $ExcludeWorkloads)
    Write-Step "Workloads: $($ordered -join ', ')"
    foreach ($name in $ordered) {
        Invoke-DscConfiguration (Join-Path (Split-Path $WorkloadList) "workloads\$name.dsc.yaml")
        foreach ($command in @($list.Workloads[$name]['Commands'])) {
            if ($command -and -not $ExpectedCommands.Contains($command)) { $ExpectedCommands.Add($command) }
        }
    }
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
            Invoke-DscConfiguration (Join-Path (Split-Path $HardwareProfiles) $hardwareProfile.Config)
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

# The Hyper-V Host Compute Service only exists once the Virtual Machine Platform is actually
# active, whereas the features can report "Enabled" while their install still awaits a restart.
# (Signal from microsoft/WindowsDeveloperConfig's wsl.ps1.)
function Test-WslPlatformActive {
    return (Test-WslFeaturesEnabled) -and $null -ne (Get-CimInstance Win32_Service -Filter "Name='vmcompute'")
}

# Once a hypervisor is running (as with WSL 2 active), Win32_Processor reports the
# virtualization extensions as off, so either signal counts.
function Test-VirtualizationAvailable {
    if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) { return $true }
    return [bool] @(Get-CimInstance Win32_Processor | Where-Object VirtualizationFirmwareEnabled)
}

# Installs the WSL platform (optional components plus the Store WSL package), which needs a
# restart. After the restart bootstrap.ps1's logon task resumes with -Resumed; if the platform is
# still inactive then with nothing pending, another restart wouldn't help, so this stops instead.
function Install-WslPlatform([string] $Reason) {
    if (Test-Path $CbsRebootPendingKey) {
        # E.g. "Shut down" with Fast Startup, or signing out, instead of Restart.
        throw [RebootRequiredException]::new("$Reason; Windows must restart to finish installing them")
    }
    if ($Resumed) {
        $diagnosis = if (Test-VirtualizationAvailable) {
            'Virtualization is available, so the likely cause is that WSL could not be downloaded; check the network and run bootstrap again.'
        } else {
            "Hardware virtualization isn't available. $VirtualizationHelp Then run bootstrap again."
        }
        throw "WSL still isn't active after restarting, and no restart is pending, so another restart won't help. $diagnosis"
    }
    $result = Invoke-Native wsl.exe @('--install', '--no-distribution') -AllowFailure
    Write-Step "wsl --install --no-distribution exited with $($result.ExitCode)"
    throw [RebootRequiredException]::new("$Reason; WSL's components were installed")
}

# The inbox wsl.exe doesn't support --version; the Store WSL package does. --web-download gets
# the same package when the Microsoft Store route fails.
function Update-WslPackage {
    if ((Invoke-Native wsl.exe @('--version') -Capture -AllowFailure).ExitCode -eq 0) { return }
    Write-Step 'Updating WSL to the current package'
    foreach ($arguments in @(@('--update'), @('--update', '--web-download'))) {
        Invoke-Native wsl.exe $arguments -AllowFailure | Out-Null
        if ((Invoke-Native wsl.exe @('--version') -Capture -AllowFailure).ExitCode -eq 0) { return }
    }
    throw 'WSL could not be updated (wsl --update, with and without --web-download)'
}

# Skips WSL's "Welcome to WSL" window, which otherwise opens after installing a distro.
function Set-WslWelcomeSeen {
    $item = Get-ItemProperty -Path $LxssKey -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties['OOBEComplete'] -and $item.OOBEComplete -eq 1) { return }
    New-Item -Path $LxssKey -Force | Out-Null
    Set-ItemProperty -Path $LxssKey -Name OOBEComplete -Value 1 -Type DWord
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
        Install-WslPlatform 'WSL reports its optional components missing'
    }
    Write-Step 'WSL is unresponsive; restarting its services'
    Invoke-Native wsl.exe @('--shutdown') -Capture -TimeoutSeconds $WslProbeTimeout -AllowFailure | Out-Null
    Restart-WslServices
    if (-not (Get-WslStatus).Ok) {
        throw 'WSL is still unresponsive after restarting its services; reboot and re-run (see Troubleshooting in README.md)'
    }
}

# `wsl --list` can lag behind a just-finished install.
function Wait-WslDistro([string] $Name) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if ($Name -in (Get-WslDistros)) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Initialize-Wsl([string] $Name) {
    Write-Step 'Ensuring WSL 2 is installed'
    if (-not (Test-WslPlatformActive)) {
        Install-WslPlatform 'the WSL platform is not active'
    }
    Update-WslPackage
    Assert-WslResponsive
    Invoke-Native wsl.exe @('--set-default-version', '2') | Out-Null

    if ($Name -notin (Get-WslDistros)) {
        Set-WslWelcomeSeen
        Write-Step "Installing $Name. Create your Linux user when prompted; if you land in a Linux shell afterwards, type ``exit`` to continue."
        Invoke-Native wsl.exe @('--install', '--distribution', $Name) -AllowFailure | Out-Null
        if (-not (Wait-WslDistro $Name)) {
            Write-Step "$Name didn't install from the Microsoft Store; downloading it from the web instead"
            Invoke-Native wsl.exe @('--install', '--distribution', $Name, '--web-download') -AllowFailure | Out-Null
            if (-not (Wait-WslDistro $Name)) {
                throw "$Name is still not registered with WSL"
            }
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

# Two runs at once would race on winget, dsc and installers. The mutex is held until this process
# exits (an abandoned one, from a killed run, counts as acquired). (Idea from
# microsoft/WindowsDeveloperConfig's dev-config.ps1.)
function Enter-SingleInstance {
    $script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Global\windows-setup-configure')
    try {
        $acquired = $script:InstanceMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        throw 'another windows-setup run is already in progress; wait for it to finish'
    }
}

function Invoke-Configure {
    if (-not (Test-Administrator)) {
        throw 'must run elevated (use bootstrap.cmd, which elevates for you)'
    }
    Enter-SingleInstance
    Write-Preflight
    if (-not $SkipDsc) {
        Initialize-DscModulePath
        $scancodeMap = Get-ScancodeMap
        Invoke-HardwareConfiguration
        Invoke-WorkloadConfiguration
        if ((Get-ScancodeMap) -ne $scancodeMap) {
            Write-Step 'Note: the keyboard remapping (Scancode Map) changed; it takes effect after a restart.'
        }
        Assert-ExpectedCommands
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
