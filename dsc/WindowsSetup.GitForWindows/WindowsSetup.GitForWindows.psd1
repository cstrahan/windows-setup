@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.GitForWindows.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '03eb711a-c79d-42a8-83dc-ee2fcae765a7'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: Git for Windows via winget, with pinned installer choices.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('GitForWindows')
}