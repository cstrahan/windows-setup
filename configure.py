# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Stage 2 of the windows-setup bootstrap (run by bootstrap.ps1 via `uv run`).

Every step checks current state before acting, so this is safe to re-run. Some steps
(enabling WSL) need a reboot; in that case we exit with EXIT_REBOOT_REQUIRED and the
bootstrap should simply be run again after rebooting.
"""

from __future__ import annotations

import argparse
import ctypes
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
import time
import tomllib
import winreg
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WINGET_CONFIG = ROOT / "configuration" / "windows.dsc.yaml"
# Extra winget configurations applied only on matching hardware.
HARDWARE_PROFILES = ROOT / "configuration" / "hardware.toml"
# Our own DSC modules (e.g. WindowsSetupDsc). Passed as winget's --module-path, so modules
# winget downloads from the PowerShell Gallery also land here (they're git-ignored).
DSC_MODULES = ROOT / "dsc"

DEFAULT_DISTRO = "Ubuntu"  # tracks the latest Ubuntu LTS
ANSIBLE_CORE_SPEC = "ansible-core>=2.19"
ANSIBLE_SPEC = "ansible>=12"  # the community collections, incl. ansible.windows
MIN_WINGET = (1, 6)  # `winget configure` went GA in 1.6
WINGET_UPDATE_NOT_APPLICABLE = 0x8A15002B  # `winget upgrade`: already the latest version
WSL_FEATURES = ("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
EXIT_REBOOT_REQUIRED = 3010  # same meaning as msiexec/dism's ERROR_SUCCESS_REBOOT_REQUIRED
CBS_REBOOT_PENDING_KEY = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
WSL_PROBE_TIMEOUT = 60  # seconds; a healthy `wsl --status` returns in well under this
WSL_RESET_TIMEOUT = 120

# Force-restarts the WSL services: WSLService (Store WSL) and LxssManager (the optional
# component). A hung service is killed outright, but only if it has its svchost to itself.
WSL_RESET_SCRIPT = """\
$ErrorActionPreference = 'Continue'
foreach ($name in 'WSLService', 'LxssManager') {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
    if (-not $svc -or $svc.ProcessId -eq 0) { continue }
    $shared = @(Get-CimInstance Win32_Service -Filter "ProcessId=$($svc.ProcessId)").Count
    if ($shared -eq 1) { Stop-Process -Id $svc.ProcessId -Force } else { Stop-Service $name -Force }
}
if (Get-Service WSLService -ErrorAction SilentlyContinue) { Start-Service WSLService }
"""

# Asks wsl.exe for UTF-8 output instead of UTF-16LE (older builds ignore it; see decode()).
WSL_ENV = {**os.environ, "WSL_UTF8": "1"}

WSL_PROVISION_SCRIPT = """\
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
uv tool install {core} --with {ansible}
ansible --version
"""


class RebootRequired(Exception):
    pass


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def run(cmd: list[str], *, check: bool = True, capture: bool = False, input: bytes | None = None,
        env: dict[str, str] | None = None, timeout: float | None = None) -> subprocess.CompletedProcess[bytes]:
    if not capture:
        print(f"  $ {subprocess.list2cmdline(cmd)}", flush=True)
    return subprocess.run(cmd, check=check, capture_output=capture, input=input, env=env, timeout=timeout)


def decode(data: bytes) -> str:
    # wsl.exe writes UTF-16LE unless it honours WSL_UTF8.
    if b"\x00" in data:
        return data.decode("utf-16-le", errors="replace")
    return data.decode("utf-8", errors="replace")


def wsl(args: list[str], **kwargs) -> subprocess.CompletedProcess[bytes]:
    return run(["wsl.exe", *args], env=WSL_ENV, **kwargs)


# --- winget configuration --------------------------------------------------------------

def winget_version(attempts: int = 12, delay: float = 5.0) -> str:
    # Right after winget upgrades itself, its app execution alias can briefly fail to launch
    # (WinError 1920) while the new package registers, so retry for up to a minute.
    for attempt in range(attempts):
        try:
            return decode(run(["winget", "--version"], capture=True).stdout).strip()
        except FileNotFoundError:
            sys.exit("error: winget not found; update 'App Installer' from the Microsoft Store")
        except (OSError, subprocess.CalledProcessError) as e:
            if attempt == attempts - 1:
                raise
            log(f"winget not ready yet ({e}); retrying in {delay:.0f}s")
            time.sleep(delay)
    raise AssertionError("unreachable")


def ensure_winget_current() -> None:
    """Upgrades winget (App Installer) to the latest release.

    winget configure downloads the latest DSC modules from the PowerShell Gallery, and
    Microsoft.WinGet.DSC only loads in the PowerShell host of a matching winget: e.g. winget 1.9
    hosts PowerShell 7.2 (.NET 6), while current Microsoft.WinGet.DSC needs .NET 8.
    """
    log("Ensuring winget is up to date")
    before = winget_version()
    result = run(["winget", "upgrade", "--id", "Microsoft.AppInstaller", "--exact", "--source", "winget",
                  "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"],
                 check=False)
    code = result.returncode & 0xFFFFFFFF
    # Upgrading winget replaces the running winget, which then typically exits with E_ABORT,
    # so judge success by the version afterwards.
    version = winget_version()
    if version == before and code not in (0, WINGET_UPDATE_NOT_APPLICABLE):
        log(f"warning: upgrading App Installer failed (0x{code:08X}); continuing with winget {version}")
    elif version != before:
        log(f"winget upgraded: {before} -> {version}")

    m = re.match(r"v?(\d+)\.(\d+)", version)
    if not m or tuple(map(int, m.groups())) < MIN_WINGET:
        sys.exit(f"error: winget {version} is too old; need >= {'.'.join(map(str, MIN_WINGET))}")
    log(f"winget {version}")


def apply_winget_configuration(config: Path) -> None:
    log(f"Applying winget configuration {config.relative_to(ROOT)}")
    # PSModulePath isn't inherited by winget's elevated configuration server; --module-path is.
    run(["winget", "configure", "--file", str(config), "--module-path", str(DSC_MODULES),
         "--accept-configuration-agreements", "--disable-interactivity"])


# --- hardware profiles -----------------------------------------------------------------

# Machine identity (Win32_ComputerSystemProduct) and the hardware IDs of present devices.
HARDWARE_QUERY = """\
$product = Get-CimInstance Win32_ComputerSystemProduct
[pscustomobject]@{
    vendor  = $product.Vendor
    model   = $product.Name
    version = $product.Version
    devices = @(Get-PnpDevice -PresentOnly | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
} | ConvertTo-Json -Compress
"""


def detect_hardware() -> dict:
    out = run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", HARDWARE_QUERY], capture=True)
    return json.loads(decode(out.stdout))


def profile_matches(profile: dict, hardware: dict) -> bool:
    """All criteria the profile gives must match; values are case-insensitive globs."""
    def glob(value: str | None, pattern: str) -> bool:
        return fnmatch.fnmatchcase((value or "").lower(), pattern.lower())

    for key in ("vendor", "model", "version"):
        if key in profile and not glob(hardware[key], profile[key]):
            return False
    if "device" in profile and not any(glob(d, profile["device"]) for d in hardware["devices"]):
        return False
    return True


def ensure_hardware_configuration() -> None:
    profiles = tomllib.loads(HARDWARE_PROFILES.read_text(encoding="utf-8")).get("profile", [])
    hardware = detect_hardware()
    log(f"Hardware: {hardware['vendor']} {hardware['model']} ({hardware['version']})")
    for profile in profiles:
        if profile_matches(profile, hardware):
            log(f"Hardware profile matches: {profile['name']}")
            apply_winget_configuration(HARDWARE_PROFILES.parent / profile["config"])
            if "note" in profile:
                log(f"Note: {profile['note']}")
        else:
            log(f"Hardware profile doesn't match, skipping: {profile['name']}")


# --- WSL -------------------------------------------------------------------------------

def optional_feature_state(name: str) -> str:
    """Returns e.g. 'Enabled', 'Disabled' or 'EnablePending' (not localized)."""
    ps = f"(Get-WindowsOptionalFeature -Online -FeatureName '{name}').State.ToString()"
    out = run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps], capture=True)
    return decode(out.stdout).strip()


def registered_distros() -> set[str]:
    result = wsl(["--list", "--quiet"], check=False, capture=True)
    if result.returncode != 0:  # also non-zero when no distros are installed
        return set()
    return {line.strip() for line in decode(result.stdout).splitlines() if line.strip()}


def distro_version(distro: str) -> int | None:
    out = decode(wsl(["--list", "--verbose"], capture=True).stdout)
    for line in out.splitlines()[1:]:
        fields = line.replace("*", " ").split()
        if len(fields) >= 3 and fields[0] == distro:
            return int(fields[-1])
    return None


def servicing_reboot_pending() -> bool:
    """True when Windows has staged component changes (e.g. optional features) that need a restart."""
    try:
        winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, CBS_REBOOT_PENDING_KEY).Close()
        return True
    except FileNotFoundError:
        return False


def wsl_status() -> tuple[bool, str]:
    """Runs `wsl --status` with a timeout; returns (ok, output)."""
    try:
        result = wsl(["--status"], check=False, capture=True, timeout=WSL_PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"`wsl --status` did not respond within {WSL_PROBE_TIMEOUT}s")
        return False, ""
    output = decode(result.stdout + result.stderr).strip()
    if result.returncode != 0:
        log(f"`wsl --status` failed ({result.returncode}): {output}")
    return result.returncode == 0, output


def ensure_wsl_responsive() -> None:
    """Guards against a hung/crashed WSL service (e.g. 0x80080005 "Server execution failed")."""
    ok, output = wsl_status()
    if ok:
        return
    if "WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED" in output:
        # The features can report "Enabled" while their installation still awaits a restart.
        if servicing_reboot_pending():
            raise RebootRequired("WSL components are enabled but Windows must restart to finish installing them")
        wsl(["--install", "--no-distribution"], check=False)
        raise RebootRequired("WSL optional components were (re)installed")
    log("WSL is unresponsive; restarting its services")
    try:
        wsl(["--shutdown"], check=False, capture=True, timeout=WSL_PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        pass  # the service is wedged; the reset below deals with it
    try:
        run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", WSL_RESET_SCRIPT],
            check=False, timeout=WSL_RESET_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"restarting the WSL services timed out after {WSL_RESET_TIMEOUT}s")
    if not wsl_status()[0]:
        sys.exit("error: WSL is still unresponsive after restarting its services; "
                 "reboot and re-run (see Troubleshooting in README.md)")


def ensure_wsl(distro: str) -> None:
    log("Ensuring WSL 2 is installed")
    states = {name: optional_feature_state(name) for name in WSL_FEATURES}
    if "EnablePending" in states.values():
        raise RebootRequired(f"WSL features are pending: {states}")

    # The Store-delivered WSL supports --version; the inbox wsl.exe does not.
    store_wsl = wsl(["--version"], check=False, capture=True).returncode == 0
    if any(state != "Enabled" for state in states.values()):
        # Enables the optional components and installs/updates the Store WSL package.
        result = wsl(["--install", "--no-distribution"], check=False)
        log(f"wsl --install exited with {result.returncode}")
        raise RebootRequired("WSL optional components were enabled")
    if not store_wsl:
        wsl(["--update"])

    ensure_wsl_responsive()
    wsl(["--set-default-version", "2"])

    if distro not in registered_distros():
        log(f"Installing {distro}. Create your Linux user when prompted; "
            "if you land in a Linux shell afterwards, type `exit` to continue.")
        wsl(["--install", "--distribution", distro])
        if distro not in registered_distros():
            sys.exit(f"error: {distro} is still not registered with WSL")

    if distro_version(distro) != 2:
        wsl(["--set-version", distro, "2"])


def ensure_wsl_ansible(distro: str) -> None:
    log(f"Ensuring uv and Ansible are installed in {distro}")
    script = WSL_PROVISION_SCRIPT.format(core=shlex.quote(ANSIBLE_CORE_SPEC),
                                         ansible=shlex.quote(ANSIBLE_SPEC))
    # Feed the script over stdin to avoid Windows -> WSL command-line quoting issues.
    wsl(["--distribution", distro, "--cd", "~", "--exec", "bash", "-s"], input=script.encode())


# --- main ------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--skip-winget", action="store_true", help="don't apply the winget configuration")
    parser.add_argument("--skip-wsl", action="store_true", help="don't set up WSL, uv or Ansible in WSL")
    parser.add_argument("--distro", default=DEFAULT_DISTRO, help=f"WSL distribution (default: {DEFAULT_DISTRO})")
    args = parser.parse_args()

    if not ctypes.windll.shell32.IsUserAnAdmin():
        sys.exit("error: must run elevated (use bootstrap.cmd, which elevates for you)")

    try:
        if not args.skip_winget:
            ensure_winget_current()
            apply_winget_configuration(WINGET_CONFIG)
            ensure_hardware_configuration()
        if not args.skip_wsl:
            ensure_wsl(args.distro)
            ensure_wsl_ansible(args.distro)
    except RebootRequired as e:
        log(f"Reboot required ({e})")
        return EXIT_REBOOT_REQUIRED
    except subprocess.CalledProcessError as e:
        print(f"error: {subprocess.list2cmdline(e.cmd)} exited with {e.returncode}", file=sys.stderr)
        return 1

    log("Done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
