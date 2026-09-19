@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.DriverPackage.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '4f3c8e2a-7b1d-4e59-9a06-2d8f5c1b7e43'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: device drivers from a vendor zip, installed with pnputil.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('DriverPackage')
}
