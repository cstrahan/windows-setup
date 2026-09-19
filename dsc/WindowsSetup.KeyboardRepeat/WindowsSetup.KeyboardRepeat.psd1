@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.KeyboardRepeat.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '65aa7950-7bb5-4e45-b0c9-4a1c145e54af'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: per-user keyboard repeat delay and rate.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('KeyboardRepeat')
}