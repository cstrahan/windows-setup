@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.WindowsCapability.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b71a62df-5929-4464-91e3-9b3acb067f99'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: a Windows capability (Feature on Demand).'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('WindowsCapability')
}