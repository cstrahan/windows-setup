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
  `configuration/windows.dsc.yaml` with `dsc config set --output-format json`
  (`Invoke-DscConfiguration`: stdout is parsed into a changed/unchanged summary, stderr traces go
  to the console), then matching hardware profiles (`configuration/hardware.psd1`), then the
  workloads (`configuration/workloads.psd1` + `configuration/workloads/*.dsc.yaml`;
  `Resolve-Workloads` orders them by `Requires`), then sets up WSL 2, the distro, and uv +
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
  two method arguments; compute it into a variable first.
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
    Microsoft.Adapter/PowerShell` (discovery). The workloads and hardware profile test fine
    unelevated; `windows.dsc.yaml` fails because `WindowsCapability`'s DISM calls need admin.
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
- **Installer logs** for packages winget installs are next to winget's own logs in
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
- **Probing dsc without UAC:** write a throwaway config under `logs/` with a
  `Microsoft.DSC.Transitional/PowerShellScript` resource whose scripts write diagnostics, and run
  `dsc config set --file logs\x.dsc.yaml --output-format json` directly from your shell.
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
- 2026-09-19: switched to DSC v3; the new registry tweaks applied, and all nine workloads were
  installed (VS 2026 Community 18.10.1 with NativeDesktop, ManagedDesktop, Universal; .NET 10
  SDK, OpenJDK 25, Python 3.14, Node LTS + tsc, rustup/stable 1.98.1 — `cargo run` links fine).
  The VS C++ modify asked for a restart (3010). A full `-SkipWsl` re-run with workloads changes
  nothing.
