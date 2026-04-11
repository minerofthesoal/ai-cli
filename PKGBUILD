# Maintainer: minerofthesoal <minerofthesoal@users.noreply.github.com>
# AUR package: ai-cli
# Install:  yay -S ai-cli
# Manual:   makepkg -si

pkgname=ai-cli
pkgver=2.7.3
pkgrel=1
pkgdesc="Universal AI shell - chat, vision, RLHF, LoRA fine-tune, TTM, GPU/CPU, rclick, GUI"
arch=('x86_64' 'aarch64' 'armv7h')
url="https://github.com/minerofthesoal/ai-cli"
license=('MIT')
install=ai-cli.install
depends=(
    'bash'
    'python'
    'python-pip'
    'git'
    'curl'
)
optdepends=(
    'python-torch: PyTorch inference and training'
    'python-transformers: HuggingFace model support'
    'python-peft: LoRA fine-tuning (AUR)'
    'python-trl: SFT/DPO/PPO training (AUR)'
    'python-datasets: HuggingFace datasets (AUR)'
    'ffmpeg: audio and video support'
    'xclip: X11 clipboard for rclick text selection'
    'wl-clipboard: Wayland clipboard for rclick text selection'
    'zenity: GUI dialogs for rclick action menu'
    'kdialog: KDE dialogs for rclick action menu'
    'yad: alternative dialog tool'
    'tk: Python Tkinter dialog fallback'
    'xdotool: X11 key simulation'
    'libnotify: desktop notifications'
    'cuda: NVIDIA GPU acceleration'
)
provides=('ai-cli')
conflicts=('ai-cli-git')
source=("${pkgname}-${pkgver}.tar.gz::${url}/archive/refs/heads/claude/cpu-windows-llm-api-uiTei.tar.gz")
b2sums=('SKIP')

# v2.6.0.1 changelog:
#   - Fixed CUDA sm_61 (GTX 1080 / Pascal) detection — cache re-runs after 5 min if GPU was not found
#   - Fixed PyTorch install for sm_61: now installs cu118 (CUDA 11.8) instead of CPU-only
#   - GUI v4: full mouse click support (left-click to select, click again to activate)
#   - GUI v4: scroll wheel support in menu, chat, and output pager
#   - GUI v4: clickable scrollbar in output pager
#   - rclick: fixed 'not authorized to execute this file' — gio set now uses -t string + "yes"
#   - rclick: added setfattr fallback for non-gio systems
#   - rclick: KDE .desktop files get X-KDE-SubstituteUID=false to prevent auth prompts
#   - rclick: new 'ai rclick fix-auth' command to re-apply trust flags without full reinstall

prepare() {
    # Verify the expected directory exists after extraction
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"
    if [[ ! -d "${src}" ]]; then
        # GitHub renames the directory; find whatever was extracted
        local extracted
        extracted=$(find "${srcdir}" -maxdepth 1 -type d -name 'ai-cli*' | head -1)
        [[ -z "${extracted}" ]] && { error "Source directory not found after extraction"; return 1; }
        mv "${extracted}" "${src}"
    fi
}

build() {
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"

    # New multi-file source layout: assemble dist/ai from src/lib/*.sh
    if [[ -d "${src}/src/lib" && -f "${src}/build/build.sh" ]]; then
        msg2 "Building from multi-file source layout…"
        bash "${src}/build/build.sh" --output "${src}/dist/ai"
    elif [[ -f "${src}/dist/ai" ]]; then
        msg2 "Using pre-assembled dist/ai binary"
    else
        msg2 "Legacy source layout — no build step needed"
    fi
}

package() {
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"

    # Prefer assembled binary; fall back to legacy main-v* scripts
    local script=""
    if [[ -f "${src}/dist/ai" ]]; then
        script="${src}/dist/ai"
        msg2 "Installing: dist/ai"
    else
        # Legacy fallback: find highest-versioned main-v* script
        local best="" best_ver=(0 0 0)
        for f in "${src}"/main-v*; do
            [[ -f "${f}" ]] || continue
            [[ "${f}" == *-arm64 ]] && [[ "${CARCH}" != "aarch64" ]] && continue
            local ver_str; ver_str=$(basename "${f}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
            IFS='.' read -r -a ver <<< "${ver_str}"
            if (( ${ver[0]:-0} > ${best_ver[0]:-0} )) || \
               (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} > ${best_ver[1]:-0} )) || \
               (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} == ${best_ver[1]:-0} && \
                  ${ver[2]:-0} >= ${best_ver[2]:-0} )); then
                best="${f}"; best_ver=("${ver[@]}")
            fi
        done
        script="${best}"
    fi

    if [[ -z "${script}" || ! -f "${script}" ]]; then
        error "No installable binary found in source directory: ${src}"
        return 1
    fi

    # Main binary
    install -Dm755 "${script}" "${pkgdir}/usr/bin/ai"

    # Python installer
    [[ -f "${src}/install.py" ]] && \
        install -Dm755 "${src}/install.py" "${pkgdir}/usr/share/ai-cli/install.py"

    # Source modules (for development / inspection)
    if [[ -d "${src}/src/lib" ]]; then
        install -dm755 "${pkgdir}/usr/share/ai-cli/src/lib"
        install -m644 "${src}/src/lib"/*.sh "${pkgdir}/usr/share/ai-cli/src/lib/"
    fi

    # Build script
    [[ -f "${src}/build/build.sh" ]] && \
        install -Dm755 "${src}/build/build.sh" "${pkgdir}/usr/share/ai-cli/build/build.sh"

    # README
    [[ -f "${src}/README.md" ]] && \
        install -Dm644 "${src}/README.md" "${pkgdir}/usr/share/doc/${pkgname}/README.md"

    # License
    install -dm755 "${pkgdir}/usr/share/licenses/${pkgname}"
    if [[ -f "${src}/LICENSE" ]]; then
        install -m644 "${src}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
    else
        printf 'MIT License\nCopyright (c) 2024 minerofthesoal\n' \
            > "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
    fi
}
