#!/bin/bash
# Pacstall package script for ai-cli
# https://pacstall.dev  |  https://github.com/pacstall/pacstall
#
# Install: pacstall -I ai-cli
# Update:  pacstall -U ai-cli
# Remove:  pacstall -R ai-cli
#
# Or install directly from this repo:
#   pacstall -I https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/ai-cli.pacscript

pkgname="ai-cli"
pkgver="3.2.1.0.1"
pkgdesc="AI CLI — local + cloud LLM terminal toolkit with 195 models, 44 API endpoints, streaming, voice, share, agent, RAG, Canvas v3 TUI, GUI+ v4"
url="https://github.com/minerofthesoal/ai-cli"
gives="ai"

# Source tarball from GitHub release
source=("https://github.com/minerofthesoal/ai-cli/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=("SKIP")  # Updated by CI — set a real hash for production use

# Runtime dependencies
depends=(
    "bash"
    "python3"
    "curl"
    "git"
)

# Optional but recommended
optdepends=(
    "ffmpeg: audio/video transcription and processing"
    "jq: JSON query utility"
    "gh: GitHub CLI for Canvas Gist upload"
    "python3-pip: install ML libraries (torch, transformers, llama-cpp-python)"
)

# Conflicts with the git version if someone made one
incompatible=("ai-cli-git")

prepare() {
    cd "${SRCDIR}/${pkgname}-${pkgver}" 2>/dev/null || \
    cd "${SRCDIR}/ai-cli-${pkgver}"
    bash -n main.sh || {
        echo "ERROR: main.sh has bash syntax errors"
        return 1
    }
}

build() {
    : # Nothing to compile
}

package() {
    local srcpath
    srcpath=$(find "${SRCDIR}" -maxdepth 1 -name "ai-cli-*" -type d | head -1)
    [[ -z "$srcpath" ]] && { echo "ERROR: source dir not found"; return 1; }
    cd "$srcpath"

    # Main executable
    install -Dm755 main.sh "${PKGDIR}/usr/bin/ai"

    # Support files
    local sharedir="${PKGDIR}/usr/share/ai-cli"
    [[ -f install_v3.1.py ]] && install -Dm755 install_v3.1.py "${sharedir}/install.py"
    [[ -f requirements.txt ]] && install -Dm644 requirements.txt "${sharedir}/requirements.txt"
    [[ -f package.json ]]     && install -Dm644 package.json     "${sharedir}/package.json"

    # Docs
    [[ -f README.md ]]    && install -Dm644 README.md    "${PKGDIR}/usr/share/doc/ai-cli/README.md"
    [[ -f CHANGELOG.md ]] && install -Dm644 CHANGELOG.md "${PKGDIR}/usr/share/doc/ai-cli/CHANGELOG.md"

    # License
    if [[ -f LICENSE ]]; then
        install -Dm644 LICENSE "${PKGDIR}/usr/share/licenses/ai-cli/LICENSE"
    fi
}

post_install() {
    cat << 'MSG'

  ╔══════════════════════════════════════════════════════════════╗
  ║  ai-cli installed via Pacstall!                              ║
  ║                                                              ║
  ║  Quick start:                                                ║
  ║    ai recommended                  # browse 195 models       ║
  ║    ai keys set GROQ_API_KEY gsk_...  (free & fast)           ║
  ║    ai keys set OPENAI_API_KEY sk-...                         ║
  ║    ai keys set ANTHROPIC_API_KEY sk-ant-...                  ║
  ║    ai ask "hello"                  # first prompt            ║
  ║    ai aui                          # terminal dashboard      ║
  ║    ai canvas new myproject         # Canvas v3 workspace     ║
  ║    ai ttm pretrain                 # train your own model    ║
  ║                                                              ║
  ║  Docs: https://github.com/minerofthesoal/ai-cli              ║
  ╚══════════════════════════════════════════════════════════════╝

MSG
}

post_upgrade() {
    echo ""
    echo "  ai-cli upgraded to ${pkgver}"
    echo "  Run: ai --version  to confirm"
    echo ""
}
