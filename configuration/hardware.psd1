# Hardware profiles: extra DSC configurations that configure.ps1 applies, before
# the workloads, on machines that match (every matching profile, in this order).
#
# Each profile has a Name, a Config file (relative to this directory), an optional Note printed
# when it applies, and match criteria. All criteria given must match; values are
# case-insensitive wildcards (PowerShell's -like).
#   Vendor, Model, Version  Win32_ComputerSystemProduct's Vendor, Name and Version
#   Device                  a hardware ID of any present device, e.g. ACPI\ELAN0412
#
# To see a machine's values:
#   Get-CimInstance Win32_ComputerSystemProduct | Format-List Vendor, Name, Version
#   Get-PnpDevice -PresentOnly | Select-Object FriendlyName, HardwareID
@{
    Profiles = @(
        @{
            Name    = 'System76 Gazelle (gaze16) drivers'
            Config  = 'hardware\system76-gaze16-drivers.dsc.yaml'
            Vendor  = 'System76'
            Version = 'gaze16-*'
        }
        @{
            Name    = 'System76 Gazelle (gaze16) with ELAN0412 touchpad'
            Config  = 'hardware\system76-gaze16.dsc.yaml'
            Note    = 'On Windows 10, touchpad changes take effect at the next sign-in.'
            Vendor  = 'System76'
            Version = 'gaze16-*'
            Device  = 'ACPI\ELAN0412'
        }
        @{
            Name    = 'NVIDIA GPU'
            Config  = 'hardware\nvidia.dsc.yaml'
            Device  = 'PCI\VEN_10DE&DEV_*'
        }
    )
}
