# windows-setup

Declarative setup for a fresh Windows 10+ install. Run it right after creating and
logging in as your user:

```bat
bootstrap.cmd
```

It asks for elevation once and is safe to re-run. If it says a reboot is required,
reboot and run it again.

## How it works

1. **`bootstrap.cmd`** runs `bootstrap.ps1`, bypassing the execution policy.
2. **`bootstrap.ps1`** (stage 1, PowerShell) elevates, registers winget if needed, installs
   [uv](https://docs.astral.sh/uv/) into `%USERPROFILE%\.local\bin` if needed, then runs
   `configure.py` with `uv run`. uv provides Python, so none has to be installed.
3. **`configure.py`** (stage 2, Python):
   - applies `configuration/windows.dsc.yaml` with `winget configure`
   - enables WSL 2 (reboot required the first time), installs the distro (default
     `Ubuntu`, the latest LTS; you create the Linux user interactively)
   - installs uv in the distro, and `ansible-core` plus the `ansible` collections as a uv tool

Arguments to `bootstrap.cmd` pass through to `configure.py`:
`--skip-winget`, `--skip-wsl`, `--distro NAME`.

## Configuration

`configuration/windows.dsc.yaml` is a [WinGet Configuration](https://aka.ms/winget-configure)
file. Most resources come from the PowerShell Gallery. Where those fall short, this repo has
its own class-based resources in `dsc/WindowsSetupDsc` (`WindowsCapability`, `GitForWindows`),
so winget needs `--module-path` pointing at `dsc`. It must be an absolute path. To check for
drift without changing anything, from the repo root:

```bat
winget configure test --file configuration\windows.dsc.yaml --module-path %CD%\dsc
```

Currently configured:

- OpenSSH Client capability installed.
- `ssh-agent` service: startup type Automatic, and running.
- `RealTimeIsUniversal = 1`: the hardware clock is kept in UTC. Takes effect after a reboot.
- Explorer Folder Options (current user): show hidden files, show file extensions, show
  empty drives, full path in the title bar. Restart Explorer or sign out to see them.
- Visual Studio Code and Windows Terminal installed.
- Git for Windows, latest version, with pinned installer choices: Explorer integration, editor,
  Windows OpenSSH, line endings, etc. Changing a choice re-runs the installer.

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
