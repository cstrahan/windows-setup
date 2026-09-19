@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.Common.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '696ff952-eec5-40c7-b0d6-7f204695b722'
    Author               = 'Charles Strahan'
    Description          = 'Shared code for the WindowsSetup.* DSC resources.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @()
}