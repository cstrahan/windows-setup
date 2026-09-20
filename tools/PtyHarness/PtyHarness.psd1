@{
    RootModule        = 'PtyHarness.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e57b2c09-6d14-4f83-b2a7-95c8e0f6d31b'
    Author            = 'Charles Strahan'
    Description       = 'Drive an interactive program through a pseudo console, rendered with libghostty-vt.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-PtyApp', 'Get-PtyApp', 'Get-PtyScreen', 'Get-PtyInfo', 'Send-PtyKeys',
                          'Send-PtyText', 'Send-PtyBytes', 'Wait-PtyText', 'Set-PtySize', 'Stop-PtyApp')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
