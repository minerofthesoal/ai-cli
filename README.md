# AI CLI

**Universal AI terminal toolkit** — local GGUF models, cloud APIs (OpenAI, Claude, Gemini, Groq, Mistral), model training, RLHF, Canvas workspace, and 195 curated models. One command: `ai`.

---

## Quick Install

```bash
# Universal (any Linux / macOS / WSL)
curl -fsSL https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/installers/install.sh | sh

# Then:
ai install-deps        # auto-detects CUDA / Metal / CPU
ai recommended         # browse 195 curated models
ai ask "Hello!"
```

## All Install Methods

| Platform | Command |
|----------|---------|
| **Universal (sh)** | `curl -fsSL .../installers/install.sh \| sh` |
| **Debian/Ubuntu** | `sh installers/install-deb.sh` or download `.deb` from Releases |
| **Arch Linux** | `sh installers/install-arch.sh --aur` or `yay -S ai-cli` |
| **Fedora/RHEL** | `sh installers/install-rpm.sh` |
| **macOS** | `sh installers/install-mac.sh` |
| **Python** | `python3 installers/install.py` |
| **C++ (compile)** | `g++ -std=c++17 -o install installers/install.cpp && ./install` |
| **Manual** | `chmod +x main.sh && sudo cp main.sh /usr/local/bin/ai` |

## Features

### Local AI
- **GGUF inference** via llama.cpp (CPU + GPU)
- **195 curated models** with recommendations by hardware tier
- **CPU auto-detection**: AVX-512, AVX2, NEON, SVE
- **GPU support**: CUDA (NVIDIA), Metal (Apple Silicon), ROCm (AMD)

### Cloud APIs
- OpenAI (GPT-4o, o1, o3)
- Anthropic Claude (Opus, Sonnet, Haiku)
- Google Gemini
- Groq, Mistral, Together, HuggingFace

### Training & Fine-tuning
- **TTM** — Tiny Training Model (from scratch)
- **MTM** — Mini Training Model
- **LoRA fine-tuning** for any HuggingFace model
- **RLHF** — DPO, PPO, GRPO reward training

### Interfaces
- **Terminal** — `ai ask`, `ai chat`
- **TUI** — curses-based dashboard (`ai aui`)
- **Canvas v3** — multi-file workspace with syntax highlighting, AI-insert, live preview
- **GUI+** — tkinter 8-tab interface

### Extras
- Batch processing & watch mode
- Dataset generation
- FLUX image generation
- Audio transcription (Whisper)
- Embeddings & RAG
- Project management with persistent memory
- Workflow engine & templates

## Usage Examples

```bash
# Chat & query
ai ask "Explain quicksort"
ai chat
ai ask -m claude "Review this code" < file.py

# Models
ai recommended                    # browse 195 models
ai recommended download 1         # download first model
ai recommended use 1              # activate it

# Canvas workspace
ai canvas new myproject python
ai canvas ask "Build a web scraper"
ai canvas run

# Training
ai ttm pretrain                   # train tiny model
ai rlhf rate                      # rate responses for RLHF

# GUI
ai aui                            # terminal dashboard
ai -gui                           # TUI mode

# System
ai install-deps                   # install ML dependencies
ai keys set OPENAI_API_KEY sk-... # set API key
ai status                         # show config & GPU info
```

## Project Structure

```
ai-cli/
├── main.sh                    # Core CLI (22k+ lines of Bash)
├── installers/
│   ├── install.sh             # Universal POSIX sh installer
│   ├── install-arch.sh        # Arch Linux / pacman
│   ├── install-deb.sh         # Debian / Ubuntu / Mint
│   ├── install-rpm.sh         # Fedora / RHEL / CentOS
│   ├── install-mac.sh         # macOS (Homebrew)
│   ├── install.py             # Python cross-platform installer
│   └── install.cpp            # C++ installer (compile & run)
├── packaging/
│   ├── PKGBUILD               # Arch Linux AUR package
│   ├── debian/                # .deb packaging (control, postinst, prerm)
│   └── rpm/                   # RPM spec file
├── .github/workflows/
│   ├── build.yml              # CI: lint, build .deb, compile C++
│   └── release.yml            # CD: create GitHub Release after build
├── misc/
│   ├── requirements.txt       # Python ML dependencies
│   └── package.json           # Node.js metadata
├── old/                       # Legacy versions archive
├── LICENSE                    # MIT
└── PACKAGING.md               # Release workflow docs
```

## CI/CD

The project uses two GitHub Actions workflows:

1. **Build** (`build.yml`) — runs on every push/PR:
   - Lints all shell scripts, Python, and C++
   - Builds `.deb` package
   - Compiles C++ installer
   - Validates RPM spec

2. **Release** (`release.yml`) — runs after successful build on tags:
   - Downloads build artifacts
   - Creates GitHub Release with all assets
   - Generates install instructions for every platform

```bash
# To create a release:
git tag v2.8.5.6
git push origin main --tags
# GitHub Actions handles the rest
```

## Requirements

- **Bash** >= 5.0
- **Python** >= 3.10 (for ML features)
- **curl**, **git**
- Optional: ffmpeg, jq, nodejs, npm

## Supported Platforms

| OS | Arch | Status |
|----|------|--------|
| Ubuntu / Debian / Mint / Pop!_OS | x86_64, arm64 | Full support |
| Arch / Manjaro / EndeavourOS | x86_64, arm64 | Full support (AUR) |
| Fedora / RHEL / Rocky / Alma | x86_64, arm64 | Full support |
| openSUSE | x86_64, arm64 | Full support |
| macOS (Intel) | x86_64 | Full support |
| macOS (Apple Silicon) | arm64 | Full support (Metal) |
| Windows (WSL / Git Bash) | x86_64 | Supported |
| Raspberry Pi | arm64/armv7l | Supported (CPU) |
| NVIDIA Jetson | arm64 | Supported (CUDA) |

## License

MIT License. See [LICENSE](LICENSE).
