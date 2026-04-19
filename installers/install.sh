#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — Universal POSIX sh Installer                                      ║
# ║  Works on any POSIX-compliant system: Linux, macOS, WSL, BSD                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -e

# ── Constants ──────────────────────────────────────────────────────────────────
REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"
INSTALL_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/ai-cli"
CONFIG_DIR="${HOME}/.config/ai-cli"
SCRIPT_NAME="ai"
VERSION=""
BRANCH="main"
PREFIX="/usr/local"
DRY_RUN=0
FORCE=0
NO_DEPS=0
CPU_ONLY=0
UNINSTALL=0

# ── Colors (only if terminal supports them) ────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

# ── Logging ────────────────────────────────────────────────────────────────────
info()  { printf "%s[INFO]%s  %s\n"  "$BLUE"   "$RESET" "$*"; }
ok()    { printf "%s[ OK ]%s  %s\n"  "$GREEN"  "$RESET" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n"  "$YELLOW" "$RESET" "$*"; }
err()   { printf "%s[ERR ]%s  %s\n"  "$RED"    "$RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ── Banner ─────────────────────────────────────────────────────────────────────
banner() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$CYAN" "$RESET"
    printf "%s║     AI CLI — Universal Installer                    ║%s\n" "$CYAN" "$RESET"
    printf "%s║     Local + Cloud LLM Terminal Toolkit              ║%s\n" "$CYAN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$CYAN" "$RESET"
    printf "\n"
}

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --prefix DIR       Installation prefix (default: /usr/local)
  --branch NAME      Git branch to install from (default: main)
  --force            Force reinstall even if version matches
  --no-deps          Skip dependency installation
  --cpu-only         Force CPU-only mode (no CUDA/Metal)
  --dry-run          Show what would be done without doing it
  --uninstall        Remove ai-cli from the system
  -h, --help         Show this help message

Examples:
  curl -fsSL ${RAW_URL}/main/installers/install.sh | sh
  sh install.sh --prefix /opt/ai-cli
  sh install.sh --branch develop --cpu-only
  sh install.sh --uninstall
EOF
    exit 0
}

# ── Parse arguments ────────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --prefix)    PREFIX="$2"; shift 2 ;;
            --branch)    BRANCH="$2"; shift 2 ;;
            --force)     FORCE=1; shift ;;
            --no-deps)   NO_DEPS=1; shift ;;
            --cpu-only)  CPU_ONLY=1; shift ;;
            --dry-run)   DRY_RUN=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            -h|--help)   usage ;;
            *)           die "Unknown option: $1 (use --help)" ;;
        esac
    done
    INSTALL_DIR="${PREFIX}/bin"
    SHARE_DIR="${PREFIX}/share/ai-cli"
}

# ── Platform detection ─────────────────────────────────────────────────────────
detect_platform() {
    OS="$(uname -s 2>/dev/null || echo unknown)"
    ARCH="$(uname -m 2>/dev/null || echo unknown)"

    case "$OS" in
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        Darwin)   PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        FreeBSD)  PLATFORM="freebsd" ;;
        *)        PLATFORM="unknown" ;;
    esac

    # Detect distro on Linux
    DISTRO="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
    elif [ -f /etc/arch-release ]; then
        DISTRO="arch"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
    fi

    info "Platform: ${BOLD}${PLATFORM}${RESET} | Arch: ${BOLD}${ARCH}${RESET} | Distro: ${BOLD}${DISTRO}${RESET}"
}

# ── Privilege escalation ──────────────────────────────────────────────────────
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        elif command -v doas >/dev/null 2>&1; then
            SUDO="doas"
        else
            die "Root privileges required. Run with sudo or as root."
        fi
    else
        SUDO=""
    fi
}

# ── Check dependencies ────────────────────────────────────────────────────────
check_deps() {
    MISSING=""
    for cmd in curl git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            MISSING="$MISSING $cmd"
        fi
    done

    if [ -n "$MISSING" ]; then
        warn "Missing required tools:${MISSING}"
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRY RUN] Would install:${MISSING}"
            return
        fi
        info "Attempting to install missing tools..."
        case "$DISTRO" in
            ubuntu|debian|linuxmint|pop)
                $SUDO apt-get update -qq && $SUDO apt-get install -y $MISSING ;;
            arch|manjaro|endeavouros)
                $SUDO pacman -Sy --noconfirm $MISSING ;;
            fedora)
                $SUDO dnf install -y $MISSING ;;
            rhel|centos|rocky|alma)
                $SUDO yum install -y $MISSING ;;
            opensuse*|sles)
                $SUDO zypper install -y $MISSING ;;
            alpine)
                $SUDO apk add $MISSING ;;
            void)
                $SUDO xbps-install -Sy $MISSING ;;
            *)
                if [ "$PLATFORM" = "macos" ]; then
                    if command -v nanobrew >/dev/null 2>&1; then
                        nanobrew install $MISSING
                    elif command -v brew >/dev/null 2>&1; then
                        brew install $MISSING
                    else
                        die "Install nanobrew or Homebrew first"
                    fi
                else
                    die "Cannot auto-install on ${DISTRO}. Please install:${MISSING}"
                fi
                ;;
        esac
    fi
    ok "All required tools available"
}

# ── Check for Python 3.10+ ────────────────────────────────────────────────────
check_python() {
    PY=""
    for candidate in python3 python python3.12 python3.11 python3.10; do
        if command -v "$candidate" >/dev/null 2>&1; then
            ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
            major=$(echo "$ver" | cut -d. -f1)
            minor=$(echo "$ver" | cut -d. -f2)
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                PY="$candidate"
                break
            fi
        fi
    done

    if [ -z "$PY" ]; then
        warn "Python 3.10+ not found. Some features require Python."
    else
        ok "Python: $($PY --version 2>&1)"
    fi
}

# ── Version check ─────────────────────────────────────────────────────────────
check_installed_version() {
    if [ -x "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        INSTALLED_VER=$(grep '^VERSION=' "${INSTALL_DIR}/${SCRIPT_NAME}" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")
        if [ -n "$INSTALLED_VER" ]; then
            info "Installed version: ${BOLD}${INSTALLED_VER}${RESET}"
        fi
    else
        INSTALLED_VER=""
    fi
}

# ── Fetch latest version from remote ──────────────────────────────────────────
fetch_remote_version() {
    info "Fetching latest version from branch '${BRANCH}'..."
    VERSION=$(curl -fsSL "${RAW_URL}/${BRANCH}/main.sh" 2>/dev/null \
        | grep '^VERSION=' | head -1 | cut -d'"' -f2 || echo "")

    if [ -z "$VERSION" ]; then
        die "Could not determine remote version. Check branch name and network."
    fi
    info "Remote version: ${BOLD}${VERSION}${RESET}"
}

# ── Compare versions ──────────────────────────────────────────────────────────
should_install() {
    if [ "$FORCE" -eq 1 ]; then
        return 0
    fi
    if [ -z "$INSTALLED_VER" ]; then
        return 0
    fi
    if [ "$INSTALLED_VER" = "$VERSION" ]; then
        ok "Already up to date (v${VERSION}). Use --force to reinstall."
        exit 0
    fi
    return 0
}

# ── Download and install ──────────────────────────────────────────────────────
do_install() {
    info "Installing ai-cli v${VERSION} to ${INSTALL_DIR}/${SCRIPT_NAME}..."

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would download main.sh from branch '${BRANCH}'"
        info "[DRY RUN] Would install to ${INSTALL_DIR}/${SCRIPT_NAME}"
        info "[DRY RUN] Would create ${SHARE_DIR}/"
        info "[DRY RUN] Would create ${CONFIG_DIR}/"
        return
    fi

    # Create directories
    $SUDO mkdir -p "$INSTALL_DIR" "$SHARE_DIR"
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true

    # Download main script
    TMPFILE=$(mktemp /tmp/ai-cli-XXXXXX)
    trap 'rm -f "$TMPFILE"' EXIT

    info "Downloading main.sh..."
    curl -fsSL "${RAW_URL}/${BRANCH}/main.sh" -o "$TMPFILE"

    # Verify download
    if [ ! -s "$TMPFILE" ]; then
        die "Download failed or file is empty"
    fi

    # Verify it's actually a bash script
    HEAD=$(head -1 "$TMPFILE")
    case "$HEAD" in
        *bash*|*sh*) ;;
        *) die "Downloaded file doesn't look like a shell script" ;;
    esac

    # Install
    $SUDO install -m 0755 "$TMPFILE" "${INSTALL_DIR}/${SCRIPT_NAME}"
    ok "Installed ${INSTALL_DIR}/${SCRIPT_NAME}"

    # Download support files
    for f in misc/requirements.txt misc/package.json; do
        URL="${RAW_URL}/${BRANCH}/${f}"
        DEST="${SHARE_DIR}/$(basename "$f")"
        curl -fsSL "$URL" -o "$DEST" 2>/dev/null && \
            ok "Installed ${DEST}" || \
            warn "Optional file ${f} not available"
    done

    # Create default config
    if [ ! -f "${CONFIG_DIR}/keys.env" ]; then
        cat > "${CONFIG_DIR}/keys.env" <<'KEYSEOF'
# AI CLI — API Keys
# Run: ai keys set OPENAI_API_KEY sk-...
# Run: ai keys set ANTHROPIC_API_KEY sk-ant-...
# Run: ai keys set GEMINI_API_KEY AIza...
KEYSEOF
        ok "Created ${CONFIG_DIR}/keys.env"
    fi
}

# ── Install dependencies ──────────────────────────────────────────────────────
install_deps() {
    if [ "$NO_DEPS" -eq 1 ]; then
        info "Skipping dependency installation (--no-deps)"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would run: ai install-deps"
        return
    fi

    if command -v ai >/dev/null 2>&1; then
        info "Installing AI CLI dependencies..."
        if [ "$CPU_ONLY" -eq 1 ]; then
            ai install-deps --cpu-only || warn "Dependency install returned non-zero"
        else
            ai install-deps || warn "Dependency install returned non-zero"
        fi
    fi
}

# ── Uninstall ──────────────────────────────────────────────────────────────────
do_uninstall() {
    info "Uninstalling ai-cli..."

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would remove ${INSTALL_DIR}/${SCRIPT_NAME}"
        info "[DRY RUN] Would remove ${SHARE_DIR}/"
        info "[DRY RUN] Config at ${CONFIG_DIR}/ would be preserved"
        return
    fi

    need_root

    if [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]; then
        $SUDO rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
        ok "Removed ${INSTALL_DIR}/${SCRIPT_NAME}"
    else
        warn "${INSTALL_DIR}/${SCRIPT_NAME} not found"
    fi

    if [ -d "$SHARE_DIR" ]; then
        $SUDO rm -rf "$SHARE_DIR"
        ok "Removed ${SHARE_DIR}/"
    fi

    warn "Config directory ${CONFIG_DIR}/ preserved. Remove manually if desired."
    ok "ai-cli uninstalled"
    exit 0
}

# ── Post-install summary ──────────────────────────────────────────────────────
summary() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$GREEN" "$RESET"
    printf "%s║  ai-cli v%-10s installed successfully!         ║%s\n" "$GREEN" "$VERSION" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$GREEN" "$RESET"
    printf "\n"
    printf "  %sQuick start:%s\n" "$BOLD" "$RESET"
    printf "    ai --help             Show all commands\n"
    printf "    ai ask \"hello\"        One-shot question\n"
    printf "    ai chat               Interactive chat\n"
    printf "    ai recommended        Browse 195 curated models\n"
    printf "    ai keys set KEY VAL   Set an API key\n"
    printf "\n"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    banner

    if [ "$UNINSTALL" -eq 1 ]; then
        do_uninstall
    fi

    detect_platform
    need_root
    check_deps
    check_python
    check_installed_version
    fetch_remote_version
    should_install
    do_install
    install_deps
    summary
}

main "$@"
