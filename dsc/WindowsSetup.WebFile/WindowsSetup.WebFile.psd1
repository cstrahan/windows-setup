@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.WebFile.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '4c9e7a31-2b68-41d5-8f0a-7d53e6c1b924'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: a file downloaded with a pinned hash, optionally taken out of a zip.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('WebFile')
}
