@{
    RootModule           = 'WindowsSetupDsc.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7ed3e97c-bf79-4d0d-88fd-c9546c10a086'
    Author               = 'Charles Strahan'
    Description          = 'Local DSC resources for windows-setup, for gaps in the PSGallery modules under winget configure.'
    # Get-DscResource (and so winget) only finds class-based resources that
    # `Get-Module -ListAvailable` lists under ExportedDscResources. In winget's PowerShell 7.2
    # host that list comes back empty if FunctionsToExport is @(), so it must be '*'. Under
    # Windows PowerShell 5.1, PowerShellVersion/CompatiblePSEditions also emptied it; leave them out.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('WindowsCapability', 'GitForWindows', 'GoLang', 'PrecisionTouchpad')
}
