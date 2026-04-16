#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — Debian / Ubuntu / Mint / Pop!_OS Installer                        ║
# ║  Installs from .deb release or builds locally                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -e

REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
DRY_RUN=0
FORCE=0
NO_DEPS=0
FROM_SOURCE=0

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

banner() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$CYAN" "$RESET"
    printf "%s║    AI CLI — Debian / Ubuntu Installer               ║%s\n" "$CYAN" "$RESET"
    printf "%s║    .deb package from GitHub Releases                ║%s\n" "$CYAN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$CYAN" "$RESET"
    printf "\n"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --from-source     Build .deb locally instead of downloading
  --force           Force reinstall
  --no-deps         Skip optional dependencies
  --dry-run         Preview actions
  -h, --help        Show this help

Default: downloads latest .deb from GitHub Releases
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-source) FROM_SOURCE=1; shift ;;
            --force)       FORCE=1; shift ;;
            --no-deps)     NO_DEPS=1; shift ;;
            --dry-run)     DRY_RUN=1; shift ;;
            -h|--help)     usage ;;
            *)             die "Unknown option: $1" ;;
        esac
    done
}

# ── Verify Debian-based system ─────────────────────────────────────────────────
verify_debian() {
    if ! command -v dpkg >/dev/null 2>&1; then
        die "dpkg not found. This installer is for Debian-based systems."
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get not found. This installer is for Debian-based systems."
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "Detected: ${BOLD}${PRETTY_NAME:-$ID}${RESET}"
    fi
}

# ── Install base dependencies ─────────────────────────────────────────────────
install_base_deps() {
    info "Ensuring base dependencies are installed..."
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would install: bash python3 curl git"
        return
    fi

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        bash python3 python3-pip curl git ca-certificates

    if [ "$NO_DEPS" -eq 0 ]; then
        info "Installing recommended packages..."
        sudo apt-get install -y --no-install-recommends \
            ffmpeg jq nodejs npm 2>/dev/null || \
            warn "Some optional packages unavailable"
    fi

    ok "Dependencies installed"
}

# ── Fetch latest release info ─────────────────────────────────────────────────
fetch_latest_release() {
    info "Checking latest release on GitHub..."
    RELEASE_JSON=$(curl -fsSL "${API_URL}/releases/latest" 2>/dev/null || echo "")

    if [ -z "$RELEASE_JSON" ]; then
        warn "Could not fetch release info. Falling back to source install."
        FROM_SOURCE=1
        return
    fi

    # Parse tag name and .deb URL
    TAG_NAME=$(printf '%s' "$RELEASE_JSON" | grep '"tag_name"' | head -1 | \
        sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    DEB_URL=$(printf '%s' "$RELEASE_JSON" | grep '"browser_download_url"' | \
        grep '\.deb"' | head -1 | \
        sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ -z "$DEB_URL" ]; then
        warn "No .deb found in latest release. Falling back to source install."
        FROM_SOURCE=1
        return
    fi

    VERSION="${TAG_NAME#v}"
    info "Latest release: ${BOLD}${TAG_NAME}${RESET}"
    info "Package URL: ${DEB_URL}"
}

# ── Check installed version ────────────────────────────────────────────────────
check_installed() {
    INSTALLED_VER=$(dpkg-query -W -f='${Version}' ai-cli 2>/dev/null || echo "")
    if [ -n "$INSTALLED_VER" ]; then
        info "Currently installed: v${INSTALLED_VER}"
        if [ "$FORCE" -eq 0 ] && [ "$INSTALLED_VER" = "$VERSION" ]; then
            ok "Already up to date (v${VERSION}). Use --force to reinstall."
            exit 0
        fi
    fi
}

# ── Install from .deb download ─────────────────────────────────────────────────
install_deb() {
    TMPFILE=$(mktemp /tmp/ai-cli-XXXXXX.deb)
    trap 'rm -f "$TMPFILE"' EXIT

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would download: ${DEB_URL}"
        info "[DRY RUN] Would install via: sudo dpkg -i"
        return
    fi

    info "Downloading .deb package..."
    curl -fsSL "$DEB_URL" -o "$TMPFILE"

    info "Installing .deb package..."
    sudo dpkg -i "$TMPFILE" || true
    sudo apt-get install -f -y    # resolve any missing deps

    ok "ai-cli v${VERSION} installed via .deb"
}

# ── Build from source ─────────────────────────────────────────────────────────
build_from_source() {
    info "Building .deb from source..."

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would clone, build, and install .deb"
        return
    fi

    # Install build tools
    sudo apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot build-essential

    TMPDIR=$(mktemp -d /tmp/ai-cli-build-XXXXXX)
    trap 'rm -rf "$TMPDIR"' EXIT

    git clone --depth 1 "$REPO_URL" "$TMPDIR/ai-cli-src"
    cd "$TMPDIR/ai-cli-src"

    # Determine version
    VERSION=$(grep '^VERSION=' main.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "0.0.0")
    PKG="ai-cli"
    BUILD="${TMPDIR}/${PKG}_${VERSION}"

    mkdir -p "${BUILD}/usr/bin" \
             "${BUILD}/usr/share/${PKG}" \
             "${BUILD}/usr/share/doc/${PKG}" \
             "${BUILD}/DEBIAN"

    install -m 0755 main.sh "${BUILD}/usr/bin/ai"

    [ -f misc/requirements.txt ] && \
        install -m 0644 misc/requirements.txt "${BUILD}/usr/share/${PKG}/"
    [ -f README.md ] && \
        install -m 0644 README.md "${BUILD}/usr/share/doc/${PKG}/"

    cat > "${BUILD}/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${VERSION}
Architecture: all
Maintainer: minerofthesoal <https://github.com/minerofthesoal/ai-cli>
Section: utils
Priority: optional
Depends: bash (>= 5.0), python3 (>= 3.10), curl, git
Recommends: python3-pip, ffmpeg, jq
Suggests: gh
Homepage: https://github.com/${REPO_OWNER}/${REPO_NAME}
Description: AI CLI — local + cloud LLM terminal toolkit
 Unified terminal interface for local and cloud AI models.
EOF

    fakeroot dpkg-deb --build --root-owner-group "${BUILD}"
    sudo dpkg -i "${TMPDIR}/${PKG}_${VERSION}.deb" || true
    sudo apt-get install -f -y

    ok "ai-cli v${VERSION} built and installed from source"
}

# ── Summary ────────────────────────────────────────────────────────────────────
summary() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$GREEN" "$RESET"
    printf "%s║  ai-cli installed on Debian/Ubuntu!                 ║%s\n" "$GREEN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$GREEN" "$RESET"
    printf "\n"
    printf "  %sQuick start:%s\n" "$BOLD" "$RESET"
    printf "    ai --help             Show all commands\n"
    printf "    ai ask \"hello\"        One-shot question\n"
    printf "    ai chat               Interactive chat\n"
    printf "    ai recommended        Browse 195 curated models\n"
    printf "\n"
    printf "  %sPackage management:%s\n" "$BOLD" "$RESET"
    printf "    dpkg -l ai-cli        Package info\n"
    printf "    sudo apt remove ai-cli  Uninstall\n"
    printf "\n"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    banner
    verify_debian
    install_base_deps

    if [ "$FROM_SOURCE" -eq 1 ]; then
        build_from_source
    else
        fetch_latest_release
        if [ "$FROM_SOURCE" -eq 1 ]; then
            build_from_source
        else
            check_installed
            install_deb
        fi
    fi

    summary
}

main "$@"
