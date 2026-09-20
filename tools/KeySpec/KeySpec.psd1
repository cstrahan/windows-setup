@{
    RootModule        = 'KeySpec.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b0a4d6f2-19c7-4e8a-9d35-6f2c81be47a0'
    Author            = 'Charles Strahan'
    Description       = "Parses AutoHotkey-style key and mouse specifications into input events."
    PowerShellVersion = '5.1'
    FunctionsToExport = @('ConvertFrom-KeySpec')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
