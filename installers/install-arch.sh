#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — Arch Linux / Pacman Installer                                     ║
# ║  Supports: Arch, Manjaro, EndeavourOS, Garuda, Artix                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -e

REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
AUR_PKG="ai-cli"
PREFIX="/usr"
DRY_RUN=0
FORCE=0
USE_AUR=0
AUR_HELPER=""
NO_DEPS=0

# ── Colors ─────────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4) CYAN=$(tput setaf 6) BOLD=$(tput bold) RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

info()  { printf "%s[INFO]%s  %s\n"  "$BLUE"   "$RESET" "$*"; }
ok()    { printf "%s[ OK ]%s  %s\n"  "$GREEN"  "$RESET" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n"  "$YELLOW" "$RESET" "$*"; }
err()   { printf "%s[ERR ]%s  %s\n"  "$RED"    "$RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ── Banner ─────────────────────────────────────────────────────────────────────
banner() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$CYAN" "$RESET"
    printf "%s║    AI CLI — Arch Linux Installer                    ║%s\n" "$CYAN" "$RESET"
    printf "%s║    pacman / AUR / manual install                    ║%s\n" "$CYAN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$CYAN" "$RESET"
    printf "\n"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --aur              Install from AUR (requires AUR helper)
  --aur-helper CMD   Specify AUR helper (yay, paru, trizen, pikaur)
  --force            Force reinstall
  --no-deps          Skip optional dependency installation
  --dry-run          Preview actions
  -h, --help         Show this help

Install methods:
  1. AUR (recommended):  $0 --aur
  2. Manual PKGBUILD:    $0
  3. Direct install:     $0 --direct
EOF
    exit 0
}

parse_args() {
    DIRECT=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --aur)        USE_AUR=1; shift ;;
            --aur-helper) AUR_HELPER="$2"; shift 2 ;;
            --direct)     DIRECT=1; shift ;;
            --force)      FORCE=1; shift ;;
            --no-deps)    NO_DEPS=1; shift ;;
            --dry-run)    DRY_RUN=1; shift ;;
            -h|--help)    usage ;;
            *)            die "Unknown option: $1" ;;
        esac
    done
}

# ── Verify we're on Arch-based system ──────────────────────────────────────────
verify_arch() {
    if ! command -v pacman >/dev/null 2>&1; then
        die "pacman not found. This installer is for Arch Linux and derivatives."
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "Detected: ${BOLD}${PRETTY_NAME:-$ID}${RESET}"
    else
        info "Detected: Arch-based system"
    fi
}

# ── Detect AUR helper ─────────────────────────────────────────────────────────
detect_aur_helper() {
    if [ -n "$AUR_HELPER" ]; then
        if command -v "$AUR_HELPER" >/dev/null 2>&1; then
            ok "Using AUR helper: ${AUR_HELPER}"
            return
        else
            die "Specified AUR helper '${AUR_HELPER}' not found"
        fi
    fi

    for helper in paru yay trizen pikaur; do
        if command -v "$helper" >/dev/null 2>&1; then
            AUR_HELPER="$helper"
            ok "Found AUR helper: ${AUR_HELPER}"
            return
        fi
    done

    warn "No AUR helper found. Install one with:"
    printf "    sudo pacman -S --needed git base-devel\n"
    printf "    git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si\n"
    die "AUR helper required for --aur install"
}

# ── Install core dependencies via pacman ───────────────────────────────────────
install_pacman_deps() {
    info "Installing core dependencies via pacman..."

    DEPS="bash python python-pip curl git"
    OPT_DEPS="ffmpeg jq nodejs npm github-cli"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would run: sudo pacman -S --needed ${DEPS}"
        [ "$NO_DEPS" -eq 0 ] && info "[DRY RUN] Would install optional: ${OPT_DEPS}"
        return
    fi

    sudo pacman -S --needed --noconfirm $DEPS
    ok "Core dependencies installed"

    if [ "$NO_DEPS" -eq 0 ]; then
        info "Installing optional dependencies..."
        # Use --needed to skip already-installed packages; don't fail on optional
        sudo pacman -S --needed --noconfirm $OPT_DEPS 2>/dev/null || \
            warn "Some optional dependencies could not be installed"
    fi
}

# ── Install from AUR ──────────────────────────────────────────────────────────
install_aur() {
    detect_aur_helper

    info "Installing ${AUR_PKG} from AUR via ${AUR_HELPER}..."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would run: ${AUR_HELPER} -S ${AUR_PKG}"
        return
    fi

    if [ "$FORCE" -eq 1 ]; then
        $AUR_HELPER -S --rebuild "$AUR_PKG"
    else
        $AUR_HELPER -S "$AUR_PKG"
    fi
    ok "Installed ${AUR_PKG} from AUR"
}

# ── Build from PKGBUILD ───────────────────────────────────────────────────────
install_pkgbuild() {
    info "Building from PKGBUILD..."

    # Ensure base-devel is available
    if [ "$DRY_RUN" -eq 0 ]; then
        sudo pacman -S --needed --noconfirm base-devel
    fi

    TMPDIR=$(mktemp -d /tmp/ai-cli-build-XXXXXX)
    trap 'rm -rf "$TMPDIR"' EXIT

    info "Cloning repository..."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would clone and build PKGBUILD"
        return
    fi

    git clone --depth 1 "$REPO_URL" "$TMPDIR/ai-cli"

    # Use the PKGBUILD from the packaging directory
    if [ -f "$TMPDIR/ai-cli/packaging/PKGBUILD" ]; then
        cp "$TMPDIR/ai-cli/packaging/PKGBUILD" "$TMPDIR/"
    else
        die "PKGBUILD not found in repository"
    fi

    cd "$TMPDIR"
    makepkg -si --noconfirm
    ok "Package built and installed via makepkg"
}

# ── Direct install (skip packaging) ───────────────────────────────────────────
install_direct() {
    info "Direct install (bypassing package manager)..."

    TMPFILE=$(mktemp /tmp/ai-cli-XXXXXX)
    trap 'rm -f "$TMPFILE"' EXIT

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would download main.sh and install to /usr/local/bin/ai"
        return
    fi

    curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/main.sh" -o "$TMPFILE"
    sudo install -m 0755 "$TMPFILE" /usr/local/bin/ai
    ok "Installed /usr/local/bin/ai"

    # Create config directory
    mkdir -p "${HOME}/.config/ai-cli" 2>/dev/null || true
    ok "Direct install complete"
}

# ── Post-install ───────────────────────────────────────────────────────────────
post_install() {
    # Get installed version
    VER=""
    if command -v ai >/dev/null 2>&1; then
        VER=$(ai --version 2>/dev/null | head -1 || echo "")
    fi

    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$GREEN" "$RESET"
    printf "%s║  ai-cli installed on Arch Linux!                    ║%s\n" "$GREEN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$GREEN" "$RESET"
    printf "\n"
    printf "  %sQuick start:%s\n" "$BOLD" "$RESET"
    printf "    ai --help             Show all commands\n"
    printf "    ai ask \"hello\"        One-shot question\n"
    printf "    ai chat               Interactive chat\n"
    printf "    ai recommended        Browse 195 curated models\n"
    printf "    ai install-deps       Install Python ML dependencies\n"
    printf "\n"
    printf "  %sPackage management:%s\n" "$BOLD" "$RESET"
    printf "    pacman -Qi ai-cli     Package info\n"
    printf "    pacman -R ai-cli      Uninstall\n"
    printf "\n"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    banner
    verify_arch
    install_pacman_deps

    if [ "$USE_AUR" -eq 1 ]; then
        install_aur
    elif [ "$DIRECT" -eq 1 ]; then
        install_direct
    else
        install_pkgbuild
    fi

    post_install
}

main "$@"
