# Notes for Claude

See README.md for what the project does. These notes cover testing it from a Claude session.

## Layout

- `bootstrap.cmd` → `bootstrap.ps1` (stage 1, Windows PowerShell 5.1). Contract: it's started
  **unelevated** and refuses to run otherwise. The unelevated section (`Invoke-UnelevatedSection`)
  installs per-user things as the user (Scoop, so `~\scoop` isn't owned by Administrators). It
  then relaunches itself with `--elevated-relaunch` via UAC for the elevated section
  (`Invoke-ElevatedSection`): register and upgrade winget, VC++ runtime, install/upgrade DSC v3
  (`Microsoft.DSC`) and PowerShell 7 (the MSI), run `configure.ps1` with `C:\Program Files\PowerShell\7\pwsh.exe` (full path: PATH isn't
  refreshed in that session). The elevated window pauses for Enter at the end unless its output
  is redirected. Unelevated-only steps belong in the unelevated section. De-elevating from the
  elevated section is possible but not simple; see "Future directions" for what was measured and
  a design for supporting bootstrap starts from an elevated prompt.
- `configure.ps1` (stage 2, PowerShell 7): puts `<repo>\dsc` on `PSModulePath`, applies
  each configuration with `dsc config set --output-format json` (`Invoke-DscConfiguration`:
  stdout is parsed into a changed/unchanged summary, stderr traces go to the console): matching
  hardware profiles (`configuration/hardware.psd1`), then the workloads
  (`configuration/workloads.psd1` + `configuration/workloads/*.dsc.yaml`). There's no base
  config: everything, even Explorer settings, is a workload. `Resolve-Workloads` adds the
  `Always` ones (`core`), applies `-Workloads`/`-ExcludeWorkloads`, orders by `Requires`, and
  refuses exclusions that break a requirement. After that it sets up WSL 2, the distro, and uv +
  Ansible inside it. Programs are run through `Invoke-Native` (console passthrough, or
  `-Capture` / `-CaptureStdout`, `-InputText`, `-TimeoutSeconds`). Dot-sourcing it
  (`. .\configure.ps1`) only defines the functions, so they can be tested directly in `pwsh`
  without admin.
- `dsc/WindowsSetup.<Name>/`: our own class-based DSC resources, **one single-file module per
  resource** (`WindowsSetup.<Name>.psd1` with `RootModule` = the `.psm1` holding the class, and
  `DscResourcesToExport`). Resource type names are `WindowsSetup.<Name>/<Name>`. Shared code (the
  `Ensure` enum, `SystemParametersInfoW` interop) is the `WindowsSetup.Common` module, loaded with
  `using module WindowsSetup.Common` (so it must be on PSModulePath even to parse-check). See
  "DSC v3" below for why they're split up.
- `install.ps1`: the README's one-liner (`irm .../install.ps1 | iex`). Resolves a ref to a commit
  via the GitHub API, caches the extracted zip in `%LOCALAPPDATA%\windows-setup\<sha>`, runs
  its `bootstrap.ps1`. Must stay 5.1-compatible, keep everything inside its `& { } @args`
  block (iex runs in the caller's scope), and never `exit` (that closes the caller's window).
  Test it locally with `& ([scriptblock]::Create((Get-Content -Raw install.ps1))) -CacheDir
  <repo>\logs\cache ...`, run *unelevated* (the bootstrap refuses to start elevated); its
  elevated window then waits for the user's Enter. Don't use the default cache from here: `%LOCALAPPDATA%` is virtualized for
  Claude's processes, and winget (outside the sandbox) wouldn't see the files. It fetches
  what's on GitHub, so local changes need pushing first.
- Exit code `3010` means "restart, then re-run". Every step must stay idempotent. On 3010
  (only the WSL platform install raises it) `bootstrap.ps1` registers the logon task
  `\windows-setup\Resume after restart` (`Register-ResumeTask`: runs `bootstrap.cmd <args>
  -Resumed` as the user, Limited, 30 s after logon); the elevated section removes it. With
  `-Resumed`, `configure.ps1`'s `Install-WslPlatform` refuses a second restart unless one is
  actually pending (CBS `RebootPending`) and diagnoses virtualization instead.

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
  (KB5066791, October 2025, the last free one for Windows 10 22H2). The user installed it on
  2026-09-19 (build 19045.6456), but WSLg hasn't been re-checked since; until it has, use
  `-SkipWsl` for routine runs. If WSL must be exercised, stop the `msrdc.exe` processes it leaves behind afterwards, elevated
  (`taskkill /F /PID ...`; wslservice launches them, so unelevated gets Access denied), and tell
  the user.
- **Redirected runs aren't interactive.** The distro install (`wsl --install -d ...`) prompts for
  a Linux username/password, so that step has to be run by the user in a real terminal.
- **Windows PowerShell 5.1 gotchas** (bootstrap.ps1): `& exe | Select-Object -First 1` stops the
  pipeline early and leaves `$LASTEXITCODE` from the *previous* command, so capture all output
  first. `Get-ItemPropertyValue -ErrorAction SilentlyContinue` still *throws* when the key exists
  but the value doesn't; use `Get-RegistryValue` (bootstrap.ps1). In any PowerShell, `-replace 'a', 'b'` inside a method call's parentheses splits into
  two method arguments; compute it into a variable first. Related: `,` binds tighter than
  arithmetic, so `@(0x6F + $n, 0)` is `0x6F + ($n, 0)` and fails with "does not contain a method
  named 'op_Addition'"; parenthesise the sum.
- **PowerShell 7 must be the MSI.** winget's `Microsoft.PowerShell` defaults to the MSIX build
  (per-user, sandboxed, only a `WindowsApps\pwsh.exe` alias), so bootstrap passes
  `--installer-type wix --scope machine`.
- **Scoop's installer persists a custom location.** Run with `-ScoopDir`, it writes `root_path`
  to the user's real `~\.config\scoop\config.json`. After a test install into a scratch dir
  (2026-09-18), the user's real Scoop kept looking there until the key was removed. If a test
  installs Scoop somewhere else, also back up and restore that file, not just `PATH` and the
  `SCOOP` variable. Check with `scoop config root_path` (unset = default `~\scoop`).
- **Faking failures for tests:** `bootstrap.ps1` and `configure.ps1` can both be dot-sourced to
  just define their functions. Their paths are script variables, so point `$VCRedistKey` at a
  scratch key under `HKCU:` (and remove it afterwards). In PowerShell a function beats an
  executable of the same name, so `function winget.exe { ... }` stands in for winget (setting
  `$global:LASTEXITCODE`). The retries, preflight and PATH checks borrow ideas from
  microsoft/WindowsDeveloperConfig's `src/Workloads/_common` (MIT). Its scripts weren't vendored
  because they're tied to that repo's CI and Command Palette tooling. A clone of that repo may
  be at `C:\Users\cstrahan\src\WindowsDeveloperConfig`; the workloads were adapted from its
  `src/Workloads/<name>/configuration.winget`.
- **Unelevated checks you can run directly:**
  - `pwsh -File <test script>` that dot-sources `configure.ps1`, then calls its functions
    (`Get-Hardware`, `Test-HardwareProfile` with faked hardware, `Invoke-Native`,
    `Resolve-Workloads`, `Invoke-DscConfiguration` on a throwaway HKCU-only config under `logs/`,
    the WSL queries).
  - `[Management.Automation.Language.Parser]::ParseFile(...)` for syntax.
  - With `$env:PSModulePath = "$PWD\dsc;$env:PSModulePath"`: `dsc config test --file <config>
    --output-format json` (per-resource `inDesiredState` / `differingProperties`),
    `dsc config set --what-if`, and `dsc resource list 'WindowsSetup.*' --adapter
    Microsoft.Adapter/PowerShell` (discovery). Most workloads and hardware profiles test fine
    unelevated; `ssh` fails because `WindowsCapability`'s DISM calls need admin, and `time`'s
    SYSTEM-owned task reads as drift (see "Time sync").
  - Feature state without admin: `Get-CimInstance Win32_OptionalFeature` (InstallState 1 = enabled).
  - Pending servicing reboot: `Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'`.
- **DSC v3 (dsc 3.2.3, the `Microsoft.DSC` MSIX from winget; switched from `winget configure` on
  2026-09-19).** Measured quirks:
  - **dsc does not test before set.** Both `PowerShellScript` and adapted class resources ran
    Set even when Test returned true. Every class `Set()` starts with `if ($this.Test()) { return }`,
    and every `setScript` re-checks before acting.
  - **`PowerShellScript`** (`Microsoft.DSC.Transitional`): `testScript` must output exactly one
    `[bool]`; with `input`, every script needs exactly one `param($X)`; it runs with
    `$ErrorActionPreference = 'Stop'`. The set result counts `output` as changed unless the
    get and set outputs are equal, so use `getScript: 'return'` (outputs `[]`; `'$null'` outputs
    `[null]`) and have `setScript` print only when it changes something. The summary shows those
    lines.
  - **The PowerShell adapter only finds classes in a module's root `.psm1`.**
    `psDscAdapter.psm1` calls `$Resources.AddRange(...)` on a function's returned List, which
    PowerShell unrolls (empty → `$null`, one item → the bare object), so modules with
    `NestedModules` fail discovery. Hence one module per resource. The adapter caches discovery
    in `%LOCALAPPDATA%\dsc\PSAdapterCache*.json`; delete it (`[IO.File]::Delete`) after
    renaming modules.
  - Resources must not write to stdout: the adapter talks to dsc over it. Capture native output,
    or use `Start-Process -Wait`.
  - **`Microsoft.Windows/FeatureOnDemandList` (`dism_dsc`) refuses to run from the MSIX install**
    ("This resource currently is not supported when installed via Appx"), which is the only way
    winget ships dsc. Hence our `WindowsSetup.WindowsCapability`. Other `Microsoft.Windows/*`
    resources (`Registry`, `Service`) worked. Check new built-in resources for this.
  - dsc runs in its own package context: its AppData and HKCU writes land in the real
    locations even when launched from Claude's sandboxed shell.
  - `Microsoft.WinGet/Package` and the other `Microsoft.WinGet/*` resources ship with App
    Installer (listed from its `WindowsApps` folder), not with dsc; `Initialize-Dsc` checks for them.
  - `dependsOn` syntax: `"[resourceId('Type/Name', 'name')]"`.
  - A class-based module is only discoverable if `Get-Module -ListAvailable` shows its
    `ExportedDscResources`. That list comes back empty when the manifest has
    `FunctionsToExport = @()`, so use `'*'`.
- **Windows 10's `Dism` module under PowerShell 7:** in winget's old configuration host (its own
  PowerShell 7.2.8) every call threw `COMException: Class not registered`. `WindowsCapability`
  loads it with `Import-Module Dism -UseWindowsPowerShell`; other Windows-only modules may need
  the same.
- **winget self-upgrade:** when winget upgrades itself, the old process exits with `0x80004004`
  (E_ABORT), and for a few seconds afterwards launching `winget` fails with `WinError 1920`,
  hence the retry in `Get-WingetVersion`.
- **winget package IDs are case-sensitive with `--exact`** (and in `Microsoft.WinGet/Package`):
  WindowsDeveloperConfig's `Microsoft.WinAppCLI` doesn't match `Microsoft.WinAppCli`. Check IDs
  with `winget show --id <id> --exact --source winget`.
- **Visual Studio Installer (`setup.exe modify`)**, measured 2026-09-19 with VS 2026 18.10:
  - `--wait` is only a `vs_<edition>.exe` bootstrapper option; the installed `setup.exe` rejects
    it with exit code 87 ("Option 'wait' is unknown"). `setup.exe` runs to completion anyway.
  - **Unknown `--add` IDs are silently ignored** (exit 0). Hence `VisualStudioComponents`
    re-tests after Set. Check IDs in `C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<id>\catalog.json`
    (`packages[].id`); e.g. VS 2026 has `Component.WindowsAppSdkSupport.CSharp`, not
    WindowsDeveloperConfig's `ComponentGroup.WindowsAppSDK.Cs`.
  - Logs: `%TEMP%\dd_setup_*.log` (+ `_errors.log`), `dd_installer_*.log`. Benign noise: canceled
    channel-update requests (0x8013153b), "Didn't find any channel feed", "not applicable"
    packages, and `Error 0x80070005: Could not sync DCAT registration` (a TrustedInstaller-owned
    Windows Update key; only affects VS updates via Windows Update).
  - Adding the C++ workload returned 3010 (restart to finish); the resource warns.
- **Drivers (`WindowsSetup.DriverPackage`, gaze16 profile).** Findings from 2026-09-19:
  - System76's chipset and Serial IO drivers were already on this laptop, but they had been
    installed by hand with Intel's installers (`setupapi.dev.log` shows `%TEMP%` source paths
    via DifX), not by Windows Update. Check with `pnputil /enum-drivers`, `Win32_PnPSignedDriver`,
    and `Select-String` in `C:\Windows\INF\setupapi.dev*.log`.
  - The package version isn't the driver version: chipset "10.1.18698.8258" ships
    `TigerLakePCH-HSystem.inf` 10.1.34.8 (dated 1968 so it never outranks a real driver).
  - Intel's INFs mostly list bare `PCI\VEN_x&DEV_y` IDs, which are devices' *compatible* IDs,
    so match on HardwareID + CompatibleID.
  - **system76/windows-drivers stores zips in Git LFS.** `raw.githubusercontent.com/<commit>/...`
    returns the 132-byte pointer; use `media.githubusercontent.com/media/<owner>/<repo>/<commit>/<path>`.
    (`github.com/<owner>/<repo>/raw/master/...` also redirects to the content, but isn't pinned.)
  - Test: `dsc config test`/`get` works unelevated (`get` lists `OutdatedDevices`); the cache is
    `%ProgramData%\windows-setup\drivers\<sha256>`. The `pnputil /add-driver /install` path ran
    for real once (the HID Event Filter, 2026-09-19): the device came up OK at once, no restart.
  - **`Win32_PnPSignedDriver` goes stale:** right after that install it still listed the device
    with a blank version, while `DEVPKEY_Device_DriverVersion` (`Get-PnpDeviceProperty`) was
    already right. The resource reads the device property.
  - `ACPI\INT33D5` (Intel HID Event Filter) had no driver. Windows Update offered 1.1.1.318
    (2016) as an optional update; the profile installs System76's 2.2.1.386 (added for the gaze17;
    its INF lists INT33D5 for Windows 10 1803+). Without it, some Fn hotkeys did nothing (e.g.
    brightness; volume worked); with it, the user confirmed they all work. Pending WU drivers, with hardware IDs, come from
    `Microsoft.Update.Session` → `CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'")`
    (works unelevated).
  - Still without drivers, deliberately: `ACPI\INTC1026` (the SCU/PMC IPC interface, per Linux's
    `intel_scu_pltdrv`; no Windows driver offered), `ACPI\17761776` (System76 ACPI),
    `ACPI\BOOT0000` (coreboot tables).- **GPU drivers** (2026-09-19; neither has a winget package):
  - **NVIDIA** (`WindowsSetup.NvidiaDriver`, `hardware/nvidia.dsc.yaml`): NVIDIA's client lookup
    `gfwsl.geforce.com/.../getDispDrvrByDevid/<json>` takes the PCI device ID (`dIDa: ["2520_10DE"]`),
    `iLp` (laptop), `isCRD`/`upCRD` (Studio) and returns `DriverAttributes.Version` and
    `DownloadURLAdmin` (the full package, with the NVIDIA App). NVIDIA version = last five digits
    of the Windows version's last two parts (31.0.15.3713 -> 537.13); only trust it when the
    device's driver provider is NVIDIA. The package installs with `-s -noreboot` (as
    TinyNvidiaUpdateChecker does); no checksums, so its Authenticode signer is checked. Here it
    went 537.13 -> 616.92 and replaced GeForce Experience with the NVIDIA App.
  - The installer creates `ROOT\UNNAMED_DEVICE\0001` with hardware ID `ACPI\NVDA0820` (NVPCF /
    Dynamic Boost) even though this coreboot firmware has no such ACPI device (System76 supports
    Dynamic Boost only on 13th-gen models), so it failed with code 31. The profile disables such
    stand-ins only when no firmware `ACPI\NVDA0820\*` device exists.
  - **Intel** (`WindowsSetup.DriverInstaller`, gaze16 profile): no lookup API, and intel.com pages
    return "Access Denied" to scripts, but `downloadmirror.intel.com/<id>/<file>` works; the SHA-256
    is on the download page (read it with WebFetch). The package is a self-extractor whose
    `installation_readme.txt` documents switches and exit codes (read it with 7-Zip, installed at
    `C:\Program Files\7-Zip`). **The .exe returns 1000 + Installer.exe's code** (log:
    `%ProgramData%\Intel\GFXInstaller\{Bootstrapper,Installer}\*.log`).
  - **Installers must not inherit PowerShell 7's `PSModulePath`.** Intel's self-extractor runs
    `powershell.exe` to hash its files; started (indirectly) from pwsh, 5.1 inherits pwsh's module
    paths, can't find `Get-FileHash`, and shows "the file integrity check failed". (pwsh repairs
    the variable only for processes it starts itself, so `& powershell.exe` from pwsh doesn't
    reproduce it; go through `cmd.exe /c`.) Both resources reset it to the Machine value around
    `Start-Process`.
- **PowerShell class gotchas** (both broke a module's load, which dsc reports only as a
  `FindAndParseResourceDefinitions` error): a method's local variable can't share a property's
  name (`$gpu` vs `[string] $Gpu`), and a variable assigned only inside an inner `try` is "not
  assigned in the method". Parse-check every module after edits:
  `[Management.Automation.Language.Parser]::ParseFile(...)`, ignoring the `using module` errors.- **Installer logs** for packages winget installs are next to winget's own logs in
  `DiagOutputDir` (e.g. `Git.Git.<version>-<timestamp>.log`), and include the full installer
  command line. Check there first when a package fails with a generic `InstallError`.
- **Git for Windows cancels silently if Git is in use** (a Git Bash window, etc.);
  `GitForWindows` checks for this first and names the processes. Don't kill the user's
  processes; ask them to close them. The Claude app's shells set `GIT_EDITOR=true`, so `git var
  GIT_EDITOR` isn't meaningful from here; use `git config --show-origin --get core.editor`.
- **Resource warnings:** under `winget configure`, `Write-Warning` from a resource was lost.
  Under dsc, adapter and script warnings reach stderr as `WARN` traces, which `configure.ps1`
  passes to the console, but keep anything the user must act on in `configure.ps1` output
  (e.g. a hardware profile's `note`).
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
  - Test it unelevated with throwaway configs under `logs/` and `dsc config test`, and restore
    the original values afterwards.
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
  `dsc config test` reports drift), so inspect or test them elevated, e.g.
  `schtasks /query /tn ... /xml`. Task Scheduler's defaults skip tasks on battery; set
  `AllowStartIfOnBatteries`/`DontStopIfGoingOnBatteries` for anything a laptop needs.
- **PowerShell hashtable member access can hit methods:** `$h.Clear` is `Hashtable.Clear()`, not
  the `Clear` key. Use `$h['Key']` for keys that might collide with members.
- **Testing the WSL restart/resume flow** without breaking this machine's WSL (tested
  2026-09-19):
  - The logic: dot-source `configure.ps1` in `pwsh` and override `Test-WslPlatformActive`,
    `Test-VirtualizationAvailable` and `Invoke-Native` (it uses `Process.Start`, so a
    `function wsl.exe` fake isn't enough), set `$Resumed`, and point `$CbsRebootPendingKey` /
    `$LxssKey` at scratch `HKCU:` keys.
  - The task: dot-source `bootstrap.ps1` in Windows PowerShell, set `$passthru = @('-SkipWsl',
    '-Workloads', 'core')`, call `Register-ResumeTask` (works unelevated), inspect it with `schtasks
    /query /tn "\windows-setup\Resume after restart" /xml`, then `Start-ScheduledTask` it. That
    runs what the logon trigger would: a visible window, a UAC prompt, and an elevated window
    waiting for Enter (tell the user). The task disappearing shows the elevated section ran.
  - Real signals here: `vmcompute` exists; `Win32_Processor.VirtualizationFirmwareEnabled` is
    False because a hypervisor is running, so `HypervisorPresent` is checked first.
- **Probing dsc without UAC:** write a throwaway config under `logs/` with a
  `Microsoft.DSC.Transitional/PowerShellScript` resource whose scripts write diagnostics, and run
  `dsc config set --file logs\x.dsc.yaml --output-format json` directly from your shell.
- **`wsl.exe` output** is UTF-16LE unless `WSL_UTF8=1` is set; `configure.ps1` handles both.
- **dsc config parameters:** `--parameters '<json>'` is an option of `dsc config` itself, *before*
  the subcommand (`dsc config --parameters ... set --file ...`), and dsc fails with "No parameters
  defined in configuration" when the document doesn't declare them. `Invoke-DscConfiguration`
  therefore passes `repoRoot` only to configurations whose text matches `^\s+repoRoot:` (the
  `shell` workload installs files from the repo that way).
- **A property string starting with `[` is parsed as a dsc expression** (`[parameters('x')]`), even
  in a `|` block scalar: a `testScript` beginning with `[bool] (...)` fails with "Parser: Unable to
  parse statement root". Start such scripts with something else (assign first, then `[bool] $x`).
- **PowerShell profiles** (the `shell` workload): the loader block goes in the all-hosts profiles
  (`Documents\{PowerShell,WindowsPowerShell}\profile.ps1`) and dot-sources
  `~\.config\powershell\profile.d\*.ps1`; the snippets are copied from
  `configuration\powershell\profile.d` and carry a `windows-setup: managed file` header (that
  marker is what makes removal of dropped files safe). Profiles and `~\.config` are outside the
  AppData sandbox, so this workload can be applied and tested straight from your shell with
  `dsc config --parameters ... set --file configuration\workloads\shell.dsc.yaml` (no UAC: mise
  installs, `Install-PSResource -Scope CurrentUser` and those files are all per-user). Test the
  result with `pwsh -NoProfile -Command { Import-Module PSReadLine; . <snippet>; Get-PSReadLineKeyHandler -Bound }`:
  a non-interactive host has no PSReadLine loaded, and `20-psfzf.ps1` deliberately returns early
  there (as it does on 5.1, whose PSReadLine 2.0 is older than PSFzf's handlers expect).
- **Running things outside the AppData sandbox, unelevated:** `logs\unsandboxed.dsc.yaml` (git-
  ignored; recreate if missing) is a PowerShellScript resource whose setScript refreshes PATH and
  runs `logs\step.ps1` with all output to `logs\step.log`. `dsc config set --file
  logs\unsandboxed.dsc.yaml` from your shell then runs the step for real (dsc's package context),
  with no UAC. Use it for anything that must write the user's real `%LOCALAPPDATA%` (Neovim's
  config and data, mise installs). Reading those locations from your own shell is fine.

## Testing interactive console apps (tools\ConsoleHarness)

Terminal UIs (the fzf pickers, Neovim) can be driven and read from a script, so their interactions
don't need a human at the keyboard:

```powershell
Import-Module .\tools\ConsoleHarness
$session = Start-ConsoleApp -Command '. "$HOME\.config\powershell\profile.d\40-fzf-functions.ps1"; _fzf_select_path' -WorkingDirectory $PWD
try {
    Wait-ConsoleText $session 'Files> '            # poll, don't sleep
    Send-ConsoleKeys $session 'psfzf'              # literal text
    $screen = Send-ConsoleKeys $session '^s'       # Ctrl+S; returns the redrawn screen as string[]
} finally { Stop-ConsoleApp $session }             # always
```

- **Keys use AutoHotkey v2's `Send` syntax** (the `tools\KeySpec` module, parsed in the
  calling process): text is literal, `{Enter}` `{Tab}` `{BS 3}` `{F5}` are keys, `^` `!` `+` are
  Ctrl/Alt/Shift for the next key, `{Ctrl down}`…`{Ctrl up}` holds one, and `{^}` `{!}` `{{}`
  `{U+263A}` `{Raw}` are the escapes. **`!` and `+` inside text need escaping**: `:qa!{Enter}`
  silently sends Alt+Enter, so write `:qa{!}{Enter}`. **`Send-ConsoleText` is the literal
  counterpart** (AHK's `SendText`): nothing in it is syntax, so paths, commas, braces and words
  like `enter` all survive — use it for anything that came from a variable or the app's own
  output. `#` (Win), mouse/media keys and a bare `{Ctrl}` are errors, since a console app can't
  receive them.
- **A session survives your tool call**, so poking at an app across several calls works: start it
  with `-Name <label>`, then `$s = Get-ConsoleApp -Name <label>` in the next call and carry on
  sending keys. `Get-ConsoleApp` with no arguments lists what's still running (records and screens
  live in `%TEMP%\console-harness`). **`Stop-ConsoleApp` kills the process tree**, not just the
  `pwsh` wrapper — before that was fixed, tests left 180 stray `fzf`/mise-shim processes behind.
  `Stop-ConsoleApp -All` clears everything the module started, which is the cleanup to run after
  a script died before its `finally`.
- **Mouse, size and scrollback** (all verified 2026-09-19): `{Click 40 10}`, `{Click 5 5 Right}`,
  `{LButton down}`...`{LButton up}`, `{WheelDown 3}` (coordinates are cells in the visible window
  and stick between tokens); `Get-ConsoleInfo`, `Set-ConsoleSize`; `Get-ConsoleScreen -Scrollback`
  / `-FromRow`/`-Rows` and `Move-ConsoleView -Lines/-Top/-Start/-End`.
- **Mouse delivery is a property of the application, not the console.** `-MouseDelivery Vt`
  (the default, SGR reports) or `Record` (console input records). There is deliberately no
  auto-detection: an application can parse SGR from its own input without setting
  `ENABLE_VIRTUAL_TERMINAL_INPUT`, so the console's mode proves nothing. Neovim and fzf's
  `--height` mode want `Vt`; full-screen fzf wants `Record` (it uses tcell). The README keeps a
  table of known application quirks - **add to it** when you work one out.
- **Before aiming a mouse event, print the screen with row numbers** and see where the
  application actually drew. Events outside its box are ignored, which looks identical to "mouse
  is broken", and guessing at coordinates cost a long detour once already: fzf with `--height 60%`
  drew rows 1-14 in a 30-row console while the wheel was being aimed at row 20. One
  `for ($i = 0; $i -lt $screen.Count; $i++) { '{0,3}: {1}' -f $i, $screen[$i] }` settles it, and
  a small window keeps the dump cheap. The same goes for reading state back: assert on something
  that can actually change (fzf's `--preview 'echo SEL={}'`), not on a marker like the selection
  bar, which the character grid shows on every row.
- **An app on the alternate screen buffer** (any full-screen TUI) refuses buffer/window resizes
  with `ERROR_INVALID_HANDLE`, so `Set-ConsoleSize` falls back to resizing conhost's window; it
  also has no scrollback.
- **Tests:** `pwsh -File tools\Test-Tools.ps1` runs every `tools\<module>\Test-*.ps1`
  (`-Name KeySpec` for one, `-SkipConsole` to skip the ones that drive a real console). The
  console tests need fzf on PATH — it isn't in Claude's shells, so prepend
  `$env:LOCALAPPDATA\mise\shims`. Shared assertions live in `tools\TestSupport.ps1`; there's no
  Pester because Windows ships only 3.4 and these tools must work on an unconfigured machine.
- **The key/mouse parser is its own module** (`tools\KeySpec`, PowerShell 5.1-compatible, no
  console dependencies) so the planned ConPTY harness can share the syntax. Its tests are
  `tools\KeySpec\Test-KeySpec.ps1`, and its README documents the syntax in full.

- **How:** the app runs in its own hidden console; each call spawns a worker that attaches to it
  (`AttachConsole`), reads the visible grid (`ReadConsoleOutputCharacter`) and injects keys
  (`WriteConsoleInput`). conhost has already rendered the app's escape sequences into that grid,
  so there's **no terminal emulation and no VT parsing**, and input doesn't need window focus. A
  process can attach to only one console, hence the separate worker process (~0.2 s per call).
- **Why not the alternatives:** ConPTY would need a screen emulator (xterm.js headless, pyte) to
  get the same grid; UI Automation on the console window can read text but injects keys through
  the focused window. Nothing suitable exists on the PowerShell Gallery (the only near-match,
  `Expect` 0.0.1, is pipe-based and can't drive a full-screen TUI).
- **Verified 2026-09-19:** `fdg`'s files/directories toggle (prompt, list and preview all change),
  typing to filter, and Neovim (file opens, `<leader>` shows which-key, `:qa{!}{Enter}` exits).
- **Gotchas:**
  - Assert on lasting UI state, not messages: LazyVim's `noice` shows `:version` and friends in a
    popup that fades before the next read.
  - Give redraws time with `-SettleMilliseconds` (250 default; 600+ for fzf reloads, 1500 for
    Neovim popups), or better, `Wait-ConsoleText`.
  - It reads the visible window, not scrollback, and text only (no colours).
  - PowerShell variable names are case-insensitive: inside the worker, a `$out` handle would
    silently clobber an `$Out` parameter (it wrote the screen to a file named after the handle
    before that was fixed).

## Neovim / LazyVim (set up by hand on 2026-09-19; config not managed yet)

The `neovim` workload handles the prerequisites; the LazyVim config itself was installed manually
with the steps below. Paths: config `%LOCALAPPDATA%\nvim` (the LazyVim starter, `.git` removed),
data `%LOCALAPPDATA%\nvim-data` (plugins in `lazy\`, parsers in `site\parser`, Mason in `mason\`).
The earlier `nvim-data` (only shada/swap from Neovim 0.10) is at `nvim-data.bak`.

- **Neovim version:** an old winget MSI Neovim 0.10.3 (`C:\Program Files\Neovim`, machine PATH)
  shadowed Scoop's 0.12.5 (user PATH). LazyVim needs 0.11.2+. The workload uninstalls the MSI
  (`Neovim.Neovim`, `_exist: false`); Scoop's is the only one.
- **CLI tools** (fzf, ripgrep, fd, lazygit, tree-sitter, ast-grep) come from mise's global config
  (`~\.config\mise\config.toml`, alongside the user's `node`). mise's `windows_shim_mode` is `exe`
  (real executables, which plugins can spawn directly, unlike `.cmd` shims), and the workload puts
  `%LOCALAPPDATA%\mise\shims` on the user PATH, since `mise activate` only happens in PowerShell 7
  profiles. mise activation now lives in the `shell` workload's
  `profile.d\00-mise.ps1` (PowerShell 7 only: on 5.1 `mise activate` printed "chpwd functionality
  requires PowerShell version 7" on every start, which snacks' health surfaced; 5.1 uses the shims).
- **Install steps** (through the unsandboxed runner above):
  1. Move `nvim` / `nvim-data` aside, `git clone https://github.com/LazyVim/starter
     %LOCALAPPDATA%\nvim`, delete its `.git`.
  2. `nvim --headless "+Lazy! sync" +qa` (33 plugins, ~15 s).
  3. Parsers and LSP: a Lua script run with `nvim --headless "+luafile ..." +qa!`:
     `require('nvim-treesitter').install(LazyVim.opts('nvim-treesitter').ensure_installed):wait(...)`
     (23 languages), and Mason's `lua-language-server`. **Wait on Mason's install callback**
     (`pkg:install({}, function(success) ... end)`, then `vim.wait` on a flag): polling
     `is_installed()` returned true while the install was still running, and quitting aborted it
     ("Neovim exited while the following packages were installing").
- **Health checks headless:** `:LazyHealth` wrote an empty buffer (the checks run async in 0.12).
  This works: `nvim --headless "+Lazy! load all" "+checkhealth" "+sleep 15" "+w! <file>" "+qa!"`.
  Headless artifacts to ignore: snacks' "setup did not run", "`vim.ui.input`/`vim.ui.select` not
  set", "is not ready" (snacks sets these up with a UI).
- **C compiler / tree-sitter parsers:** nvim-treesitter (main) builds parsers with `tree-sitter
  build`, whose `cc` crate finds MSVC by itself (vswhere): with gcc hidden, no `CC` and no `cl` on
  PATH, nvim-treesitter built and loaded parsers with VS 2026's MSVC (linker 14.51). But LazyVim's
  pre-check (`lua/lazyvim/util/treesitter.lua`, `M.check`/`win_find_cl`) only accepts `$CC`,
  `cl`/`gcc` on PATH, or `cl.exe` under `C:\Program Files (x86)\Microsoft Visual Studio` (the
  standalone Build Tools), so VS 2022/2026 in `C:\Program Files` fails it and LazyVim skips
  installing parsers. Workarounds tested: `CC=<path to cl.exe>` **breaks** the build (bypasses
  the crate's environment setup: `stdio.h` not found); MSVC's bin dir on PATH works but also puts
  `link`, `lib`, `nmake`, ... on PATH. Chosen: WinLibs gcc (winget, LazyVim's own suggestion);
  with gcc on PATH LazyVim sets `CC=gcc`. Upstream fix (find cl.exe via vswhere): LazyVim PR #7257,
  https://github.com/LazyVim/LazyVim/pull/7257 (opened 2026-09-19). If merged, gcc is no longer needed
  for LazyVim on machines with Visual Studio.
- **Providers** (`vim.provider` health is all green): the `neovim` workload installs each, and
  `%LOCALAPPDATA%\nvim\lua\config\options.lua` (edited by hand) pins them on Windows:
  `g:python3_host_prog` = `stdpath('data')/python-provider/Scripts/python.exe` (a `uv venv` with
  pynvim; `python3` on PATH used to be App Installer's Store stub, which the `python` workload now
  removes), `g:node_host_prog` = `$APPDATA/npm/node_modules/neovim/bin/cli.js` (installed with the
  winget Node's `npm.cmd` explicitly, since activated PowerShell puts mise's node first; Neovim
  runs `node <cli.js>`), Ruby found via `neovim-ruby-host.bat` on PATH (the `neovim` gem in the
  ruby workload's Ruby 3.4), and `g:loaded_perl_provider = 0` (mise's Perl,
  skaji/relocatable-perl, has no Windows builds; the user chose no Perl).
- **Old Ruby 3.2.4** (RubyInstaller, installed by hand for the user only) was uninstalled with
  winget, which refuses user-scope packages from an elevated session ("cannot be uninstalled when
  running with administrator privileges"): run it unelevated. Its silent uninstaller left
  `C:\Ruby32-x64\msys64` (865 MB) behind; the user was told to delete it.
- **lazy.nvim's hererocks** (`stdpath('data')\lazy-rocks\hererocks`, Lua 5.1.5 + LuaRocks 3.8.0) is
  prebuilt by the workload with `uvx hererocks <root> -l 5.1 -r latest --target mingw`:
  - It failed with "couldn't run install.bat /?: is install.bat in PATH?" only because **Claude's
    shells set `NoDefaultCurrentDirectoryInExePath=1`** (the user's environment doesn't), which
    stops Windows from finding programs in the current directory. Not a Python 3.12+ issue (it
    failed on 3.11 too). Clear the variable before running things that rely on it.
  - hererocks can't build newer LuaRocks on Windows (`-r 3.12.2` silently skipped it).
  - LuaRocks 3.8.0 links C rocks with `-lMSVCR80`, so they build but fail to load ("The specified
    module could not be found"). `luarocks config --scope system variables.MSVCRT ucrt` (stored in
    hererocks' own `luarocks\config-5.1.lua`) makes it link `-lucrt`, matching WinLibs; lpeg then
    built and loaded. Without `--scope system` it writes the per-user `%APPDATA%\luarocks` config.
  - lazy's health still reports "`.../hererocks/bin/luarocks` not installed": a lazy.nvim bug on
    Windows. Its install path appends `.bat` (`lua/lazy/pkg/rockspec.lua`, ~line 155) but its
    health check doesn't (~line 80). Harmless. Upstream fix: lazy.nvim PR #2185,
    https://github.com/folke/lazy.nvim/pull/2185 (opened 2026-09-19).
- **Upstream work** happens in clones under `~\src\upstream` (LazyVim, lazy.nvim), with `origin` =
  upstream and `fork` = the user's fork; `gh` (mise global config, signed in by the user with
  SSH) opened the PRs. Clones use `core.autocrlf=true`, so check formatting on an LF copy of
  the file (`stylua --check`; Mason's stylua), not the CRLF working file.
- **Remaining health warnings, judged harmless:** Mason's missing unzip/wget/gzip/7z/php/julia
  (it unpacked lua-language-server fine with Windows' own tools); lazy's luarocks error (see
  hererocks above); `site\pack\core` existing packages / vim.pack lockfile (an empty
  folder Neovim 0.12's built-in `vim.pack` creates); snacks' image tools (kitty/wezterm/ghostty
  graphics, magick, gs, tectonic, mmdc: Windows Terminal lacks the kitty graphics protocol);
  conform's `fish_indent`; blink.cmp's first-run "fuzzy lib not downloaded" (it downloads on
  first start; fine afterwards).

## Open threads (as of 2026-09-19)

- **The user intends to use bat and eza from PowerShell** ("shortly"). Both are installed by the
  `shell` workload; nothing uses them yet beyond fzf previews. That's a new `profile.d` snippet
  (aliases, `$env:BAT_THEME`, an `eza`-based `ls`), not a workload change. Ask what they want
  aliased before replacing built-ins like `ls`/`cat`.
- **Upstream PRs are open and unreviewed:** LazyVim #7257 (find MSVC via vswhere) and lazy.nvim
  #2185 (hererocks' `luarocks.bat` in the health check). If #7257 is merged, WinLibs gcc is no
  longer needed for LazyVim on machines with Visual Studio; if #2185 is merged, lazy's luarocks
  health error goes away. Branches live in `~\src\upstream\{LazyVim,lazy.nvim}` with `fork` =
  the user's fork.
- **The LazyVim config itself isn't managed** (see the Neovim section). The `profile.d` mechanism
  in the `shell` workload is the obvious model for it: files in the repo, copied out, with a
  managed-file header.
- **Not re-checked since KB5066791:** WSL/WSLg on this machine. Routine runs still use `-SkipWsl`.
- **Left for the user to delete:** `C:\Ruby32-x64\msys64` (865 MB), orphaned by the Ruby 3.2
  uninstall.
- **`tools\PtyHarness` runs programs under a pseudo console** and renders the VT stream with
  libghostty-vt in wasmtime, for when genuine terminal behaviour matters (reflow, scrollback, VT
  semantics) rather than conhost's rendering of it. Mouse there needs no per-application choice:
  send SGR and the console host adapts. **It hosts the pty with Windows Terminal's OpenConsole**,
  not `CreatePseudoConsole`, because the inbox conhost on this machine forwards no mouse at all;
  the host binary is copied to `tools\PtyHarness\lib` since Windows refuses to execute anything
  inside `WindowsApps` from outside the package. `Get-PtyScreen` gives the
  viewport and `-Scrollback` the history (the formatter emits both together, so the split comes
  from asking the terminal how many rows scrolled off). **Terminal queries still go unanswered**,
  and the obvious fix is blocked: a host function can be installed in the module's
  `__indirect_function_table` and accepted as the callback, but invoking it crashes the process
  outright - reproduced from PowerShell and from plain C#, so don't assume it's the binding.
- **`tools\ConsoleHarness` now makes TUI behaviour testable** (fzf, Neovim), so verify interactive
  changes yourself instead of asking the user to try them.

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
- 2026-09-19: switched to DSC v3; the new registry tweaks applied, and all nine workloads were
  installed (VS 2026 Community 18.10.1 with NativeDesktop, ManagedDesktop, Universal; .NET 10
  SDK, OpenJDK 25, Python 3.14, Node LTS + tsc, rustup/stable 1.98.1 — `cargo run` links fine).
  The VS C++ modify asked for a restart (3010). A full `-SkipWsl` re-run with workloads changes
  nothing.
