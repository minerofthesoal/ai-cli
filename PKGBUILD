# Maintainer: minerofthesoal <https://github.com/minerofthesoal>
# AUR package: ai-cli
# Install:  yay -S ai-cli   OR   sudo pacman -S ai-cli  (once in AUR)
# Manual:   makepkg -si

pkgname=ai-cli
pkgver=2.6
pkgrel=1
pkgdesc="Universal AI shell — chat, vision, RLHF, LoRA, TTM, GPU/CPU, rclick, GUI"
arch=('x86_64' 'aarch64' 'armv7h')
url="https://github.com/minerofthesoal/ai-cli"
license=('MIT')
depends=(
    'bash'
    'python'
    'python-pip'
    'git'
    'curl'
)
optdepends=(
    'python-torch: PyTorch inference / training'
    'python-transformers: HuggingFace model support'
    'python-peft: LoRA fine-tuning'
    'python-trl: SFT / DPO / PPO training'
    'python-datasets: HuggingFace datasets'
    'ffmpeg: audio/video support'
    'xclip: X11 clipboard (rclick text selection)'
    'wl-clipboard: Wayland clipboard (rclick text selection)'
    'zenity: GUI dialogs (rclick action menu)'
    'kdialog: KDE dialogs (rclick action menu)'
    'yad: YAD dialogs (alternative to zenity)'
    'tk: Python Tkinter dialogs fallback'
    'xdotool: X11 key simulation'
    'libnotify: desktop notifications'
    'nvml: NVIDIA GPU detection'
)
provides=('ai-cli' 'ai')
conflicts=('ai-cli-git')
source=("${pkgname}-${pkgver}.tar.gz::${url}/archive/refs/heads/claude/cpu-windows-llm-api-uiTei.tar.gz")
sha256sums=('SKIP')

# Override source for local builds
_local_src="${SRCDEST}/${pkgname}-local"

prepare() {
    # If building from local source (dev mode), use that
    if [[ -d "$_local_src" ]]; then
        cp -r "$_local_src" "${srcdir}/${pkgname}-${pkgver}"
    fi
}

build() {
    # Nothing to compile — pure shell script
    :
}

_pick_script() {
    # Pick the best script for this architecture
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"
    [[ -d "${src}" ]] || src="${srcdir}/${pkgname}-${pkgver}"

    case "${CARCH}" in
        aarch64)
            # Prefer ARM64-specific build
            local arm64_script
            arm64_script=$(ls "${src}"/main-v*-arm64 2>/dev/null | sort -V | tail -1)
            if [[ -n "${arm64_script}" ]]; then
                echo "${arm64_script}"
                return
            fi
            ;;
    esac

    # Generic / x86_64 / armv7h: pick latest main-v* without -arm64 suffix
    local generic_script
    generic_script=$(ls "${src}"/main-v* 2>/dev/null | grep -v '\-arm64$' | sort -V | tail -1)
    echo "${generic_script}"
}

package() {
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"
    [[ -d "${src}" ]] || src="${srcdir}/${pkgname}-${pkgver}"

    local script
    script=$(_pick_script)
    if [[ -z "${script}" || ! -f "${script}" ]]; then
        error "No main-v* script found in source directory"
        return 1
    fi

    msg2 "Selected script: $(basename ${script})"

    # Install the main 'ai' binary
    install -Dm755 "${script}" "${pkgdir}/usr/local/bin/ai"

    # Install the Python installer
    if [[ -f "${src}/install.py" ]]; then
        install -Dm755 "${src}/install.py" "${pkgdir}/usr/share/ai-cli/install.py"
    fi

    # Install PKGBUILD for reference
    install -Dm644 "${src}/PKGBUILD" "${pkgdir}/usr/share/ai-cli/PKGBUILD" 2>/dev/null || true

    # Install README if present
    if [[ -f "${src}/README.md" ]]; then
        install -Dm644 "${src}/README.md" "${pkgdir}/usr/share/doc/ai-cli/README.md"
    fi

    # Create config directory placeholder
    install -dm755 "${pkgdir}/etc/ai-cli"

    # Post-install message
    msg2 "Run 'ai install-deps' after installing to set up Python dependencies"
    msg2 "Run 'ai recommended' to browse and download AI models"
    msg2 "Run 'ai -gui' to launch the interactive TUI"
}

post_install() {
    echo ""
    echo "  AI CLI v${pkgver} installed!"
    echo ""
    echo "  Run these commands to get started:"
    echo "    ai install-deps      # Install Python deps (torch, transformers, etc.)"
    echo "    ai recommended       # Browse curated models"
    echo "    ai ask \"Hello!\"    # Test it out"
    echo "    ai -gui              # Launch TUI"
    echo "    ai project new work  # Create a project with memory"
    echo "    ai help              # See all commands"
    echo ""
}

post_upgrade() {
    echo ""
    echo "  AI CLI upgraded to v${pkgver}"
    echo "  Run 'ai install-deps' to update Python dependencies"
    echo ""
}
