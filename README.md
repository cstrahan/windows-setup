# windows-setup

Declarative setup for a fresh Windows 10+ install. Run it right after creating and
logging in as your user. No clone needed; in Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/cstrahan/windows-setup/main/install.ps1 | iex
```

Start it from a **normal (non-admin)** prompt: it installs some things as you first, then asks
for elevation once for the rest, and refuses to run if started elevated. It's safe to re-run.
The first run on a new machine needs one restart, for WSL: it tells you, you restart when you're
ready (use **Restart**, not Shut down), and setup continues by itself after you sign in again,
with one more UAC prompt.

`install.ps1` resolves `main` to a commit, downloads that commit's zip from GitHub into
`%LOCALAPPDATA%\windows-setup\<commit>` (reused if already there; the three most recently
used commits are kept), and runs its `bootstrap.ps1`. To pass options, such as a different
branch, tag or commit (`-Ref`), or bootstrap arguments (see below):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cstrahan/windows-setup/main/install.ps1))) -Ref main -SkipWsl
```

From a clone, run `bootstrap.cmd` directly instead.

## How it works

1. **`bootstrap.cmd`** runs `bootstrap.ps1`, bypassing the execution policy.
2. **`bootstrap.ps1`** (stage 1, in Windows PowerShell 5.1, which is all a fresh install has):
   - unelevated section: installs [Scoop](https://scoop.sh) for the current user, so it's owned by
     you rather than Administrators, then the Scoop apps listed in `$ScoopApps` (currently
     [mise](https://mise.jdx.dev) and [Neovim](https://neovim.io)) if they aren't installed yet
   - relaunches itself elevated (one UAC prompt) for the elevated section:
     - registers winget if needed, and upgrades it
     - installs the Visual C++ runtime if it's missing, and installs or upgrades
       [DSC v3](https://learn.microsoft.com/powershell/dsc/overview) (`dsc`, via winget)
     - installs or upgrades PowerShell 7 (the MSI, via winget)
     - runs `configure.ps1` in PowerShell 7
3. **`configure.ps1`** (stage 2, PowerShell 7):
   - logs a preflight line (Windows build, winget, PowerShell, free disk space), with a warning
     if Windows is missing updates that WSLg needs or hardware virtualization is off
   - applies, with `dsc config set`, any matching hardware profiles, then the selected
     workloads, printing what each one changed; then checks that what they installed (`scoop`
     plus the workloads' commands) is on PATH
   - enables WSL 2, installs the distro (default `Ubuntu`, the latest LTS; you create the Linux
     user interactively). Installing the WSL platform needs a restart, see below
   - installs uv in the distro, and `ansible-core` plus the `ansible` collections as a uv tool

Arguments to `bootstrap.cmd` pass through to `configure.ps1`: `-SkipDsc` (skip all DSC
configurations), `-Workloads a,b` (exactly these instead of the enabled list),
`-ExcludeWorkloads a,b`,
`-SkipWsl`, `-Distro NAME`. (`-Resumed` is for the resume task below.)

### Restarting for WSL

The WSL platform (its Windows features) only becomes active after a restart. When one is needed,
`bootstrap.ps1` registers a scheduled task, `\windows-setup\Resume after restart`, that runs the
bootstrap again at your next sign-in, as you, 30 seconds after logon, with the same arguments plus
`-Resumed`. It never restarts the machine itself. The resumed run asks for UAC as usual and
removes the task. If you decline the prompt, it tries again at the following sign-in; run bootstrap
yourself or delete the task to stop that.

Only one restart is expected. If WSL still isn't active after it and no restart is pending, the
resumed run stops and says why, usually hardware virtualization turned off in the BIOS/UEFI,
instead of asking for another. When the Microsoft Store route fails, `wsl --update` and the
distro install are retried with `--web-download`. (Adapted from microsoft/WindowsDeveloperConfig,
which instead forces a restart after a 10-second warning.)

## Configuration

The configurations are [DSC v3](https://learn.microsoft.com/powershell/dsc/overview) documents.
Most resources are DSC's and winget's built-in ones (`Microsoft.Windows/Registry`,
`Microsoft.Windows/Service`, `Microsoft.WinGet/Package`, `Microsoft.DSC.Transitional/PowerShellScript`).
Where those fall short, this repo has its own class-based PowerShell resources in `dsc/`, one
module each: `WindowsSetup.WindowsCapability`, `.ScheduledTask`, `.DriverPackage`, `.DriverInstaller`, `.NvidiaDriver`, `.GitForWindows`, `.GoLang`,
`.KeyboardRepeat`, `.PrecisionTouchpad`, `.VisualStudioComponents` (plus `WindowsSetup.Common`,
shared code). DSC finds them through `PSModulePath`, which `configure.ps1` sets. To check a
configuration for drift without changing anything, in an elevated PowerShell 7 at the repo root:

```powershell
$env:PSModulePath = "$PWD\dsc;$env:PSModulePath"
dsc config test --file configuration\workloads\explorer.dsc.yaml
```

(`dsc config set --what-if` shows what a run would do.)

### Workloads

Everything is a workload: a configuration in `configuration/workloads/<name>.dsc.yaml`, listed in
`configuration/workloads.psd1` with a description, the workloads it requires (applied first) and
the commands it should put on PATH. `Enabled` there picks which ones run (currently all of
them). For one run, `-Workloads go,rust` applies exactly those (plus what they require), and
`-ExcludeWorkloads remote-desktop,taskbar` leaves some out. Excluding something another selected
workload requires is an error, as is excluding `core`, which always runs.

**Windows**

| Workload | What it does |
|---|---|
| `core` (always) | Windows PowerShell's execution policy `RemoteSigned` for the current user, so local scripts like Scoop's `scoop.ps1` shim can run. (PowerShell 7 already defaults to it.) |
| `ssh` | OpenSSH Client capability installed; `ssh-agent` service Automatic and running. |
| `time` | `RealTimeIsUniversal = 1`: the hardware clock is kept in UTC (after a reboot). The Windows Time service stays running, and a scheduled task (`\windows-setup\Resync time`) runs `w32tm /resync` whenever a network connects or the machine resumes. Otherwise Windows waits for its next poll, which can be hours away, before correcting the clock after sleep, hibernation or Fast Startup. |
| `system` | Developer Mode, Win32 long paths, `sudo` in inline mode (Windows 11 24H2+). |
| `remote-desktop` | Remote Desktop allowed. The firewall rule is left closed, so it isn't reachable from the network until you enable it (as in microsoft/WindowsDeveloperConfig). |
| `explorer` | For the current user: hidden files and file extensions shown, empty drives shown, full path in the title bar, opens to This PC, Quick Access without frequent folders, recent files, cloud files or sync-provider ads. Restart Explorer or sign out to see them. |
| `taskbar` | "End task" in the taskbar's right-click menu (Windows 11 23H2+); no web results or search highlights in search; no Start recommendations (Windows 11); no Widgets or News and Interests. |
| `keyboard` | Shortest repeat delay, fastest repeat rate (applied immediately). Caps Lock acts as an extra Left Ctrl on every keyboard, after a restart: Windows' remapping (`Scancode Map`) applies to all keyboards and is read at boot. |

Settings marked Windows 11 are harmless on Windows 10: they're just registry values nothing reads.

**Tools**

| Workload | What it does |
|---|---|
| `terminal` | Windows Terminal. |
| `vscode` | Visual Studio Code (it updates itself, so only its presence is managed). |
| `git` | Git for Windows, latest version, with pinned installer choices: Explorer integration, VS Code as editor, Windows OpenSSH, line endings, a Terminal profile, etc. Changing a choice re-runs the installer. Requires `ssh`, `vscode`, `terminal`. |
| `go` | Go, latest stable release (at least 1.27.1), from go.dev's official MSI (checksum-verified). |
| `uv` | uv, the Python package and project manager. |
| `neovim` | Prerequisites for [LazyVim](https://www.lazyvim.org): fzf, ripgrep, fd, lazygit, tree-sitter and ast-grep in mise's global config (with mise's shims on PATH), WinLibs gcc for tree-sitter parsers, JetBrainsMono Nerd Font as Windows Terminal's default font, Neovim's providers (a uv venv with pynvim, the `neovim` npm package and gem), lazy.nvim's Lua 5.1 + LuaRocks (hererocks), and removes an old winget/MSI Neovim that shadowed Scoop's. Neovim itself is a Scoop app; the LazyVim config isn't managed yet. Requires `git`, `uv`, `node`, `ruby`. |

**Development stacks**, adapted from
[microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig)'s workloads:

| Workload | What it does |
|---|---|
| `visualstudio` | Visual Studio 2026 Community (required by `rust`, `winforms`, `winui`). |
| `dotnet` | .NET 10 SDK. |
| `java` | Microsoft Build of OpenJDK 25. |
| `python` | Python 3.14 (with the `py` launcher), and removes App Installer's `python.exe`/`python3.exe` App execution aliases (Microsoft Store placeholders that `python3` otherwise resolves to). |
| `node` | Node.js LTS (winget, machine-wide). |
| `typescript` | TypeScript (`tsc`) globally via npm. Requires `node`. |
| `ruby` | Ruby 3.4 (RubyInstaller) with the MSYS2 devkit. |
| `rust` | rustup with the stable toolchain as default, and Visual Studio's C++ workload for the MSVC linker and Windows SDK. |
| `powershell` | VS Code's PowerShell and Pester extensions, and PSScriptAnalyzer settings with the recommended rules. |
| `winforms` | Visual Studio's .NET desktop workload (plus `system`, for Developer Mode). |
| `winui` | Visual Studio's .NET desktop, UWP and Windows App SDK (C#) components, the `winapp` CLI and the Windows App Runtime 1.6 (plus `system`, for Developer Mode). |
### Hardware profiles

`configuration/hardware.psd1` lists extra configurations that apply only to matching
hardware. Profiles match on the machine's vendor, model and version, and optionally on a
present device's hardware ID. Before the workloads, `configure.ps1` applies every profile
that matches, and logs the ones it skips. Currently:

- **System76 Gazelle (gaze16)**: the two drivers System76 lists for it in
  [system76/windows-drivers](https://github.com/system76/windows-drivers), Intel's chipset INFs
  (10.1.34.8 for the Tiger Lake PCH-H) and Serial IO (30.100.2104.1: I2C, UART, GPIO, SPI), plus
  the Intel HID Event Filter 2.2.1.386 from its gaze17 list (without it the `INT33D5` device has
  no driver; Windows Update only offers a 2016 build). Windows Update doesn't install these.
  Also Intel's graphics driver for its UHD Graphics (32.0.101.7088, from Intel's 11th-14th gen
  download; `WindowsSetup.DriverInstaller` runs Intel's installer silently, pinned by SHA-256).
- **Any NVIDIA GPU**: the latest Game Ready driver (NVIDIA's standard package, including the
  NVIDIA App), found through the same driver lookup NVIDIA's own software uses, so every run
  updates it when NVIDIA releases a new one. `Studio: true` in `hardware/nvidia.dsc.yaml` tracks
  the Studio branch instead. Also disables the `NVIDIA Platform Controllers and Framework`
  stand-in device the installer creates on laptops whose firmware lacks Dynamic Boost support
  (it fails with code 31 otherwise). `WindowsSetup.DriverPackage` downloads each zip (pinned to
  a commit and a SHA-256, cached in `%ProgramData%\windows-setup\drivers`) and installs its INFs
  with `pnputil`, only where a device's driver is older, so a newer driver from Windows Update
  stays.
- **System76 Gazelle (gaze16) with the ELAN0412 touchpad**: turns off touchpad tapping
  (tap to click, two-finger tap to right-click, tap-and-drag), since the touchpad has
  dedicated buttons.

`PrecisionTouchpad` covers every user setting in Windows' touchpad API
(`TOUCHPAD_PARAMETERS`): taps, the right-click zone, two-finger scroll and zoom, scrolling
direction, sensitivity, cursor speed, and on newer hardware haptics. See the property comments
in `dsc/WindowsSetup.PrecisionTouchpad/WindowsSetup.PrecisionTouchpad.psm1`.

**Touchpad settings on Windows 10 take effect at the next sign-in.** Windows 11 24H2 added an
API for applying them immediately (`SPI_SETTOUCHPADPARAMETERS`), and `PrecisionTouchpad` uses
it where available. Windows 10 has no equivalent: restarting the touchpad device or Explorer
doesn't apply them. Sign out and back in instead. Windows 10 also only supports the settings
its Settings app has. The haptics settings, click force, right-click zone size and
`HonorMouseAccelSetting` fail there with an error saying they need Windows 11 24H2.

## Troubleshooting

**`WslRegisterDistribution failed with error: 0x80080005` (Server execution failed)**, usually
after a long delay. Windows couldn't start the WSL service. Common causes:

- The WSL optional component isn't installed. The Store WSL package can be installed without
  it, and then the `LxssManager` service doesn't exist. `wsl --status` reports
  `WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED`. The bootstrap installs it; reboot when asked.
  The features can already show as *Enabled* while their installation is still waiting for a
  restart. With Fast Startup on, "Shut down" never completes the install, so use **Restart**.
- The service is hung or crashed. Before touching distros, the bootstrap runs `wsl --status`
  with a timeout. If that fails, it runs `wsl --shutdown`, force-restarts `WSLService` and
  `LxssManager`, and checks again. If WSL still doesn't respond, reboot and re-run.

**"WSL still isn't active after restarting, and no restart is pending"**: the resumed run found
the WSL platform inactive (no Hyper-V Host Compute Service, `vmcompute`) even though Windows
has nothing left to install. Usually hardware virtualization is off: enable Intel VT-x / AMD-V
("SVM") in the BIOS/UEFI settings, or nested virtualization for a VM, then run bootstrap again.
If virtualization is on, WSL's package probably couldn't be downloaded; check the network.

**Setup didn't resume after restarting**: check the task with
`schtasks /query /tn "\windows-setup\Resume after restart"`. It runs at sign-in, not at boot,
and only once you approve its UAC prompt. You can always just run bootstrap again.
