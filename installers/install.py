#!/usr/bin/env python3
"""
AI CLI — Python Installer v4.0
Cross-platform installer with auto-detection, version checking, and branch scanning.
"""

import os, sys, shutil, subprocess, platform, tempfile, re, argparse
import json, urllib.request, urllib.error, urllib.parse, time
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
VERSION = "4.0"
REPO_OWNER = "minerofthesoal"
REPO_NAME = "ai-cli"
REPO_URL = f"https://github.com/{REPO_OWNER}/{REPO_NAME}.git"
RAW_URL = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}"
API_URL = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}"
BINARY = "ai"

# ── Colors ────────────────────────────────────────────────────────────────────
if sys.stdout.isatty() and platform.system() != "Windows":
    G = "\033[92m"; Y = "\033[93m"; R = "\033[91m"
    C = "\033[96m"; B = "\033[1m"; D = "\033[2m"; Z = "\033[0m"
else:
    G = Y = R = C = B = D = Z = ""

def ok(m):   print(f"{G}[OK]{Z}  {m}")
def info(m): print(f"{C}[..]{Z}  {m}")
def warn(m): print(f"{Y}[!!]{Z}  {m}")
def err(m):  print(f"{R}[ERR]{Z} {m}", file=sys.stderr)
def die(m):  err(m); sys.exit(1)


# ── Platform Detection ────────────────────────────────────────────────────────
def detect_platform() -> dict:
    """Detect OS, arch, distro, and ARM sub-type."""
    system = platform.system()
    machine = platform.machine().lower()
    arch = {"x86_64": "x86_64", "amd64": "x86_64",
            "arm64": "arm64", "aarch64": "arm64"}.get(machine, machine)

    plat = "linux"
    if system == "Darwin":
        plat = "macos"
    elif system == "Windows" or "MINGW" in os.environ.get("MSYSTEM", ""):
        plat = "windows"
    elif system == "Linux":
        try:
            with open("/proc/version") as f:
                if "microsoft" in f.read().lower():
                    plat = "wsl"
        except OSError:
            pass

    distro = "unknown"
    if os.path.isfile("/etc/os-release"):
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("ID="):
                    distro = line.strip().split("=", 1)[1].strip('"')
                    break

    arm_type = ""
    if arch == "arm64":
        if plat == "macos":
            arm_type = "apple_silicon"
        else:
            for p in ["/proc/device-tree/model", "/sys/firmware/devicetree/base/model"]:
                try:
                    with open(p, "rb") as f:
                        model = f.read().decode(errors="replace").lower()
                    if "raspberry" in model: arm_type = "raspberry_pi"
                    elif "jetson" in model or "tegra" in model: arm_type = "jetson"
                    break
                except OSError:
                    pass
            if not arm_type:
                arm_type = "generic_arm64"

    return {"platform": plat, "arch": arch, "distro": distro, "arm_type": arm_type}


def need_sudo() -> bool:
    if platform.system() == "Windows":
        return False
    return os.geteuid() != 0


def run_cmd(cmd, dry_run=False, check=True, capture=False):
    if dry_run:
        info(f"[dry-run] {' '.join(str(c) for c in cmd)}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    return subprocess.run(cmd, check=check, capture_output=capture, text=True)


# ── Version Helpers ───────────────────────────────────────────────────────────
def fetch_remote_version(branch="main") -> str:
    url = f"{RAW_URL}/{branch}/main.sh"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ai-cli-installer"})
        with urllib.request.urlopen(req, timeout=10) as r:
            for line in r.read().decode().splitlines():
                if line.startswith("VERSION="):
                    return line.split('"')[1]
    except Exception:
        pass
    return ""


def get_installed_version(prefix: Path) -> str:
    ai_bin = prefix / "bin" / BINARY
    if not ai_bin.exists():
        return ""
    try:
        with open(ai_bin) as f:
            for line in f:
                if line.startswith("VERSION="):
                    return line.split('"')[1]
    except Exception:
        pass
    return ""


# ── Download & Install ────────────────────────────────────────────────────────
def download_file(url: str, dest: Path):
    info(f"Downloading {url}...")
    req = urllib.request.Request(url, headers={"User-Agent": "ai-cli-installer"})
    with urllib.request.urlopen(req, timeout=30) as r:
        dest.write_bytes(r.read())


def do_install(prefix: Path, branch: str, dry_run=False):
    info(f"Installing ai-cli to {prefix}/bin/{BINARY}...")
    if dry_run:
        info("[dry-run] Would download and install main.sh")
        return

    tmp = Path(tempfile.mktemp(suffix=".sh"))
    try:
        download_file(f"{RAW_URL}/{branch}/main.sh", tmp)
        if not tmp.stat().st_size:
            die("Downloaded file is empty")

        bin_dir = prefix / "bin"
        share_dir = prefix / "share" / "ai-cli"
        config_dir = Path.home() / ".config" / "ai-cli"

        for d in [bin_dir, share_dir, config_dir]:
            d.mkdir(parents=True, exist_ok=True)

        dest = bin_dir / BINARY
        if need_sudo():
            run_cmd(["sudo", "cp", str(tmp), str(dest)])
            run_cmd(["sudo", "chmod", "755", str(dest)])
        else:
            shutil.copy2(tmp, dest)
            dest.chmod(0o755)

        ok(f"Installed {dest}")

        # Download support files
        for f in ["misc/requirements.txt", "misc/package.json"]:
            try:
                download_file(f"{RAW_URL}/{branch}/{f}",
                              share_dir / Path(f).name)
            except Exception:
                pass

        # Default config
        keys_file = config_dir / "keys.env"
        if not keys_file.exists():
            keys_file.write_text(
                "# AI CLI API Keys\n"
                "# ai keys set OPENAI_API_KEY sk-...\n"
                "# ai keys set ANTHROPIC_API_KEY sk-ant-...\n"
            )
    finally:
        tmp.unlink(missing_ok=True)


def do_uninstall(prefix: Path, dry_run=False):
    targets = [prefix / "bin" / BINARY, prefix / "share" / "ai-cli"]
    for t in targets:
        if t.exists():
            if dry_run:
                info(f"[dry-run] Would remove {t}")
            elif need_sudo():
                run_cmd(["sudo", "rm", "-rf", str(t)])
                ok(f"Removed {t}")
            else:
                if t.is_dir():
                    shutil.rmtree(t)
                else:
                    t.unlink()
                ok(f"Removed {t}")
    warn("Config at ~/.config/ai-cli/ preserved.")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    p = argparse.ArgumentParser(description=f"AI CLI Installer v{VERSION}")
    p.add_argument("--prefix", default="/usr/local", help="Install prefix")
    p.add_argument("--branch", default="main", help="Git branch")
    p.add_argument("--force", action="store_true", help="Force reinstall")
    p.add_argument("--no-deps", action="store_true", help="Skip deps")
    p.add_argument("--cpu-only", action="store_true", help="CPU-only mode")
    p.add_argument("--dry-run", action="store_true", help="Preview only")
    p.add_argument("--uninstall", action="store_true", help="Remove ai-cli")
    p.add_argument("--check", action="store_true", help="Check for updates")
    args = p.parse_args()

    prefix = Path(args.prefix).expanduser().resolve()
    plat = detect_platform()

    print(f"\n{C}{'='*50}{Z}")
    print(f"{B}  AI CLI — Python Installer v{VERSION}{Z}")
    print(f"{C}{'='*50}{Z}\n")
    info(f"Platform: {plat['platform']} | Arch: {plat['arch']} | Distro: {plat['distro']}")
    if plat["arm_type"]:
        info(f"ARM type: {plat['arm_type']}")

    if args.uninstall:
        do_uninstall(prefix, args.dry_run)
        return

    remote_ver = fetch_remote_version(args.branch)
    installed_ver = get_installed_version(prefix)

    if remote_ver:
        info(f"Remote version:    v{remote_ver}")
    if installed_ver:
        info(f"Installed version: v{installed_ver}")

    if args.check:
        if not remote_ver:
            die("Could not fetch remote version")
        if installed_ver == remote_ver:
            ok("Up to date!")
        elif installed_ver:
            warn(f"Update available: {installed_ver} -> {remote_ver}")
        else:
            info("Not installed yet")
        return

    if installed_ver and installed_ver == remote_ver and not args.force:
        ok(f"Already up to date (v{installed_ver}). Use --force to reinstall.")
        return

    do_install(prefix, args.branch, args.dry_run)

    if not args.no_deps and not args.dry_run:
        ai_bin = prefix / "bin" / BINARY
        if ai_bin.exists():
            info("Installing dependencies...")
            cmd = [str(ai_bin), "install-deps"]
            if args.cpu_only:
                cmd.append("--cpu-only")
            subprocess.run(cmd, check=False)

    print(f"\n{G}{'='*50}{Z}")
    print(f"{G}  ai-cli v{remote_ver or 'latest'} installed!{Z}")
    print(f"{G}{'='*50}{Z}")
    print(f"\n  ai --help          Show commands")
    print(f"  ai ask \"hello\"     Quick question")
    print(f"  ai chat            Interactive chat")
    print(f"  ai recommended     Browse 195 models\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(1)
