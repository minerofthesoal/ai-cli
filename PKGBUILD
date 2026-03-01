# Maintainer: minerofthesoal <minerofthesoal@users.noreply.github.com>
# AUR package: ai-cli
# Install:  yay -S ai-cli
# Manual:   makepkg -si

pkgname=ai-cli
pkgver=2.6
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
    # Pure shell script — nothing to compile
    :
}

_pick_script() {
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"

    local best=""
    local best_ver=(0 0 0)

    case "${CARCH}" in
        aarch64)
            # Prefer arm64-specific builds on aarch64
            for f in "${src}"/main-v*-arm64; do
                [[ -f "${f}" ]] || continue
                # Extract version numbers from filename
                local ver_str
                ver_str=$(basename "${f}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
                IFS='.' read -r -a ver <<< "${ver_str}"
                if (( ${ver[0]:-0} > ${best_ver[0]:-0} )) || \
                   (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} > ${best_ver[1]:-0} )) || \
                   (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} == ${best_ver[1]:-0} && ${ver[2]:-0} >= ${best_ver[2]:-0} )); then
                    best="${f}"
                    best_ver=("${ver[@]}")
                fi
            done
            [[ -n "${best}" ]] && { echo "${best}"; return 0; }
            ;;
    esac

    # x86_64 / armv7h / aarch64 fallback: pick highest-versioned generic script
    best=""
    best_ver=(0 0 0)
    for f in "${src}"/main-v*; do
        [[ -f "${f}" ]] || continue
        # Skip arm64-specific builds for non-arm64 targets
        [[ "${f}" == *-arm64 ]] && [[ "${CARCH}" != "aarch64" ]] && continue
        local ver_str
        ver_str=$(basename "${f}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
        IFS='.' read -r -a ver <<< "${ver_str}"
        if (( ${ver[0]:-0} > ${best_ver[0]:-0} )) || \
           (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} > ${best_ver[1]:-0} )) || \
           (( ${ver[0]:-0} == ${best_ver[0]:-0} && ${ver[1]:-0} == ${best_ver[1]:-0} && ${ver[2]:-0} >= ${best_ver[2]:-0} )); then
            best="${f}"
            best_ver=("${ver[@]}")
        fi
    done

    echo "${best}"
}

package() {
    local src="${srcdir}/ai-cli-claude-cpu-windows-llm-api-uiTei"

    local script
    script=$(_pick_script)
    if [[ -z "${script}" || ! -f "${script}" ]]; then
        error "No main-v* script found in source directory: ${src}"
        return 1
    fi

    msg2 "Selected script: $(basename "${script}")"

    # Main binary
    install -Dm755 "${script}" "${pkgdir}/usr/bin/ai"

    # Python installer
    [[ -f "${src}/install.py" ]] && \
        install -Dm755 "${src}/install.py" "${pkgdir}/usr/share/ai-cli/install.py"

    # README
    [[ -f "${src}/README.md" ]] && \
        install -Dm644 "${src}/README.md" "${pkgdir}/usr/share/doc/${pkgname}/README.md"

    # License placeholder (add LICENSE file to repo to satisfy AUR checkers)
    install -dm755 "${pkgdir}/usr/share/licenses/${pkgname}"
    printf 'MIT License\nCopyright (c) 2024 minerofthesoal\n' \
        > "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
