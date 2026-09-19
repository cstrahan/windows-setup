@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.NvidiaDriver.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '8d2b6f41-3c7e-4a95-b1e0-5f9a2c7d4e18'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: the latest NVIDIA display driver, via NVIDIA''s driver lookup.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('NvidiaDriver')
}
