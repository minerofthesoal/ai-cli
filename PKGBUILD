# Maintainer: Your Name <your.email@example.com>
pkgname=ai-cli
pkgver=2.4.0
pkgrel=1
pkgdesc="Universal AI CLI · TUI · Fine-tune · Canvas · TTM/MTM/Mtm with GGUF·PyTorch·Diffusers·OpenAI·Claude·Gemini"
arch=('x86_64' 'aarch64')
url="https://github.com/minerofthesoal/ai-cli"
license=('MIT')

depends=(
  'bash'
  'python>=3.10'
  'curl'
  'jq'
)

makedepends=(
  'git'
)

optdepends=(
  'cuda: GPU acceleration support'
  'rocm-hip-runtime: AMD GPU support'
)

source=("${pkgname}::git+https://github.com/minerofthesoal/ai-cli.git#tag=v${pkgver}")
sha256sums=('SKIP')

package() {
  cd "${srcdir}/${pkgname}"
  
  # Install the main script
  install -Dm755 main-v2.4 "${pkgdir}/usr/bin/ai"
  
  # Install license
  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
  
  # Install documentation
  install -Dm644 README.md "${pkgdir}/usr/share/doc/${pkgname}/README.md"
}
