# Notes for Claude

See README.md for what the project does. These notes cover testing it from a Claude session.

## Layout

- `bootstrap.cmd` → `bootstrap.ps1` (stage 1, Windows PowerShell 5.1). Contract: it's started
  **unelevated** and refuses to run otherwise. The unelevated section (`Invoke-UnelevatedSection`)
  installs per-user things as the user (Scoop, so `~\scoop` isn't owned by Administrators). It
  then relaunches itself with `--elevated-relaunch` via UAC for the elevated section
  (`Invoke-ElevatedSection`): register and upgrade winget, install/upgrade PowerShell 7 (the
  MSI), run `configure.ps1` with `C:\Program Files\PowerShell\7\pwsh.exe` (full path: PATH isn't
  refreshed in that session). The elevated window pauses for Enter at the end unless its output
  is redirected. Unelevated-only steps belong in the unelevated section. De-elevating from the
  elevated section is possible but not simple; see "Future directions" for what was measured and
  a design for supporting bootstrap starts from an elevated prompt.
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
- `install.ps1`: the README's one-liner (`irm .../install.ps1 | iex`). Resolves a ref to a commit
  via the GitHub API, caches the extracted zip in `%LOCALAPPDATA%\windows-setup\<sha>`, runs
  its `bootstrap.ps1`. Must stay 5.1-compatible, keep everything inside its `& { } @args`
  block (iex runs in the caller's scope), and never `exit` (that closes the caller's window).
  Test it locally with `& ([scriptblock]::Create((Get-Content -Raw install.ps1))) -CacheDir
  <repo>\logs\cache ...`, run *unelevated* (the bootstrap refuses to start elevated); its
  elevated window then waits for the user's Enter. Don't use the default cache from here: `%LOCALAPPDATA%` is virtualized for
  Claude's processes, and winget (outside the sandbox) wouldn't see the files. It fetches
  what's on GitHub, so local changes need pushing first.
- Exit code `3010` means "restart, then re-run". Every step must stay idempotent.

## Testing from the Claude desktop app

**Your shell is not elevated**, and most of the work needs admin. Launching with `-Verb RunAs`
pops UAC for the user, so warn them first. Output from an elevated window can't be read
directly, so redirect it to a file through `cmd.exe` and read the file afterwards. Plain
`bootstrap.cmd` refuses to start elevated, so to test the **elevated section**, invoke its
relaunch step directly; with output redirected it doesn't pause for Enter:

```powershell
Set-Location C:\Users\cstrahan\src\windows-setup
New-Item -ItemType Directory -Force logs | Out-Null
$log = "$PWD\logs\run.log"
$cmdline = "`"$PWD\bootstrap.cmd --elevated-relaunch > `"$log`" 2>&1`""  # add e.g. -SkipWsl after --elevated-relaunch
$p = Start-Process cmd.exe -Verb RunAs -Wait -PassThru -ArgumentList '/c', $cmdline
"exit: $($p.ExitCode)"
Get-Content $log | Where-Object { $_ -notmatch '^\s*[-\\|/]\s' -and $_.Trim() }  # drop winget spinner lines
```

To test the **whole flow** (unelevated section, then UAC, then elevated section), run
`bootstrap.cmd` unelevated from your shell (`Start-Process cmd.exe -Wait -WindowStyle Hidden
-ArgumentList '/c', "... > log 2>&1"`). The log only has the unelevated part; the elevated
window shows the rest and waits for the user to press Enter, so tell them.

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
- **The sandbox virtualizes AppData only, not the registry:** `HKCU\Environment` writes from
  your shell were visible to winget's (unsandboxed) process. So things that write only to
  `~\...` and the registry, like Scoop's installer, can run from your shell, so the bootstrap's
  unelevated section can be tested from here.
- **WSLg's Remote Desktop client (`msrdc.exe`) can't load on this machine as of 2026-09-18.**
  WSL 2.7.14's `rdclientax.dll` imports `kernel32!GetTempPath2W`, which Windows 10 only has from
  the March 2025 updates, and this laptop was on January 2025's (19045.5371). Symptoms:
  - Linux GUI apps (e.g. `xeyes`) never appear; Weston logs `rdp_peer is not initalized` in
    `/mnt/wslg/weston.log`.
  - WSLg relaunches `msrdc.exe` repeatedly (`/mnt/wslg/stderr.log`).
  - WSL started from your shells also showed recurring "Could not load the Remote Desktop
    Services ActiveX control (rdclientax.dll)" / "RemoteApp … unable to connect" pop-ups; from
    the user's own launches the client fails quietly in `/silent` mode.

  Diagnose by loading the DLL (`LoadLibraryEx` gives error 127 = procedure not found) and
  checking its imports with `GetProcAddress`. The fix is the latest cumulative update
  (KB5066791, October 2025, the last free one for Windows 10 22H2). It was downloaded but not
  installed; the user was told. Until that's installed, use `-SkipWsl` for routine runs. If WSL
  must be exercised, stop the `msrdc.exe` processes it leaves behind afterwards, elevated
  (`taskkill /F /PID ...`; wslservice launches them, so unelevated gets Access denied), and tell
  the user.
- **Redirected runs aren't interactive.** The distro install (`wsl --install -d ...`) prompts for
  a Linux username/password, so that step has to be run by the user in a real terminal.
- **Windows PowerShell 5.1 gotchas** (bootstrap.ps1): `& exe | Select-Object -First 1` stops the
  pipeline early and leaves `$LASTEXITCODE` from the *previous* command, so capture all output
  first. `Get-ItemPropertyValue -ErrorAction SilentlyContinue` still *throws* when the key exists
  but the value doesn't; use `Get-RegistryValue` (bootstrap.ps1). In any PowerShell, `-replace 'a', 'b'` inside a method call's parentheses splits into
  two method arguments; compute it into a variable first.
- **PowerShell 7 must be the MSI.** winget's `Microsoft.PowerShell` defaults to the MSIX build
  (per-user, sandboxed, only a `WindowsApps\pwsh.exe` alias), so bootstrap passes
  `--installer-type wix --scope machine`.
- **Faking failures for tests:** `bootstrap.ps1` and `configure.ps1` can both be dot-sourced to
  just define their functions. Their paths are script variables, so point `$ConfigurePolicyKey` /
  `$VCRedistKey` at a scratch key under `HKCU:` (and remove it afterwards). In PowerShell a
  function beats an executable of the same name, so `function winget.exe { ... }` stands in for
  winget (setting `$global:LASTEXITCODE`) to exercise the "configure disabled" paths. The
  `winget configure` guards, retries, preflight and PATH checks borrow ideas from
  microsoft/WindowsDeveloperConfig's `src/Workloads/_common` (MIT). Its scripts weren't vendored
  because they're tied to that repo's CI and Command Palette tooling.
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

## Future directions

### Starting the bootstrap elevated (not implemented; the user chose to keep the current rule)

Today `bootstrap.ps1` refuses to start elevated, and a normal run uses two windows: the
original unelevated one, plus the elevated one UAC opens. (That's inherent: UAC can't elevate a
running process, and hiding the elevated window would leave interactive prompts, like the
first-time WSL user creation, with nowhere to appear.) A more graceful alternative for the
started-elevated case, measured on 2026-09-18 but not built:

- Run only the **unelevated section** as a hidden, unelevated child, wait for it, print its
  log, then continue with the elevated section in the **same window**. That gives one window
  and no UAC prompt. If the elevation used a *different* admin account, the child runs as the
  signed-in desktop user, which is the right profile for Scoop.
- **How to de-elevate.** Measured from an elevated process with a probe recording integrity
  level, admin status, and the owner of a folder it creates:

  | Method | Result |
  |---|---|
  | `__COMPAT_LAYER=RunAsInvoker` | still High/admin (it only prevents elevation) |
  | `(New-Object -ComObject Shell.Application).ShellExecute(...)` | still High/admin (that object lives in the elevated process) |
  | `runas /trustlevel:0x20000` | not admin, but **High** integrity; returns without waiting |
  | `explorer.exe script.cmd` | Medium/user, but no arguments and always a visible window |
  | scheduled task, Interactive logon, Limited run level | Medium/user; needs polling to wait (a first attempt's wait loop missed completion and hung until its timeout) |
  | **the desktop's `Shell.Application` via `IShellWindows.FindWindowSW`** | **Medium/user, parent `explorer`, takes arguments, can be hidden** |

  The last one is the one to use (Raymond Chen's "launch an unelevated process from an
  elevated one"). It worked from Windows PowerShell 5.1 as:

  ```powershell
  Add-Type -ReferencedAssemblies Microsoft.CSharp -TypeDefinition @"
  using System;
  public static class DesktopShell {
      public static void ShellExecute(string file, string args, int show) {
          dynamic windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")));
          object loc = 0, root = null; int hwnd;
          dynamic desktop = windows.FindWindowSW(ref loc, ref root, 8 /* SWC_DESKTOP */, out hwnd, 1 /* SWFO_NEEDDISPATCH */);
          desktop.Document.Application.ShellExecute(file, args, "", "open", show);  // show 0 = hidden
      }
  }
  "@
  ```

- **Waiting.** Launching through Explorer gives no process handle. Have the child (e.g.
  `bootstrap.ps1 --unelevated-section --result-file <path>`, run through `cmd /c "... > log
  2>&1"` so native output is captured) write its exit code to a temp file and rename it into
  place when done, so it appears complete in one step. The parent polls for that file with a
  timeout, then prints the log.
- **Fallback:** if Explorer isn't running (so `FindWindowSW` fails), keep today's "start from a
  normal prompt" error.

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
