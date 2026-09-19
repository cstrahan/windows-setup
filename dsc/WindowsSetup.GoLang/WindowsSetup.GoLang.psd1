@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.GoLang.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '18f35d94-5568-4a32-b401-393555e47ac8'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: Go from the go.dev official Windows MSI.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('GoLang')
}