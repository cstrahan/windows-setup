@{
    RootModule        = 'ConsoleHarness.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c4e2f19-8a63-4d05-b1c8-3e97f5a2d604'
    Author            = 'Charles Strahan'
    Description       = 'Drive and read an interactive console app (fzf, Neovim, prompts) for testing.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-ConsoleApp', 'Get-ConsoleScreen', 'Send-ConsoleKeys', 'Send-ConsoleText', 'Wait-ConsoleText', 'Stop-ConsoleApp')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
