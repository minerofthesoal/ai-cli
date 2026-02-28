#!/usr/bin/env python3
"""
AI CLI — Installer / Updater
Checks for existing install, removes it, clones latest version, installs,
then runs the built-in dependency installer.

Usage:
    python3 install.py [--prefix /usr/local] [--no-deps] [--dry-run]
"""

import os
import sys
import shutil
import subprocess
import platform
import tempfile
import re
import argparse
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
REPO_URL    = "https://github.com/minerofthesoal/ai-cli.git"
REPO_BRANCH = "claude/cpu-windows-llm-api-uiTei"
BINARY_NAME = "ai"
VERSION_GLOB = "main-v"   # files matching main-v*.* pattern

# Install prefixes to check when looking for existing installs
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
    CYN = "\033[96m"; BLD = "\033[1m";  RST = "\033[0m"
else:
    GRN = YLW = RED = CYN = BLD = RST = ""

def ok(msg):   print(f"{GRN}✓ {msg}{RST}")
def info(msg): print(f"{CYN}ℹ {msg}{RST}")
def warn(msg): print(f"{YLW}⚠ {msg}{RST}")
def err(msg):  print(f"{RED}✗ {msg}{RST}", file=sys.stderr)
def hdr(msg):  print(f"\n{BLD}{msg}{RST}")

# ── Platform helpers ──────────────────────────────────────────────────────────
def is_windows():
    return platform.system() == "Windows" or "MINGW" in os.environ.get("MSYSTEM","")

def is_wsl():
    try:
        with open("/proc/version") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False

def need_sudo():
    """True if we need sudo to write to /usr/local/bin."""
    if is_windows():
        return False
    return os.geteuid() != 0

def run(cmd, check=True, capture=False, dry_run=False):
    """Run a shell command with optional dry-run."""
    if dry_run:
        print(f"  [dry-run] {' '.join(str(c) for c in cmd)}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    kwargs = {"capture_output": capture, "text": True}
    if check:
        return subprocess.run(cmd, check=True, **kwargs)
    else:
        return subprocess.run(cmd, **kwargs)

# ── Version parsing ───────────────────────────────────────────────────────────
def parse_version(name: str):
    """Parse 'main-v2.5.1' → (2, 5, 1) for comparison."""
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", name)
    if not m:
        return (0, 0, 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))

def find_latest_script(repo_dir: Path) -> Path:
    """Find the highest-versioned main-vX.Y[.Z] script in the cloned repo."""
    candidates = sorted(
        [p for p in repo_dir.iterdir()
         if p.name.startswith(VERSION_GLOB) and p.is_file()],
        key=lambda p: parse_version(p.name),
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(
            f"No 'main-v*' script found in {repo_dir}.\n"
            "The repo may use a different naming convention."
        )
    return candidates[0]

# ── Step 1: Detect existing installs ─────────────────────────────────────────
def find_existing_installs():
    """Return list of absolute paths where 'ai' binary is found."""
    found = []
    # which / where
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

    # Manual search
    for sp in SEARCH_PATHS:
        p = Path(sp) / BINARY_NAME
        if p.exists() and str(p) not in found:
            found.append(str(p))
        # Windows: check .cmd / .bat wrappers too
        if is_windows():
            for ext in (".cmd", ".bat", ".exe"):
                pw = p.with_suffix(ext)
                if pw.exists() and str(pw) not in found:
                    found.append(str(pw))
    return found

def detect_installed_version(path: str) -> str:
    """Try to read VERSION from an existing install."""
    try:
        result = subprocess.run([path, "version"], capture_output=True, text=True, timeout=5)
        text = (result.stdout + result.stderr).strip()
        m = re.search(r"v?(\d+\.\d+(?:\.\d+)?)", text)
        return m.group(1) if m else "unknown"
    except Exception:
        return "unknown"

# ── Step 2: Uninstall ─────────────────────────────────────────────────────────
def uninstall(paths: list, dry_run=False):
    for p in paths:
        try:
            if dry_run:
                warn(f"[dry-run] Would remove: {p}")
            else:
                if need_sudo() and not Path(p).stat().st_mode & 0o200:
                    run(["sudo", "rm", "-f", p], dry_run=dry_run)
                else:
                    os.remove(p)
                ok(f"Removed: {p}")
        except PermissionError:
            warn(f"Permission denied removing {p} — retrying with sudo...")
            if not dry_run:
                run(["sudo", "rm", "-f", p], check=False)
        except Exception as e:
            warn(f"Could not remove {p}: {e}")

# ── Step 3: Clone repo ────────────────────────────────────────────────────────
def clone_repo(dest: Path, dry_run=False):
    if not shutil.which("git"):
        raise EnvironmentError(
            "git is not installed.\n"
            "  Arch:   sudo pacman -S git\n"
            "  Ubuntu: sudo apt install git\n"
            "  macOS:  brew install git"
        )
    cmd = ["git", "clone", "--depth=1", "--branch", REPO_BRANCH, REPO_URL, str(dest)]
    info(f"Cloning {REPO_URL} (branch: {REPO_BRANCH}) …")
    run(cmd, dry_run=dry_run)

# ── Step 4: Install ───────────────────────────────────────────────────────────
def install_script(script: Path, prefix: Path, dry_run=False):
    bin_dir = prefix / "bin"
    dest    = bin_dir / BINARY_NAME

    if is_windows():
        # On Windows: copy to ~/bin or user-chosen dir
        dest = bin_dir / f"{BINARY_NAME}.sh"

    if not dry_run:
        bin_dir.mkdir(parents=True, exist_ok=True)

    # Copy with sudo if needed
    if need_sudo():
        info(f"Installing to {dest} (sudo required)…")
        run(["sudo", "cp", str(script), str(dest)], dry_run=dry_run)
        run(["sudo", "chmod", "+x", str(dest)], dry_run=dry_run)
    else:
        if dry_run:
            info(f"[dry-run] Would copy {script} → {dest}")
        else:
            shutil.copy2(script, dest)
            dest.chmod(dest.stat().st_mode | 0o755)
        ok(f"Installed: {dest}")

    # On Windows also write a tiny .cmd wrapper
    if is_windows() and not dry_run:
        cmd_wrapper = bin_dir / f"{BINARY_NAME}.cmd"
        cmd_wrapper.write_text(
            f'@echo off\nbash "%~dp0{BINARY_NAME}.sh" %*\n'
        )
        ok(f"Windows wrapper: {cmd_wrapper}")

    return dest

# ── Step 5: Run install-deps ──────────────────────────────────────────────────
def run_install_deps(ai_bin: Path, cpu_only=False, dry_run=False):
    cmd = [str(ai_bin), "install-deps"]
    if cpu_only or is_windows():
        cmd.append("--cpu-only")
    info("Running: " + " ".join(cmd))
    if not dry_run:
        # Stream output live
        proc = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)
        proc.wait()
        if proc.returncode != 0:
            warn("install-deps returned non-zero — some optional packages may be missing.")
        else:
            ok("Dependencies installed successfully.")

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="AI CLI installer — detects, removes old version, clones + installs latest"
    )
    parser.add_argument("--prefix",   default="/usr/local",
                        help="Install prefix (default: /usr/local)")
    parser.add_argument("--no-deps",  action="store_true",
                        help="Skip running 'ai install-deps' after install")
    parser.add_argument("--cpu-only", action="store_true",
                        help="Pass --cpu-only to install-deps (no CUDA)")
    parser.add_argument("--dry-run",  action="store_true",
                        help="Print what would be done without doing it")
    parser.add_argument("--keep-clone", action="store_true",
                        help="Keep the cloned repo after install (default: delete it)")
    args = parser.parse_args()

    dry = args.dry_run
    prefix = Path(args.prefix).expanduser().resolve()

    hdr("═══ AI CLI Installer ═══")
    info(f"Repo:   {REPO_URL}")
    info(f"Branch: {REPO_BRANCH}")
    info(f"Prefix: {prefix}")
    if dry:
        warn("DRY RUN — no changes will be made")

    # ── 1. Check for existing install ──────────────────────────────────────
    hdr("Step 1 — Checking for existing install…")
    existing = find_existing_installs()
    if existing:
        for p in existing:
            ver = detect_installed_version(p)
            warn(f"Found: {p}  (version: {ver})")
    else:
        ok("No existing install found.")

    # ── 2. Uninstall old version ───────────────────────────────────────────
    if existing:
        hdr("Step 2 — Uninstalling old version…")
        uninstall(existing, dry_run=dry)
    else:
        info("Step 2 — Skipped (nothing to uninstall)")

    # ── 3. Clone latest version ────────────────────────────────────────────
    hdr("Step 3 — Cloning latest version…")
    tmp_dir = Path(tempfile.mkdtemp(prefix="ai-cli-install-"))
    clone_dest = tmp_dir / "ai-cli"
    try:
        clone_repo(clone_dest, dry_run=dry)

        # ── 4. Find newest script and install ─────────────────────────────
        hdr("Step 4 — Installing…")
        if dry:
            latest = Path("main-v2.5.1")   # placeholder for dry-run
            new_ver = "2.5.1"
        else:
            latest  = find_latest_script(clone_dest)
            new_ver = ".".join(str(x) for x in parse_version(latest.name))

        info(f"Latest script: {latest.name}  (v{new_ver})")
        ai_bin = install_script(latest, prefix, dry_run=dry)
        ok(f"AI CLI v{new_ver} installed → {ai_bin}")

        # ── 5. Install dependencies ────────────────────────────────────────
        if not args.no_deps:
            hdr("Step 5 — Installing dependencies…")
            run_install_deps(ai_bin, cpu_only=args.cpu_only, dry_run=dry)
        else:
            info("Step 5 — Skipped (--no-deps)")

        # ── Done ───────────────────────────────────────────────────────────
        hdr("═══ Installation complete ═══")
        ok(f"AI CLI v{new_ver} is ready.")
        print()
        print(f"  {BLD}Usage:{RST}")
        print(f"    ai ask \"Hello!\"")
        print(f"    ai -gui")
        print(f"    ai recommended")
        print(f"    ai install-deps --cpu-only   (CPU-only mode)")
        print()

    finally:
        # Clean up the temp clone unless --keep-clone
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
    except Exception as e:
        err(str(e))
        sys.exit(1)
