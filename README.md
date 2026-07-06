# AI CLI

**Universal AI terminal toolkit** — local GGUF models, cloud APIs (OpenAI, Claude, Gemini, Groq, Mistral), model training, RLHF, Canvas workspace, and 195 curated models. One command: `ai`.

---

## Quick Install

```bash
# Universal (any Linux / macOS / WSL)
curl -fsSL https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/installers/install.sh | sh

# Then:
ai install-deps        # auto-detects CUDA / Metal / CPU
ai setup               # interactive first-time setup wizard (v3.3)
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

## What's New in v3.3

### 15+ New Features

| Feature | Command | Description |
|---------|---------|-------------|
| **Setup Wizard** | `ai setup` | Interactive first-time configuration |
| **Shell Completions** | `ai completion bash` | Generate bash/zsh/fish completions |
| **LM Studio Integration** | `ai import-models` | Auto-detect and use LM Studio models folder |
| **Ollama Support** | `ai use ollama://llama3` | Use Ollama-hosted models |
| **Quick Model Switch** | `ai use <model>` | Fast model switching with aliases |
| **Model Favorites** | `ai model fav <name>` | Bookmark frequently used models |
| **Model Tags** | `ai model tags` | Organize models with custom tags |
| **Model Info** | `ai model info` | Detailed model metadata display |
| **Config Profiles** | `ai profile save/load` | Save and switch config presets |
| **Health Check** | `ai health` | Full system diagnostics |
| **Quant Recommendations** | `ai recommend-quant` | VRAM-aware quantization advice |
| **Chat Export** | `ai export-chat md` | Export conversations to markdown |
| **Model Import** | `ai import-models` | Import from LM Studio, Ollama, GPT4All |
| **Improved Help** | `ai help --search <term>` | Searchable help with categories |

### Improved Help Menu (v3.3)

```bash
ai help                    # Full command list with categories
ai help --search model     # Search commands by keyword
ai -h <command>            # Detailed help for any command
```

The new help menu features:
- **Color-coded sections** — Chat, Models, Media, Training, Settings
- **Search functionality** — Find commands by keyword
- **Pro tips section** — Common usage patterns
- **External integration status** — LM Studio, Ollama detection

## Features

### Local AI
- **GGUF inference** via llama.cpp (CPU + GPU)
- **195 curated models** with recommendations by hardware tier
- **CPU auto-detection**: AVX-512, AVX2, NEON, SVE
- **GPU support**: CUDA (NVIDIA), Metal (Apple Silicon), ROCm (AMD)
- **Multi-model backends**: LM Studio, Ollama, GPT4All integration

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
- **GUI+ v4** — tkinter 9-tab interface (Chat · Models · Agent · API · Write · RAG · Canvas · Tools · Status)
- **HTTP API v3.2** — 44 endpoints, 12-tab web dashboard, OpenAI-compatible

### Model Management (v3.3)
- **Quick switch**: `ai use <model>` — instant model switching
- **Favorites**: `ai model fav` — bookmark frequently used models
- **Tags**: `ai model tags` — categorize and organize models
- **Profiles**: `ai profile save/load` — config presets for different tasks
- **Import**: `ai import-models` — import from LM Studio, Ollama, GPT4All
- **Info**: `ai model info` — detailed model metadata and system status

### Extras
- Batch processing & watch mode
- Dataset generation
- FLUX image generation
- Audio transcription (Whisper)
- Text-to-speech (piper / espeak / macOS `say`)
- Embeddings & RAG (quick mode: `ai rag-quick`)
- Project management with persistent memory
- Workflow engine & templates
- Public sharing via Cloudflare/ngrok tunnel (`ai share`)
- Autonomous agent loop (`ai agent "goal" --steps N`)
- AI diff reviewer (`ai diff-review staged`)
- Shell completions (`ai completion bash|zsh|fish`)
- Health diagnostics (`ai health`)

## Usage Examples

```bash
# Chat & query
ai ask "Explain quicksort"        # long form
ai a   "Explain quicksort"        # short alias
ai chat
ai ask -m claude "Review this code" < file.py

# Models
ai recommended                    # browse 195 models
ai recommended download 1         # download first model
ai use 1                          # activate model #1 (v3.3)
ai use llama3.3                   # quick switch by name (v3.3)
ai use ollama://llama3           # use Ollama model (v3.3)
ai model fav llama3.3             # add to favorites (v3.3)
ai model info                     # show model details (v3.3)
ai import-models                  # import external models (v3.3)

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

# API server (local LLM over HTTP + 12-tab dashboard, 44 endpoints)
ai api start                      # http://localhost:8080
ai api start --port 9000 --public # bind 0.0.0.0
ai api stop
ai -apip SECRET                   # set Terminal-tab password (<=8 chars)
# Endpoints: /v3/site /v3/status /v3/sysinfo /v3/models /v3/keys
#            /v3/history /v3/tokens /v3/cost /v3/embed /v3/chat/stream
#            /v3/web /v3/benchmark /v3/agent /v3/diff/review
#            /v3/voice/tts /v3/share /v3/rag/* /v3/files/* /v3/run
curl http://localhost:8080/v3/endpoints | jq

# v3.3 new commands
ai setup                          # interactive first-time wizard
ai completion bash                # generate shell completions
ai completion bash >> ~/.bashrc   # install completions
ai use qwen2.5                    # quick model switch
ai use ollama://llama3           # use Ollama model
ai model fav qwen2.5              # add to favorites
ai model tags                     # list tagged models
ai model tag qwen2.5 coding       # tag a model
ai profile save coding            # save config profile
ai profile load coding            # load config profile
ai health                         # full system diagnostics
ai recommend-quant                # VRAM-aware quantization advice
ai export-chat md > chat.md      # export conversation to markdown
ai import-models                  # auto-detect LM Studio / Ollama
ai import-models --lmstudio ~/.lmstudio/models
ai import-models --ollama --link

# v3.2 new commands
ai voice tts "hello world"        # speak via piper/espeak/say
ai voice stt recording.wav        # transcribe via whisper
ai voice ask "explain quicksort"  # ask + speak answer
ai share                          # public tunnel (cloudflared/ngrok)
ai diff-review staged             # AI review of git staged diff
ai diff-review HEAD               # review last commit
ai diff-review mydiff.patch       # review a diff file
ai agent "plan a blog post" --steps 4   # autonomous multi-step loop
ai rag-quick README.md "what does this do?"
ai rag-quick src/  "how are API keys stored?"

# System
ai install-deps                   # install ML dependencies
ai keys set OPENAI_API_KEY sk-... # set API key
ai status                         # show config & GPU info
ai -Cf u-gpu 0                    # disable GPU (persistent)
ai -Cf u-gpu 1                    # re-enable GPU
ai -L                             # show latest changelog
ai -Su                            # self-update from GitHub
```

## Project Structure

```
ai-cli/
├── main.sh                    # Core CLI (~25k lines of Bash)
├── patches/
│   └── v3.3-additions.sh      # v3.3 feature additions
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
git tag v3.3.0
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