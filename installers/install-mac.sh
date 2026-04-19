#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — macOS Installer                                                   ║
# ║  Supports Intel and Apple Silicon (M1/M2/M3/M4)                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -e

REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"
BRANCH="main"
PREFIX="/usr/local"
DRY_RUN=0
FORCE=0
NO_DEPS=0
UNINSTALL=0

# ── Colors ─────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED="\033[0;31m" GREEN="\033[0;32m" YELLOW="\033[0;33m"
    BLUE="\033[0;34m" CYAN="\033[0;36m" BOLD="\033[1m" RESET="\033[0m"
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

info()  { printf "${BLUE}[INFO]${RESET}  %s\n"  "$*"; }
ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n"  "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n"  "$*"; }
err()   { printf "${RED}[ERR ]${RESET}  %s\n"  "$*" >&2; }
die()   { err "$*"; exit 1; }

banner() {
    printf "\n"
    printf "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}\n"
    printf "${CYAN}║    AI CLI — macOS Installer                        ║${RESET}\n"
    printf "${CYAN}║    Intel & Apple Silicon (M1/M2/M3/M4)             ║${RESET}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}\n"
    printf "\n"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --prefix DIR     Installation prefix (default: /usr/local)
  --branch NAME    Git branch (default: main)
  --force          Force reinstall
  --no-deps        Skip Homebrew dependency installation
  --dry-run        Preview actions
  --uninstall      Remove ai-cli
  -h, --help       Show this help
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --prefix)    PREFIX="$2"; shift 2 ;;
            --branch)    BRANCH="$2"; shift 2 ;;
            --force)     FORCE=1; shift ;;
            --no-deps)   NO_DEPS=1; shift ;;
            --dry-run)   DRY_RUN=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            -h|--help)   usage ;;
            *)           die "Unknown option: $1" ;;
        esac
    done
}

# ── Verify macOS ───────────────────────────────────────────────────────────────
verify_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        die "This installer is for macOS only."
    fi

    ARCH="$(uname -m)"
    MAC_VER="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

    case "$ARCH" in
        arm64)  CHIP_TYPE="Apple Silicon" ;;
        x86_64) CHIP_TYPE="Intel" ;;
        *)      CHIP_TYPE="$ARCH" ;;
    esac

    info "macOS ${BOLD}${MAC_VER}${RESET} (${CHIP_TYPE}, ${ARCH})"
}

# ── Package Manager (nanobrew or Homebrew) ────────────────────────────────────
ensure_homebrew() {
    if command -v nanobrew >/dev/null 2>&1; then
        ok "nanobrew found"
        return
    fi
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew found: $(brew --version | head -1)"
        return
    fi

    warn "Homebrew not found."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would install Homebrew"
        return
    fi

    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon
    if [ "$ARCH" = "arm64" ] && [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    ok "Homebrew installed"
}

# ── Install dependencies ──────────────────────────────────────────────────────
install_deps() {
    if [ "$NO_DEPS" -eq 1 ]; then
        info "Skipping dependencies (--no-deps)"
        return
    fi

    # Use nanobrew if available, otherwise Homebrew
    local PKG_CMD="brew"
    command -v nanobrew >/dev/null 2>&1 && PKG_CMD="nanobrew"
    info "Installing dependencies via ${PKG_CMD}..."

    DEPS="python@3.12 curl git bash"
    OPT_DEPS="ffmpeg jq node gh"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would install: ${DEPS} ${OPT_DEPS}"
        return
    fi

    for pkg in $DEPS; do
        $PKG_CMD install "$pkg" 2>/dev/null || $PKG_CMD upgrade "$pkg" 2>/dev/null || true
    done

    for pkg in $OPT_DEPS; do
        brew install "$pkg" 2>/dev/null || true
    done

    ok "Dependencies installed"
}

# ── Version check ─────────────────────────────────────────────────────────────
check_version() {
    INSTALLED_VER=""
    if [ -x "${PREFIX}/bin/ai" ]; then
        INSTALLED_VER=$(grep '^VERSION=' "${PREFIX}/bin/ai" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")
        [ -n "$INSTALLED_VER" ] && info "Installed: v${INSTALLED_VER}"
    fi

    info "Fetching remote version..."
    VERSION=$(curl -fsSL "${RAW_URL}/${BRANCH}/main.sh" 2>/dev/null \
        | grep '^VERSION=' | head -1 | cut -d'"' -f2 || echo "")

    if [ -z "$VERSION" ]; then
        die "Could not fetch remote version"
    fi
    info "Remote: v${VERSION}"

    if [ "$FORCE" -eq 0 ] && [ "$INSTALLED_VER" = "$VERSION" ]; then
        ok "Already up to date. Use --force to reinstall."
        exit 0
    fi
}

# ── Install ────────────────────────────────────────────────────────────────────
do_install() {
    info "Installing ai-cli v${VERSION}..."

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would install to ${PREFIX}/bin/ai"
        return
    fi

    TMPFILE=$(mktemp /tmp/ai-cli-XXXXXX)
    trap 'rm -f "$TMPFILE"' EXIT

    curl -fsSL "${RAW_URL}/${BRANCH}/main.sh" -o "$TMPFILE"

    # On macOS, /usr/local/bin usually doesn't need sudo for Homebrew users
    if [ -w "${PREFIX}/bin" ]; then
        install -m 0755 "$TMPFILE" "${PREFIX}/bin/ai"
    else
        sudo install -m 0755 "$TMPFILE" "${PREFIX}/bin/ai"
    fi

    # Share directory
    SHARE_DIR="${PREFIX}/share/ai-cli"
    mkdir -p "$SHARE_DIR" 2>/dev/null || sudo mkdir -p "$SHARE_DIR"

    for f in misc/requirements.txt misc/package.json; do
        curl -fsSL "${RAW_URL}/${BRANCH}/${f}" -o "${SHARE_DIR}/$(basename "$f")" 2>/dev/null || true
    done

    # Config
    mkdir -p "${HOME}/.config/ai-cli" 2>/dev/null || true
    if [ ! -f "${HOME}/.config/ai-cli/keys.env" ]; then
        cat > "${HOME}/.config/ai-cli/keys.env" <<'EOF'
# AI CLI — API Keys
# ai keys set OPENAI_API_KEY sk-...
# ai keys set ANTHROPIC_API_KEY sk-ant-...
EOF
    fi

    ok "Installed ${PREFIX}/bin/ai"
}

# ── Uninstall ──────────────────────────────────────────────────────────────────
do_uninstall() {
    info "Uninstalling ai-cli..."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would remove ${PREFIX}/bin/ai and ${PREFIX}/share/ai-cli/"
        exit 0
    fi

    for target in "${PREFIX}/bin/ai" "${PREFIX}/share/ai-cli"; do
        if [ -e "$target" ]; then
            if [ -w "$target" ] || [ -w "$(dirname "$target")" ]; then
                rm -rf "$target"
            else
                sudo rm -rf "$target"
            fi
            ok "Removed $target"
        fi
    done

    warn "Config at ~/.config/ai-cli/ preserved."
    exit 0
}

# ── Summary ────────────────────────────────────────────────────────────────────
summary() {
    printf "\n"
    printf "${GREEN}╔══════════════════════════════════════════════════════╗${RESET}\n"
    printf "${GREEN}║  ai-cli v%-10s installed on macOS!             ║${RESET}\n" "$VERSION"
    printf "${GREEN}╚══════════════════════════════════════════════════════╝${RESET}\n"
    printf "\n"
    printf "  ${BOLD}Quick start:${RESET}\n"
    printf "    ai --help             Show all commands\n"
    printf "    ai ask \"hello\"        One-shot question\n"
    printf "    ai chat               Interactive chat\n"
    printf "    ai recommended        Browse 195 curated models\n"
    printf "    ai install-deps       Install Python ML dependencies\n"
    printf "\n"
    if [ "$ARCH" = "arm64" ]; then
        printf "  ${BOLD}Apple Silicon note:${RESET}\n"
        printf "    Metal GPU acceleration is auto-detected for local models.\n"
        printf "\n"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    banner

    if [ "$UNINSTALL" -eq 1 ]; then
        do_uninstall
    fi

    verify_macos
    ensure_homebrew
    install_deps
    check_version
    do_install
    summary
}

main "$@"
