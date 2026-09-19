# MiseTools: tools in mise's global config (~\.config\mise\config.toml), installed at `latest`.
# Several workloads want their own tools there, so each declares its own set; mise's config is
# shared, and tools other sets (or the user) added are left alone.

# Installers update PATH in the registry, not in running processes.
function Update-PathFromRegistry {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User') |
        Where-Object { $_ }) -join ';'
}

# Tool -> installed?, from mise's global config only (not the whole registry).
function Get-MiseGlobalTools {
    # Captured, not emitted: the adapter uses stdout.
    $output = @(& mise ls --global --json 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "mise ls --global failed (exit code $LASTEXITCODE): $(($output | Select-Object -Last 5) -join ' ')"
    }
    $installed = @{}
    $listed = ($output -join "`n") | ConvertFrom-Json -AsHashtable
    foreach ($tool in $listed.Keys) {
        $installed[$tool] = [bool] @($listed[$tool] | Where-Object { $_['installed'] })
    }
    return $installed
}

# Ensures each tool is in mise's global config and installed.
[DscResource()]
class MiseTools {
    # A label for this set of tools, e.g. the workload's name.
    [DscProperty(Key)]
    [string] $Name

    # mise tool names, e.g. fzf, ripgrep. Installed as <tool>@latest.
    [DscProperty(Mandatory)]
    [string[]] $Tools

    [DscProperty(NotConfigurable)]
    [string[]] $MissingTools

    [string[]] GetMissing() {
        Update-PathFromRegistry
        if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
            throw 'mise is not on PATH (bootstrap.ps1 installs it with Scoop)'
        }
        $installed = Get-MiseGlobalTools
        return @($this.Tools | Where-Object { -not $installed[$_] })
    }

    [MiseTools] Get() {
        $current = [MiseTools]::new()
        $current.Name = $this.Name
        $current.Tools = $this.Tools
        $current.MissingTools = $this.GetMissing()
        return $current
    }

    [bool] Test() {
        return -not $this.GetMissing()
    }

    [void] Set() {
        foreach ($tool in $this.GetMissing()) {  # empty when already in the desired state
            $output = @(& mise use --global "$tool@latest" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "mise use --global $tool@latest failed (exit code $LASTEXITCODE): $(($output | Select-Object -Last 5) -join ' ')"
            }
        }
        $still = $this.GetMissing()
        if ($still) {
            throw "mise didn't install: $($still -join ', ')"
        }
    }
}
