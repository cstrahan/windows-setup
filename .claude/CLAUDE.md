# Notes for Claude

See README.md for what the project does. These notes cover testing it from a Claude session.

## Layout

- `bootstrap.cmd` → `bootstrap.ps1` (stage 1, Windows PowerShell 5.1): self-elevates, registers
  and upgrades winget, installs/upgrades PowerShell 7 (the MSI), then runs `configure.ps1` with
  `C:\Program Files\PowerShell\7\pwsh.exe` (full path: PATH isn't refreshed in that session).
- `configure.ps1` (stage 2, PowerShell 7): applies `configuration/windows.dsc.yaml` with
  `winget configure --module-path <repo>\dsc` (must be an absolute path), then matching
  hardware profiles (`configuration/hardware.psd1`), then sets up WSL 2, the distro, and
  uv + Ansible inside it. Programs are run through `Invoke-Native` (console passthrough or
  `-Capture`, `-InputText`, `-TimeoutSeconds`). Dot-sourcing it (`. .\configure.ps1`) only
  defines the functions, so they can be tested directly in `pwsh` without admin.
- `dsc/WindowsSetupDsc/`: our own class-based DSC resources, for gaps in the Gallery modules.
  One `<Resource>.psm1` per resource, listed in the manifest's `NestedModules` and
  `DscResourcesToExport`; shared code (the `Ensure` enum, `SystemParametersInfoW` interop) is in
  `Common.psm1`, which each resource loads with `using module .\Common.psm1`. DSC discovers
  class resources in nested modules (checked in winget's host). To add a resource, add both
  manifest entries. Everything else in `dsc/` is Gallery modules winget downloaded
  (git-ignored).
- Exit code `3010` means "restart, then re-run". Every step must stay idempotent.

## Testing from the Claude desktop app

**Your shell is not elevated**, and the scripts need admin. Launching with `-Verb RunAs` pops
UAC for the user, so warn them first. Output from the elevated window can't be read directly,
so redirect it to a file through `cmd.exe` and read the file afterwards:

```powershell
Set-Location C:\Users\cstrahan\src\windows-setup
New-Item -ItemType Directory -Force logs | Out-Null
$log = "$PWD\logs\run.log"
$cmdline = "`"$PWD\bootstrap.cmd > `"$log`" 2>&1`""  # append e.g. ` -SkipWsl` after bootstrap.cmd
$p = Start-Process cmd.exe -Verb RunAs -Wait -PassThru -ArgumentList '/c', $cmdline
"exit: $($p.ExitCode)"
Get-Content $log | Where-Object { $_ -notmatch '^\s*[-\\|/]\s' -and $_.Trim() }  # drop winget spinner lines
```

Gotchas:

- **`%APPDATA%` / `%LOCALAPPDATA%` are virtualized.** Claude desktop is an MSIX app, so every
  process it spawns, including elevated ones, has AppData writes redirected to
  `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\...`. (When stage 2 was Python, this
  broke uv's managed-Python junctions.) Real runs by the user aren't affected, so don't "fix"
  this in the scripts. Programs winget runs (it's its own packaged app) write to the real
  locations. Keep it in mind when inspecting AppData from your own shell: you see the
  virtualized view.
- **Write logs somewhere short and non-virtualized.** Use the project's `logs/`, not the
  scratchpad: that path sits under `%LOCALAPPDATA%\Temp` and is close to MAX_PATH, and
  redirecting into it silently produced no file. The target directory must already exist.
- **Don't use PowerShell `*>` / `2>&1` redirection** around the bootstrap. In PS 5.1 that turns
  native stderr (winget/wsl progress, etc.) into error records, which `$ErrorActionPreference = 'Stop'`
  turns into failures. Redirect at the `cmd.exe` level as above.
- **Redirected runs aren't interactive.** The distro install (`wsl --install -d ...`) prompts for
  a Linux username/password, so that step has to be run by the user in a real terminal.
- **Windows PowerShell 5.1 gotchas** (bootstrap.ps1): `& exe | Select-Object -First 1` stops the
  pipeline early and leaves `$LASTEXITCODE` from the *previous* command, so capture all output
  first. In any PowerShell, `-replace 'a', 'b'` inside a method call's parentheses splits into
  two method arguments; compute it into a variable first.
- **PowerShell 7 must be the MSI.** winget's `Microsoft.PowerShell` defaults to the MSIX build
  (per-user, sandboxed, only a `WindowsApps\pwsh.exe` alias), so bootstrap passes
  `--installer-type wix --scope machine`.
- **Unelevated checks you can run directly:**
  - `pwsh -File <test script>` that dot-sources `configure.ps1`, then calls its functions
    (`Get-Hardware`, `Test-HardwareProfile` with faked hardware, `Invoke-Native`, the WSL
    queries).
  - `[Management.Automation.Language.Parser]::ParseFile(...)` for syntax.
  - `winget configure validate --file configuration\windows.dsc.yaml --module-path %CD%\dsc`
    checks the config file. It exits 1 with "found locally, but could not be found in any
    configured catalog" for each `WindowsSetupDsc` unit; that's expected for local modules.
    `winget configure test` needs elevation because of `securityContext: elevated`.
  - Feature state without admin: `Get-CimInstance Win32_OptionalFeature` (InstallState 1 = enabled).
  - Pending servicing reboot: `Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'`.
- **winget configure failures:** the console only shows the error message. Full stack traces
  are in `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir\WinGet-*.log`
  (search for `[CONF]`). DSC modules winget downloads are in
  `%LOCALAPPDATA%\Microsoft\WinGet\Configuration\Modules`, so you can read a resource's source there.
- **winget's DSC host is its own PowerShell 7.2.8**, built into `ConfigurationRemotingServer.exe`
  in the App Installer package. It is neither Windows PowerShell 5.1 nor any installed pwsh.
  - Windows 10's `Dism` module loads natively there, but every call throws
    `COMException: Class not registered`. `ComputerManagementDsc/WindowsCapability` turns that
    into a misleading "capability not found". Use `Import-Module Dism -UseWindowsPowerShell`
    (as `WindowsSetupDsc` does); other Windows-only modules may need the same.
  - The elevated server (`securityContext: elevated`) does **not** inherit `PSModulePath`, but it
    does get `--module-path`, which is how `configure.ps1` makes `dsc/` visible.
  - A class-based module is only discoverable if `Get-Module -ListAvailable` shows its
    `ExportedDscResources`. That list comes back empty when the manifest has
    `FunctionsToExport = @()`, so use `'*'`. Discovery failures show up only as "The
    configuration unit could not be found" (`FindDscResourceNotFoundException` in the log).
- **winget and the Gallery's `Microsoft.WinGet.DSC` must match.** winget always downloads the
  latest module, and winget 1.9's host (PowerShell 7.2 / .NET 6) can't load it: "Loading the
  module for the configuration unit failed", with `System.Runtime, Version=8.0.0.0` in the log.
  That's why `bootstrap.ps1` upgrades `Microsoft.AppInstaller` first. When winget upgrades
  itself, the old process exits with `0x80004004` (E_ABORT), and for a few seconds afterwards
  launching `winget` fails with `WinError 1920`, hence the retry in `Get-WingetVersion`.
- **winget 1.29's output format** differs from 1.9's: units are listed as `Name [id]` and results
  as "Unit successfully applied." When filtering logs, match on those.
- **Installer logs** for packages winget installs are next to winget's own logs in
  `DiagOutputDir` (e.g. `Git.Git.<version>-<timestamp>.log`), and include the full installer
  command line. Check there first when a package fails with a generic `InstallError`.
- **Git for Windows cancels silently if Git is in use** (a Git Bash window, etc.);
  `GitForWindows` checks for this first and names the processes. Don't kill the user's
  processes; ask them to close them. The Claude app's shells set `GIT_EDITOR=true`, so `git var
  GIT_EDITOR` isn't meaningful from here; use `git config --show-origin --get core.editor`.
- **Resource warnings are lost.** `Write-Warning`/`Write-Verbose` from a DSC resource shows up
  neither in winget's console output nor in its log. Anything the user must see has to be
  printed by `configure.ps1` (e.g. a hardware profile's `note`).
- **Precision touchpad settings** (`HKCU\...\PrecisionTouchPad`) can't be applied live on
  Windows 10: restarting the touchpad collection, its parent I2C HID device, or Explorer all
  failed; signing out and in worked. `SPI_GET/SETTOUCHPADPARAMETERS` exists only from
  Windows 11 24H2 (error 87 here). Touchpad tests can flip the registry freely: on Windows 10
  nothing changes until the next sign-in. Precision touchpads show up in `Get-PnpDevice` with
  hardware ID `HID_DEVICE_UP:000D_U:0005`.
  - `PrecisionTouchpad`'s Windows 10 registry mappings were checked by reading
    Settings > Devices > Touchpad with UI Automation (`UIAutomationClient`: TogglePattern,
    RangeValuePattern, SelectionPattern; `Start-Process ms-settings:devices-touchpad`), not guessed.
    `CursorSpeed` is 2 × the Windows 10 slider, and `ScrollDirection = 0xFFFFFFFF` means "Down motion
    scrolls down". The SPI path (Windows 11 24H2+) follows Microsoft's `TOUCHPAD_PARAMETERS_V1`
    docs and hasn't been run on real hardware.
  - Test it unelevated with throwaway configs under `logs/` and `winget configure test` (exit 0 =
    in the desired state), and restore the original values afterwards.
- **Keyboard:** `Scancode Map` (HKLM) is global to all keyboards and read at boot (Microsoft
  documents both; per-keyboard remapping needs a third-party filter driver). `configure.ps1`
  prints a restart note when it changes. For repeat settings, the live values
  (`SPI_GETKEYBOARDDELAY`/`SPEED`) and `HKCU\Control Panel\Keyboard` can disagree: in 2026-09 the
  live delay here was 0 while the registry said 1, so `KeyboardRepeat` checks both and sets them
  through `SystemParametersInfo` with `SPIF_UPDATEINIFILE`.
- **Time sync:** on this laptop, after sleep/hibernation the first sync often came only at the
  next poll (8+ hours later); the event log shows it (`Power-Troubleshooter` 1 = resume,
  `Time-Service` 35/37 = sync). Hence the `\windows-setup\Resync time` task. Tasks running as
  SYSTEM are invisible to unelevated queries (`Get-ScheduledTask` says not found, and
  `winget configure test` reports drift), so inspect or test them elevated, e.g.
  `schtasks /query /tn ... /xml`. Task Scheduler's defaults skip tasks on battery; set
  `AllowStartIfOnBatteries`/`DontStopIfGoingOnBatteries` for anything a laptop needs.
- **PowerShell hashtable member access can hit methods:** `$h.Clear` is `Hashtable.Clear()`, not
  the `Clear` key. Use `$h['Key']` for keys that might collide with members.
- **Probing winget's host without UAC:** write a throwaway config under `logs/` with a
  `PSDscResources/Script` unit whose `TestScript` writes diagnostics to a file and returns
  `$true`. Leave out `securityContext: elevated` and it runs unelevated with no UAC prompt, so
  you can run `winget configure --file logs\x.dsc.yaml --accept-configuration-agreements
  --disable-interactivity` directly. Add the directive only for things that need admin.
- **`wsl.exe` output** is UTF-16LE unless `WSL_UTF8=1` is set; `configure.ps1` handles both.

## Machine-specific history (Windows 10 22H2, 19045)

- Store WSL (2.x) is installed. In 2026-09 the WSL optional features reported *Enabled* while the
  component was still pending a restart (Fast Startup meant no real reboot since 2025-01). The
  result was `WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED`, no `LxssManager` service, and
  `0x80080005` from the Ubuntu launcher.
  A real Restart fixed it.
- `RealTimeIsUniversal` was already `1` (QWORD) before this project touched it.
- The `Ubuntu` distro (26.04 LTS, default user `cstrahan`) already exists, so full bootstrap runs
  from Claude are non-interactive here. As of 2026-09-18, two consecutive full runs exited 0; the
  second was a no-op (ansible-core 2.21.4, ansible.windows 3.8.0).
- 2026-09-18: App Installer upgraded 1.24 → 1.29 (winget 1.9 → 1.29.290) and Git 2.33.0.2 →
  2.55.0.3 by this configuration. VS Code (user scope) and Windows Terminal 1.21 were already
  installed. A full `-SkipWsl` re-run takes about 15 seconds and changes nothing.
