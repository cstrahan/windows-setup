@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.MiseTools.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'f3b7c1d8-5e64-4a29-9c07-2a1f8b6d4e05'
    Author               = 'Charles Strahan'
    Description          = "DSC resource: tools in mise's global config."
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('MiseTools')
}
