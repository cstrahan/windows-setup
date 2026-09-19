@{
    # DSC v3's PowerShell adapter only finds class-based resources in a module's root .psm1 (it
    # fails on nested modules), so each resource is its own single-file module.
    RootModule           = 'WindowsSetup.ScheduledTask.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a5a79bb2-46cf-4f20-b82c-6b67884ae8b8'
    Author               = 'Charles Strahan'
    Description          = 'DSC resource: an event-triggered scheduled task.'
    # '*', not @(): with an empty list, Get-Module -ListAvailable reports no DSC resources.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('ScheduledTask')
}