# Shared by the WindowsSetup.* DSC resource modules, which load it with
# `using module WindowsSetup.Common`. DSC v3 runs them through its PowerShell adapter
# (Microsoft.Adapter/PowerShell), in the installed PowerShell 7.

enum Ensure {
    Absent
    Present
}

# SystemParametersInfoW, with pvParam as a struct buffer, a UINT out-parameter (SPI_GET* for
# numbers), or unused (SPI_SET* that take their value in uiParam).
function Initialize-SpiInterop {
    if (-not ('WindowsSetupDsc.NativeMethods' -as [type])) {
        Add-Type -Namespace WindowsSetupDsc -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, byte[] pvParam, uint fWinIni);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);
'@
    }
}
