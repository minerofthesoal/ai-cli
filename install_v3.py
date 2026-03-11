#!/usr/bin/env python3
"""
AI CLI — Installer v3.0
━━━━━━━━━━━━━━━━━━━━━━━
NEW in v3:
  • AUTO BRANCH SEARCH — scans every branch in the repo and picks the
    highest-versioned main-v* script across all of them
  • --list-branches   Show all branches + their available versions and exit
  • --branch <name>   Pin to a specific branch (skips auto-search)
  • --branch-filter   Glob/regex pattern to narrow which branches are scanned
  • --prefer-branch   Prefer a named branch if it ties on version
  • --no-branch-scan  Disable scan, fall back to hardcoded REPO_BRANCH
  • Parallel branch scanning (ThreadPoolExecutor) for speed
  • Caches branch scan results for 10 min (~/.cache/ai-cli/branches.json)
  • Shows a live progress bar during scan
  • All v2.5 features retained

Kept from v2.5:
  • CPU arch / ARM sub-type detection (x86_64 / ARM64 / armv7l)
  • ARM sub-types: Apple Silicon / Jetson / Raspberry Pi / generic
  • VERSION CHECK: skips reinstall if up-to-date (unless --force)
  • AUTO-UPDATE mode
  • Platform-specific deps (CUDA / Metal / CPU-only)
  • --dry-run, --keep-clone, --check, --no-deps, --prefix …

Usage:
    python3 install.py [options]

Options (v3 additions):
    --list-branches         Show all discovered branches + versions and exit
    --branch NAME           Use this branch (skip auto-search)
    --branch-filter PAT     Only scan branches matching pattern (substring)
    --prefer-branch NAME    Prefer named branch on version tie
    --no-branch-scan        Skip scan; use hardcoded REPO_BRANCH
    --scan-threads N        Parallel scan threads (default: 8)
    --no-cache              Ignore cached branch scan
    --scan-timeout N        Seconds per branch probe (default: 6)

Options (v2.5 retained):
    --prefix DIR            Install prefix (default: /usr/local)
    --no-deps               Skip 'ai install-deps' after install
    --cpu-only              Force CPU-only deps (no CUDA / no Metal)
    --dry-run               Preview actions without executing
    --keep-clone            Keep the cloned repo after install
    --arch ARCH             Override arch: x86_64 | arm64 | armv7l
    --arm-type TYPE         Override ARM sub-type
    --jetson                Shorthand for --arm-type jetson
    --force                 Force reinstall even if version matches
    --update                Auto-update existing install (skip confirmation)
    --check                 Check if an update is available and exit
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
import time
import threading
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ────────────────────────────────────────────────────────────────────
INSTALLER_VERSION = "3.0"
REPO_OWNER  = "minerofthesoal"
REPO_NAME   = "ai-cli"
REPO_URL    = f"https://github.com/{REPO_OWNER}/{REPO_NAME}.git"
REPO_BRANCH = "claude/cpu-windows-llm-api-uiTei"   # fallback if scan disabled
BINARY_NAME = "ai"
VERSION_GLOB = "main-v"   # files starting with main-v

# GitHub API
GH_API_BASE      = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}"
GH_RAW_BASE      = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}"
GH_TREE_API      = f"{GH_API_BASE}/git/trees"
GH_BRANCHES_API  = f"{GH_API_BASE}/branches?per_page=100&page="
GH_CONTENTS_API  = f"{GH_API_BASE}/contents"

BRANCH_CACHE_FILE = Path.home() / ".cache" / "ai-cli" / "branches_v3.json"
BRANCH_CACHE_TTL  = 600   # seconds (10 min)

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
    MAG = "\033[95m"; WHT = "\033[97m"; BLU = "\033[94m"
else:
    GRN = YLW = RED = CYN = BLD = DIM = RST = MAG = WHT = BLU = ""

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

# ── CPU type detection ────────────────────────────────────────────────────────
def detect_cpu_features() -> dict:
    feats = {"avx512": False, "avx2": False, "avx": False,
             "sse4_2": False, "neon": False, "sve": False}
    system = platform.system()
    arch = platform.machine().lower()
    if arch in ("arm64", "aarch64"):
        feats["neon"] = True
        try:
            with open("/proc/cpuinfo") as f:
                if "sve" in f.read().lower():
                    feats["sve"] = True
        except OSError:
            pass
        return feats
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
    if feats.get("avx512"):  return "avx512"
    if feats.get("avx2"):    return "avx2"
    if feats.get("avx"):     return "avx"
    if feats.get("sse4_2"):  return "sse4"
    return "baseline"

# ── Architecture detection ────────────────────────────────────────────────────
def detect_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):   return "x86_64"
    if machine in ("arm64", "aarch64"):  return "arm64"
    if machine.startswith("armv7"):      return "armv7l"
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
    if "raspberry pi" in model_str.lower(): return "raspberry_pi"
    if "nvidia jetson" in model_str.lower(): return "jetson"
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read().lower()
        if "tegra" in cpuinfo or "jetson" in cpuinfo:
            return "jetson"
    except OSError:
        pass
    if Path("/etc/nv_tegra_release").exists(): return "jetson"
    if shutil.which("jetson_release"):         return "jetson"
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
    clean = re.sub(r"-(arm64|arm|aarch64|armv7l)$", "", name)
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", clean)
    if not m:
        return (0, 0, 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))

def version_str(tup: tuple) -> str:
    return ".".join(str(x) for x in tup)

def find_script_for_arch(repo_dir: Path, arch: str) -> Path:
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
        info(f"ARM64-specific builds: {[p.name for p in candidates]}")
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
    try:
        script = find_script_for_arch(repo_dir, arch)
        return parse_version(script.name)
    except Exception:
        return (0, 0, 0)

# ── Uninstall ─────────────────────────────────────────────────────────────────
def uninstall(paths: list, dry_run=False):
    for p in paths:
        try:
            if dry_run:
                warn(f"[dry-run] Would remove: {p}"); continue
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

# ── Clone / fetch ─────────────────────────────────────────────────────────────
def clone_repo(dest: Path, branch: str, dry_run=False):
    if not shutil.which("git"):
        raise EnvironmentError(
            "git not found.\n"
            "  Arch:   sudo pacman -S git\n"
            "  Ubuntu: sudo apt install git\n"
            "  macOS:  brew install git"
        )
    cmd = ["git", "clone", "--depth=1", "--branch", branch, REPO_URL, str(dest)]
    info(f"Cloning {REPO_URL} @ {branch} …")
    run(cmd, dry_run=dry_run)

def fetch_latest_branch(repo_dir: Path, branch: str, dry_run=False):
    run(["git", "-C", str(repo_dir), "fetch", "--depth=1", "origin", branch],
        dry_run=dry_run, check=False)
    run(["git", "-C", str(repo_dir), "reset", "--hard", f"origin/{branch}"],
        dry_run=dry_run, check=False)

# ── Install ───────────────────────────────────────────────────────────────────
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

# ── Deps ──────────────────────────────────────────────────────────────────────
def run_install_deps(ai_bin: Path, cpu_only=False, arm_type="",
                     jetson=False, dry_run=False):
    cmd = [str(ai_bin), "install-deps"]
    if is_windows() or cpu_only:
        cmd.append("--cpu-only")
    elif jetson or arm_type == "jetson":
        cmd.append("--jetson")
    elif arm_type in ("raspberry_pi", "generic_arm64"):
        cmd.append("--cpu-only")
    info("Running: " + " ".join(cmd))
    if not dry_run:
        proc = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)
        proc.wait()
        if proc.returncode != 0:
            warn("install-deps returned non-zero — some optional packages may be missing.")
        else:
            ok("Dependencies installed.")

# ══════════════════════════════════════════════════════════════════════════════
#  v3: BRANCH AUTO-SEARCH ENGINE
# ══════════════════════════════════════════════════════════════════════════════

def _gh_api(url: str, timeout: int = 8) -> object:
    """Fetch GitHub API endpoint, return parsed JSON or None."""
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                "User-Agent": f"ai-cli-installer/{INSTALLER_VERSION}"})
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 403:
            warn("GitHub API rate limited. Set GITHUB_TOKEN env var to increase limit.")
        return None
    except Exception:
        return None

def fetch_all_branches(timeout: int = 8) -> list[str]:
    """
    Returns a list of all branch names in the repo via GitHub API.
    Falls back to git ls-remote if the API fails.
    Paginates automatically.
    """
    branches = []
    page = 1
    while True:
        url = f"{GH_BRANCHES_API}{page}"
        data = _gh_api(url, timeout=timeout)
        if not data or not isinstance(data, list):
            break
        for b in data:
            name = b.get("name", "")
            if name:
                branches.append(name)
        if len(data) < 100:
            break   # last page
        page += 1

    if not branches:
        # Fallback: git ls-remote
        info("GitHub API unavailable — falling back to git ls-remote …")
        try:
            r = subprocess.run(
                ["git", "ls-remote", "--heads", REPO_URL],
                capture_output=True, text=True, timeout=20
            )
            for line in r.stdout.splitlines():
                m = re.search(r"refs/heads/(.+)$", line)
                if m:
                    branches.append(m.group(1))
        except Exception as exc:
            warn(f"git ls-remote failed: {exc}")

    return branches

def _probe_branch_for_scripts(branch: str, timeout: int = 6) -> dict:
    """
    Probe a single branch via GitHub Contents API.
    Returns { "branch": name, "scripts": [filenames], "best_ver": tuple }
    """
    result = {"branch": branch, "scripts": [], "best_ver": (0, 0, 0)}
    url = f"{GH_CONTENTS_API}?ref={urllib.parse.quote(branch)}"
    data = _gh_api(url, timeout=timeout)
    if not data or not isinstance(data, list):
        return result
    scripts = []
    for item in data:
        name = item.get("name", "")
        if name.startswith(VERSION_GLOB) and item.get("type") == "file":
            scripts.append(name)
    if scripts:
        best = max(scripts, key=lambda n: parse_version(n))
        result["scripts"] = scripts
        result["best_ver"] = parse_version(best)
    return result

# Make sure urllib.parse is imported
import urllib.parse

def progress_bar(current: int, total: int, width: int = 30,
                 label: str = "") -> str:
    pct = current / total if total else 0
    filled = int(width * pct)
    bar = "█" * filled + "░" * (width - filled)
    return f"  [{bar}] {current}/{total}  {label}"

def scan_all_branches(
    branch_filter: str = "",
    prefer_branch: str = "",
    threads: int = 8,
    timeout: int = 6,
    no_cache: bool = False,
) -> list[dict]:
    """
    Scans all branches for main-v* scripts.
    Returns list of dicts sorted by best_ver descending:
      [{ "branch", "scripts", "best_ver" }, …]
    Only entries with at least one script are included.
    """
    # ── Cache check ──────────────────────────────────────────────────────────
    if not no_cache and BRANCH_CACHE_FILE.exists():
        try:
            cached = json.loads(BRANCH_CACHE_FILE.read_text())
            age = time.time() - cached.get("ts", 0)
            if age < BRANCH_CACHE_TTL:
                results = cached.get("results", [])
                if results:
                    dim(f"Using cached branch scan ({int(age)}s old, "
                        f"--no-cache to refresh)")
                    # Convert lists back to tuples for best_ver
                    for r in results:
                        r["best_ver"] = tuple(r["best_ver"])
                    return _apply_filter_and_sort(results, branch_filter, prefer_branch)
        except Exception:
            pass

    # ── Fetch branch list ────────────────────────────────────────────────────
    info("Fetching branch list from GitHub…")
    all_branches = fetch_all_branches(timeout=timeout)
    if not all_branches:
        warn("Could not retrieve branch list — using default branch.")
        return []

    # Apply filter
    if branch_filter:
        all_branches = [b for b in all_branches if branch_filter.lower() in b.lower()]
        info(f"Filter '{branch_filter}' matches {len(all_branches)} branch(es)")

    total = len(all_branches)
    info(f"Scanning {total} branch(es) for main-v* scripts ({threads} threads)…")

    results = []
    lock = threading.Lock()
    done_count = [0]

    def probe(branch: str) -> dict:
        r = _probe_branch_for_scripts(branch, timeout=timeout)
        with lock:
            done_count[0] += 1
            current = done_count[0]
            # Live progress (overwrite line)
            bar = progress_bar(current, total, label=branch[:30])
            print(f"\r{DIM}{bar}{RST}", end="", flush=True)
        return r

    with ThreadPoolExecutor(max_workers=threads) as pool:
        futures = {pool.submit(probe, b): b for b in all_branches}
        for future in as_completed(futures):
            try:
                r = future.result()
                if r["scripts"]:
                    results.append(r)
            except Exception:
                pass

    print()  # newline after progress bar

    # ── Save cache ───────────────────────────────────────────────────────────
    try:
        BRANCH_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        BRANCH_CACHE_FILE.write_text(json.dumps({"ts": time.time(), "results": [
            {**r, "best_ver": list(r["best_ver"])} for r in results
        ]}, indent=2))
    except Exception:
        pass

    return _apply_filter_and_sort(results, branch_filter, prefer_branch)

def _apply_filter_and_sort(results: list, branch_filter: str,
                            prefer_branch: str) -> list:
    """Sort by version desc; break ties by preferring prefer_branch."""
    def sort_key(r):
        preferred = 1 if r["branch"] == prefer_branch else 0
        return (r["best_ver"], preferred)
    return sorted(results, key=sort_key, reverse=True)

def pick_best_branch(scan_results: list) -> tuple[str, tuple, list]:
    """
    Given sorted scan results, return (branch_name, best_version, script_list).
    """
    if not scan_results:
        return REPO_BRANCH, (0, 0, 0), []
    best = scan_results[0]
    return best["branch"], best["best_ver"], best["scripts"]

def check_remote_version(arch: str) -> tuple:
    """
    Try to determine the latest version from the remote without cloning.
    v3: also checks all branches via API before falling back.
    """
    # Try scan first (fast, uses cache if available)
    try:
        results = scan_all_branches(threads=4, timeout=5)
        if results:
            return results[0]["best_ver"]
    except Exception:
        pass
    # Fallback: VERSION file on default branch
    raw_url = f"{GH_RAW_BASE}/{REPO_BRANCH}/VERSION"
    try:
        with urllib.request.urlopen(raw_url, timeout=5) as resp:
            content = resp.read().decode().strip()
            m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", content)
            if m:
                return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))
    except Exception:
        pass
    return (0, 0, 0)

# ── List-branches display ─────────────────────────────────────────────────────
def cmd_list_branches(scan_results: list, arch: str):
    """Print a formatted table of all branches with their available versions."""
    hdr(f"╔══ Branch Scan Results ({len(scan_results)} branches with scripts) ══╗")
    if not scan_results:
        warn("No branches found with main-v* scripts.")
        return

    # Column widths
    bw = max(len(r["branch"]) for r in scan_results) + 2
    bw = max(bw, 20)

    print(f"\n  {BLD}{'Branch':<{bw}} {'Best Version':<14} {'Scripts'}{RST}")
    print(f"  {'─'*bw} {'─'*13} {'─'*30}")

    for i, r in enumerate(scan_results):
        ver = version_str(r["best_ver"]) if r["best_ver"] != (0,0,0) else "?"
        scripts_str = ", ".join(sorted(r["scripts"])[:4])
        if len(r["scripts"]) > 4:
            scripts_str += f" (+{len(r['scripts'])-4})"
        marker = f" {GRN}◀ best{RST}" if i == 0 else ""
        print(f"  {BLU}{r['branch']:<{bw}}{RST} {GRN}v{ver:<13}{RST} {DIM}{scripts_str}{RST}{marker}")

    print()
    best = scan_results[0]
    ok(f"Best branch:  {best['branch']}  (v{version_str(best['best_ver'])})")
    info(f"Install from it:  python3 install.py --branch \"{best['branch']}\"")

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description=f"AI CLI Installer v{INSTALLER_VERSION} — "
                    "auto branch search, smart arch detection, version checks"
    )
    # v3 new options
    parser.add_argument("--list-branches",  action="store_true",
                        help="Scan all branches, show versions, and exit")
    parser.add_argument("--branch",         default="",
                        help="Use this specific branch (skip auto-search)")
    parser.add_argument("--branch-filter",  default="",
                        help="Only scan branches whose name contains this string")
    parser.add_argument("--prefer-branch",  default="",
                        help="Prefer this branch on version tie")
    parser.add_argument("--no-branch-scan", action="store_true",
                        help="Disable branch scan; use hardcoded REPO_BRANCH")
    parser.add_argument("--scan-threads",   type=int, default=8,
                        help="Parallel threads for branch scan (default: 8)")
    parser.add_argument("--no-cache",       action="store_true",
                        help="Ignore cached branch scan results")
    parser.add_argument("--scan-timeout",   type=int, default=6,
                        help="Seconds per branch probe (default: 6)")
    # v2.5 retained
    parser.add_argument("--prefix",     default="/usr/local",
                        help="Install prefix (default: /usr/local)")
    parser.add_argument("--no-deps",    action="store_true",
                        help="Skip 'ai install-deps' after install")
    parser.add_argument("--cpu-only",   action="store_true",
                        help="Force --cpu-only for install-deps")
    parser.add_argument("--dry-run",    action="store_true",
                        help="Preview without executing")
    parser.add_argument("--keep-clone", action="store_true",
                        help="Keep the cloned repo after install")
    parser.add_argument("--arch",       default="",
                        help="Override arch: x86_64 | arm64 | armv7l")
    parser.add_argument("--arm-type",   default="",
                        help="Override ARM sub-type")
    parser.add_argument("--jetson",     action="store_true",
                        help="Shorthand for --arm-type jetson")
    parser.add_argument("--force",      action="store_true",
                        help="Force reinstall even if version is current")
    parser.add_argument("--update",     action="store_true",
                        help="Update existing install (skips confirmation)")
    parser.add_argument("--check",      action="store_true",
                        help="Check for updates and exit (no install)")
    args = parser.parse_args()

    dry    = args.dry_run
    prefix = Path(args.prefix).expanduser().resolve()

    # ── Detect platform ────────────────────────────────────────────────────────
    arch     = args.arch or detect_arch()
    arm_type = args.arm_type or ("jetson" if args.jetson else "")
    if arch == "arm64" and not arm_type:
        arm_type = detect_arm_type()
    cpu_feats = detect_cpu_features()

    # ── Banner ─────────────────────────────────────────────────────────────────
    hdr(f"╔══ AI CLI Installer v{INSTALLER_VERSION} ══╗")
    info(f"Repo:         {REPO_URL}")
    info(f"Prefix:       {prefix}")
    info(f"Platform:     {arch_label(arch, arm_type, cpu_feats)}")
    if arch == "x86_64":
        info(f"CPU tier:     {cpu_tier(cpu_feats)} (affects GGUF quantisation speed)")
    if dry:
        warn("DRY RUN — no changes will be made")

    # ══════════════════════════════════════════════════════════════════════════
    # v3: Branch selection
    # ══════════════════════════════════════════════════════════════════════════
    selected_branch = REPO_BRANCH
    scan_results    = []

    if args.branch:
        # User pinned a branch explicitly
        selected_branch = args.branch
        info(f"Branch:       {selected_branch}  (pinned via --branch)")

    elif args.no_branch_scan:
        selected_branch = REPO_BRANCH
        info(f"Branch:       {selected_branch}  (hardcoded, scan disabled)")

    else:
        # Auto-search all branches
        hdr("Branch Discovery — scanning all branches for latest version…")
        scan_results = scan_all_branches(
            branch_filter=args.branch_filter,
            prefer_branch=args.prefer_branch,
            threads=args.scan_threads,
            timeout=args.scan_timeout,
            no_cache=args.no_cache,
        )

        if scan_results:
            selected_branch, found_ver, found_scripts = pick_best_branch(scan_results)
            ok(f"Best branch:  {selected_branch}  (v{version_str(found_ver)}, "
               f"{len(found_scripts)} script(s))")
        else:
            warn("Branch scan returned no results — falling back to default branch.")
            selected_branch = REPO_BRANCH

        info(f"Branch:       {selected_branch}")

    # ── --list-branches mode ──────────────────────────────────────────────────
    if args.list_branches:
        if not scan_results:
            info("Running full branch scan…")
            scan_results = scan_all_branches(
                branch_filter=args.branch_filter,
                prefer_branch=args.prefer_branch,
                threads=args.scan_threads,
                timeout=args.scan_timeout,
                no_cache=args.no_cache,
            )
        cmd_list_branches(scan_results, arch)
        sys.exit(0)

    # ── 1. Check existing install ─────────────────────────────────────────────
    hdr("Step 1 — Checking existing installation…")
    existing      = find_existing_installs()
    installed_ver = (0, 0, 0)
    installed_path = None

    if existing:
        installed_path = existing[0]
        installed_ver  = detect_installed_version(installed_path)
        info(f"Found: {installed_path}  (version: {version_str(installed_ver)})")
    else:
        ok("No existing install found — fresh install.")

    # ── --check mode ──────────────────────────────────────────────────────────
    if args.check:
        hdr("Version check (remote)…")
        if scan_results:
            remote_ver = scan_results[0]["best_ver"]
            remote_branch = scan_results[0]["branch"]
        else:
            remote_ver    = check_remote_version(arch)
            remote_branch = selected_branch
        if remote_ver > (0, 0, 0):
            if remote_ver > installed_ver:
                warn(f"Update available: {version_str(installed_ver)} → "
                     f"{version_str(remote_ver)}  [{remote_branch}]")
                warn("Run: python3 install.py --update")
            else:
                ok(f"Up-to-date: v{version_str(installed_ver)}")
        else:
            info("Could not fetch remote version (offline?). Clone locally to check.")
        # Print top 5 branches with scripts
        if scan_results:
            print(f"\n  {BLD}Top branches by version:{RST}")
            for r in scan_results[:5]:
                tag = " ◀ current best" if r is scan_results[0] else ""
                print(f"    v{version_str(r['best_ver']):<10}  {r['branch']}{tag}")
        sys.exit(0)

    # ── 2. Clone latest ───────────────────────────────────────────────────────
    hdr(f"Step 2 — Fetching latest version from [{selected_branch}]…")
    tmp_dir    = Path(tempfile.mkdtemp(prefix="ai-cli-install-"))
    clone_dest = tmp_dir / "ai-cli"

    try:
        clone_repo(clone_dest, branch=selected_branch, dry_run=dry)

        if dry:
            latest_ver = (2, 8, 0)
            latest     = Path(f"main-v2.8{'-arm64' if arch=='arm64' else ''}")
        else:
            latest     = find_script_for_arch(clone_dest, arch)
            latest_ver = parse_version(latest.name)

        info(f"Available:    v{version_str(latest_ver)}  ({latest.name})")
        info(f"Installed:    v{version_str(installed_ver)}"
             if installed_ver != (0,0,0) else "Installed:    (none)")

        # If scan found an even newer branch, hint the user
        if scan_results and scan_results[0]["best_ver"] > latest_ver:
            top = scan_results[0]
            warn(f"Note: branch '{top['branch']}' may have a newer version "
                 f"(v{version_str(top['best_ver'])}) — run with "
                 f"--branch \"{top['branch']}\" to use it.")

        # ── Version check: skip if up-to-date ─────────────────────────────
        if installed_ver >= latest_ver and not args.force:
            if installed_ver == latest_ver:
                ok(f"Already up-to-date: v{version_str(installed_ver)}")
            else:
                ok(f"Installed v{version_str(installed_ver)} is newer than repo "
                   f"v{version_str(latest_ver)}")
            info("No reinstall needed. Use --force to reinstall anyway.")
            return

        # ── Confirm update ─────────────────────────────────────────────────
        if installed_ver != (0, 0, 0) and not args.update and not args.force and not dry:
            print()
            if installed_ver < latest_ver:
                msg = (f"Upgrade from v{version_str(installed_ver)} "
                       f"→ v{version_str(latest_ver)}")
            else:
                msg = f"Reinstall v{version_str(latest_ver)}"
            ans = input(f"  {BLD}{msg}?{RST} [Y/n]: ").strip().lower()
            if ans in ("n", "no"):
                info("Cancelled."); return

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
        print( "    ai gui                  # blessed TUI (v2.8)")
        print( "    ai gui-adv              # advanced 6-panel TUI (v2.8)")
        print()
        print(f"  {BLD}What's new in v{version_str(latest_ver)}:{RST}")
        if latest_ver >= (2, 8, 0):
            print("    ai workflow new pipeline # JSON pipeline engine")
            print("    ai batch summarize .     # batch process files with AI")
            print("    ai memo add              # AI-powered notes")
            print("    ai -Ad -m 21 -A \"task\"  # AI self-modifier")
            print("    ai gui / ai gui-adv      # npm blessed TUI")
        elif latest_ver >= (2, 6, 0):
            print("    ai project new mywork    # persistent multi-chat memory")
            print("    ai system set \"...\"     # apply system prompt to all backends")
            print("    ai finetune any <model>  # LoRA-tune any HuggingFace model")
        print()
        print(f"  {BLD}Branch management:{RST}")
        print( "    python3 install.py --list-branches     # show all branches + versions")
        print( "    python3 install.py --check             # check for updates")
        print( "    python3 install.py --update            # apply updates (auto-picks best)")
        print( "    python3 install.py --branch <name>     # install from specific branch")
        print( "    ai -aup                                # built-in updater")
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
