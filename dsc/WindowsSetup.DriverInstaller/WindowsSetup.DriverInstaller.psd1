@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.DriverInstaller.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'c6e1a9d4-2f58-4b73-8e0c-91d3b7a5f264'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: a pinned vendor driver installer, run for devices with older drivers.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('DriverInstaller')
}
