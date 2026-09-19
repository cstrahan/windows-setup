@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.PrecisionTouchpad.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '86c5fce5-8713-4a45-93b9-175829068592'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: per-user precision touchpad settings.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('PrecisionTouchpad')
}