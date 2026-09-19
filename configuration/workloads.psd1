# Workloads: optional toolchains, one DSC v3 configuration each in workloads\<name>.dsc.yaml
# (mostly from microsoft/WindowsDeveloperConfig's src/Workloads). configure.ps1 applies the
# Enabled ones after windows.dsc.yaml, each after the workloads it Requires. -Workloads on the
# command line overrides Enabled for one run.
#
#   Requires  other workloads to apply first (e.g. Visual Studio before adding components to it)
#   Commands  commands that should be on PATH afterwards; checked at the end of the run
@{
    Enabled   = @('dotnet', 'java', 'python', 'typescript', 'rust', 'powershell', 'winforms', 'winui')

    Workloads = @{
        visualstudio = @{ Requires = @(); Commands = @() }
        dotnet       = @{ Requires = @(); Commands = @('dotnet') }
        java         = @{ Requires = @(); Commands = @('java') }
        python       = @{ Requires = @(); Commands = @('py') }
        typescript   = @{ Requires = @(); Commands = @('node', 'npm', 'tsc') }
        rust         = @{ Requires = @('visualstudio'); Commands = @('rustup', 'cargo', 'rustc') }
        powershell   = @{ Requires = @(); Commands = @() }
        winforms     = @{ Requires = @('dotnet', 'visualstudio'); Commands = @('dotnet') }
        winui        = @{ Requires = @('dotnet', 'visualstudio'); Commands = @('dotnet') }
    }
}
