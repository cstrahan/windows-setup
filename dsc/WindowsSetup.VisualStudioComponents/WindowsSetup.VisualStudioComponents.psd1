@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.VisualStudioComponents.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6addeee4-f9b2-4d27-9dfe-69c7305fe87d'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: workloads/components added to the installed Visual Studio.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('VisualStudioComponents')
}