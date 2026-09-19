# VisualStudioComponents: workloads/components added to the installed Visual Studio (installed
# separately, e.g. with Microsoft.WinGet/Package). Several workload configurations can each add
# what they need. Ids are listed at
# https://learn.microsoft.com/visualstudio/install/workload-component-id-vs-community

$script:VSInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'

# The latest Visual Studio's install path, but only if it has all $Components (vswhere's
# -requires means all of them); $null otherwise.
function Get-VisualStudioWith([string[]] $Components) {
    $vswhere = Join-Path $script:VSInstaller 'vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        return $null
    }
    $vswhereArgs = @('-latest', '-products', '*', '-property', 'installationPath')
    if ($Components) { $vswhereArgs += @('-requires') + $Components }
    $path = & $vswhere @vswhereArgs | Select-Object -First 1
    if ($path) { return "$path".Trim() } else { return $null }
}

[DscResource()]
class VisualStudioComponents {
    # A label for this set of components, e.g. the workload that needs them.
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Components

    # Also add each workload's recommended components (the installer's --includeRecommended).
    [DscProperty()]
    [bool] $IncludeRecommended = $true

    [DscProperty(NotConfigurable)]
    [string] $InstallationPath

    [VisualStudioComponents] Get() {
        $current = [VisualStudioComponents]::new()
        $current.Name = $this.Name
        $current.Components = $this.Components
        $current.IncludeRecommended = $this.IncludeRecommended
        $current.InstallationPath = Get-VisualStudioWith $this.Components
        return $current
    }

    [bool] Test() {
        return [bool] (Get-VisualStudioWith $this.Components)
    }

    [void] Set() {
        if ($this.Test()) { return }  # DSC v3 calls Set() without testing first
        $installPath = Get-VisualStudioWith @()
        if (-not $installPath) {
            throw 'Visual Studio is not installed; install it before adding components.'
        }
        # No --wait: that's the vs_<edition>.exe bootstrapper's option, and the installed setup.exe
        # rejects it (exit code 87). setup.exe itself runs until the operation is done.
        $setupArgs = @('modify', '--installPath', "`"$installPath`"", '--quiet', '--norestart')
        foreach ($component in $this.Components) { $setupArgs += @('--add', $component) }
        if ($this.IncludeRecommended) { $setupArgs += '--includeRecommended' }
        # Start-Process, not &: output must not reach stdout, which DSC's adapter uses.
        $process = Start-Process -FilePath (Join-Path $script:VSInstaller 'setup.exe') -ArgumentList $setupArgs -Wait -PassThru
        if ($process.ExitCode -eq 3010) {
            Write-Warning 'Visual Studio needs a restart to finish adding components.'
        } elseif ($process.ExitCode -ne 0) {
            throw "Visual Studio Installer (setup.exe modify) failed with exit code $($process.ExitCode); its logs are in %TEMP%\dd_*.log."
        }
        if (-not $this.Test()) {
            throw "Visual Studio Installer (setup.exe modify) exited with $($process.ExitCode), but these still aren't all installed: $($this.Components -join ', '). The installer silently ignores IDs it doesn't know, so check them against the catalog (C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<id>\catalog.json); its logs are in %TEMP%\dd_*.log."
        }
    }
}
