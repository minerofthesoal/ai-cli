# Maintainer: minerofthesoal <https://github.com/minerofthesoal>
# AUR: https://aur.archlinux.org/packages/ai-cli
# Source: https://github.com/minerofthesoal/ai-cli
#
# Manual install (without AUR helper):
#   git clone https://aur.archlinux.org/ai-cli.git
#   cd ai-cli && makepkg -si

pkgname=ai-cli
pkgver=2.8.5.5
pkgrel=1
pkgdesc="AI CLI — local + cloud LLM terminal toolkit with 195 models, RLHF, Canvas v3 TUI, AUI"
arch=('any')
url="https://github.com/minerofthesoal/ai-cli"
license=('MIT')

depends=(
    'bash>=5.0'
    'python>=3.10'
    'curl'
    'git'
)

optdepends=(
    'python-pip: install AI/ML Python libraries (torch, transformers, etc.)'
    'ffmpeg: audio transcription and video processing'
    'jq: JSON utilities used by some commands'
    'github-cli: Canvas Gist upload and repo management'
    'python-torch: local model inference (gguf/pytorch backends)'
    'python-transformers: HuggingFace model download and use'
    'llama-cpp-python: fast CPU/GPU inference for GGUF models'
    'python-openai: OpenAI API client'
    'python-anthropic: Anthropic Claude API client'
)

provides=('ai')
conflicts=('ai-cli-git')

source=("${pkgname}-${pkgver}.tar.gz::https://github.com/minerofthesoal/ai-cli/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=('SKIP')  # Updated automatically by CI — set manually for offline use
b2sums=('SKIP')

prepare() {
    cd "${srcdir}/${pkgname}-${pkgver}"
    bash -n main.sh  # fail fast if script has syntax errors
}

build() {
    : # Pure bash — nothing to compile
}

check() {
    cd "${srcdir}/${pkgname}-${pkgver}"
    # Verify script can report its version
    bash main.sh --version 2>/dev/null || \
    grep -qE '^VERSION="[0-9]' main.sh
}

package() {
    cd "${srcdir}/${pkgname}-${pkgver}"

    # ── Main binary ───────────────────────────────────────────────────────────
    install -Dm755 main.sh "${pkgdir}/usr/bin/ai"

    # ── Shared data ───────────────────────────────────────────────────────────
    local sharedir="${pkgdir}/usr/share/${pkgname}"
    [[ -f install_v3.1.py ]] && install -Dm755 install_v3.1.py "${sharedir}/install.py"
    [[ -f requirements.txt ]] && install -Dm644 requirements.txt "${sharedir}/requirements.txt"
    [[ -f package.json ]]     && install -Dm644 package.json     "${sharedir}/package.json"

    # ── License ───────────────────────────────────────────────────────────────
    install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE" 2>/dev/null || \
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE" << 'LICEOF'
MIT License — Copyright (c) minerofthesoal
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies, subject to the conditions at https://opensource.org/licenses/MIT
LICEOF

    # ── Documentation ─────────────────────────────────────────────────────────
    local docdir="${pkgdir}/usr/share/doc/${pkgname}"
    [[ -f README.md ]]    && install -Dm644 README.md    "${docdir}/README.md"
    [[ -f CHANGELOG.md ]] && install -Dm644 CHANGELOG.md "${docdir}/CHANGELOG.md"
}

post_install() {
    cat << 'MSG'

  ╔══════════════════════════════════════════════════════════════╗
  ║  ai-cli installed!  Run: ai --help                          ║
  ║                                                              ║
  ║  Quick setup:                                                ║
  ║    ai recommended              # browse 195 models           ║
  ║    ai keys set GROQ_API_KEY gsk_...   # free & fast          ║
  ║    ai keys set OPENAI_API_KEY sk-...                         ║
  ║    ai keys set ANTHROPIC_API_KEY sk-ant-...                  ║
  ║    ai ask "hello"              # first prompt                ║
  ║    ai aui                      # terminal dashboard          ║
  ║    ai canvas new myproject     # Canvas v3 workspace         ║
  ╚══════════════════════════════════════════════════════════════╝

MSG
}

post_upgrade() {
    echo "  ai-cli upgraded to $(bash /usr/bin/ai --version 2>/dev/null || echo 'new version')"
    echo "  Run: ai --version  to confirm"
}
