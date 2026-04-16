#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — RPM Installer (Fedora / RHEL / CentOS / Rocky / Alma / openSUSE) ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -e

REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
DRY_RUN=0
FORCE=0
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

banner() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$CYAN" "$RESET"
    printf "%s║    AI CLI — RPM-Based Distro Installer              ║%s\n" "$CYAN" "$RESET"
    printf "%s║    Fedora / RHEL / CentOS / Rocky / openSUSE        ║%s\n" "$CYAN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$CYAN" "$RESET"
    printf "\n"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --force          Force reinstall
  --no-deps        Skip optional dependencies
  --dry-run        Preview actions
  -h, --help       Show this help

Builds an RPM from source or installs directly.
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)    FORCE=1; shift ;;
            --no-deps)  NO_DEPS=1; shift ;;
            --dry-run)  DRY_RUN=1; shift ;;
            -h|--help)  usage ;;
            *)          die "Unknown option: $1" ;;
        esac
    done
}

# ── Detect RPM-based distro and package manager ───────────────────────────────
detect_distro() {
    if ! command -v rpm >/dev/null 2>&1; then
        die "rpm not found. This installer is for RPM-based distributions."
    fi

    DISTRO="unknown"
    PKG_MGR="dnf"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
        info "Detected: ${BOLD}${PRETTY_NAME:-$ID}${RESET}"
    fi

    # Determine package manager
    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
    else
        die "No supported package manager found (dnf, yum, zypper)"
    fi

    info "Package manager: ${BOLD}${PKG_MGR}${RESET}"
}

# ── Install dependencies ──────────────────────────────────────────────────────
install_deps() {
    info "Installing dependencies..."

    CORE_DEPS="bash python3 python3-pip curl git"
    OPT_DEPS="ffmpeg jq nodejs npm"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would install: ${CORE_DEPS}"
        return
    fi

    case "$PKG_MGR" in
        dnf)
            sudo dnf install -y $CORE_DEPS
            [ "$NO_DEPS" -eq 0 ] && sudo dnf install -y $OPT_DEPS 2>/dev/null || true
            ;;
        yum)
            sudo yum install -y $CORE_DEPS
            [ "$NO_DEPS" -eq 0 ] && sudo yum install -y $OPT_DEPS 2>/dev/null || true
            ;;
        zypper)
            sudo zypper install -y $CORE_DEPS
            [ "$NO_DEPS" -eq 0 ] && sudo zypper install -y $OPT_DEPS 2>/dev/null || true
            ;;
    esac

    ok "Dependencies installed"
}

# ── Build RPM from source ─────────────────────────────────────────────────────
build_rpm() {
    info "Building RPM package from source..."

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would build RPM from repository"
        return
    fi

    # Install build tools
    case "$PKG_MGR" in
        dnf)    sudo dnf install -y rpm-build rpmdevtools ;;
        yum)    sudo yum install -y rpm-build rpmdevtools ;;
        zypper) sudo zypper install -y rpm-build rpmdevtools ;;
    esac

    # Setup RPM build tree
    rpmdev-setuptree 2>/dev/null || {
        mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    }

    # Clone and prepare source
    TMPDIR=$(mktemp -d /tmp/ai-cli-rpm-XXXXXX)
    trap 'rm -rf "$TMPDIR"' EXIT

    git clone --depth 1 "$REPO_URL" "$TMPDIR/ai-cli"
    cd "$TMPDIR/ai-cli"

    VERSION=$(grep '^VERSION=' main.sh 2>/dev/null | head -1 | cut -d'"' -f2 || echo "0.0.0")
    # RPM doesn't allow hyphens in version; replace dots after 4th segment
    RPM_VERSION=$(echo "$VERSION" | sed 's/-/./g')

    info "Building RPM for version ${RPM_VERSION}..."

    # Create tarball
    TARNAME="ai-cli-${RPM_VERSION}"
    mkdir -p "$TMPDIR/$TARNAME"
    cp main.sh "$TMPDIR/$TARNAME/"
    [ -f misc/requirements.txt ] && cp misc/requirements.txt "$TMPDIR/$TARNAME/"
    [ -f README.md ] && cp README.md "$TMPDIR/$TARNAME/"
    [ -f LICENSE ] && cp LICENSE "$TMPDIR/$TARNAME/"

    cd "$TMPDIR"
    tar czf ~/rpmbuild/SOURCES/${TARNAME}.tar.gz "$TARNAME"

    # Generate spec file
    cat > ~/rpmbuild/SPECS/ai-cli.spec <<SPEC
Name:           ai-cli
Version:        ${RPM_VERSION}
Release:        1%{?dist}
Summary:        AI CLI — local + cloud LLM terminal toolkit
License:        MIT
URL:            https://github.com/${REPO_OWNER}/${REPO_NAME}
Source0:        %{name}-%{version}.tar.gz

Requires:       bash >= 5.0
Requires:       python3 >= 3.10
Requires:       curl
Requires:       git
Recommends:     python3-pip
Recommends:     ffmpeg
Suggests:       jq

BuildArch:      noarch

%description
Unified terminal interface for local and cloud AI models.
Supports GGUF (llama.cpp), OpenAI, Claude, Gemini, Groq, Mistral APIs.
Includes model training, RLHF, Canvas v3 workspace, and 195 curated models.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/%{name}
mkdir -p %{buildroot}/usr/share/doc/%{name}
mkdir -p %{buildroot}/usr/share/licenses/%{name}

install -m 0755 main.sh %{buildroot}/usr/bin/ai
[ -f requirements.txt ] && install -m 0644 requirements.txt %{buildroot}/usr/share/%{name}/
[ -f README.md ] && install -m 0644 README.md %{buildroot}/usr/share/doc/%{name}/
[ -f LICENSE ] && install -m 0644 LICENSE %{buildroot}/usr/share/licenses/%{name}/

%files
/usr/bin/ai
/usr/share/%{name}/
/usr/share/doc/%{name}/
/usr/share/licenses/%{name}/

%post
echo ""
echo "  ai-cli %{version} installed!"
echo "  Run: ai --help"
echo ""

%changelog
* $(date '+%a %b %d %Y') minerofthesoal - ${RPM_VERSION}-1
- Automated RPM build from GitHub source
SPEC

    # Build the RPM
    rpmbuild -bb ~/rpmbuild/SPECS/ai-cli.spec

    # Install the RPM
    RPM_FILE=$(ls ~/rpmbuild/RPMS/noarch/ai-cli-*.rpm 2>/dev/null | head -1)
    if [ -n "$RPM_FILE" ]; then
        sudo rpm -Uvh --force "$RPM_FILE"
        ok "ai-cli v${RPM_VERSION} installed from RPM"
    else
        die "RPM build produced no output"
    fi
}

# ── Direct install fallback ───────────────────────────────────────────────────
install_direct() {
    info "Direct install (no package manager)..."

    TMPFILE=$(mktemp /tmp/ai-cli-XXXXXX)
    trap 'rm -f "$TMPFILE"' EXIT

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY RUN] Would download main.sh to /usr/local/bin/ai"
        return
    fi

    curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/main.sh" -o "$TMPFILE"
    sudo install -m 0755 "$TMPFILE" /usr/local/bin/ai
    mkdir -p "${HOME}/.config/ai-cli" 2>/dev/null || true
    ok "Installed /usr/local/bin/ai"
}

# ── Summary ────────────────────────────────────────────────────────────────────
summary() {
    printf "\n"
    printf "%s╔══════════════════════════════════════════════════════╗%s\n" "$GREEN" "$RESET"
    printf "%s║  ai-cli installed on RPM-based system!              ║%s\n" "$GREEN" "$RESET"
    printf "%s╚══════════════════════════════════════════════════════╝%s\n" "$GREEN" "$RESET"
    printf "\n"
    printf "  %sQuick start:%s\n" "$BOLD" "$RESET"
    printf "    ai --help             Show all commands\n"
    printf "    ai ask \"hello\"        One-shot question\n"
    printf "    ai chat               Interactive chat\n"
    printf "    ai recommended        Browse 195 curated models\n"
    printf "\n"
    printf "  %sPackage management:%s\n" "$BOLD" "$RESET"
    printf "    rpm -qi ai-cli        Package info\n"
    printf "    sudo %s remove ai-cli   Uninstall\n" "$PKG_MGR"
    printf "\n"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    banner
    detect_distro
    install_deps
    build_rpm
    summary
}

main "$@"
