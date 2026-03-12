#!/usr/bin/env python3
"""
AI CLI — Installer v2.5
• Detects CPU architecture (x86_64 / ARM64 / armv7l)
• Detects ARM sub-type (Apple Silicon / Jetson / Raspberry Pi / generic)
• VERSION CHECK: skips reinstall if already up-to-date (unless --force)
• AUTO-UPDATE mode: updates an existing install to the latest version
• Picks the correct build variant automatically
• Installs dependencies for the detected platform

Usage:
    python3 install.py [options]

Options:
    --prefix DIR     Install prefix (default: /usr/local)
    --no-deps        Skip 'ai install-deps' after install
    --cpu-only       Force CPU-only deps (no CUDA / no Metal)
    --dry-run        Preview actions without executing
    --keep-clone     Keep the cloned repo after install
    --arch ARCH      Override arch: x86_64 | arm64 | armv7l
    --arm-type TYPE  Override ARM sub-type
    --jetson         Shorthand for --arm-type jetson
    --force          Force reinstall even if version matches
    --update         Auto-update existing install (skip confirmation)
    --check          Check if an update is available and exit
"""

import os
import sys
import shutil
import subprocess
import platform
import tempfile
import re
import argparse
import json
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────
INSTALLER_VERSION = "2.5"
REPO_URL    = "https://github.com/minerofthesoal/ai-cli.git"
REPO_BRANCH = "claude/cpu-windows-llm-api-uiTei"
BINARY_NAME = "ai"
VERSION_GLOB = "main-v"   # files starting with main-v

SEARCH_PATHS = [
    "/usr/local/bin",
    "/usr/bin",
    "/opt/local/bin",
    os.path.expanduser("~/.local/bin"),
    os.path.expanduser("~/bin"),
]

# ── Colors ────────────────────────────────────────────────────────────────────
if sys.stdout.isatty() and platform.system() != "Windows":
    GRN = "\033[92m"; YLW = "\033[93m"; RED = "\033[91m"
    CYN = "\033[96m"; BLD = "\033[1m";  DIM = "\033[2m"; RST = "\033[0m"
    MAG = "\033[95m"; WHT = "\033[97m"
else:
    GRN = YLW = RED = CYN = BLD = DIM = RST = MAG = WHT = ""

def ok(msg):   print(f"{GRN}✓ {msg}{RST}")
def info(msg): print(f"{CYN}ℹ {msg}{RST}")
def warn(msg): print(f"{YLW}⚠ {msg}{RST}")
def err(msg):  print(f"{RED}✗ {msg}{RST}", file=sys.stderr)
def hdr(msg):  print(f"\n{BLD}{WHT}{msg}{RST}")
def dim(msg):  print(f"{DIM}  {msg}{RST}")

# ── Platform helpers ──────────────────────────────────────────────────────────
def is_windows():
    return platform.system() == "Windows" or "MINGW" in os.environ.get("MSYSTEM", "")

def is_wsl():
    try:
        with open("/proc/version") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False

def is_macos():
    return platform.system() == "Darwin"

def need_sudo():
    if is_windows():
        return False
    return os.geteuid() != 0

def run(cmd, check=True, capture=False, dry_run=False, timeout=None):
    if dry_run:
        print(f"  {DIM}[dry-run]{RST} {' '.join(str(c) for c in cmd)}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    kwargs = {"capture_output": capture, "text": True}
    if timeout:
        kwargs["timeout"] = timeout
    if check:
        return subprocess.run(cmd, check=True, **kwargs)
    return subprocess.run(cmd, **kwargs)

# ── CPU type detection (x86 sub-types) ────────────────────────────────────────
def detect_cpu_features() -> dict:
    """
    Returns dict with CPU feature flags relevant to model selection:
      avx512, avx2, avx, sse4_2, neon (ARM), sve (ARM)
    Used to pick the best GGUF quantisation / backend build.
    """
    feats = {"avx512": False, "avx2": False, "avx": False,
             "sse4_2": False, "neon": False, "sve": False}
    system = platform.system()
    arch = platform.machine().lower()

    if arch in ("arm64", "aarch64"):
        # ARM — check for NEON (always on aarch64) and SVE
        feats["neon"] = True
        try:
            with open("/proc/cpuinfo") as f:
                cpuinfo = f.read().lower()
            if "sve" in cpuinfo:
                feats["sve"] = True
        except OSError:
            pass
        return feats

    # x86_64: read /proc/cpuinfo (Linux) or sysctl (macOS)
    flags_str = ""
    if system == "Linux":
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.startswith("flags"):
                        flags_str = line.split(":", 1)[1].lower()
                        break
        except OSError:
            pass
    elif system == "Darwin":
        try:
            r = subprocess.run(["sysctl", "-n", "machdep.cpu.features",
                                 "machdep.cpu.leaf7_features"],
                                capture_output=True, text=True, timeout=3)
            flags_str = r.stdout.lower()
        except Exception:
            pass
    elif system == "Windows":
        # Use Python's cpuinfo fallback
        try:
            import cpuinfo  # type: ignore
            flags_str = " ".join(cpuinfo.get_cpu_info().get("flags", []))
        except Exception:
            pass

    feats["avx512"] = "avx512f" in flags_str or "avx512" in flags_str
    feats["avx2"]   = "avx2" in flags_str
    feats["avx"]    = "avx " in flags_str or flags_str.startswith("avx")
    feats["sse4_2"] = "sse4_2" in flags_str or "sse4.2" in flags_str
    return feats

def cpu_tier(feats: dict) -> str:
    """Returns 'avx512' | 'avx2' | 'avx' | 'sse4' | 'baseline'"""
    if feats.get("avx512"):  return "avx512"
    if feats.get("avx2"):    return "avx2"
    if feats.get("avx"):     return "avx"
    if feats.get("sse4_2"):  return "sse4"
    return "baseline"

# ── Architecture detection ────────────────────────────────────────────────────
def detect_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    if machine in ("arm64", "aarch64"):
        return "arm64"
    if machine.startswith("armv7"):
        return "armv7l"
    return machine or "unknown"

def detect_arm_type() -> str:
    if is_macos():
        return "apple_silicon"
    model_str = ""
    for path in ("/proc/device-tree/model", "/sys/firmware/devicetree/base/model"):
        try:
            with open(path, "rb") as f:
                model_str = f.read().decode("utf-8", errors="replace").strip("\x00")
            break
        except OSError:
            pass
    if "raspberry pi" in model_str.lower():
        return "raspberry_pi"
    if "nvidia jetson" in model_str.lower():
        return "jetson"
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read().lower()
        if "tegra" in cpuinfo or "jetson" in cpuinfo:
            return "jetson"
    except OSError:
        pass
    if Path("/etc/nv_tegra_release").exists():
        return "jetson"
    if shutil.which("jetson_release"):
        return "jetson"
    return "generic_arm64"

def arch_label(arch: str, arm_type: str, cpu_feats: dict = None) -> str:
    if arch == "x86_64":
        tier = cpu_tier(cpu_feats) if cpu_feats else "unknown"
        return f"x86_64 (Intel/AMD) — CPU tier: {tier}"
    if arch == "arm64":
        labels = {
            "apple_silicon": "ARM64 — Apple Silicon (M1/M2/M3/M4+)",
            "jetson":        "ARM64 — NVIDIA Jetson (CUDA)",
            "raspberry_pi":  "ARM64 — Raspberry Pi",
            "generic_arm64": "ARM64 — Generic aarch64",
        }
        return labels.get(arm_type, f"ARM64 — {arm_type}")
    return arch

# ── Version parsing ───────────────────────────────────────────────────────────
def parse_version(name: str) -> tuple:
    """
    Parse 'main-v2.6' or 'main-v2.5.1-arm64' → (2, 6, 0) or (2, 5, 1).
    Strips trailing -arm64 / -arm suffix before parsing.
    """
    clean = re.sub(r"-(arm64|arm|aarch64|armv7l)$", "", name)
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", clean)
    if not m:
        return (0, 0, 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))

def version_str(tup: tuple) -> str:
    return ".".join(str(x) for x in tup)

def find_script_for_arch(repo_dir: Path, arch: str) -> Path:
    """
    Selects the highest-versioned script matching the target arch:
      - ARM64  → prefer main-v*-arm64; fall back to generic main-v*
      - x86_64 / armv7l → use generic main-v* only
    """
    all_scripts = [
        p for p in repo_dir.iterdir()
        if p.name.startswith(VERSION_GLOB) and p.is_file()
    ]
    if not all_scripts:
        raise FileNotFoundError(
            f"No 'main-v*' script found in {repo_dir}. Check the repo branch."
        )
    arm64_scripts   = [p for p in all_scripts if re.search(r"-(arm64|aarch64)$", p.name)]
    generic_scripts = [p for p in all_scripts
                       if not re.search(r"-(arm64|aarch64|armv7l)$", p.name)]

    if arch == "arm64" and arm64_scripts:
        candidates = arm64_scripts
        info(f"ARM64-specific builds available: {[p.name for p in candidates]}")
    else:
        if arch == "arm64":
            warn("No arm64-specific build found — using generic script")
        candidates = generic_scripts or all_scripts

    best = sorted(candidates, key=lambda p: parse_version(p.name), reverse=True)[0]
    info(f"Selected build: {best.name}")
    return best

# ── Installed version detection ───────────────────────────────────────────────
def find_existing_installs() -> list:
    found = []
    which_cmd = "where" if is_windows() else "which"
    try:
        result = run([which_cmd, BINARY_NAME], capture=True, check=False)
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                p = Path(line.strip())
                if p.exists() and str(p) not in found:
                    found.append(str(p))
    except Exception:
        pass
    for sp in SEARCH_PATHS:
        p = Path(sp) / BINARY_NAME
        if p.exists() and str(p) not in found:
            found.append(str(p))
        if is_windows():
            for ext in (".cmd", ".bat", ".exe"):
                pw = p.with_suffix(ext)
                if pw.exists() and str(pw) not in found:
                    found.append(str(pw))
    return found

def detect_installed_version(path: str) -> tuple:
    """Returns parsed version tuple of installed binary."""
    try:
        result = subprocess.run(
            [path, "version"], capture_output=True, text=True, timeout=8
        )
        text = (result.stdout + result.stderr).strip()
        m = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text)
        if m:
            return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
    except Exception:
        pass
    return (0, 0, 0)

def get_latest_repo_version(repo_dir: Path, arch: str) -> tuple:
    """Get version of best available script in the cloned repo."""
    try:
        script = find_script_for_arch(repo_dir, arch)
        return parse_version(script.name)
    except Exception:
        return (0, 0, 0)

# ── Uninstall ──────────────────────────────────────────────────────────────────
def uninstall(paths: list, dry_run=False):
    for p in paths:
        try:
            if dry_run:
                warn(f"[dry-run] Would remove: {p}")
                continue
            if need_sudo() and not Path(p).stat().st_mode & 0o200:
                run(["sudo", "rm", "-f", p])
            else:
                os.remove(p)
            ok(f"Removed: {p}")
        except PermissionError:
            warn(f"Retrying with sudo: {p}")
            if not dry_run:
                run(["sudo", "rm", "-f", p], check=False)
        except Exception as exc:
            warn(f"Could not remove {p}: {exc}")

# ── Clone ──────────────────────────────────────────────────────────────────────
def clone_repo(dest: Path, dry_run=False):
    if not shutil.which("git"):
        raise EnvironmentError(
            "git not found.\n"
            "  Arch:   sudo pacman -S git\n"
            "  Ubuntu: sudo apt install git\n"
            "  macOS:  brew install git"
        )
    cmd = ["git", "clone", "--depth=1", "--branch", REPO_BRANCH, REPO_URL, str(dest)]
    info(f"Cloning {REPO_URL} @ {REPO_BRANCH} …")
    run(cmd, dry_run=dry_run)

def fetch_latest_branch(repo_dir: Path, dry_run=False):
    """Pull latest changes in an existing clone."""
    run(["git", "-C", str(repo_dir), "fetch", "--depth=1", "origin", REPO_BRANCH],
        dry_run=dry_run, check=False)
    run(["git", "-C", str(repo_dir), "reset", "--hard", f"origin/{REPO_BRANCH}"],
        dry_run=dry_run, check=False)

# ── Install ────────────────────────────────────────────────────────────────────
def install_script(script: Path, prefix: Path, dry_run=False) -> Path:
    bin_dir = prefix / "bin"
    dest    = bin_dir / BINARY_NAME
    if is_windows():
        dest = bin_dir / f"{BINARY_NAME}.sh"
    if not dry_run:
        bin_dir.mkdir(parents=True, exist_ok=True)
    if need_sudo():
        info(f"Installing to {dest} (sudo required)…")
        run(["sudo", "cp", str(script), str(dest)], dry_run=dry_run)
        run(["sudo", "chmod", "+x", str(dest)], dry_run=dry_run)
    else:
        if dry_run:
            info(f"[dry-run] Would copy {script.name} → {dest}")
        else:
            shutil.copy2(script, dest)
            dest.chmod(dest.stat().st_mode | 0o755)
        ok(f"Installed: {dest}")
    if is_windows() and not dry_run:
        cmd_wrapper = bin_dir / f"{BINARY_NAME}.cmd"
        cmd_wrapper.write_text(f'@echo off\nbash "%~dp0{BINARY_NAME}.sh" %*\n')
        ok(f"Windows wrapper: {cmd_wrapper}")
    return dest

# ── Deps ───────────────────────────────────────────────────────────────────────
def run_install_deps(ai_bin: Path, cpu_only=False, arm_type="",
                     jetson=False, dry_run=False):
    cmd = [str(ai_bin), "install-deps"]
    if is_windows() or cpu_only:
        cmd.append("--cpu-only")
    elif jetson or arm_type == "jetson":
        cmd.append("--jetson")
    elif arm_type in ("raspberry_pi", "generic_arm64"):
        cmd.append("--cpu-only")
    # apple_silicon: no extra flag — Metal auto-detected
    info("Running: " + " ".join(cmd))
    if not dry_run:
        proc = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)
        proc.wait()
        if proc.returncode != 0:
            warn("install-deps returned non-zero — some optional packages may be missing.")
        else:
            ok("Dependencies installed.")

# ── Version check (online — optional, uses git ls-remote) ────────────────────
def check_remote_version(arch: str) -> tuple:
    """
    Tries to determine the latest version from the remote branch without cloning.
    Reads the PKGBUILD or a VERSION file via raw GitHub URL if available,
    otherwise returns (0,0,0) to indicate 'unknown'.
    """
    # Try raw GitHub URL for a VERSION marker file
    raw_url = (
        f"https://raw.githubusercontent.com/minerofthesoal/ai-cli/"
        f"{REPO_BRANCH}/VERSION"
    )
    try:
        with urllib.request.urlopen(raw_url, timeout=5) as resp:
            content = resp.read().decode().strip()
            m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", content)
            if m:
                return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
    except Exception:
        pass
    return (0, 0, 0)

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description=f"AI CLI Installer v{INSTALLER_VERSION} — "
                    "smart arch detection, version checks, auto-update"
    )
    parser.add_argument("--prefix",   default="/usr/local",
                        help="Install prefix (default: /usr/local)")
    parser.add_argument("--no-deps",  action="store_true",
                        help="Skip 'ai install-deps' after install")
    parser.add_argument("--cpu-only", action="store_true",
                        help="Force --cpu-only for install-deps")
    parser.add_argument("--dry-run",  action="store_true",
                        help="Preview without executing")
    parser.add_argument("--keep-clone", action="store_true",
                        help="Keep the cloned repo after install")
    parser.add_argument("--arch",     default="",
                        help="Override arch: x86_64 | arm64 | armv7l")
    parser.add_argument("--arm-type", default="",
                        help="Override ARM sub-type")
    parser.add_argument("--jetson",   action="store_true",
                        help="Shorthand for --arm-type jetson")
    parser.add_argument("--force",    action="store_true",
                        help="Force reinstall even if version is current")
    parser.add_argument("--update",   action="store_true",
                        help="Update existing install (skips confirmation)")
    parser.add_argument("--check",    action="store_true",
                        help="Check for updates and exit (no install)")
    args = parser.parse_args()

    dry    = args.dry_run
    prefix = Path(args.prefix).expanduser().resolve()

    # ── Detect platform ────────────────────────────────────────────────────
    arch     = args.arch or detect_arch()
    arm_type = args.arm_type or ("jetson" if args.jetson else "")
    if arch == "arm64" and not arm_type:
        arm_type = detect_arm_type()
    cpu_feats = detect_cpu_features()

    # ── Banner ─────────────────────────────────────────────────────────────
    hdr(f"╔══ AI CLI Installer v{INSTALLER_VERSION} ══╗")
    info(f"Repo:         {REPO_URL}")
    info(f"Branch:       {REPO_BRANCH}")
    info(f"Prefix:       {prefix}")
    info(f"Platform:     {arch_label(arch, arm_type, cpu_feats)}")
    if arch == "x86_64":
        info(f"CPU tier:     {cpu_tier(cpu_feats)} (affects GGUF quantisation speed)")
    if dry:
        warn("DRY RUN — no changes will be made")

    # ── 1. Check existing install ──────────────────────────────────────────
    hdr("Step 1 — Checking existing installation…")
    existing = find_existing_installs()
    installed_ver = (0, 0, 0)
    installed_path = None

    if existing:
        installed_path = existing[0]
        installed_ver  = detect_installed_version(installed_path)
        info(f"Found: {installed_path}  (version: {version_str(installed_ver)})")
    else:
        ok("No existing install found — fresh install.")

    # ── --check mode: just report ──────────────────────────────────────────
    if args.check:
        hdr("Version check (remote)…")
        remote_ver = check_remote_version(arch)
        if remote_ver > (0, 0, 0):
            if remote_ver > installed_ver:
                warn(f"Update available: {version_str(installed_ver)} → {version_str(remote_ver)}")
                warn("Run: python3 install.py --update")
            else:
                ok(f"Up-to-date: v{version_str(installed_ver)}")
        else:
            info("Could not fetch remote version (offline?). Clone locally to check.")
        sys.exit(0)

    # ── 2. Clone latest ────────────────────────────────────────────────────
    hdr("Step 2 — Fetching latest version…")
    tmp_dir    = Path(tempfile.mkdtemp(prefix="ai-cli-install-"))
    clone_dest = tmp_dir / "ai-cli"

    try:
        clone_repo(clone_dest, dry_run=dry)

        # Get latest version from repo
        if dry:
            latest_ver = (2, 6, 0)
            latest     = Path(f"main-v2.6{'-arm64' if arch=='arm64' else ''}")
        else:
            latest = find_script_for_arch(clone_dest, arch)
            latest_ver = parse_version(latest.name)

        info(f"Available:    v{version_str(latest_ver)}  ({latest.name if not dry else latest.name})")
        info(f"Installed:    v{version_str(installed_ver)}" if installed_ver != (0,0,0) else "Installed:    (none)")

        # ── Version check: skip if up-to-date ─────────────────────────────
        if installed_ver >= latest_ver and not args.force:
            if installed_ver == latest_ver:
                ok(f"Already up-to-date: v{version_str(installed_ver)}")
            else:
                ok(f"Installed v{version_str(installed_ver)} is newer than repo v{version_str(latest_ver)}")
            info("No reinstall needed. Use --force to reinstall anyway.")
            return

        # ── Confirm update (unless --update or fresh install) ─────────────
        if installed_ver != (0, 0, 0) and not args.update and not args.force and not dry:
            print()
            if installed_ver < latest_ver:
                msg = (f"Upgrade from v{version_str(installed_ver)} "
                       f"→ v{version_str(latest_ver)}")
            else:
                msg = f"Reinstall v{version_str(latest_ver)}"
            ans = input(f"  {BLD}{msg}?{RST} [Y/n]: ").strip().lower()
            if ans in ("n", "no"):
                info("Cancelled.")
                return

        # ── 3. Uninstall old ───────────────────────────────────────────────
        if existing:
            hdr("Step 3 — Removing old installation…")
            uninstall(existing, dry_run=dry)
        else:
            info("Step 3 — Skipped (no old installation found)")

        # ── 4. Install new build ───────────────────────────────────────────
        hdr(f"Step 4 — Installing v{version_str(latest_ver)} "
            f"[{arch_label(arch, arm_type, cpu_feats)}]…")
        ai_bin = install_script(latest, prefix, dry_run=dry)
        ok(f"AI CLI v{version_str(latest_ver)} installed → {ai_bin}")

        # ── 5. Install dependencies ────────────────────────────────────────
        if not args.no_deps:
            hdr("Step 5 — Installing dependencies…")
            run_install_deps(
                ai_bin,
                cpu_only=args.cpu_only,
                arm_type=arm_type,
                jetson=args.jetson,
                dry_run=dry,
            )
        else:
            info("Step 5 — Skipped (--no-deps)")

        # ── Done ───────────────────────────────────────────────────────────
        hdr("══ Installation Complete ══")
        ok(f"AI CLI v{version_str(latest_ver)} ready  [{arch_label(arch, arm_type, cpu_feats)}]")
        print()

        # Platform-specific quick-start tips
        print(f"  {BLD}Quick start:{RST}")
        if arch == "arm64":
            match arm_type:
                case "apple_silicon":
                    print("    ai status              # verify Metal/MPS detected")
                    print("    ai recommended         # ARM64-optimised models")
                case "jetson":
                    print("    ai status              # verify Jetson CUDA detected")
                    print("    ai recommended         # Jetson CUDA models")
                case "raspberry_pi":
                    print("    ai recommended download 1   # 360M model (RPi-friendly)")
                case _:
                    print("    ai recommended         # browse ARM64 models")
        else:
            tier = cpu_tier(cpu_feats)
            print(f"    ai recommended         # browse models (CPU: {tier})")
            print( "    ai recommended download 1")

        print( "    ai ask \"Hello!\"")
        print( "    ai -gui")
        print()
        print(f"  {BLD}What's new in v{version_str(latest_ver)}:{RST}")
        if latest_ver >= (2, 6, 0):
            print("    ai project new mywork    # persistent multi-chat memory")
            print("    ai project switch mywork # switch project context")
            print("    ai system set \"...\"     # apply system prompt to all backends")
            print("    ai finetune any <model>  # LoRA-tune any HuggingFace model")
            print("    ai rclick install        # rclick v3 (fixed auth + menu)")
        elif latest_ver >= (2, 5, 5):
            print("    ai system set \"You are a pirate AI.\"")
            print("    ai dataset generate mydata \"Python tips\" --count 100")
            print("    ai finetune any Qwen/Qwen2.5-1.5B-Instruct")
        print()
        print(f"  {BLD}To update later:{RST}")
        print( "    python3 install.py --check    # check for updates")
        print( "    python3 install.py --update   # apply updates")
        print( "    ai -aup                        # or use built-in updater")
        print()

    finally:
        if not args.keep_clone and tmp_dir.exists():
            if dry:
                info(f"[dry-run] Would delete temp dir: {tmp_dir}")
            else:
                shutil.rmtree(tmp_dir, ignore_errors=True)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(1)
    except Exception as exc:
        err(str(exc))
        sys.exit(1)
