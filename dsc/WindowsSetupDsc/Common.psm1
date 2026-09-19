# Shared by WindowsSetupDsc's resources (see WindowsSetupDsc.psd1). Each resource module pulls
# this in with `using module .\Common.psm1`. winget configure runs these resources in its own
# embedded PowerShell 7 host.

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
