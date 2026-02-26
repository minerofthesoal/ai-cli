#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║           AI.SH  —  Universal AI CLI for Konsole v2.0           ║
# ║  GGUF • Diffusers • PyTorch • OpenAI • Claude • Gemini • HF     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ════════════════════════════════════════════════════════════════════
#  ENVIRONMENT DETECTION (runs before anything else)
# ════════════════════════════════════════════════════════════════════

find_python() {
  for candidate in python3.12 python3.11 python3.10 python3 python; do
    local p
    p=$(command -v "$candidate" 2>/dev/null) || continue
    local ver
    ver=$("$p" -c "import sys; print(sys.version_info.major,sys.version_info.minor)" 2>/dev/null) || continue
    local major minor
    read -r major minor <<< "$ver"
    if (( major == 3 && minor >= 10 )); then
      echo "$p"; return 0
    fi
  done
  echo ""
}

find_llama_cpp() {
  # 1. Common CLI binary names in PATH
  for bin in llama-cli llama llama-run llama-main; do
    local p; p=$(command -v "$bin" 2>/dev/null) && { echo "$p"; return 0; }
  done
  # 2. Common install locations
  local search_paths=(
    "$HOME/.local/bin"
    "$HOME/bin"
    "$HOME/llama.cpp/build/bin"
    "$HOME/llama.cpp/build"
    "$HOME/llama.cpp"
    "/usr/local/bin"
    "/opt/llama.cpp/bin"
    "/opt/homebrew/bin"
  )
  for dir in "${search_paths[@]}"; do
    for bin in llama-cli llama llama-run main; do
      [[ -x "$dir/$bin" ]] && { echo "$dir/$bin"; return 0; }
    done
  done
  # 3. Fallback: use llama-cpp-python Python API
  local py; py=$(find_python)
  if [[ -n "$py" ]] && "$py" -c "import llama_cpp" 2>/dev/null; then
    echo "llama_cpp_python"; return 0
  fi
  echo ""
}

PYTHON="$(find_python)"
LLAMA_BIN="$(find_llama_cpp)"

# ════════════════════════════════════════════════════════════════════
#  ANSI COLORS
# ════════════════════════════════════════════════════════════════════
R="\033[0m"
B="\033[1m"; DIM="\033[2m"; IT="\033[3m"; UL="\033[4m"
BLACK="\033[30m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; GRAY="\033[90m"
BRED="\033[91m"; BGREEN="\033[92m"; BYELLOW="\033[93m"; BBLUE="\033[94m"
BMAGENTA="\033[95m"; BCYAN="\033[96m"; BWHITE="\033[97m"
BG_BLACK="\033[40m"; BG_RED="\033[41m"; BG_GREEN="\033[42m"; BG_YELLOW="\033[43m"
BG_BLUE="\033[44m"; BG_MAGENTA="\033[45m"; BG_CYAN="\033[46m"; BG_WHITE="\033[47m"

# ════════════════════════════════════════════════════════════════════
#  CONFIG PATHS
# ════════════════════════════════════════════════════════════════════
CONFIG_DIR="${AI_CLI_CONFIG:-$HOME/.config/ai-cli}"
CONFIG_FILE="$CONFIG_DIR/config.env"
KEYS_FILE="$CONFIG_DIR/keys.env"
LOG_FILE="$CONFIG_DIR/history.log"
SESSIONS_DIR="$CONFIG_DIR/sessions"
PERSONAS_DIR="$CONFIG_DIR/personas"
MODELS_DIR="${AI_CLI_MODELS:-$HOME/.ai-cli/models}"
AI_OUTPUT_DIR="${AI_OUTPUT_DIR:-$HOME/ai-outputs}"

mkdir -p "$CONFIG_DIR" "$MODELS_DIR" "$SESSIONS_DIR" "$PERSONAS_DIR" "$AI_OUTPUT_DIR"
touch "$KEYS_FILE" && chmod 600 "$KEYS_FILE"

# Load saved settings
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -f "$KEYS_FILE"   ]] && source "$KEYS_FILE"

# Defaults
ACTIVE_MODEL="${ACTIVE_MODEL:-}"
ACTIVE_BACKEND="${ACTIVE_BACKEND:-}"
ACTIVE_PERSONA="${ACTIVE_PERSONA:-}"
ACTIVE_SESSION="${ACTIVE_SESSION:-default}"
MAX_TOKENS="${MAX_TOKENS:-2048}"
TEMPERATURE="${TEMPERATURE:-0.7}"
STREAM="${STREAM:-1}"
VERBOSE="${VERBOSE:-0}"
VERSION="2.0.0"

# ════════════════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS
# ════════════════════════════════════════════════════════════════════
divider() { echo -e "${GRAY}──────────────────────────────────────────────────────────${R}"; }
header()  { echo -e ""; echo -e "${B}${BG_BLUE}${BWHITE}  $*  ${R}"; echo -e ""; }
ok()      { echo -e "  ${BGREEN}✓${R}  $*"; }
warn()    { echo -e "  ${BYELLOW}⚠${R}   $*"; }
err()     { echo -e "  ${BRED}✗${R}  $*" >&2; }
info()    { echo -e "  ${BCYAN}→${R}  $*"; }
label()   { printf "  ${CYAN}%-22s${R}  %b\n" "$1" "$2"; }

spinner() {
  local pid=$1 msg="${2:-Working…}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${BCYAN}${frames[$((i % 10))]}${R}  ${DIM}${msg}${R}"
    i=$((i+1)); sleep 0.08
  done
  printf "\r%-70s\r" " "
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
ACTIVE_MODEL="$ACTIVE_MODEL"
ACTIVE_BACKEND="$ACTIVE_BACKEND"
ACTIVE_PERSONA="$ACTIVE_PERSONA"
ACTIVE_SESSION="$ACTIVE_SESSION"
MAX_TOKENS="$MAX_TOKENS"
TEMPERATURE="$TEMPERATURE"
STREAM="$STREAM"
VERBOSE="$VERBOSE"
MODELS_DIR="$MODELS_DIR"
AI_OUTPUT_DIR="$AI_OUTPUT_DIR"
EOF
}

log_interaction() {
  local role="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [session:$ACTIVE_SESSION] [$role] $*" >> "$LOG_FILE"
}

session_file() { echo "$SESSIONS_DIR/${1:-$ACTIVE_SESSION}.json"; }

require_jq()     { command -v jq    &>/dev/null || { err "jq required:   sudo apt install jq";   exit 1; }; }
require_curl()   { command -v curl  &>/dev/null || { err "curl required: sudo apt install curl"; exit 1; }; }
require_python() { [[ -n "$PYTHON" ]] || { err "Python 3.10+ not found. Install python3.12."; exit 1; }; }
require_model()  {
  [[ -n "$ACTIVE_MODEL" ]] || {
    err "No model selected."
    info "Set one: ${YELLOW}ai model <n>${R}"
    info "Download: ${YELLOW}ai download TheBloke/Mistral-7B-Instruct-v0.2-GGUF${R}"
    exit 1
  }
}

# ════════════════════════════════════════════════════════════════════
#  HELP
# ════════════════════════════════════════════════════════════════════
show_help() {
  clear
  cat <<HELPEOF

$(echo -e "${B}${BG_MAGENTA}${BWHITE}                                                              ${R}")
$(echo -e "${B}${BG_MAGENTA}${BWHITE}   🤖  AI CLI  v${VERSION}  —  Universal AI Interface for Konsole  ${R}")
$(echo -e "${B}${BG_MAGENTA}${BWHITE}                                                              ${R}")

$(echo -e "  ${GRAY}Python:  ${PYTHON:-NOT FOUND}${R}")
$(echo -e "  ${GRAY}llama:   ${LLAMA_BIN:-not found (python API used as fallback)}${R}")
$(echo -e "  ${GRAY}Config:  ${CONFIG_DIR}${R}   Models: ${MODELS_DIR}${R}")

$(echo -e "${B}${BCYAN}━━ ASKING & GENERATION ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BGREEN}ask${R} ${BYELLOW}<prompt>${R}")
      Send a text prompt to the active model
      $(echo -e "${IT}${GRAY}ai ask \"Explain neural networks\"${R}")

  $(echo -e "${BGREEN}ask${R} ${BYELLOW}<prompt>${R} ${BMAGENTA}image <path|url>${R}")
      Multimodal — attach a local image or URL
      $(echo -e "${IT}${GRAY}ai ask \"What is in this?\" image ~/photo.jpg${R}")
      $(echo -e "${IT}${GRAY}ai ask \"Describe\" image https://example.com/img.png${R}")

  $(echo -e "${BGREEN}ask${R} ${BYELLOW}<prompt>${R} ${BMAGENTA}file <path>${R}")
      Include a text file's contents in the prompt
      $(echo -e "${IT}${GRAY}ai ask \"Summarize this\" file ~/notes.txt${R}")

  $(echo -e "${BGREEN}think${R} ${BYELLOW}<prompt>${R}")
      Chain-of-thought reasoning — renders steps then final answer
      $(echo -e "${IT}${GRAY}ai think \"If train A leaves at 9am at 60mph and train B...\"${R}")

  $(echo -e "${BGREEN}imagine${R} ${BYELLOW}<prompt>${R} ${GRAY}[--steps N] [--size WxH] [--out path]${R}")
      Generate an image (Diffusers: SD/SDXL/FLUX or DALL-E via OpenAI)
      $(echo -e "${IT}${GRAY}ai imagine \"Cyberpunk cat at sunset, hyperrealistic\"${R}")
      $(echo -e "${IT}${GRAY}ai imagine \"Oil painting of mountains\" --steps 40 --size 1024x1024${R}")

  $(echo -e "${BGREEN}chat${R} ${GRAY}[--session name]${R}")
      Interactive multi-turn conversation. CTRL+D or 'exit' to quit.
      $(echo -e "${IT}${GRAY}ai chat${R}")
      $(echo -e "${IT}${GRAY}ai chat --session myproject${R}")

  $(echo -e "${BGREEN}pipe${R} ${BYELLOW}<prompt>${R}")
      Pipe stdin as context — great for scripts and git workflows
      $(echo -e "${IT}${GRAY}cat myapp.py | ai pipe \"Find all bugs\"${R}")
      $(echo -e "${IT}${GRAY}git diff    | ai pipe \"Write a commit message\"${R}")

  $(echo -e "${BGREEN}code${R} ${BYELLOW}<prompt>${R} ${GRAY}[--lang python|bash|js|...] [--run]${R}")
      Generate code; optionally execute it immediately
      $(echo -e "${IT}${GRAY}ai code \"Parse a CSV and make a bar chart\" --lang python${R}")
      $(echo -e "${IT}${GRAY}ai code \"Fibonacci sequence\" --lang bash --run${R}")

  $(echo -e "${BGREEN}review${R} ${BYELLOW}<file>${R}")
      Code review: bugs, security, style, performance suggestions
      $(echo -e "${IT}${GRAY}ai review myapp.py${R}")

  $(echo -e "${BGREEN}explain${R} ${BYELLOW}<file|snippet>${R}")
      Explain code or text in plain English
      $(echo -e "${IT}${GRAY}ai explain myscript.sh${R}")

  $(echo -e "${BGREEN}summarize${R} ${BYELLOW}<file|url|stdin>${R} ${GRAY}[--format markdown|bullet|tldr]${R}")
      Summarize a file, URL, or piped content
      $(echo -e "${IT}${GRAY}ai summarize ~/report.txt --format bullet${R}")
      $(echo -e "${IT}${GRAY}ai summarize https://example.com/article${R}")

  $(echo -e "${BGREEN}translate${R} ${BYELLOW}<text>${R} ${BMAGENTA}to <language>${R}")
      Translate text using the active model
      $(echo -e "${IT}${GRAY}ai translate \"Good morning\" to Japanese${R}")

  $(echo -e "${BGREEN}tts${R} ${BYELLOW}<text>${R} ${GRAY}[--voice alloy|echo|fable|onyx|nova|shimmer] [--out file.mp3]${R}")
      Text-to-speech via OpenAI TTS (auto-plays if mpv installed)
      $(echo -e "${IT}${GRAY}ai tts \"Hello world\" --voice nova${R}")

  $(echo -e "${BGREEN}transcribe${R} ${BYELLOW}<audio-file>${R} ${GRAY}[--lang en]${R}")
      Transcribe audio via OpenAI Whisper or local whisper
      $(echo -e "${IT}${GRAY}ai transcribe recording.mp3${R}")

  $(echo -e "${BGREEN}embed${R} ${BYELLOW}<text>${R} ${GRAY}[--out file.json]${R}")
      Get vector embeddings for text (OpenAI text-embedding-3-small)
      $(echo -e "${IT}${GRAY}ai embed \"quantum computing\"${R}")

$(echo -e "${B}${BCYAN}━━ MODELS & BACKENDS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BGREEN}model${R} ${BYELLOW}<name|path>${R} ${GRAY}[backend]${R}")
      Set the active model. Backend auto-detected if omitted.
      $(echo -e "${IT}${GRAY}ai model gpt-4o${R}")
      $(echo -e "${IT}${GRAY}ai model claude-opus-4-5${R}")
      $(echo -e "${IT}${GRAY}ai model gemini-2.0-flash${R}")
      $(echo -e "${IT}${GRAY}ai model ~/mistral-7b.Q4_K_M.gguf${R}")
      $(echo -e "${IT}${GRAY}ai model meta-llama/Llama-3-8B-Instruct pytorch${R}")

  $(echo -e "${BGREEN}models${R}")
      List all local and API-available models

  $(echo -e "${BGREEN}model-info${R} ${BYELLOW}<name>${R}")
      Show model metadata (params, quant, context length, etc.)

  $(echo -e "${BGREEN}backend${R} ${BYELLOW}<name>${R}")
      Force a backend: $(echo -e "${CYAN}gguf${R} | ${CYAN}diffusers${R} | ${CYAN}pytorch${R} | ${CYAN}openai${R} | ${CYAN}claude${R} | ${CYAN}gemini${R} | ${CYAN}hf${R}")

$(echo -e "${B}${BCYAN}━━ DOWNLOAD & API KEYS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BGREEN}download${R} ${BYELLOW}<hf-repo|url>${R} ${GRAY}[--gguf] [--file filename.gguf]${R}")
      Download model from HuggingFace. Auto-detects type.
      $(echo -e "${IT}${GRAY}ai download TheBloke/Mistral-7B-Instruct-v0.2-GGUF${R}")
      $(echo -e "${IT}${GRAY}ai download TheBloke/Mistral-7B-GGUF --file mistral-7b.Q4_K_M.gguf${R}")
      $(echo -e "${IT}${GRAY}ai download stabilityai/stable-diffusion-xl-base-1.0${R}")
      $(echo -e "${IT}${GRAY}ai download meta-llama/Llama-3-8B-Instruct${R}")

  $(echo -e "${BGREEN}download${R} ${BMAGENTA}openai${R}  ${BYELLOW}<sk-...>${R}        Save OpenAI API key")
  $(echo -e "${BGREEN}download${R} ${BMAGENTA}claude${R}  ${BYELLOW}<sk-ant-...>${R}    Save Anthropic/Claude key")
  $(echo -e "${BGREEN}download${R} ${BMAGENTA}gemini${R}  ${BYELLOW}<AIza...>${R}       Save Google Gemini key")
  $(echo -e "${BGREEN}download${R} ${BMAGENTA}hf${R}      ${BYELLOW}<hf_...>${R}        Save HuggingFace token")

  $(echo -e "${BGREEN}keys${R}")
      Show all stored API keys (partially masked)

$(echo -e "${B}${BCYAN}━━ SESSIONS & PERSONAS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BGREEN}session${R} ${GRAY}list|new|load|delete|export [name]${R}")
      $(echo -e "${IT}${GRAY}ai session list${R}              List all sessions")
      $(echo -e "${IT}${GRAY}ai session new myproject${R}     Create & switch session")
      $(echo -e "${IT}${GRAY}ai session load myproject${R}    Resume a session")
      $(echo -e "${IT}${GRAY}ai session export myproject${R}  Export to markdown")

  $(echo -e "${BGREEN}persona${R} ${GRAY}list|set|create|edit [name]${R}")
      Built-in: $(echo -e "${CYAN}default${R} | ${CYAN}dev${R} | ${CYAN}researcher${R} | ${CYAN}writer${R} | ${CYAN}teacher${R} | ${CYAN}sysadmin${R} | ${CYAN}security${R}")
      $(echo -e "${IT}${GRAY}ai persona set dev${R}            Use developer persona")
      $(echo -e "${IT}${GRAY}ai persona create mycustom${R}    Create custom persona")

$(echo -e "${B}${BCYAN}━━ UTILITY & TOOLS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BGREEN}history${R} ${GRAY}[--n 20] [--session name] [--search term]${R}")
  $(echo -e "${BGREEN}clear-history${R} ${GRAY}[name|--all]${R}")
  $(echo -e "${BGREEN}bench${R} ${BYELLOW}<prompt>${R} ${GRAY}[--runs N]${R}              Benchmark inference speed")
  $(echo -e "${BGREEN}serve${R} ${GRAY}[--port 8080] [--host 0.0.0.0]${R}       Launch inference server")
  $(echo -e "${BGREEN}convert${R} ${BYELLOW}<path>${R} ${GRAY}[--to gguf] [--quant Q4_K_M]${R}")
  $(echo -e "${BGREEN}config${R} ${GRAY}[key] [value]${R}                        View/set config values")
      $(echo -e "${IT}${GRAY}ai config temperature 0.5${R}")
      $(echo -e "${IT}${GRAY}ai config max_tokens 4096${R}")
  $(echo -e "${BGREEN}status${R}")
  $(echo -e "${BGREEN}install-deps${R} ${GRAY}[--force] [--cpu-only]${R}")
  $(echo -e "${BGREEN}version${R}")
  $(echo -e "${BGREEN}-help${R} / ${BGREEN}--help${R}")

$(echo -e "${B}${BCYAN}━━ BACKEND × FEATURE MATRIX ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

$(printf "  ${B}${WHITE}%-14s %-18s %-6s %-8s %-7s %-10s %-10s${R}\n" "Backend" "Formats" "ask" "image" "think" "imagine" "download")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BYELLOW}%-8s${R} ${BGREEN}%-7s${R} ${RED}%-10s${R} ${BGREEN}%-10s${R}\n" "gguf"      ".gguf"              "✓" "✓ llava" "✓" "✗"        "HF / URL")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${RED}%-6s${R} ${BGREEN}%-8s${R} ${RED}%-7s${R} ${BGREEN}%-10s${R} ${BGREEN}%-10s${R}\n" "diffusers" "SD/SDXL/FLUX"       "✗" "✓ gen"   "✗" "✓"        "HF")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BYELLOW}%-8s${R} ${BGREEN}%-7s${R} ${RED}%-10s${R} ${BGREEN}%-10s${R}\n" "pytorch"   ".safetensors/.bin"  "✓" "✓ llava" "✓" "✗"        "HF")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BGREEN}%-8s${R} ${BGREEN}%-7s${R} ${BGREEN}%-10s${R} ${BYELLOW}%-10s${R}\n" "openai"    "GPT-4o/o1/o3/o4"   "✓" "✓"       "✓ o1" "✓ DALL-E" "API key")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BGREEN}%-8s${R} ${BGREEN}%-7s${R} ${RED}%-10s${R} ${BYELLOW}%-10s${R}\n" "claude"    "Claude 3/4 family"  "✓" "✓"       "✓"    "✗"        "API key")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BGREEN}%-8s${R} ${BGREEN}%-7s${R} ${BGREEN}%-10s${R} ${BYELLOW}%-10s${R}\n" "gemini"    "Gemini 1.5/2.0"     "✓" "✓"       "✓"    "✓ Imagen" "API key")
$(printf "  ${BGREEN}%-14s${R} ${GRAY}%-18s${R} ${BGREEN}%-6s${R} ${BGREEN}%-8s${R} ${BGREEN}%-7s${R} ${RED}%-10s${R} ${BYELLOW}%-10s${R}\n" "hf"        "HF Inference API"   "✓" "✓"       "✓"    "✗"        "HF token")

  $(echo -e "${GRAY}* vision needs a vision-capable model: LLaVA, Moondream, BakLLaVA, etc.${R}")

$(echo -e "${B}${BCYAN}━━ QUICK START ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}")

  $(echo -e "${BYELLOW}# Install all dependencies (uses your system Python 3.12)${R}")
  $(echo -e "${WHITE}ai install-deps${R}")

  $(echo -e "${BYELLOW}# Option A: Cloud API (no GPU needed)${R}")
  $(echo -e "${WHITE}ai download claude sk-ant-...      # or openai / gemini${R}")
  $(echo -e "${WHITE}ai model claude-sonnet-4-5${R}")
  $(echo -e "${WHITE}ai ask \"Hello!\"${R}")

  $(echo -e "${BYELLOW}# Option B: Local GGUF (CPU or GPU)${R}")
  $(echo -e "${WHITE}ai download TheBloke/Mistral-7B-Instruct-v0.2-GGUF --file mistral-7b-instruct-v0.2.Q4_K_M.gguf${R}")
  $(echo -e "${WHITE}ai model ~/.ai-cli/models/Mistral-7B-Instruct-v0.2-GGUF/mistral-7b-instruct-v0.2.Q4_K_M.gguf${R}")
  $(echo -e "${WHITE}ai ask \"What is quantum computing?\"${R}")

  $(echo -e "${BYELLOW}# Option C: Interactive chat with sessions${R}")
  $(echo -e "${WHITE}ai chat --session myproject${R}")

HELPEOF
}

# ════════════════════════════════════════════════════════════════════
#  BACKEND DETECTION
# ════════════════════════════════════════════════════════════════════
detect_backend() {
  local m="$1"
  [[ "$m" == gpt-* || "$m" == o1* || "$m" == o3* || "$m" == o4* || "$m" == chatgpt* ]] && { echo "openai"; return; }
  [[ "$m" == claude-* ]] && { echo "claude"; return; }
  [[ "$m" == gemini-* ]] && { echo "gemini"; return; }
  [[ "$m" == *.gguf ]] && { echo "gguf"; return; }
  [[ -f "$m" && "$m" == *.gguf ]] && { echo "gguf"; return; }
  [[ -f "$MODELS_DIR/$m" ]] && { echo "gguf"; return; }
  echo "$m" | grep -qiE "stable-diffusion|sdxl|flux|sd-[0-9]|kandinsky|dall-e" && { echo "diffusers"; return; }
  [[ -n "${HF_TOKEN:-}" ]] && { echo "hf"; return; }
  echo "pytorch"
}

resolve_model_path() {
  local m="$ACTIVE_MODEL"
  [[ -f "$m" ]] && { echo "$m"; return; }
  [[ -f "$MODELS_DIR/$m" ]] && { echo "$MODELS_DIR/$m"; return; }
  local found; found=$(find "$MODELS_DIR" -name "$m" -type f 2>/dev/null | head -1)
  [[ -n "$found" ]] && { echo "$found"; return; }
  echo "$m"
}

# ════════════════════════════════════════════════════════════════════
#  INSTALL DEPS
# ════════════════════════════════════════════════════════════════════
cmd_install_deps() {
  local force=0 cpu_only=0 no_torch=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1 ;; --cpu-only) cpu_only=1 ;; --no-torch) no_torch=1 ;; esac
    shift
  done

  header "AI CLI Dependency Installer"

  # ── Python check ────────────────────────────────────────────────
  if [[ -z "$PYTHON" ]]; then
    err "Python 3.10+ not found!"
    info "Install: sudo apt install python3.12 python3.12-dev python3-pip"
    exit 1
  fi
  ok "Python: $($PYTHON --version 2>&1) → $PYTHON"

  local PIP="$PYTHON -m pip"
  $PIP --version &>/dev/null || {
    warn "pip missing. Bootstrapping..."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON"
  }

  # ── System packages ─────────────────────────────────────────────
  info "Installing system packages..."
  sudo apt-get install -qq -y \
    jq curl wget git build-essential cmake pkg-config \
    libopenblas-dev libgomp1 ffmpeg \
    python3-dev 2>/dev/null | tail -2 || warn "Some apt packages may have failed (non-fatal)"
  ok "System packages done"

  # ── PyTorch ─────────────────────────────────────────────────────
  if [[ $no_torch -eq 0 ]]; then
    info "Installing PyTorch..."
    if [[ $cpu_only -eq 1 ]]; then
      $PIP install --break-system-packages -q --upgrade \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu
      ok "PyTorch (CPU) installed"
    elif command -v nvidia-smi &>/dev/null; then
      local cuda; cuda=$(nvidia-smi | grep -oP "CUDA Version: \K[0-9.]+" | head -1 || echo "12.1")
      info "NVIDIA GPU + CUDA ${cuda} detected"
      local cu_tag="cu$(echo "$cuda" | tr -d '.')"
      $PIP install --break-system-packages -q --upgrade \
        torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${cu_tag}" 2>/dev/null || \
      $PIP install --break-system-packages -q --upgrade torch torchvision torchaudio
      ok "PyTorch (CUDA) installed"
    else
      warn "No NVIDIA GPU found — installing CPU PyTorch"
      $PIP install --break-system-packages -q --upgrade \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu
      ok "PyTorch (CPU) installed"
    fi
  fi

  # ── HuggingFace stack ───────────────────────────────────────────
  info "Installing HuggingFace + Transformers..."
  $PIP install --break-system-packages -q --upgrade \
    huggingface_hub transformers tokenizers accelerate \
    safetensors sentencepiece protobuf datasets optimum
  ok "Transformers stack installed"

  info "Installing Diffusers..."
  $PIP install --break-system-packages -q --upgrade \
    diffusers Pillow opencv-python-headless invisible-watermark
  ok "Diffusers installed"

  # ── llama-cpp-python ────────────────────────────────────────────
  # Check if already installed
  if "$PYTHON" -c "import llama_cpp" 2>/dev/null && [[ $force -eq 0 ]]; then
    local lv; lv=$("$PYTHON" -c "import llama_cpp; print(llama_cpp.__version__)" 2>/dev/null || echo "?")
    ok "llama-cpp-python already installed (${lv})"
  else
    info "Installing llama-cpp-python..."
    if command -v nvidia-smi &>/dev/null && [[ $cpu_only -eq 0 ]]; then
      info "Compiling with CUDA support (this takes a few minutes)..."
      CMAKE_ARGS="-DLLAMA_CUDA=on" \
      FORCE_CMAKE=1 \
      $PIP install --break-system-packages -q --upgrade llama-cpp-python 2>/dev/null || \
      $PIP install --break-system-packages -q --upgrade llama-cpp-python
    else
      $PIP install --break-system-packages -q --upgrade llama-cpp-python
    fi
    ok "llama-cpp-python installed"
  fi

  # ── Detect llama.cpp binary ─────────────────────────────────────
  LLAMA_BIN="$(find_llama_cpp)"
  if [[ -z "$LLAMA_BIN" ]]; then
    warn "No llama-cli binary found in PATH."
    info "Build llama.cpp for best GGUF performance:"
    echo ""
    echo -e "    ${BYELLOW}git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp${R}"
    echo -e "    ${BYELLOW}cd ~/llama.cpp && cmake -B build -DLLAMA_CUDA=ON && cmake --build build -j\$(nproc)${R}"
    echo -e "    ${BYELLOW}echo 'export PATH=\$HOME/llama.cpp/build/bin:\$PATH' >> ~/.bashrc${R}"
    echo ""
    info "Or install llama-cpp-python server: ${YELLOW}pip install 'llama-cpp-python[server]' --break-system-packages${R}"
    info "The Python API fallback will be used automatically."
  else
    ok "llama.cpp binary: $LLAMA_BIN"
  fi

  # ── Optional extras ─────────────────────────────────────────────
  info "Installing optional extras (openai, anthropic, google-generativeai)..."
  $PIP install --break-system-packages -q --upgrade \
    openai anthropic google-generativeai tiktoken \
    requests tqdm rich pydub soundfile 2>/dev/null || warn "Some optional packages failed (non-fatal)"
  ok "Optional extras installed"

  echo ""
  divider
  ok "${B}All dependencies installed!${R}"
  info "Run ${YELLOW}ai status${R} to verify everything."
  echo ""
}

# ════════════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════════════
cmd_status() {
  header "AI CLI Status — v${VERSION}"
  label "OS:"        "$(uname -srm)"
  label "Python:"    "${PYTHON:-${RED}not found${R}} $([[ -n "$PYTHON" ]] && $PYTHON --version 2>&1 | awk '{print $2}')"
  label "llama.cpp:" "${LLAMA_BIN:-${BYELLOW}not found — python API fallback active${R}}"
  label "GPU:"       "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo 'none detected')"
  echo ""
  label "Active model:"   "${ACTIVE_MODEL:-${BYELLOW}not set${R}}"
  label "Backend:"        "${ACTIVE_BACKEND:-${GRAY}auto-detect${R}}"
  label "Session:"        "$ACTIVE_SESSION"
  label "Persona:"        "${ACTIVE_PERSONA:-${GRAY}none${R}}"
  label "Temperature:"    "$TEMPERATURE"
  label "Max tokens:"     "$MAX_TOKENS"
  echo ""
  label "OpenAI key:"  "$([[ -n "${OPENAI_API_KEY:-}"    ]] && echo "${BGREEN}set${R}" || echo "${RED}not set${R}")"
  label "Claude key:"  "$([[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "${BGREEN}set${R}" || echo "${RED}not set${R}")"
  label "Gemini key:"  "$([[ -n "${GEMINI_API_KEY:-}"    ]] && echo "${BGREEN}set${R}" || echo "${RED}not set${R}")"
  label "HF token:"    "$([[ -n "${HF_TOKEN:-}"          ]] && echo "${BGREEN}set${R}" || echo "${RED}not set${R}")"
  echo ""
  echo -e "  ${B}Python packages:${R}"
  for pkg in torch transformers diffusers llama_cpp huggingface_hub openai anthropic; do
    if [[ -n "$PYTHON" ]] && "$PYTHON" -c "import $pkg" 2>/dev/null; then
      local ver; ver=$("$PYTHON" -c "import $pkg; print(getattr($pkg,'__version__','?'))" 2>/dev/null || echo "?")
      printf "    ${BGREEN}✓${R}  %-30s ${GRAY}%s${R}\n" "$pkg" "$ver"
    else
      printf "    ${RED}✗${R}  %-30s ${GRAY}not installed${R}\n" "$pkg"
    fi
  done
  echo ""
  local count; count=$(find "$MODELS_DIR" -type f \( -name "*.gguf" -o -name "*.safetensors" \) 2>/dev/null | wc -l)
  label "Local models:" "$count file(s) in $MODELS_DIR"
  echo ""
}

# ════════════════════════════════════════════════════════════════════
#  DOWNLOAD
# ════════════════════════════════════════════════════════════════════
cmd_download() {
  local source="${1:-}"; shift 2>/dev/null || true

  # API key shortcuts
  case "${source,,}" in
    openai)
      local key="${1:-}"; [[ -z "$key" ]] && { err "Usage: ai download openai <sk-...>"; exit 1; }
      sed -i '/^OPENAI_API_KEY=/d' "$KEYS_FILE" 2>/dev/null || true
      echo "OPENAI_API_KEY=\"$key\"" >> "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
      ok "OpenAI API key saved."; return ;;
    claude|anthropic)
      local key="${1:-}"; [[ -z "$key" ]] && { err "Usage: ai download claude <sk-ant-...>"; exit 1; }
      sed -i '/^ANTHROPIC_API_KEY=/d' "$KEYS_FILE" 2>/dev/null || true
      echo "ANTHROPIC_API_KEY=\"$key\"" >> "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
      ok "Claude/Anthropic API key saved."; return ;;
    gemini|google)
      local key="${1:-}"; [[ -z "$key" ]] && { err "Usage: ai download gemini <AIza...>"; exit 1; }
      sed -i '/^GEMINI_API_KEY=/d' "$KEYS_FILE" 2>/dev/null || true
      echo "GEMINI_API_KEY=\"$key\"" >> "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
      ok "Gemini API key saved."; return ;;
    hf|huggingface)
      local key="${1:-}"; [[ -z "$key" ]] && { err "Usage: ai download hf <hf_...>"; exit 1; }
      sed -i '/^HF_TOKEN=/d' "$KEYS_FILE" 2>/dev/null || true
      echo "HF_TOKEN=\"$key\"" >> "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
      ok "HuggingFace token saved."; return ;;
  esac

  # HuggingFace download
  require_python
  local repo="$source"
  repo="${repo#https://huggingface.co/}"; repo="${repo%/}"
  local specific_file="" gguf_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --file) specific_file="${2:-}"; shift ;; --gguf) gguf_only=1 ;; esac
    shift
  done

  [[ -z "$repo" ]] && { err "No repo specified. Example: ai download TheBloke/Mistral-7B-GGUF"; exit 1; }
  info "Downloading ${B}$repo${R} from HuggingFace..."

  if ! "$PYTHON" -c "import huggingface_hub" 2>/dev/null; then
    err "huggingface_hub not installed. Run: ai install-deps"; exit 1
  fi

  local dest="$MODELS_DIR/$(basename "$repo")"
  mkdir -p "$dest"

  (
    "$PYTHON" - <<PYEOF
from huggingface_hub import snapshot_download, hf_hub_download
import sys

repo = "$repo"
dest = "$dest"
token = "${HF_TOKEN:-}" or None
specific = "$specific_file"
gguf_only = "$gguf_only" == "1"

try:
    if specific:
        path = hf_hub_download(repo, specific, local_dir=dest, token=token)
        print(f"Downloaded: {path}")
    elif gguf_only:
        path = snapshot_download(repo, local_dir=dest, token=token,
            allow_patterns=["*.gguf","*.json","*.md"])
        print(f"Downloaded to: {path}")
    else:
        path = snapshot_download(repo, local_dir=dest, token=token,
            ignore_patterns=["*.msgpack","*.h5","flax_model*","tf_model*"])
        print(f"Downloaded to: {path}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  ) & spinner $! "Downloading $repo (this may take a while)..."

  wait $!
  ok "Download complete → ${WHITE}$dest${R}"
  info "Activate with: ${YELLOW}ai model $dest/<filename>.gguf${R}"
}

# ════════════════════════════════════════════════════════════════════
#  KEYS
# ════════════════════════════════════════════════════════════════════
cmd_keys() {
  header "API Keys"
  label "OpenAI:"   "$([[ -n "${OPENAI_API_KEY:-}"    ]] && echo "${BGREEN}${OPENAI_API_KEY:0:8}…${R}"    || echo "${RED}not set${R}")"
  label "Claude:"   "$([[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "${BGREEN}${ANTHROPIC_API_KEY:0:10}…${R}" || echo "${RED}not set${R}")"
  label "Gemini:"   "$([[ -n "${GEMINI_API_KEY:-}"    ]] && echo "${BGREEN}${GEMINI_API_KEY:0:8}…${R}"    || echo "${RED}not set${R}")"
  label "HF Token:" "$([[ -n "${HF_TOKEN:-}"          ]] && echo "${BGREEN}${HF_TOKEN:0:8}…${R}"          || echo "${RED}not set${R}")"
  echo ""
  info "Keys stored in: ${WHITE}$KEYS_FILE${R}  (chmod 600)"
  info "Set with: ${YELLOW}ai download openai|claude|gemini|hf <key>${R}"
}

# ════════════════════════════════════════════════════════════════════
#  MODELS LIST
# ════════════════════════════════════════════════════════════════════
cmd_models() {
  header "Available Models"
  echo -e "  ${B}${BCYAN}Local Models${R}  ${GRAY}($MODELS_DIR)${R}"
  local found=0
  while IFS= read -r f; do
    local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
    local active=""; [[ "$f" == "$ACTIVE_MODEL" || "$(basename "$f")" == "$ACTIVE_MODEL" ]] && active=" ${BGREEN}← active${R}"
    local ext="${f##*.}"
    local backend
    case "$ext" in
      gguf) backend="${CYAN}gguf${R}" ;;
      safetensors|bin) backend="${MAGENTA}pytorch${R}" ;;
      *) backend="${GRAY}?${R}" ;;
    esac
    printf "    ${GREEN}%-52s${R}  ${GRAY}%6s${R}  [%b]%b\n" "$(basename "$f")" "$size" "$backend" "$active"
    found=1
  done < <(find "$MODELS_DIR" -type f \( -name "*.gguf" -o -name "*.safetensors" -o -name "*.bin" \) 2>/dev/null | sort)
  [[ $found -eq 0 ]] && echo -e "    ${GRAY}None. Try: ai download TheBloke/Mistral-7B-Instruct-v0.2-GGUF${R}"
  echo ""
  echo -e "  ${B}${BCYAN}API Models${R}"
  [[ -n "${OPENAI_API_KEY:-}"    ]] && echo -e "    ${BGREEN}OpenAI:${R}  gpt-4o  gpt-4o-mini  o1  o1-mini  o3  o4-mini  gpt-4-turbo"
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo -e "    ${BGREEN}Claude:${R}  claude-opus-4-5  claude-sonnet-4-5  claude-haiku-4-5"
  [[ -n "${GEMINI_API_KEY:-}"    ]] && echo -e "    ${BGREEN}Gemini:${R}  gemini-2.0-flash  gemini-1.5-pro  gemini-1.5-flash"
  [[ -n "${HF_TOKEN:-}"          ]] && echo -e "    ${BGREEN}HF API:${R}  Any public or gated HuggingFace model"
  echo ""
}

# ════════════════════════════════════════════════════════════════════
#  THINK — chain-of-thought
# ════════════════════════════════════════════════════════════════════
build_think_prompt() {
  cat <<THINKEOF
You are a meticulous reasoning assistant. Work step-by-step.

Format your response EXACTLY like this — do not deviate:
<think>
Step 1: [understand what is being asked]
Step 2: [break down the problem]
Step 3: [work through the solution or reasoning]
Step 4: [verify or consider edge cases]
...continue as needed...
</think>

<answer>
[Your final, clear, concise answer here]
</answer>

Question: $1
THINKEOF
}

render_think_output() {
  local raw="$1"
  local in_think=0 in_answer=0
  echo ""
  echo -e "${B}${BG_MAGENTA}${BWHITE}  🧠 Chain-of-Thought  ${R}"
  echo ""
  echo -e "${MAGENTA}${B}┌─ Reasoning ─────────────────────────────────────────────────┐${R}"
  while IFS= read -r line; do
    if echo "$line" | grep -q "<think>";  then in_think=1;  continue; fi
    if echo "$line" | grep -q "</think>"; then
      in_think=0
      echo -e "${MAGENTA}${B}└─────────────────────────────────────────────────────────────┘${R}"
      echo ""
      echo -e "${BGREEN}${B}┌─ Answer ─────────────────────────────────────────────────────┐${R}"
      continue
    fi
    if echo "$line" | grep -q "<answer>";  then in_answer=1; continue; fi
    if echo "$line" | grep -q "</answer>"; then
      in_answer=0
      echo -e "${BGREEN}${B}└─────────────────────────────────────────────────────────────┘${R}"
      continue
    fi
    [[ $in_think  -eq 1 ]] && echo -e "${MAGENTA}│${R} ${DIM}$line${R}"
    [[ $in_answer -eq 1 ]] && echo -e "${BGREEN}│${R}  $line"
  done <<< "$raw"
  # Fallback: no tags found
  if ! echo "$raw" | grep -q "<think>"; then echo -e "$raw"; fi
  echo ""
}

# ════════════════════════════════════════════════════════════════════
#  BACKENDS
# ════════════════════════════════════════════════════════════════════

ask_gguf() {
  local prompt="$1" image="${2:-}"
  local model_path; model_path=$(resolve_model_path)
  [[ ! -f "$model_path" ]] && { err "GGUF model not found: $model_path"; exit 1; }

  # Use CLI binary if available (fastest)
  if [[ -n "$LLAMA_BIN" && "$LLAMA_BIN" != "llama_cpp_python" ]]; then
    local args=(-m "$model_path" --no-display-prompt -p "$prompt" -n "$MAX_TOKENS" --temp "$TEMPERATURE" --log-disable)
    [[ -n "$image" ]] && args+=(--image "$image")
    "$LLAMA_BIN" "${args[@]}" 2>/dev/null
    return
  fi

  # Fallback: llama-cpp-python
  require_python
  "$PYTHON" - <<PYEOF
import sys
try:
    from llama_cpp import Llama

    llm = Llama(
        model_path="$model_path",
        n_ctx=4096,
        n_gpu_layers=-1,
        verbose=False
    )
    out = llm.create_chat_completion(
        messages=[{"role": "user", "content": """$prompt"""}],
        max_tokens=$MAX_TOKENS,
        temperature=$TEMPERATURE,
        stream=False
    )
    print(out["choices"][0]["message"]["content"])
except ImportError:
    print("llama-cpp-python not installed. Run: ai install-deps", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

ask_pytorch() {
  local prompt="$1" image="${2:-}"
  require_python
  "$PYTHON" - <<PYEOF
import sys
model_id = "$ACTIVE_MODEL"
prompt = """$prompt"""
image_path = "$image"
hf_token = "${HF_TOKEN:-}" or None

try:
    import torch
    from transformers import pipeline, AutoProcessor

    if image_path:
        from transformers import LlavaForConditionalGeneration
        from PIL import Image
        import requests
        from io import BytesIO

        proc  = AutoProcessor.from_pretrained(model_id, token=hf_token)
        model = LlavaForConditionalGeneration.from_pretrained(
            model_id, torch_dtype=torch.float16, device_map="auto", token=hf_token)

        if image_path.startswith("http"):
            img = Image.open(BytesIO(requests.get(image_path, timeout=30).content)).convert("RGB")
        else:
            img = Image.open(image_path).convert("RGB")

        inputs = proc(text=prompt, images=img, return_tensors="pt").to(model.device)
        out = model.generate(**inputs, max_new_tokens=$MAX_TOKENS)
        print(proc.decode(out[0], skip_special_tokens=True))
    else:
        pipe = pipeline("text-generation", model=model_id, device_map="auto",
                        torch_dtype="auto", token=hf_token)
        result = pipe(prompt, max_new_tokens=$MAX_TOKENS, do_sample=True, temperature=$TEMPERATURE)
        text = result[0]["generated_text"]
        print(text[len(prompt):].strip() if text.startswith(prompt) else text)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

ask_diffusers() {
  local prompt="$1" steps="${2:-30}" size="${3:-1024x1024}" out_file="${4:-}"
  require_python
  [[ -z "$out_file" ]] && out_file="$AI_OUTPUT_DIR/generated-$(date +%s).png"
  local width="${size%x*}" height="${size#*x}"
  "$PYTHON" - <<PYEOF
import sys
model_id = "$ACTIVE_MODEL"
prompt = """$prompt"""
out_path = "$out_file"
hf_token = "${HF_TOKEN:-}" or None
steps, width, height = $steps, $width, $height

try:
    from diffusers import AutoPipelineForText2Image, DiffusionPipeline
    import torch

    dtype  = torch.float16 if torch.cuda.is_available() else torch.float32
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Loading {model_id} on {device}...", flush=True)

    try:
        pipe = AutoPipelineForText2Image.from_pretrained(
            model_id, torch_dtype=dtype, token=hf_token,
            variant="fp16" if device == "cuda" else None)
    except Exception:
        pipe = DiffusionPipeline.from_pretrained(model_id, torch_dtype=dtype, token=hf_token)

    pipe = pipe.to(device)
    if device == "cuda":
        try: pipe.enable_xformers_memory_efficient_attention()
        except: pass

    print("Generating...", flush=True)
    image = pipe(prompt, num_inference_steps=steps, width=width, height=height,
                 guidance_scale=7.5).images[0]
    image.save(out_path)
    print(f"Saved: {out_path}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

ask_openai() {
  local prompt="$1" image="${2:-}"
  require_jq; require_curl
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "No OpenAI key. Run: ai download openai sk-..."; exit 1; }

  local content_json
  if [[ -n "$image" ]]; then
    local img_url
    if [[ "$image" == http* ]]; then
      content_json=$(jq -nc --arg p "$prompt" --arg u "$image" \
        '[{"type":"text","text":$p},{"type":"image_url","image_url":{"url":$u}}]')
    else
      local mime="image/jpeg"
      [[ "$image" == *.png  ]] && mime="image/png"
      [[ "$image" == *.webp ]] && mime="image/webp"
      local img_data; img_data=$(base64 -w0 "$image")
      content_json=$(jq -nc --arg p "$prompt" --arg d "$img_data" --arg m "$mime" \
        '[{"type":"text","text":$p},{"type":"image_url","image_url":{"url":("data:"+$m+";base64,"+$d)}}]')
    fi
  else
    content_json=$(jq -nc --arg p "$prompt" '[{"type":"text","text":$p}]')
  fi

  local sys_prompt="You are a helpful assistant."
  [[ -n "${ACTIVE_PERSONA:-}" && -f "$PERSONAS_DIR/$ACTIVE_PERSONA.txt" ]] && \
    sys_prompt=$(cat "$PERSONAS_DIR/$ACTIVE_PERSONA.txt")

  local body
  body=$(jq -nc \
    --arg m "${ACTIVE_MODEL:-gpt-4o}" \
    --argjson c "$content_json" \
    --argjson mt "$MAX_TOKENS" \
    --argjson tp "$TEMPERATURE" \
    --arg s "$sys_prompt" \
    '{"model":$m,"messages":[{"role":"system","content":$s},{"role":"user","content":$c}],"max_tokens":$mt,"temperature":$tp}')

  curl -sf https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" | jq -r '.choices[0].message.content // "Error: no response"'
}

ask_claude() {
  local prompt="$1" image="${2:-}"
  require_jq; require_curl
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "No Claude key. Run: ai download claude sk-ant-..."; exit 1; }

  local content_json
  if [[ -n "$image" ]]; then
    local mime="image/jpeg"
    [[ "$image" == *.png  ]] && mime="image/png"
    [[ "$image" == *.webp ]] && mime="image/webp"
    [[ "$image" == *.gif  ]] && mime="image/gif"
    local img_data
    if [[ "$image" == http* ]]; then
      img_data=$(curl -sf "$image" | base64 -w0)
    else
      img_data=$(base64 -w0 "$image")
    fi
    content_json=$(jq -nc --arg p "$prompt" --arg d "$img_data" --arg m "$mime" \
      '[{"type":"image","source":{"type":"base64","media_type":$m,"data":$d}},{"type":"text","text":$p}]')
  else
    content_json=$(jq -nc --arg p "$prompt" '[{"type":"text","text":$p}]')
  fi

  local sys_prompt="You are a helpful assistant."
  [[ -n "${ACTIVE_PERSONA:-}" && -f "$PERSONAS_DIR/$ACTIVE_PERSONA.txt" ]] && \
    sys_prompt=$(cat "$PERSONAS_DIR/$ACTIVE_PERSONA.txt")

  local body
  body=$(jq -nc \
    --arg m "${ACTIVE_MODEL:-claude-sonnet-4-5}" \
    --argjson c "$content_json" \
    --argjson mt "$MAX_TOKENS" \
    --arg s "$sys_prompt" \
    '{"model":$m,"max_tokens":$mt,"system":$s,"messages":[{"role":"user","content":$c}]}')

  curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "$body" | jq -r '.content[0].text // "Error: no response"'
}

ask_gemini() {
  local prompt="$1" image="${2:-}"
  require_jq; require_curl
  [[ -z "${GEMINI_API_KEY:-}" ]] && { err "No Gemini key. Run: ai download gemini AIza..."; exit 1; }

  local model="${ACTIVE_MODEL:-gemini-2.0-flash}"
  local parts_json

  if [[ -n "$image" ]]; then
    local mime="image/jpeg"
    [[ "$image" == *.png  ]] && mime="image/png"
    [[ "$image" == *.webp ]] && mime="image/webp"
    local img_data
    if [[ "$image" == http* ]]; then
      img_data=$(curl -sf "$image" | base64 -w0)
    else
      img_data=$(base64 -w0 "$image")
    fi
    parts_json=$(jq -nc --arg p "$prompt" --arg d "$img_data" --arg m "$mime" \
      '[{"inline_data":{"mime_type":$m,"data":$d}},{"text":$p}]')
  else
    parts_json=$(jq -nc --arg p "$prompt" '[{"text":$p}]')
  fi

  local body
  body=$(jq -nc --argjson parts "$parts_json" --argjson mt "$MAX_TOKENS" --argjson tp "$TEMPERATURE" \
    '{"contents":[{"parts":$parts}],"generationConfig":{"maxOutputTokens":$mt,"temperature":$tp}}')

  curl -sf "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" | jq -r '.candidates[0].content.parts[0].text // "Error: no response"'
}

ask_hf() {
  local prompt="$1"
  require_curl
  [[ -z "${HF_TOKEN:-}" ]] && { err "No HF token. Run: ai download hf hf_..."; exit 1; }
  curl -sf "https://api-inference.huggingface.co/models/$ACTIVE_MODEL" \
    -H "Authorization: Bearer $HF_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"inputs\":$(jq -nc --arg p "$prompt" '$p'),\"parameters\":{\"max_new_tokens\":$MAX_TOKENS,\"temperature\":$TEMPERATURE}}" \
  | jq -r '.[0].generated_text // .[0].text // "Error: unexpected response"'
}

# ════════════════════════════════════════════════════════════════════
#  DISPATCH
# ════════════════════════════════════════════════════════════════════
dispatch_ask() {
  local prompt="$1" image="${2:-}" is_think="${3:-0}"
  require_model

  local backend="${ACTIVE_BACKEND:-$(detect_backend "$ACTIVE_MODEL")}"
  [[ "$is_think" == "1" ]] && prompt="$(build_think_prompt "$prompt")"

  echo -e "${GRAY}  [backend: ${backend}]  [model: ${ACTIVE_MODEL}]${R}" >&2
  log_interaction "user" "$prompt"

  local response
  case "$backend" in
    gguf)      response=$(ask_gguf "$prompt" "$image") ;;
    diffusers) ask_diffusers "$prompt"; return ;;
    pytorch)   response=$(ask_pytorch "$prompt" "$image") ;;
    openai)    response=$(ask_openai "$prompt" "$image") ;;
    claude)    response=$(ask_claude "$prompt" "$image") ;;
    gemini)    response=$(ask_gemini "$prompt" "$image") ;;
    hf)        response=$(ask_hf "$prompt") ;;
    *)         err "Unknown backend: $backend"; exit 1 ;;
  esac

  log_interaction "assistant" "$response"
  [[ "$is_think" == "1" ]] && render_think_output "$response" || echo -e "$response"
}

# ════════════════════════════════════════════════════════════════════
#  CHAT
# ════════════════════════════════════════════════════════════════════
cmd_chat() {
  local session="$ACTIVE_SESSION"
  [[ "${1:-}" == "--session" ]] && { session="$2"; ACTIVE_SESSION="$2"; save_config; }

  require_model
  local backend="${ACTIVE_BACKEND:-$(detect_backend "$ACTIVE_MODEL")}"
  header "Chat  [${ACTIVE_MODEL}]  [session: ${session}]"
  echo -e "  ${GRAY}CTRL+D or 'exit' to quit  |  '/reset' to clear history  |  '/think <q>' for CoT${R}"
  echo ""

  local history=()
  local session_f; session_f=$(session_file "$session")
  if [[ -f "$session_f" ]] && command -v jq &>/dev/null; then
    info "Resuming session: ${BGREEN}$session${R}"
    mapfile -t history < <(jq -c '.[]' "$session_f" 2>/dev/null)
    jq -r '.[] | "  [\(.role)] \(.content[0:100])"' "$session_f" 2>/dev/null | tail -6 | \
      while IFS= read -r l; do echo -e "${GRAY}$l${R}"; done
    echo ""
  fi

  while true; do
    printf "${BGREEN}you${R} ${GRAY}▸${R} "
    local user_input; IFS= read -r user_input || break
    [[ -z "$user_input" ]] && continue
    [[ "$user_input" == "exit" || "$user_input" == "quit" ]] && break
    [[ "$user_input" == "/reset" ]] && { history=(); rm -f "$session_f"; ok "Session cleared."; continue; }

    # /think support in chat
    local is_think=0 actual_input="$user_input"
    if [[ "$user_input" == /think* ]]; then
      is_think=1; actual_input="${user_input#/think }"; actual_input="$(build_think_prompt "$actual_input")"
    fi

    log_interaction "user" "$actual_input"
    history+=("{\"role\":\"user\",\"content\":$(jq -nc --arg c "$actual_input" '$c')}")

    printf "\n${BCYAN}ai${R}  ${GRAY}▸${R}  "

    local response=""
    case "$backend" in
      openai)
        local msgs_json; msgs_json=$(printf '%s\n' "${history[@]}" | jq -sc '.')
        response=$(jq -nc --arg m "${ACTIVE_MODEL:-gpt-4o}" --argjson msgs "$msgs_json" --argjson mt "$MAX_TOKENS" \
          '{"model":$m,"messages":$msgs,"max_tokens":$mt}' | \
          curl -sf https://api.openai.com/v1/chat/completions \
          -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" -d @- | \
          jq -r '.choices[0].message.content')
        ;;
      claude)
        local msgs_json; msgs_json=$(printf '%s\n' "${history[@]}" | jq -sc '.')
        response=$(jq -nc --arg m "${ACTIVE_MODEL:-claude-sonnet-4-5}" --argjson msgs "$msgs_json" --argjson mt "$MAX_TOKENS" \
          '{"model":$m,"max_tokens":$mt,"messages":$msgs}' | \
          curl -sf https://api.anthropic.com/v1/messages \
          -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
          -H "Content-Type: application/json" -d @- | \
          jq -r '.content[0].text')
        ;;
      *) response=$(dispatch_ask "$actual_input" "" "0" 2>/dev/null) ;;
    esac

    if [[ $is_think -eq 1 ]]; then
      render_think_output "$response"
    else
      echo -e "$response"
    fi
    echo ""

    log_interaction "assistant" "$response"
    history+=("{\"role\":\"assistant\",\"content\":$(jq -nc --arg c "$response" '$c')}")
    printf '%s\n' "${history[@]}" | jq -sc '.' > "$session_f"
  done
  echo -e "\n${GRAY}Session saved: $session_f${R}"
}

# ════════════════════════════════════════════════════════════════════
#  PIPE
# ════════════════════════════════════════════════════════════════════
cmd_pipe() {
  local prompt="${1:-Analyze this:}"
  local stdin_content; stdin_content=$(cat)
  dispatch_ask "$prompt

---
$stdin_content"
}

# ════════════════════════════════════════════════════════════════════
#  SESSIONS
# ════════════════════════════════════════════════════════════════════
cmd_session() {
  local subcmd="${1:-list}" name="${2:-}"
  case "$subcmd" in
    list)
      echo -e "${B}${BCYAN}Sessions:${R}"
      local found=0
      for f in "$SESSIONS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local sname; sname=$(basename "$f" .json)
        local count; count=$(jq '. | length' "$f" 2>/dev/null || echo "?")
        local active=""; [[ "$sname" == "$ACTIVE_SESSION" ]] && active=" ${BGREEN}← active${R}"
        printf "  ${CYAN}%-20s${R}  ${GRAY}%s msgs${R}%b\n" "$sname" "$count" "$active"
        found=1
      done
      [[ $found -eq 0 ]] && echo -e "  ${GRAY}No sessions yet.${R}"
      ;;
    new)
      [[ -z "$name" ]] && { err "Usage: ai session new <n>"; exit 1; }
      ACTIVE_SESSION="$name"; save_config; ok "Created session: ${BGREEN}$name${R}" ;;
    load)
      [[ -z "$name" ]] && { err "Usage: ai session load <n>"; exit 1; }
      [[ ! -f "$SESSIONS_DIR/$name.json" ]] && { err "Not found: $name"; exit 1; }
      ACTIVE_SESSION="$name"; save_config; ok "Loaded: ${BGREEN}$name${R}" ;;
    delete)
      [[ -z "$name" ]] && { err "Usage: ai session delete <n>"; exit 1; }
      rm -f "$SESSIONS_DIR/$name.json"; ok "Deleted: $name" ;;
    export)
      [[ -z "$name" ]] && name="$ACTIVE_SESSION"
      local f="$SESSIONS_DIR/$name.json"
      [[ ! -f "$f" ]] && { err "Not found: $name"; exit 1; }
      local out="$AI_OUTPUT_DIR/${name}-$(date +%Y%m%d).md"
      { echo "# AI Chat: $name"; echo "Exported: $(date)"; echo "";
        jq -r '.[] | "**\(.role | ascii_upcase)**\n\n\(.content)\n\n---\n"' "$f"; } > "$out"
      ok "Exported: ${WHITE}$out${R}" ;;
    *) err "Unknown: $subcmd"; info "Usage: ai session [list|new|load|delete|export] [name]" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  PERSONAS
# ════════════════════════════════════════════════════════════════════
BUILTIN_PERSONAS=(
  "default:You are a helpful, concise, and friendly assistant."
  "dev:You are an expert software engineer. Write clean, efficient, well-commented code. Focus on practical solutions. Point out bugs, security issues, and performance problems."
  "researcher:You are a rigorous research assistant. Cite your reasoning clearly, acknowledge uncertainty, and prefer depth over brevity."
  "writer:You are a skilled writer and editor. Focus on clarity, flow, and engagement. Adapt your tone to context."
  "teacher:You are a patient teacher. Explain concepts simply using analogies and examples. Check for understanding."
  "sysadmin:You are a Linux/DevOps expert. Give precise, tested shell commands. Prefer one-liners. Always explain what a command does before running it."
  "security:You are a cybersecurity expert. Think like an attacker to defend systems. Be precise about CVEs, attack vectors, and mitigations."
)

cmd_persona() {
  local subcmd="${1:-list}" name="${2:-}"
  case "$subcmd" in
    list)
      echo -e "${B}${BCYAN}Built-in Personas:${R}"
      for p in "${BUILTIN_PERSONAS[@]}"; do
        local pname="${p%%:*}" pdesc="${p#*:}"
        local active=""; [[ "$pname" == "${ACTIVE_PERSONA:-}" ]] && active=" ${BGREEN}← active${R}"
        printf "  ${CYAN}%-15s${R}  ${GRAY}%.70s${R}%b\n" "$pname" "$pdesc" "$active"
      done
      if ls "$PERSONAS_DIR"/*.txt &>/dev/null 2>&1; then
        echo -e "${B}${BCYAN}Custom Personas:${R}"
        for f in "$PERSONAS_DIR"/*.txt; do
          printf "  ${MAGENTA}%-15s${R}  ${GRAY}%s${R}\n" "$(basename "$f" .txt)" "$(head -1 "$f")"
        done
      fi ;;
    set)
      [[ -z "$name" ]] && { err "Usage: ai persona set <n>"; exit 1; }
      local found=0
      for p in "${BUILTIN_PERSONAS[@]}"; do
        if [[ "${p%%:*}" == "$name" ]]; then
          found=1; echo "${p#*:}" > "$PERSONAS_DIR/$name.txt"
        fi
      done
      [[ $found -eq 0 && ! -f "$PERSONAS_DIR/$name.txt" ]] && {
        err "Persona not found: $name"; info "Run: ai persona list"; exit 1; }
      ACTIVE_PERSONA="$name"; save_config; ok "Persona: ${BGREEN}$name${R}" ;;
    create)
      [[ -z "$name" ]] && { err "Usage: ai persona create <n>"; exit 1; }
      echo -e "${CYAN}Describe the persona (CTRL+D when done):${R}"
      cat > "$PERSONAS_DIR/$name.txt"
      ok "Created: $name"; info "Activate: ${YELLOW}ai persona set $name${R}" ;;
    edit)
      [[ -z "$name" ]] && name="$ACTIVE_PERSONA"
      "${EDITOR:-nano}" "$PERSONAS_DIR/$name.txt"; ok "Updated: $name" ;;
    *) err "Unknown: $subcmd"; info "Usage: ai persona [list|set|create|edit] [name]" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  IMAGINE
# ════════════════════════════════════════════════════════════════════
cmd_imagine() {
  local prompt="" steps=30 size="1024x1024" out_file=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --steps) steps="$2"; shift ;; --size) size="$2"; shift ;;
      --out) out_file="$2"; shift ;; *) args+=("$1") ;; esac; shift
  done
  prompt="${args[*]}"
  [[ -z "$prompt" ]] && { err "Usage: ai imagine <prompt> [--steps N] [--size WxH] [--out file]"; exit 1; }

  local backend="${ACTIVE_BACKEND:-$(detect_backend "${ACTIVE_MODEL:-openai}")}"
  if [[ "$backend" == "openai" ]]; then
    require_jq; require_curl
    [[ -z "${OPENAI_API_KEY:-}" ]] && { err "No OpenAI key."; exit 1; }
    info "Generating via DALL-E 3..."
    [[ -z "$out_file" ]] && out_file="$AI_OUTPUT_DIR/dalle-$(date +%s).png"
    local img_url
    img_url=$(curl -sf https://api.openai.com/v1/images/generations \
      -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
      -d "{\"model\":\"dall-e-3\",\"prompt\":$(jq -nc --arg p "$prompt" '$p'),\"n\":1,\"size\":\"$size\"}" | \
      jq -r '.data[0].url')
    curl -sf "$img_url" -o "$out_file"
    ok "Saved: ${WHITE}$out_file${R}"
  else
    ask_diffusers "$prompt" "$steps" "$size" "$out_file"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  TTS
# ════════════════════════════════════════════════════════════════════
cmd_tts() {
  require_jq; require_curl
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "TTS requires OpenAI key."; exit 1; }
  local text="" voice="alloy" out_file="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --voice) voice="$2"; shift ;; --out) out_file="$2"; shift ;; *) args+=("$1") ;; esac; shift
  done
  text="${args[*]}"
  [[ -z "$text" ]] && { err "Usage: ai tts <text> [--voice alloy|echo|fable|onyx|nova|shimmer] [--out file.mp3]"; exit 1; }
  [[ -z "$out_file" ]] && out_file="$AI_OUTPUT_DIR/tts-$(date +%s).mp3"
  info "Generating speech (voice: $voice)..."
  curl -sf https://api.openai.com/v1/audio/speech \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"tts-1\",\"input\":$(jq -nc --arg t "$text" '$t'),\"voice\":\"$voice\"}" \
    --output "$out_file"
  ok "Saved: ${WHITE}$out_file${R}"
  command -v mpv     &>/dev/null && mpv "$out_file" &>/dev/null & disown
  command -v paplay  &>/dev/null && ! command -v mpv &>/dev/null && paplay "$out_file" & disown
}

# ════════════════════════════════════════════════════════════════════
#  TRANSCRIBE
# ════════════════════════════════════════════════════════════════════
cmd_transcribe() {
  local file="${1:-}" lang="en"
  [[ "${2:-}" == "--lang" ]] && lang="${3:-en}"
  [[ -z "$file" || ! -f "$file" ]] && { err "Usage: ai transcribe <audio-file> [--lang en]"; exit 1; }
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    info "Transcribing via OpenAI Whisper..."
    curl -sf https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F file="@$file" -F model="whisper-1" -F language="$lang" | jq -r '.text'
  else
    require_python
    info "Transcribing via local Whisper..."
    "$PYTHON" -c "
import sys
try:
    import whisper
    m = whisper.load_model('base')
    print(m.transcribe('$file', language='$lang')['text'])
except ImportError:
    print('Install whisper: pip install openai-whisper --break-system-packages', file=sys.stderr)
    sys.exit(1)
"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  SUMMARIZE
# ════════════════════════════════════════════════════════════════════
cmd_summarize() {
  local target="${1:-}" format="markdown"
  [[ "${2:-}" == "--format" ]] && format="${3:-markdown}"
  local content=""
  if [[ -z "$target" ]]; then content=$(cat)
  elif [[ "$target" == http* ]]; then content=$(curl -sf "$target" | sed 's/<[^>]*>//g' | head -400)
  elif [[ -f "$target" ]]; then content=$(cat "$target")
  else err "Not found: $target"; exit 1; fi
  local fmt
  case "$format" in
    bullet)   fmt="Summarize as bullet points:" ;;
    tldr)     fmt="Give a 2-3 sentence TL;DR:" ;;
    markdown) fmt="Summarize in structured markdown with headers:" ;;
    *)        fmt="Summarize:" ;;
  esac
  dispatch_ask "$fmt

$content"
}

# ════════════════════════════════════════════════════════════════════
#  TRANSLATE
# ════════════════════════════════════════════════════════════════════
cmd_translate() {
  local lang="English" args=()
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "to" ]] && { lang="${2:-English}"; shift; shift; continue; }
    args+=("$1"); shift
  done
  [[ ${#args[@]} -eq 0 ]] && { err "Usage: ai translate <text> to <language>"; exit 1; }
  dispatch_ask "Translate to $lang. Output only the translation:

${args[*]}"
}

# ════════════════════════════════════════════════════════════════════
#  CODE
# ════════════════════════════════════════════════════════════════════
cmd_code() {
  local lang="" run=0 args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --lang) lang="$2"; shift ;; --run) run=1 ;; *) args+=("$1") ;; esac; shift
  done
  [[ ${#args[@]} -eq 0 ]] && { err "Usage: ai code <prompt> [--lang python|bash|js] [--run]"; exit 1; }
  local lang_hint=""; [[ -n "$lang" ]] && lang_hint="Write in $lang."
  local response
  response=$(dispatch_ask "You are an expert programmer. $lang_hint Write clean, working, commented code.
Output ONLY the code block, no preamble.
Task: ${args[*]}")
  echo -e "$response"
  if [[ $run -eq 1 && -n "$lang" ]]; then
    local code_file
    case "${lang,,}" in
      python) code_file=$(mktemp /tmp/ai_XXXX.py) ;;
      bash|sh) code_file=$(mktemp /tmp/ai_XXXX.sh) ;;
      js|javascript) code_file=$(mktemp /tmp/ai_XXXX.js) ;;
      *) warn "Auto-run not supported for $lang"; return ;;
    esac
    echo "$response" | sed -n '/```/,/```/p' | grep -v '```' > "$code_file"
    echo ""; info "Running..."; divider
    case "${lang,,}" in
      python) "$PYTHON" "$code_file" ;;
      bash|sh) bash "$code_file" ;;
      js) node "$code_file" 2>/dev/null || err "node not found" ;;
    esac
    divider; rm -f "$code_file"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  REVIEW
# ════════════════════════════════════════════════════════════════════
cmd_review() {
  local file="${1:-}"
  [[ -z "$file" || ! -f "$file" ]] && { err "Usage: ai review <file>"; exit 1; }
  local ext="${file##*.}"
  dispatch_ask "You are a senior code reviewer. Review for:
1. Bugs and logic errors  2. Security vulnerabilities  3. Performance issues
4. Code style/readability  5. Improvements (with examples)

\`\`\`$ext
$(cat "$file")
\`\`\`"
}

# ════════════════════════════════════════════════════════════════════
#  EXPLAIN
# ════════════════════════════════════════════════════════════════════
cmd_explain() {
  local content=""
  [[ -f "${1:-}" ]] && content=$(cat "$1") || content="$*"
  dispatch_ask "Explain the following in plain English with examples:

$content"
}

# ════════════════════════════════════════════════════════════════════
#  BENCH
# ════════════════════════════════════════════════════════════════════
cmd_bench() {
  local runs=3 args=()
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--runs" ]] && { runs="${2:-3}"; shift; shift; continue; }
    args+=("$1"); shift
  done
  local prompt="${args[*]:-Hello, how are you?}"
  require_model
  header "Benchmark: $ACTIVE_MODEL"
  label "Prompt:" "$prompt"; label "Runs:" "$runs"; echo ""
  local total=0
  for ((i=1; i<=runs; i++)); do
    local t0; t0=$(date +%s%N)
    dispatch_ask "$prompt" "" "0" > /dev/null 2>&1
    local t1; t1=$(date +%s%N)
    local ms=$(( (t1 - t0) / 1000000 ))
    total=$((total + ms))
    printf "  Run %d:  ${BGREEN}%d ms${R}\n" "$i" "$ms"
  done
  echo ""; label "Average:" "${BGREEN}$((total / runs)) ms${R}"; echo ""
}

# ════════════════════════════════════════════════════════════════════
#  SERVE
# ════════════════════════════════════════════════════════════════════
cmd_serve() {
  require_model
  local port=8080 host="0.0.0.0"
  while [[ $# -gt 0 ]]; do
    case "$1" in --port) port="$2"; shift ;; --host) host="$2"; shift ;; esac; shift
  done
  local backend="${ACTIVE_BACKEND:-$(detect_backend "$ACTIVE_MODEL")}"
  local model_path; model_path=$(resolve_model_path)
  header "AI Server  ${host}:${port}"
  label "Model:" "$ACTIVE_MODEL"; label "Backend:" "$backend"; echo ""
  case "$backend" in
    gguf)
      if command -v llama-server &>/dev/null; then
        llama-server -m "$model_path" --host "$host" --port "$port"
      else
        require_python
        "$PYTHON" -m llama_cpp.server --model "$model_path" --host "$host" --port "$port" 2>/dev/null || \
          err "Install: pip install 'llama-cpp-python[server]' --break-system-packages"
      fi ;;
    *) err "Serve for backend '$backend' not yet implemented."; info "For GGUF: ai backend gguf && ai serve" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  CONFIG
# ════════════════════════════════════════════════════════════════════
cmd_config() {
  if [[ $# -eq 0 ]]; then
    header "Configuration"
    label "active_model:"   "$ACTIVE_MODEL"
    label "active_backend:" "$ACTIVE_BACKEND"
    label "active_session:" "$ACTIVE_SESSION"
    label "active_persona:" "$ACTIVE_PERSONA"
    label "temperature:"    "$TEMPERATURE"
    label "max_tokens:"     "$MAX_TOKENS"
    label "stream:"         "$STREAM"
    label "verbose:"        "$VERBOSE"
    label "models_dir:"     "$MODELS_DIR"
    label "output_dir:"     "$AI_OUTPUT_DIR"
    return
  fi
  local key="${1,,}" value="$2"
  case "$key" in
    temperature) TEMPERATURE="$value" ;;
    max_tokens)  MAX_TOKENS="$value" ;;
    stream)      [[ "$value" == "on" || "$value" == "1" ]] && STREAM=1 || STREAM=0 ;;
    verbose)     [[ "$value" == "on" || "$value" == "1" ]] && VERBOSE=1 || VERBOSE=0 ;;
    models_dir)  MODELS_DIR="$value" ;;
    output_dir)  AI_OUTPUT_DIR="$value"; mkdir -p "$AI_OUTPUT_DIR" ;;
    *) err "Unknown key: $key"; info "Valid: temperature, max_tokens, stream, verbose, models_dir, output_dir"; exit 1 ;;
  esac
  save_config; ok "Set ${CYAN}$key${R} = ${BGREEN}$value${R}"
}

# ════════════════════════════════════════════════════════════════════
#  EMBED
# ════════════════════════════════════════════════════════════════════
cmd_embed() {
  require_jq; require_curl
  local text="" out_file="" args=()
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--out" ]] && { out_file="$2"; shift; shift; continue; }
    args+=("$1"); shift
  done
  text="${args[*]}"
  [[ -z "$text" ]] && { err "Usage: ai embed <text> [--out file.json]"; exit 1; }
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "Embeddings require OpenAI key."; exit 1; }
  local resp
  resp=$(curl -sf https://api.openai.com/v1/embeddings \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
    -d "{\"input\":$(jq -nc --arg t "$text" '$t'),\"model\":\"text-embedding-3-small\"}")
  if [[ -n "$out_file" ]]; then
    echo "$resp" > "$out_file"; ok "Saved: $out_file"
  else
    echo "$resp" | jq '.data[0].embedding[:5]'
    info "Showing 5 of $(echo "$resp" | jq '.data[0].embedding | length') dimensions"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  HISTORY
# ════════════════════════════════════════════════════════════════════
cmd_history() {
  local n=20 session="" search=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --n) n="${2:-20}"; shift ;; --session) session="${2:-}"; shift ;;
      --search) search="${2:-}"; shift ;; esac; shift
  done
  [[ ! -f "$LOG_FILE" ]] && { echo -e "${GRAY}No history.${R}"; return; }
  header "History"
  local cmd="cat \"$LOG_FILE\""
  [[ -n "$session" ]] && cmd="grep '\[session:$session\]' \"$LOG_FILE\""
  [[ -n "$search"  ]] && cmd="grep -i '$search' \"$LOG_FILE\""
  eval "$cmd" | tail -n "$n" | while IFS= read -r line; do
    if echo "$line" | grep -q "\[user\]"; then
      echo -e "${BGREEN}$line${R}"
    else
      echo -e "${GRAY}$line${R}"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════
#  MODEL INFO
# ════════════════════════════════════════════════════════════════════
cmd_model_info() {
  local model="${1:-$ACTIVE_MODEL}"
  [[ -z "$model" ]] && { err "No model. Use: ai model-info <n>"; exit 1; }
  header "Model Info: $model"
  local path; path=$(resolve_model_path)
  if [[ -f "$path" ]]; then
    label "File:" "$path"
    label "Size:" "$(du -sh "$path" | cut -f1)"
    label "Format:" "${path##*.}"
    if [[ "$path" == *.gguf ]] && [[ -n "$PYTHON" ]] && "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
      "$PYTHON" - <<PYEOF
try:
    from llama_cpp import Llama
    llm = Llama(model_path="$path", verbose=False, n_ctx=0)
    for k,v in llm.metadata.items():
        print(f"  {k:30s} {v}")
except Exception as e:
    print(f"  Metadata error: {e}")
PYEOF
    fi
  else
    label "Type:" "API model"
    label "Backend:" "$(detect_backend "$model")"
  fi
  echo ""
}

# ════════════════════════════════════════════════════════════════════
#  CONVERT
# ════════════════════════════════════════════════════════════════════
cmd_convert() {
  local model_path="" target="gguf" quant="Q4_K_M"
  while [[ $# -gt 0 ]]; do
    case "$1" in --to) target="$2"; shift ;; --quant) quant="$2"; shift ;; *) model_path="$1" ;; esac; shift
  done
  [[ -z "$model_path" ]] && { err "Usage: ai convert <path> [--to gguf] [--quant Q4_K_M]"; exit 1; }
  require_python
  local script="$HOME/llama.cpp/convert_hf_to_gguf.py"
  [[ ! -f "$script" ]] && { err "llama.cpp not found. Clone: git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp"; exit 1; }
  local out="${model_path%/}-${quant}.gguf"
  info "Converting to GGUF (${quant})..."
  "$PYTHON" "$script" "$model_path" --outfile "$out" --outtype "$quant"
  ok "Output: ${WHITE}$out${R}"
}

# ════════════════════════════════════════════════════════════════════
#  MAIN DISPATCHER
# ════════════════════════════════════════════════════════════════════
main() {
  local cmd="${1:-help}"; shift 2>/dev/null || true

  case "$cmd" in
    ask)
      local prompt="${1:-}"; shift 2>/dev/null || true
      local image="" extra_content=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          image) image="${2:-}"; shift ;;
          file)  extra_content=$(cat "${2:-/dev/null}" 2>/dev/null); shift ;;
        esac; shift
      done
      [[ -n "$extra_content" ]] && prompt="$prompt

$extra_content"
      dispatch_ask "$prompt" "$image" "0" ;;

    think)
      local prompt="${1:-}"; shift 2>/dev/null || true
      local image=""; [[ "${1:-}" == "image" ]] && { image="${2:-}"; shift 2; }
      dispatch_ask "$prompt" "$image" "1" ;;

    imagine)    cmd_imagine "$@" ;;
    chat)       cmd_chat "$@" ;;
    pipe)       cmd_pipe "$@" ;;
    embed)      cmd_embed "$@" ;;
    tts)        cmd_tts "$@" ;;
    transcribe) cmd_transcribe "$@" ;;
    summarize)  cmd_summarize "$@" ;;
    translate)  cmd_translate "$@" ;;
    code)       cmd_code "$@" ;;
    review)     cmd_review "$@" ;;
    explain)    cmd_explain "$@" ;;
    bench)      cmd_bench "$@" ;;
    serve)      cmd_serve "$@" ;;
    convert)    cmd_convert "$@" ;;

    model)
      ACTIVE_MODEL="${1:-}"
      ACTIVE_BACKEND="${2:-$(detect_backend "$ACTIVE_MODEL")}"
      save_config
      ok "Model: ${BGREEN}$ACTIVE_MODEL${R}  backend: ${CYAN}$ACTIVE_BACKEND${R}" ;;

    models)     cmd_models ;;
    model-info) cmd_model_info "$@" ;;

    backend)
      ACTIVE_BACKEND="${1:-}"; save_config
      ok "Backend: ${BGREEN}$ACTIVE_BACKEND${R}" ;;

    download)   cmd_download "$@" ;;
    keys)       cmd_keys ;;
    session)    cmd_session "$@" ;;
    persona)    cmd_persona "$@" ;;
    history)    cmd_history "$@" ;;

    clear-history)
      local s="${1:---all}"
      if [[ "$s" == "--all" ]]; then
        > "$LOG_FILE"; rm -f "$SESSIONS_DIR"/*.json; ok "All history cleared."
      else
        rm -f "$(session_file "$s")"; ok "Session cleared: $s"
      fi ;;

    config)       cmd_config "$@" ;;
    status)       cmd_status ;;
    install-deps) cmd_install_deps "$@" ;;

    version|-v|--version)
      echo -e "${B}ai.sh${R} ${BGREEN}v${VERSION}${R}" ;;

    -help|--help|help|"")
      show_help ;;

    *)
      err "Unknown command: ${B}$cmd${R}"
      info "Run ${YELLOW}ai -help${R} for all commands."
      exit 1 ;;
  esac
}

main "$@"
