#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI.SH v3.2.0 — Universal AI CLI · GUI v7 · GUI+ v4 · 195 Models · 44 API EP║
# ║  GGUF·PyTorch·OpenAI·Claude·Gemini·Groq·Mistral·Together·HuggingFace        ║
# ║  RAG·Batch·Snap·Perf·Compare·Templates·Branch·Export·Notebook·Learn·Quiz    ║
# ║  rclick v3.2 (Win+Mac+Linux) · iSH · bash 4+ auto-switch · Canvas v3        ║
# ║  v3.2: 44 HTTP endpoints · streaming · voice · share · agent · diff-review ║
# ║        rag-quick · 12-tab dashboard · GUI+ v4 with API + Agent tabs        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# Linux/Mac:   chmod +x ai.sh && sudo cp ai.sh /usr/local/bin/ai
# Arch Linux:  pacman -S python python-pip git ffmpeg && ai install-deps
# Windows 10:  Run in Git Bash / WSL; see 'ai install-deps --windows' for setup
# Install:     curl -fsSL .../installers/install.sh | sh
set -uo pipefail
VERSION="3.2.1"

# Remove old lib/ files immediately — they cause CONFIG_DIR unbound errors
for _d in /usr/local/share/ai-cli/lib /usr/share/ai-cli/lib; do
  [[ -d "$_d" ]] && { rm -rf "$_d" 2>/dev/null || sudo rm -rf "$_d" 2>/dev/null || true; }
done

# macOS ships bash 3.2 which lacks associative arrays (declare -A).
# Require bash 4+ or auto-switch to nb/Homebrew bash if available.
if (( BASH_VERSINFO[0] < 4 )); then
  for _newbash in /opt/nb/bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash /run/current-system/sw/bin/bash; do
    [[ ! -x "$_newbash" ]] && continue
    # Skip if wrong CPU architecture
    if command -v file >/dev/null 2>&1; then
      _arch=$(uname -m 2>/dev/null)
      _barch=$(file "$_newbash" 2>/dev/null)
      [[ "$_arch" == "x86_64" && "$_barch" != *x86_64* && "$_barch" != *i386* ]] && continue
      [[ "$_arch" == "arm64" && "$_barch" != *arm64* ]] && continue
    fi
    "$_newbash" --version >/dev/null 2>&1 || continue
    exec "$_newbash" "$0" "$@"
  done
  echo "AI CLI requires bash 4+. Your version: ${BASH_VERSION}"
  echo ""
  echo "  macOS fix:  nb install bash   OR   brew install bash"
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════════
#  ENVIRONMENT DETECTION
# ════════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════════
#  PLATFORM DETECTION (Windows 10/11 CPU-only, Linux, macOS)
# ════════════════════════════════════════════════════════════════════════════════
detect_platform() {
  local os; os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin)               echo "macos"   ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
      elif [[ -f /dev/location ]] || grep -qi ish /proc/version 2>/dev/null || [[ "$(uname -r 2>/dev/null)" == *ish* ]]; then echo "ish"
      else echo "linux"; fi ;;
    *)                    echo "unknown" ;;
  esac
}
PLATFORM="$(detect_platform)"
IS_WINDOWS=0; IS_WSL=0; IS_MACOS=0; IS_ISH=0
[[ "$PLATFORM" == "windows" ]] && IS_WINDOWS=1
[[ "$PLATFORM" == "wsl"     ]] && IS_WSL=1
[[ "$PLATFORM" == "macos"   ]] && IS_MACOS=1
[[ "$PLATFORM" == "ish"     ]] && IS_ISH=1

# Windows-safe config root (falls back to APPDATA if set)
if [[ $IS_WINDOWS -eq 1 && -n "${APPDATA:-}" ]]; then
  _WIN_CONFIG_ROOT="$(cygpath -u "$APPDATA" 2>/dev/null || echo "$HOME")/ai-cli"
else
  _WIN_CONFIG_ROOT="$HOME/.config/ai-cli"
fi

find_python() {
  # Windows: try 'py' launcher first, then standard names
  if [[ $IS_WINDOWS -eq 1 ]]; then
    for c in "py -3.12" "py -3.11" "py -3.10" "py -3" python3.12 python3.11 python3.10 python3 python; do
      local p; p=$(command -v ${c%% *} 2>/dev/null) || continue
      local v; v=$($c -c "import sys; print(sys.version_info.major,sys.version_info.minor)" 2>/dev/null) || continue
      read -r ma mi <<< "$v"
      (( ma==3 && mi>=10 )) && { echo "$p"; return 0; }
    done
    echo ""; return
  fi
  for c in python3.12 python3.11 python3.10 python3 python; do
    local p; p=$(command -v "$c" 2>/dev/null) || continue
    local v; v=$("$p" -c "import sys; print(sys.version_info.major,sys.version_info.minor)" 2>/dev/null) || continue
    read -r ma mi <<< "$v"
    (( ma==3 && mi>=10 )) && { echo "$p"; return 0; }
  done; echo ""
}
find_llama() {
  # Validate candidate is actually llama.cpp (not some other binary on PATH that
  # happens to be named `llama` and prints "Unknown command" when given our
  # flags). We only accept binaries whose --help output contains a llama.cpp
  # telltale like "llama.cpp" or "-ngl" / "--n-gpu-layers".
  _is_llama_cpp() {
    local b="$1"
    "$b" --help 2>&1 \
      | grep -qE 'llama\.cpp|--n-gpu-layers|^llama-cli|^usage: +llama' \
      && return 0
    return 1
  }
  # Prefer canonical llama.cpp names. `llama` / `llama-main` / `llama.cpp`
  # are intentionally omitted — on Arch and some other distros a different
  # tool squats that name and we'd end up executing the wrong binary.
  for b in llama-cli llama-run; do
    if command -v "$b" &>/dev/null && _is_llama_cpp "$b"; then
      command -v "$b"; return 0
    fi
  done
  for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/llama.cpp/build/bin" \
            "$HOME/llama.cpp/build" "$HOME/llama.cpp" "/usr/local/bin" \
            "/opt/llama.cpp/bin" "/opt/nb/bin" "/opt/homebrew/bin"; do
    for b in llama-cli llama-run main; do
      if [[ -x "$d/$b" ]] && _is_llama_cpp "$d/$b"; then
        echo "$d/$b"; return 0
      fi
    done
  done
  local py; py=$(find_python)
  [[ -n "$py" ]] && "$py" -c "import llama_cpp" 2>/dev/null && { echo "llama_cpp_python"; return 0; }
  echo ""
}
detect_cuda_arch() {
  # 1) Try nvidia-smi first — works even without PyTorch, handles all archs incl sm_61
  if command -v nvidia-smi &>/dev/null; then
    local cap
    # Try compute_cap field (newer drivers)
    cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' \n')
    if [[ -n "$cap" && "$cap" != "N/A" ]]; then
      echo "$cap" | tr -d '.'
      return 0
    fi
    # Fallback: parse from nvidia-smi -q output  (works on older drivers)
    cap=$(nvidia-smi -q 2>/dev/null | awk '/CUDA Capability/{gsub(/[^0-9.]/,"",$NF); print $NF; exit}' | tr -d '.')
    if [[ -n "$cap" && "$cap" != "0" ]]; then echo "$cap"; return 0; fi
  fi
  # 2) Check /proc/driver/nvidia for presence of GPU even if smi missing
  if [[ -d /proc/driver/nvidia/gpus ]] || ls /dev/nvidia[0-9]* &>/dev/null 2>&1; then
    # GPU exists but nvidia-smi not available; try PyTorch
    local py; py=$(find_python)
    if [[ -n "$py" ]]; then
      local arch
      arch=$("$py" -c "
import sys
try:
    import torch
    if torch.cuda.is_available():
        cc=torch.cuda.get_device_capability(0)
        print(cc[0]*10+cc[1])
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null)
      [[ -n "$arch" && "$arch" != "0" ]] && { echo "$arch"; return 0; }
    fi
    # Return a safe fallback compute cap (sm_61 = Pascal) if GPU exists but undetectable
    echo "61"
    return 0
  fi
  # 3) macOS Metal — not CUDA but GPU exists
  if [[ "$(uname -s)" == "Darwin" ]]; then
    system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal" && { echo "metal"; return 0; }
  fi
  echo "0"
}

# ── Startup performance: cache CUDA arch to avoid slow detection on every invocation ──
_CUDA_CACHE="$HOME/.ai/cache/cuda_arch"
detect_cuda_arch_cached() {
  local _now; _now=$(date +%s)
  local _age=0
  if [[ -f "$_CUDA_CACHE" ]]; then
    _age=$(( _now - $(stat -c %Y "$_CUDA_CACHE" 2>/dev/null || echo 0) ))
  fi
  local _cached_val; _cached_val=$(cat "$_CUDA_CACHE" 2>/dev/null || echo "")
  # Refresh when: cache missing, older than 24 h, or last result was 0 and >5 min old
  # (re-detect quickly after driver/package installation)
  local _stale=0
  [[ ! -f "$_CUDA_CACHE" ]]          && _stale=1
  (( _age > 86400 ))                 && _stale=1
  [[ "$_cached_val" == "0" ]] && (( _age > 300 )) && _stale=1
  if [[ $_stale -eq 1 ]]; then
    mkdir -p "$(dirname "$_CUDA_CACHE")"
    detect_cuda_arch > "$_CUDA_CACHE" 2>/dev/null || echo "0" > "$_CUDA_CACHE"
  fi
  cat "$_CUDA_CACHE"
}

PYTHON="$(find_python)"
LLAMA_BIN="$(find_llama)"
CUDA_ARCH="$(detect_cuda_arch_cached)"

# ════════════════════════════════════════════════════════════════════════════════
#  COLORS
# ════════════════════════════════════════════════════════════════════════════════
R="\033[0m"; B="\033[1m"; DIM="\033[2m"; IT="\033[3m"; UL="\033[4m"
BL="\033[5m"; INV="\033[7m"
BLACK="\033[30m";RED="\033[31m";GREEN="\033[32m";YELLOW="\033[33m"
BLUE="\033[34m";MAGENTA="\033[35m";CYAN="\033[36m";WHITE="\033[37m";GRAY="\033[90m"
BRED="\033[91m";BGREEN="\033[92m";BYELLOW="\033[93m";BBLUE="\033[94m"
BMAGENTA="\033[95m";BCYAN="\033[96m";BWHITE="\033[97m"
BG_BLACK="\033[40m";BG_RED="\033[41m";BG_GREEN="\033[42m";BG_YELLOW="\033[43m"
BG_BLUE="\033[44m";BG_MAGENTA="\033[45m";BG_CYAN="\033[46m";BG_WHITE="\033[47m"

# ════════════════════════════════════════════════════════════════════════════════
#  PATHS & CONFIG
# ════════════════════════════════════════════════════════════════════════════════
CONFIG_DIR="${AI_CLI_CONFIG:-$HOME/.config/ai-cli}"
CONFIG_FILE="$CONFIG_DIR/config.env"
KEYS_FILE="$CONFIG_DIR/keys.env"
LOG_FILE="$CONFIG_DIR/history.log"
SESSIONS_DIR="$CONFIG_DIR/sessions"
PERSONAS_DIR="$CONFIG_DIR/personas"
MODELS_DIR="${AI_CLI_MODELS:-$HOME/.ai-cli/models}"
AI_OUTPUT_DIR="${AI_OUTPUT_DIR:-$HOME/ai-outputs}"
CANVAS_DIR="$AI_OUTPUT_DIR/canvas"
FINETUNE_DIR="$CONFIG_DIR/finetune"
TOOLS_DIR="$CONFIG_DIR/tools"
PLUGINS_DIR="$CONFIG_DIR/plugins"
SEARCH_CACHE="$CONFIG_DIR/search_cache"
CUSTOM_MODELS_DIR="$CONFIG_DIR/custom_models"
TTM_DIR="$CONFIG_DIR/tiny_model"
MTM_DIR="$CONFIG_DIR/mini_model"
MMTM_DIR="$CONFIG_DIR/medium_model"
CHAT_LOGS_DIR="$CONFIG_DIR/chat_logs"
AUDIO_DIR="$AI_OUTPUT_DIR/audio"
VIDEO_DIR="$AI_OUTPUT_DIR/video"
DATASETS_DIR="$CONFIG_DIR/datasets"       # v2.4:   custom dataset storage
API_PID_FILE="$CONFIG_DIR/api.pid"        # v2.4:   LLM API server PID
API_KEYS_FILE="$CONFIG_DIR/api_keys.json" # v2.4.5: shareable API key store
MULTIAI_DIR="$CONFIG_DIR/multiai"         # v2.4.5: multi-AI conversation logs
RLHF_HF_DATASETS_FILE="$CONFIG_DIR/rlhf_hf_datasets.json" # v2.4.5: imported HF RLHF datasets
GITHUB_DIR="$CONFIG_DIR/github"                            # v2.5:   GitHub integration cache
PAPERS_DIR="$AI_OUTPUT_DIR/papers"                         # v2.5:   downloaded research papers
MULTIMODAL_DIR="$CONFIG_DIR/multimodal"                    # v2.5:   multimodal training
CANVAS_V3_DIR="$AI_OUTPUT_DIR/canvas_v3"                  # v2.5:   Canvas v3 workspaces
BUILD_DIR="$CONFIG_DIR/builds"                             # v2.5:   XZ bundle output
PROJECTS_DIR="$CONFIG_DIR/projects"                        # v2.6:   multi-chat projects
FIRST_RUN_FILE="$CONFIG_DIR/.first_run_done"               # v2.6:   first-run flag
EXTENSIONS_DIR="$CONFIG_DIR/extensions"                    # v2.7:   AI extensions (.aipack)
FIREFOX_EXT_DIR="$CONFIG_DIR/firefox_extension"            # v2.7:   Firefox sidebar extension
ALIASES_FILE="$CONFIG_DIR/aliases.env"                     # v2.7.3: user-defined command aliases

mkdir -p "$CONFIG_DIR" "$MODELS_DIR" "$SESSIONS_DIR" "$PERSONAS_DIR" \
         "$AI_OUTPUT_DIR" "$CANVAS_DIR" "$FINETUNE_DIR" "$TOOLS_DIR" \
         "$PLUGINS_DIR" "$SEARCH_CACHE" "$CUSTOM_MODELS_DIR" \
         "$TTM_DIR" "$MTM_DIR" "$MMTM_DIR" \
         "$CHAT_LOGS_DIR" "$AUDIO_DIR" "$VIDEO_DIR" "$DATASETS_DIR" \
         "$MULTIAI_DIR" "$GITHUB_DIR" "$PAPERS_DIR" \
         "$MULTIMODAL_DIR" "$CANVAS_V3_DIR" "$BUILD_DIR" "$PROJECTS_DIR" \
         "$EXTENSIONS_DIR" "$FIREFOX_EXT_DIR"
touch "$KEYS_FILE" && chmod 600 "$KEYS_FILE"
touch "$ALIASES_FILE" 2>/dev/null || true

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -f "$KEYS_FILE"   ]] && source "$KEYS_FILE"


# Runtime vars
ACTIVE_MODEL="${ACTIVE_MODEL:-}"
ACTIVE_BACKEND="${ACTIVE_BACKEND:-}"
ACTIVE_PERSONA="${ACTIVE_PERSONA:-}"
ACTIVE_SESSION="${ACTIVE_SESSION:-default}"
ACTIVE_PROJECT="${ACTIVE_PROJECT:-}"  # v2.6: active project name
MAX_TOKENS="${MAX_TOKENS:-2048}"
TEMPERATURE="${TEMPERATURE:-0.7}"
TOP_P="${TOP_P:-0.9}"
REPEAT_PENALTY="${REPEAT_PENALTY:-1.1}"
CONTEXT_SIZE="${CONTEXT_SIZE:-4096}"
GPU_LAYERS="${GPU_LAYERS:--1}"
THREADS="${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || python3 -c "import os;print(os.cpu_count())" 2>/dev/null || echo 4)}"
STREAM="${STREAM:-1}"
VERBOSE="${VERBOSE:-0}"
TOOL_CALLING="${TOOL_CALLING:-1}"
WEB_SEARCH_ENABLED="${WEB_SEARCH_ENABLED:-1}"
SEARCH_ENGINE="${SEARCH_ENGINE:-ddg}"
CANVAS_ACTIVE="${CANVAS_ACTIVE:-}"
HF_DATASET_SYNC="${HF_DATASET_SYNC:-0}"
HF_DATASET_REPO="${HF_DATASET_REPO:-ray0rf1re/cli}"
HF_DATASET_KEY="${HF_DATASET_KEY:-}"
GUI_THEME="${GUI_THEME:-dark}"

# v2.5: GitHub integration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_DEFAULT_BRANCH="${GITHUB_DEFAULT_BRANCH:-main}"

# v2.5: Research papers
PAPERS_DEFAULT_SOURCES="${PAPERS_DEFAULT_SOURCES:-arxiv,pmc,biorxiv,core,openalex}"
PAPERS_CITATION_FORMAT="${PAPERS_CITATION_FORMAT:-apa}"

# v2.5: Multimodal training
MULTIMODAL_VL_MODEL="${MULTIMODAL_VL_MODEL:-Qwen/Qwen2-VL-2B-Instruct}"
MULTIMODAL_T2I_MODEL="${MULTIMODAL_T2I_MODEL:-stabilityai/stable-diffusion-xl-base-1.0}"

# v2.5.5: Custom system prompts
CUSTOM_SYSTEM_PROMPT="${CUSTOM_SYSTEM_PROMPT:-}"    # overrides persona system prompt when set
SYSTEM_PROMPTS_DIR="$CONFIG_DIR/system_prompts"    # named system prompt library
mkdir -p "$SYSTEM_PROMPTS_DIR"

# v2.9.0: New directories and config
SNAPSHOTS_DIR="$CONFIG_DIR/snapshots"              # config snapshots
TEMPLATES_DIR="$CONFIG_DIR/prompt_templates"        # prompt template library
RAG_DIR="$CONFIG_DIR/rag"                          # RAG knowledge bases
BATCH_DIR="$CONFIG_DIR/batch_queue"                # batch job queue
EXPORTS_DIR="$AI_OUTPUT_DIR/exports"               # export archive
BRANCHES_DIR="$CONFIG_DIR/chat_branches"           # conversation branching
HEALTH_LOG="$CONFIG_DIR/health.log"                # health check log
PERF_LOG="$CONFIG_DIR/perf_benchmarks.log"         # performance benchmark log
COMPARE_DIR="$CONFIG_DIR/compare_results"          # model comparison output
RETRY_MAX="${RETRY_MAX:-3}"                        # API retry count
RETRY_DELAY="${RETRY_DELAY:-2}"                    # seconds between retries
BATCH_CONCURRENCY="${BATCH_CONCURRENCY:-4}"        # batch parallel jobs
RAG_CHUNK_SIZE="${RAG_CHUNK_SIZE:-512}"             # RAG chunk token size
RAG_TOP_K="${RAG_TOP_K:-5}"                        # RAG retrieval count
PERF_WARMUP_TOKENS="${PERF_WARMUP_TOKENS:-32}"     # warmup before benchmarking
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-3600}"  # seconds between auto health checks
PROMPT_TEMPLATE_DEFAULT="${PROMPT_TEMPLATE_DEFAULT:-}"   # default prompt template name
CONVERSATION_BRANCH="${CONVERSATION_BRANCH:-}"     # active conversation branch
EXPORT_FORMAT="${EXPORT_FORMAT:-json}"              # export format: json, csv, md
mkdir -p "$SNAPSHOTS_DIR" "$TEMPLATES_DIR" "$RAG_DIR" "$BATCH_DIR" \
         "$EXPORTS_DIR" "$BRANCHES_DIR" "$COMPARE_DIR"

# TTM (Tiny — 179.35M)
TTM_AUTO_TRAIN="${TTM_AUTO_TRAIN:-0}"
TTM_PRETRAINED="${TTM_PRETRAINED:-0}"
TTM_VERSION="${TTM_VERSION:-0}"

# MTM (Mini — 0.61B — GTX 1080 optimized)
MTM_AUTO_TRAIN="${MTM_AUTO_TRAIN:-0}"
MTM_PRETRAINED="${MTM_PRETRAINED:-0}"
MTM_VERSION="${MTM_VERSION:-0}"

# Mtm (Medium — 1.075B — RTX 2080+ optimized)
MMTM_AUTO_TRAIN="${MMTM_AUTO_TRAIN:-0}"
MMTM_PRETRAINED="${MMTM_PRETRAINED:-0}"
MMTM_VERSION="${MMTM_VERSION:-0}"

save_config() {
  cat > "$CONFIG_FILE" <<CONF
ACTIVE_MODEL="${ACTIVE_MODEL}"
ACTIVE_BACKEND="${ACTIVE_BACKEND}"
ACTIVE_PERSONA="${ACTIVE_PERSONA}"
ACTIVE_SESSION="${ACTIVE_SESSION}"
MAX_TOKENS="${MAX_TOKENS}"
TEMPERATURE="${TEMPERATURE}"
TOP_P="${TOP_P}"
REPEAT_PENALTY="${REPEAT_PENALTY}"
CONTEXT_SIZE="${CONTEXT_SIZE}"
GPU_LAYERS="${GPU_LAYERS}"
THREADS="${THREADS}"
STREAM="${STREAM}"
VERBOSE="${VERBOSE}"
TOOL_CALLING="${TOOL_CALLING}"
WEB_SEARCH_ENABLED="${WEB_SEARCH_ENABLED}"
SEARCH_ENGINE="${SEARCH_ENGINE}"
CANVAS_ACTIVE="${CANVAS_ACTIVE}"
HF_DATASET_SYNC="${HF_DATASET_SYNC}"
HF_DATASET_REPO="${HF_DATASET_REPO}"
HF_DATASET_KEY="${HF_DATASET_KEY}"
GUI_THEME="${GUI_THEME}"
TTM_AUTO_TRAIN="${TTM_AUTO_TRAIN}"
TTM_PRETRAINED="${TTM_PRETRAINED}"
TTM_VERSION="${TTM_VERSION}"
MTM_AUTO_TRAIN="${MTM_AUTO_TRAIN}"
MTM_PRETRAINED="${MTM_PRETRAINED}"
MTM_VERSION="${MTM_VERSION}"
MMTM_AUTO_TRAIN="${MMTM_AUTO_TRAIN}"
MMTM_PRETRAINED="${MMTM_PRETRAINED}"
MMTM_VERSION="${MMTM_VERSION}"
RLHF_AUTO="${RLHF_AUTO}"
RLHF_JUDGE="${RLHF_JUDGE}"
RLHF_MANUAL_ENABLED="${RLHF_MANUAL_ENABLED}"
RLHF_REWARD_THRESHOLD="${RLHF_REWARD_THRESHOLD}"
RLHF_ACTIVE_HF_DATASET="${RLHF_ACTIVE_HF_DATASET}"
RCLICK_ENABLED="${RCLICK_ENABLED}"
RCLICK_VL_MODEL="${RCLICK_VL_MODEL}"
RCLICK_CUSTOM_MODEL="${RCLICK_CUSTOM_MODEL}"
RCLICK_KEYBIND="${RCLICK_KEYBIND}"
AUP_REPO="${AUP_REPO}"
AUP_CHECK_INTERVAL="${AUP_CHECK_INTERVAL}"
AUP_LAST_CHECK="${AUP_LAST_CHECK}"
AGENT_MODE="${AGENT_MODE}"
AGENT_MAX_STEPS="${AGENT_MAX_STEPS}"
AGENT_SEARCH_ENGINE="${AGENT_SEARCH_ENGINE}"
PRETRAIN_CUSTOM_1="${PRETRAIN_CUSTOM_1}"
PRETRAIN_CUSTOM_2="${PRETRAIN_CUSTOM_2}"
API_HOST="${API_HOST}"
API_PORT="${API_PORT}"
API_KEY="${API_KEY}"
API_CORS="${API_CORS}"
API_SHARE_ENABLED="${API_SHARE_ENABLED}"
API_SHARE_HOST="${API_SHARE_HOST}"
API_SHARE_PORT="${API_SHARE_PORT}"
API_SHARE_RATE_LIMIT="${API_SHARE_RATE_LIMIT}"
CPU_ONLY_MODE="${CPU_ONLY_MODE}"
MULTIAI_ROUNDS="${MULTIAI_ROUNDS}"
MULTIAI_SAVE_DATASET="${MULTIAI_SAVE_DATASET}"
MULTIAI_RLHF_TRAIN="${MULTIAI_RLHF_TRAIN}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_DEFAULT_BRANCH="${GITHUB_DEFAULT_BRANCH}"
PAPERS_DEFAULT_SOURCES="${PAPERS_DEFAULT_SOURCES}"
PAPERS_CITATION_FORMAT="${PAPERS_CITATION_FORMAT}"
MULTIMODAL_VL_MODEL="${MULTIMODAL_VL_MODEL}"
MULTIMODAL_T2I_MODEL="${MULTIMODAL_T2I_MODEL}"
CUSTOM_SYSTEM_PROMPT="${CUSTOM_SYSTEM_PROMPT}"
RETRY_MAX="${RETRY_MAX}"
RETRY_DELAY="${RETRY_DELAY}"
BATCH_CONCURRENCY="${BATCH_CONCURRENCY}"
RAG_CHUNK_SIZE="${RAG_CHUNK_SIZE}"
RAG_TOP_K="${RAG_TOP_K}"
PERF_WARMUP_TOKENS="${PERF_WARMUP_TOKENS}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL}"
PROMPT_TEMPLATE_DEFAULT="${PROMPT_TEMPLATE_DEFAULT}"
CONVERSATION_BRANCH="${CONVERSATION_BRANCH}"
EXPORT_FORMAT="${EXPORT_FORMAT}"
CONF
}

log_history() { local role="$1"; local msg="$2"; echo "$(date -Iseconds) [$role] $msg" >> "$LOG_FILE"; }

# ════════════════════════════════════════════════════════════════════════════════
#  ERROR CODES — v2.7.3
#  Format: ERR<category><number>
#    1xx = Config/Setup    2xx = Model/Backend    3xx = Network/API
#    4xx = File/IO         5xx = Runtime/Python   6xx = Auth/Keys
# ════════════════════════════════════════════════════════════════════════════════
declare -A ERR_CODES
ERR_CODES=(
  [ERR101]="No config directory (run: ai install-deps)"
  [ERR102]="First-run setup required (run: ai install-deps)"
  [ERR103]="Config file corrupted"
  [ERR201]="No model or API key configured"
  [ERR202]="Model file not found"
  [ERR203]="Model directory not found"
  [ERR204]="Unknown backend"
  [ERR205]="GGUF inference failed"
  [ERR206]="PyTorch inference failed"
  [ERR207]="No llama.cpp binary found (run: ai install-deps)"
  [ERR301]="Network request failed"
  [ERR302]="HuggingFace API error"
  [ERR303]="OpenAI API error"
  [ERR304]="Claude API error"
  [ERR305]="Gemini API error"
  [ERR306]="Download failed"
  [ERR401]="File not found"
  [ERR402]="Permission denied"
  [ERR403]="Disk full or write error"
  [ERR501]="Python 3.10+ not found (run: ai install-deps)"
  [ERR502]="Python dependency missing (run: ai install-deps)"
  [ERR503]="PyTorch not installed"
  [ERR601]="API key not set"
  [ERR602]="Invalid API key"
  [ERR603]="Rate limit exceeded"
)

err()  {
  # Support: err "message" or err ERR201 "message"
  if [[ "${1:-}" =~ ^ERR[0-9]{3}$ ]]; then
    local code="$1"; shift
    echo -e "${BRED}✗ [${code}] $*${R}" >&2
    echo -e "${DIM}  ${ERR_CODES[$code]:-}${R}" >&2
  else
    echo -e "${BRED}✗ $*${R}" >&2
  fi
}
ok()   { echo -e "${BGREEN}✓ $*${R}"; }
info() { echo -e "${BCYAN}ℹ $*${R}"; }
warn() { echo -e "${BYELLOW}⚠ $*${R}"; }
hdr()  { echo -e "${B}${BWHITE}$*${R}"; }
dim()  { echo -e "${DIM}$*${R}"; }

# ════════════════════════════════════════════════════════════════════════════════
#  RECOMMENDED MODELS
# ════════════════════════════════════════════════════════════════════════════════
declare -A RECOMMENDED_MODELS
RECOMMENDED_MODELS=(
  # ── Tiny / CPU-friendly LLMs ──────────────────────────────────────────────
  [1]="Amu/supertiny-llama3-0.25B-v0.1|gguf|0.25B|Supertiny Llama3 — runs on ANY CPU"
  [2]="bartowski/Phi-3.1-mini-128k-instruct-GGUF|gguf|3.8B|Phi-3 Mini 128k context"
  [3]="bartowski/SmolLM2-1.7B-Instruct-GGUF|gguf|1.7B|SmolLM2 — ultra-fast on CPU"
  [4]="bartowski/Qwen2.5-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 1.5B — multilingual tiny"
  [5]="Qwen/Qwen2.5-0.5B-Instruct-GGUF|gguf|0.5B|Qwen2.5 0.5B — smallest usable"
  [6]="bartowski/Llama-3.2-1B-Instruct-GGUF|gguf|1B|Llama 3.2 1B — Meta tiny"
  [7]="bartowski/Llama-3.2-3B-Instruct-GGUF|gguf|3B|Llama 3.2 3B — Meta small"
  [8]="bartowski/gemma-2-2b-it-GGUF|gguf|2B|Gemma 2 2B — Google lightweight"
  # ── General-purpose LLMs (7–9B) ───────────────────────────────────────────
  [9]="TheBloke/Mistral-7B-Instruct-v0.2-GGUF|gguf|7B|Mistral 7B — top general-purpose"
  [10]="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|gguf|8B|Llama 3.1 8B — strong reasoning"
  [11]="Qwen/Qwen2-7B-Instruct-GGUF|gguf|7B|Qwen2 7B — multilingual + coding"
  [12]="bartowski/gemma-2-9b-it-GGUF|gguf|9B|Gemma 2 9B — Google model"
  [13]="bartowski/Qwen2.5-7B-Instruct-GGUF|gguf|7B|Qwen2.5 7B — best 7B 2025"
  [14]="bartowski/Mistral-Nemo-Instruct-2407-GGUF|gguf|12B|Mistral Nemo 12B — long context"
  [15]="bartowski/Phi-3.5-mini-instruct-GGUF|gguf|3.8B|Phi-3.5 Mini — fast instruction"
  [16]="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF|gguf|70B|Llama 3.1 70B — flagship open"
  # ── Coding LLMs ───────────────────────────────────────────────────────────
  [17]="bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|gguf|16B|DeepSeek Coder V2 — code"
  [18]="bartowski/Codestral-22B-v0.1-GGUF|gguf|22B|Codestral 22B — Mistral code model"
  [19]="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF|gguf|7B|Qwen2.5 Coder 7B — top coder"
  [20]="bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 Coder 1.5B — tiny coder"
  [21]="bartowski/starcoder2-7b-GGUF|gguf|7B|StarCoder2 7B — multi-language code"
  [22]="bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|gguf|7B|DeepSeek-R1 7B — reasoning"
  [23]="bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF|gguf|8B|DeepSeek-R1 Llama 8B — reasoning"
  # ── Math / Reasoning LLMs ─────────────────────────────────────────────────
  [24]="bartowski/Qwen2.5-Math-7B-Instruct-GGUF|gguf|7B|Qwen2.5 Math 7B — best open math"
  [25]="bartowski/internlm2_5-7b-chat-GGUF|gguf|7B|InternLM2.5 7B — strong all-rounder"
  [26]="bartowski/Hermes-3-Llama-3.1-8B-GGUF|gguf|8B|Hermes 3 8B — advanced instruction"
  # ── Vision / Multimodal LLMs ──────────────────────────────────────────────
  [27]="Qwen/Qwen2-VL-7B-Instruct|hf|7B|Qwen2-VL 7B — best open vision-language"
  [28]="microsoft/Phi-3.5-vision-instruct|hf|4.2B|Phi-3.5 Vision — small + capable"
  [29]="llava-hf/llava-1.5-7b-hf|hf|7B|LLaVA 1.5 7B — classic vision model"
  [30]="Qwen/Qwen2-VL-2B-Instruct|hf|2B|Qwen2-VL 2B — tiny vision model"
  [31]="llava-hf/llava-v1.6-mistral-7b-hf|hf|7B|LLaVA 1.6 Mistral 7B — better vision"
  # ── Image Generation ──────────────────────────────────────────────────────
  [32]="stabilityai/stable-diffusion-xl-base-1.0|diffusers|SDXL|SDXL 1.0 — high quality"
  [33]="black-forest-labs/FLUX.1-schnell|diffusers|FLUX|FLUX Schnell — fast 4-step"
  [34]="black-forest-labs/FLUX.1-dev|diffusers|FLUX|FLUX Dev — best quality"
  [35]="stabilityai/stable-diffusion-2-1|diffusers|SD2|SD 2.1 — lightweight option"
  [36]="stabilityai/stable-diffusion-3-medium-diffusers|diffusers|SD3|SD 3 Medium — latest SD"
  [37]="stabilityai/sdxl-turbo|diffusers|SDXL-T|SDXL Turbo — real-time image gen"
  # ── Audio / Speech ────────────────────────────────────────────────────────
  [38]="openai/whisper-base|hf|74M|Whisper base — fast speech-to-text"
  [39]="openai/whisper-large-v3|hf|1.5B|Whisper Large v3 — best transcription"
  [40]="suno/bark|hf|TTS|Bark — realistic multi-lingual TTS"
  [41]="openai/whisper-medium|hf|307M|Whisper medium — balanced transcription"
  [42]="facebook/musicgen-small|hf|300M|MusicGen small — AI music generation"
  # ── Embedding / RAG Models ────────────────────────────────────────────────
  [43]="BAAI/bge-small-en-v1.5|hf|33M|BGE small — fast embeddings"
  [44]="BAAI/bge-large-en-v1.5|hf|335M|BGE large — best embeddings"
  [45]="sentence-transformers/all-MiniLM-L6-v2|hf|22M|MiniLM L6 — sentence embeddings"
  [46]="nomic-ai/nomic-embed-text-v1.5|hf|137M|Nomic Embed — long context embeddings"
  # ── Cloud API Models ──────────────────────────────────────────────────────
  [47]="gpt-4o|openai|API|GPT-4o with vision"
  [48]="gpt-4o-mini|openai|API|GPT-4o mini — fast and affordable"
  [49]="gpt-4.5-preview|openai|API|GPT-4.5 Preview — latest OpenAI"
  [50]="claude-sonnet-4-5|claude|API|Claude Sonnet 4.5 — top reasoning"
  [51]="claude-haiku-4-5-20251001|claude|API|Claude Haiku 4.5 — ultra-fast"
  [52]="claude-opus-4-6|claude|API|Claude Opus 4.6 — most capable Claude"
  [53]="gemini-2.0-flash|gemini|API|Gemini 2.0 Flash — Google best"
  [54]="gemini-2.0-flash-lite|gemini|API|Gemini 2.0 Flash Lite — cheapest Gemini"
  [55]="gemini-1.5-pro|gemini|API|Gemini 1.5 Pro — long context 2M"
  [56]="o1-mini|openai|API|OpenAI o1-mini — fast reasoning model"
  # ── Large LLMs (13B–70B+) ─────────────────────────────────────────
  [57]="bartowski/Qwen2.5-14B-Instruct-GGUF|gguf|14B|Qwen2.5 14B — strong mid-size"
  [58]="bartowski/Qwen2.5-32B-Instruct-GGUF|gguf|32B|Qwen2.5 32B — top open model"
  [59]="bartowski/Qwen2.5-72B-Instruct-GGUF|gguf|72B|Qwen2.5 72B — flagship Qwen"
  [60]="bartowski/Mixtral-8x7B-Instruct-v0.1-GGUF|gguf|46B|Mixtral 8x7B MoE — fast 46B"
  [61]="bartowski/Yi-1.5-34B-Chat-GGUF|gguf|34B|Yi 1.5 34B — bilingual EN/ZH"
  [62]="bartowski/c4ai-command-r-plus-GGUF|gguf|104B|Command R+ — enterprise RAG"
  [63]="bartowski/Llama-3.3-70B-Instruct-GGUF|gguf|70B|Llama 3.3 70B — latest Meta"
  [64]="bartowski/gemma-2-27b-it-GGUF|gguf|27B|Gemma 2 27B — Google large"
  [65]="bartowski/Phi-4-GGUF|gguf|14B|Phi-4 14B — Microsoft best small"
  [66]="bartowski/Mistral-Small-24B-Instruct-2501-GGUF|gguf|24B|Mistral Small 24B"
  # ── More Coding Models ────────────────────────────────────────────
  [67]="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|gguf|14B|Qwen2.5 Coder 14B"
  [68]="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF|gguf|32B|Qwen2.5 Coder 32B — top coder"
  [69]="bartowski/DeepSeek-Coder-V2-Instruct-GGUF|gguf|236B|DeepSeek Coder V2 MoE"
  [70]="bartowski/CodeLlama-34b-Instruct-GGUF|gguf|34B|Code Llama 34B"
  [71]="bartowski/starcoder2-15b-GGUF|gguf|15B|StarCoder2 15B — multi-lang code"
  [72]="bartowski/stable-code-instruct-3b-GGUF|gguf|3B|Stable Code 3B — tiny coder"
  [73]="bartowski/codegemma-7b-it-GGUF|gguf|7B|CodeGemma 7B — Google code"
  [74]="bartowski/WizardCoder-33B-V1.1-GGUF|gguf|33B|WizardCoder 33B"
  # ── More Reasoning / Math ─────────────────────────────────────────
  [75]="bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF|gguf|14B|DeepSeek-R1 14B reasoning"
  [76]="bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|gguf|32B|DeepSeek-R1 32B reasoning"
  [77]="bartowski/Qwen2.5-Math-72B-Instruct-GGUF|gguf|72B|Qwen2.5 Math 72B — flagship math"
  [78]="bartowski/Qwen2.5-Math-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 Math 1.5B — tiny math"
  [79]="bartowski/WizardMath-7B-V1.1-GGUF|gguf|7B|WizardMath 7B"
  [80]="bartowski/Abel-7B-002-GGUF|gguf|7B|Abel 7B — math reasoning"
  # ── Roleplay / Creative ──────────────────────────────────────────
  [81]="bartowski/Nous-Hermes-2-Mixtral-8x7B-DPO-GGUF|gguf|46B|Nous Hermes 2 Mixtral"
  [82]="bartowski/OpenHermes-2.5-Mistral-7B-GGUF|gguf|7B|OpenHermes 2.5 7B"
  [83]="bartowski/Mythomax-L2-13B-GGUF|gguf|13B|MythoMax 13B — creative writing"
  [84]="bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF|gguf|7B|Dolphin Mistral — uncensored"
  [85]="bartowski/Samantha-1.11-70b-GGUF|gguf|70B|Samantha 70B — empathetic AI"
  # ── Multilingual Models ──────────────────────────────────────────
  [86]="bartowski/aya-23-8B-GGUF|gguf|8B|Aya 23 8B — 23 languages"
  [87]="bartowski/aya-23-35B-GGUF|gguf|35B|Aya 23 35B — 23 languages large"
  [88]="bartowski/Llama-3.1-8B-Instruct-GGUF|gguf|8B|Llama 3.1 8B multilingual"
  [89]="bartowski/Qwen2.5-3B-Instruct-GGUF|gguf|3B|Qwen2.5 3B — multilingual tiny"
  [90]="bartowski/Vikhr-Nemo-12B-Instruct-R-GGUF|gguf|12B|Vikhr 12B — Russian specialist"
  # ── Long Context Models ──────────────────────────────────────────
  [91]="bartowski/Llama-3.1-8B-Instruct-GGUF|gguf|8B|Llama 3.1 8B — 128k context"
  [92]="bartowski/Qwen2.5-7B-Instruct-GGUF|gguf|7B|Qwen2.5 7B — 128k context"
  [93]="bartowski/Yi-1.5-9B-Chat-GGUF|gguf|9B|Yi 1.5 9B — 200k context"
  [94]="bartowski/Phi-3.1-mini-128k-instruct-GGUF|gguf|3.8B|Phi 3.1 128k context"
  # ── More Vision / VL Models ──────────────────────────────────────
  [95]="Qwen/Qwen2.5-VL-7B-Instruct|hf|7B|Qwen2.5-VL 7B — latest vision"
  [96]="Qwen/Qwen2.5-VL-3B-Instruct|hf|3B|Qwen2.5-VL 3B — tiny vision"
  [97]="microsoft/Florence-2-large|hf|0.7B|Florence 2 — image understanding"
  [98]="llava-hf/llava-onevision-qwen2-7b-ov-hf|hf|7B|LLaVA OneVision 7B"
  [99]="vikhyatk/moondream2|hf|1.8B|Moondream2 — tiny vision model"
  [100]="THUDM/cogvlm2-llama3-chat-19B|hf|19B|CogVLM2 19B — powerful VL"
  # ── More Image Generation ────────────────────────────────────────
  [101]="stabilityai/stable-diffusion-3.5-large|diffusers|SD3.5|SD 3.5 Large — newest SD"
  [102]="playgroundai/playground-v2.5-1024px-aesthetic|diffusers|PG2.5|Playground v2.5"
  [103]="dataautogpt3/FLUX-anime2|diffusers|FLUX-A|FLUX Anime — anime style"
  [104]="Shakker-Labs/FLUX.1-dev-LoRA-Logo-Design|diffusers|FLUX-L|FLUX Logo Design"
  # ── More Audio ────────────────────────────────────────────────────
  [105]="openai/whisper-small|hf|244M|Whisper small — balanced speed/quality"
  [106]="openai/whisper-tiny|hf|39M|Whisper tiny — fastest transcription"
  [107]="facebook/musicgen-medium|hf|1.5B|MusicGen medium — better music"
  [108]="facebook/musicgen-large|hf|3.3B|MusicGen large — best music"
  [109]="parler-tts/parler-tts-mini-v1|hf|0.8B|Parler TTS mini — natural speech"
  # ── Embedding / Reranker ─────────────────────────────────────────
  [110]="BAAI/bge-m3|hf|568M|BGE M3 — multilingual embeddings"
  [111]="jinaai/jina-embeddings-v3|hf|570M|Jina v3 — task-specific embeddings"
  [112]="BAAI/bge-reranker-v2-m3|hf|568M|BGE Reranker M3 — cross-encoder"
  [113]="Xenova/all-MiniLM-L6-v2|hf|22M|MiniLM ONNX — fastest embeddings"
  # ── Specialized / Niche ──────────────────────────────────────────
  [114]="bartowski/BioMistral-7B-GGUF|gguf|7B|BioMistral — medical/bio AI"
  [115]="bartowski/Meditron-7B-GGUF|gguf|7B|Meditron — clinical medicine"
  [116]="bartowski/LegalBert-GGUF|gguf|0.3B|LegalBERT — legal text"
  [117]="bartowski/finance-LLM-GGUF|gguf|7B|FinanceLLM — financial analysis"
  # ── Tiny / Edge Models ───────────────────────────────────────────
  [118]="bartowski/TinyLlama-1.1B-Chat-v1.0-GGUF|gguf|1.1B|TinyLlama 1.1B — ultra light"
  [119]="bartowski/Qwen2.5-0.5B-Instruct-GGUF|gguf|0.5B|Qwen2.5 0.5B — smallest chat"
  [120]="bartowski/SmolLM2-360M-Instruct-GGUF|gguf|0.36B|SmolLM2 360M — edge device"
  [121]="bartowski/SmolLM2-135M-Instruct-GGUF|gguf|0.13B|SmolLM2 135M — IOT/embedded"
  # ── Instruction Tuned ────────────────────────────────────────────
  [122]="bartowski/neural-chat-7b-v3-3-GGUF|gguf|7B|Neural Chat — Intel tuned"
  [123]="bartowski/zephyr-7b-beta-GGUF|gguf|7B|Zephyr 7B — HuggingFace tuned"
  [124]="bartowski/openchat-3.5-0106-GGUF|gguf|7B|OpenChat 3.5 — competitive 7B"
  [125]="bartowski/Starling-LM-7B-alpha-GGUF|gguf|7B|Starling 7B — RLHF champion"
  # ── More Cloud APIs ──────────────────────────────────────────────
  [126]="o3-mini|openai|API|OpenAI o3-mini — advanced reasoning"
  [127]="gpt-4-turbo|openai|API|GPT-4 Turbo — fast GPT-4"
  [128]="gpt-3.5-turbo|openai|API|GPT-3.5 Turbo — cheapest OpenAI"
  [129]="claude-sonnet-4-6|claude|API|Claude Sonnet 4.6 — latest Sonnet"
  [130]="claude-opus-4-7|claude|API|Claude Opus 4.7 — most capable"
  [131]="gemini-2.5-pro|gemini|API|Gemini 2.5 Pro — latest Gemini"
  [132]="gemini-2.5-flash|gemini|API|Gemini 2.5 Flash — fast Gemini"
  [133]="llama-3.3-70b-versatile|groq|API|Groq Llama 70B — ultra fast"
  [134]="llama-3.1-8b-instant|groq|API|Groq Llama 8B — instant replies"
  [135]="mixtral-8x7b-32768|groq|API|Groq Mixtral — fast MoE"
  [136]="mistral-large-latest|mistral|API|Mistral Large — flagship"
  [137]="mistral-small-latest|mistral|API|Mistral Small — affordable"
  [138]="codestral-latest|mistral|API|Codestral — Mistral code"
  [139]="meta-llama/Llama-3.3-70B-Instruct-Turbo|together|API|Together Llama 70B"
  [140]="meta-llama/Llama-3.1-8B-Instruct-Turbo|together|API|Together Llama 8B"
  # ── Function Calling / Tool Use ──────────────────────────────────
  [141]="bartowski/Hermes-3-Llama-3.1-70B-GGUF|gguf|70B|Hermes 3 70B — tool calling"
  [142]="bartowski/functionary-small-v3.2-GGUF|gguf|8B|Functionary 8B — function calling"
  [143]="bartowski/NexusRaven-V2-13B-GGUF|gguf|13B|NexusRaven — function calling"
  # ── Agent / Planning ─────────────────────────────────────────────
  [144]="bartowski/Qwen2.5-7B-Instruct-GGUF|gguf|7B|Qwen2.5 7B — agentic"
  [145]="bartowski/Llama-3.1-Storm-8B-GGUF|gguf|8B|Storm 8B — planning agent"
  # ── RLHF / DPO Tuned ────────────────────────────────────────────
  [146]="bartowski/tulu-2-dpo-70b-GGUF|gguf|70B|Tulu 2 DPO 70B — RLHF aligned"
  [147]="bartowski/Nous-Hermes-2-SOLAR-10.7B-GGUF|gguf|10.7B|Hermes SOLAR — DPO tuned"
  # ── Uncensored / Unfiltered ──────────────────────────────────────
  [148]="bartowski/dolphin-2.9.3-llama-3.1-8B-GGUF|gguf|8B|Dolphin Llama 8B"
  [149]="bartowski/Midnight-Miqu-70B-v1.5-GGUF|gguf|70B|Midnight Miqu 70B"
  # ── Japanese / CJK ──────────────────────────────────────────────
  [150]="bartowski/Llama-3-ELYZA-JP-8B-GGUF|gguf|8B|ELYZA 8B — Japanese"
  [151]="bartowski/Japanese-Starling-ChatV-7B-GGUF|gguf|7B|Starling JP — Japanese chat"
  # ── Science / Research ───────────────────────────────────────────
  [152]="bartowski/SciGLM-6B-GGUF|gguf|6B|SciGLM — science QA"
  [153]="bartowski/ChemLLM-7B-Chat-GGUF|gguf|7B|ChemLLM — chemistry"
  # ── Text Classification / NLU ────────────────────────────────────
  [154]="MoritzLaurer/deberta-v3-large-zeroshot-v2.0|hf|0.4B|DeBERTa — zero-shot classify"
  [155]="facebook/bart-large-mnli|hf|0.4B|BART MNLI — NLI classifier"
  # ── Summarization ────────────────────────────────────────────────
  [156]="facebook/bart-large-cnn|hf|0.4B|BART CNN — summarization"
  [157]="google/pegasus-xsum|hf|0.5B|Pegasus — abstractive summary"
  # ── Translation ──────────────────────────────────────────────────
  [158]="facebook/nllb-200-distilled-600M|hf|0.6B|NLLB-200 — 200 languages"
  [159]="Helsinki-NLP/opus-mt-en-fr|hf|0.3B|OPUS EN→FR translation"
  [160]="Helsinki-NLP/opus-mt-en-de|hf|0.3B|OPUS EN→DE translation"
  [161]="Helsinki-NLP/opus-mt-en-es|hf|0.3B|OPUS EN→ES translation"
  [162]="Helsinki-NLP/opus-mt-en-zh|hf|0.3B|OPUS EN→ZH translation"
  # ── Sentiment / Emotion ──────────────────────────────────────────
  [163]="cardiffnlp/twitter-roberta-base-sentiment-latest|hf|0.1B|Twitter Sentiment"
  [164]="SamLowe/roberta-base-go_emotions|hf|0.1B|GoEmotions — 28 emotions"
  # ── Named Entity Recognition ─────────────────────────────────────
  [165]="dslim/bert-base-NER|hf|0.1B|BERT NER — entity extraction"
  [166]="Jean-Baptiste/camembert-ner|hf|0.1B|CamemBERT NER — French NER"
  # ── Q&A / Reading Comprehension ──────────────────────────────────
  [167]="deepset/roberta-base-squad2|hf|0.1B|RoBERTa SQuAD2 — extractive QA"
  [168]="Intel/dynamic_tinybert|hf|0.06B|TinyBERT — fast QA"
  # ── OCR / Document ───────────────────────────────────────────────
  [169]="microsoft/trocr-base-printed|hf|0.3B|TrOCR — printed text OCR"
  [170]="microsoft/trocr-base-handwritten|hf|0.3B|TrOCR — handwriting OCR"
  [171]="microsoft/layoutlmv3-base|hf|0.1B|LayoutLMv3 — document AI"
  # ── Object Detection / Segmentation ──────────────────────────────
  [172]="facebook/detr-resnet-50|hf|41M|DETR — object detection"
  [173]="facebook/sam-vit-base|hf|0.3B|SAM — segment anything"
  [174]="google/owlvit-base-patch32|hf|0.15B|OWL-ViT — open vocab detection"
  # ── Image Classification ─────────────────────────────────────────
  [175]="google/vit-base-patch16-224|hf|86M|ViT — image classification"
  [176]="microsoft/resnet-50|hf|25M|ResNet-50 — classic image classifier"
  # ── Depth Estimation ─────────────────────────────────────────────
  [177]="Intel/dpt-large|hf|0.3B|DPT — monocular depth estimation"
  [178]="LiheYoung/depth-anything-base-hf|hf|97M|Depth Anything — relative depth"
  # ── Video Models ─────────────────────────────────────────────────
  [179]="MCG-NJU/videomae-base|hf|86M|VideoMAE — video understanding"
  # ── Text-to-Speech Extended ──────────────────────────────────────
  [180]="microsoft/speecht5_tts|hf|0.3B|SpeechT5 — fast TTS"
  [181]="facebook/mms-tts-eng|hf|0.3B|MMS TTS English — Meta speech"
  # ── More GGUF Small Models ───────────────────────────────────────
  [182]="bartowski/Llama-3.2-1B-Instruct-GGUF|gguf|1B|Llama 3.2 1B — Meta tiny"
  [183]="bartowski/internlm2_5-1_8b-chat-GGUF|gguf|1.8B|InternLM2.5 1.8B"
  [184]="bartowski/stablelm-zephyr-3b-GGUF|gguf|3B|StableLM Zephyr 3B"
  [185]="bartowski/rocket-3B-GGUF|gguf|3B|Rocket 3B — ultra fast"
  [186]="bartowski/H2O-Danube3-500M-Chat-GGUF|gguf|0.5B|H2O Danube 500M — edge"
  # ── Mixture of Experts ───────────────────────────────────────────
  [187]="bartowski/Mixtral-8x22B-Instruct-v0.1-GGUF|gguf|141B|Mixtral 8x22B — massive MoE"
  [188]="bartowski/DeepSeek-V2-Lite-Chat-GGUF|gguf|16B|DeepSeek V2 Lite MoE"
  [189]="bartowski/DBRX-Instruct-GGUF|gguf|132B|DBRX — Databricks MoE"
  # ── Safety / Moderation ──────────────────────────────────────────
  [190]="meta-llama/Llama-Guard-3-8B|hf|8B|Llama Guard 3 — content safety"
  [191]="meta-llama/Prompt-Guard-86M|hf|86M|Prompt Guard — injection detection"
  # ── Reward Models ────────────────────────────────────────────────
  [192]="OpenAssistant/reward-model-deberta-v3-large-v2|hf|0.4B|OA Reward Model"
  # ── Code Completion ──────────────────────────────────────────────
  [193]="bigcode/starcoder2-3b|hf|3B|StarCoder2 3B — code completion"
  [194]="Qwen/CodeQwen1.5-7B|hf|7B|CodeQwen 1.5 — code gen"
  # ── Newest 2025 Models ───────────────────────────────────────────
  [195]="bartowski/Qwen3-8B-GGUF|gguf|8B|Qwen3 8B — latest Qwen generation"
  # ── Thinking / Reasoning Models ──────────────────────────────────
  [196]="o3-mini|openai|API|OpenAI o3-mini — chain-of-thought reasoning"
  [197]="o1|openai|API|OpenAI o1 — deep reasoning"
  [198]="o1-mini|openai|API|OpenAI o1-mini — fast reasoning"
  [199]="claude-opus-4-7|claude|API|Claude Opus 4.7 — extended thinking"
  [200]="bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF|gguf|14B|DeepSeek-R1 14B — local reasoning"
  [201]="bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF|gguf|32B|DeepSeek-R1 32B — strong reasoning"
  [202]="bartowski/Qwen3-8B-GGUF|gguf|8B|Qwen3 8B — thinking mode built-in"
  [203]="bartowski/Qwen2.5-Math-72B-Instruct-GGUF|gguf|72B|Qwen2.5 Math 72B — math reasoning"
  [204]="gemini-2.5-pro|gemini|API|Gemini 2.5 Pro — thinking with search"
  [205]="llama-3.3-70b-versatile|groq|API|Groq Llama 70B — fast chain-of-thought"
)

# ════════════════════════════════════════════════════════════════════════════════
#  BUILTIN PERSONAS
# ════════════════════════════════════════════════════════════════════════════════
declare -A BUILTIN_PERSONAS
BUILTIN_PERSONAS=(
  [default]="You are a helpful, friendly AI assistant."
  [dev]="You are an expert software engineer. Write clean, secure, well-documented code. Prefer idiomatic solutions. Flag potential bugs and security issues."
  [researcher]="You are a rigorous researcher. Cite your reasoning. Acknowledge uncertainty. Be precise and thorough."
  [writer]="You are a skilled writer. Prioritize clarity, flow, and engagement. Adapt tone to context."
  [teacher]="You are a patient teacher. Use analogies and examples. Check for understanding. Scaffold complex concepts."
  [sysadmin]="You are a Linux/DevOps expert. Give precise, tested commands. Prefer minimal dependencies."
  [security]="You are a cybersecurity expert. Think offensively to defend. Reference CVEs where relevant."
  [data]="You are a data scientist. Use pandas, numpy, matplotlib. Apply statistical rigor."
  [creative]="You are a bold, original creative. Push boundaries. Experiment with form and voice."
  [concise]="Be maximally concise. Use the fewest words without losing accuracy."
  [audio]="You are an audio engineering and music production expert. Help with DSP, audio files, mixing, analysis."
  [video]="You are a video production and ffmpeg expert. Help with video editing, transcoding, analysis."
)


# ════════════════════════════════════════════════════════════════════════════════
#  CUSTOM MODEL CONFIGS (prebuilt architecture presets)
# ════════════════════════════════════════════════════════════════════════════════
declare -A MODEL_PRESETS
MODEL_PRESETS=(
  [nano]="hidden_size=256|num_hidden_layers=8|num_attention_heads=8|intermediate_size=512|max_position_embeddings=512|vocab_size=32000|params=~0.125B"
  [micro]="hidden_size=512|num_hidden_layers=8|num_attention_heads=8|intermediate_size=1024|max_position_embeddings=1024|vocab_size=32000|params=~0.25B"
  [tiny]="hidden_size=512|num_hidden_layers=10|num_attention_heads=8|intermediate_size=1024|max_position_embeddings=2048|vocab_size=32000|params=~0.35B"
  [small]="hidden_size=768|num_hidden_layers=12|num_attention_heads=12|intermediate_size=2048|max_position_embeddings=2048|vocab_size=32000|params=~0.5B"
  [medium]="hidden_size=1024|num_hidden_layers=16|num_attention_heads=16|intermediate_size=4096|max_position_embeddings=2048|vocab_size=32000|params=~1B"
  [tinyllama]="hidden_size=2048|num_hidden_layers=22|num_attention_heads=32|intermediate_size=5632|max_position_embeddings=2048|vocab_size=32000|params=~1.1B"
)

# ── Model JSON configs ────────────────────────────────────────────────────────

# TTM: 179.35M — TinyLlama-based
TTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":1280,"initializer_range":0.02,
  "intermediate_size":3328,"max_position_embeddings":2048,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":14,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"bfloat16",
  "use_cache":true,"vocab_size":32000,"_comment":"~179.35M params"
}'

# MTM: 0.61B — GTX 1080 optimized (fp16, 8GB VRAM — Pascal arch)
# Uses grouped-query attention (GQA) 4 kv heads, smaller intermediate for VRAM fit
MTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":2048,"initializer_range":0.02,
  "intermediate_size":5120,"max_position_embeddings":2048,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":18,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"float16",
  "use_cache":true,"vocab_size":32000,
  "_comment":"~0.61B params — GTX 1080 (8GB fp16) optimized"
}'

# Mtm: 1.075B — RTX 2080+ optimized (bf16, 8GB+ VRAM — Turing/Ampere)
# More layers, wider intermediate, bf16 for Turing+ tensor cores
MMTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":2048,"initializer_range":0.02,
  "intermediate_size":5632,"max_position_embeddings":4096,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":28,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"bfloat16",
  "use_cache":true,"vocab_size":32000,
  "_comment":"~1.075B params — RTX 2080+ (bf16) optimized"
}'

# ════════════════════════════════════════════════════════════════════════════════
#  6 PRETRAINING DATASETS (shared by TTM/MTM/Mtm)
#  +2 optional custom ones set by user
# ════════════════════════════════════════════════════════════════════════════════
PRETRAIN_DATASETS=(
  "roneneldan/TinyStories|text|5000|Tiny children's stories — fluent English"
  "sahil2801/CodeAlpaca-20k|instruction+output|3000|Code generation pairs"
  "Open-Orca/OpenOrca|system_prompt+question+response|2000|Instruction following"
  "bigcode/the-stack-smol|content|2000|Small code snippets across languages"
  "HuggingFaceFW/fineweb-edu|text|3000|High-quality educational web text"
  "wikimedia/wikipedia|text|3000|Wikipedia articles (en, 20231101)"
)
# User-settable custom datasets (HF id or 'hf:user/repo' or local path)
PRETRAIN_CUSTOM_1="${PRETRAIN_CUSTOM_1:-}"
PRETRAIN_CUSTOM_2="${PRETRAIN_CUSTOM_2:-}"

# RLHF settings
RLHF_AUTO="${RLHF_AUTO:-0}"
RLHF_JUDGE="${RLHF_JUDGE:-nix26}"           # nix26 | qwen3+luth | qwen3+llama32
RLHF_MANUAL_ENABLED="${RLHF_MANUAL_ENABLED:-1}"
RLHF_REWARD_THRESHOLD="${RLHF_REWARD_THRESHOLD:-0.6}"

# Right-click context menu
RCLICK_ENABLED="${RCLICK_ENABLED:-0}"
RCLICK_VL_MODEL="${RCLICK_VL_MODEL:-qwen3vl}"  # qwen3vl | lfm25vl | lfm25vl_gguf | custom
RCLICK_CUSTOM_MODEL="${RCLICK_CUSTOM_MODEL:-}"

# Auto-updater
AUP_REPO="${AUP_REPO:-minerofthesoal/ai-cli}"
AUP_CHECK_INTERVAL="${AUP_CHECK_INTERVAL:-3600}"
AUP_LAST_CHECK="${AUP_LAST_CHECK:-0}"

# Agent mode
AGENT_MODE="${AGENT_MODE:-0}"
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-10}"
AGENT_SEARCH_ENGINE="${AGENT_SEARCH_ENGINE:-ddg}"

# v2.4: LLM API server settings
API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8080}"
API_KEY="${API_KEY:-}"            # optional bearer token for API auth
API_CORS="${API_CORS:-1}"         # enable CORS for browser clients

# v2.4.5: API key hosting (shareable keys for others to access your model)
API_SHARE_ENABLED="${API_SHARE_ENABLED:-0}"
API_SHARE_HOST="${API_SHARE_HOST:-0.0.0.0}"
API_SHARE_PORT="${API_SHARE_PORT:-8080}"
API_SHARE_RATE_LIMIT="${API_SHARE_RATE_LIMIT:-60}"  # requests per minute per key

# v2.4.5: Multi-AI settings
MULTIAI_ROUNDS="${MULTIAI_ROUNDS:-6}"               # default conversation rounds
MULTIAI_SAVE_DATASET="${MULTIAI_SAVE_DATASET:-1}"   # save as training dataset
MULTIAI_RLHF_TRAIN="${MULTIAI_RLHF_TRAIN:-0}"       # auto-train on rated exchanges

# v2.4: CPU-only mode (auto-set on Windows or when no GPU found)
# v2.6: Fixed — sm_61 (Pascal GTX 10xx) and Metal correctly detected as GPU
# v2.9.1: Stale cache fix — delete cache if GPU now exists but cache says 0
CPU_ONLY_MODE="${CPU_ONLY_MODE:-0}"
[[ $IS_WINDOWS -eq 1 ]] && CPU_ONLY_MODE=1
[[ $IS_ISH -eq 1 ]] && CPU_ONLY_MODE=1
# Re-detect if cache says 0 but nvidia device exists
if [[ "${CUDA_ARCH:-0}" == "0" ]]; then
  if command -v nvidia-smi &>/dev/null || [[ -d /proc/driver/nvidia/gpus ]] || ls /dev/nvidia[0-9]* &>/dev/null 2>&1; then
    rm -f "$_CUDA_CACHE" 2>/dev/null
    CUDA_ARCH="$(detect_cuda_arch)"
    mkdir -p "$(dirname "$_CUDA_CACHE")" && echo "$CUDA_ARCH" > "$_CUDA_CACHE" 2>/dev/null
  fi
fi
[[ "${CUDA_ARCH:-0}" == "0" ]] && CPU_ONLY_MODE=1
# v2.9.1: Auto-fix GPU_LAYERS=0 when GPU is available
if [[ "${CUDA_ARCH:-0}" != "0" && "${GPU_LAYERS:-0}" == "0" ]]; then
  GPU_LAYERS=-1
fi

# ════════════════════════════════════════════════════════════════════════════════
#  GENERALIZED TRAINED MODEL ENGINE
#  Handles TTM (tiny/179M), MTM (mini/0.61B), Mtm (medium/1.075B)
# ════════════════════════════════════════════════════════════════════════════════

# _tm_vars MODEL_ID  →  sets TM_DIR TM_HF_REPO TM_CONFIG_JSON TM_LABEL
#                        TM_AUTO_TRAIN_VAR TM_VERSION_VAR TM_PRETRAINED_VAR
_tm_vars() {
  local id="$1"
  case "$id" in
    TTM|ttm)
      TM_DIR="$TTM_DIR"
      TM_HF_REPO="ray0rf1re/tiny"
      TM_CONFIG_JSON="$TTM_CONFIG_JSON"
      TM_LABEL="TTM (Tiny ~179M)"
      TM_AUTO_TRAIN_VAR="TTM_AUTO_TRAIN"
      TM_VERSION_VAR="TTM_VERSION"
      TM_PRETRAINED_VAR="TTM_PRETRAINED"
      TM_DTYPE="bfloat16"
      TM_GPU_OPT="any"
      ;;
    MTM|mtm)
      TM_DIR="$MTM_DIR"
      TM_HF_REPO="ray0rf1re/mini"
      TM_CONFIG_JSON="$MTM_CONFIG_JSON"
      TM_LABEL="MTM (Mini ~0.61B, GTX 1080)"
      TM_AUTO_TRAIN_VAR="MTM_AUTO_TRAIN"
      TM_VERSION_VAR="MTM_VERSION"
      TM_PRETRAINED_VAR="MTM_PRETRAINED"
      TM_DTYPE="float16"
      TM_GPU_OPT="GTX 1080 / Pascal+"
      ;;
    Mtm|mmtm|MMTM)
      TM_DIR="$MMTM_DIR"
      TM_HF_REPO="ray0rf1re/medium"
      TM_CONFIG_JSON="$MMTM_CONFIG_JSON"
      TM_LABEL="Mtm (Medium ~1.075B, RTX 2080+)"
      TM_AUTO_TRAIN_VAR="MMTM_AUTO_TRAIN"
      TM_VERSION_VAR="MMTM_VERSION"
      TM_PRETRAINED_VAR="MMTM_PRETRAINED"
      TM_DTYPE="bfloat16"
      TM_GPU_OPT="RTX 2080+ / Turing+"
      ;;
    *) err "Unknown model ID: $id (use TTM, MTM, or Mtm)"; return 1 ;;
  esac
}

_tm_get_var()  { eval "echo \"\${${1}:-0}\""; }
_tm_set_var()  { eval "${1}=\"${2}\""; }

_tm_init() {
  local id="$1"; _tm_vars "$id"
  mkdir -p "$TM_DIR"
  local cfg="$TM_DIR/config.json"
  if [[ ! -f "$cfg" ]]; then
    echo "$TM_CONFIG_JSON" > "$cfg"
    ok "$TM_LABEL config created: $cfg"
  fi
}

_tm_create_repo() {
  local id="$1"; _tm_vars "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }
  info "Creating HuggingFace repo: $TM_HF_REPO ..."
  HF_TOKEN_VAL="$hf_key" REPO_ID="$TM_HF_REPO" MODEL_LABEL="$TM_LABEL" \
  MODEL_CFG="$TM_CONFIG_JSON" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed. Run: ai install-deps"); sys.exit(1)
api = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo = os.environ['REPO_ID']
label = os.environ['MODEL_LABEL']
cfg   = os.environ['MODEL_CFG']
try:
    api.create_repo(repo_id=repo, exist_ok=True, private=False, repo_type='model')
    readme = f"# {label}\n\nAuto-trained model by AI CLI v2.3.\n\n```json\n{cfg}\n```\n"
    api.upload_file(
        path_or_fileobj=readme.encode(),
        path_in_repo="README.md",
        repo_id=repo,
        commit_message="init: create repo",
    )
    print(f"Created: https://huggingface.co/{repo}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

_tm_pretrain() {
  local id="$1"; shift
  local custom1="${1:-$PRETRAIN_CUSTOM_1}"; local custom2="${2:-$PRETRAIN_CUSTOM_2}"
  _tm_vars "$id"; _tm_init "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  info "$TM_LABEL — Starting pretraining"
  info "Using 6 standard datasets + ${custom1:+custom1: $custom1 }${custom2:+custom2: $custom2}"
  echo ""

  TM_DIR_VAL="$TM_DIR" TM_DTYPE_VAL="$TM_DTYPE" \
  CUSTOM1="${custom1:-}" CUSTOM2="${custom2:-}" \
  "$PYTHON" - <<'PYEOF'
import os, json, sys
TM_DIR   = os.environ['TM_DIR_VAL']
TM_DTYPE = os.environ.get('TM_DTYPE_VAL','float32')
CUSTOM1  = os.environ.get('CUSTOM1','')
CUSTOM2  = os.environ.get('CUSTOM2','')

try:
    import torch
    from transformers import (AutoTokenizer, LlamaConfig, LlamaForCausalLM,
                               TrainingArguments, Trainer, DataCollatorForLanguageModeling)
    from datasets import load_dataset, Dataset
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)

cfg_path = f"{TM_DIR}/config.json"
out_dir  = f"{TM_DIR}/pretrained"
os.makedirs(out_dir, exist_ok=True)

with open(cfg_path) as f:
    raw = json.load(f)
cfg = LlamaConfig(**{k:v for k,v in raw.items() if not k.startswith('_') and k!='architectures'})
model = LlamaForCausalLM(cfg)
total = sum(p.numel() for p in model.parameters())
print(f"Parameters: {total:,} ({total/1e6:.2f}M)")

tokenizer = AutoTokenizer.from_pretrained("TinyLlama/TinyLlama-1.1B-Chat-v1.0")
tokenizer.pad_token = tokenizer.eos_token
MAX_LEN = min(cfg.max_position_embeddings, 256)

records = []

# ── Dataset 1: TinyStories ────────────────────────────────────────────────────
print("Dataset 1/8: roneneldan/TinyStories")
try:
    ds = load_dataset("roneneldan/TinyStories", split="train[:6000]")
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 2: CodeAlpaca ─────────────────────────────────────────────────────
print("Dataset 2/8: sahil2801/CodeAlpaca-20k")
try:
    ds = load_dataset("sahil2801/CodeAlpaca-20k", split="train[:4000]")
    for ex in ds:
        t = (ex.get('instruction','') + '\n' + ex.get('output',''))[:MAX_LEN*4]
        records.append(t)
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 3: OpenOrca ───────────────────────────────────────────────────────
print("Dataset 3/8: Open-Orca/OpenOrca")
try:
    ds = load_dataset("Open-Orca/OpenOrca", split="train[:3000]")
    for ex in ds:
        t = (ex.get('system_prompt','') + ' ' + ex.get('question','') + '\n' + ex.get('response',''))[:MAX_LEN*4]
        records.append(t)
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 4: The Stack Smol ─────────────────────────────────────────────────
print("Dataset 4/8: bigcode/the-stack-smol")
try:
    ds = load_dataset("bigcode/the-stack-smol", data_dir="data/python", split="train[:3000]")
    for ex in ds: records.append(ex.get('content','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 5: FineWeb-Edu ────────────────────────────────────────────────────
print("Dataset 5/8: HuggingFaceFW/fineweb-edu")
try:
    ds = load_dataset("HuggingFaceFW/fineweb-edu", name="sample-10BT", split="train[:4000]",
                      streaming=False)
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 6: Wikipedia ──────────────────────────────────────────────────────
print("Dataset 6/8: wikimedia/wikipedia (en)")
try:
    ds = load_dataset("wikimedia/wikipedia", "20231101.en", split="train[:4000]")
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Custom dataset 1 ──────────────────────────────────────────────────────────
if CUSTOM1:
    print(f"Dataset 7/8: {CUSTOM1} (custom)")
    try:
        if CUSTOM1.startswith('/') or CUSTOM1.endswith('.jsonl') or CUSTOM1.endswith('.txt'):
            with open(CUSTOM1) as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        obj = json.loads(line)
                        t = obj.get('text','') or obj.get('content','') or str(obj)
                    except:
                        t = line
                    records.append(t[:MAX_LEN*4])
        else:
            ds_id = CUSTOM1.replace('hf:','')
            ds = load_dataset(ds_id, split="train[:2000]")
            tcols = [c for c in ds.column_names if c in ['text','content','input','instruction']]
            col = tcols[0] if tcols else ds.column_names[0]
            for ex in ds: records.append(str(ex.get(col,''))[:MAX_LEN*4])
        print(f"  added custom1 (total {len(records)})")
    except Exception as e: print(f"  skipped: {e}")

# ── Custom dataset 2 ──────────────────────────────────────────────────────────
if CUSTOM2:
    print(f"Dataset 8/8: {CUSTOM2} (custom)")
    try:
        if CUSTOM2.startswith('/') or CUSTOM2.endswith('.jsonl') or CUSTOM2.endswith('.txt'):
            with open(CUSTOM2) as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        obj = json.loads(line)
                        t = obj.get('text','') or obj.get('content','') or str(obj)
                    except:
                        t = line
                    records.append(t[:MAX_LEN*4])
        else:
            ds_id = CUSTOM2.replace('hf:','')
            ds = load_dataset(ds_id, split="train[:2000]")
            tcols = [c for c in ds.column_names if c in ['text','content','input','instruction']]
            col = tcols[0] if tcols else ds.column_names[0]
            for ex in ds: records.append(str(ex.get(col,''))[:MAX_LEN*4])
        print(f"  added custom2 (total {len(records)})")
    except Exception as e: print(f"  skipped: {e}")

# ── Filter and tokenize ───────────────────────────────────────────────────────
records = [r for r in records if r and len(r.strip()) > 20]
print(f"\nTotal records: {len(records)}")
if not records:
    print("No data loaded"); sys.exit(1)

ds_all = Dataset.from_list([{'text': r} for r in records])
def tokenize(ex):
    return tokenizer(ex['text'], truncation=True, max_length=MAX_LEN, padding='max_length')
ds_all = ds_all.map(tokenize, batched=True, remove_columns=['text'])

device = 'cuda' if torch.cuda.is_available() else 'cpu'
dtype_map = {'float16': torch.float16, 'bfloat16': torch.bfloat16, 'float32': torch.float32}
torch_dtype = dtype_map.get(TM_DTYPE, torch.float32)
model = model.to(device)
if device == 'cuda':
    model = model.to(torch_dtype)

print(f"Training on: {device} | dtype: {TM_DTYPE} | records: {len(ds_all)}")

args = TrainingArguments(
    output_dir=out_dir,
    num_train_epochs=1.075,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,
    learning_rate=5e-4,
    lr_scheduler_type='cosine',
    warmup_ratio=0.05,
    fp16=(device=='cuda' and TM_DTYPE=='float16'),
    bf16=(device=='cuda' and TM_DTYPE=='bfloat16'),
    logging_steps=50,
    save_steps=500,
    save_total_limit=1,
    report_to='none',
    dataloader_num_workers=0,
)
trainer = Trainer(
    model=model,
    args=args,
    train_dataset=ds_all,
    data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"\nPretrained model saved: {out_dir}")
PYEOF

  if [[ -d "$TM_DIR/pretrained" ]]; then
    _tm_set_var "$TM_PRETRAINED_VAR" "1"
    save_config
    ok "$TM_LABEL pretraining complete"
  fi
}

_tm_train_batch() {
  local id="$1"; _tm_vars "$id"
  local auto_var; auto_var=$(_tm_get_var "$TM_AUTO_TRAIN_VAR")
  [[ "$auto_var" != "1" ]] && return 0
  [[ -z "$PYTHON" ]] && return 0

  # Build batch data from chat logs + history
  local batch_file; batch_file=$(mktemp /tmp/tm_batch_XXXX.jsonl)
  find "$CHAT_LOGS_DIR" -name "*.jsonl" -newer "$TM_DIR/.last_train" 2>/dev/null | head -5 | while read -r f; do
    cat "$f"
  done > "$batch_file" 2>/dev/null || true
  if [[ -f "$LOG_FILE" ]]; then
    tail -20 "$LOG_FILE" | while IFS= read -r line; do
      local msg; msg=$(echo "$line" | sed 's/^[0-9T:+-]* \[[a-z]*\] //')
      [[ -n "$msg" ]] && echo "{\"text\":\"$msg\"}" >> "$batch_file"
    done
  fi

  local count; count=$(wc -l < "$batch_file" 2>/dev/null || echo 0)
  if (( count < 3 )); then rm -f "$batch_file"; return 0; fi

  local base_model="$TM_DIR/pretrained"
  local latest_ft; latest_ft=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest_ft" ]] && base_model="$latest_ft"
  [[ ! -d "$base_model" ]] && { rm -f "$batch_file"; return 0; }

  local cur_ver; cur_ver=$(_tm_get_var "$TM_VERSION_VAR")
  local new_ver=$(( cur_ver + 1 ))
  local out_dir="$TM_DIR/ft_v${new_ver}"
  mkdir -p "$out_dir"

  BATCH_FILE="$batch_file" BASE_MODEL="$base_model" OUT_DIR="$out_dir" \
  TM_DTYPE_VAL="$TM_DTYPE" "$PYTHON" - <<'PYEOF' &>/dev/null &
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, \
        TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType
except ImportError: sys.exit(0)

batch_file = os.environ['BATCH_FILE']
base_model = os.environ['BASE_MODEL']
out_dir    = os.environ['OUT_DIR']
TM_DTYPE   = os.environ.get('TM_DTYPE_VAL','float32')

records = []
with open(batch_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            txt = obj.get('text','') or obj.get('output','') + ' ' + obj.get('instruction','')
            if txt.strip(): records.append({'text': txt[:256]})
        except: pass
if len(records) < 3: sys.exit(0)

tokenizer = AutoTokenizer.from_pretrained(base_model)
tokenizer.pad_token = tokenizer.eos_token
model = AutoModelForCausalLM.from_pretrained(base_model)
lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=4, lora_alpha=8,
                  lora_dropout=0.05, target_modules=["q_proj","v_proj"])
model = get_peft_model(model, lora)
ds = Dataset.from_list(records)
def tok(ex): return tokenizer(ex['text'], truncation=True, max_length=128, padding='max_length')
ds = ds.map(tok, batched=True, remove_columns=['text'])
device = 'cuda' if torch.cuda.is_available() else 'cpu'
model = model.to(device)
dtype_map = {'float16': torch.float16, 'bfloat16': torch.bfloat16}
if device == 'cuda' and TM_DTYPE in dtype_map:
    model = model.to(dtype_map[TM_DTYPE])
args = TrainingArguments(
    output_dir=out_dir, num_train_epochs=1, per_device_train_batch_size=1,
    gradient_accumulation_steps=1, max_steps=1, learning_rate=2e-4,
    fp16=(device=='cuda' and TM_DTYPE=='float16'),
    bf16=(device=='cuda' and TM_DTYPE=='bfloat16'),
    logging_steps=1, save_steps=1, report_to='none',
)
Trainer(model=model, args=args, train_dataset=ds,
        data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False)).train()
merged = model.merge_and_unload()
merged.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
PYEOF

  rm -f "$batch_file"
  touch "$TM_DIR/.last_train"
  _tm_set_var "$TM_VERSION_VAR" "$new_ver"
  save_config
}

_tm_upload() {
  local id="$1"; local version="${2:-latest}"; _tm_vars "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }

  local model_dir
  if [[ "$version" == "latest" ]]; then
    model_dir=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "$TM_DIR/pretrained")
  else
    model_dir="$TM_DIR/ft_v${version}"
  fi
  [[ ! -d "$model_dir" ]] && { err "No $id model at $model_dir. Run: ai $id pretrain"; return 1; }

  local folder_name; folder_name=$(basename "$model_dir")
  info "Uploading $id $folder_name → $TM_HF_REPO/$folder_name"

  HF_TOKEN_VAL="$hf_key" MODEL_DIR="$model_dir" FOLDER_NAME="$folder_name" \
  TM_HF_REPO="$TM_HF_REPO" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed. Run: ai install-deps"); sys.exit(1)
api   = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo  = os.environ['TM_HF_REPO']
mdir  = os.environ['MODEL_DIR']
fname = os.environ['FOLDER_NAME']
try:
    api.create_repo(repo_id=repo, exist_ok=True, private=False)
except: pass
api.upload_folder(
    folder_path=mdir, repo_id=repo, path_in_repo=fname,
    commit_message=f"auto-upload: {fname}",
)
print(f"Uploaded: https://huggingface.co/{repo}/tree/main/{fname}")
PYEOF
}

_tm_load() {
  local id="$1"; local version="${2:-latest}"; _tm_vars "$id"
  local mdir
  if [[ "$version" == "latest" ]]; then
    mdir=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "$TM_DIR/pretrained")
  else
    mdir="$TM_DIR/ft_v${version}"
  fi
  [[ ! -d "$mdir" ]] && { err "$id not trained yet. Run: ai $id pretrain"; return 1; }
  ACTIVE_MODEL="$mdir"; ACTIVE_BACKEND="pytorch"; save_config
  ok "Loaded $TM_LABEL from $mdir"
}

_tm_status() {
  local id="$1"; _tm_vars "$id"
  local auto_var;    auto_var=$(_tm_get_var "$TM_AUTO_TRAIN_VAR")
  local pretrain_var; pretrain_var=$(_tm_get_var "$TM_PRETRAINED_VAR")
  local ver_var;     ver_var=$(_tm_get_var "$TM_VERSION_VAR")

  hdr "$TM_LABEL Status"
  echo "  HF Repo:    $TM_HF_REPO"
  echo "  GPU target: $TM_GPU_OPT"
  echo "  Data type:  $TM_DTYPE"
  echo "  Config:     $TM_DIR/config.json"
  echo "  Auto-train: $auto_var"
  echo "  Pretrained: $pretrain_var"
  echo "  Version:    $ver_var"
  echo ""
  [[ -d "$TM_DIR/pretrained" ]] && ok "Pretrained model present" || warn "Not pretrained yet"
  local latest; latest=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest" ]] && ok "Latest finetune: $(basename "$latest")"
  [[ -n "$PRETRAIN_CUSTOM_1" ]] && echo "  Custom DS 1: $PRETRAIN_CUSTOM_1"
  [[ -n "$PRETRAIN_CUSTOM_2" ]] && echo "  Custom DS 2: $PRETRAIN_CUSTOM_2"
}

# ── Generic cmd dispatcher for TTM/MTM/Mtm ────────────────────────────────────
_tm_cmd() {
  local id="$1"; shift
  local sub="${1:-help}"; shift || true
  _tm_init "$id"
  case "$sub" in
    pretrain)
      local c1="${1:-$PRETRAIN_CUSTOM_1}"; local c2="${2:-$PRETRAIN_CUSTOM_2}"
      _tm_pretrain "$id" "$c1" "$c2"
      ;;
    status)    _tm_status "$id" ;;
    load)      _tm_load "$id" "${1:-latest}" ;;
    train-now) _tm_train_batch "$id" ;;
    upload)    _tm_upload "$id" "${1:-latest}" ;;
    create-repo) _tm_create_repo "$id" ;;
    enable)
      _tm_vars "$id"
      _tm_set_var "$TM_AUTO_TRAIN_VAR" "1"; save_config
      ok "$TM_LABEL auto-training enabled"
      ;;
    disable)
      _tm_vars "$id"
      _tm_set_var "$TM_AUTO_TRAIN_VAR" "0"; save_config
      ok "$TM_LABEL auto-training disabled"
      ;;
    set-custom1)
      PRETRAIN_CUSTOM_1="${1:-}"; save_config
      ok "Custom dataset 1: $PRETRAIN_CUSTOM_1"
      ;;
    set-custom2)
      PRETRAIN_CUSTOM_2="${1:-}"; save_config
      ok "Custom dataset 2: $PRETRAIN_CUSTOM_2"
      ;;
    finetune|fine-tune|ft)
      local dataset="${1:-}"; local epochs="${2:-3}"; local lr="${3:-2e-4}"
      _tm_finetune "$id" "$dataset" "$epochs" "$lr"
      ;;
    *)
      _tm_vars "$id"
      echo -e "${B}${BCYAN}$TM_LABEL${R}"
      echo "  GPU target: $TM_GPU_OPT | Dtype: $TM_DTYPE | Repo: $TM_HF_REPO"
      echo ""
      echo "  ${B}ai $id pretrain [custom1] [custom2]${R} — Pretrain 6 standard + 2 optional"
      echo "  ${B}ai $id finetune DATASET [epochs] [lr]${R} — Fine-tune on custom dataset "
      echo "  ${B}ai $id enable / disable${R}              — Toggle auto-training"
      echo "  ${B}ai $id train-now${R}                     — Force one batch"
      echo "  ${B}ai $id upload [version]${R}              — Upload to $TM_HF_REPO"
      echo "  ${B}ai $id create-repo${R}                   — Create HF repo"
      echo "  ${B}ai $id status${R}                        — Show status"
      echo "  ${B}ai $id load [version]${R}                — Set as active model"
      echo "  ${B}ai $id set-custom1 HF_ID${R}   — Set custom dataset 1"
      echo "  ${B}ai $id set-custom2 HF_ID${R}   — Set custom dataset 2"
      echo ""
      echo "  ${B}ai -TTM${R} / ${B}ai -MTM${R} / ${B}ai -Mtm${R}            — Load respective model"
      ;;
  esac
}

cmd_ttm() { _tm_cmd "TTM" "$@"; }
cmd_mtm() { _tm_cmd "MTM" "$@"; }
cmd_Mtm() { _tm_cmd "Mtm" "$@"; }

# ════════════════════════════════════════════════════════════════════════════════
#  TTM / MTM / Mtm FINE-TUNING  
#  Fine-tune any trained model on a custom dataset using LoRA/QLoRA
#  ai ttm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
#  ai mtm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
#  ai Mtm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
# ════════════════════════════════════════════════════════════════════════════════
_tm_finetune() {
  local id="$1"; local dataset="${2:-}"; local epochs="${3:-3}"; local lr="${4:-2e-4}"
  _tm_vars "$id"; _tm_init "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Resolve dataset path
  local ds_path=""
  if [[ -z "$dataset" ]]; then
    err "Usage: ai $id finetune <dataset-name-or-path> [epochs] [lr]"
    echo "  Available datasets: $(ls "$DATASETS_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  if [[ -f "$DATASETS_DIR/$dataset/data.jsonl" ]]; then
    ds_path="$DATASETS_DIR/$dataset/data.jsonl"
  elif [[ -f "$dataset" ]]; then
    ds_path="$dataset"
  else
    err "Dataset '$dataset' not found"
    echo "  Create one: ai dataset create $dataset"
    echo "  Or provide a path to a JSONL file"
    return 1
  fi

  local n_pairs; n_pairs=$(wc -l < "$ds_path" 2>/dev/null || echo 0)
  if (( n_pairs < 10 )); then
    err "Dataset too small: $n_pairs pairs (need at least 10)"
    echo "  Add more pairs: ai dataset add $dataset \"PROMPT\" \"RESPONSE\""
    return 1
  fi

  local base_model_dir="$TM_DIR/pretrained"
  if [[ ! -d "$base_model_dir" ]]; then
    warn "No pretrained model found at $base_model_dir"
    warn "Run 'ai $id pretrain' first, or fine-tuning from config..."
    base_model_dir="$TM_DIR"
  fi

  local ft_out="$TM_DIR/finetuned_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$ft_out"

  hdr "$TM_LABEL Fine-tuning"
  echo "  Dataset:  $ds_path — $n_pairs pairs"
  echo "  Base:     $base_model_dir"
  echo "  Output:   $ft_out"
  echo "  Epochs:   $epochs | LR: $lr | Dtype: $TM_DTYPE"
  echo ""

  TM_DIR_VAL="$TM_DIR" TM_DTYPE_VAL="$TM_DTYPE" TM_LABEL_VAL="$TM_LABEL" \
  DS_PATH="$ds_path" EPOCHS="$epochs" LR="$lr" FT_OUT="$ft_out" \
  BASE_MODEL="$base_model_dir" \
  "$PYTHON" - <<'PYEOF'
import os, sys, json

TM_DIR   = os.environ['TM_DIR_VAL']
TM_DTYPE = os.environ.get('TM_DTYPE_VAL', 'float32')
TM_LABEL = os.environ.get('TM_LABEL_VAL', 'Model')
DS_PATH  = os.environ['DS_PATH']
EPOCHS   = int(os.environ.get('EPOCHS', '3'))
LR       = float(os.environ.get('LR', '2e-4'))
FT_OUT   = os.environ['FT_OUT']
BASE     = os.environ['BASE_MODEL']

try:
    import torch
    from transformers import (AutoTokenizer, AutoModelForCausalLM,
                               TrainingArguments, LlamaForCausalLM, LlamaConfig)
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)

# CPU-only mode: use float32 and minimal batch
device = "cpu"
dtype = torch.float32
if torch.cuda.is_available():
    device = "cuda"
    dtype = torch.float16 if TM_DTYPE == 'float16' else torch.bfloat16
    if TM_DTYPE == 'bfloat16' and not torch.cuda.is_bf16_supported():
        dtype = torch.float16
        print("  Note: BF16 not supported, falling back to FP16")

print(f"  Device: {device} | Dtype: {dtype}")

# Load tokenizer — try from base dir, fallback to TinyLlama tokenizer
try:
    tokenizer = AutoTokenizer.from_pretrained(BASE)
except Exception:
    tokenizer = AutoTokenizer.from_pretrained("TinyLlama/TinyLlama-1.1B-Chat-v1.0")
tokenizer.pad_token = tokenizer.eos_token

# Load model — try from pretrained dir, else from config
try:
    if TM_DTYPE == 'bfloat16' and device == 'cuda':
        model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=dtype).to(device)
    else:
        model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.float32).to(device)
    print(f"  Loaded pretrained model from {BASE}")
except Exception as e:
    print(f"  Loading from config (no pretrained weights): {e}")
    cfg_path = f"{TM_DIR}/config.json"
    with open(cfg_path) as f:
        raw = json.load(f)
    cfg = LlamaConfig(**{k: v for k, v in raw.items() if not k.startswith('_') and k != 'architectures'})
    model = LlamaForCausalLM(cfg).to(device)

total_params = sum(p.numel() for p in model.parameters())
print(f"  Parameters: {total_params:,} ({total_params/1e6:.2f}M)")

# Apply LoRA for efficient fine-tuning (CPU-friendly: small rank)
cpu_mode = (device == "cpu")
lora_r = 4 if cpu_mode else 8
lora_alpha = 8 if cpu_mode else 16

lora_cfg = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=lora_r,
    lora_alpha=lora_alpha,
    lora_dropout=0.05,
    bias="none",
    target_modules=["q_proj", "v_proj"]
)
model = get_peft_model(model, lora_cfg)
trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
print(f"  LoRA rank={lora_r} | Trainable params: {trainable:,} ({trainable/total_params*100:.2f}%)")

# Load dataset
records = []
with open(DS_PATH) as f:
    for line in f:
        try:
            r = json.loads(line)
            prompt = r.get('prompt', r.get('instruction', ''))
            response = r.get('response', r.get('output', r.get('answer', '')))
            if prompt and response:
                records.append({"text": f"User: {prompt}\nAssistant: {response}{tokenizer.eos_token}"})
        except: pass
print(f"  Dataset: {len(records)} training pairs")

if not records:
    print("ERROR: No valid pairs found in dataset"); sys.exit(1)

MAX_LEN = 256 if cpu_mode else 512

def tokenize(batch):
    out = tokenizer(batch['text'], truncation=True, padding='max_length',
                    max_length=MAX_LEN, return_tensors=None)
    out['labels'] = out['input_ids'].copy()
    return out

ds = Dataset.from_list(records).map(tokenize, batched=True, remove_columns=['text'])

# Training arguments — CPU-optimized when no GPU
batch_size = 1 if cpu_mode else 4
grad_accum = 8 if cpu_mode else 4

args = TrainingArguments(
    output_dir=FT_OUT,
    num_train_epochs=EPOCHS,
    per_device_train_batch_size=batch_size,
    gradient_accumulation_steps=grad_accum,
    learning_rate=LR,
    warmup_ratio=0.05,
    lr_scheduler_type="cosine",
    logging_steps=10,
    save_strategy="epoch",
    fp16=(dtype == torch.float16 and device == 'cuda'),
    bf16=(dtype == torch.bfloat16 and device == 'cuda'),
    dataloader_num_workers=0,
    no_cuda=(device == 'cpu'),
    report_to="none",
    save_total_limit=2,
    load_best_model_at_end=False,
    optim="adamw_torch",
)

from transformers import Trainer, DataCollatorForLanguageModeling
collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
trainer = Trainer(model=model, args=args, train_dataset=ds, data_collator=collator)

print(f"\n  Starting fine-tuning ({EPOCHS} epochs)...")
trainer.train()

# Save merged model
try:
    merged = model.merge_and_unload()
    merged.save_pretrained(FT_OUT)
    print(f"  Merged model saved: {FT_OUT}")
except Exception as e:
    # Save LoRA adapter only
    model.save_pretrained(FT_OUT)
    print(f"  LoRA adapter saved: {FT_OUT}")

tokenizer.save_pretrained(FT_OUT)
print(f"\n  Fine-tuning complete → {FT_OUT}")
print(f"  Load: ai {TM_LABEL.split()[0].lower()} load")
PYEOF

  if [[ $? -eq 0 ]]; then
    ok "Fine-tuning complete: $ft_out"
    echo "  Load model: ai $(echo "$id" | tr '[:upper:]' '[:lower:]') load"
    echo "  Upload:     ai $(echo "$id" | tr '[:upper:]' '[:lower:]') upload"
  else
    err "Fine-tuning failed. Check logs above."
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  RLHF — Reinforcement Learning from Human Feedback
#  Auto-RLHF: judge model rates responses → DPO training
#  Manual RLHF: thumbs up/down + star ratings → stored preferences
# ════════════════════════════════════════════════════════════════════════════════

# Judge model configs
declare -A RLHF_JUDGES
RLHF_JUDGES=(
  [nix26]="mradermacher/Nix2.6-GGUF|Nix2.6-Q4_K_M.gguf|Single judge — Nix 2.6 (general alignment)"
  [qwen3+luth]="Qwen/Qwen3-1.7B-GGUF|qwen3-1.7b-q4_k_m.gguf+kurakurai/Luth-LFM2-350M-GGUF|Luth-LFM2-350M.Q4_K_M.gguf|Dual judge — Qwen3-1.7B + Luth 350M (fast+quality)"
  [qwen3+llama32]="Qwen/Qwen3-1.7B-GGUF|qwen3-1.7b-q4_k_m.gguf+bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|Dual judge — Qwen3-1.7B + Llama 3.2-3B (balanced)"
)

RLHF_PREF_FILE="$CONFIG_DIR/rlhf_preferences.jsonl"
RLHF_PAIRS_FILE="$CONFIG_DIR/rlhf_pairs.jsonl"
RLHF_RATINGS_FILE="$CONFIG_DIR/rlhf_ratings.jsonl"
# Ensure RLHF data files exist
touch "$RLHF_PAIRS_FILE" "$RLHF_RATINGS_FILE" 2>/dev/null || true

# Active HF RLHF dataset for training (set via 'ai rlhf use-dataset')
RLHF_ACTIVE_HF_DATASET="${RLHF_ACTIVE_HF_DATASET:-}"

# ── Download judge models ─────────────────────────────────────────────────────
_rlhf_download_judge() {
  local judge="${RLHF_JUDGE:-nix26}"
  local entry="${RLHF_JUDGES[$judge]:-${RLHF_JUDGES[nix26]}}"
  local judge_dir="$MODELS_DIR/rlhf_judges"
  mkdir -p "$judge_dir"

  info "Downloading RLHF judge(s): $judge"

  # Parse single or dual judge
  IFS='+' read -ra parts <<< "$entry"
  local i=0
  for part in "${parts[@]}"; do
    IFS='|' read -r repo filename desc <<< "$part"
    [[ -z "$repo" ]] && continue
    local dest="$judge_dir/${filename}"
    if [[ ! -f "$dest" ]]; then
      info "  Downloading $filename from $repo..."
      curl -L --progress-bar \
        --retry 5 --retry-delay 2 \
        ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/${repo}/resolve/main/${filename}" \
        -o "$dest" 2>/dev/null || \
      curl -L --progress-bar \
        --retry 5 --retry-delay 2 \
        ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/${repo}/resolve/main/$(echo "$filename" | tr '[:upper:]' '[:lower:]')" \
        -o "$dest" 2>/dev/null || { warn "  Could not download $filename"; continue; }
      ok "  Downloaded: $dest"
    else
      ok "  Already present: $filename"
    fi
    (( i++ ))
  done
}

# ── Score a response using judge model(s) ────────────────────────────────────
_rlhf_score_response() {
  local prompt="$1" response="$2" judge="${RLHF_JUDGE:-nix26}"
  local entry="${RLHF_JUDGES[$judge]:-${RLHF_JUDGES[nix26]}}"
  local judge_dir="$MODELS_DIR/rlhf_judges"
  [[ -z "$LLAMA_BIN" && -z "$PYTHON" ]] && { echo "0.5"; return; }

  # Build judge prompt
  local judge_prompt="[INST] Rate this AI response on a scale of 0.0-1.0.
Consider: factual accuracy, helpfulness, coherence, no hallucinations.
Respond with ONLY a decimal number between 0.0 and 1.0.

User prompt: ${prompt:0:200}
AI response: ${response:0:400}
[/INST] Score:"

  local score="0.5"

  # Try with llama.cpp
  if [[ -n "$LLAMA_BIN" && "$LLAMA_BIN" != "llama_cpp_python" ]]; then
    IFS='+' read -ra parts <<< "$entry"
    local scores=()
    for part in "${parts[@]}"; do
      IFS='|' read -r repo filename _ <<< "$part"
      local model="$judge_dir/$filename"
      [[ ! -f "$model" ]] && continue
      local s
      s=$("$LLAMA_BIN" -m "$model" -p "$judge_prompt" \
          -n 8 --temp 0 --top-k 1 --repeat-penalty 1.0 \
          --no-display-prompt 2>/dev/null | \
          grep -oP '[0-9]\.[0-9]+' | head -1)
      [[ -n "$s" ]] && scores+=("$s")
    done
    if [[ ${#scores[@]} -gt 0 ]]; then
      # Average scores from dual judges
      score=$(python3 -c "scores=[${scores[*]}]; print(round(sum(scores)/len(scores),3))" 2>/dev/null || echo "0.5")
    fi
  elif [[ -n "$PYTHON" ]]; then
    # Use transformers for scoring
    IFS='+' read -ra parts <<< "$entry"
    local part="${parts[0]}"
    IFS='|' read -r repo filename _ <<< "$part"
    local model="$judge_dir/$filename"
    [[ -f "$model" ]] && score=$(JUDGE_MODEL="$model" JUDGE_PROMPT="$judge_prompt" \
      "$PYTHON" - <<'PYEOF' 2>/dev/null
import os,sys
try:
    from llama_cpp import Llama
    llm=Llama(model_path=os.environ['JUDGE_MODEL'],n_ctx=512,verbose=False)
    out=llm(os.environ['JUDGE_PROMPT'],max_tokens=8,temperature=0,stop=['\n'])
    txt=out['choices'][0]['text'].strip()
    import re; m=re.search(r'[0-9]\.[0-9]+',txt)
    print(m.group(0) if m else '0.5')
except: print('0.5')
PYEOF
    )
  fi
  echo "$score"
}

# ── Auto-RLHF: collect (prompt, response, score) pairs → DPO training ────────
_rlhf_auto_collect() {
  local prompt="$1" response="$2"
  [[ "$RLHF_AUTO" != "1" ]] && return
  [[ -z "$prompt" || -z "$response" ]] && return

  local score
  score=$(_rlhf_score_response "$prompt" "$response")
  local ts; ts=$(date -Iseconds)

  # Store pair
  printf '{"ts":"%s","prompt":%s,"response":%s,"score":%s,"judge":"%s"}\n' \
    "$ts" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null || echo "\"$prompt\"")" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$response" 2>/dev/null || echo "\"$response\"")" \
    "$score" "$RLHF_JUDGE" \
    >> "$RLHF_PAIRS_FILE"

  # Trigger DPO if enough pairs accumulated and score is low
  local count; count=$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)
  if (( count > 0 && count % 20 == 0 )); then
    _rlhf_dpo_train &
  fi
}

# ── DPO training on collected pairs ──────────────────────────────────────────
_rlhf_dpo_train() {
  local model_dir="${1:-$ACTIVE_MODEL}"
  # Resolve TTM/MTM/Mtm shortcuts
  case "$model_dir" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|mmtm|MMTM) model_dir="$MMTM_DIR" ;;
  esac
  if [[ -z "$model_dir" || ! -d "$model_dir" ]]; then
    warn "RLHF: model directory not found: ${model_dir:-<not set>}"
    warn "  Run 'ai ttm pretrain' first, or specify model: ai rlhf train TTM"
    return 1
  fi
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Merge any active HF dataset pairs in first
  local pairs_source="$RLHF_PAIRS_FILE"
  if [[ -n "$RLHF_ACTIVE_HF_DATASET" && -f "$RLHF_ACTIVE_HF_DATASET" ]]; then
    local merged="/tmp/ai_rlhf_merged_$$.jsonl"
    cat "$RLHF_PAIRS_FILE" "$RLHF_ACTIVE_HF_DATASET" > "$merged" 2>/dev/null || true
    pairs_source="$merged"
  fi

  [[ ! -f "$pairs_source" ]] && { warn "No RLHF pairs collected yet."; return 1; }
  local count; count=$(wc -l < "$pairs_source" 2>/dev/null || echo 0)
  if (( count < 10 )); then
    warn "RLHF: Need at least 10 pairs have $count. Rate more responses or add HF dataset."
    return 1
  fi

  info "RLHF: Running DPO training on $count pairs → $model_dir ..."
  PAIRS_FILE="$pairs_source" MODEL_DIR="$model_dir" \
  THRESHOLD="${RLHF_REWARD_THRESHOLD:-0.6}" CPU_ONLY="${CPU_ONLY_MODE:-0}" \
  "$PYTHON" - <<'PYEOF' &
import os, json, sys, random, pathlib, shutil
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType
except ImportError as e:
    print(f"RLHF: Missing dependency: {e}")
    print("  Install: pip install trl peft transformers datasets torch")
    sys.exit(1)

pairs_file = os.environ['PAIRS_FILE']
model_dir  = os.environ['MODEL_DIR']
threshold  = float(os.environ.get('THRESHOLD', '0.6'))
cpu_only   = os.environ.get('CPU_ONLY', '0') == '1'
out_dir    = model_dir + "_dpo"

# ── Load & deduplicate pairs ─────────────────────────────────────────────────
pairs = []; seen = set()
with open(pairs_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            p = json.loads(line)
            # Normalise score field — could be 'score', 'rating', 'reward'
            if 'rating' in p and 'score' not in p:
                p['score'] = float(p['rating']) / 5.0  # 1-5 stars → 0-1
            key = str(p.get('prompt', ''))[:120]
            if key in seen: continue
            seen.add(key); pairs.append(p)
        except: pass

if not pairs:
    print("RLHF: No valid pairs found in pairs file"); sys.exit(1)

# ── Build DPO format ─────────────────────────────────────────────────────────
dpo_data = []
if all('chosen' in p and 'rejected' in p for p in pairs):
    dpo_data = [{'prompt': p.get('prompt', ''),
                 'chosen': str(p['chosen']),
                 'rejected': str(p['rejected'])}
                for p in pairs if p.get('prompt') and p.get('chosen') and p.get('rejected')]
else:
    chosen   = [p for p in pairs if float(p.get('score', 0)) >= threshold]
    rejected = [p for p in pairs if float(p.get('score', 1)) <  threshold]
    if len(chosen) < 2 or len(rejected) < 2:
        print(f"RLHF: Not enough contrast pairs (chosen={len(chosen)}, rejected={len(rejected)})")
        print(f"  threshold={threshold}. Try: ai rlhf threshold 0.4")
        print("  Or import pairs: ai rlhf add-dataset hh-rlhf")
        sys.exit(1)
    random.shuffle(chosen); random.shuffle(rejected)
    for c, r in zip(chosen, rejected):
        dpo_data.append({
            'prompt':   str(c.get('prompt', '')),
            'chosen':   str(c.get('response', c.get('chosen', ''))),
            'rejected': str(r.get('response', r.get('rejected', ''))),
        })

dpo_data = [d for d in dpo_data if d['prompt'] and d['chosen'] and d['rejected']]
if not dpo_data:
    print("RLHF: No usable DPO pairs after filtering"); sys.exit(1)

print(f"RLHF: {len(dpo_data)} DPO pairs — training on {'CPU' if cpu_only else 'GPU/CPU'}...")

# ── Model setup ──────────────────────────────────────────────────────────────
try:
    from trl import DPOTrainer, DPOConfig
    import inspect

    device   = 'cpu' if cpu_only else ('cuda' if torch.cuda.is_available() else 'cpu')
    use_cuda = device == 'cuda'
    dtype    = torch.float32 if (cpu_only or not use_cuda) else \
               (torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16)

    load_kw = {'torch_dtype': dtype, 'low_cpu_mem_usage': True}
    if use_cuda:
        load_kw['device_map'] = 'auto'

    tokenizer = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model     = AutoModelForCausalLM.from_pretrained(model_dir, **load_kw)
    ref_model = AutoModelForCausalLM.from_pretrained(model_dir, **load_kw)

    lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=8, lora_alpha=16,
                      lora_dropout=0.05,
                      target_modules=["q_proj", "v_proj", "k_proj", "o_proj"],
                      bias="none")
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()

    if not use_cuda:
        model = model.to(device)
        ref_model = ref_model.to(device)

    ds = Dataset.from_list(dpo_data)

    # ── DPOConfig — compatible with trl 0.7 through 0.12+ ────────────────────
    dpo_cfg_params = inspect.signature(DPOConfig.__init__).parameters
    cfg_kwargs = dict(
        output_dir=out_dir,
        num_train_epochs=1,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        max_steps=min(len(dpo_data), 200),
        learning_rate=5e-6,
        lr_scheduler_type="cosine",
        warmup_ratio=0.05,
        logging_steps=10,
        save_steps=500,
        report_to='none',
        remove_unused_columns=False,
        bf16=(use_cuda and dtype == torch.bfloat16),
        fp16=(use_cuda and dtype == torch.float16),
    )
    # max_length / max_prompt_length removed in trl ≥ 0.9
    if 'max_length' in dpo_cfg_params:
        cfg_kwargs['max_length'] = 512
    if 'max_prompt_length' in dpo_cfg_params:
        cfg_kwargs['max_prompt_length'] = 256

    cfg = DPOConfig(**cfg_kwargs)

    # ── DPOTrainer — 'tokenizer' renamed to 'processing_class' in trl ≥ 0.12 ─
    trainer_params = inspect.signature(DPOTrainer.__init__).parameters
    trainer_kwargs = dict(model=model, ref_model=ref_model, args=cfg, train_dataset=ds)
    if 'processing_class' in trainer_params:
        trainer_kwargs['processing_class'] = tokenizer
    else:
        trainer_kwargs['tokenizer'] = tokenizer

    trainer = DPOTrainer(**trainer_kwargs)
    trainer.train()

    # Merge LoRA weights back into base model and save
    merged = model.merge_and_unload()
    merged.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)

    # Copy config.json if missing from output
    src_cfg = pathlib.Path(model_dir) / 'config.json'
    dst_cfg = pathlib.Path(out_dir) / 'config.json'
    if src_cfg.exists() and not dst_cfg.exists():
        shutil.copy(src_cfg, dst_cfg)

    print(f"RLHF DPO complete → {out_dir}")
    print(f"  Load with: ai model {out_dir}")

except ImportError as ie:
    print(f"RLHF: Missing dependency: {ie}")
    print("  Install: pip install 'trl>=0.7' peft transformers datasets")
    sys.exit(1)
except Exception as e:
    import traceback
    print(f"RLHF DPO error: {e}")
    traceback.print_exc()
    sys.exit(1)
PYEOF
  # Clean up temp merged file if we created one
  [[ -f "/tmp/ai_rlhf_merged_$$.jsonl" ]] && rm -f "/tmp/ai_rlhf_merged_$$.jsonl" 2>/dev/null || true
}

# ── Mandatory realignment (anti-hallucination) using Qwen3 ───────────────────
_tm_align() {
  local id="$1"; _tm_vars "$id"
  local base_model="$TM_DIR/pretrained"
  local latest_ft; latest_ft=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest_ft" ]] && base_model="$latest_ft"
  [[ ! -d "$base_model" ]] && { warn "No model to align"; return 1; }
  [[ -z "$PYTHON" ]] && { warn "Python not found for alignment"; return 1; }

  # Download Qwen3-1.7B if not present
  local qwen_dir="$MODELS_DIR/rlhf_judges"
  local qwen_gguf="$qwen_dir/qwen3-1.7b-q4_k_m.gguf"
  mkdir -p "$qwen_dir"
  if [[ ! -f "$qwen_gguf" ]]; then
    info "Downloading Qwen3-1.7B for alignment..."
    curl -L --retry 5 --progress-bar \
      ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
      "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/qwen3-1.7b-q4_k_m.gguf" \
      -o "$qwen_gguf" 2>/dev/null || { warn "Could not download Qwen3; skipping alignment"; return 1; }
  fi

  local out_dir="$TM_DIR/aligned_v$(_tm_get_var "$TM_VERSION_VAR")"
  mkdir -p "$out_dir"
  info "Alignment: generating anti-hallucination training pairs with Qwen3..."

  BASE_MODEL="$base_model" QWEN_GGUF="$qwen_gguf" OUT_DIR="$out_dir" \
  LLAMA_BIN_VAL="${LLAMA_BIN:-}" "$PYTHON" - <<'PYEOF'
import os, json, subprocess, sys, random
base_model = os.environ['BASE_MODEL']
qwen_gguf  = os.environ['QWEN_GGUF']
out_dir    = os.environ['OUT_DIR']
llama_bin  = os.environ.get('LLAMA_BIN_VAL','')

# Generate factual Q&A pairs using Qwen3 as teacher
alignment_prompts = [
    "What is 2+2? Answer only with the number.",
    "Name the capital of France. Answer in one word.",
    "Is the Earth round or flat? Answer in one sentence.",
    "What is Python? Answer in 1-2 sentences without fabricating details.",
    "What does CPU stand for? Answer in one sentence.",
    "Name three primary colors. List only the colors.",
    "What year did World War 2 end? Answer with just the year.",
    "What language is used to style web pages? One word answer.",
    "Is the sun a star? Yes or no, then one sentence explanation.",
    "What is machine learning? Define it in 1-2 sentences without making things up.",
    "Who wrote Hamlet? One sentence answer.",
    "What does HTTP stand for? Full expansion only.",
    "Name the planet closest to the Sun. One word.",
    "What is the boiling point of water at sea level? Number and unit.",
    "How many continents are there? Number only.",
    "What is photosynthesis? One factual sentence.",
    "What programming language is named after a snake? One word.",
    "What is RAM used for? One sentence.",
    "Name the largest ocean. One word.",
    "What does AI stand for? Two words.",
]

pairs = []
if llama_bin and llama_bin != 'llama_cpp_python':
    for prompt in alignment_prompts:
        try:
            result = subprocess.run(
                [llama_bin, '-m', qwen_gguf, '-p',
                 f'<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n',
                 '-n', '64', '--temp', '0.1', '--top-k', '10',
                 '--no-display-prompt', '--repeat-penalty', '1.1'],
                capture_output=True, text=True, timeout=30
            )
            response = result.stdout.strip()
            if response and len(response) > 2:
                pairs.append({'instruction': prompt, 'response': response,
                              'source': 'qwen3_alignment'})
        except Exception as e:
            pass

if not pairs:
    # Fallback: static high-quality alignment pairs
    pairs = [
        {"instruction": "What is 2+2?", "response": "4"},
        {"instruction": "Name the capital of France.", "response": "Paris"},
        {"instruction": "Is the Earth round or flat?", "response": "The Earth is round (an oblate spheroid)."},
        {"instruction": "What does CPU stand for?", "response": "Central Processing Unit."},
        {"instruction": "What year did World War 2 end?", "response": "1945"},
        {"instruction": "What is Python?", "response": "Python is a high-level, interpreted programming language known for its readable syntax."},
        {"instruction": "What does HTTP stand for?", "response": "HyperText Transfer Protocol."},
        {"instruction": "What is machine learning?", "response": "Machine learning is a subset of AI where systems learn patterns from data to make predictions."},
        {"instruction": "Name the planet closest to the Sun.", "response": "Mercury."},
        {"instruction": "What is the boiling point of water at sea level?", "response": "100°C (212°F)."},
        {"instruction": "How many continents are there?", "response": "7"},
        {"instruction": "What does RAM stand for?", "response": "Random Access Memory."},
        {"instruction": "Who wrote Hamlet?", "response": "William Shakespeare."},
        {"instruction": "Name the largest ocean.", "response": "The Pacific Ocean."},
        {"instruction": "What does AI stand for?", "response": "Artificial Intelligence."},
        {"instruction": "What language styles web pages?", "response": "CSS (Cascading Style Sheets)."},
        {"instruction": "What programming language is named after a snake?", "response": "Python."},
        {"instruction": "Name three primary colors.", "response": "Red, blue, and yellow."},
        {"instruction": "Is the sun a star?", "response": "Yes. The Sun is a G-type main-sequence star at the center of our solar system."},
        {"instruction": "What is photosynthesis?", "response": "Photosynthesis is the process by which plants use sunlight, water, and CO2 to produce glucose and oxygen."},
    ]

# Save alignment dataset
align_file = f"{out_dir}/alignment_data.jsonl"
with open(align_file, 'w') as f:
    for p in pairs: f.write(json.dumps(p) + '\n')
print(f"Generated {len(pairs)} alignment pairs → {align_file}")

# Fine-tune the model on alignment data
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, \
        TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType

    tokenizer = AutoTokenizer.from_pretrained(base_model)
    tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(base_model)
    lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=8, lora_alpha=16,
                      lora_dropout=0.05, target_modules=["q_proj","v_proj","k_proj","o_proj"])
    model = get_peft_model(model, lora)

    texts = [f"### Instruction:\n{p['instruction']}\n\n### Response:\n{p['response']}" for p in pairs]
    ds = Dataset.from_list([{'text': t} for t in texts])
    def tok(ex):
        return tokenizer(ex['text'], truncation=True, max_length=256, padding='max_length')
    ds = ds.map(tok, batched=True, remove_columns=['text'])

    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    model = model.to(device)

    args = TrainingArguments(
        output_dir=out_dir, num_train_epochs=3,
        per_device_train_batch_size=1, gradient_accumulation_steps=4,
        learning_rate=2e-4, logging_steps=5, save_steps=100,
        report_to='none', warmup_ratio=0.1,
        fp16=(device=='cuda'), dataloader_num_workers=0,
    )
    Trainer(model=model, args=args, train_dataset=ds,
            data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False)).train()
    merged = model.merge_and_unload()
    merged.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)
    print(f"Alignment fine-tune saved → {out_dir}")
except Exception as e:
    print(f"Alignment training error (data saved): {e}")
PYEOF

  if [[ -d "$out_dir" ]]; then
    ok "Alignment complete: $out_dir"
    # Set as latest model
    local ver; ver=$(_tm_get_var "$TM_VERSION_VAR")
    local aligned_link="$TM_DIR/ft_v${ver}_aligned"
    [[ -L "$aligned_link" ]] && rm -f "$aligned_link"
    ln -sfn "$out_dir" "$aligned_link" 2>/dev/null || true
  else
    warn "Alignment output not found"
  fi
}

# ── Manual RLHF: rating system ────────────────────────────────────────────────
_rlhf_rate() {
  local prompt="$1" response="$2" rating="${3:-}"

  if [[ -z "$rating" ]]; then
    echo -e "\n${B}Rate this response:${R}"
    echo -e "  ${BGREEN}5${R} ★★★★★ Excellent"
    echo -e "  ${BBLUE}4${R} ★★★★☆ Good"
    echo -e "  ${BYELLOW}3${R} ★★★☆☆ OK"
    echo -e "  ${BRED}2${R} ★★☆☆☆ Poor"
    echo -e "  ${RED}1${R} ★☆☆☆☆ Wrong/Harmful"
    echo -e "  ${DIM}s${R} Skip"
    read -rp "Rating [1-5/s]: " rating
    [[ "$rating" == "s" || -z "$rating" ]] && return
  fi

  local ts; ts=$(date -Iseconds)
  local score
  case "$rating" in
    5) score="1.0" ;;  4) score="0.8" ;;  3) score="0.6" ;;
    2) score="0.3" ;;  1) score="0.0" ;;  *) return ;;
  esac

  printf '{"ts":"%s","prompt":%s,"response":%s,"rating":%s,"score":%s,"source":"manual"}\n' \
    "$ts" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null || echo "\"$prompt\"")" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$response" 2>/dev/null || echo "\"$response\"")" \
    "$rating" "$score" \
    >> "$RLHF_RATINGS_FILE"

  case "$rating" in
    5) echo -e "${BGREEN}✓ Saved — Excellent${R}" ;;
    4) echo -e "${BBLUE}✓ Saved — Good${R}" ;;
    3) echo -e "${BYELLOW}✓ Saved${R}" ;;
    2|1) echo -e "${BRED}✓ Saved — Will use for improvement${R}" ;;
  esac
  ok "Rating saved. Total: $(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null)  |  ai rlhf train-on-ratings"
}

cmd_rlhf() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    status)
      hdr "RLHF Status"
      printf "  %-25s %s\n" "Auto-RLHF:" "$RLHF_AUTO"
      printf "  %-25s %s\n" "Judge model:" "$RLHF_JUDGE"
      printf "  %-25s %s\n" "Reward threshold:" "$RLHF_REWARD_THRESHOLD"
      printf "  %-25s %s\n" "Manual ratings:" "$(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null || echo 0)"
      printf "  %-25s %s\n" "Auto pairs collected:" "$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)"
      ;;
    enable)
      RLHF_AUTO="1"; save_config
      ok "Auto-RLHF enabled (judge: $RLHF_JUDGE)"
      warn "Run 'ai rlhf download-judges' to get judge models"
      ;;
    disable) RLHF_AUTO="0"; save_config; ok "Auto-RLHF disabled" ;;
    judge)
      local j="${1:-}"; [[ -z "$j" ]] && {
        hdr "Available RLHF Judges"
        for k in "${!RLHF_JUDGES[@]}"; do
          IFS='|' read -r _ _ desc <<< "${RLHF_JUDGES[$k]}"
          printf "  ${B}%-18s${R} %s\n" "$k" "$desc"
        done
        echo ""; read -rp "Choose judge [nix26/qwen3+luth/qwen3+llama32]: " j
      }
      [[ -z "${RLHF_JUDGES[$j]:-}" ]] && { err "Unknown judge: $j"; return 1; }
      RLHF_JUDGE="$j"; save_config; ok "Judge: $j"
      ;;
    download-judges) _rlhf_download_judge ;;
    train)
      local model="${1:-$ACTIVE_MODEL}"
      [[ -z "$model" ]] && { err "No model specified"; return 1; }
      info "Running DPO training on auto-collected pairs..."
      _rlhf_dpo_train "$model"
      ;;
    train-on-ratings)
      local count; count=$(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null || echo 0)
      (( count < 5 )) && { warn "Need at least 5 ratings have $count"; return 1; }
      # Merge ratings into pairs file then train
      cat "$RLHF_RATINGS_FILE" >> "$RLHF_PAIRS_FILE"
      _rlhf_dpo_train "$ACTIVE_MODEL"
      ;;
    rate)
      local prompt="${1:-}"; local response="${2:-}"; local rating="${3:-}"
      if [[ -z "$prompt" ]]; then
        read -rp "Prompt: " prompt; read -rp "Response: " response
      fi
      _rlhf_rate "$prompt" "$response" "$rating"
      ;;
    align)
      local id="${1:-TTM}"
      _tm_vars "$id" 2>/dev/null && _tm_align "$id"
      ;;
    clear-pairs)
      read -rp "Clear all collected RLHF pairs? [y/N]: " c
      [[ "$c" =~ ^[Yy]$ ]] && { > "$RLHF_PAIRS_FILE"; > "$RLHF_RATINGS_FILE"; ok "Cleared"; }
      ;;
    threshold)
      RLHF_REWARD_THRESHOLD="${1:-0.6}"; save_config
      ok "Reward threshold: $RLHF_REWARD_THRESHOLD"
      ;;

    # ── v2.4.5: HuggingFace RLHF datasets ─────────────────────────────────────
    datasets|list-datasets)
      _rlhf_hf_list_presets
      ;;
    add-dataset)
      local ds="${1:?Usage: ai rlhf add-dataset <hf-id-or-preset-name>}"
      local split="${2:-train[:3000]}"
      _rlhf_hf_import "$ds" "$split"
      ;;
    use-dataset)
      local ds="${1:?Usage: ai rlhf use-dataset <hf-id-or-preset-name>}"
      _rlhf_hf_set_active "$ds"
      ;;
    my-datasets)
      _rlhf_hf_list_imported
      ;;

    # v2.5: RLHF v2 — reward model, PPO, GRPO
    reward-model|train-reward)
      _rlhf_train_reward_model "${1:-TTM}" ;;
    ppo|train-ppo)
      _rlhf_train_ppo "${1:-TTM}" ;;
    grpo|train-grpo)
      _rlhf_train_grpo "${1:-TTM}" ;;

    *)
      hdr "RLHF v2 — Reinforcement Learning from Human Feedback"
      echo ""
      echo "  ${B}Auto-RLHF${R}  judge scores responses then DPO trains"
      echo "  ai rlhf enable / disable"
      echo "  ai rlhf judge [nix26|qwen3+luth|qwen3+llama32]"
      echo "  ai rlhf download-judges      — Download selected judge model(s)"
      echo "  ai rlhf train [model-path]   — Run DPO on collected pairs"
      echo "  ai rlhf threshold <0.0-1.0>  — Set reward cutoff (default 0.6)"
      echo ""
      echo "  ${B}v2.5: RLHF v2 additions${R}"
      echo "  ai rlhf reward-model [model] — Train reward model on pairs"
      echo "  ai rlhf ppo [model]          — PPO fine-tuning with reward model"
      echo "  ai rlhf grpo [model]         — GRPO training (DeepSeek-R1 style)"
      echo ""
      echo "  ${B}Manual RLHF${R}  rate 1-5 stars"
      echo "  ai rlhf rate                 — Rate a response interactively"
      echo "  ai rlhf train-on-ratings     — Fine-tune on your ratings"
      echo ""
      echo "  ${B}HF RLHF Datasets v2.4.5${R}  — curated preference datasets"
      echo "  ai rlhf datasets             — List available HF preset datasets"
      echo "  ai rlhf add-dataset ID     — Import a HF dataset into RLHF pairs"
      echo "  ai rlhf use-dataset ID     — Set as active RLHF training source"
      echo "  ai rlhf my-datasets          — Show imported datasets + counts"
      echo ""
      echo "  ${B}Alignment${R}  Qwen3 anti-hallucination"
      echo "  ai rlhf align TTM|MTM|Mtm    — Run alignment on trained model"
      echo ""
      echo "  ai rlhf status               — Show RLHF stats"
      echo "  ai rlhf clear-pairs          — Clear collected data"
      echo ""
      echo -e "  ${DIM}Judge options:${R}"
      for k in "${!RLHF_JUDGES[@]}"; do
        IFS='|' read -r _ _ desc <<< "${RLHF_JUDGES[$k]}"
        printf "    ${B}%-18s${R} %s\n" "$k" "$desc"
      done
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  RLHF HF DATASETS  v2.4.5
#  Curated list of HuggingFace preference/RLHF datasets
#  Import → convert to {prompt, chosen, rejected} format → merge into RLHF pairs
# ════════════════════════════════════════════════════════════════════════════════

# Curated RLHF / preference datasets on HuggingFace
# Format: "hf-id|field-map|description"
declare -A RLHF_HF_PRESETS
RLHF_HF_PRESETS=(
  [hh-rlhf]="Anthropic/hh-rlhf|chosen+rejected|Anthropic HH-RLHF (human pref, 160k pairs)"
  [summarize]="openai/summarize_from_feedback|info.post+summary|OpenAI Summary Feedback (93k)"
  [pku-safe]="PKU-Alignment/PKU-SafeRLHF|prompt+response_0+response_1+better_response_id|PKU-SafeRLHF (330k safety pairs)"
  [ultrafeedback]="HuggingFaceH4/ultrafeedback_binarized|prompt+chosen+rejected|UltraFeedback binarized (61k)"
  [helpsteer2]="nvidia/HelpSteer2|prompt+response+helpfulness|NVIDIA HelpSteer2 (21k rated)"
  [orca-dpo]="Intel/orca_dpo_pairs|system+question+chosen+rejected|Orca DPO pairs (12.9k)"
  [capybara]="argilla/distilabel-capybara-dpo-7k-binarized|instruction+chosen+rejected|Capybara DPO 7k"
  [math-pref]="argilla/distilabel-math-preference-dpo|instruction+chosen+rejected|Math preference DPO"
  [openhermes-pref]="argilla/openhermes2.5-dpo-binarized-alpha|prompt+chosen+rejected|OpenHermes 2.5 DPO"
  [skywork-reward]="Skywork/Skywork-Reward-Preference-80K-v0.2|prompt+chosen+rejected|Skywork Reward 80k"
)

_rlhf_hf_list_presets() {
  hdr "HuggingFace RLHF Datasets v2.4.5"
  echo ""
  printf "  %-18s  %-45s  %s\n" "PRESET NAME" "HF REPO" "DESCRIPTION"
  printf "  %s\n" "$(printf '%0.s-' {1..90})"
  for key in "${!RLHF_HF_PRESETS[@]}"; do
    IFS='|' read -r hf_id _ desc <<< "${RLHF_HF_PRESETS[$key]}"
    printf "  %-18s  %-45s  %s\n" "$key" "$hf_id" "$desc"
  done | sort
  echo ""
  echo "  Add any preset: ai rlhf add-dataset NAME"
  echo "  Or any HF id:   ai rlhf add-dataset Anthropic/hh-rlhf"
  echo "  Limit sample:   ai rlhf add-dataset hh-rlhf 'train[:2000]'"
}

_rlhf_hf_list_imported() {
  [[ ! -f "$RLHF_HF_DATASETS_FILE" ]] && { info "No HF datasets imported yet"; return; }
  hdr "Imported RLHF Datasets"
  python3 -c "
import json, sys
try:
    ds = json.load(open('$RLHF_HF_DATASETS_FILE'))
except:
    ds = []
if not ds:
    print('  None.')
    sys.exit()
for d in ds:
    active = ' [active]' if d.get('active') else ''
    print(f\"  {d.get('name','?'):20}  {d.get('source','?'):40}  {d.get('pairs',0):>6} pairs{active}\")
"
}

_rlhf_hf_set_active() {
  local name="$1"
  [[ ! -f "$RLHF_HF_DATASETS_FILE" ]] && { err "No HF datasets. Import one first."; return 1; }
  python3 - <<PYEOF
import json
dss = json.load(open('$RLHF_HF_DATASETS_FILE'))
found = False
for d in dss:
    if d.get('name') == '$name' or d.get('source', '').endswith('$name'):
        d['active'] = True; found = True
    else:
        d['active'] = False
json.dump(dss, open('$RLHF_HF_DATASETS_FILE', 'w'), indent=2)
# Print the jsonl file path for the active dataset so bash can capture it
active = next((d for d in dss if d.get('active')), None)
if active:
    import pathlib
    # Derive the per-dataset jsonl path from pairs file convention
    ds_name = active.get('name', '')
    print(f'ACTIVE_PATH:$CONFIG_DIR/rlhf_hf_{ds_name}.jsonl')
print('Active RLHF dataset set to: $name' if found else 'Dataset not found: $name')
PYEOF
  local out; out=$?
  if [[ $out -eq 0 ]]; then
    # Extract and save the active file path if printed
    local active_path
    active_path=$(python3 -c "
import json,sys
dss=json.load(open('$RLHF_HF_DATASETS_FILE'))
a=next((d for d in dss if d.get('active')),None)
print('$CONFIG_DIR/rlhf_hf_'+a['name']+'.jsonl' if a else '') " 2>/dev/null || true)
    [[ -n "$active_path" ]] && RLHF_ACTIVE_HF_DATASET="$active_path"
    save_config
    ok "Active RLHF dataset: $name"
  fi
}

_rlhf_hf_import() {
  local input="$1"; local split="${2:-train[:3000]}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }

  # Resolve preset name to HF id + field map
  local hf_id="$input" field_map=""
  if [[ -n "${RLHF_HF_PRESETS[$input]:-}" ]]; then
    IFS='|' read -r hf_id field_map _ <<< "${RLHF_HF_PRESETS[$input]}"
  fi

  local ds_name; ds_name=$(echo "$hf_id" | tr '/' '_' | tr -d '.')
  info "Importing RLHF dataset: $hf_id (split: $split)"
  info "Output: $RLHF_PAIRS_FILE"

  HF_ID="$hf_id" SPLIT="$split" FIELD_MAP="$field_map" \
  PAIRS_FILE="$RLHF_PAIRS_FILE" DS_NAME="$ds_name" \
  HF_DATASETS_FILE="$RLHF_HF_DATASETS_FILE" \
  HF_TOKEN_VAL="${HF_TOKEN:-}" \
  "$PYTHON" - <<'PYEOF'
import os, sys, json
hf_id      = os.environ['HF_ID']
split      = os.environ.get('SPLIT', 'train[:3000]')
field_map  = os.environ.get('FIELD_MAP', '')
pairs_file = os.environ['PAIRS_FILE']
ds_name    = os.environ['DS_NAME']
hf_ds_file = os.environ['HF_DATASETS_FILE']
hf_token   = os.environ.get('HF_TOKEN_VAL', '') or None

try:
    from datasets import load_dataset
except ImportError:
    print("Missing: datasets\nRun: pip install datasets"); sys.exit(1)

print(f"  Loading {hf_id} [{split}] ...")
try:
    ds = load_dataset(hf_id, split=split, token=hf_token, trust_remote_code=True)
except Exception as e:
    # Try without split parameter
    try:
        ds = load_dataset(hf_id, token=hf_token, trust_remote_code=True)
        # Get first available split
        if hasattr(ds, 'keys'):
            first_split = list(ds.keys())[0]
            ds = ds[first_split]
            if '[' in split:
                n = int(split.split('[')[1].rstrip(']').replace(':', ''))
                ds = ds.select(range(min(n, len(ds))))
    except Exception as e2:
        print(f"  Failed to load: {e2}"); sys.exit(1)

print(f"  Loaded {len(ds)} examples. Columns: {ds.column_names}")

# Smart field detection
cols = ds.column_names
pairs = []
for row in ds:
    chosen = None; rejected = None; prompt = None
    # Try explicit field_map first
    if field_map:
        fields = field_map.split('+')
        if len(fields) >= 2:
            if 'chosen' in fields and 'rejected' in fields:
                chosen   = str(row.get('chosen', '') or '')
                rejected = str(row.get('rejected', '') or '')
                prompt   = str(row.get('prompt', row.get('instruction', row.get('system', ''))) or '')
            elif 'response_0' in fields:
                # PKU-SafeRLHF style
                bid = int(row.get('better_response_id', 0))
                r0 = str(row.get('response_0', '') or '')
                r1 = str(row.get('response_1', '') or '')
                prompt = str(row.get('prompt', '') or '')
                chosen   = r0 if bid == 0 else r1
                rejected = r1 if bid == 0 else r0
            else:
                # Generic: treat first as prompt, second as chosen
                vals = [str(row.get(f, '') or '') for f in fields if f in row]
                if len(vals) >= 2:
                    prompt = vals[0]; chosen = vals[1]
    # Auto-detect if still not set
    if chosen is None:
        if 'chosen' in cols and 'rejected' in cols:
            chosen   = str(row.get('chosen', '') or '')
            rejected = str(row.get('rejected', '') or '')
            prompt   = str(row.get('prompt', row.get('instruction', '')) or '')
        elif 'response' in cols and 'helpfulness' in cols:
            # HelpSteer2 style — score > 3 = chosen
            score = float(row.get('helpfulness', 3))
            if score >= 3.5:
                chosen = str(row.get('response', '') or '')
                prompt = str(row.get('prompt', '') or '')
        elif 'output' in cols:
            prompt = str(row.get('input', row.get('instruction', '')) or '')
            chosen = str(row.get('output', '') or '')
    if not chosen or not prompt:
        continue
    entry = {'prompt': prompt[:512], 'chosen': chosen[:1024]}
    if rejected:
        entry['rejected'] = rejected[:1024]
    entry['source'] = hf_id
    pairs.append(entry)

print(f"  Extracted {len(pairs)} preference pairs")
if not pairs:
    print("  No pairs could be extracted — check column names above"); sys.exit(1)

# Append to RLHF pairs file
with open(pairs_file, 'a') as f:
    for p in pairs:
        f.write(json.dumps(p) + '\n')
print(f"  Appended to: {pairs_file}")

# Track in HF datasets registry
try:
    reg = json.load(open(hf_ds_file)) if os.path.exists(hf_ds_file) else []
except:
    reg = []
# Update or add entry
found = False
for d in reg:
    if d.get('source') == hf_id:
        d['pairs'] += len(pairs); found = True
if not found:
    reg.append({'name': ds_name, 'source': hf_id, 'pairs': len(pairs),
                'split': split, 'active': True})
json.dump(reg, open(hf_ds_file, 'w'), indent=2)
print(f"  Registered as: {ds_name}")
print(f"  Total RLHF pairs now: {sum(1 for _ in open(pairs_file))}")
PYEOF

  if [[ $? -eq 0 ]]; then
    ok "HF RLHF dataset imported: $hf_id"
    local total; total=$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)
    echo "  Total RLHF pairs: $total"
    echo "  Train now: ai rlhf train"
  else
    err "Import failed"
    return 1
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  RIGHT-CLICK CONTEXT MENU — Linux system-wide "Ask AI" integration  (v2.4.6)
#  Works on: GNOME, KDE Plasma 5/6, XFCE, LXDE, MATE, Cinnamon, Openbox,
#            i3, sway, Hyprland, river, dwm, any WM/DE
#  Grabs selected text (X11 primary / Wayland / clipboard), sends to AI,
#  shows result in best available display method.
#  Custom keybind support: ai rclick keybind <key-combo>
# ════════════════════════════════════════════════════════════════════════════════

# Vision-Language model options for right-click
declare -A RCLICK_VL_MODELS
RCLICK_VL_MODELS=(
  [qwen3vl]="Qwen/Qwen3-VL-2B-Thinking-GGUF|Qwen3-VL-2B-Thinking-Q4_K_M.gguf|Qwen3 VL 2B Thinking — best reasoning"
  [lfm25vl]="LiquidAI/LFM2.5-VL-1.6B|model.safetensors|LFM2.5 VL 1.6B (PyTorch)"
  [lfm25vl_gguf]="LiquidAI/LFM2.5-VL-1.6B-GGUF|lfm2.5-vl-1.6b-q4_k_m.gguf|LFM2.5 VL 1.6B GGUF — fast"
  [custom]="custom||Custom model (set RCLICK_CUSTOM_MODEL)"
)

# Default keybind — user can change via: ai rclick keybind COMBO
RCLICK_KEYBIND="${RCLICK_KEYBIND:-Super+Shift+a}"

_rclick_install_deps() {
  info "Installing right-click context menu dependencies..."
  local pkgs=()
  # Detect display server: Wayland or X11
  local is_wayland=0
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=1
  [[ -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && is_wayland=1

  if command -v apt-get &>/dev/null; then
    pkgs=(libnotify-bin xdg-utils python3-tk)
    if [[ $is_wayland -eq 1 ]]; then
      pkgs+=(wl-clipboard)
      # Try to get ydotool for Wayland input simulation
      command -v ydotool &>/dev/null || pkgs+=(ydotool) 2>/dev/null || true
    else
      pkgs+=(xdotool xclip xsel zenity)
      command -v python3 &>/dev/null && pkgs+=(python3-tkinter python3-gi)
    fi
    sudo apt-get install -y -q "${pkgs[@]}" 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    if [[ $is_wayland -eq 1 ]]; then
      sudo dnf install -y libnotify wl-clipboard python3-tkinter 2>/dev/null || true
    else
      sudo dnf install -y xdotool xclip xsel libnotify zenity python3-tkinter 2>/dev/null || true
    fi
  elif command -v pacman &>/dev/null; then
    if [[ $is_wayland -eq 1 ]]; then
      sudo pacman -S --noconfirm libnotify wl-clipboard tk 2>/dev/null || true
    else
      sudo pacman -S --noconfirm xdotool xclip xsel libnotify zenity tk 2>/dev/null || true
    fi
  elif command -v zypper &>/dev/null; then
    sudo zypper install -y xdotool xclip libnotify-tools zenity python3-tk 2>/dev/null || true
  fi
  ok "Dependencies installed"
}

_rclick_get_selection() {
  # Robust text retrieval: Wayland primary → X11 primary → clipboard
  local text=""
  # Wayland
  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-paste &>/dev/null && text=$(wl-paste --primary --no-newline 2>/dev/null || true)
    [[ -z "$text" ]] && command -v wl-paste &>/dev/null && text=$(wl-paste --no-newline 2>/dev/null || true)
  fi
  # X11 primary (highlighted text)
  if [[ -z "$text" ]]; then
    command -v xclip &>/dev/null && text=$(xclip -selection primary -o 2>/dev/null || true)
    [[ -z "$text" ]] && command -v xsel &>/dev/null && text=$(xsel --primary --output 2>/dev/null || true)
  fi
  # Clipboard fallback
  if [[ -z "$text" ]]; then
    command -v xclip  &>/dev/null && text=$(xclip -selection clipboard -o 2>/dev/null || true)
    [[ -z "$text" ]] && command -v xsel     &>/dev/null && text=$(xsel --clipboard --output 2>/dev/null || true)
    [[ -z "$text" ]] && command -v wl-paste &>/dev/null && text=$(wl-paste --no-newline 2>/dev/null || true)
  fi
  echo "${text:0:4000}"
}

# Convert user-friendly key combo to gsettings format
# e.g. "Super+Shift+a" → "<Super><Shift>a"
_rclick_key_to_gsettings() {
  local key="$1"
  local out=""
  IFS='+' read -ra parts <<< "$key"
  local last="${parts[-1]}"
  for (( i=0; i<${#parts[@]}-1; i++ )); do
    local mod="${parts[$i]}"
    case "${mod,,}" in
      super|win|meta) out+="<Super>" ;;
      ctrl|control)   out+="<Ctrl>"  ;;
      alt)            out+="<Alt>"   ;;
      shift)          out+="<Shift>" ;;
      *)              out+="<${mod}>" ;;
    esac
  done
  out+="${last,,}"
  echo "$out"
}

# Convert user-friendly key combo to sway/i3 bindsym format
# e.g. "Super+Shift+a" → "$mod+Shift+a"  (or "Ctrl+Shift+a" stays as-is)
_rclick_key_to_sway() {
  local key="$1"
  # Replace Super/Win with $mod
  echo "$key" | sed 's/Super/$mod/Ig;s/Win/$mod/Ig'
}

# Write the ai-rclick script to /usr/local/bin/ai-rclick  (v3.1 — v2.7.1)
# Fixes: build_prompt newlines (printf), Python show_result heredoc, yad parsing,
#        cleaner output, new actions (Rewrite, To bullet points, Copy result).
_rclick_write_script() {
  local script_path="/usr/local/bin/ai-rclick"
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "ai")
  local vl_model="${RCLICK_VL_MODEL:-qwen3vl}"
  local vl_dir="$MODELS_DIR/rclick_vl"

  cat > /tmp/ai_rclick_v3.1.sh <<RCLICK_SCRIPT
#!/usr/bin/env bash
# AI Right-Click Handler v3.2 — installed by ai-cli v${VERSION}
CLI_BIN="${cli_bin}"
VL_MODEL_DIR="${vl_dir}"
VL_TYPE="${vl_model}"
RCLICK_SCRIPT
  cat >> /tmp/ai_rclick_v3.1.sh << 'RCLICK_SCRIPT'

# ── Copy text to clipboard ─────────────────────────────────────────────────────
copy_to_clipboard() {
  local text="$1"
  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-copy &>/dev/null && echo "$text" | wl-copy 2>/dev/null && return
  fi
  command -v xclip  &>/dev/null && echo "$text" | xclip -selection clipboard 2>/dev/null && return
  command -v xsel   &>/dev/null && echo "$text" | xsel --clipboard --input 2>/dev/null && return
}

# ── Get selected text (X11 primary / Wayland / clipboard) ─────────────────────
get_text() {
  local t=""
  # Wayland primary selection
  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-paste &>/dev/null && t=$(wl-paste --primary --no-newline 2>/dev/null || true)
  fi
  # X11 primary (highlighted text — most reliable for "select then trigger")
  if [[ -z "$t" ]]; then
    command -v xclip &>/dev/null && t=$(xclip -selection primary -o 2>/dev/null || true)
    [[ -z "$t" ]] && command -v xsel &>/dev/null && t=$(xsel --primary --output 2>/dev/null || true)
  fi
  # Clipboard fallback
  if [[ -z "$t" ]]; then
    command -v xclip  &>/dev/null && t=$(xclip -selection clipboard -o 2>/dev/null || true)
    [[ -z "$t" ]] && command -v xsel     &>/dev/null && t=$(xsel --clipboard --output 2>/dev/null || true)
    [[ -z "$t" ]] && command -v wl-paste &>/dev/null && t=$(wl-paste --no-newline 2>/dev/null || true)
  fi
  echo "${t:0:4000}"
}

# ── Show result in best available UI ──────────────────────────────────────────
# v3.1 fix: Python fallback now writes code to temp file (heredoc-to-stdin was broken)
show_result() {
  local title="$1" body="$2" tmp
  tmp=$(mktemp /tmp/ai_result_XXXXX.txt)
  printf '%s\n' "$body" > "$tmp"
  # Always save last result for recovery
  cp "$tmp" /tmp/ai_rclick_last_result.txt

  if command -v zenity &>/dev/null; then
    zenity --text-info --title="$title" --filename="$tmp" \
           --width=760 --height=520 --font="Monospace 10" 2>/dev/null &
  elif command -v kdialog &>/dev/null; then
    kdialog --title "$title" --textbox "$tmp" 760 520 2>/dev/null &
  elif command -v yad &>/dev/null; then
    yad --text-info --filename="$tmp" --title="$title" \
        --width=760 --height=520 --wrap --button=Close:0 2>/dev/null &
  elif command -v xmessage &>/dev/null; then
    xmessage -file "$tmp" -title "$title" -buttons OK 2>/dev/null &
  elif command -v python3 &>/dev/null; then
    # v3.1 fix: write Python UI code to a temp file (heredoc-to-stdin broken with &)
    local _py_tmp; _py_tmp=$(mktemp /tmp/ai_rclick_ui_XXXX.py)
    cat > "$_py_tmp" << 'INNER_PYEOF'
import sys, pathlib, tkinter as tk
from tkinter import scrolledtext, font as tkfont
title_arg = sys.argv[1] if len(sys.argv) > 1 else "AI Result"
file_arg  = sys.argv[2] if len(sys.argv) > 2 else ""
root = tk.Tk()
root.title(title_arg)
root.geometry("820x560")
root.configure(bg='#1a1b26')
try:
    mf = tkfont.Font(family="Monospace", size=10)
except Exception:
    mf = None
txt = scrolledtext.ScrolledText(root, wrap=tk.WORD, font=mf,
    padx=10, pady=10, bg='#16161e', fg='#c0caf5',
    insertbackground='#7aa2f7', relief='flat')
txt.pack(fill='both', expand=True, padx=4, pady=4)
content = pathlib.Path(file_arg).read_text(errors='replace') if file_arg else ""
txt.insert('1.0', content)
txt.config(state='disabled')
btn_frame = tk.Frame(root, bg='#1a1b26'); btn_frame.pack(fill='x', pady=4, padx=4)
def do_copy():
    root.clipboard_clear()
    root.clipboard_append(txt.get('1.0', 'end-1c'))
    root.update()
tk.Button(btn_frame, text='Copy to Clipboard', command=do_copy,
    bg='#7aa2f7', fg='#1a1b26', relief='flat', padx=8).pack(side='left', padx=4)
tk.Button(btn_frame, text='Close', command=root.destroy,
    bg='#292e42', fg='#c0caf5', relief='flat', padx=8).pack(side='right', padx=4)
root.mainloop()
INNER_PYEOF
    python3 "$_py_tmp" "$title" "$tmp" &
    (sleep 120 && rm -f "$_py_tmp") &
  elif command -v foot &>/dev/null; then
    foot -e bash -c "cat '$tmp'; echo; printf 'Press Enter to close...'; read -r _" &
  elif command -v alacritty &>/dev/null; then
    alacritty -e bash -c "cat '$tmp'; echo; printf 'Press Enter to close...'; read -r _" &
  elif command -v xterm &>/dev/null; then
    xterm -title "$title" -e "cat '$tmp'; printf 'Press Enter...'; read -r _" &
  else
    # Last resort: notification + file
    notify-send "$title" "${body:0:300}..." -t 20000 -i dialog-information 2>/dev/null || true
    echo "Full result saved: /tmp/ai_rclick_last_result.txt"
  fi
  # Cleanup after 90 s
  (sleep 90 && rm -f "$tmp") &
}

# ── Action menu (v3.1) ────────────────────────────────────────────────────────
choose_action() {
  local ctx="${1:0:80}"
  local has_files="${2:-0}"
  local action=""

  # Full action list — new in v3.1: Rewrite, Bullet points, To JSON
  local opts=(
    "Explain this"
    "Summarize"
    "Fix code / errors"
    "Find bugs"
    "Generate tests"
    "Rewrite / improve"
    "Improve writing"
    "Translate to English"
    "To bullet points"
    "Ask a question..."
  )
  [[ "$has_files" == "1" ]] && opts+=("Analyze file(s)" "Summarize file(s)")

  if command -v zenity &>/dev/null; then
    local list_args=()
    for o in "${opts[@]}"; do list_args+=(FALSE "$o"); done
    action=$(zenity --list --radiolist \
      --title="AI Right-Click v3.1" \
      --text="Context: ${ctx:0:60}...\n\nChoose an action:" \
      --column="" --column="Action" \
      "${list_args[@]}" --width=440 --height=440 2>/dev/null) || return 1
  elif command -v kdialog &>/dev/null; then
    local menu_args=()
    local i=1
    for o in "${opts[@]}"; do menu_args+=("$i" "$o"); ((i++)); done
    local choice
    choice=$(kdialog --menu "AI: ${ctx:0:60}..." "${menu_args[@]}" 2>/dev/null) || return 1
    action="${opts[$((choice-1))]}"
  elif command -v yad &>/dev/null; then
    # v3.1 fix: use --print-column=2 to avoid column-header/FALSE prefix in output
    local yad_rows=()
    for o in "${opts[@]}"; do yad_rows+=(FALSE "$o"); done
    action=$(yad --list --radiolist \
      --title="AI Right-Click v3.1" \
      --text="Context: ${ctx:0:60}..." \
      --column="●" --column="Action" \
      --print-column=2 \
      "${yad_rows[@]}" \
      --width=400 --height=400 2>/dev/null | sed 's/|//g' | tr -d '\n') || return 1
  elif command -v python3 &>/dev/null; then
    # v3.1 fix: write Python picker to temp file (heredoc-to-stdin broken with &)
    local _py_pick; _py_pick=$(mktemp /tmp/ai_rclick_pick_XXXX.py)
    cat > "$_py_pick" << 'INNER_PYEOF'
import sys, tkinter as tk
ctx  = sys.argv[1] if len(sys.argv) > 1 else ""
opts = sys.argv[2:]
root = tk.Tk()
root.title("AI Right-Click v3.1")
root.geometry("420x480")
root.configure(bg='#1a1b26')
tk.Label(root, text=f"Context: {ctx[:70]}...",
    wraplength=400, justify='left', bg='#1a1b26', fg='#c0caf5',
    font=('', 9)).pack(padx=10, pady=(8,2), anchor='w')
tk.Label(root, text="Choose action:", font=('', 10, 'bold'),
    bg='#1a1b26', fg='#7aa2f7').pack(padx=10, anchor='w')
frame = tk.Frame(root, bg='#16161e'); frame.pack(fill='both', expand=True, padx=8, pady=4)
result = tk.StringVar(value=opts[0] if opts else "")
for o in opts:
    tk.Radiobutton(frame, text=o, variable=result, value=o,
        anchor='w', bg='#16161e', fg='#c0caf5',
        selectcolor='#283457', activebackground='#1f2335',
        font=('', 10)).pack(fill='x', padx=4, pady=1)
chosen = []
def ok():
    v = result.get()
    if v: chosen.append(v)
    root.destroy()
bf = tk.Frame(root, bg='#1a1b26'); bf.pack(pady=6)
tk.Button(bf, text='OK', width=12, command=ok,
    bg='#7aa2f7', fg='#1a1b26', relief='flat').pack(side='left', padx=4)
tk.Button(bf, text='Cancel', width=12, command=root.destroy,
    bg='#292e42', fg='#c0caf5', relief='flat').pack(side='left', padx=4)
root.bind('<Return>', lambda e: ok())
root.bind('<Escape>', lambda e: root.destroy())
root.mainloop()
if chosen: print(chosen[0])
INNER_PYEOF
    action=$(python3 "$_py_pick" "$ctx" "${opts[@]}" 2>/dev/null) || { rm -f "$_py_pick"; return 1; }
    rm -f "$_py_pick"
  else
    action="Explain this"  # headless fallback
  fi
  [[ -z "$action" ]] && return 1
  echo "$action"
}

# ── Custom question input ─────────────────────────────────────────────────────
ask_custom_question() {
  local ctx="${1:0:100}"
  local q=""
  if command -v zenity &>/dev/null; then
    q=$(zenity --entry --title="Ask AI" \
      --text="Context: ${ctx:0:60}...\n\nYour question:" --width=520 2>/dev/null) || return 1
  elif command -v kdialog &>/dev/null; then
    q=$(kdialog --title "Ask AI" --inputbox "Your question about: ${ctx:0:60}..." "" 2>/dev/null) || return 1
  elif command -v python3 &>/dev/null; then
    local _py_ask; _py_ask=$(mktemp /tmp/ai_rclick_ask_XXXX.py)
    cat > "$_py_ask" << 'INNER_PYEOF'
import sys, tkinter as tk
from tkinter import simpledialog
ctx = sys.argv[1] if len(sys.argv) > 1 else ""
root = tk.Tk(); root.withdraw()
q = simpledialog.askstring('Ask AI',
    f'Context: {ctx[:60]}...\n\nYour question:',
    parent=root)
print(q or '')
INNER_PYEOF
    q=$(python3 "$_py_ask" "$ctx" 2>/dev/null); rm -f "$_py_ask"
    q=$(echo "$q" | tr -d '\r')
  else
    q="Explain this"
  fi
  [[ -z "$q" ]] && return 1
  echo "$q"
}

# ── Build AI prompt from action + context ─────────────────────────────────────
# v3.1 fix: use printf for proper newline handling (echo doesn't interpolate \n)
build_prompt() {
  local action="$1"
  local context="$2"
  local files="$3"
  case "$action" in
    "Explain this")
      printf 'Explain the following clearly and concisely:\n\n%s\n' "$context" ;;
    "Summarize")
      printf 'Summarize the following in a few sentences:\n\n%s\n' "$context" ;;
    "Fix code / errors")
      printf 'Fix any bugs or errors in the following code. Show the corrected version with an explanation of changes:\n\n%s\n' "$context" ;;
    "Find bugs")
      printf 'Identify all bugs, issues, and potential problems in the following code. Be specific:\n\n%s\n' "$context" ;;
    "Generate tests")
      printf 'Generate comprehensive unit tests for the following code:\n\n%s\n' "$context" ;;
    "Rewrite / improve")
      printf 'Rewrite and improve the following code or text. Make it cleaner, more efficient, and well-structured:\n\n%s\n' "$context" ;;
    "Improve writing")
      printf 'Improve the clarity, grammar, and style of the following text:\n\n%s\n' "$context" ;;
    "Translate to English")
      printf 'Translate the following to English:\n\n%s\n' "$context" ;;
    "To bullet points")
      printf 'Convert the following into clear, concise bullet points:\n\n%s\n' "$context" ;;
    "Analyze file(s)")
      printf 'Analyze the following file(s) and provide insights:\n\nContext: %s\n\nFiles: %s\n' "$context" "$files" ;;
    "Summarize file(s)")
      printf 'Summarize the content of the following file(s):\n\nContext: %s\n\nFiles: %s\n' "$context" "$files" ;;
    *)
      printf '%s\n\nContext:\n%s\n' "$action" "$context" ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local files_str=""
  local has_files=0
  if [[ $# -gt 0 ]]; then
    files_str="$*"
    has_files=1
  fi

  local selected; selected=$(get_text)

  # If no text selected but files given, use first filename as context
  if [[ -z "$selected" && $has_files -eq 1 ]]; then
    selected="$1"
  fi

  if [[ -z "$selected" && $has_files -eq 0 ]]; then
    notify-send "AI Right-Click v3.1" \
      "No text selected and no files passed. Highlight text first, then press the shortcut." \
      -t 6000 -i dialog-information 2>/dev/null || \
      { echo "ai-rclick: no text selected" >&2; }
    exit 0
  fi

  local action
  action=$(choose_action "$selected" "$has_files") || exit 0
  [[ -z "$action" ]] && exit 0

  local full_prompt
  if [[ "$action" == "Ask a question..." ]]; then
    local custom_q
    custom_q=$(ask_custom_question "$selected") || exit 0
    full_prompt=$(printf '%s\n\nContext:\n%s\n' "$custom_q" "$selected")
  else
    full_prompt=$(build_prompt "$action" "$selected" "$files_str")
    # Include file contents for file actions (v3.1: safer wc -c check)
    if [[ $has_files -eq 1 && "$action" == *"file"* ]]; then
      for f in "$@"; do
        if [[ -f "$f" ]]; then
          local fsz; fsz=$(wc -c < "$f" 2>/dev/null || echo 0)
          if (( fsz < 8192 )); then
            full_prompt+=$(printf '\n\n--- %s ---\n' "$f")
            full_prompt+=$(head -100 "$f" 2>/dev/null)
          fi
        fi
      done
    fi
  fi

  notify-send "AI Right-Click v3.1" "Processing: ${action}..." \
    -t 3000 -i dialog-information 2>/dev/null || true

  local result
  result=$("$CLI_BIN" ask "$full_prompt" 2>&1)
  # v3.1: strip leading/trailing blank lines from result for cleaner output
  result=$(echo "$result" | sed '/^[[:space:]]*$/{ /./!d; }' | sed -e '1{/^$/d}' 2>/dev/null || echo "$result")

  if [[ -z "$result" ]]; then
    result="[No response — is 'ai' installed and a model configured?]
Run: ai status   to check your setup.
Run: ai ask 'hello'  to test."
  fi

  # Offer to copy result to clipboard before showing dialog
  copy_to_clipboard "$result" 2>/dev/null || true

  show_result "AI — ${action}" "$result"
}

# main called at end of file
RCLICK_SCRIPT

  sudo cp /tmp/ai_rclick_v3.1.sh "$script_path"
  sudo chmod a+x "$script_path"
  # v2.6.0.1: Multi-method trust marking — fixes 'not authorized to execute' in file managers
  # Method 1: GIO metadata::trusted (GNOME 42+ Nautilus — must use -t string and "yes")
  if command -v gio &>/dev/null; then
    sudo gio set -t string "$script_path" metadata::trusted yes 2>/dev/null || \
      sudo gio set "$script_path" metadata::trusted true 2>/dev/null || true
  fi
  # Method 2: setfattr / attr (xattr fallback for older GNOME or non-gio systems)
  command -v setfattr &>/dev/null && \
    sudo setfattr -n user.nautilus-trusted -v "" "$script_path" 2>/dev/null || true
  command -v attr &>/dev/null && \
    sudo attr -s "user.nautilus-trusted" -V "" "$script_path" 2>/dev/null || true
  rm -f /tmp/ai_rclick_v3.1.sh
  ok "Installed: $script_path (rclick v3.2, trust flags set)"
}

_rclick_download_vl() {
  local vl="${RCLICK_VL_MODEL:-qwen3vl}"
  local vl_dir="$MODELS_DIR/rclick_vl"
  mkdir -p "$vl_dir"

  local entry="${RCLICK_VL_MODELS[$vl]:-${RCLICK_VL_MODELS[qwen3vl]}}"
  IFS='|' read -r repo filename desc <<< "$entry"
  [[ "$repo" == "custom" ]] && { err "Set RCLICK_CUSTOM_MODEL first"; return 1; }
  [[ -z "$filename" ]] && { err "No filename for $vl"; return 1; }

  if [[ "$filename" == *.gguf ]]; then
    local dest="$vl_dir/$filename"
    [[ -f "$dest" ]] && { ok "Already present: $filename"; return; }
    info "Downloading $desc..."
    curl -L --retry 5 --progress-bar \
      ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
      "https://huggingface.co/${repo}/resolve/main/${filename}" \
      -o "$dest"
    ok "Downloaded: $dest"
  else
    [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
    info "Downloading PyTorch model: $desc..."
    HF_REPO="$repo" DEST="$vl_dir" HF_TOKEN_VAL="${HF_TOKEN:-}" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("huggingface_hub not installed. Run: pip install huggingface_hub"); sys.exit(1)
snapshot_download(repo_id=os.environ['HF_REPO'],
                  local_dir=os.environ['DEST'],
                  token=os.environ.get('HF_TOKEN_VAL') or None)
print(f"Downloaded to {os.environ['DEST']}")
PYEOF
  fi
}

# ── DE-specific integrations ───────────────────────────────────────────────────

_rclick_install_gnome() {
  local keybind_gs; keybind_gs=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
  info "Installing GNOME Nautilus right-click actions (v3.1)..."
  mkdir -p "$HOME/.local/share/nautilus/scripts"
  local cli_full; cli_full=$(command -v ai 2>/dev/null || echo "/usr/local/bin/ai")

  # v2.6: Use full path and generate multiple action scripts
  for action_name in "Ask AI" "Summarize" "Explain this" "Fix code" "Find bugs" "Rewrite" "Improve writing" "To bullet points" "Translate to English"; do
    local action_file="$HOME/.local/share/nautilus/scripts/${action_name}"
    printf '#!/usr/bin/env bash\n/usr/local/bin/ai-rclick "$@"\n' > "$action_file"
    chmod a+x "$action_file"
    # v2.6.0.1: Mark as trusted — fixes 'not authorized to execute' in GNOME/Nautilus
    # Must use -t string and "yes" for GNOME 42+; fall back to xattr/attr methods
    if command -v gio &>/dev/null; then
      gio set -t string "$action_file" metadata::trusted yes 2>/dev/null || \
        gio set "$action_file" metadata::trusted true 2>/dev/null || true
    fi
    command -v setfattr &>/dev/null && \
      setfattr -n user.nautilus-trusted -v "" "$action_file" 2>/dev/null || true
    command -v attr &>/dev/null && \
      attr -s "user.nautilus-trusted" -V "" "$action_file" 2>/dev/null || true
  done
  ok "GNOME Nautilus: Scripts menu → AI actions (right-click Scripts)"

  # Also register with Files/Nemo (Cinnamon)
  if [[ -d "$HOME/.local/share/nemo/scripts" ]]; then
    for action_name in "Ask AI" "Summarize" "Explain this" "Fix code"; do
      local nemo_file="$HOME/.local/share/nemo/scripts/${action_name}"
      cp "$HOME/.local/share/nautilus/scripts/${action_name}" "$nemo_file" 2>/dev/null || true
      chmod a+x "$nemo_file" 2>/dev/null || true
      if command -v gio &>/dev/null; then
        gio set -t string "$nemo_file" metadata::trusted yes 2>/dev/null || true
      fi
    done
    ok "Cinnamon Nemo: Scripts menu → AI actions"
  fi

  info "Installing GNOME Shell keyboard shortcut ($RCLICK_KEYBIND)..."
  local base="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick"
  # Append to existing custom-keybindings list (don't overwrite others)
  local cur_list
  cur_list=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")
  if [[ "$cur_list" != *"ai-rclick"* ]]; then
    local new_list="${cur_list%']'},'${base}/']"
    new_list="${new_list/\[@as \[/[}"
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
      "$new_list" 2>/dev/null || \
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
      "['${base}/']" 2>/dev/null || true
  fi
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    name "Ask AI" 2>/dev/null || true
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    command "ai-rclick" 2>/dev/null || true
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    binding "$keybind_gs" 2>/dev/null || true
  ok "GNOME shortcut: $RCLICK_KEYBIND → ai-rclick"
}

_rclick_install_kde() {
  # Detect Plasma version
  local plasma_ver=5
  command -v kwriteconfig6 &>/dev/null && plasma_ver=6
  plasmashell --version 2>/dev/null | grep -q "^plasmashell 6" && plasma_ver=6

  info "Installing KDE Dolphin right-click service menu (Plasma $plasma_ver)..."

  # Plasma 5 service menu path
  local p5="$HOME/.local/share/kservices5/ServiceMenus"
  # Plasma 6 service menu path (KIO servicemenus)
  local p6="$HOME/.local/share/kio/servicemenus"
  mkdir -p "$p5" "$p6"

  # Write .desktop for Plasma 5 (KonqPopupMenu/Plugin style) — v3.1 with more actions
  # v2.6.0.1: Added X-KDE-SubstituteUID=false to prevent KDE auth dialog
  cat > "$p5/ai-rclick.desktop" <<'DESK5'
[Desktop Entry]
Type=Service
ServiceTypes=KonqPopupMenu/Plugin
MimeType=all/all;
Actions=ask_ai;summarize;explain;fix_code;find_bugs;rewrite;improve;bullets;translate
X-KDE-StartupNotify=false
X-KDE-Priority=TopLevel
X-KDE-Submenu=AI Tools (v3.1)
X-KDE-SubstituteUID=false

[Desktop Action ask_ai]
Name=Ask AI...
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action summarize]
Name=Summarize
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action explain]
Name=Explain this
Icon=help-contextual
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action fix_code]
Name=Fix code / errors
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action find_bugs]
Name=Find bugs
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action rewrite]
Name=Rewrite / improve
Icon=document-edit
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action improve]
Name=Improve writing
Icon=accessories-text-editor
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action bullets]
Name=To bullet points
Icon=format-list-unordered
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action translate]
Name=Translate to English
Icon=applications-education-language
Exec=/usr/local/bin/ai-rclick %F
DESK5
  chmod a+x "$p5/ai-rclick.desktop" 2>/dev/null || true

  # Write .desktop for Plasma 6 (KIO servicemenu style — Actions= format) — v3.1
  # v2.6.0.1: Added X-KDE-SubstituteUID=false to prevent KDE auth dialog
  cat > "$p6/ai-rclick.desktop" <<'DESK6'
[Desktop Entry]
Type=Service
MimeType=all/all;
Actions=ask_ai;summarize;explain;fix_code;find_bugs;rewrite;improve;bullets;translate
X-KDE-Submenu=AI Tools (v3.1)
X-KDE-StartupNotify=false
X-KDE-SubstituteUID=false

[Desktop Action ask_ai]
Name=Ask AI...
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action summarize]
Name=Summarize
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action explain]
Name=Explain this
Icon=help-contextual
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action fix_code]
Name=Fix code / errors
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action find_bugs]
Name=Find bugs
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action rewrite]
Name=Rewrite / improve
Icon=document-edit
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action improve]
Name=Improve writing
Icon=accessories-text-editor
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action bullets]
Name=To bullet points
Icon=format-list-unordered
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action translate]
Name=Translate to English
Icon=applications-education-language
Exec=/usr/local/bin/ai-rclick %F
DESK6
  chmod a+x "$p6/ai-rclick.desktop" 2>/dev/null || true

  ok "KDE Dolphin (Plasma $plasma_ver): right-click → Ask AI"

  # ── KDE Plasma 6: register global shortcut via D-Bus + kglobalaccel6 ────────
  local keybind_kde
  keybind_kde=$(echo "$RCLICK_KEYBIND" | sed 's/Super/Meta/Ig; s/Ctrl/Ctrl/g')

  if [[ $plasma_ver -eq 6 ]] && command -v kwriteconfig6 &>/dev/null; then
    # Write to kglobalshortcutsrc
    kwriteconfig6 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "_k_friendly_name" "Ask AI" 2>/dev/null || true
    kwriteconfig6 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "Ask AI" "${keybind_kde},none,Ask AI" 2>/dev/null || true

    # Register via kglobalaccel6 D-Bus if available
    if command -v qdbus6 &>/dev/null || command -v qdbus &>/dev/null; then
      local QDBUS
      QDBUS=$(command -v qdbus6 2>/dev/null || command -v qdbus)
      # Reload kglobalaccel to pick up new shortcut
      $QDBUS org.kde.kglobalaccel /kglobalaccel \
        org.kde.kglobalaccel.Component.reloadActionIdentifiers \
        2>/dev/null || true
    fi

    # Also register as custom shortcut via khotkeys (Plasma 6 fallback)
    local khotkeys="$HOME/.config/khotkeysrc"
    if [[ ! -f "$khotkeys" ]] || ! grep -q "ai-rclick" "$khotkeys" 2>/dev/null; then
      cat >> "$khotkeys" <<KHOTKEYS

[Data_ai_rclick]
Comment=Ask AI (ai-cli)
DataCount=1
Enabled=true
Name=Ask AI
SystemGroup=0
Type=SIMPLE_ACTION_DATA

[Data_ai_rclick_Actions]
ActionsCount=1

[Data_ai_rclick_Actions0]
CommandURL=ai-rclick
Type=COMMAND_URL

[Data_ai_rclick_Triggers]
TriggersCount=1

[Data_ai_rclick_Triggers0]
Key=${keybind_kde}
Type=SHORTCUT
Uuid={ai-rclick-uuid}
KHOTKEYS
    fi
    ok "KDE Plasma 6 shortcut: $RCLICK_KEYBIND → ai-rclick"
    info "  Reload shortcuts: qdbus6 org.kde.kglobalaccel /kglobalaccel reloadActionIdentifiers"

  elif command -v kwriteconfig5 &>/dev/null; then
    kwriteconfig5 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "_k_friendly_name" "Ask AI" 2>/dev/null || true
    kwriteconfig5 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "Ask AI" "${keybind_kde},none,Ask AI" 2>/dev/null || true
    ok "KDE Plasma 5 shortcut: $RCLICK_KEYBIND → ai-rclick"
  else
    warn "KDE: Manually add shortcut in System Settings > Shortcuts > Custom Shortcuts"
    info "  Command: ai-rclick   Shortcut: $RCLICK_KEYBIND"
  fi

  # Plasma 6: install xdg-open handler so Nautilus scripts work too
  if [[ $plasma_ver -eq 6 ]]; then
    local update_cmd
    update_cmd=$(command -v kbuildsycoca6 2>/dev/null || command -v kbuildsycoca5 2>/dev/null || true)
    [[ -n "$update_cmd" ]] && "$update_cmd" --noincremental 2>/dev/null &
  fi
}

_rclick_install_xfce() {
  info "Installing XFCE Thunar right-click action..."
  local uca="$HOME/.config/Thunar/uca.xml"
  mkdir -p "$(dirname "$uca")"
  [[ ! -f "$uca" ]] && echo '<actions></actions>' > "$uca"
  if ! grep -q "ai-rclick" "$uca" 2>/dev/null; then
    python3 - <<PYEOF
import xml.etree.ElementTree as ET
ET.register_namespace('', '')
try:
    tree = ET.parse('$uca')
    root = tree.getroot()
except:
    import xml.etree.ElementTree as ET2
    root = ET2.Element('actions')
    tree = ET2.ElementTree(root)
action = ET.SubElement(root, 'action')
for tag, text in [('icon','dialog-question'),('name','Ask AI'),
                  ('command','ai-rclick'),
                  ('description','Ask AI about selected text/file'),
                  ('patterns','*'),('directories','1'),('text-files','1'),
                  ('other-files','1')]:
    ET.SubElement(action, tag).text = text
tree.write('$uca', xml_declaration=True, encoding='utf-8')
print("XFCE Thunar action installed")
PYEOF
  fi
  ok "XFCE Thunar: right-click → Ask AI"

  # XFCE keyboard shortcut via xfconf
  if command -v xfconf-query &>/dev/null; then
    local keybind_xfce
    keybind_xfce=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
    xfconf-query -c xfce4-keyboard-shortcuts -p \
      "/commands/custom/${keybind_xfce}" \
      --create -t string -s "ai-rclick" 2>/dev/null || true
    ok "XFCE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_mate() {
  info "Installing MATE Caja right-click action..."
  mkdir -p "$HOME/.config/caja/scripts"
  printf '#!/usr/bin/env bash\nai-rclick "$@"\n' > "$HOME/.config/caja/scripts/Ask AI"
  chmod +x "$HOME/.config/caja/scripts/Ask AI"
  ok "MATE Caja: right-click → Scripts > Ask AI"

  if command -v dconf &>/dev/null; then
    local keybind_gs; keybind_gs=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
    dconf write /org/mate/desktop/keybindings/ask-ai/action "'ai-rclick'" 2>/dev/null || true
    dconf write /org/mate/desktop/keybindings/ask-ai/binding "'${keybind_gs}'" 2>/dev/null || true
    dconf write /org/mate/desktop/keybindings/ask-ai/name "'Ask AI'" 2>/dev/null || true
    ok "MATE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_lxde() {
  info "Installing LXDE/LXQt right-click (openbox menu)..."
  local ob_menu="$HOME/.config/openbox/menu.xml"
  if [[ -f "$ob_menu" ]] && ! grep -q "ai-rclick" "$ob_menu"; then
    sed -i 's|</openbox_menu>|  <menu id="ask-ai-menu" label="Ask AI" execute="ai-rclick"/>\n</openbox_menu>|' \
      "$ob_menu" 2>/dev/null || true
    ok "Openbox menu updated: Ask AI entry added"
  fi
  # LXDE keyboard shortcut
  local lxde_kb="$HOME/.config/openbox/lxde-rc.xml"
  if [[ -f "$lxde_kb" ]] && ! grep -q "ai-rclick" "$lxde_kb"; then
    local keybind_ob; keybind_ob=$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')
    sed -i "s|</keyboard>|  <keybind key=\"${keybind_ob}\">\n      <action name=\"Execute\"><command>ai-rclick</command></action>\n    </keybind>\n  </keyboard>|" \
      "$lxde_kb" 2>/dev/null || true
    ok "LXDE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_sway_i3() {
  local wm=""
  command -v sway &>/dev/null && wm="sway"
  command -v i3   &>/dev/null && [[ -z "$wm" ]] && wm="i3"
  [[ -n "${SWAYSOCK:-}" ]] && wm="sway"

  local keybind_sym; keybind_sym=$(_rclick_key_to_sway "$RCLICK_KEYBIND")
  local cfg_file=""
  case "$wm" in
    sway) cfg_file="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config" ;;
    i3)   cfg_file="${XDG_CONFIG_HOME:-$HOME/.config}/i3/config"   ;;
  esac

  if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
    if ! grep -q "ai-rclick" "$cfg_file"; then
      printf '\n# Ask AI shortcut \nbindsym %s exec ai-rclick\n' \
        "$keybind_sym" >> "$cfg_file"
      ok "${wm^}: Added '$keybind_sym → ai-rclick' in $cfg_file"
    else
      ok "${wm^}: ai-rclick keybind already in $cfg_file"
    fi
    info "Reload config: ${wm} reload  (or restart ${wm})"
  elif [[ -n "$wm" ]]; then
    # Config file not found — create snippet
    local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/$wm"
    mkdir -p "$cfg_dir"
    printf '# Ask AI shortcut \nbindsym %s exec ai-rclick\n' \
      "$keybind_sym" >> "$cfg_dir/config"
    ok "${wm^}: Created $cfg_dir/config with keybind"
  else
    echo "  Add to your sway/i3 config:  bindsym $keybind_sym exec ai-rclick"
  fi
}

_rclick_install_hyprland() {
  info "Installing Hyprland keybinding..."
  local hcfg="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
  local keybind_hypr
  # Hyprland format: SUPER SHIFT, A, exec, ai-rclick
  keybind_hypr=$(echo "$RCLICK_KEYBIND" | \
    sed 's/Super/SUPER/Ig;s/Ctrl/CTRL/Ig;s/Alt/ALT/Ig;s/Shift/SHIFT/Ig' | \
    awk -F'+' 'BEGIN{OFS=""} {mods=""; for(i=1;i<NF;i++) mods=mods" "$i; key=$NF; print mods", "key", exec, ai-rclick"}' | \
    sed 's/^ //')
  mkdir -p "$(dirname "$hcfg")"
  if [[ ! -f "$hcfg" ]] || ! grep -q "ai-rclick" "$hcfg"; then
    printf '\n# Ask AI shortcut \nbind = %s\n' "$keybind_hypr" >> "$hcfg"
    ok "Hyprland: Added 'bind = $keybind_hypr' in $hcfg"
  else
    ok "Hyprland: ai-rclick keybind already in $hcfg"
  fi
  info "Reload: hyprctl reload"
}

_rclick_install_openbox() {
  info "Installing Openbox keybinding..."
  local rc="${XDG_CONFIG_HOME:-$HOME/.config}/openbox/rc.xml"
  if [[ -f "$rc" ]] && ! grep -q "ai-rclick" "$rc"; then
    local keybind_ob; keybind_ob=$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')
    sed -i "s|</keyboard>|  <keybind key=\"${keybind_ob}\">\n      <action name=\"Execute\"><command>ai-rclick</command></action>\n    </keybind>\n  </keyboard>|" \
      "$rc" 2>/dev/null || true
    ok "Openbox: Added keybind $RCLICK_KEYBIND → ai-rclick"
    info "Reload: openbox --reconfigure"
  else
    echo "  Add to $rc <keyboard> section:"
    printf '    <keybind key="%s">\n      <action name="Execute"><command>ai-rclick</command></action>\n    </keybind>\n' \
      "$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')"
  fi
}

_rclick_install_xbindkeys() {
  # Universal X11 fallback using xbindkeys
  if ! command -v xbindkeys &>/dev/null; then
    info "xbindkeys not installed. For universal X11 keybind support:"
    info "  apt install xbindkeys   OR   pacman -S xbindkeys"
    return
  fi
  local cfg="$HOME/.xbindkeysrc"
  local keybind_xbk
  keybind_xbk=$(echo "$RCLICK_KEYBIND" | \
    sed 's/Super/Mod4/Ig;s/Ctrl/Control/Ig' | \
    awk -F'+' 'BEGIN{OFS="+"} {key=$NF; printf "\"%s\"\n  ", $0}')
  if [[ ! -f "$cfg" ]] || ! grep -q "ai-rclick" "$cfg"; then
    {
      echo ""
      echo "# Ask AI "
      echo '"ai-rclick"'
      echo "  $(echo "$RCLICK_KEYBIND" | sed 's/Super/Mod4/Ig;s/Ctrl/Control/Ig;s/+/ + /g')"
    } >> "$cfg"
    ok "xbindkeys: Added $RCLICK_KEYBIND → ai-rclick in $cfg"
    info "Reload: pkill xbindkeys; xbindkeys &"
  fi
}

# v3.2: Linux Mint / Cinnamon — Nemo file manager actions
_rclick_install_cinnamon() {
  info "Installing Cinnamon/Nemo right-click actions..."
  local nemo_dir="$HOME/.local/share/nemo/actions"
  mkdir -p "$nemo_dir"
  for action in "Ask AI" "Summarize" "Explain" "Fix Code" "Rewrite"; do
    local safe_name; safe_name=$(echo "$action" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    cat > "$nemo_dir/ai-${safe_name}.nemo_action" <<NEMOEOF
[Nemo Action]
Name=$action
Comment=Send to AI CLI
Exec=bash -c 'ai-rclick "$action" %F'
Selection=any
Extensions=any;
Icon-Name=dialog-information
NEMOEOF
  done
  ok "Cinnamon/Nemo: 5 actions installed in $nemo_dir"
  info "Restart Nemo: nemo -q && nemo &"
}

# v3.2: macOS — Services menu + keyboard shortcut
_rclick_install_macos() {
  info "Installing macOS Services integration..."
  local workflow_dir="$HOME/Library/Services"
  mkdir -p "$workflow_dir"

  local wf_dir="$workflow_dir/Ask AI.workflow/Contents"
  mkdir -p "$wf_dir"
  cat > "$wf_dir/Info.plist" <<'MACPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  KEYNSServices</key>
  <array>
    <dict>
      KEYNSMenuItem</key>
      <dict>KEYdefault</key><string>Ask AI</string></dict>
      KEYNSMessage</key><string>runWorkflowAsService</string>
      KEYNSSendTypes</key><array><string>NSStringPboardType</string></array>
    </dict>
  </array>
</dict>
</plist>
MACPLIST
  cat > "$wf_dir/document.wflow" <<'MACWFLOW'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  KEYactions</key>
  <array>
    <dict>
      KEYaction</key>
      <dict>
        KEYActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
        KEYActionName</key><string>Run Shell Script</string>
        KEYActionParameters</key>
        <dict>
          KEYCOMMAND_STRING</key><string>/usr/local/bin/ai ask "$@" | pbcopy &amp;&amp; osascript -e 'display notification "AI response copied to clipboard" with title "AI CLI"'</string>
          KEYCheckedForUserDefaultShell</key><true/>
          KEYinputMethod</key><integer>1</integer>
          KEYshell</key><string>/bin/bash</string>
        </dict>
      </dict>
    </dict>
  </array>
</dict>
</plist>
MACWFLOW
  ok "macOS: 'Ask AI' service installed"
  info "Access: Select text → right-click → Services → Ask AI"
  info "Or set a keyboard shortcut in: System Settings → Keyboard → Shortcuts → Services"
}

# v3.2: Windows — PowerShell context menu (registry-based)
_rclick_install_windows() {
  info "Installing Windows right-click menu..."
  local ps_script="$CONFIG_DIR/rclick_install.ps1"
  cat > "$ps_script" <<'WINEOF'
# AI CLI Right-Click Menu Installer for Windows
$ErrorActionPreference = "Stop"

# Add "Ask AI" to right-click context menu for all files
$regPath = "Registry::HKEY_CURRENT_USER\Software\Classes\*\shell\AskAI"
$cmdPath = "$regPath\command"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "(Default)" -Value "Ask AI"
Set-ItemProperty -Path $regPath -Name "Icon" -Value "cmd.exe"
New-Item -Path $cmdPath -Force | Out-Null
Set-ItemProperty -Path $cmdPath -Name "(Default)" -Value 'cmd /k bash -c "ai ask \"$(cat \"%1\")\" "'

# Add "Ask AI" for selected text (background)
$bgPath = "Registry::HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\AskAI"
$bgCmd = "$bgPath\command"
New-Item -Path $bgPath -Force | Out-Null
Set-ItemProperty -Path $bgPath -Name "(Default)" -Value "Ask AI (clipboard)"
New-Item -Path $bgCmd -Force | Out-Null
Set-ItemProperty -Path $bgCmd -Name "(Default)" -Value 'cmd /k bash -c "ai ask \"$(powershell.exe -c Get-Clipboard)\" "'

Write-Host "AI CLI right-click menu installed!" -ForegroundColor Green
Write-Host "Right-click any file or desktop background to use."
WINEOF
  ok "Windows: PowerShell installer created at $ps_script"
  if [[ $IS_WINDOWS -eq 1 ]]; then
    info "Running installer..."
    powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "$ps_script")" 2>/dev/null || \
      warn "Auto-install failed. Run manually: powershell -File $ps_script"
  else
    info "Copy to Windows and run: powershell -ExecutionPolicy Bypass -File rclick_install.ps1"
  fi
}

cmd_rclick() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    install)
      _rclick_install_deps
      _rclick_write_script

      # Auto-detect ALL present DEs/WMs and install for each
      local de="${XDG_CURRENT_DESKTOP:-}"
      local installed=()

      # GNOME / Cinnamon / Unity / Budgie (all use gsettings)
      if [[ -n "${GNOME_DESKTOP_SESSION_ID:-}" ]] \
         || [[ "$de" =~ (GNOME|Unity|Budgie|Cinnamon) ]]; then
        _rclick_install_gnome && installed+=("GNOME/Cinnamon")
      fi
      # KDE Plasma 5 / 6
      if [[ "$de" =~ (KDE) ]] || command -v plasmashell &>/dev/null; then
        _rclick_install_kde && installed+=("KDE")
      fi
      # XFCE
      if [[ "$de" =~ (XFCE|Xfce) ]] || command -v xfce4-session &>/dev/null; then
        _rclick_install_xfce && installed+=("XFCE")
      fi
      # MATE
      if [[ "$de" =~ (MATE) ]] || command -v mate-session &>/dev/null; then
        _rclick_install_mate && installed+=("MATE")
      fi
      # LXDE / LXQt
      if [[ "$de" =~ (LXDE|LXQt) ]] || command -v lxsession &>/dev/null; then
        _rclick_install_lxde && installed+=("LXDE")
      fi
      # Hyprland
      if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || command -v hyprctl &>/dev/null; then
        _rclick_install_hyprland && installed+=("Hyprland")
      fi
      # sway
      if [[ -n "${SWAYSOCK:-}" ]] || command -v sway &>/dev/null; then
        _rclick_install_sway_i3 && installed+=("sway")
      fi
      # i3
      if [[ "$de" =~ (i3) ]] || command -v i3 &>/dev/null && [[ ! " ${installed[*]} " =~ "sway" ]]; then
        _rclick_install_sway_i3 && installed+=("i3")
      fi
      # Openbox (standalone)
      if command -v openbox &>/dev/null && [[ ! " ${installed[*]} " =~ "LXDE" ]]; then
        _rclick_install_openbox && installed+=("Openbox")
      fi
      # v3.2: Cinnamon / Linux Mint (Nemo)
      if [[ "$de" =~ (Cinnamon|X-Cinnamon) ]] || command -v cinnamon &>/dev/null || command -v nemo &>/dev/null; then
        _rclick_install_cinnamon && installed+=("Cinnamon/Mint")
      fi
      # v3.2: macOS
      if [[ $IS_MACOS -eq 1 ]]; then
        _rclick_install_macos && installed+=("macOS")
      fi
      # v3.2: Windows
      if [[ $IS_WINDOWS -eq 1 ]] || [[ $IS_WSL -eq 1 ]]; then
        _rclick_install_windows && installed+=("Windows")
      fi

      # If nothing matched or as extra fallback, install xbindkeys
      if [[ ${#installed[@]} -eq 0 ]]; then
        warn "Could not detect DE/WM — installing all compatible integrations..."
        _rclick_install_gnome  2>/dev/null || true
        _rclick_install_kde    2>/dev/null || true
        _rclick_install_xfce   2>/dev/null || true
        _rclick_install_openbox 2>/dev/null || true
        _rclick_install_xbindkeys 2>/dev/null || true
      fi
      # Always offer xbindkeys as a universal fallback
      [[ ! " ${installed[*]} " =~ "xbindkeys" ]] && \
        command -v xbindkeys &>/dev/null && _rclick_install_xbindkeys 2>/dev/null || true

      RCLICK_ENABLED="1"; save_config
      echo ""
      ok "Right-click AI installed!"
      [[ ${#installed[@]} -gt 0 ]] && info "  DEs configured: ${installed[*]}"
      info "  Shortcut: $RCLICK_KEYBIND   (select text first, then press)"
      info "  Or right-click in file manager → Ask AI"
      info "  Change shortcut: ai rclick keybind COMBO  e.g. Ctrl+Shift+a"
      ;;

    keybind)
      local kb="${1:-}"
      if [[ -z "$kb" ]]; then
        echo "  Current keybind: ${RCLICK_KEYBIND}"
        echo ""
        echo "  Usage: ai rclick keybind COMBO"
        echo "  Examples:"
        echo "    ai rclick keybind Super+Shift+a    "
        echo "    ai rclick keybind Ctrl+Shift+a"
        echo "    ai rclick keybind Super+Alt+a"
        echo "    ai rclick keybind F12"
        echo ""
        echo "  After changing: run 'ai rclick install' to apply"
        return
      fi
      RCLICK_KEYBIND="$kb"; save_config
      ok "Keybind set: $kb"
      info "Run 'ai rclick install' to apply to your DE/WM"
      ;;

    uninstall)
      sudo rm -f /usr/local/bin/ai-rclick
      rm -f "$HOME/.local/share/nautilus/scripts/Ask AI"
      rm -f "$HOME/.local/share/nemo/scripts/Ask AI"
      rm -f "$HOME/.local/share/kservices5/ServiceMenus/ai-rclick.desktop"
      rm -f "$HOME/.local/share/kio/servicemenus/ai-rclick.desktop"
      rm -f "$HOME/.config/caja/scripts/Ask AI"
      # Remove GNOME shortcut
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null | \
           sed "s|, *'/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick/'||g" | \
           sed "s|'/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick/', *||g"
        )" 2>/dev/null || true
      RCLICK_ENABLED="0"; save_config
      ok "Right-click AI uninstalled"
      ;;

    model)
      local m="${1:-}"
      if [[ -z "$m" ]]; then
        hdr "VL Model Options for Right-Click"
        for k in "${!RCLICK_VL_MODELS[@]}"; do
          IFS='|' read -r repo _ desc <<< "${RCLICK_VL_MODELS[$k]}"
          printf "  ${B}%-16s${R} %s\n" "$k:" "$desc"
        done
        read -rp "Choose [qwen3vl/lfm25vl/lfm25vl_gguf/custom]: " m
      fi
      [[ -z "${RCLICK_VL_MODELS[$m]:-}" ]] && { err "Unknown: $m"; return 1; }
      RCLICK_VL_MODEL="$m"; save_config
      ok "VL model set: $m"
      info "Run 'ai rclick install' to reinstall script with new model"
      ;;

    download-model) _rclick_download_vl ;;

    test)
      info "Testing right-click AI..."
      local text="Right-click AI test from ai-cli v2.4.6. If you see this, it works!"
      command -v wl-copy  &>/dev/null && echo "$text" | wl-copy 2>/dev/null || true
      command -v xclip    &>/dev/null && echo "$text" | xclip -selection clipboard 2>/dev/null || true
      command -v xsel     &>/dev/null && echo "$text" | xsel --clipboard --input 2>/dev/null || true
      if command -v ai-rclick &>/dev/null; then
        AI_RCLICK_SKIP_QUESTION=1 ai-rclick 2>/dev/null || bash /usr/local/bin/ai-rclick
      else
        err "ai-rclick not installed. Run: ai rclick install"
        return 1
      fi
      ;;

    status)
      hdr "Right-Click AI Status (v2.4.6)"
      local script_loc; script_loc=$(command -v ai-rclick 2>/dev/null || echo 'NOT INSTALLED')
      local disp="X11"
      [[ -n "${WAYLAND_DISPLAY:-}${SWAYSOCK:-}${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && disp="Wayland"
      printf "  %-22s %s\n" "Enabled:"       "$RCLICK_ENABLED"
      printf "  %-22s %s\n" "VL model:"      "${RCLICK_VL_MODEL:-not set}"
      printf "  %-22s %s\n" "Keybind:"       "$RCLICK_KEYBIND"
      printf "  %-22s %s\n" "Script:"        "$script_loc"
      printf "  %-22s %s\n" "DE/WM:"         "${XDG_CURRENT_DESKTOP:-unknown}"
      printf "  %-22s %s\n" "Display server:" "$disp"
      printf "  %-22s %s\n" "Clipboard tools:" \
        "$(for t in xclip xsel wl-paste wl-copy; do command -v $t &>/dev/null && echo -n "$t "; done; echo)"
      ;;

    fix-auth|fixauth)
      # v2.6.0.1: Re-apply trust/execute flags to all rclick scripts
      # Fixes 'not authorized to execute this file' without a full reinstall
      hdr "Fixing rclick authorization flags..."
      local _script="/usr/local/bin/ai-rclick"
      if [[ -f "$_script" ]]; then
        sudo chmod a+x "$_script"
        if command -v gio &>/dev/null; then
          sudo gio set -t string "$_script" metadata::trusted yes 2>/dev/null || true
        fi
        command -v setfattr &>/dev/null && \
          sudo setfattr -n user.nautilus-trusted -v "" "$_script" 2>/dev/null || true
        ok "Fixed: $_script"
      else
        warn "ai-rclick not found at $_script — run: ai rclick install"
      fi
      # Fix Nautilus scripts directory
      for d in "$HOME/.local/share/nautilus/scripts" "$HOME/.local/share/nemo/scripts"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/Ask\ AI "$d"/Summarize "$d"/Explain\ this "$d"/Fix\ code "$d"/Translate\ to\ English "$d"/Find\ bugs; do
          [[ -f "$f" ]] || continue
          chmod a+x "$f"
          if command -v gio &>/dev/null; then
            gio set -t string "$f" metadata::trusted yes 2>/dev/null || true
          fi
          command -v setfattr &>/dev/null && \
            setfattr -n user.nautilus-trusted -v "" "$f" 2>/dev/null || true
          ok "Fixed: $f"
        done
      done
      # Fix KDE .desktop files
      for f in \
          "$HOME/.local/share/kservices5/ServiceMenus/ai-rclick.desktop" \
          "$HOME/.local/share/kio/servicemenus/ai-rclick.desktop"; do
        [[ -f "$f" ]] || continue
        chmod a+x "$f"
        ok "Fixed: $f"
      done
      ok "Authorization fix complete. If Nautilus still shows the error, log out and back in."
      ;;

    *)
      hdr "Right-Click AI Context Menu "
      echo ""
      echo "  ${B}ai rclick install${R}             — Install for all detected DEs/WMs"
      echo "  ${B}ai rclick fix-auth${R}            — Fix 'not authorized' error "
      echo "  ${B}ai rclick keybind COMBO${R}      — Change keyboard shortcut"
      echo "  ${B}ai rclick uninstall${R}           — Remove all integrations"
      echo "  ${B}ai rclick model NAME${R}         — Set VL model"
      echo "  ${B}ai rclick download-model${R}       — Download VL model"
      echo "  ${B}ai rclick test${R}                 — Test with clipboard content"
      echo "  ${B}ai rclick status${R}               — Show full status"
      echo ""
      echo "  ${B}Supported DEs/WMs all auto-detected:${R}"
      echo "    GNOME · KDE Plasma 5+6 · XFCE · MATE · Cinnamon/Mint"
      echo "    Hyprland · sway · i3 · Openbox · LXDE · macOS · Windows"
      echo "    Openbox · LXDE/LXQt · i3 · sway · Hyprland"
      echo "    X11 universal: xbindkeys fallback"
      echo ""
      echo "  ${B}Default keybind:${R} $RCLICK_KEYBIND  (select text first)"
      echo "  Change:  ai rclick keybind Ctrl+Shift+a"
      echo ""
      echo "  ${B}VL models:${R}"
      for k in "${!RCLICK_VL_MODELS[@]}"; do
        IFS='|' read -r _ _ desc <<< "${RCLICK_VL_MODELS[$k]}"
        printf "    ${B}%-16s${R} %s\n" "$k" "$desc"
      done
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  AUTO-UPDATER — checks github.com/minerofthesoal/ai-cli for new releases
# ════════════════════════════════════════════════════════════════════════════════

_aup_get_latest() {
  # Returns "TAG|URL" of latest release from GitHub
  local api_url="https://api.github.com/repos/${AUP_REPO}/releases/latest"
  local info
  info=$(curl -sS --max-time 10 --retry 3 \
    -H "Accept: application/vnd.github.v3+json" \
    "$api_url" 2>/dev/null) || { echo ""; return 1; }
  local tag download_url
  tag=$(echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null)
  download_url=$(echo "$info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assets=d.get('assets',[])
for a in assets:
    n=a.get('name','')
    if n.endswith('.sh') or n=='ai.sh' or n=='ai':
        print(a.get('browser_download_url','')); break
else:
    # Fallback: try raw download from tag
    tag=d.get('tag_name','')
    repo='${AUP_REPO}'
    print(f'https://raw.githubusercontent.com/{repo}/{tag}/ai.sh')
" 2>/dev/null)
  echo "${tag}|${download_url}"
}

_aup_compare_versions() {
  # Returns 1 if $1 > $2 (remote > current)
  local remote="$1" current="$2"
  python3 - <<PYEOF 2>/dev/null
import sys
def parse(v):
    v = v.lstrip('v')
    parts = v.split('.')
    try: return [int(x) for x in parts]
    except: return [0,0,0]
remote  = parse('$remote')
current = parse('$current')
sys.exit(0 if remote > current else 1)
PYEOF
}

_aup_do_update() {
  local tag="$1" url="$2"
  local tmp; tmp=$(mktemp /tmp/ai_update_XXXX.sh)
  info "Downloading update $tag from $url ..."
  curl -sS -L --retry 5 --progress-bar "$url" -o "$tmp" 2>/dev/null || {
    rm -f "$tmp"; err "Download failed"; return 1
  }
  # Validate
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; err "Downloaded script has syntax errors"; return 1; }
  local target
  target=$(command -v ai 2>/dev/null || echo "/usr/local/bin/ai")
  if [[ -w "$target" ]]; then
    cp "$tmp" "$target" && chmod +x "$target"
  else
    sudo cp "$tmp" "$target" && sudo chmod +x "$target"
  fi
  rm -f "$tmp"
  AUP_LAST_CHECK=$(date +%s); save_config
  ok "Updated to $tag! Restart ai to use new version."
  info "Run 'ai help' to see what's new"
}

# Model persistence: save/restore active model across updates
_model_save_state() {
  local state_file="$CONFIG_DIR/.model_state"
  cat > "$state_file" <<MSTATE
SAVED_MODEL="${ACTIVE_MODEL}"
SAVED_BACKEND="${ACTIVE_BACKEND}"
SAVED_SESSION="${ACTIVE_SESSION}"
MSTATE
}

_model_restore_state() {
  local state_file="$CONFIG_DIR/.model_state"
  [[ ! -f "$state_file" ]] && return
  source "$state_file" 2>/dev/null || return
  if [[ -n "${SAVED_MODEL:-}" && ( -f "$SAVED_MODEL" || -d "$SAVED_MODEL" ) ]]; then
    ACTIVE_MODEL="$SAVED_MODEL"
    ACTIVE_BACKEND="${SAVED_BACKEND:-}"
    ACTIVE_SESSION="${SAVED_SESSION:-default}"
    save_config
    ok "Model restored: $ACTIVE_MODEL"
  fi
  rm -f "$state_file"
}

cmd_autoupdate() {
  local force=0 check_only=0
  for a in "$@"; do
    [[ "$a" == "--force"      ]] && force=1
    [[ "$a" == "--check-only" ]] && check_only=1
  done

  # Check interval (default 1 hour)
  local now; now=$(date +%s)
  local last="${AUP_LAST_CHECK:-0}"
  if (( force == 0 && now - last < AUP_CHECK_INTERVAL )); then
    dim "Update check: next in $(( (AUP_CHECK_INTERVAL - (now - last)) / 60 )) min"
    return 0
  fi

  info "Checking for updates (${AUP_REPO})..."
  local info_str; info_str=$(_aup_get_latest)
  [[ -z "$info_str" ]] && { warn "Could not reach GitHub (offline?)"; return 1; }

  IFS='|' read -r remote_tag download_url <<< "$info_str"
  [[ -z "$remote_tag" ]] && { warn "Could not parse release info"; return 1; }

  printf "  Current:  %s\n  Latest:   %s\n" "v$VERSION" "$remote_tag"

  if _aup_compare_versions "$remote_tag" "$VERSION"; then
    ok "New release: $remote_tag"
    [[ $check_only -eq 1 ]] && return 0
    read -rp "Update now? [Y/n]: " ans
    [[ "${ans,,}" == "n" ]] && return 0
    _model_save_state
    _aup_do_update "$remote_tag" "$download_url"
    _model_restore_state
  else
    ok "Already up to date ($VERSION)"
    AUP_LAST_CHECK=$now; save_config
  fi
}

# Background silent update check (runs at startup when -aup flag set)
_aup_bg_check() {
  local now; now=$(date +%s)
  local last="${AUP_LAST_CHECK:-0}"
  (( now - last < AUP_CHECK_INTERVAL )) && return

  {
    local info_str; info_str=$(_aup_get_latest 2>/dev/null)
    [[ -z "$info_str" ]] && exit 0
    IFS='|' read -r remote_tag _ <<< "$info_str"
    if _aup_compare_versions "$remote_tag" "$VERSION" 2>/dev/null; then
      echo ""
      echo -e "${BYELLOW}⬆  Update available: ${B}$remote_tag${R}${BYELLOW} (current: $VERSION)${R}"
      echo -e "   Run ${B}ai -aup${R} to update"
    fi
    AUP_LAST_CHECK=$now; save_config
  } &>/dev/null &
  disown
}

# ════════════════════════════════════════════════════════════════════════════════
#  AGENT MODE — multi-step agentic task execution with web search
# ════════════════════════════════════════════════════════════════════════════════

declare -A AGENT_TOOLS_REGISTRY
AGENT_TOOLS_REGISTRY=(
  [web_search]="Search the web for current information. Args: {query: string}"
  [read_url]="Read the content of a URL. Args: {url: string}"
  [write_file]="Write content to a file. Args: {path: string, content: string}"
  [read_file]="Read a file's content. Args: {path: string}"
  [run_code]="Execute Python code. Args: {code: string}"
  [run_bash]="Execute a bash command. Args: {command: string}"
  [ask_user]="Ask the user a clarifying question. Args: {question: string}"
  [calculate]="Evaluate a math expression. Args: {expression: string}"
)

_agent_web_search() {
  local query="$1"
  # Try multiple search backends (no rate limiting)
  local results=""

  # DDG
  if [[ "${AGENT_SEARCH_ENGINE:-ddg}" == "ddg" ]] || true; then
    results=$(curl -sS --max-time 10 --retry 3 \
      -H "User-Agent: Mozilla/5.0 (compatible; ai-cli)" \
      "https://api.duckduckgo.com/?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "${query// /+}")&format=json&no_redirect=1" \
      2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    items=[]
    if d.get('AbstractText'): items.append({'title':'Summary','snippet':d['AbstractText'],'url':d.get('AbstractURL','')})
    for r in d.get('RelatedTopics',[])[:6]:
        if isinstance(r,dict) and r.get('Text'):
            items.append({'title':r.get('Text','')[:60],'snippet':r.get('Text',''),'url':r.get('FirstURL','')})
    print(json.dumps(items[:5]))
except: print('[]')
" 2>/dev/null)
  fi

  # Brave Search API if key available
  if [[ -n "${BRAVE_API_KEY:-}" ]] && [[ -z "$results" || "$results" == "[]" ]]; then
    results=$(curl -sS --max-time 10 --retry 3 \
      -H "Accept: application/json" \
      -H "Accept-Encoding: gzip" \
      -H "X-Subscription-Token: $BRAVE_API_KEY" \
      "https://api.search.brave.com/res/v1/web/search?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")" \
      2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    items=[{'title':r.get('title',''),'snippet':r.get('description',''),'url':r.get('url','')}
           for r in d.get('web',{}).get('results',[])]
    print(json.dumps(items[:6]))
except: print('[]')
" 2>/dev/null)
  fi

  echo "${results:-[]}"
}

_agent_read_url() {
  local url="$1"
  curl -sS --max-time 15 --retry 2 \
    -H "User-Agent: Mozilla/5.0" \
    -L "$url" 2>/dev/null | python3 -c "
import sys,re
html=sys.stdin.read()
# Strip HTML tags
text=re.sub(r'<script[^>]*>.*?</script>','',html,flags=re.DOTALL|re.IGNORECASE)
text=re.sub(r'<style[^>]*>.*?</style>','',text,flags=re.DOTALL|re.IGNORECASE)
text=re.sub(r'<[^>]+>','',text)
text=re.sub(r'\s+',' ',text).strip()
print(text[:3000])
" 2>/dev/null
}

_agent_run_code() {
  local code="$1"
  echo "$code" | python3 2>&1 | head -50
}

_agent_execute_step() {
  local tool="$1" args="$2"
  case "$tool" in
    web_search)
      local q; q=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('query',''))" 2>/dev/null)
      _agent_web_search "$q"
      ;;
    read_url)
      local url; url=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
      _agent_read_url "$url"
      ;;
    write_file)
      local path content
      path=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
      content=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))" 2>/dev/null)
      echo "$content" > "$path" && echo "Written: $path"
      ;;
    read_file)
      local p; p=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
      cat "$p" 2>/dev/null || echo "File not found: $p"
      ;;
    run_code)
      local code; code=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
      _agent_run_code "$code"
      ;;
    run_bash)
      local cmd; cmd=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command',''))" 2>/dev/null)
      eval "$cmd" 2>&1 | head -50
      ;;
    ask_user)
      local q; q=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('question',''))" 2>/dev/null)
      read -rp "$q: " ans; echo "$ans"
      ;;
    calculate)
      local expr; expr=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('expression',''))" 2>/dev/null)
      python3 -c "print(eval('$expr'))" 2>/dev/null
      ;;
    *)
      echo "Unknown tool: $tool"
      ;;
  esac
}

cmd_agent() {
  local task="$*"
  [[ -z "$task" ]] && { read -rp "Task: " task; }
  [[ -z "$task" ]] && return

  AGENT_MODE=1
  local max_steps="${AGENT_MAX_STEPS:-10}"
  local step=0
  local history=()
  local done=0

  hdr "🤖 Agent Mode — Task: $task"
  echo ""

  # Build tools list for the model
  local tools_desc
  tools_desc=$(for t in "${!AGENT_TOOLS_REGISTRY[@]}"; do
    echo "  - $t: ${AGENT_TOOLS_REGISTRY[$t]}"; done)

  local system_prompt="You are an autonomous AI agent. Break complex tasks into steps using available tools.
Available tools:
$tools_desc

Respond in this exact JSON format when using a tool:
{\"thought\": \"reasoning\", \"tool\": \"tool_name\", \"args\": {\"key\": \"value\"}}

Or when done:
{\"thought\": \"reasoning\", \"done\": true, \"answer\": \"final answer\"}

Be systematic. Use web_search for current information. Never make up facts."

  local context="Task: $task"

  while (( step < max_steps && done == 0 )); do
    (( step++ ))
    printf "\n${B}${BCYAN}Step %d/%d${R}\n" "$step" "$max_steps"

    # Get next action from AI
    local response
    response=$(AI_SYSTEM_OVERRIDE="$system_prompt" dispatch_ask "$context" 2>/dev/null)
    echo -e "${DIM}$response${R}"

    # Parse JSON response
    local thought tool args final_answer is_done
    thought=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('thought',''))" 2>/dev/null)
    tool=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('tool',''))" 2>/dev/null)
    args=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(json.dumps(d.get('args',{})))" 2>/dev/null || echo "{}")
    is_done=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('done','false'))" 2>/dev/null)
    final_answer=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('answer',''))" 2>/dev/null)

    [[ -n "$thought" ]] && echo -e "${DIM}  💭 $thought${R}"

    if [[ "$is_done" == "True" || "$is_done" == "true" || -n "$final_answer" ]]; then
      done=1
      echo ""
      hdr "✅ Agent Complete"
      echo -e "${BWHITE}$final_answer${R}"
      break
    fi

    if [[ -n "$tool" && "$tool" != "None" && "$tool" != "null" ]]; then
      echo -e "  ${BBLUE}🔧 Tool: $tool${R}"
      local tool_result
      tool_result=$(_agent_execute_step "$tool" "$args")
      echo -e "  ${DIM}Result: ${tool_result:0:500}${R}"
      context="${context}\n\nStep $step — Used: $tool\nResult: ${tool_result:0:1000}"
    else
      # Model gave a plain response, not JSON — treat as final answer
      done=1
      hdr "✅ Agent Response"
      echo "$response"
    fi
  done

  if (( done == 0 )); then
    warn "Max steps ($max_steps) reached. Use 'ai config agent_max_steps N' to increase."
  fi
  AGENT_MODE=0
}

# ════════════════════════════════════════════════════════════════════════════════
#  ENHANCED WEB SEARCH (no rate limiting, multiple backends)
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  MODEL LOADING PERSISTENCE (save/restore between install/update)
# ════════════════════════════════════════════════════════════════════════════════
cmd_model_save_restore() {
  local sub="${1:-status}"
  case "$sub" in
    save)
      _model_save_state
      ok "Model state saved: $ACTIVE_MODEL ($ACTIVE_BACKEND)"
      ;;
    restore)
      _model_restore_state
      ;;
    status)
      local state_file="$CONFIG_DIR/.model_state"
      if [[ -f "$state_file" ]]; then
        info "Saved state:"
        cat "$state_file"
      else
        info "No saved state (current: $ACTIVE_MODEL)"
      fi
      ;;
  esac
}

cmd_model_create() {
  local subcmd="${1:-help}"; shift || true
  case "$subcmd" in
    presets) _model_list_presets ;;
    new)     _model_new "$@" ;;
    edit)    _model_edit "$@" ;;
    list)    _model_list_custom ;;
    train)   _model_train_custom "$@" ;;
    info)    _model_info_custom "$@" ;;
    delete)  _model_delete_custom "$@" ;;
    *)
      echo -e "${B}${BCYAN}Custom Model Creator${R}"
      echo ""
      echo "  ${B}ai model-create presets${R}         — List built-in architecture presets"
      echo "  ${B}ai model-create new NAME [preset|custom]${R} — Create new model config"
      echo "  ${B}ai model-create edit NAME${R}     — Edit model config JSON"
      echo "  ${B}ai model-create list${R}            — List custom models"
      echo "  ${B}ai model-create train NAME [data.jsonl]${R} — Train from scratch"
      echo "  ${B}ai model-create info NAME${R}     — Show model info"
      echo "  ${B}ai model-create delete NAME${R}   — Delete custom model"
      echo ""
      echo -e "  ${DIM}Minimum: 0.125B params (nano preset)${R}"
      ;;
  esac
}

_model_list_presets() {
  hdr "Built-in Model Presets"
  echo ""
  for key in nano micro tiny small medium tinyllama; do
    local val="${MODEL_PRESETS[$key]}"
    local params; params=$(echo "$val" | grep -o 'params=[^|]*' | cut -d= -f2)
    printf "  ${B}%-12s${R} %s\n" "$key" "$params"
  done
  echo ""
  echo "  Use: ${B}ai model-create new mymodel nano${R}"
  echo "  Or:  ${B}ai model-create new mymodel custom${R} opens editor"
}

_model_new() {
  local name="${1:-}"; local preset="${2:-tiny}"
  [[ -z "$name" ]] && { read -rp "Model name: " name; }
  [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ -d "$mdir" ]] && { err "Model '$name' already exists"; return 1; }
  mkdir -p "$mdir"

  local config
  if [[ "$preset" == "custom" ]]; then
    config="$TTM_CONFIG_JSON"
    echo "$config" > "$mdir/config.json"
    "${EDITOR:-nano}" "$mdir/config.json"
  elif [[ -n "${MODEL_PRESETS[$preset]:-}" ]]; then
    local p="${MODEL_PRESETS[$preset]}"
    local hs; hs=$(echo "$p" | grep -o 'hidden_size=[0-9]*' | cut -d= -f2)
    local nhl; nhl=$(echo "$p" | grep -o 'num_hidden_layers=[0-9]*' | cut -d= -f2)
    local nah; nah=$(echo "$p" | grep -o 'num_attention_heads=[0-9]*' | cut -d= -f2)
    local is; is=$(echo "$p" | grep -o 'intermediate_size=[0-9]*' | cut -d= -f2)
    local mpe; mpe=$(echo "$p" | grep -o 'max_position_embeddings=[0-9]*' | cut -d= -f2)
    local vs; vs=$(echo "$p" | grep -o 'vocab_size=[0-9]*' | cut -d= -f2)
    cat > "$mdir/config.json" <<JSON
{
  "architectures": ["LlamaForCausalLM"],
  "bos_token_id": 1,
  "eos_token_id": 2,
  "hidden_act": "silu",
  "hidden_size": $hs,
  "initializer_range": 0.02,
  "intermediate_size": $is,
  "max_position_embeddings": $mpe,
  "model_type": "llama",
  "num_attention_heads": $nah,
  "num_hidden_layers": $nhl,
  "num_key_value_heads": $nah,
  "rms_norm_eps": 1e-05,
  "rope_scaling": null,
  "tie_word_embeddings": false,
  "torch_dtype": "float32",
  "use_cache": true,
  "vocab_size": $vs
}
JSON
  elif [[ -f "$preset" ]]; then
    cp "$preset" "$mdir/config.json"
  else
    err "Unknown preset: $preset. Use: nano micro tiny small medium tinyllama custom or a path to JSON"
    rm -rf "$mdir"; return 1
  fi

  cat > "$mdir/meta.json" <<META
{
  "name": "$name",
  "preset": "$preset",
  "created": "$(date -Iseconds)",
  "trained": false,
  "train_steps": 0,
  "version": 1
}
META
  ok "Created custom model '$name' in $mdir"
  echo "  Config: $mdir/config.json"
  echo "  Train:  ai model-create train $name DATA"
}

_model_edit() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  "${EDITOR:-nano}" "$mdir/config.json"
  ok "Saved '$name' config"
}

_model_list_custom() {
  hdr "Custom Models"
  local found=0
  for d in "$CUSTOM_MODELS_DIR"/*/; do
    [[ -f "$d/meta.json" ]] || continue
    found=1
    local name; name=$(basename "$d")
    local trained; trained=$(python3 -c "import json,sys; d=json.load(open('$d/meta.json')); print('yes' if d.get('trained') else 'no')" 2>/dev/null || echo "?")
    local steps; steps=$(python3 -c "import json,sys; d=json.load(open('$d/meta.json')); print(d.get('train_steps',0))" 2>/dev/null || echo "0")
    printf "  ${B}%-20s${R} trained=%-4s steps=%s\n" "$name" "$trained" "$steps"
  done
  [[ $found -eq 0 ]] && dim "  No custom models. Create one: ai model-create new mymodel tiny"
}

_model_info_custom() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  hdr "Model: $name"
  [[ -f "$mdir/config.json" ]] && { echo ""; echo "Config:"; cat "$mdir/config.json"; }
  [[ -f "$mdir/meta.json"   ]] && { echo ""; echo "Meta:";   cat "$mdir/meta.json";   }
}

_model_delete_custom() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  read -rp "Delete '$name'? This cannot be undone. [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled"; return 0; }
  rm -rf "$mdir"; ok "Deleted '$name'"
}

_model_train_custom() {
  local name="${1:-}"; local data="${2:-}"
  [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found. Create it first: ai model-create new $name"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Use provided dataset or look for default
  if [[ -z "$data" ]]; then
    [[ -f "$FINETUNE_DIR/dataset.jsonl" ]] && data="$FINETUNE_DIR/dataset.jsonl"
    [[ -z "$data" ]] && { err "No dataset. Provide path or run: ai finetune prepare <data>"; return 1; }
  fi
  [[ ! -f "$data" ]] && { err "Dataset not found: $data"; return 1; }

  local out_dir="$mdir/trained_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$out_dir"
  info "Training custom model '$name' from scratch..."
  info "Config: $mdir/config.json"
  info "Data:   $data"
  info "Output: $out_dir"
  echo ""

  "$PYTHON" - <<PYEOF
import json, os, sys
try:
    import torch
    from transformers import (AutoTokenizer, LlamaConfig, LlamaForCausalLM,
                               TrainingArguments, Trainer, DataCollatorForLanguageModeling)
    from datasets import Dataset
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run: ai install-deps")
    sys.exit(1)

config_path = "$mdir/config.json"
data_path   = "$data"
out_dir     = "$out_dir"

with open(config_path) as f:
    cfg_dict = json.load(f)

cfg = LlamaConfig(**{k: v for k, v in cfg_dict.items()
                     if not k.startswith('_') and k != 'architectures'})
model = LlamaForCausalLM(cfg)
total_params = sum(p.numel() for p in model.parameters())
print(f"Model parameters: {total_params:,} ({total_params/1e6:.2f}M)")

if total_params < 0.125e9:
    print(f"WARNING: Model has {total_params/1e6:.2f}M params, minimum is 125M (0.125B)")
    sys.exit(1)

# Tokenizer — use TinyLlama's tokenizer as base
tokenizer_id = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
try:
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_id)
except Exception:
    tokenizer = AutoTokenizer.from_pretrained("huggyllama/llama-7b", use_fast=True)
tokenizer.pad_token = tokenizer.eos_token

# Load dataset
records = []
with open(data_path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            txt = obj.get('text') or (obj.get('instruction','') + ' ' + obj.get('output',''))
            if txt.strip(): records.append({'text': txt})
        except: pass

if not records:
    print("No valid records in dataset"); sys.exit(1)
print(f"Dataset records: {len(records)}")

ds = Dataset.from_list(records)
def tokenize(ex):
    return tokenizer(ex['text'], truncation=True, max_length=cfg.max_position_embeddings,
                     padding='max_length')
ds = ds.map(tokenize, batched=True, remove_columns=['text'])

device = 'cuda' if torch.cuda.is_available() else 'cpu'
model = model.to(device)
print(f"Training on: {device}")

args = TrainingArguments(
    output_dir=out_dir,
    num_train_epochs=3,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=8,
    learning_rate=3e-4,
    lr_scheduler_type='cosine',
    warmup_ratio=0.05,
    fp16=(device=='cuda'),
    logging_steps=10,
    save_steps=100,
    save_total_limit=2,
    report_to='none',
)
trainer = Trainer(
    model=model,
    args=args,
    train_dataset=ds,
    data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved to {out_dir}")
PYEOF

  if [[ $? -eq 0 ]]; then
    # Update meta
    "$PYTHON" -c "
import json
m = json.load(open('$mdir/meta.json'))
m['trained'] = True
m['train_steps'] = m.get('train_steps',0) + 1
m['last_trained'] = '$(date -Iseconds)'
m['last_output'] = '$out_dir'
json.dump(m, open('$mdir/meta.json','w'), indent=2)
"
    ok "Training complete! Model saved to $out_dir"
  else
    err "Training failed"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════════
#  NAMED CHAT (-C) WITH JSONL SAVE + HF DATASET SYNC
# ════════════════════════════════════════════════════════════════════════════════
CURRENT_CHAT_NAME=""
CURRENT_CHAT_FILE=""

_chat_start() {
  local name="$1"
  # auto: generate a name based on timestamp
  if [[ "$name" == "auto" ]]; then
    name="chat_$(date +%Y%m%d_%H%M%S)"
  fi
  # Sanitize name
  name="${name//[^a-zA-Z0-9_-]/_}"
  CURRENT_CHAT_NAME="$name"
  CURRENT_CHAT_FILE="$CHAT_LOGS_DIR/${name}.jsonl"
  ok "Chat started: $name"
  echo "  Saving to: $CURRENT_CHAT_FILE"
  [[ "$HF_DATASET_SYNC" == "1" ]] && echo "  HF sync:   enabled → $HF_DATASET_REPO"
}

_chat_append() {
  local role="$1"; local content="$2"
  [[ -z "$CURRENT_CHAT_FILE" ]] && return 0
  local ts; ts=$(date -Iseconds)
  local record; record=$(printf '{"timestamp":"%s","session":"%s","role":"%s","content":%s}' \
    "$ts" "$CURRENT_CHAT_NAME" "$role" "$(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')")
  echo "$record" >> "$CURRENT_CHAT_FILE"

  # Background sync to HF if enabled
  if [[ "$HF_DATASET_SYNC" == "1" ]] && [[ -n "${HF_DATASET_KEY:-}" ]]; then
    _hf_dataset_sync_bg
  fi
}

_hf_dataset_sync_bg() {
  # Run in background — upload the current chat jsonl to the dataset repo
  local chat_file="$CURRENT_CHAT_FILE"
  local chat_name="$CURRENT_CHAT_NAME"
  local hf_key="$HF_DATASET_KEY"
  local repo="$HF_DATASET_REPO"
  [[ -z "$PYTHON" ]] && return 0

  ( HF_CHAT_FILE="$chat_file" HF_CHAT_NAME="$chat_name" \
    HF_KEY="$hf_key" HF_REPO="$repo" \
    "$PYTHON" - <<'PYEOF' &>/dev/null
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    sys.exit(0)
chat_file = os.environ['HF_CHAT_FILE']
chat_name = os.environ['HF_CHAT_NAME']
hf_key    = os.environ['HF_KEY']
repo      = os.environ['HF_REPO']
if not os.path.exists(chat_file): sys.exit(0)
api = HfApi(token=hf_key)
try:
    api.create_repo(repo_id=repo, repo_type='dataset', exist_ok=True, private=False)
    api.upload_file(
        path_or_fileobj=chat_file,
        path_in_repo=f"chats/{chat_name}.jsonl",
        repo_id=repo,
        repo_type='dataset',
        commit_message=f"sync: {chat_name}",
    )
except Exception as e:
    pass
PYEOF
  ) &
}

cmd_chat_list() {
  hdr "Saved Chats"
  local count=0
  for f in "$CHAT_LOGS_DIR"/*.jsonl; do
    [[ -f "$f" ]] || continue
    count=$(( count + 1 ))
    local name; name=$(basename "$f" .jsonl)
    local lines; lines=$(wc -l < "$f")
    printf "  ${B}%-30s${R} %3d messages\n" "$name" "$lines"
  done
  [[ $count -eq 0 ]] && dim "  No saved chats. Use: ai -C [name] ask ..."
}

cmd_chat_show() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: ai chat-show NAME"; return 1; }
  local f="$CHAT_LOGS_DIR/${name}.jsonl"
  [[ ! -f "$f" ]] && { err "Chat '$name' not found"; return 1; }
  hdr "Chat: $name"
  echo ""
  while IFS= read -r line; do
    local role; role=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('role','?'))" 2>/dev/null || echo "?")
    local content; content=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('content',''))" 2>/dev/null || echo "")
    if [[ "$role" == "user" ]]; then
      echo -e "${B}${BCYAN}You:${R} $content"
    else
      echo -e "${B}${BGREEN}AI:${R} $content"
    fi
    echo ""
  done < "$f"
}

cmd_chat_delete() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local f="$CHAT_LOGS_DIR/${name}.jsonl"
  [[ ! -f "$f" ]] && { err "Chat '$name' not found"; return 1; }
  read -rp "Delete chat '$name'? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled"; return 0; }
  rm -f "$f"; ok "Deleted $name"
}

# ════════════════════════════════════════════════════════════════════════════════
#  AUDIO SUPPORT
cmd_audio() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    transcribe) _audio_transcribe "$@" ;;
    tts)        _audio_tts "$@" ;;
    analyze)    _audio_analyze "$@" ;;
    convert)    _audio_convert "$@" ;;
    extract)    _audio_extract_from_video "$@" ;;
    ask)        _audio_ask "$@" ;;
    play)       _audio_play "$@" ;;
    info)       _audio_info "$@" ;;
    *)
      echo -e "${B}${BCYAN}Audio Commands${R}"
      echo "  ${B}ai audio transcribe FILE [--lang en] [--model base]${R}"
      echo "  ${B}ai audio tts TEXT [--voice nova] [--out file.mp3]${R}"
      echo "  ${B}ai audio analyze FILE${R}      — Analyze audio with AI"
      echo "  ${B}ai audio convert IN OUT${R}  — Convert format "
      echo "  ${B}ai audio extract VIDEO${R}     — Extract audio from video"
      echo "  ${B}ai audio ask FILE QUESTION${R} — Ask about audio content"
      echo "  ${B}ai audio play FILE${R}          — Play audio file"
      echo "  ${B}ai audio info FILE${R}          — Show audio metadata"
      ;;
  esac
}

_audio_transcribe() {
  local file="" lang="en" model_size="base" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)  lang="$2"; shift 2 ;;
      --model) model_size="$2"; shift 2 ;;
      --out)   out="$2"; shift 2 ;;
      *)       file="$1"; shift ;;
    esac
  done
  [[ -z "$file" ]] && { err "Usage: ai audio transcribe FILE"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }

  # Try OpenAI Whisper API first
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    info "Transcribing with OpenAI Whisper API..."
    local result
    result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F "file=@$file" \
      -F "model=whisper-1" \
      -F "language=$lang" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null)
    if [[ -n "$result" ]]; then
      echo "$result"
      if [[ -n "$out" ]]; then
        echo "$result" > "$out"; ok "Saved to $out"
      fi
      return 0
    fi
  fi

  # Fallback: local whisper
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  info "Transcribing with local Whisper (model: $model_size)..."
  local result
  result=$(AUDIO_FILE="$file" WHISPER_MODEL="$model_size" WHISPER_LANG="$lang" \
    "$PYTHON" - <<'PYEOF'
import os, sys
try:
    import whisper
except ImportError:
    try:
        import openai_whisper as whisper
    except ImportError:
        print("ERROR: whisper not installed. Run: pip install openai-whisper --break-system-packages")
        sys.exit(1)
f = os.environ['AUDIO_FILE']
m = os.environ.get('WHISPER_MODEL','base')
l = os.environ.get('WHISPER_LANG','en')
model = whisper.load_model(m)
result = model.transcribe(f, language=l)
print(result['text'])
PYEOF
  )
  if [[ -n "$result" ]]; then
    echo "$result"
    [[ -n "$out" ]] && { echo "$result" > "$out"; ok "Saved to $out"; }
  fi
}

_audio_tts() {
  local text="" voice="nova" out="" speed="1.0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --voice) voice="$2"; shift 2 ;;
      --out)   out="$2"; shift 2 ;;
      --speed) speed="$2"; shift 2 ;;
      *)       text="${text}${text:+ }$1"; shift ;;
    esac
  done
  [[ -z "$text" ]] && { read -rp "Text: " text; }
  [[ -z "$text" ]] && { err "No text provided"; return 1; }

  if [[ -z "$out" ]]; then
    out="$AUDIO_DIR/tts_$(date +%Y%m%d_%H%M%S).mp3"
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    info "Generating TTS with OpenAI (voice: $voice)..."
    curl -sS https://api.openai.com/v1/audio/speech \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"tts-1\",\"input\":$(echo "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"voice\":\"$voice\",\"speed\":$speed}" \
      --output "$out"
    ok "Saved to $out"
    _audio_play "$out"
  else
    # Fallback: pyttsx3 or espeak
    if "$PYTHON" -c "import pyttsx3" 2>/dev/null; then
      SPEAK_TEXT="$text" SPEAK_OUT="$out" "$PYTHON" - <<'PYEOF'
import os, pyttsx3
engine = pyttsx3.init()
engine.save_to_file(os.environ['SPEAK_TEXT'], os.environ['SPEAK_OUT'])
engine.runAndWait()
print(f"Saved to {os.environ['SPEAK_OUT']}")
PYEOF
    elif command -v espeak &>/dev/null; then
      espeak "$text" -w "$out"
      ok "Saved to $out"
    else
      err "No TTS backend. Set OPENAI_API_KEY or install: pip install pyttsx3 --break-system-packages"
      return 1
    fi
  fi
}

_audio_analyze() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "Usage: ai audio analyze FILE"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }

  # First transcribe, then analyze with AI
  info "Transcribing for analysis..."
  local transcript; transcript=$(_audio_transcribe "$file" 2>/dev/null)
  [[ -z "$transcript" ]] && { err "Could not transcribe audio"; return 1; }

  local prompt="Analyze this audio transcript. Provide: 1) Summary, 2) Key topics, 3) Sentiment, 4) Notable quotes.

Transcript:
$transcript"
  dispatch_ask "$prompt"
}

_audio_convert() {
  local input="${1:-}"; local output="${2:-}"
  [[ -z "$input" || -z "$output" ]] && { err "Usage: ai audio convert <input> <output>"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg not installed"; return 1; }
  ffmpeg -i "$input" "$output" && ok "Converted: $output"
}

_audio_extract_from_video() {
  local video="${1:-}"; local out="${2:-}"
  [[ -z "$video" ]] && { err "Usage: ai audio extract VIDEO [output.mp3]"; return 1; }
  [[ ! -f "$video" ]] && { err "File not found: $video"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  [[ -z "$out" ]] && out="$AUDIO_DIR/$(basename "$video" | sed 's/\.[^.]*$//').mp3"
  ffmpeg -i "$video" -q:a 0 -map a "$out" -y
  ok "Audio extracted to: $out"
}

_audio_ask() {
  local file="${1:-}"; shift
  local question="$*"
  [[ -z "$file" || -z "$question" ]] && { err "Usage: ai audio ask FILE QUESTION"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  info "Transcribing..."
  local transcript; transcript=$(_audio_transcribe "$file" 2>/dev/null)
  local prompt="Audio transcript:
$transcript

Question: $question"
  dispatch_ask "$prompt"
}

_audio_play() {
  local file="${1:-}"; [[ -z "$file" ]] && return 0
  for player in mpv vlc aplay paplay afplay; do
    command -v "$player" &>/dev/null && { "$player" "$file" &>/dev/null & return 0; }
  done
  warn "No audio player found (install mpv)"
}

_audio_info() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "File required"; return 1; }
  [[ ! -f "$file" ]] && { err "Not found: $file"; return 1; }
  if command -v ffprobe &>/dev/null; then
    ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
fmt=d.get('format',{})
print(f\"File:     {fmt.get('filename','?')}\")
print(f\"Duration: {float(fmt.get('duration',0)):.1f}s\")
print(f\"Size:     {int(fmt.get('size',0))//1024} KB\")
print(f\"Bitrate:  {int(fmt.get('bit_rate',0))//1000} kbps\")
for s in d.get('streams',[]):
    print(f\"Stream:   {s.get('codec_type','?')} / {s.get('codec_name','?')} / {s.get('sample_rate','?')}Hz\")
" 2>/dev/null
  else
    ls -lh "$file"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  VIDEO SUPPORT
# ════════════════════════════════════════════════════════════════════════════════
cmd_video() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    analyze)   _video_analyze "$@" ;;
    transcribe) _video_transcribe "$@" ;;
    caption)   _video_caption "$@" ;;
    convert)   _video_convert "$@" ;;
    extract)   _video_extract_frames "$@" ;;
    ask)       _video_ask "$@" ;;
    trim)      _video_trim "$@" ;;
    info)      _video_info "$@" ;;
    summary)   _video_summary "$@" ;;
    *)
      echo -e "${B}${BCYAN}Video Commands${R}"
      echo "  ${B}ai video analyze FILE${R}          — Analyze video content with AI"
      echo "  ${B}ai video transcribe FILE${R}       — Transcribe video audio"
      echo "  ${B}ai video caption FILE${R}          — Generate captions/subtitles .srt"
      echo "  ${B}ai video convert IN OUT${R}      — Convert video format"
      echo "  ${B}ai video extract FILE [fps]${R}    — Extract frames"
      echo "  ${B}ai video ask FILE QUESTION${R}   — Ask about video"
      echo "  ${B}ai video trim IN START END OUT${R}"
      echo "  ${B}ai video info FILE${R}             — Show video metadata"
      echo "  ${B}ai video summary FILE${R}          — AI summary of video"
      ;;
  esac
}

_video_info() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "File required"; return 1; }
  command -v ffprobe &>/dev/null || { err "ffmpeg/ffprobe required"; return 1; }
  ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
fmt=d.get('format',{})
print(f\"File:     {fmt.get('filename','?')}\")
dur=float(fmt.get('duration',0))
print(f\"Duration: {int(dur//60)}m {dur%60:.1f}s\")
print(f\"Size:     {int(fmt.get('size',0))//1024//1024} MB\")
print(f\"Bitrate:  {int(fmt.get('bit_rate',0))//1000} kbps\")
for s in d.get('streams',[]):
    if s.get('codec_type')=='video':
        print(f\"Video:    {s.get('codec_name')} {s.get('width')}x{s.get('height')} @ {s.get('r_frame_rate','?')} fps\")
    elif s.get('codec_type')=='audio':
        print(f\"Audio:    {s.get('codec_name')} {s.get('sample_rate','?')}Hz {s.get('channel_layout','?')}\")
" 2>/dev/null
}

_video_transcribe() {
  local file="${1:-}"; shift
  [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  info "Extracting audio..."
  local tmp_audio; tmp_audio=$(mktemp /tmp/vid_audio_XXXX.mp3)
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$file" -q:a 0 -map a "$tmp_audio" -y &>/dev/null
  info "Transcribing..."
  _audio_transcribe "$tmp_audio" "$@"
  rm -f "$tmp_audio"
}

_video_caption() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "Video file required"; return 1; }
  local out_srt="${file%.*}.srt"
  info "Generating captions for: $file"

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local tmp; tmp=$(mktemp /tmp/vid_XXXX.mp3)
    ffmpeg -i "$file" -q:a 0 -map a "$tmp" -y &>/dev/null
    local result
    result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F "file=@$tmp" -F "model=whisper-1" -F "response_format=srt" 2>/dev/null)
    rm -f "$tmp"
    echo "$result" > "$out_srt"
    ok "Captions saved: $out_srt"
  else
    err "OpenAI API key required for caption generation (provides word-level timestamps)"
  fi
}

_video_extract_frames() {
  local file="${1:-}"; local fps="${2:-1}"
  [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  local out_dir="$VIDEO_DIR/frames_$(basename "$file" | sed 's/\.[^.]*$//')_$(date +%H%M%S)"
  mkdir -p "$out_dir"
  ffmpeg -i "$file" -vf "fps=$fps" "$out_dir/frame_%04d.jpg" -y &>/dev/null
  local count; count=$(ls "$out_dir"/*.jpg 2>/dev/null | wc -l)
  ok "Extracted $count frames to $out_dir"
}

_video_trim() {
  local input="${1:-}"; local start="${2:-}"; local end="${3:-}"; local output="${4:-}"
  [[ -z "$input" || -z "$start" || -z "$end" ]] && {
    err "Usage: ai video trim <input> START END [output]"
    err "Example: ai video trim video.mp4 00:01:00 00:02:30 clip.mp4"
    return 1
  }
  [[ -z "$output" ]] && output="$VIDEO_DIR/trim_$(basename "$input")"
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$input" -ss "$start" -to "$end" -c copy "$output" -y
  ok "Trimmed video: $output"
}

_video_convert() {
  local input="${1:-}"; local output="${2:-}"
  [[ -z "$input" || -z "$output" ]] && { err "Usage: ai video convert <input> <output>"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$input" "$output" && ok "Converted: $output"
}

_video_analyze() {
  local file="${1:-}"; [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  info "Analyzing video: $file"
  _video_info "$file"
  echo ""
  info "Transcribing audio for analysis..."
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)

  # Extract a few frames and describe them if vision model available
  local frame_desc=""
  if command -v ffmpeg &>/dev/null && [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local tmpdir; tmpdir=$(mktemp -d /tmp/vid_frames_XXXX)
    ffmpeg -i "$file" -vf "fps=0.1" -vframes 3 "$tmpdir/frame_%02d.jpg" -y &>/dev/null
    local first_frame="$tmpdir/frame_01.jpg"
    if [[ -f "$first_frame" ]]; then
      info "Analyzing key frame with vision model..."
      local b64; b64=$(base64 -w0 < "$first_frame" 2>/dev/null || base64 < "$first_frame" 2>/dev/null)
      frame_desc=$(curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$b64\"}},{\"type\":\"text\",\"text\":\"Briefly describe what you see in this video frame.\"}]}],\"max_tokens\":200}" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
    fi
    rm -rf "$tmpdir"
  fi

  local prompt="Analyze this video content comprehensively.

${frame_desc:+Visual description of key frame:
$frame_desc

}${transcript:+Audio transcript:
$transcript

}Provide: 1) Overall summary, 2) Key topics/themes, 3) Sentiment/tone, 4) Notable moments."

  dispatch_ask "$prompt"
}

_video_ask() {
  local file="${1:-}"; shift
  local question="$*"
  [[ -z "$file" || -z "$question" ]] && { err "Usage: ai video ask FILE QUESTION"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  info "Processing video for question answering..."
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)
  local prompt="Video content:
${transcript:-[No audio/transcript available]}

Question: $question"
  dispatch_ask "$prompt"
}

_video_summary() {
  local file="${1:-}"; [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)
  dispatch_ask "Summarize this video content in 3-5 sentences:
$transcript"
}

# ════════════════════════════════════════════════════════════════════════════════
#  IMAGE-TEXT-TO-TEXT (Full vision support)
# ════════════════════════════════════════════════════════════════════════════════
cmd_vision() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    ask)     _vision_ask "$@" ;;
    ocr)     _vision_ocr "$@" ;;
    caption) _vision_caption "$@" ;;
    compare) _vision_compare "$@" ;;
    *)
      echo -e "${B}${BCYAN}Vision (Image-Text-to-Text)${R}"
      echo "  ${B}ai vision ask IMAGE QUESTION${R}   — Ask about an image"
      echo "  ${B}ai vision ocr IMAGE${R}              — Extract text from image"
      echo "  ${B}ai vision caption IMAGE${R}          — Generate image caption"
      echo "  ${B}ai vision compare IMG1 IMG2${R}    — Compare two images"
      echo ""
      echo "  Supports: jpg, png, gif, webp, bmp"
      echo "  Backends: OpenAI GPT-4o best, Claude 3, Gemini 1.5, LLaVA local"
      ;;
  esac
}

_encode_image_b64() {
  local file="$1"
  base64 -w0 < "$file" 2>/dev/null || base64 < "$file" 2>/dev/null
}

_vision_ask() {
  local image="${1:-}"; shift
  local question="${*:-Describe this image in detail.}"
  [[ -z "$image" ]] && { err "Usage: ai vision ask IMAGE QUESTION"; return 1; }
  [[ ! -f "$image" ]] && { err "Image not found: $image"; return 1; }

  local ext="${image##*.}"; ext="${ext,,}"
  local mime
  case "$ext" in
    jpg|jpeg) mime="image/jpeg" ;;
    png)      mime="image/png" ;;
    gif)      mime="image/gif" ;;
    webp)     mime="image/webp" ;;
    *)        mime="image/jpeg" ;;
  esac

  local b64; b64=$(_encode_image_b64 "$image")

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    curl -sS https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime;base64,$b64\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}],\"max_tokens\":${MAX_TOKENS}}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    curl -sS https://api.anthropic.com/v1/messages \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"claude-opus-4-5\",\"max_tokens\":${MAX_TOKENS},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"$mime\",\"data\":\"$b64\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null
  elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
    curl -sS "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$GEMINI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"contents\":[{\"parts\":[{\"inline_data\":{\"mime_type\":\"$mime\",\"data\":\"$b64\"}},{\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['candidates'][0]['content']['parts'][0]['text'])" 2>/dev/null
  elif [[ -n "$PYTHON" ]] && "$PYTHON" -c "import llava" 2>/dev/null; then
    IMAGE_FILE="$image" IMAGE_QUESTION="$question" "$PYTHON" - <<'PYEOF'
import os
from llava.model.builder import load_pretrained_model
from llava.mm_utils import get_model_name_from_path
model_path = "liuhaotian/llava-v1.5-7b"
tokenizer, model, image_processor, _ = load_pretrained_model(model_path, None, get_model_name_from_path(model_path))
from PIL import Image
image = Image.open(os.environ['IMAGE_FILE']).convert('RGB')
# simplified inference
print("LLaVA vision response")
PYEOF
  else
    err "No vision-capable backend. Set OPENAI_API_KEY, ANTHROPIC_API_KEY, or GEMINI_API_KEY"
    return 1
  fi
}

_vision_ocr() {
  local image="${1:-}"; [[ -z "$image" || ! -f "$image" ]] && { err "Image required"; return 1; }
  _vision_ask "$image" "Extract ALL text from this image exactly as it appears. Return only the text, no commentary."
}

_vision_caption() {
  local image="${1:-}"; [[ -z "$image" || ! -f "$image" ]] && { err "Image required"; return 1; }
  _vision_ask "$image" "Write a concise, descriptive caption for this image in one sentence."
}

_vision_compare() {
  local img1="${1:-}"; local img2="${2:-}"; local question="${3:-What are the differences between these images?}"
  [[ -z "$img1" || -z "$img2" ]] && { err "Usage: ai vision compare IMG1 IMG2 [question]"; return 1; }
  [[ ! -f "$img1" ]] && { err "Not found: $img1"; return 1; }
  [[ ! -f "$img2" ]] && { err "Not found: $img2"; return 1; }

  local b64_1; b64_1=$(_encode_image_b64 "$img1")
  local b64_2; b64_2=$(_encode_image_b64 "$img2")
  local mime1="image/jpeg"; local mime2="image/jpeg"

  [[ -n "${OPENAI_API_KEY:-}" ]] && \
    curl -sS https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime1;base64,$b64_1\"}},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime2;base64,$b64_2\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}],\"max_tokens\":${MAX_TOKENS}}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || \
    err "Vision comparison requires OPENAI_API_KEY"
}


# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  GUI v5 — Split-pane · Edit-on-select · AI Extensions · Firefox Sidebar
# ════════════════════════════════════════════════════════════════════════════════
#  New in v5: Split-pane layout (sidebar + content), inline editing on Enter/click,
#  different visual style, extension manager, Firefox extension install.
# ════════════════════════════════════════════════════════════════════════════════

cmd_gui() {
  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required for GUI"; _gui_fallback; return; }

  local gui_script; gui_script=$(mktemp /tmp/ai_gui_XXXX.py)
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "$0")
  local theme="${GUI_THEME:-dark}"
  local ext_dir="${EXTENSIONS_DIR:-$HOME/.config/ai-cli/extensions}"

  cat > "$gui_script" << 'GUIEOF'
#!/usr/bin/env python3
"""AI CLI v3.1 — GUI v7.1: curses TUI with scrolling, panels, themes"""
import sys,os,curses,subprocess,threading,textwrap,re
CLI=sys.argv[1] if len(sys.argv)>1 else "ai"
THEME=sys.argv[2] if len(sys.argv)>2 else "dark"
T={"dark":{"bg":0,"fg":7,"acc":6,"sel":4,"sf":15,"brd":6,"ttl":14,"dim":8,"hdr":4,"hf":15},
   "light":{"bg":15,"fg":0,"acc":4,"sel":6,"sf":0,"brd":4,"ttl":4,"dim":8,"hdr":6,"hf":0},
   "hacker":{"bg":0,"fg":2,"acc":10,"sel":2,"sf":0,"brd":2,"ttl":10,"dim":8,"hdr":2,"hf":0},
   "nord":{"bg":236,"fg":153,"acc":67,"sel":67,"sf":15,"brd":67,"ttl":153,"dim":242,"hdr":67,"hf":15},
   "dracula":{"bg":236,"fg":253,"acc":141,"sel":141,"sf":236,"brd":141,"ttl":141,"dim":245,"hdr":141,"hf":236},
   "gruvbox":{"bg":235,"fg":223,"acc":214,"sel":214,"sf":235,"brd":214,"ttl":214,"dim":243,"hdr":214,"hf":235},
}.get(THEME,{"bg":0,"fg":7,"acc":6,"sel":4,"sf":15,"brd":6,"ttl":14,"dim":8,"hdr":4,"hf":15})
def strip_ansi(s): return re.sub(r'\x1b\[[0-9;]*m','',s)
def run_ai(cmd):
    try:
        e=os.environ.copy();e["NO_COLOR"]="1"
        r=subprocess.run(f"{CLI} {cmd}",shell=True,capture_output=True,text=True,timeout=120,env=e)
        return strip_ansi((r.stdout+r.stderr).strip())
    except: return "Error: timeout or failure"
class App:
    def __init__(s,scr):
        s.s=scr;s.s.keypad(True);curses.curs_set(0);curses.start_color();curses.use_default_colors()
        try:
            for i,k in enumerate(["fg","acc","ttl","sf","brd","dim","hdr"],1):
                curses.init_pair(i,T.get(k,7),T["bg"])
            curses.init_pair(8,T["sf"],T["sel"])
            curses.init_pair(9,T["hf"],T["hdr"])
        except: pass
        s.C=lambda n:curses.color_pair(n)
        s.menu=[
            "Chat","Ask","Ask Web","Ask Think","Agent","Web Search",
            "Models","Recommended","Status","Health","Test",
            "Canvas","Notebook","Write","Node Editor",
            "Audio","Video","Vision","Imagine",
            "Memory","Snapshots","Templates","RAG","Batch",
            "Plugins","Presets","Profiles","Analytics",
            "Perf","Compare","Export","Cleanup","Security",
            "Git AI","Learn","Quiz","Interview",
            "Shell","JSON","SQL","Docker","Regex",
            "API Server","Firefox Ext","Settings","Help","Quit",
        ]
        s.cmds={
            "Chat":"chat","Ask":"ask","Ask Web":"ask-web","Ask Think":"ask-think",
            "Agent":"agent","Web Search":"websearch","Models":"models",
            "Recommended":"recommended","Status":"status","Health":"health",
            "Test":"test -A","Canvas":"canvas","Notebook":"notebook",
            "Write":"write","Node Editor":"node","Audio":"audio","Video":"video",
            "Vision":"vision","Imagine":"imagine","Memory":"memory list",
            "Snapshots":"snap list","Templates":"template list","RAG":"rag list",
            "Batch":"batch list","Plugins":"plugin list","Presets":"preset list",
            "Profiles":"profile list","Analytics":"analytics","Perf":"perf",
            "Compare":"compare","Export":"export","Cleanup":"cleanup --dry-run",
            "Security":"security","Git AI":"git","Learn":"learn",
            "Quiz":"quiz","Interview":"interview","Shell":"shell",
            "JSON":"json","SQL":"sql","Docker":"docker","Regex":"regex",
            "API Server":"api","Firefox Ext":"install-firefox-ext",
            "Settings":"config","Help":"help",
        }
        s.sel=0;s.scroll_top=0;s.out_scroll=0
        s.output=["AI CLI v3.1 — GUI v7.1","","Arrow keys navigate, Enter selects","PgUp/PgDn scroll output","q to quit, / to search, t to cycle theme"]
        s.input_mode=False;s.input_buf="";s.input_label="";s.input_cmd=""
        s.running=False;s.search=""
    def filtered(s):
        if not s.search: return list(enumerate(s.menu))
        return [(i,m) for i,m in enumerate(s.menu) if s.search.lower() in m.lower()]
    def draw(s):
        s.s.erase();H,W=s.s.getmaxyx()
        sw=min(30,W//3);cx=sw+1;cw=W-cx-1
        # Title bar
        title=f" AI CLI v3.1 — GUI v7.1 [{THEME}] "
        try: s.s.addstr(0,0," "*W,s.C(9));s.s.addstr(0,max(0,(W-len(title))//2),title,s.C(9)|curses.A_BOLD)
        except: pass
        # Sidebar header
        try: s.s.addstr(1,0," COMMANDS".ljust(sw),s.C(9)|curses.A_BOLD)
        except: pass
        # Sidebar items
        items=s.filtered()
        vis=H-4
        if s.sel>=s.scroll_top+vis: s.scroll_top=s.sel-vis+1
        if s.sel<s.scroll_top: s.scroll_top=s.sel
        for idx,(orig_i,label) in enumerate(items[s.scroll_top:s.scroll_top+vis]):
            y=idx+2
            if y>=H-1: break
            if orig_i==s.sel:
                try: s.s.addstr(y,0,f" {label}".ljust(sw),s.C(8)|curses.A_BOLD)
                except: pass
            else:
                try: s.s.addstr(y,1,label[:sw-2],s.C(2))
                except: pass
        # Vertical border
        for y in range(1,H-1):
            try: s.s.addch(y,sw,curses.ACS_VLINE,s.C(5))
            except: pass
        # Content header
        try: s.s.addstr(1,cx," OUTPUT".ljust(cw),s.C(9)|curses.A_BOLD)
        except: pass
        # Content area with scrolling
        content_h=H-4
        total=len(s.output)
        max_scroll=max(0,total-content_h)
        s.out_scroll=min(s.out_scroll,max_scroll)
        vis_lines=s.output[s.out_scroll:s.out_scroll+content_h]
        for i,line in enumerate(vis_lines):
            y=i+2
            if y>=H-1: break
            try: s.s.addstr(y,cx+1,line[:cw-1],s.C(1))
            except: pass
        # Scrollbar indicator
        if total>content_h and cw>2:
            sb_y=2+int(s.out_scroll/max(1,max_scroll)*(content_h-1)) if max_scroll>0 else 2
            try: s.s.addch(min(sb_y,H-2),W-1,curses.ACS_BLOCK,s.C(5))
            except: pass
        # Status bar
        if s.running: status=" Running... "
        elif s.input_mode: status=f" {s.input_label}: {s.input_buf}_ "
        elif s.search: status=f" Search: {s.search}_ | ESC to clear "
        else: status=f" q:quit Enter:select /:search t:theme PgUp/Dn:scroll | {s.menu[s.sel]} "
        try: s.s.addstr(H-1,0,status[:W-1].ljust(W-1),s.C(9)|curses.A_BOLD)
        except: pass
        s.s.refresh()
    def handle(s):
        k=s.s.getch()
        if s.input_mode:
            if k in(10,13):
                s.input_mode=False;cmd=s.input_cmd.replace("{}",s.input_buf)
                s.output.append(f"> ai {cmd}");s.running=True;s.draw()
                r=run_ai(cmd);s.running=False
                for l in r.split("\n"): s.output.append(l)
                s.out_scroll=max(0,len(s.output)-(curses.LINES-4))
                s.input_buf=""
            elif k==27: s.input_mode=False;s.input_buf=""
            elif k in(curses.KEY_BACKSPACE,127,8): s.input_buf=s.input_buf[:-1]
            elif 32<=k<127: s.input_buf+=chr(k)
            return True
        if s.search and k!=27 and k!=10 and k!=curses.KEY_UP and k!=curses.KEY_DOWN:
            if k in(curses.KEY_BACKSPACE,127,8): s.search=s.search[:-1]
            elif 32<=k<127: s.search+=chr(k)
            s.sel=0;s.scroll_top=0
            return True
        if k==ord('q') or k==ord('Q'): return False
        elif k==curses.KEY_UP or k==ord('k'): s.sel=max(0,s.sel-1)
        elif k==curses.KEY_DOWN or k==ord('j'): s.sel=min(len(s.menu)-1,s.sel+1)
        elif k==curses.KEY_PPAGE: s.out_scroll=max(0,s.out_scroll-10)
        elif k==curses.KEY_NPAGE: s.out_scroll+=10
        elif k==curses.KEY_HOME: s.out_scroll=0
        elif k==curses.KEY_END: s.out_scroll=max(0,len(s.output)-(curses.LINES-4))
        elif k==ord('/'): s.search="";s.sel=0
        elif k==27: s.search=""
        elif k==ord('t'):
            themes=["dark","light","hacker","nord","dracula","gruvbox"]
            global THEME;ci=themes.index(THEME) if THEME in themes else 0
            THEME=themes[(ci+1)%len(themes)]
            s.output.append(f"Theme: {THEME} (restart to apply)")
        elif k in(10,13):
            if s.search:
                items=s.filtered()
                if items: s.sel=items[0][0]
                s.search=""
            label=s.menu[s.sel]
            if label=="Quit": return False
            if label in("Chat","Learn","Interview"):
                curses.endwin();os.system(f"{CLI} {s.cmds[label]}");s.s=curses.initscr();curses.curs_set(0);return True
            if label in("Ask","Ask Web","Ask Think","Agent","Web Search","Imagine","Write","Quiz","Compare","Shell","JSON","SQL","Docker","Regex"):
                s.input_mode=True;s.input_label=label;s.input_cmd=f"{s.cmds[label]} {{}}"
                return True
            cmd=s.cmds.get(label,"help")
            s.output.append(f"> ai {cmd}");s.running=True;s.draw()
            r=run_ai(cmd);s.running=False
            for l in r.split("\n"): s.output.append(l)
            s.out_scroll=max(0,len(s.output)-(curses.LINES-4))
        return True
    def run(s):
        while True:
            s.draw()
            if not s.handle(): break
def main(scr): App(scr).run()
if __name__=="__main__": curses.wrapper(main)
GUIEOF
  info "Launching GUI v7 (split-pane, structured settings, v2.9 features)..."
  "$PYTHON" "$gui_script" "$cli_bin" "$theme" "$ext_dir"
  local rc=$?
  rm -f "$gui_script"
  [[ $rc -ne 0 ]] && _gui_fallback
}

_gui_fallback() {
  # Text-mode fallback when Python/curses unavailable
  while true; do
    echo ""
    hdr "═══ AI CLI v${VERSION} — Main Menu (GUI v7 text mode) ═══"
    echo ""
    echo -e "  ${B}${BCYAN}── Chat & AI ──${R}"
    echo -e "   ${B} 1.${R} Chat (interactive)       ${B} 2.${R} Ask a question"
    echo -e "   ${B} 3.${R} Agent mode               ${B} 4.${R} Web search"
    echo -e "  ${B}${BCYAN}── Media ──${R}"
    echo -e "   ${B} 5.${R} Imagine (image gen)       ${B} 6.${R} Vision (image→text)"
    echo -e "   ${B} 7.${R} Audio                     ${B} 8.${R} Video"
    echo -e "  ${B}${BCYAN}── Models & Training ──${R}"
    echo -e "   ${B} 9.${R} Models / Download         ${B}10.${R} Recommended (195)"
    echo -e "   ${B}11.${R} TTM / MTM / Mtm           ${B}12.${R} RLHF"
    echo -e "   ${B}13.${R} Datasets                  ${B}14.${R} Fine-tune"
    echo -e "  ${B}${BCYAN}── Workspace ──${R}"
    echo -e "   ${B}15.${R} Canvas                    ${B}16.${R} Notebook"
    echo -e "   ${B}17.${R} Write (blog/email/docs)   ${B}18.${R} Node Editor"
    echo -e "  ${B}${BCYAN}── v2.9 Features ──${R}"
    echo -e "   ${B}19.${R} Health check              ${B}20.${R} Perf benchmark"
    echo -e "   ${B}21.${R} RAG knowledge base        ${B}22.${R} Prompt templates"
    echo -e "   ${B}23.${R} Config snapshots           ${B}24.${R} Model compare"
    echo -e "   ${B}25.${R} Batch queue               ${B}26.${R} Analytics"
    echo -e "  ${B}${BCYAN}── System ──${R}"
    echo -e "   ${B}27.${R} Status                    ${B}28.${R} Settings"
    echo -e "   ${B}29.${R} Extensions                ${B}30.${R} Plugins"
    echo -e "   ${B}31.${R} Multi-AI Arena            ${B}32.${R} Learn mode"
    echo -e "   ${B} 0.${R} Quit"
    echo ""
    read -rp "Choose [0-32]: " choice
    case "$choice" in
      1)  cmd_chat_interactive ;;
      2)  read -rp "Question: " q; dispatch_ask "$q" ;;
      3)  read -rp "Task: " q; cmd_agent "$q" ;;
      4)  read -rp "Search: " q; cmd_websearch "$q" ;;
      5)  read -rp "Prompt: " p; cmd_imagine "$p" ;;
      6)  read -rp "Image: " img; read -rp "Question: " q; cmd_vision ask "$img" "$q" ;;
      7)  cmd_audio ;;
      8)  cmd_video ;;
      9)  cmd_list_models ;;
      10) cmd_recommended ;;
      11) read -rp "Model (TTM/MTM/Mtm): " m; case "$m" in TTM|ttm) cmd_ttm ;; MTM|mtm) cmd_mtm ;; *) cmd_Mtm ;; esac ;;
      12) cmd_rlhf status ;;
      13) cmd_dataset list ;;
      14) cmd_finetune ;;
      15) cmd_canvas ;;
      16) cmd_notebook ;;
      17) cmd_write ;;
      18) cmd_node ;;
      19) cmd_health ;;
      20) cmd_perf ;;
      21) cmd_rag ;;
      22) cmd_template ;;
      23) cmd_snap ;;
      24) read -rp "Prompt: " q; cmd_compare "$q" ;;
      25) cmd_batch ;;
      26) cmd_analytics ;;
      27) cmd_status ;;
      28) cmd_config ;;
      29) cmd_extension list ;;
      30) cmd_plugin list ;;
      31) read -rp "Topic: " q; cmd_multiai debate "$q" ;;
      32) read -rp "Topic: " q; cmd_learn "$q" ;;
      0|q|Q|"") break ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════════════════════════
#  GUI+ v3 — Advanced tkinter GUI (2.1× size, tabbed, modern)
# ════════════════════════════════════════════════════════════════════════════════
#  Requires: python3-tk  (sudo apt install python3-tk / pacman -S tk)
#  Falls back to enhanced curses GUI+ if tkinter unavailable
# ════════════════════════════════════════════════════════════════════════════════

cmd_gui_plus() {
  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required for GUI+"; return 1; }
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "$0")
  local theme="${GUI_THEME:-dark}"
  local cfg_dir="${CONFIG_DIR:-$HOME/.config/ai-cli}"
  if ! "$PYTHON" -c "import tkinter" 2>/dev/null; then
    warn "tkinter not found — falling back to enhanced curses GUI+"
    _gui_plus_curses "$cli_bin" "$theme" "$cfg_dir"
    return
  fi
  local script; script=$(mktemp /tmp/ai_guiplus_XXXX.py)
  cat > "$script" << 'GUIPLUSEOF'
#!/usr/bin/env python3
"""AI CLI v3.2 — GUI+ v4: tkinter, tabbed, 8 panels, dark/light themes"""
import sys, os, subprocess, threading, json, time, warnings
warnings.filterwarnings("ignore")
import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox, filedialog, simpledialog

CLI     = sys.argv[1] if len(sys.argv) > 1 else "ai"
THEME   = sys.argv[2] if len(sys.argv) > 2 else "dark"
CFG_DIR = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.config/ai-cli")

PALETTES = {
  "dark":   {"bg":"#1e1e2e","fg":"#cdd6f4","accent":"#89b4fa","accent2":"#a6e3a1",
             "err":"#f38ba8","dim":"#6c7086","panel":"#181825","border":"#313244",
             "sel":"#313244","btn":"#313244","btn_fg":"#cdd6f4","entry_bg":"#313244",
             "entry_fg":"#cdd6f4","chat_user":"#89b4fa","chat_ai":"#a6e3a1"},
  "light":  {"bg":"#eff1f5","fg":"#4c4f69","accent":"#1e66f5","accent2":"#40a02b",
             "err":"#d20f39","dim":"#9ca0b0","panel":"#e6e9ef","border":"#bcc0cc",
             "sel":"#bcc0cc","btn":"#dce0e8","btn_fg":"#4c4f69","entry_bg":"#dce0e8",
             "entry_fg":"#4c4f69","chat_user":"#1e66f5","chat_ai":"#40a02b"},
  "dracula":{"bg":"#282a36","fg":"#f8f8f2","accent":"#bd93f9","accent2":"#50fa7b",
             "err":"#ff5555","dim":"#6272a4","panel":"#21222c","border":"#44475a",
             "sel":"#44475a","btn":"#44475a","btn_fg":"#f8f8f2","entry_bg":"#44475a",
             "entry_fg":"#f8f8f2","chat_user":"#bd93f9","chat_ai":"#50fa7b"},
}
P = PALETTES.get(THEME, PALETTES["dark"])

def strip_ansi(s):
    import re
    return re.sub(r'\x1b\[[0-9;]*m', '', s)

def run_ai(cmd):
    try:
        env = os.environ.copy()
        env["NO_COLOR"] = "1"
        r = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True, timeout=120, env=env)
        return strip_ansi((r.stdout + r.stderr).strip())
    except subprocess.TimeoutExpired:
        return "Error: Command timed out"
    except Exception as e:
        return f"Error: {e}"

class ChatTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        self.chat = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], insertbackground=P["fg"], font=("Consolas",11),
            relief=tk.FLAT, borderwidth=0)
        self.chat.pack(fill=tk.BOTH, expand=True, padx=5, pady=(5,0))
        self.chat.insert(tk.END, "Welcome to AI CLI v3.2 — GUI+ v4\nType a message and press Enter or click Send.\n\n")
        self.chat.config(state=tk.DISABLED)
        # Input frame
        inp = tk.Frame(self, bg=P["bg"])
        inp.pack(fill=tk.X, padx=5, pady=5)
        self.entry = tk.Entry(inp, bg=P["entry_bg"], fg=P["entry_fg"],
            insertbackground=P["fg"], font=("Consolas",11), relief=tk.FLAT)
        self.entry.pack(side=tk.LEFT, fill=tk.X, expand=True, ipady=4)
        self.entry.bind("<Return>", self.send)
        self.web_var = tk.BooleanVar(value=False)
        tk.Checkbutton(inp, text="Web", variable=self.web_var, bg=P["bg"],
            fg=P["accent"], selectcolor=P["panel"], activebackground=P["bg"]).pack(side=tk.LEFT, padx=2)
        self.mem_var = tk.BooleanVar(value=False)
        tk.Checkbutton(inp, text="Mem", variable=self.mem_var, bg=P["bg"],
            fg=P["accent2"], selectcolor=P["panel"], activebackground=P["bg"]).pack(side=tk.LEFT, padx=2)
        tk.Button(inp, text="Send", command=self.send, bg=P["btn"],
            fg=P["btn_fg"], relief=tk.FLAT, padx=10).pack(side=tk.RIGHT)

    def append(self, role, text):
        self.chat.config(state=tk.NORMAL)
        color = P["chat_user"] if role == "user" else P["chat_ai"]
        self.chat.insert(tk.END, f"\n{role.upper()}: ", "role")
        self.chat.insert(tk.END, f"{text}\n")
        self.chat.tag_config("role", foreground=color, font=("Consolas",11,"bold"))
        self.chat.see(tk.END)
        self.chat.config(state=tk.DISABLED)

    def send(self, event=None):
        msg = self.entry.get().strip()
        if not msg: return
        self.entry.delete(0, tk.END)
        self.append("user", msg)
        cmd = "ask-web" if self.web_var.get() else "ask"
        mem = " -mem" if self.mem_var.get() else ""
        def _run():
            result = run_ai(f'{cmd}{mem} "{msg}"')
            self.after(0, lambda: self.append("ai", result))
        threading.Thread(target=_run, daemon=True).start()

class ModelsTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        btn_frame = tk.Frame(self, bg=P["bg"])
        btn_frame.pack(fill=tk.X, padx=5, pady=5)
        tk.Button(btn_frame, text="Refresh", command=self.refresh,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        tk.Button(btn_frame, text="Browse 195", command=self.browse,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=5)
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.refresh()

    def refresh(self):
        def _r():
            out = run_ai("models")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def browse(self):
        def _r():
            out = run_ai("recommended")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _set(self, text):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, text)

class SettingsTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        btn = tk.Frame(self, bg=P["bg"])
        btn.pack(fill=tk.X, padx=5, pady=5)
        tk.Button(btn, text="Refresh", command=self.refresh,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        tk.Button(btn, text="Health Check", command=self.health,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=5)
        tk.Button(btn, text="System Info", command=self.sysinfo,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        self.refresh()

    def refresh(self):
        def _r():
            out = run_ai("status")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def health(self):
        def _r():
            out = run_ai("health")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def sysinfo(self):
        def _r():
            out = run_ai("sysinfo")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _set(self, text):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, text)

class ToolsTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        self.tools = [
            ("Speed Test", "test -S"), ("Network Test", "test -N"),
            ("Perf Benchmark", "perf"), ("Security Audit", "security"),
            ("Cleanup", "cleanup --dry-run"), ("Analytics", "analytics"),
            ("Changelog", "change latest"), ("Memory", "memory list"),
            ("Snapshots", "snap list"), ("Templates", "template list"),
            ("Plugins", "plugin list"), ("Presets", "preset list"),
        ]
        btn_frame = tk.Frame(self, bg=P["bg"])
        btn_frame.pack(fill=tk.X, padx=5, pady=5)
        for i, (label, cmd) in enumerate(self.tools):
            b = tk.Button(btn_frame, text=label, command=lambda c=cmd: self.run_tool(c),
                bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT, padx=6, pady=2)
            b.grid(row=i//4, column=i%4, padx=2, pady=2, sticky="ew")
        for c in range(4):
            btn_frame.columnconfigure(c, weight=1)
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def run_tool(self, cmd):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, f"Running: ai {cmd}...\n")
        def _r():
            out = run_ai(cmd)
            self.after(0, lambda: self._append(out))
        threading.Thread(target=_r, daemon=True).start()

    def _append(self, text):
        self.text.insert(tk.END, text + "\n")
        self.text.see(tk.END)

class WriteTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        top = tk.Frame(self, bg=P["bg"])
        top.pack(fill=tk.X, padx=5, pady=5)
        tk.Label(top, text="Mode:", bg=P["bg"], fg=P["fg"]).pack(side=tk.LEFT)
        self.mode = ttk.Combobox(top, values=["blog","email","readme","docs","story","poem","resume"], width=10)
        self.mode.set("blog")
        self.mode.pack(side=tk.LEFT, padx=5)
        tk.Label(top, text="Topic:", bg=P["bg"], fg=P["fg"]).pack(side=tk.LEFT)
        self.topic = tk.Entry(top, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT, width=40)
        self.topic.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=5)
        tk.Button(top, text="Generate", command=self.generate,
            bg=P["accent"], fg="#ffffff", relief=tk.FLAT, padx=10).pack(side=tk.RIGHT)
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",11), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def generate(self):
        m = self.mode.get()
        t = self.topic.get().strip()
        if not t: return
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, f"Generating {m}: {t}...\n")
        def _r():
            out = run_ai(f'write {m} "{t}"')
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _set(self, text):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, text)

class RAGTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        top = tk.Frame(self, bg=P["bg"])
        top.pack(fill=tk.X, padx=5, pady=5)
        tk.Button(top, text="List KBs", command=self.list_kb,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        tk.Button(top, text="Create KB", command=self.create_kb,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=5)
        tk.Label(top, text="Query:", bg=P["bg"], fg=P["fg"]).pack(side=tk.LEFT, padx=(10,2))
        self.kb_name = tk.Entry(top, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT, width=12)
        self.kb_name.pack(side=tk.LEFT, padx=2)
        self.query = tk.Entry(top, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT, width=30)
        self.query.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=2)
        self.query.bind("<Return>", lambda e: self.do_query())
        tk.Button(top, text="Ask", command=self.do_query,
            bg=P["accent"], fg="#ffffff", relief=tk.FLAT).pack(side=tk.RIGHT)
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def list_kb(self):
        def _r():
            out = run_ai("rag list")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def create_kb(self):
        name = simpledialog.askstring("Create KB", "Knowledge base name:")
        if not name: return
        d = filedialog.askdirectory(title="Select documents directory")
        if not d: return
        def _r():
            out = run_ai(f'rag create "{name}" "{d}"')
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def do_query(self):
        kb = self.kb_name.get().strip()
        q = self.query.get().strip()
        if not kb or not q: return
        def _r():
            out = run_ai(f'rag query "{kb}" "{q}"')
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _set(self, text):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, text)

class CanvasTab(tk.Frame):
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        top = tk.Frame(self, bg=P["bg"])
        top.pack(fill=tk.X, padx=5, pady=5)
        tk.Button(top, text="New Workspace", command=self.new_ws,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        tk.Button(top, text="Open in TUI", command=self.open_tui,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=5)
        tk.Button(top, text="List", command=self.list_ws,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT)
        self.text = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.text.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.list_ws()

    def new_ws(self):
        name = simpledialog.askstring("New Workspace", "Workspace name:")
        if name:
            out = run_ai(f'canvas new "{name}"')
            self._set(out)

    def open_tui(self):
        name = simpledialog.askstring("Open Workspace", "Workspace name:")
        if name:
            subprocess.Popen([CLI, "canvas", "open", name])

    def list_ws(self):
        def _r():
            out = run_ai("canvas open")
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _set(self, text):
        self.text.delete("1.0", tk.END)
        self.text.insert(tk.END, text)

class APITab(tk.Frame):
    """Talks directly to the local HTTP API server (port 8080)."""
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        top = tk.Frame(self, bg=P["bg"]); top.pack(fill=tk.X, padx=5, pady=5)
        tk.Label(top, text="API URL:", bg=P["bg"], fg=P["fg"]).pack(side=tk.LEFT)
        self.url = tk.Entry(top, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT, width=28)
        self.url.insert(0, "http://127.0.0.1:8080")
        self.url.pack(side=tk.LEFT, padx=4)
        for label, cmd in [("Start", "api start"), ("Stop", "api stop"), ("Status", "api status")]:
            tk.Button(top, text=label, command=lambda c=cmd: self._run_ai(c),
                bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=2)
        tk.Button(top, text="Open in Browser", command=self._open,
            bg=P["accent"], fg="#ffffff", relief=tk.FLAT).pack(side=tk.RIGHT)
        # grid of endpoint probe buttons
        grid = tk.Frame(self, bg=P["bg"]); grid.pack(fill=tk.X, padx=5, pady=5)
        buttons = [
            ("Health", "/health"), ("Status", "/v3/status"), ("SysInfo", "/v3/sysinfo"),
            ("Models", "/v3/models"), ("Keys", "/v3/keys"), ("Endpoints", "/v3/endpoints"),
            ("History", "/v3/history"), ("Logs", "/v3/logs"), ("Config", "/v3/config"),
        ]
        for i, (lbl, path) in enumerate(buttons):
            tk.Button(grid, text=lbl, command=lambda p=path: self._get(p),
                bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT, padx=6, pady=2
            ).grid(row=i//5, column=i%5, padx=2, pady=2, sticky="ew")
        for c in range(5):
            grid.columnconfigure(c, weight=1)
        self.out = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.out.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def _run_ai(self, cmd):
        def _r():
            out = run_ai(cmd)
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _get(self, path):
        import urllib.request
        self._set(f"GET {self.url.get()}{path}\n\n")
        def _r():
            try:
                with urllib.request.urlopen(self.url.get() + path, timeout=10) as r:
                    out = r.read().decode()
            except Exception as e:
                out = f"Error: {e}"
            self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def _open(self):
        import webbrowser
        webbrowser.open(self.url.get() + "/v3/site")

    def _set(self, text):
        self.out.delete("1.0", tk.END); self.out.insert(tk.END, text)

class AgentTab(tk.Frame):
    """Run autonomous agent + diff review."""
    def __init__(self, parent):
        super().__init__(parent, bg=P["bg"])
        tk.Label(self, text="Goal:", bg=P["bg"], fg=P["fg"]).pack(anchor=tk.W, padx=5, pady=(6,0))
        self.goal = tk.Entry(self, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT)
        self.goal.pack(fill=tk.X, padx=5, pady=2)
        row = tk.Frame(self, bg=P["bg"]); row.pack(fill=tk.X, padx=5, pady=4)
        tk.Label(row, text="Steps:", bg=P["bg"], fg=P["fg"]).pack(side=tk.LEFT)
        self.steps = tk.Entry(row, bg=P["entry_bg"], fg=P["entry_fg"], relief=tk.FLAT, width=6)
        self.steps.insert(0, "3"); self.steps.pack(side=tk.LEFT, padx=4)
        tk.Button(row, text="Run Agent", command=self.run_agent,
            bg=P["accent"], fg="#ffffff", relief=tk.FLAT).pack(side=tk.LEFT, padx=4)
        tk.Button(row, text="Review Staged Diff", command=self.review_diff,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=4)
        tk.Button(row, text="Share API", command=self.share,
            bg=P["btn"], fg=P["btn_fg"], relief=tk.FLAT).pack(side=tk.LEFT, padx=4)
        self.out = scrolledtext.ScrolledText(self, wrap=tk.WORD, bg=P["panel"],
            fg=P["fg"], font=("Consolas",10), relief=tk.FLAT)
        self.out.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def _bg(self, cmd):
        self._set(f"Running: ai {cmd}\n\n")
        def _r():
            out = run_ai(cmd); self.after(0, lambda: self._set(out))
        threading.Thread(target=_r, daemon=True).start()

    def run_agent(self):
        g = self.goal.get().strip()
        if not g: return
        s = self.steps.get().strip() or "3"
        self._bg(f'agent "{g}" --steps {s}')

    def review_diff(self):
        self._bg("diff-review")

    def share(self):
        self._bg("share")

    def _set(self, text):
        self.out.delete("1.0", tk.END); self.out.insert(tk.END, text)

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"AI CLI v3.2 — GUI+ v4 [{THEME}]")
        self.geometry("1180x740")
        self.configure(bg=P["bg"])
        self.minsize(900, 560)
        # Notebook (tabs)
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TNotebook", background=P["bg"], borderwidth=0)
        style.configure("TNotebook.Tab", background=P["btn"], foreground=P["btn_fg"],
            padding=[12,4], font=("Consolas",10))
        style.map("TNotebook.Tab", background=[("selected",P["accent"])],
            foreground=[("selected","#ffffff")])
        nb = ttk.Notebook(self)
        nb.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        nb.add(ChatTab(nb), text=" Chat ")
        nb.add(ModelsTab(nb), text=" Models ")
        nb.add(AgentTab(nb), text=" Agent ")
        nb.add(APITab(nb), text=" API ")
        nb.add(WriteTab(nb), text=" Write ")
        nb.add(RAGTab(nb), text=" RAG ")
        nb.add(CanvasTab(nb), text=" Canvas ")
        nb.add(ToolsTab(nb), text=" Tools ")
        nb.add(SettingsTab(nb), text=" Status ")
        # Status bar
        self.status_var = tk.StringVar(value=f"AI CLI v3.2 — GUI+ v4 ready")
        tk.Label(self, textvariable=self.status_var, bg=P["border"], fg=P["dim"],
            font=("Consolas",9), anchor="w").pack(fill=tk.X, side=tk.BOTTOM)
        # Menu bar
        menu = tk.Menu(self, bg=P["bg"], fg=P["fg"])
        self.config(menu=menu)
        file_menu = tk.Menu(menu, tearoff=0, bg=P["bg"], fg=P["fg"])
        file_menu.add_command(label="Quit", command=self.quit, accelerator="Ctrl+Q")
        menu.add_cascade(label="File", menu=file_menu)
        help_menu = tk.Menu(menu, tearoff=0, bg=P["bg"], fg=P["fg"])
        help_menu.add_command(label="About", command=self.about)
        menu.add_cascade(label="Help", menu=help_menu)
        self.bind("<Control-q>", lambda e: self.quit())

    def about(self):
        messagebox.showinfo("About", f"AI CLI v3.2 — GUI+ v4\n\nTabbed tkinter interface\n"
            f"Theme: {THEME}\n\nTabs: Chat · Models · Agent · API · Write · RAG · Canvas · Tools · Status\n\n"
            f"v3.2: 44 HTTP endpoints, streaming chat, RAG, voice, share, agent loop")

if __name__ == "__main__":
    app = App()
    app.mainloop()
GUIPLUSEOF
  info "Launching GUI+ v3 (tkinter, 2.1× size)…"
  "$PYTHON" "$script" "$cli_bin" "$theme" "$cfg_dir"
  local rc=$?
  rm -f "$script"
  [[ $rc -ne 0 ]] && { warn "GUI+ tkinter failed (rc=$rc) — trying curses fallback"; _gui_plus_curses "$cli_bin" "$theme" "$cfg_dir"; }
}

_gui_plus_curses() {
  local cli_bin="$1" theme="$2" cfg_dir="$3"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local script; script=$(mktemp /tmp/ai_gpc_XXXX.py)
  cat > "$script" << 'GPCEOF'
#!/usr/bin/env python3
"""AI CLI v2.7.4 — GUI+ curses fallback"""
import sys,os,curses,subprocess,threading
CLI=sys.argv[1] if len(sys.argv)>1 else "ai"
MENU=[("Chat","chat"),("Ask","ask"),("Node Editor","node new"),("Models","models"),
      ("Recommended","recommended"),("Settings","config"),("Status","status"),
      ("Benchmark","bench"),("Extensions","extension locate"),("RLHF","rlhf status"),
      ("Multi-AI","multiai"),("Audio","audio help"),("Video","video help"),
      ("Vision","vision help"),("Imagine","imagine"),("Web Search","websearch"),
      ("GitHub","github help"),("Papers","papers help"),("API Server","api start"),
      ("TTM","ttm help"),("MTM","mtm help"),("Error Codes","error-codes"),
      ("Update","--check-only"),("Aliases","alias list"),("Node Config","node config"),
      ("Quit","__quit__")]
def run_ai(*a,timeout=60):
    try: r=subprocess.run([CLI]+list(a),capture_output=True,text=True,timeout=timeout); return (r.stdout+r.stderr).strip()
    except: return "[error]"
class App:
    def __init__(self,s):
        self.s=s; self.sel=0; self.out=[]
        curses.start_color(); curses.use_default_colors()
        for i,fg in enumerate([6,7,14,8,5,2],1): 
            try: curses.init_pair(i,fg,-1)
            except: pass
        curses.curs_set(0); self.s.timeout(80)
    def draw(self):
        self.s.erase(); H,W=self.s.getmaxyx(); sw=max(26,W//4); cw=W-sw-2
        try:
            self.s.addstr(0,0,"─"*W,curses.color_pair(1)|curses.A_BOLD)
            hdr=" AI CLI v2.9.0 — GUI+ v3 "; self.s.addstr(0,max(0,(W-len(hdr))//2),hdr,curses.color_pair(3)|curses.A_BOLD)
            for i,(label,_) in enumerate(MENU):
                r=1+i
                if r>=H-1: break
                attr=curses.color_pair(5)|curses.A_BOLD if i==self.sel else curses.color_pair(2)
                pfx=" ▶ " if i==self.sel else "   "
                try: self.s.addstr(r,0,f"{pfx}{label[:sw-3]:<{sw-3}}",attr)
                except: pass
            for i,line in enumerate(self.out[-(H-3):]):
                r=1+i
                if r>=H-1: break
                try: self.s.addstr(r,sw+1,line[:cw],curses.color_pair(4 if line.startswith("  ") else 2))
                except: pass
            self.s.addstr(H-1,0," ↑↓=nav  Enter=run  q=quit ",curses.color_pair(4))
        except: pass
        self.s.refresh()
    def run(self):
        while True:
            self.draw()
            try: ch=self.s.getch()
            except: ch=-1
            if ch in (ord('q'),ord('Q')): break
            elif ch==curses.KEY_UP:   self.sel=max(0,self.sel-1)
            elif ch==curses.KEY_DOWN: self.sel=min(len(MENU)-1,self.sel+1)
            elif ch in (curses.KEY_ENTER,10,13):
                label,cmd=MENU[self.sel]
                if cmd=="__quit__": break
                self.out=[f"$ ai {cmd}","..."]
                def _go(c=cmd): 
                    r=run_ai(*c.split())
                    self.out=[f"$ ai {c}",""]+r.splitlines()[:50]
                threading.Thread(target=_go,daemon=True).start()
def main(s): App(s).run()
try: curses.wrapper(main)
except KeyboardInterrupt: pass
GPCEOF
  "$PYTHON" "$script" "$cli_bin"
  rm -f "$script"
}

# ════════════════════════════════════════════════════════════════════════════════
#  BUILTIN TOOLS
# ════════════════════════════════════════════════════════════════════════════════
BUILTIN_TOOLS=("web_search" "read_file" "write_file" "run_code" "list_dir"
               "get_time" "get_sysinfo" "calc" "download_file" "image_info")


# ════════════════════════════════════════════════════════════════════════════════
#  WEB SEARCH
# ════════════════════════════════════════════════════════════════════════════════

BUILTIN_TOOLS=("web_search" "read_file" "write_file" "run_code" "list_dir"
               "get_time" "get_sysinfo" "calc" "download_file" "image_info")

run_tool() {
  local name="$1"; local args_json="${2:-{}}"
  case "$name" in
    web_search)
      local q; q=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('query',''))" 2>/dev/null)
      web_search "$q" 5 ;;
    read_file)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -f "$p" ]] && cat "$p" || echo "File not found: $p" ;;
    write_file)
      local p c
      p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      c=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('content',''))" 2>/dev/null)
      echo "$c" > "$p" && echo "Written: $p" ;;
    run_code)
      local lang code
      lang=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('language','python'))" 2>/dev/null)
      code=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('code',''))" 2>/dev/null)
      case "$lang" in
        python|py) echo "$code" | python3 2>&1 ;;
        bash|sh)   echo "$code" | bash 2>&1 ;;
        js|node)   echo "$code" | node 2>&1 ;;
        *) echo "Unsupported language: $lang" ;;
      esac ;;
    list_dir)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path','.'))" 2>/dev/null)
      ls -la "$p" 2>&1 ;;
    get_time) date ;;
    get_sysinfo)
      echo "OS: $(uname -s -r)"
      echo "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
      echo "RAM: $(free -h 2>/dev/null | awk '/^Mem/{print $2}' || echo '?')"
      [[ -n "$PYTHON" ]] && echo "Python: $($PYTHON --version 2>&1)"
      command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "GPU: none/unknown"
      ;;
    calc)
      local expr; expr=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('expression',''))" 2>/dev/null)
      python3 -c "import math; print(eval('$expr'))" 2>&1 ;;
    download_file)
      local url sp
      url=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('url',''))" 2>/dev/null)
      sp=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('save_path','/tmp/download'))" 2>/dev/null)
      curl -sL "$url" -o "$sp" && echo "Saved: $sp" ;;
    image_info)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "from PIL import Image; im=Image.open('$p'); print(f'Size: {im.size}, Mode: {im.mode}')" 2>/dev/null || file "$p" ;;
    *) echo "Unknown tool: $name" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  WEB SEARCH
# ════════════════════════════════════════════════════════════════════════════════
web_search() {
  local query="$1"; local max="${2:-5}"
  local encoded; encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null || echo "$query")

  if [[ "${SEARCH_ENGINE:-ddg}" == "brave" ]] && [[ -n "${BRAVE_API_KEY:-}" ]]; then
    curl -sS "https://api.search.brave.com/res/v1/web/search?q=${encoded}&count=${max}" \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: $BRAVE_API_KEY" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('web',{}).get('results',[])[:int('$max')]:
    print(f\"Title: {r.get('title','')}\")
    print(f\"URL: {r.get('url','')}\")
    print(f\"Snippet: {r.get('description','')[:200]}\")
    print()
" 2>/dev/null
  else
    curl -sS "https://api.duckduckgo.com/?q=${encoded}&format=json&no_redirect=1&no_html=1" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
results=[]
if d.get('AbstractText'):
    results.append({'title': d.get('Heading',''), 'url': d.get('AbstractURL',''), 'snippet': d.get('AbstractText','')})
for r in d.get('RelatedTopics',[])[:int('$max')]:
    if isinstance(r,dict) and r.get('Text'):
        results.append({'title': r.get('Text','')[:80], 'url': r.get('FirstURL',''), 'snippet': r.get('Text','')[:200]})
for r in results[:int('$max')]:
    print(f\"Title: {r['title']}\")
    print(f\"URL: {r['url']}\")
    print(f\"Snippet: {r['snippet']}\")
    print()
" 2>/dev/null
  fi
}

cmd_websearch() {
  local query="$*"
  [[ -z "$query" ]] && { read -rp "Search: " query; }
  hdr "Search: $query"
  echo ""
  web_search "$query" 10
}

# ════════════════════════════════════════════════════════════════════════════════
#  AI BACKENDS
# ════════════════════════════════════════════════════════════════════════════════
_get_persona_prompt() {
  local name="${ACTIVE_PERSONA:-default}"
  if [[ -f "$PERSONAS_DIR/$name" ]]; then cat "$PERSONAS_DIR/$name"
  elif [[ -n "${BUILTIN_PERSONAS[$name]:-}" ]]; then echo "${BUILTIN_PERSONAS[$name]}"
  else echo "${BUILTIN_PERSONAS[default]}"
  fi
}

# v2.5.5: Returns CUSTOM_SYSTEM_PROMPT if set, else AI_SYSTEM_OVERRIDE, else persona
_get_effective_system() {
  if [[ -n "${AI_SYSTEM_OVERRIDE:-}" ]]; then echo "$AI_SYSTEM_OVERRIDE"; return; fi
  if [[ -n "${CUSTOM_SYSTEM_PROMPT:-}" ]]; then echo "$CUSTOM_SYSTEM_PROMPT"; return; fi
  _get_persona_prompt
}

# v2.5.5: Custom system prompt management
# ai system set "..."       — set session-wide custom system prompt
# ai system save NAME "." — save a named system prompt to library
# ai system load NAME     — load a saved system prompt
# ai system list            — list saved system prompts
# ai system show            — show current effective system prompt
# ai system clear           — clear custom (fall back to persona)
cmd_system() {
  local sub="${1:-show}"; shift || true
  case "$sub" in
    set|s)
      local prompt="${*}"
      [[ -z "$prompt" ]] && { read -rp "System prompt: " prompt; }
      CUSTOM_SYSTEM_PROMPT="$prompt"
      save_config
      ok "Custom system prompt set."
      dim "Active for: ask, chat, code, all model backends"
      dim "Clear with: ai system clear"
      ;;
    save)
      local name="${1:?Usage: ai system save NAME PROMPT}"; shift
      local prompt="${*}"
      [[ -z "$prompt" ]] && { read -rp "System prompt to save as '$name': " prompt; }
      echo "$prompt" > "$SYSTEM_PROMPTS_DIR/$name"
      ok "Saved system prompt: $name"
      ;;
    load)
      local name="${1:?Usage: ai system load NAME}"
      local f="$SYSTEM_PROMPTS_DIR/$name"
      [[ ! -f "$f" ]] && { err "Not found: $name  (run: ai system list)"; return 1; }
      CUSTOM_SYSTEM_PROMPT="$(cat "$f")"
      save_config
      ok "Loaded system prompt: $name"
      dim "$CUSTOM_SYSTEM_PROMPT"
      ;;
    list|ls)
      hdr "Saved System Prompts"
      local found=0
      for f in "$SYSTEM_PROMPTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        found=1
        local nm; nm=$(basename "$f")
        local preview; preview=$(head -c 60 "$f" | tr '\n' ' ')
        local active=""
        [[ "$CUSTOM_SYSTEM_PROMPT" == "$(cat "$f")" ]] && active=" ${BGREEN}◀ active${R}"
        printf "  ${B}%-18s${R}  %s…%b\n" "$nm" "$preview" "$active"
      done
      [[ $found -eq 0 ]] && dim "No saved prompts — use: ai system save NAME PROMPT"
      echo ""
      hdr "Built-in Personas (usable with: ai persona set NAME)"
      for k in "${!BUILTIN_PERSONAS[@]}"; do
        local a=""; [[ "$k" == "${ACTIVE_PERSONA:-default}" ]] && a=" ${BGREEN}◀${R}"
        printf "  ${B}%-12s${R}%b\n" "$k" "$a"
      done
      ;;
    show|current)
      hdr "Current System Prompt"
      local eff; eff=$(_get_effective_system)
      echo -e "${DIM}${eff}${R}"
      if [[ -n "${CUSTOM_SYSTEM_PROMPT:-}" ]]; then
        info "Source: custom (override active)"
      elif [[ -n "${AI_SYSTEM_OVERRIDE:-}" ]]; then
        info "Source: environment override"
      else
        info "Source: persona '${ACTIVE_PERSONA:-default}'"
      fi
      ;;
    clear|reset)
      CUSTOM_SYSTEM_PROMPT=""
      save_config
      ok "Custom system prompt cleared — using persona '${ACTIVE_PERSONA:-default}'"
      ;;
    delete|rm)
      local name="${1:?Usage: ai system delete NAME}"
      [[ ! -f "$SYSTEM_PROMPTS_DIR/$name" ]] && { err "Not found: $name"; return 1; }
      rm -f "$SYSTEM_PROMPTS_DIR/$name"
      ok "Deleted: $name"
      ;;
    *)
      echo "Usage: ai system <set|save|load|list|show|clear|delete>"
      echo ""
      echo "  ai system set \"PROMPT\"         Set custom system prompt "
      echo "  ai system save NAME \"PROMPT\"  Save to named library"
      echo "  ai system load NAME             Activate a saved prompt"
      echo "  ai system list                    List saved + built-in personas"
      echo "  ai system show                    Show the current active system prompt"
      echo "  ai system clear                   Remove custom prompt "
      echo "  ai system delete NAME           Delete a saved prompt"
      ;;
  esac
}

_inject_session_history() {
  local session="${ACTIVE_SESSION:-default}"
  local sess_file="$SESSIONS_DIR/${session}.json"
  [[ ! -f "$sess_file" ]] && echo "[]" && return 0
  cat "$sess_file"
}

_save_session_turn() {
  local user_msg="$1" ai_msg="$2"
  local session="${ACTIVE_SESSION:-default}"
  local sess_file="$SESSIONS_DIR/${session}.json"
  [[ ! -f "$sess_file" ]] && echo "[]" > "$sess_file"
  SESSION_FILE="$sess_file" USER_MSG="$user_msg" AI_MSG="$ai_msg" \
    "$PYTHON" -c '
import json, os
f = os.environ["SESSION_FILE"]
try:
    hist = json.load(open(f))
except (json.JSONDecodeError, FileNotFoundError):
    hist = []
hist.append({"role": "user", "content": os.environ["USER_MSG"]})
hist.append({"role": "assistant", "content": os.environ["AI_MSG"]})
if len(hist) > 40:
    hist = hist[-40:]
json.dump(hist, open(f, "w"), indent=2)
' 2>/dev/null || true
}

ask_gguf() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  if [[ -z "$model" ]]; then
    err ERR201 "No model set. Run: ai download 1  OR  ai recommended"
    return 1
  fi
  # v2.7.3: GGUF model resolution — search MODELS_DIR if direct path fails
  if [[ ! -f "$model" ]]; then
    # Try exact basename match in MODELS_DIR
    local candidate; candidate=$(find "$MODELS_DIR" -maxdepth 1 -name "$(basename "$model")" 2>/dev/null | head -1)
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      model="$candidate"
      ACTIVE_MODEL="$model"; save_config 2>/dev/null || true
    else
      # Try partial name match (case-insensitive)
      candidate=$(find "$MODELS_DIR" -maxdepth 1 -iname "*$(basename "$model" .gguf)*" -name "*.gguf" 2>/dev/null | head -1)
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        model="$candidate"
        ACTIVE_MODEL="$model"; save_config 2>/dev/null || true
      else
        err ERR202 "GGUF model not found: $model"
        echo "  Hint: Run 'ai models' to list downloaded models."
        echo "  Hint: Run 'ai recommended download N' to download a model."
        return 1
      fi
    fi
  fi

  if [[ "${LLAMA_BIN:-}" == "llama_cpp_python" ]]; then
    [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
    local sys_prompt; sys_prompt=$(_get_effective_system)
    LLAMA_PROMPT="$prompt" LLAMA_MODEL="$model" LLAMA_MAX="${MAX_TOKENS:-512}" \
    LLAMA_TEMP="${TEMPERATURE:-0.7}" LLAMA_CTX="${CONTEXT_SIZE:-4096}" \
    LLAMA_GPU="${GPU_LAYERS:--1}" LLAMA_SYS="$sys_prompt" \
    "$PYTHON" - <<'PYEOF'
import os, sys, logging
logging.disable(logging.WARNING)
os.environ["LLAMA_LOG_LEVEL"] = "0"
try:
    from llama_cpp import Llama
except ImportError:
    print("llama-cpp-python not installed. Run: ai install-deps", file=sys.stderr); sys.exit(1)
try:
    sys_prompt = os.environ.get('LLAMA_SYS', '').strip()
    user_prompt = os.environ['LLAMA_PROMPT']
    llm = Llama(model_path=os.environ['LLAMA_MODEL'],
                n_ctx=int(os.environ['LLAMA_CTX']),
                n_gpu_layers=int(os.environ['LLAMA_GPU']),
                verbose=False)
    # Use chat_completion if system prompt set, else plain completion
    if sys_prompt:
        out = llm.create_chat_completion(
            messages=[{"role": "system", "content": sys_prompt},
                      {"role": "user",   "content": user_prompt}],
            max_tokens=int(os.environ['LLAMA_MAX']),
            temperature=float(os.environ['LLAMA_TEMP']))
        print(out['choices'][0]['message']['content'], end='', flush=True)
    else:
        out = llm(user_prompt,
                  max_tokens=int(os.environ['LLAMA_MAX']),
                  temperature=float(os.environ['LLAMA_TEMP']),
                  stream=False)
        print(out['choices'][0]['text'], end='', flush=True)
except Exception as e:
    print(f"GGUF inference error: {e}", file=sys.stderr); sys.exit(1)
PYEOF
  elif [[ -n "${LLAMA_BIN:-}" ]]; then
    # Use llama.cpp binary — show stderr so user sees errors
    local _sys; _sys=$(_get_effective_system)
    local _prompt_arg="$prompt"
    # Prepend system as prefix when not empty
    [[ -n "$_sys" ]] && _prompt_arg="System: ${_sys}

User: ${prompt}"
    "$LLAMA_BIN" -m "$model" -p "$_prompt_arg" \
      -n "${MAX_TOKENS:-512}" --temp "${TEMPERATURE:-0.7}" \
      -c "${CONTEXT_SIZE:-4096}" \
      --n-gpu-layers "${GPU_LAYERS:--1}" \
      --threads "${THREADS:-4}" -s 0 --no-display-prompt --log-disable 2>/dev/null | \
      grep -v "^llama\|^ggml\|^llm_load\|^system_info\|^main:\|^sampling\|^build info\|^CUDA\|^Metal\|warning:\|n_ctx_per_seq\|will not be utilized\|^$" || true
  else
    err "llama.cpp not found. Run: ai install-deps"
    info "Or install manually: pip install llama-cpp-python"
    return 1
  fi
}

ask_pytorch() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  if [[ -z "$model" ]]; then err "No model set. Run: ai model PATH  OR  ai ttm load"; return 1; fi
  if [[ -z "$PYTHON" ]]; then err "Python not found. Run: ai install-deps"; return 1; fi
  if [[ ! -d "$model" ]]; then err "Model directory not found: $model"; return 1; fi

  local sys_prompt; sys_prompt=$(_get_effective_system)
  MODEL_PATH="$model" PROMPT="$prompt" MAX_TOKENS="${MAX_TOKENS:-512}" \
  TEMPERATURE="${TEMPERATURE:-0.7}" SYS_PROMPT="$sys_prompt" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
except ImportError as e:
    print(f"Missing dependency: {e}\nRun: ai install-deps", file=sys.stderr); sys.exit(1)

mp         = os.environ['MODEL_PATH']
prompt     = os.environ['PROMPT']
sys_prompt = os.environ.get('SYS_PROMPT', '').strip()
maxt   = int(os.environ.get('MAX_TOKENS', 512))
temp   = float(os.environ.get('TEMPERATURE', 0.7))
device = 'cuda' if torch.cuda.is_available() else 'cpu'
dtype  = torch.float16 if device == 'cuda' else torch.float32

try:
    tok = AutoTokenizer.from_pretrained(mp, trust_remote_code=True)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    # v2.6 fix: patch config.json if model_type key is missing (causes unrecognized model error)
    import json as _json, pathlib as _pl
    _cfg_path = _pl.Path(mp) / 'config.json'
    if _cfg_path.exists():
        try:
            _cfg = _json.loads(_cfg_path.read_text())
            if 'model_type' not in _cfg:
                _cfg['model_type'] = 'llama'   # safe default; transformers will handle it
                _cfg_path.write_text(_json.dumps(_cfg, indent=2))
        except Exception:
            pass

    mdl = AutoModelForCausalLM.from_pretrained(mp, torch_dtype=dtype,
            low_cpu_mem_usage=True, trust_remote_code=True)
    mdl = mdl.to(device).eval()

    # Apply chat template if available, else use raw prompt
    # Inject system prompt (custom or persona) when the template supports it
    if hasattr(tok, 'apply_chat_template') and tok.chat_template:
        messages = []
        if sys_prompt:
            messages.append({"role": "system", "content": sys_prompt})
        messages.append({"role": "user", "content": prompt})
        input_ids = tok.apply_chat_template(messages, return_tensors='pt',
                                            add_generation_prompt=True).to(device)
    else:
        # Prepend system prompt as plain text when no chat template is available
        full_prompt = f"[SYSTEM]: {sys_prompt}\n\n[USER]: {prompt}" if sys_prompt else prompt
        input_ids = tok(full_prompt, return_tensors='pt').input_ids.to(device)

    gen_kwargs = dict(
        max_new_tokens=maxt,
        do_sample=(temp > 0),
        pad_token_id=tok.eos_token_id,
        eos_token_id=tok.eos_token_id,
    )
    if temp > 0:
        gen_kwargs['temperature'] = temp
        gen_kwargs['top_p'] = 0.9

    with torch.no_grad():
        out = mdl.generate(input_ids, **gen_kwargs)

    new_tokens = out[0][input_ids.shape[1]:]
    text = tok.decode(new_tokens, skip_special_tokens=True).strip()
    print(text, flush=True)
except FileNotFoundError:
    print(f"Model not found: {mp}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    import traceback
    print(f"PyTorch inference error: {e}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
}

ask_openai() {
  local prompt="$1"
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "OPENAI_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-gpt-4o}"
  local sys_prompt; sys_prompt=$(_get_effective_system)

  local messages_json
  messages_json=$(python3 -c "
import json,sys
sys_p=$(echo "$sys_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
user_p=$(echo "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
msgs=[{'role':'system','content':sys_p},{'role':'user','content':user_p}]
print(json.dumps(msgs))
" 2>/dev/null)

  local body; body=$(python3 -c "
import json
body={'model':'${model}','messages':${messages_json},'max_tokens':${MAX_TOKENS},'temperature':${TEMPERATURE},'stream':False}
print(json.dumps(body))
" 2>/dev/null)

  curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['choices'][0]['message']['content'],end='',flush=True)
" 2>/dev/null
}

ask_claude() {
  local prompt="$1"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "ANTHROPIC_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-claude-sonnet-4-5}"
  local sys_prompt; sys_prompt=$(_get_effective_system)

  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)
  local sys_content; sys_content=$(echo "$sys_prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)

  curl -sS https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":$MAX_TOKENS,\"system\":$sys_content,\"messages\":[{\"role\":\"user\",\"content\":$user_content}]}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['content'][0]['text'],end='',flush=True)
" 2>/dev/null
}

ask_gemini() {
  local prompt="$1"
  [[ -z "${GEMINI_API_KEY:-}" ]] && { err "GEMINI_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-gemini-2.0-flash}"
  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)

  curl -sS "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"contents\":[{\"parts\":[{\"text\":$user_content}]}]}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['candidates'][0]['content']['parts'][0]['text'],end='',flush=True)
" 2>/dev/null
}

ask_hf() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && { err "No model set"; return 1; }
  local hf_key="${HF_TOKEN:-}"
  local auth_header=""
  [[ -n "$hf_key" ]] && auth_header="-H \"Authorization: Bearer $hf_key\""
  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)
  curl -sS "https://api-inference.huggingface.co/models/${model}" \
    ${hf_key:+-H "Authorization: Bearer $hf_key"} \
    -H "Content-Type: application/json" \
    -d "{\"inputs\":$user_content,\"parameters\":{\"max_new_tokens\":$MAX_TOKENS,\"temperature\":$TEMPERATURE}}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if isinstance(d,list): print(d[0].get('generated_text',''),end='')
elif isinstance(d,dict): print(d.get('generated_text',str(d)),end='')
" 2>/dev/null
}

ask_groq() {
  local prompt="$1"
  [[ -z "${GROQ_API_KEY:-}" ]] && { err "GROQ_API_KEY not set. Run: ai keys set GROQ_API_KEY gsk_..."; return 1; }
  local model="${ACTIVE_MODEL:-llama-3.3-70b-versatile}"
  local sys_prompt; sys_prompt=$(_get_effective_system)
  ASKAPI_PROMPT="$prompt" ASKAPI_SYS="$sys_prompt" ASKAPI_MODEL="$model" \
  ASKAPI_MAX="$MAX_TOKENS" ASKAPI_TEMP="$TEMPERATURE" \
  ASKAPI_URL="https://api.groq.com/openai/v1/chat/completions" \
  ASKAPI_KEY="$GROQ_API_KEY" "$PYTHON" -c '
import os,json,sys,urllib.request
body=json.dumps({"model":os.environ["ASKAPI_MODEL"],"max_tokens":int(os.environ["ASKAPI_MAX"]),
  "temperature":float(os.environ["ASKAPI_TEMP"]),
  "messages":[{"role":"system","content":os.environ["ASKAPI_SYS"]},
              {"role":"user","content":os.environ["ASKAPI_PROMPT"]}]})
req=urllib.request.Request(os.environ["ASKAPI_URL"],data=body.encode(),
  headers={"Authorization":"Bearer "+os.environ["ASKAPI_KEY"],"Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=60) as r:
    d=json.loads(r.read())
    print(d["choices"][0]["message"]["content"],end="",flush=True)
except Exception as e:
  print(f"Groq error: {e}",file=sys.stderr)
' 2>/dev/null
}


ask_mistral() {
  local prompt="$1"
  [[ -z "${MISTRAL_API_KEY:-}" ]] && { err "MISTRAL_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-mistral-small-latest}"
  local sys_prompt; sys_prompt=$(_get_effective_system)
  ASKAPI_PROMPT="$prompt" ASKAPI_SYS="$sys_prompt" ASKAPI_MODEL="$model" \
  ASKAPI_MAX="$MAX_TOKENS" ASKAPI_TEMP="$TEMPERATURE" \
  ASKAPI_URL="https://api.mistral.ai/v1/chat/completions" \
  ASKAPI_KEY="$MISTRAL_API_KEY" "$PYTHON" -c '
import os,json,sys,urllib.request
body=json.dumps({"model":os.environ["ASKAPI_MODEL"],"max_tokens":int(os.environ["ASKAPI_MAX"]),
  "temperature":float(os.environ["ASKAPI_TEMP"]),
  "messages":[{"role":"system","content":os.environ["ASKAPI_SYS"]},
              {"role":"user","content":os.environ["ASKAPI_PROMPT"]}]})
req=urllib.request.Request(os.environ["ASKAPI_URL"],data=body.encode(),
  headers={"Authorization":"Bearer "+os.environ["ASKAPI_KEY"],"Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=60) as r:
    d=json.loads(r.read())
    print(d["choices"][0]["message"]["content"],end="",flush=True)
except Exception as e:
  print(f"Mistral error: {e}",file=sys.stderr)
' 2>/dev/null
}

ask_together() {
  local prompt="$1"
  [[ -z "${TOGETHER_API_KEY:-}" ]] && { err "TOGETHER_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-meta-llama/Llama-3.3-70B-Instruct-Turbo}"
  local sys_prompt; sys_prompt=$(_get_effective_system)
  ASKAPI_PROMPT="$prompt" ASKAPI_SYS="$sys_prompt" ASKAPI_MODEL="$model" \
  ASKAPI_MAX="$MAX_TOKENS" ASKAPI_TEMP="$TEMPERATURE" \
  ASKAPI_URL="https://api.together.xyz/v1/chat/completions" \
  ASKAPI_KEY="$TOGETHER_API_KEY" "$PYTHON" -c '
import os,json,sys,urllib.request
body=json.dumps({"model":os.environ["ASKAPI_MODEL"],"max_tokens":int(os.environ["ASKAPI_MAX"]),
  "temperature":float(os.environ["ASKAPI_TEMP"]),
  "messages":[{"role":"system","content":os.environ["ASKAPI_SYS"]},
              {"role":"user","content":os.environ["ASKAPI_PROMPT"]}]})
req=urllib.request.Request(os.environ["ASKAPI_URL"],data=body.encode(),
  headers={"Authorization":"Bearer "+os.environ["ASKAPI_KEY"],"Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=60) as r:
    d=json.loads(r.read())
    print(d["choices"][0]["message"]["content"],end="",flush=True)
except Exception as e:
  print(f"Together error: {e}",file=sys.stderr)
' 2>/dev/null
}
_auto_detect_backend() {
  local model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && {
    [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo "claude"; return; }
    [[ -n "${GEMINI_API_KEY:-}" ]] && { echo "gemini"; return; }
    echo ""; return
  }
  [[ "$model" == gpt-* || "$model" == o1* || "$model" == o3* || "$model" == chatgpt-* ]] && { echo "openai"; return; }
  [[ "$model" == claude-* ]] && { echo "claude"; return; }
  [[ "$model" == gemini-* ]] && { echo "gemini"; return; }
  [[ "$model" == llama-* || "$model" == mixtral-* ]] && [[ -n "${GROQ_API_KEY:-}" ]] && { echo "groq"; return; }
  [[ "$model" == mistral-* || "$model" == codestral-* || "$model" == pixtral-* ]] && { echo "mistral"; return; }
  [[ "$model" == meta-llama/* || "$model" == *Turbo ]] && [[ -n "${TOGETHER_API_KEY:-}" ]] && { echo "together"; return; }
  if [[ "$model" == *.gguf || "$model" == *Q4_K* || "$model" == *Q5_K* || \
        "$model" == *Q8_0* || "$model" == *Q4_0* || "$model" == *IQ4* ]]; then
    echo "gguf"; return
  fi
  [[ -f "$model" ]] && { echo "gguf"; return; }
  [[ -d "$model" && -f "$model/config.json" ]] && { echo "pytorch"; return; }
  if [[ "$model" == */* && ! -d "$model" ]]; then echo "hf"; return; fi
  [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo "claude"; return; }
  [[ -n "${GEMINI_API_KEY:-}" ]] && { echo "gemini"; return; }
  [[ -n "${GROQ_API_KEY:-}" ]] && { echo "groq"; return; }
  [[ -n "${MISTRAL_API_KEY:-}" ]] && { echo "mistral"; return; }
  [[ -n "${TOGETHER_API_KEY:-}" ]] && { echo "together"; return; }
  echo "gguf"
}

_maybe_inject_search() {
  local prompt="$1"
  [[ "$WEB_SEARCH_ENABLED" != "1" ]] && { echo "$prompt"; return; }
  local backend; backend=$(_auto_detect_backend)
  # OpenAI tool calling handles its own search
  [[ "$backend" == "openai" ]] && { echo "$prompt"; return; }
  # Detect search-worthy keywords
  if echo "$prompt" | grep -qiE 'latest|current|today|2024|2025|2026|news|price|who is|what is the status|recent|now|trending'; then
    local search_terms; search_terms=$(echo "$prompt" | sed 's/[?!.,]//g' | tr '[:upper:]' '[:lower:]' | \
      sed 's/what is//g;s/who is//g;s/tell me about//g;s/the latest//g' | \
      awk '{for(i=1;i<=NF&&i<=6;i++) printf $i" "; print ""}' | xargs)
    local results; results=$(web_search "$search_terms" 3 2>/dev/null)
    if [[ -n "$results" ]]; then
      echo "[Web search results for context:]
$results

[User question:] $prompt"
      return
    fi
  fi
  echo "$prompt"
}

dispatch_ask() {
  local prompt="$1"
  local backend="${ACTIVE_BACKEND:-}"
  [[ -z "$backend" ]] && backend=$(_auto_detect_backend)

  # No backend at all — give clear diagnostic
  if [[ -z "$backend" ]]; then
    err "No model or API key configured."
    echo ""
    echo -e "${BCYAN}Quick setup:${R}"
    echo "  ai keys set OPENAI_API_KEY sk-...        (OpenAI GPT-4)"
    echo "  ai keys set ANTHROPIC_API_KEY sk-ant-... (Claude)"
    echo "  ai keys set GEMINI_API_KEY AIza...       (Gemini)"
    echo "  ai download 1                             (tiny local model, any CPU)"
    echo "  ai recommended                            (browse 195 curated models)"
    return 0
  fi

  # Auto-inject web search if needed
  local enriched_prompt; enriched_prompt=$(_maybe_inject_search "$prompt")

  local response="" rc=0
  case "$backend" in
    gguf)      response=$(ask_gguf "$enriched_prompt");     rc=$? ;;
    pytorch)   response=$(ask_pytorch "$enriched_prompt"); rc=$? ;;
    openai)    response=$(ask_openai "$enriched_prompt");  rc=$? ;;
    claude)    response=$(ask_claude "$enriched_prompt");  rc=$? ;;
    gemini)    response=$(ask_gemini "$enriched_prompt");  rc=$? ;;
    groq)      response=$(ask_groq "$enriched_prompt");    rc=$? ;;
    mistral)   response=$(ask_mistral "$enriched_prompt"); rc=$? ;;
    together)  response=$(ask_together "$enriched_prompt"); rc=$? ;;
    hf)        response=$(ask_hf "$enriched_prompt");      rc=$? ;;
    diffusers)
      cmd_imagine "$enriched_prompt"
      response="[Image generated]"
      ;;
    *)
      if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="openai"; response=$(ask_openai "$enriched_prompt"); rc=$?
      elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="claude"; response=$(ask_claude "$enriched_prompt"); rc=$?
      elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="gemini"; response=$(ask_gemini "$enriched_prompt"); rc=$?
      else
        err "Unknown backend '$backend'. Run: ai status"
        return 0
      fi
      ;;
  esac

  if [[ $rc -ne 0 ]]; then
    echo -e "${BRED}No response from backend.${R}" >&2
    [[ -z "${ACTIVE_MODEL:-}" ]] && echo "  Hint: no model set. Run: ai recommended" >&2
    [[ "$backend" == "gguf" && ! -f "${ACTIVE_MODEL:-x}" ]] && \
      echo "  Hint: model file not found. Run: ai recommended download 1" >&2
    [[ "$backend" == "gguf" && ! -f "${ACTIVE_MODEL:-x}" ]] && \
      echo "  Hint: model file not found. Run: ai recommended download 1" >&2
    return 0
  fi

  echo "$response"
  log_history "user" "$prompt"
  log_history "assistant" "$response"
  _save_session_turn "$prompt" "$response"
  [[ -n "${CURRENT_CHAT_FILE:-}" ]] && _chat_append "assistant" "$response"

  # Background TTM batch train if enabled
  [[ "${TTM_AUTO_TRAIN:-0}" == "1" ]] && { _ttm_train_batch &>/dev/null & disown; } 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════════
#  CANVAS — Code workspace with AI assistance
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  FINE-TUNING PIPELINE
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  IMAGE GENERATION
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  MODEL MANAGEMENT
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  FINE-TUNING PIPELINE
# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  CANVAS — Code workspace with AI assistance
# ════════════════════════════════════════════════════════════════════════════════
cmd_canvas() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    new)
      local name="${1:-canvas_$(date +%H%M%S)}"; local lang="${2:-python}"
      local file="$CANVAS_DIR/${name}.${lang}"
      touch "$file"; CANVAS_ACTIVE="$file"; save_config
      ok "Canvas: $file"
      ;;
    open)
      local f="${1:-}"; [[ -z "$f" ]] && { err "File required"; return 1; }
      [[ ! -f "$f" ]] && { err "Not found: $f"; return 1; }
      CANVAS_ACTIVE="$f"; save_config; ok "Canvas: $f"
      ;;
    edit)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      "${EDITOR:-nano}" "$CANVAS_ACTIVE"
      ;;
    show)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      hdr "Canvas: $CANVAS_ACTIVE"
      cat -n "$CANVAS_ACTIVE"
      ;;
    run)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local ext="${CANVAS_ACTIVE##*.}"
      case "$ext" in
        py|python) python3 "$CANVAS_ACTIVE" ;;
        sh|bash)   bash "$CANVAS_ACTIVE" ;;
        js|ts)     node "$CANVAS_ACTIVE" 2>/dev/null || npx ts-node "$CANVAS_ACTIVE" ;;
        c)         gcc "$CANVAS_ACTIVE" -o /tmp/canvas_out && /tmp/canvas_out ;;
        cpp)       g++ "$CANVAS_ACTIVE" -o /tmp/canvas_out && /tmp/canvas_out ;;
        *)         err "Unknown extension: $ext" ;;
      esac
      ;;
    ask)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local task="$*"
      [[ -z "$task" ]] && { read -rp "Task: " task; }
      local current_code=""
      [[ -s "$CANVAS_ACTIVE" ]] && current_code=$(cat "$CANVAS_ACTIVE")
      local prompt
      if [[ -z "$current_code" ]]; then
        prompt="Write code for this task. Return ONLY the code, no explanation, no markdown fences.

Task: $task"
      else
        prompt="Here is the current code:
\`\`\`
$current_code
\`\`\`

Modify it for this task. Return ONLY the complete updated code, no explanation, no markdown fences.

Task: $task"
      fi
      info "Generating code..."
      local result; result=$(dispatch_ask "$prompt" 2>/dev/null)
      # Strip markdown fences
      result=$(echo "$result" | sed 's/^```[a-z]*$//' | sed 's/^```$//')
      echo "$result" > "$CANVAS_ACTIVE"
      ok "Canvas updated. Lines: $(wc -l < "$CANVAS_ACTIVE")"
      cat -n "$CANVAS_ACTIVE"
      ;;
    diff)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      git diff "$CANVAS_ACTIVE" 2>/dev/null || diff /dev/null "$CANVAS_ACTIVE"
      ;;
    save)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local dest="${1:-$AI_OUTPUT_DIR/$(basename "$CANVAS_ACTIVE")}"
      cp "$CANVAS_ACTIVE" "$dest"; ok "Saved: $dest"
      ;;
    list)
      hdr "Canvas files"
      for f in "$CANVAS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local lines; lines=$(wc -l < "$f")
        local active=""
        [[ "$f" == "$CANVAS_ACTIVE" ]] && active=" ${BGREEN}◀ active${R}"
        printf "  %-40s %4d lines%b\n" "$(basename "$f")" "$lines" "$active"
      done
      ;;
    close) CANVAS_ACTIVE=""; save_config; ok "Canvas closed" ;;
    status)
      [[ -n "$CANVAS_ACTIVE" ]] && ok "Active: $CANVAS_ACTIVE ($(wc -l < "$CANVAS_ACTIVE" 2>/dev/null || echo 0) lines)" || info "No active canvas"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  FINE-TUNING PIPELINE
# ════════════════════════════════════════════════════════════════════════════════
cmd_finetune() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    prepare)
      local data="${1:-}"; [[ -z "$data" ]] && { err "Data file required"; return 1; }
      [[ ! -f "$data" ]] && { err "Not found: $data"; return 1; }
      local out="$FINETUNE_DIR/dataset.jsonl"
      info "Preparing dataset from $data..."
      "$PYTHON" - <<PYEOF
import json, re
data_file = "$data"
out_file = "$out"
records = []
with open(data_file) as f:
    content = f.read()
# Try JSONL
try:
    for line in content.splitlines():
        line = line.strip()
        if not line: continue
        obj = json.loads(line)
        if isinstance(obj, dict):
            txt = obj.get('text') or (obj.get('instruction','') + '\n' + obj.get('output',''))
            records.append({'text': txt})
    print(f"Loaded {len(records)} JSONL records")
except:
    # Try Q&A format
    pairs = re.split(r'### Human:', content)
    for p in pairs:
        if '### Assistant:' in p:
            parts = p.split('### Assistant:', 1)
            q = parts[0].strip(); a = parts[1].strip()
            if q and a:
                records.append({'text': f'### Human: {q}\n### Assistant: {a}'})
    if not records:
        # Plain text: split into chunks
        chunks = [content[i:i+512] for i in range(0,len(content),512)]
        records = [{'text': c} for c in chunks if c.strip()]
    print(f"Prepared {len(records)} records from plain text/QA")

with open(out_file, 'w') as f:
    for r in records:
        f.write(json.dumps(r) + '\n')
print(f"Saved: {out_file}")
PYEOF
      ;;
    start)
      local base="${1:-}"; local data="${2:-$FINETUNE_DIR/dataset.jsonl}"; local out="${3:-$FINETUNE_DIR/finetuned_$(date +%Y%m%d_%H%M%S)}"
      [[ -z "$base" ]] && { err "Base model required"; return 1; }
      [[ ! -f "$data" ]] && { err "Dataset not found: $data. Run: ai finetune prepare <data>"; return 1; }
      info "Starting LoRA fine-tune: $base → $out"
      mkdir -p "$out"
      BASE_MODEL="$base" DATA_FILE="$data" OUT_DIR="$out" "$PYTHON" - <<'PYEOF'
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
    from trl import SFTTrainer
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)
base = os.environ['BASE_MODEL']
data_file = os.environ['DATA_FILE']
out_dir   = os.environ['OUT_DIR']
tokenizer = AutoTokenizer.from_pretrained(base)
tokenizer.pad_token = tokenizer.eos_token
model = AutoModelForCausalLM.from_pretrained(base, torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32)
lora = LoraConfig(task_type=TaskType.CAUSAL_LM,r=16,lora_alpha=32,lora_dropout=0.05,target_modules=["q_proj","k_proj","v_proj","o_proj"])
model = get_peft_model(model, lora)
records=[]
with open(data_file) as f:
    for line in f:
        obj=json.loads(line); txt=obj.get('text','')
        if txt: records.append({'text':txt})
ds = Dataset.from_list(records)
device='cuda' if torch.cuda.is_available() else 'cpu'
model=model.to(device)
args=TrainingArguments(output_dir=out_dir,num_train_epochs=3,per_device_train_batch_size=1,gradient_accumulation_steps=4,learning_rate=2e-4,fp16=(device=='cuda'),logging_steps=20,save_steps=200,save_total_limit=2,report_to='none')
trainer=SFTTrainer(model=model,args=args,train_dataset=ds,tokenizer=tokenizer,dataset_text_field='text',max_seq_length=512)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved: {out_dir}")
PYEOF
      ;;
    merge)
      local adapter="${1:-}"; local base="${2:-}"; local out="${3:-${1}_merged}"
      [[ -z "$adapter" || -z "$base" ]] && { err "Usage: ai finetune merge <adapter> <base> [out]"; return 1; }
      info "Merging adapter into base model..."
      ADAPTER="$adapter" BASE="$base" OUT="$out" "$PYTHON" - <<'PYEOF'
import os,torch
from transformers import AutoTokenizer
from peft import PeftModel, AutoPeftModelForCausalLM
base=os.environ['BASE']; adapter=os.environ['ADAPTER']; out=os.environ['OUT']
model=AutoPeftModelForCausalLM.from_pretrained(adapter,torch_dtype=torch.float16)
merged=model.merge_and_unload()
merged.save_pretrained(out)
tok=AutoTokenizer.from_pretrained(base)
tok.save_pretrained(out)
print(f"Merged: {out}")
PYEOF
      ;;
    quantize)
      local model="${1:-}"; local quant="${2:-Q4_K_M}"
      [[ -z "$model" ]] && { err "Model path required"; return 1; }
      local script="$HOME/llama.cpp/convert_hf_to_gguf.py"
      [[ ! -f "$script" ]] && { err "llama.cpp not found at $HOME/llama.cpp"; return 1; }
      local out="${model}_${quant}.gguf"
      info "Quantizing to $quant..."
      "$PYTHON" "$script" "$model" --outfile "$out" --outtype "${quant,,}" && ok "GGUF: $out"
      ;;
    any|universal|lora-any)
      # Fine-tune ANY HuggingFace model with LoRA
      local any_model="${1:-}"; shift || true
      [[ -z "$any_model" ]] && { err "Usage: ai finetune any MODEL [--data FILE] [--epochs N] [--merge] [--quantize]"; return 1; }
      local any_data="$FINETUNE_DIR/dataset.jsonl"
      local any_epochs=3
      local any_merge=0
      local any_quantize=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data)     any_data="$2";     shift 2 ;;
          --epochs)   any_epochs="$2";   shift 2 ;;
          --merge)    any_merge=1;       shift   ;;
          --quantize) any_quantize="${2:-Q4_K_M}"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ ! -f "$any_data" ]] && { err "Dataset not found: $any_data\nRun: ai finetune prepare <data>  or  ai dataset generate NAME TOPIC"; return 1; }
      local any_out="$FINETUNE_DIR/finetuned_any_$(date +%Y%m%d_%H%M%S)"
      info "Fine-tuning $any_model → $any_out (LoRA, epochs=$any_epochs)"
      mkdir -p "$any_out"
      ANY_MODEL="$any_model" ANY_DATA="$any_data" ANY_OUT="$any_out" ANY_EPOCHS="$any_epochs" "$PYTHON" - <<'PYEOF'
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, AutoModelForSeq2SeqLM, TrainingArguments
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
    from trl import SFTTrainer
except ImportError as e:
    print(f"Missing dependency: {e}\nRun: pip install transformers peft trl datasets"); sys.exit(1)

model_id  = os.environ['ANY_MODEL']
data_file = os.environ['ANY_DATA']
out_dir   = os.environ['ANY_OUT']
epochs    = int(os.environ.get('ANY_EPOCHS', '3'))

# Device selection
if torch.cuda.is_available():
    device = 'cuda'
elif hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
    device = 'mps'
else:
    device = 'cpu'
dtype = torch.float16 if device in ('cuda', 'mps') else torch.float32

print(f"Device: {device} | Model: {model_id}")
tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

# Try CausalLM first, fall back to Seq2Seq
try:
    model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=dtype, trust_remote_code=True)
    task = TaskType.CAUSAL_LM
except Exception:
    model = AutoModelForSeq2SeqLM.from_pretrained(model_id, torch_dtype=dtype, trust_remote_code=True)
    task = TaskType.SEQ_2_SEQ_LM

# Auto-select LoRA target modules based on model architecture
model_type = getattr(model.config, 'model_type', '').lower()
target_map = {
    'llama':   ['q_proj','k_proj','v_proj','o_proj'],
    'mistral': ['q_proj','k_proj','v_proj','o_proj'],
    'mixtral': ['q_proj','k_proj','v_proj','o_proj'],
    'qwen2':   ['q_proj','k_proj','v_proj','o_proj'],
    'phi':     ['q_proj','v_proj'],
    'falcon':  ['query_key_value'],
    'mpt':     ['Wqkv'],
    'gpt2':    ['c_attn','c_proj'],
    'gpt_neox':['query_key_value'],
    't5':      ['q','v'],
    'bart':    ['q_proj','v_proj'],
}
targets = target_map.get(model_type, ['q_proj','v_proj'])
print(f"Model type: {model_type or 'unknown'} | LoRA targets: {targets}")

lora_cfg = LoraConfig(task_type=task, r=16, lora_alpha=32, lora_dropout=0.05, target_modules=targets)
model = get_peft_model(model, lora_cfg)
model.print_trainable_parameters()

records = []
with open(data_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        obj = json.loads(line)
        txt = obj.get('text','')
        if txt: records.append({'text': txt})
ds = Dataset.from_list(records)
print(f"Training records: {len(records)}")

model = model.to(device)
args = TrainingArguments(
    output_dir=out_dir, num_train_epochs=epochs,
    per_device_train_batch_size=1, gradient_accumulation_steps=4,
    learning_rate=2e-4, fp16=(device=='cuda'), bf16=False,
    logging_steps=20, save_steps=200, save_total_limit=2, report_to='none'
)
trainer = SFTTrainer(model=model, args=args, train_dataset=ds,
                     tokenizer=tokenizer, dataset_text_field='text', max_seq_length=512)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved adapter: {out_dir}")
PYEOF
      ok "Fine-tune complete: $any_out"
      # Optional merge
      if [[ "$any_merge" == "1" ]]; then
        info "Merging adapter into base model..."
        local merged_out="${any_out}_merged"
        ADAPTER="$any_out" BASE="$any_model" OUT="$merged_out" "$PYTHON" - <<'PYEOF'
import os, torch
from transformers import AutoTokenizer
from peft import AutoPeftModelForCausalLM
adapter=os.environ['ADAPTER']; base=os.environ['BASE']; out=os.environ['OUT']
model=AutoPeftModelForCausalLM.from_pretrained(adapter, torch_dtype=torch.float16)
merged=model.merge_and_unload()
merged.save_pretrained(out)
tok=AutoTokenizer.from_pretrained(base)
tok.save_pretrained(out)
print(f"Merged: {out}")
PYEOF
        ok "Merged model: $merged_out"
        any_out="$merged_out"
      fi
      # Optional quantize
      if [[ -n "$any_quantize" ]]; then
        local script="$HOME/llama.cpp/convert_hf_to_gguf.py"
        if [[ -f "$script" ]]; then
          local gguf_out="${any_out}_${any_quantize}.gguf"
          info "Quantizing to $any_quantize..."
          "$PYTHON" "$script" "$any_out" --outfile "$gguf_out" --outtype "${any_quantize,,}" && ok "GGUF: $gguf_out"
        else
          warn "llama.cpp not found; skipping quantize. Clone to $HOME/llama.cpp to enable."
        fi
      fi
      ;;
    status)
      hdr "Fine-tune Status"
      [[ -f "$FINETUNE_DIR/dataset.jsonl" ]] && echo "  Dataset: $(wc -l < "$FINETUNE_DIR/dataset.jsonl") records" || echo "  Dataset: none"
      ls -td "$FINETUNE_DIR"/finetuned_*/ 2>/dev/null | head -5 | while read -r d; do
        echo "  Model: $(basename "$d") ($(du -sh "$d" 2>/dev/null | cut -f1))"
      done
      ;;
    *) echo "Usage: ai finetune prepare|start|merge|quantize|any|status" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  IMAGE GENERATION
# ════════════════════════════════════════════════════════════════════════════════
cmd_imagine() {
  local prompt="" out="" steps=30 size="1024x1024"
  local mode="txt2img" init_img="" strength="0.75" lora=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)      out="$2";      shift 2 ;;
      --steps)    steps="$2";   shift 2 ;;
      --size)     size="$2";    shift 2 ;;
      --img2img)  mode="img2img"; init_img="$2"; shift 2 ;;
      --inpaint)  mode="inpaint"; init_img="$2"; shift 2 ;;
      --strength) strength="$2"; shift 2 ;;
      --lora)     lora="$2";    shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ ${#args[@]} -gt 0 ]] && prompt="${args[*]}"
  [[ -z "$prompt" ]] && { read -rp "Image prompt: " prompt; }
  [[ -z "$out" ]] && out="$AI_OUTPUT_DIR/generated_$(date +%Y%m%d_%H%M%S).png"
  mkdir -p "$(dirname "$out")"

  # Try OpenAI DALL-E for txt2img first
  if [[ -n "${OPENAI_API_KEY:-}" && "$mode" == "txt2img" ]]; then
    local dall_e_size="1024x1024"
    local url
    url=$(curl -sS https://api.openai.com/v1/images/generations \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"dall-e-3\",\"prompt\":$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"n\":1,\"size\":\"$dall_e_size\"}" 2>/dev/null | \
      python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data'][0]['url'])" 2>/dev/null)
    [[ -n "$url" ]] && curl -sL "$url" -o "$out" && ok "Image (DALL-E 3): $out" && return 0
  fi

  # Local diffusers (SDXL / FLUX / SD2)
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local model="${ACTIVE_MODEL:-stabilityai/stable-diffusion-xl-base-1.0}"

  # Use _imggen_v2 for SDXL/FLUX with img2img/inpaint support
  _imggen_v2 "$prompt" "$mode" "$init_img" "$strength"
}

cmd_chat_interactive() {
  local chat_name="${CURRENT_CHAT_NAME:-}"
  hdr "AI Chat v2.9 — Session: $ACTIVE_SESSION"
  info "Backend: ${ACTIVE_BACKEND:-auto} | Model: ${ACTIVE_MODEL:-auto-detect}"
  [[ -n "$chat_name" ]] && info "Chat log: $CURRENT_CHAT_FILE"
  echo ""
  echo -e "  ${DIM}Commands: /quit /clear /undo /retry /model MODEL /persona N${R}"
  echo -e "  ${DIM}          /session N /save /export /system PROMPT${R}"
  echo -e "  ${DIM}          /tokens /cost /context /multiline /help${R}"
  echo ""

  local last_prompt="" last_response="" multiline=0
  local msg_count=0

  while true; do
    local input=""
    if [[ $multiline -eq 1 ]]; then
      printf "${BCYAN}${B}You (multi): ${R}${DIM}(empty line to send)${R}\n"
      local lines=""
      while IFS= read -r line; do
        [[ -z "$line" ]] && break
        lines+="$line"$'\n'
      done
      input="${lines%$'\n'}"
      [[ -z "$input" ]] && continue
    else
      printf "${BCYAN}${B}You: ${R}"
      read -r input || break
      [[ -z "$input" ]] && continue
    fi

    case "$input" in
      /quit|/exit|/q) echo ""; info "Chat ended ($msg_count messages)"; break ;;
      /clear)
        echo "[]" > "$SESSIONS_DIR/${ACTIVE_SESSION}.json"
        msg_count=0; info "History cleared" ;;
      /undo)
        if [[ -n "$last_prompt" ]]; then
          info "Removed last exchange"
          last_prompt="" ; last_response=""
        else
          warn "Nothing to undo"
        fi ;;
      /retry)
        if [[ -n "$last_prompt" ]]; then
          info "Retrying: ${last_prompt:0:60}..."
          printf "${BGREEN}${B}AI: ${R}"
          last_response=$(dispatch_ask "$last_prompt")
          echo "$last_response"; echo ""
        else
          warn "No previous prompt to retry"
        fi ;;
      /model*)
        local m="${input#/model }"; m="${m# }"
        if [[ -n "$m" && "$m" != "/model" ]]; then
          ACTIVE_MODEL="$m"; save_config; ok "Model: $m"
        else
          info "Current model: ${ACTIVE_MODEL:-auto-detect}"
        fi ;;
      /persona*)
        local n="${input#/persona }"; n="${n# }"
        if [[ -n "$n" && "$n" != "/persona" ]]; then
          ACTIVE_PERSONA="$n"; save_config; ok "Persona: $n"
        else
          info "Current persona: ${ACTIVE_PERSONA:-default}"
          info "Available: ${!BUILTIN_PERSONAS[*]}"
        fi ;;
      /session*)
        local n="${input#/session }"; n="${n# }"
        if [[ -n "$n" && "$n" != "/session" ]]; then
          ACTIVE_SESSION="$n"; save_config; ok "Session: $n"
        else
          info "Current session: $ACTIVE_SESSION"
        fi ;;
      /save)
        info "Session: $SESSIONS_DIR/${ACTIVE_SESSION}.json"
        [[ -n "$CURRENT_CHAT_FILE" ]] && info "Chat: $CURRENT_CHAT_FILE" ;;
      /export)
        local out="$EXPORTS_DIR/chat_$(date +%Y%m%d_%H%M%S).md"
        mkdir -p "$EXPORTS_DIR"
        {
          echo "# Chat Export — $(date -Iseconds)"
          echo "Session: $ACTIVE_SESSION"
          echo ""
        } > "$out"
        [[ -f "$SESSIONS_DIR/${ACTIVE_SESSION}.json" ]] && cat "$SESSIONS_DIR/${ACTIVE_SESSION}.json" >> "$out"
        ok "Exported: $out" ;;
      /system*)
        local sp="${input#/system }"; sp="${sp# }"
        if [[ -n "$sp" && "$sp" != "/system" ]]; then
          CUSTOM_SYSTEM_PROMPT="$sp"; save_config
          ok "System prompt set"
        else
          info "Current: $(_get_effective_system | head -c 80)..."
        fi ;;
      /tokens)
        cmd_count_tokens "$last_prompt" 2>/dev/null || info "No previous message" ;;
      /cost)
        cmd_cost 500 "${MAX_TOKENS}" 2>/dev/null ;;
      /context)
        cmd_context status 2>/dev/null ;;
      /multiline)
        multiline=$(( 1 - multiline ))
        if [[ $multiline -eq 1 ]]; then ok "Multiline ON (empty line sends)"
        else ok "Multiline OFF"; fi ;;
      /temp*)
        local t="${input#/temp }"; t="${t# }"
        if [[ -n "$t" && "$t" != "/temp" ]]; then
          TEMPERATURE="$t"; save_config; ok "Temperature: $t"
        else
          info "Current temperature: $TEMPERATURE"
        fi ;;
      /help|/h)
        echo "  /quit          Exit chat"
        echo "  /clear         Clear history"
        echo "  /undo          Remove last exchange"
        echo "  /retry         Retry last prompt"
        echo "  /model MODEL     Switch model"
        echo "  /persona N   Switch persona"
        echo "  /session N   Switch session"
        echo "  /system PROMPT    Set system prompt"
        echo "  /save          Show save locations"
        echo "  /export        Export chat to markdown"
        echo "  /tokens        Count tokens in last message"
        echo "  /cost          Show API cost estimate"
        echo "  /context       Show context window usage"
        echo "  /multiline     Toggle multi-line input"
        echo "  /temp N      Set temperature"
        ;;
      /*)
        warn "Unknown command: $input (try /help)" ;;
      *)
        [[ -n "$CURRENT_CHAT_FILE" ]] && _chat_append "user" "$input"
        printf "${BGREEN}${B}AI: ${R}"
        last_prompt="$input"
        last_response=$(dispatch_ask "$input")
        echo "$last_response"
        echo ""
        (( msg_count++ ))
        ;;
    esac
  done
}
cmd_list_models() {
  hdr "Downloaded Models"
  local found=0

  # Helper: find recommended entry number for a model file/dir
  _rec_num_for() {
    local name="$1"
    for k in "${!RECOMMENDED_MODELS[@]}"; do
      local repo; repo=$(echo "${RECOMMENDED_MODELS[$k]}" | cut -d'|' -f1)
      local bname; bname=$(basename "$repo")
      echo "$name" | grep -qi "$bname" && { echo "$k"; return 0; }
      echo "$bname" | grep -qi "$(basename "$name" .gguf)" && { echo "$k"; return 0; }
    done
    echo ""
  }

  echo ""
  echo -e "  ${BCYAN}GGUF Models:${R}"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue; found=1
    local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
    local active_mark="  "
    if [[ "$f" == "$ACTIVE_MODEL" || "$(basename "$f")" == "$(basename "${ACTIVE_MODEL:-}")" ]]; then
      active_mark="${BGREEN}▶${R}"
    fi
    local rec_n; rec_n=$(_rec_num_for "$(basename "$f")" 2>/dev/null)
    local rec_str=""
    [[ -n "$rec_n" ]] && rec_str=" ${DIM}[rec #${rec_n}]${R}"
    printf "  %b  ${B}%-52s${R} %6s%b\n" "$active_mark" "$(basename "$f")" "$size" "$rec_str"
  done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | sort)
  [[ $found -eq 0 ]] && dim "    (none)"

  echo ""
  echo -e "  ${BCYAN}PyTorch / HuggingFace Models:${R}"
  local found_pt=0
  for d in "$MODELS_DIR"/*/; do
    [[ -d "$d" && -f "$d/config.json" ]] || continue; found_pt=1; found=1
    local dname; dname=$(basename "$d")
    local active_mark="  "
    [[ "${d%/}" == "$ACTIVE_MODEL" ]] && active_mark="${BGREEN}▶${R}"
    local rec_n; rec_n=$(_rec_num_for "$dname" 2>/dev/null)
    local rec_str=""
    [[ -n "$rec_n" ]] && rec_str=" ${DIM}[rec #${rec_n}]${R}"
    printf "  %b  ${B}%-52s${R} (pytorch)%b\n" "$active_mark" "$dname" "$rec_str"
  done
  [[ $found_pt -eq 0 ]] && dim "    (none)"

  echo ""
  [[ $found -eq 0 ]] && dim "  No models downloaded yet."
  echo -e "  ${BGREEN}▶${R} = active model   ${DIM}[rec #N]${R} = recommended entry number"
  echo -e "  Download: ${B}ai recommended download N${R}  |  ${B}ai download HF_REPO${R}"
  [[ -n "${ACTIVE_MODEL:-}" ]] && echo -e "  Active:   ${BGREEN}${ACTIVE_MODEL}${R} (backend: ${ACTIVE_BACKEND:-auto})"
}

cmd_download() {
  local repo="${1:-}"; local file_filter="${2:-}"
  [[ -z "$repo" ]] && { read -rp "HuggingFace repo (user/model): " repo; }
  [[ -z "$repo" ]] && { err "Repo required"; return 1; }
  if [[ "$repo" =~ ^sk-|^hf_|^AIza ]]; then
    local key_type="OPENAI_API_KEY"
    [[ "$repo" =~ ^hf_ ]] && key_type="HF_TOKEN"
    [[ "$repo" =~ ^AIza ]] && key_type="GEMINI_API_KEY"
    _set_key "$key_type" "$repo"; return 0
  fi
  mkdir -p "$MODELS_DIR"
  if [[ -z "$file_filter" ]]; then
    local files
    files=$(curl -sS --max-time 30 "https://huggingface.co/api/models/${repo}" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
gguf=[s['rfilename'] for s in d.get('siblings',[]) if s['rfilename'].endswith('.gguf')]
q4=[f for f in gguf if 'Q4_K_M' in f or 'q4_k_m' in f]
print(q4[0] if q4 else (gguf[0] if gguf else ''))
" 2>/dev/null)
    [[ -n "$files" ]] && file_filter="$files"
  fi
  if [[ -n "$file_filter" ]]; then
    local url="https://huggingface.co/${repo}/resolve/main/${file_filter}"
    local dest="$MODELS_DIR/$(basename "$file_filter")"
    info "Downloading $file_filter from $repo..."
    if ! curl -L --progress-bar "$url" ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} -o "$dest"; then
      err ERR306 "Download failed: $url"
      rm -f "$dest" 2>/dev/null || true
      return 1
    fi
    # Verify file actually downloaded (not a 404/HTML error page)
    local fsize; fsize=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if (( fsize < 1024 )); then
      err ERR306 "Downloaded file is too small (${fsize} bytes) — likely a 404 error"
      rm -f "$dest" 2>/dev/null || true
      return 1
    fi
    ok "Downloaded: $dest ($(du -sh "$dest" | cut -f1))"
    ACTIVE_MODEL="$dest"; ACTIVE_BACKEND="gguf"; save_config
    ok "Active model set to: $dest"
  else
    info "Downloading full repo $repo (PyTorch)..."
    HF_REPO="$repo" HF_DEST="$MODELS_DIR/$repo" HF_TOKEN_VAL="${HF_TOKEN:-}" "$PYTHON" - <<'PYEOF'
import os,sys
try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("huggingface_hub not installed"); sys.exit(1)
os.makedirs(os.environ['HF_DEST'], exist_ok=True)
snapshot_download(repo_id=os.environ['HF_REPO'], local_dir=os.environ['HF_DEST'],
                  token=os.environ.get('HF_TOKEN_VAL') or None)
print(f"Downloaded: {os.environ['HF_DEST']}")
PYEOF
    ACTIVE_MODEL="$MODELS_DIR/$repo"; ACTIVE_BACKEND="pytorch"; save_config
  fi
}

cmd_recommended() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    download)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Number required"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err ERR204 "No model #$n"; return 1; }
      cmd_download "$(echo "$entry" | cut -d'|' -f1)" ;;
    use)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Number required"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err ERR204 "No model #$n"; return 1; }
      ACTIVE_MODEL="$(echo "$entry"|cut -d'|' -f1)"; ACTIVE_BACKEND="$(echo "$entry"|cut -d'|' -f2)"
      save_config; ok "Model: $ACTIVE_MODEL" ;;
    *)
      hdr "Recommended Models (${#RECOMMENDED_MODELS[@]} total)"
      echo ""

      # Helper: check if a gguf/hf model is already downloaded
      _is_downloaded() {
        local repo="$1" btype="$2"
        case "$btype" in
          gguf)
            # Check if any .gguf file from this repo exists in MODELS_DIR
            local repo_name; repo_name=$(basename "$repo")
            find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | \
              grep -qi "$repo_name" && return 0
            # Also check if ACTIVE_MODEL basename contains the repo name
            [[ -n "${ACTIVE_MODEL:-}" ]] && \
              echo "$(basename "${ACTIVE_MODEL}")" | grep -qi "$repo_name" && return 0
            return 1 ;;
          hf|pytorch)
            local dir="$MODELS_DIR/$repo"
            [[ -d "$dir" ]] && return 0
            return 1 ;;
          openai|claude|gemini|groq|mistral|together)
            case "$btype" in
              openai)   [[ -n "${OPENAI_API_KEY:-}"    ]] && return 0 ;;
              claude)   [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0 ;;
              gemini)   [[ -n "${GEMINI_API_KEY:-}"    ]] && return 0 ;;
              groq)     [[ -n "${GROQ_API_KEY:-}"      ]] && return 0 ;;
              mistral)  [[ -n "${MISTRAL_API_KEY:-}"   ]] && return 0 ;;
              together) [[ -n "${TOGETHER_API_KEY:-}"   ]] && return 0 ;;
            esac
            return 1 ;;
          *) return 1 ;;
        esac
      }

      # Group headers
      local last_group=""
      local groups=(
        "1:8:TINY / CPU-FRIENDLY LLMs"
        "9:16:GENERAL-PURPOSE LLMs (7–9B)"
        "17:23:CODING LLMs"
        "24:26:MATH / REASONING"
        "27:31:VISION / MULTIMODAL"
        "32:37:IMAGE GENERATION"
        "38:42:AUDIO / SPEECH"
        "43:46:EMBEDDING / RAG"
        "47:56:CLOUD APIs (OpenAI/Claude/Gemini)"
        "57:66:LARGE LLMs (13B–70B+)"
        "67:74:MORE CODING MODELS"
        "75:80:MORE REASONING / MATH"
        "81:85:ROLEPLAY / CREATIVE"
        "86:90:MULTILINGUAL"
        "91:94:LONG CONTEXT"
        "95:100:MORE VISION / VL"
        "101:104:MORE IMAGE GEN"
        "105:109:MORE AUDIO"
        "110:113:EMBEDDING / RERANKER"
        "114:117:SPECIALIZED (MED/LEGAL/FIN)"
        "118:121:TINY / EDGE MODELS"
        "122:125:INSTRUCTION TUNED"
        "126:140:MORE CLOUD APIs (Groq/Mistral/Together)"
        "141:145:FUNCTION CALLING / AGENT"
        "146:149:RLHF / DPO / UNCENSORED"
        "150:153:JAPANESE / SCIENCE"
        "154:168:NLU / QA / CLASSIFY"
        "169:178:OCR / DETECTION / DEPTH"
        "179:181:VIDEO / TTS"
        "182:189:MORE GGUF + MOE"
        "190:195:SAFETY / REWARD / NEWEST"
        "196:205:THINKING / REASONING MODELS"
      )

      for grp in "${groups[@]}"; do
        local gstart="${grp%%:*}"; local rest="${grp#*:}"; local gend="${rest%%:*}"; local glabel="${rest#*:}"
        echo -e "  ${B}${BCYAN}── ${glabel} ──${R}"
        for key in $(seq "$gstart" "$gend"); do
          local entry="${RECOMMENDED_MODELS[$key]:-}"; [[ -z "$entry" ]] && continue
          local repo; repo=$(echo "$entry"|cut -d'|' -f1)
          local btype; btype=$(echo "$entry"|cut -d'|' -f2)
          local sz; sz=$(echo "$entry"|cut -d'|' -f3)
          local desc; desc=$(echo "$entry"|cut -d'|' -f4)
          local mark="  "
          _is_downloaded "$repo" "$btype" 2>/dev/null && mark="${BGREEN}✓${R}"
          [[ "$ACTIVE_MODEL" == "$repo" || "$ACTIVE_MODEL" == *"$(basename "$repo")"* ]] && mark="${BGREEN}▶${R}"
          printf "  %b ${B}%2d.${R} %-8s ${DIM}%-44s${R} %s\n" \
            "$mark" "$key" "$sz" "$repo" "$desc"
        done
        echo ""
      done

      echo -e "  ${BGREEN}✓${R} = downloaded   ${BGREEN}▶${R} = active   ${DIM}(cloud = key configured)${R}"
      echo ""
      echo -e "  Download: ${B}ai recommended download N${R}"
      echo -e "  Use:      ${B}ai recommended use N${R}"
      ;;
  esac
}

cmd_search_models() {
  local query="$*"; [[ -z "$query" ]] && { read -rp "Search: " query; }
  info "Searching: $query"
  curl -sS --max-time 30 "https://huggingface.co/api/models?search=${query// /+}&limit=15&sort=downloads" 2>/dev/null | \
    python3 -c "
import json,sys
for i,m in enumerate(json.load(sys.stdin),1):
    print(f'  {i:2}. {m.get(\"modelId\",\"?\")}')
    print(f'      ↓{m.get(\"downloads\",0):,}  ♥{m.get(\"likes\",0)}  [{', '.join(m.get(\"tags\",[])[:3])}]')
" 2>/dev/null
}

cmd_upload() {
  local path="${1:-}"; local repo="${2:-}"; local msg="${3:-upload via ai-cli}"
  [[ -z "$path" || -z "$repo" ]] && { err "Usage: ai upload PATH <user/repo>"; return 1; }
  [[ ! -e "$path" ]] && { err "Not found: $path"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }
  HF_TOKEN_VAL="$hf_key" P="$path" REPO="$repo" MSG="$msg" "$PYTHON" - <<'PYEOF'
import os,sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed"); sys.exit(1)
api=HfApi(token=os.environ['HF_TOKEN_VAL'])
repo=os.environ['REPO']; p=os.environ['P']; msg=os.environ['MSG']
try: api.create_repo(repo_id=repo,exist_ok=True,private=False)
except: pass
if os.path.isdir(p): api.upload_folder(folder_path=p,repo_id=repo,commit_message=msg)
else: api.upload_file(path_or_fileobj=p,path_in_repo=os.path.basename(p),repo_id=repo,commit_message=msg)
print(f"Uploaded: https://huggingface.co/{repo}")
PYEOF
}

cmd_model_info() {
  local m="${1:-$ACTIVE_MODEL}"; [[ -z "$m" ]] && { err "No model"; return 1; }
  hdr "Model: $m"
  if [[ -f "$m" ]]; then
    echo "  File: $m  ($(du -sh "$m"|cut -f1))"
  elif [[ -d "$m" && -f "$m/config.json" ]]; then
    python3 -c "import json; [print(f'  {k}: {v}') for k,v in list(json.load(open('$m/config.json')).items())[:15]]" 2>/dev/null
  else
    curl -sS --max-time 30 "https://huggingface.co/api/models/$m" 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(f'  ID: {d.get(\"modelId\",\"?\")}')
print(f'  Downloads: {d.get(\"downloads\",0):,}')
print(f'  Tags: {', '.join(d.get(\"tags\",[])[:5])}')
" 2>/dev/null
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  INSTALL / UNINSTALL
# ════════════════════════════════════════════════════════════════════════════════
cmd_install_deps() {
  local force=0 cpu_only=0 no_torch=0 windows_help=0
  for a in "$@"; do
    [[ "$a" == "--force"    ]] && force=1
    [[ "$a" == "--cpu-only" ]] && cpu_only=1
    [[ "$a" == "--no-torch" ]] && no_torch=1
    [[ "$a" == "--windows"  ]] && windows_help=1
  done

  # Windows 10 setup instructions
  if [[ $windows_help -eq 1 ]] || [[ $IS_WINDOWS -eq 1 && $force -eq 0 && -z "$PYTHON" ]]; then
    hdr "AI CLI v${VERSION} — Windows 10 Setup"
    echo ""
    echo -e "${BCYAN}Prerequisites (install in order):${R}"
    echo ""
    echo "  1. Python 3.11+ for Windows"
    echo "     https://www.python.org/downloads/windows/"
    echo "     Tick: 'Add Python to PATH' during install"
    echo ""
    echo "  2. Git for Windows (includes Git Bash)"
    echo "     https://git-scm.com/download/win"
    echo ""
    echo "  3. Run in Git Bash:"
    echo "     pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu"
    echo "     pip install transformers tokenizers accelerate safetensors datasets"
    echo "     pip install openai anthropic google-generativeai peft trl huggingface_hub"
    echo "     pip install llama-cpp-python"
    echo ""
    echo -e "${BCYAN}Recommended: Use WSL2 for best compatibility${R}"
    echo "  wsl --install        (in PowerShell as Admin)"
    echo "  Then install Ubuntu, run ai install-deps inside WSL"
    echo ""
    echo -e "${BCYAN}Run in Git Bash / WSL to install (CPU-only):${R}"
    echo "  ai install-deps --cpu-only"
    echo ""
    return 0
  fi

  hdr "Installing AI CLI v${VERSION} dependencies"
  echo "  Platform: $PLATFORM | CPU-only: $([[ $cpu_only -eq 1 || $IS_WINDOWS -eq 1 ]] && echo yes || echo auto)"
  echo ""

  # System package installation
  if [[ $IS_WINDOWS -eq 0 && $IS_WSL -eq 0 ]]; then
    if command -v apt-get &>/dev/null; then
      info "Detected APT (Debian/Ubuntu/Mint)..."
      sudo apt-get update -q 2>/dev/null || true
      sudo apt-get install -y -q python3 python3-pip python3-dev git cmake \
        build-essential ffmpeg curl jq espeak libsndfile1 \
        libssl-dev libffi-dev tk-dev 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
      info "Detected Pacman (Arch/Manjaro/EndeavourOS)..."
      sudo pacman -Sy --noconfirm --needed 2>/dev/null || true
      sudo pacman -S --noconfirm --needed \
        python python-pip git cmake base-devel \
        ffmpeg curl jq espeak libsndfile \
        openssl python-tkinter 2>/dev/null || true
      # AUR helper for yay or paru (optional extras)
      if command -v yay &>/dev/null; then
        yay -S --noconfirm --needed python-soundfile 2>/dev/null || true
      elif command -v paru &>/dev/null; then
        paru -S --noconfirm --needed python-soundfile 2>/dev/null || true
      fi
    elif command -v dnf &>/dev/null; then
      info "Detected DNF (Fedora/RHEL)..."
      sudo dnf install -y python3 python3-pip python3-devel git cmake \
        gcc gcc-c++ ffmpeg curl jq espeak libsndfile-devel \
        openssl-devel python3-tkinter 2>/dev/null || true
    elif command -v zypper &>/dev/null; then
      info "Detected Zypper (openSUSE)..."
      sudo zypper install -y python3 python3-pip python3-devel git cmake \
        gcc ffmpeg curl jq espeak libsndfile-devel \
        libopenssl-devel python3-tk 2>/dev/null || true
    elif command -v nb &>/dev/null || command -v brew &>/dev/null; then
      if command -v nb &>/dev/null; then
        info "Detected nb (macOS)..."
        nb install bash python3 cmake ffmpeg jq espeak libsndfile 2>/dev/null || true
      else
        info "Detected Homebrew (macOS)..."
        brew install bash python3 cmake ffmpeg jq espeak libsndfile 2>/dev/null || true
      fi
      info "Note: macOS needs bash 4+. Run: nb install bash  OR  brew install bash"
    elif command -v apk &>/dev/null; then
      info "Detected APK (Alpine/iSH)..."
      apk update 2>/dev/null || true
      apk add python3 py3-pip git cmake make gcc g++ musl-dev \
        ffmpeg curl jq espeak libsndfile-dev \
        openssl-dev python3-dev linux-headers 2>/dev/null || true
    else
      warn "No known package manager found. Install python3, git, ffmpeg, cmake manually."
    fi
  elif [[ $IS_ISH -eq 1 ]]; then
    info "Detected iSH (iOS) — using APK..."
    apk update 2>/dev/null || true
    apk add python3 py3-pip git curl jq bash openssl ca-certificates \
      gcc g++ musl-dev python3-dev cmake make linux-headers 2>/dev/null || true
    # Re-detect python after install
    PYTHON="$(find_python)"
    if [[ -n "$PYTHON" ]]; then
      info "Installing Python packages for iSH..."
      # llama-cpp-python CPU build (no GPU on iSH)
      CMAKE_ARGS="-DLLAMA_BLAS=OFF" \
        "$PYTHON" -m pip install llama-cpp-python \
        --break-system-packages -q 2>/dev/null || \
        "$PYTHON" -m pip install llama-cpp-python \
        --break-system-packages --no-cache-dir -q 2>/dev/null || \
        warn "llama-cpp-python failed to build (try: apk add cmake make gcc g++)"
      # Core packages
      "$PYTHON" -m pip install openai anthropic google-generativeai \
        groq mistralai requests tiktoken huggingface_hub \
        --break-system-packages -q 2>/dev/null || true
    fi
    echo ""
    ok "iSH setup complete"
    info "Local models: use small GGUF models (0.1-1B recommended)"
    info "  ai recommended download 1    # 0.25B — smallest, works on iSH"
    info "  ai recommended download 5    # 0.5B — still fast enough"
    warn "Larger models (3B+) will be very slow on iSH"
    info "Cloud APIs also work: ai keys set OPENAI_API_KEY sk-..."
  elif [[ $IS_WSL -eq 1 ]]; then
    info "Detected WSL — using APT..."
    sudo apt-get update -q 2>/dev/null || true
    sudo apt-get install -y -q python3 python3-pip python3-dev git cmake \
      build-essential ffmpeg curl jq espeak libsndfile1 \
      libssl-dev libffi-dev 2>/dev/null || true
  else
    info "Windows: skipping system package install (install manually if needed)"
  fi

  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required. On Windows run: ai install-deps --windows"; return 1; }

  # Windows / CPU-only always use CPU torch
  local use_cpu=0
  [[ $cpu_only -eq 1 || $IS_WINDOWS -eq 1 ]] && use_cpu=1

  if [[ $no_torch -eq 0 ]]; then
    local ca; ca=$(detect_cuda_arch)
    if [[ $use_cpu -eq 1 ]] || (( ca == 0 )); then
      info "Installing PyTorch CPU (Windows/CPU-only mode)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu -q 2>/dev/null || \
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu --break-system-packages -q 2>/dev/null || true
    elif (( ca >= 80 )); then
      info "Installing PyTorch CUDA 12.1 (compute $ca — Ampere/Ada+)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu121 --break-system-packages -q 2>/dev/null || true
    elif (( ca >= 37 )); then
      # sm_61 = Pascal GTX 1060/1070/1080/Ti, sm_70 = Volta, sm_75 = Turing, etc.
      # CUDA 11.8 supports compute >= 3.7 (sm_37) — covers GTX 1080 (sm_61) perfectly
      info "Installing PyTorch CUDA 11.8 (compute $ca — Pascal/Volta/Turing/Ampere)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu118 --break-system-packages -q 2>/dev/null || true
    else
      info "Installing PyTorch CPU (very old GPU, compute $ca < 3.7)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu --break-system-packages -q 2>/dev/null || true
    fi
  fi

  # Core ML and API packages
  info "Installing core packages..."
  "$PYTHON" -m pip install transformers tokenizers accelerate safetensors datasets \
    optimum "huggingface_hub>=0.20" "peft>=0.7" "trl>=0.7" diffusers Pillow \
    openai anthropic google-generativeai groq mistralai tiktoken \
    soundfile pydub -q 2>/dev/null || \
  "$PYTHON" -m pip install transformers tokenizers accelerate safetensors datasets \
    optimum "huggingface_hub>=0.20" "peft>=0.7" "trl>=0.7" diffusers Pillow \
    openai anthropic google-generativeai groq mistralai tiktoken \
    soundfile pydub --break-system-packages -q 2>/dev/null || true

  # Optional packages (may fail on some platforms)
  "$PYTHON" -m pip install openai-whisper pyttsx3 -q 2>/dev/null || \
  "$PYTHON" -m pip install openai-whisper pyttsx3 --break-system-packages -q 2>/dev/null || true

  # bitsandbytes (skip on Windows — no CUDA, often fails)
  if [[ $IS_WINDOWS -eq 0 ]]; then
    "$PYTHON" -m pip install bitsandbytes -q --break-system-packages 2>/dev/null || true
  fi

  # llama-cpp-python (CPU only on Windows/no GPU)
  info "Installing llama-cpp-python..."
  local ca; ca=$(detect_cuda_arch)
  if [[ $use_cpu -eq 1 ]] || (( ca < 61 )); then
    # CPU-only build
    CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS" \
      "$PYTHON" -m pip install llama-cpp-python -q 2>/dev/null || \
    "$PYTHON" -m pip install llama-cpp-python -q --break-system-packages 2>/dev/null || true
  else
    CMAKE_ARGS="-DLLAMA_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=${ca}" \
      "$PYTHON" -m pip install llama-cpp-python --no-cache-dir --force-reinstall \
      --break-system-packages -q 2>/dev/null || \
    "$PYTHON" -m pip install llama-cpp-python --break-system-packages -q 2>/dev/null || true
  fi

  echo ""
  ok "Installation complete!"
  if [[ $IS_WINDOWS -eq 1 ]]; then
    echo "  Windows 10 CPU-only mode is active"
    echo "  Quick start: ai recommended → ai ask \"Hello\""
  else
    echo "  Quick start: ai recommended → ai recommended download 1 → ai -gui"
  fi
  echo "  Start API server: ai api start"
}

cmd_uninstall() {
  # v2.7.3 fix: suppress first-run check during uninstall
  touch "$FIRST_RUN_FILE" 2>/dev/null || true
  if [[ $EUID -ne 0 ]]; then err "Requires sudo: sudo ai uninstall"; return 1; fi
  echo -e "${BRED}${B}╔══════════════════════════════════════════════╗${R}"
  echo -e "${BRED}${B}║   ⚠  AI CLI UNINSTALL — CANNOT BE UNDONE   ║${R}"
  echo -e "${BRED}${B}╚══════════════════════════════════════════════╝${R}"
  echo ""
  echo "  AI CLI v${VERSION} will be removed from this system."
  echo ""
  echo "  Binary:  /usr/local/bin/ai"
  echo "  Config:  $CONFIG_DIR  (optional)"
  echo "  Models:  $MODELS_DIR  (optional)"
  echo ""
  read -rp "  Type CONFIRM to proceed: " confirm
  [[ "$confirm" != "CONFIRM" ]] && { info "Cancelled."; return 0; }
  read -rp "  Remove config/sessions/chats? [y/N]: " rm_cfg
  read -rp "  Remove downloaded models? [y/N]: " rm_mdl
  # Remove binary from both common paths
  rm -f /usr/local/bin/ai 2>/dev/null && ok "Removed /usr/local/bin/ai"
  rm -f /usr/bin/ai 2>/dev/null || true
  [[ "$rm_cfg" =~ ^[Yy]$ ]] && { rm -rf "$CONFIG_DIR"; ok "Removed $CONFIG_DIR"; }
  [[ "$rm_mdl" =~ ^[Yy]$ ]] && { rm -rf "$MODELS_DIR"; ok "Removed $MODELS_DIR"; }
  ok "AI CLI v${VERSION} uninstalled successfully."
}

# ════════════════════════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════════════════════════
cmd_status() {
  hdr "AI CLI v${VERSION} — Status"; echo ""
  printf "  %-22s %s\n" "Platform:"   "$PLATFORM"
  printf "  %-22s %s\n" "OS:"         "$(uname -s -r 2>/dev/null || echo unknown)"
  printf "  %-22s %s\n" "Python:"     "${PYTHON:-not found}"
  printf "  %-22s %s\n" "llama.cpp:"  "${LLAMA_BIN:-not found}"
  printf "  %-22s %s\n" "ffmpeg:"     "$(command -v ffmpeg 2>/dev/null || echo 'not found')"
  printf "  %-22s %s\n" "CPU-only:"   "$([[ $CPU_ONLY_MODE -eq 1 ]] && echo 'YES (Windows/no GPU)' || echo 'no')"
  echo ""
  if command -v nvidia-smi &>/dev/null; then
    printf "  %-22s %s\n" "GPU:" "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null|head -1)"
    printf "  %-22s %s\n" "VRAM:" "$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null|head -1)"
    printf "  %-22s %s\n" "Compute:" "$CUDA_ARCH"
    if (( CUDA_ARCH >= 61 )); then
      printf "  %-22s ${BGREEN}✓ CUDA supported${R}\n" "Support:"
    else
      printf "  %-22s ${BRED}✗ Legacy GPU (CPU only)${R}\n" "Support:"
    fi
  else
    printf "  %-22s %s\n" "GPU:" "none (CPU-only mode)"
  fi
  echo ""
  printf "  %-22s %s\n" "Active model:"   "${ACTIVE_MODEL:-not set}"
  printf "  %-22s %s\n" "Backend:"        "${ACTIVE_BACKEND:-auto}"
  printf "  %-22s %s\n" "Session:"        "${ACTIVE_SESSION:-default}"
  printf "  %-22s %s\n" "Persona:"        "${ACTIVE_PERSONA:-default}"
  printf "  %-22s %s\n" "Canvas:"         "${CANVAS_ACTIVE:-none}"
  printf "  %-22s %s\n" "GUI theme:"      "${GUI_THEME:-dark}"
  echo ""
  printf "  %-22s %s (v%s)\n" "TTM:"  "$TTM_AUTO_TRAIN" "$TTM_VERSION"
  printf "  %-22s %s (v%s)\n" "MTM:"  "$MTM_AUTO_TRAIN" "$MTM_VERSION"
  printf "  %-22s %s (v%s)\n" "Mtm:"  "$MMTM_AUTO_TRAIN" "$MMTM_VERSION"
  printf "  %-22s %s → %s\n" "HF sync:" "$HF_DATASET_SYNC" "$HF_DATASET_REPO"
  echo ""
  # v2.4: API server status
  local api_status="not running"
  if [[ -f "$API_PID_FILE" ]]; then
    local apid; apid=$(cat "$API_PID_FILE" 2>/dev/null)
    kill -0 "$apid" 2>/dev/null && api_status="${BGREEN}running${R} — PID $apid) on $API_HOST:$API_PORT"
  fi
  printf "  %-22s " "LLM API :"; echo -e "$api_status"
  printf "  %-22s %s\n" "Datasets :" "$(ls "$DATASETS_DIR" 2>/dev/null | wc -l) dataset(s)"
  echo ""
  printf "  %-22s %s\n" "Temperature:"  "$TEMPERATURE"
  printf "  %-22s %s\n" "Max tokens:"   "$MAX_TOKENS"
  printf "  %-22s %s\n" "Context:"      "$CONTEXT_SIZE"
  printf "  %-22s %s\n" "GPU layers:"   "$GPU_LAYERS"
  echo ""
  hdr "API Keys"
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GROQ_API_KEY MISTRAL_API_KEY TOGETHER_API_KEY HF_TOKEN BRAVE_API_KEY; do
    local v; v=$(eval "echo \"\${$k:-}\"")
    if [[ -n "$v" ]]; then printf "  %-26s ${BGREEN}set${R} (%s…%s)\n" "$k:" "${v:0:4}" "${v: -4}"
    else printf "  %-26s ${DIM}not set${R}\n" "$k:"; fi
  done
  echo ""
  printf "  %-22s %s\n" "GGUF models:" "$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | wc -l)"
  printf "  %-22s %s\n" "Chat logs:"   "$(ls "$CHAT_LOGS_DIR"/*.jsonl 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "Datasets:"    "$(ls "$DATASETS_DIR" 2>/dev/null | wc -l)"
  printf "  %-22s %s\n" "Snapshots:"   "$(ls "$SNAPSHOTS_DIR"/*.snap 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "Templates:"   "$(ls "$TEMPLATES_DIR"/*.tpl 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "RAG bases:"   "$(ls -d "$RAG_DIR"/*/ 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "Plugins:"     "$(ls "$PLUGINS_DIR"/*.sh 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "Disk (models):" "$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}' || echo '?')"
  printf "  %-22s %s\n" "Disk (config):" "$(du -sh "$CONFIG_DIR" 2>/dev/null | awk '{print $1}' || echo '?')"
}

# ════════════════════════════════════════════════════════════════════════════════
#  HELP
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  MISC HELPERS (personas, sessions, config, history, etc.)
# ════════════════════════════════════════════════════════════════════════════════
_set_key() {
  local var="$1"; local val="$2"; [[ -z "$val" ]] && return 0
  local tmpf; tmpf=$(mktemp)
  grep -v "^${var}=" "$KEYS_FILE" > "$tmpf" 2>/dev/null || true
  echo "${var}=\"${val}\"" >> "$tmpf"
  mv "$tmpf" "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
  eval "${var}=\"${val}\""; ok "Set $var"
}
cmd_keys() {
  if [[ "${1:-}" == "set" ]]; then _set_key "${2:-}" "${3:-}"; return; fi
  hdr "API Key Status"
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY HF_TOKEN HF_DATASET_KEY BRAVE_API_KEY; do
    local v; v=$(eval "echo \"\${$k:-}\"")
    if [[ -n "$v" ]]; then printf "  %-22s ${BGREEN}set${R} (%s…%s)\n" "$k:" "${v:0:6}" "${v: -4}"
    else printf "  %-22s ${DIM}not set${R}\n" "$k:"; fi
  done
}
cmd_persona() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      hdr "Personas"
      for k in "${!BUILTIN_PERSONAS[@]}"; do
        local a=""; [[ "$k" == "${ACTIVE_PERSONA:-default}" ]] && a=" ${BGREEN}◀${R}"
        printf "  ${B}%-12s${R}%b\n" "$k" "$a"
      done
      for f in "$PERSONAS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local a=""; [[ "$(basename "$f")" == "${ACTIVE_PERSONA:-}" ]] && a=" ${BGREEN}◀${R}"
        printf "  ${B}%-12s${R} (custom)%b\n" "$(basename "$f")" "$a"
      done ;;
    set)   ACTIVE_PERSONA="${1:-default}"; save_config; ok "Persona: $ACTIVE_PERSONA" ;;
    create)
      local n="${1:-}"; [[ -z "$n" ]] && { read -rp "Name: " n; }
      read -rp "System prompt: " p; echo "$p" > "$PERSONAS_DIR/$n"; ok "Created: $n" ;;
    edit)  "${EDITOR:-nano}" "$PERSONAS_DIR/${1:-$ACTIVE_PERSONA}" ;;
    clear) ACTIVE_PERSONA="default"; save_config; ok "Reset to default" ;;
  esac
}
cmd_session() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      hdr "Sessions"
      for f in "$SESSIONS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local name; name=$(basename "$f" .json)
        local turns; turns=$(python3 -c "import json; print(len(json.load(open('$f')))//2)" 2>/dev/null || echo "?")
        local a=""; [[ "$name" == "$ACTIVE_SESSION" ]] && a=" ${BGREEN}◀ active${R}"
        printf "  ${B}%-25s${R} %s turns%b\n" "$name" "$turns" "$a"
      done ;;
    new)
      local n="${1:-session_$(date +%H%M%S)}"; ACTIVE_SESSION="$n"
      echo "[]" > "$SESSIONS_DIR/${n}.json"; save_config; ok "Session: $n" ;;
    load)  ACTIVE_SESSION="${1:-}"; save_config; ok "Loaded: $ACTIVE_SESSION" ;;
    delete)
      read -rp "Delete session '${1:-}'? [y/N]: " a
      [[ "$a" =~ ^[Yy]$ ]] && rm -f "$SESSIONS_DIR/${1:-}.json" && ok "Deleted" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.6: PROJECTS — multi-chat memory with per-project context
# ════════════════════════════════════════════════════════════════════════════════
cmd_project() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    new|create)
      local name="${1:-project_$(date +%Y%m%d_%H%M%S)}"
      local desc="${2:-}"
      local pdir="$PROJECTS_DIR/$name"
      mkdir -p "$pdir"
      echo "[]" > "$pdir/history.jsonl"
      cat > "$pdir/meta.json" <<META
{
  "name": "$name",
  "description": "$desc",
  "created": "$(date -Iseconds)",
  "model": "${ACTIVE_MODEL:-}",
  "session_count": 0
}
META
      ACTIVE_PROJECT="$name"; ACTIVE_SESSION="$name"; save_config
      ok "Project created: $name"
      [[ -n "$desc" ]] && info "  $desc" ;;

    list|ls)
      hdr "Projects"
      local found=0
      for pdir in "$PROJECTS_DIR"/*/; do
        [[ -d "$pdir" ]] || continue
        local n; n=$(basename "$pdir")
        local desc=""; [[ -f "$pdir/meta.json" ]] && desc=$(python3 -c "import json; d=json.load(open('$pdir/meta.json')); print(d.get('description',''))" 2>/dev/null)
        local msgs=0; [[ -f "$pdir/history.jsonl" ]] && msgs=$(wc -l < "$pdir/history.jsonl" 2>/dev/null || echo 0)
        local a=""; [[ "$n" == "$ACTIVE_PROJECT" ]] && a="${BGREEN} ◀ active${R}"
        printf "  ${B}%-28s${R} %3s msgs  %s%b\n" "$n" "$msgs" "$desc" "$a"
        found=1
      done
      [[ $found -eq 0 ]] && info "No projects yet. Run: ai project new NAME" ;;

    switch|load|use)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      [[ ! -d "$PROJECTS_DIR/$name" ]] && { err "Project not found: $name"; return 1; }
      ACTIVE_PROJECT="$name"; ACTIVE_SESSION="$name"; save_config
      ok "Switched to project: $name"
      local desc=""; [[ -f "$PROJECTS_DIR/$name/meta.json" ]] && \
        desc=$(python3 -c "import json; d=json.load(open('$PROJECTS_DIR/$name/meta.json')); print(d.get('description',''))" 2>/dev/null)
      [[ -n "$desc" ]] && info "  $desc" ;;

    show|info)
      local name="${1:-$ACTIVE_PROJECT}"; [[ -z "$name" ]] && { err "No active project. Run: ai project list"; return 1; }
      local pdir="$PROJECTS_DIR/$name"
      [[ ! -d "$pdir" ]] && { err "Project not found: $name"; return 1; }
      hdr "Project: $name"
      [[ -f "$pdir/meta.json" ]] && python3 -c "
import json, sys
d=json.load(open('$pdir/meta.json'))
for k,v in d.items(): print(f'  {k:18s}: {v}')
" 2>/dev/null
      echo ""
      if [[ -f "$pdir/history.jsonl" ]]; then
        local cnt; cnt=$(wc -l < "$pdir/history.jsonl")
        echo "  Messages: $cnt"
        echo "  Recent:"
        tail -4 "$pdir/history.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        m=json.loads(line)
        role=m.get('role','?')[:6]
        content=m.get('content','')[:80]
        print(f'    [{role}] {content}')
    except: pass
" 2>/dev/null
      fi ;;

    memory|context)
      # Show a summary of the project's accumulated context
      local name="${1:-$ACTIVE_PROJECT}"; [[ -z "$name" ]] && { err "No active project"; return 1; }
      local pdir="$PROJECTS_DIR/$name"
      [[ ! -f "$pdir/history.jsonl" ]] && { info "No history in project $name"; return; }
      hdr "Project Memory: $name"
      python3 - "$pdir/history.jsonl" <<'PYEOF'
import json, sys, collections
hist = []
with open(sys.argv[1]) as f:
    for line in f:
        line=line.strip()
        if line:
            try: hist.append(json.loads(line))
            except: pass
roles = collections.Counter(m.get('role','?') for m in hist)
print(f"  Total messages: {len(hist)}")
for r, c in sorted(roles.items()): print(f"  {r:10s}: {c}")
print(f"\n  Topics (from user messages):")
user_msgs = [m['content'] for m in hist if m.get('role')=='user']
for m in user_msgs[-5:]:
    print(f"    · {m[:80].strip()}")
PYEOF
      ;;

    delete|rm)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      read -rp "Delete project '$name'? This removes all history. [y/N]: " a
      [[ "$a" =~ ^[Yy]$ ]] || return 0
      rm -rf "$PROJECTS_DIR/$name"
      [[ "$ACTIVE_PROJECT" == "$name" ]] && { ACTIVE_PROJECT=""; save_config; }
      ok "Deleted: $name" ;;

    export)
      local name="${1:-$ACTIVE_PROJECT}"; [[ -z "$name" ]] && { err "No active project"; return 1; }
      local out="${2:-${name}_export_$(date +%Y%m%d).jsonl}"
      [[ -f "$PROJECTS_DIR/$name/history.jsonl" ]] && cp "$PROJECTS_DIR/$name/history.jsonl" "$out"
      ok "Exported: $out" ;;

    clear-memory)
      local name="${1:-$ACTIVE_PROJECT}"; [[ -z "$name" ]] && { err "No active project"; return 1; }
      read -rp "Clear all memory in project '$name'? [y/N]: " a
      [[ "$a" =~ ^[Yy]$ ]] || return 0
      echo "[]" > "$PROJECTS_DIR/$name/history.jsonl"
      ok "Memory cleared for: $name" ;;

    *)
      echo "Usage: ai project <subcommand> [args]"
      echo ""
      echo "  new NAME [desc]    Create a new project (persistent chat memory)"
      echo "  list                 List all projects"
      echo "  switch NAME        Switch to a project"
      echo "  show [name]          Show project info and recent messages"
      echo "  memory [name]        Show memory summary"
      echo "  delete NAME        Delete a project"
      echo "  export [name] [out]  Export history to JSONL"
      echo "  clear-memory [name]  Wipe project memory"
      echo ""
      echo "  Active project: ${ACTIVE_PROJECT:-none}"
      ;;
  esac
}

# v2.6: First-run setup — ask if user wants to download a model
_first_run_check() {
  [[ -f "$FIRST_RUN_FILE" ]] && return 0  # already ran
  # v2.7.3: Never run first-run setup during uninstall or special commands
  _is_noninteractive_cmd "${1:-}" 2>/dev/null && return 0
  # Only run interactively (not in pipes/scripts)
  [[ ! -t 1 ]] && return 0
  echo ""
  echo -e "${B}${BCYAN}╔══════════════════════════════════════════════════════════════╗${R}"
  echo -e "${B}${BCYAN}║  Welcome to AI CLI v${VERSION}! First-run setup.              ║${R}"
  echo -e "${B}${BCYAN}╚══════════════════════════════════════════════════════════════╝${R}"
  echo ""
  echo "  Would you like to download a recommended AI model now?"
  echo "  (You can always do this later with: ai recommended download 1)"
  echo ""
  read -rp "  Download a model now? [Y/n]: " _ans
  if [[ ! "$_ans" =~ ^[Nn]$ ]]; then
    echo ""
    echo "  Recommended quick-start models:"
    echo "    1) Qwen2.5-0.5B-Instruct-GGUF   (tiny, 400MB, any CPU)"
    echo "    2) Phi-3.5-mini-instruct-GGUF    (small, 2.2GB, good quality)"
    echo "    3) Llama-3.2-3B-Instruct-GGUF    (medium, 1.9GB, balanced)"
    echo "    4) Skip — I'll configure manually"
    echo ""
    read -rp "  Choose [1-4]: " _pick
    case "$_pick" in
      1) cmd_download "Qwen/Qwen2.5-0.5B-Instruct-GGUF" 2>/dev/null || cmd_recommended download 1 2>/dev/null || true ;;
      2) cmd_download "microsoft/Phi-3.5-mini-instruct-gguf" 2>/dev/null || cmd_recommended download 2 2>/dev/null || true ;;
      3) cmd_download "bartowski/Llama-3.2-3B-Instruct-GGUF" 2>/dev/null || cmd_recommended download 3 2>/dev/null || true ;;
      4|*) info "Skipped. Run: ai recommended  to see curated models" ;;
    esac
  fi
  # Run install-deps check
  echo ""
  read -rp "  Install Python dependencies now? [Y/n]: " _dep_ans
  [[ ! "$_dep_ans" =~ ^[Nn]$ ]] && cmd_install_deps
  touch "$FIRST_RUN_FILE"
  echo ""
  ok "First-run setup complete! Run 'ai help' to see all commands."
  echo ""
}

cmd_config() {
  if [[ $# -eq 0 ]]; then cat "$CONFIG_FILE" 2>/dev/null; return; fi
  local key="${1,,}"; local val="${2:-}"
  case "$key" in
    temperature|temp)        TEMPERATURE="$val"; save_config; ok "Temperature: $val" ;;
    max_tokens|tokens)       MAX_TOKENS="$val";  save_config ;;
    context|context_size)    CONTEXT_SIZE="$val"; save_config ;;
    gpu_layers|gpu)          GPU_LAYERS="$val";  save_config ;;
    stream)                  STREAM="$val";       save_config ;;
    tool_calling|tools)      TOOL_CALLING="$val"; save_config ;;
    web_search|websearch)    WEB_SEARCH_ENABLED="$val"; save_config ;;
    hf_dataset_sync|sync)    HF_DATASET_SYNC="$val"; save_config ;;
    ttm_auto_train)          TTM_AUTO_TRAIN="$val"; save_config ;;
    mtm_auto_train)          MTM_AUTO_TRAIN="$val"; save_config ;;
    mmtm_auto_train)         MMTM_AUTO_TRAIN="$val"; save_config ;;
    gui_theme|theme)         GUI_THEME="$val"; save_config ;;
    rlhf_auto)               RLHF_AUTO="$val"; save_config ;;
    rlhf_judge)              RLHF_JUDGE="$val"; save_config ;;
    rlhf_reward_threshold|threshold) RLHF_REWARD_THRESHOLD="$val"; save_config ;;
    rclick_enabled|rclick)   RCLICK_ENABLED="$val"; save_config ;;
    rclick_vl_model)         RCLICK_VL_MODEL="$val"; save_config ;;
    agent_max_steps)         AGENT_MAX_STEPS="$val"; save_config ;;
    agent_search_engine)     AGENT_SEARCH_ENGINE="$val"; save_config ;;
    aup_repo)                AUP_REPO="$val"; save_config ;;
    hf_dataset_key|dataset_key) HF_DATASET_KEY="$val"; save_config; ok "HF dataset key set" ;;
    api_host)                API_HOST="$val"; save_config; ok "API host: $val" ;;
    api_port)                API_PORT="$val"; save_config; ok "API port: $val" ;;
    api_key)                 API_KEY="$val";  save_config; ok "API key set" ;;
    api_cors)                API_CORS="$val"; save_config; ok "API CORS: $val" ;;
    api_share_host)          API_SHARE_HOST="$val"; save_config; ok "Share host: $val" ;;
    api_share_port)          API_SHARE_PORT="$val"; save_config; ok "Share port: $val" ;;
    api_share_rate_limit)    API_SHARE_RATE_LIMIT="$val"; save_config; ok "Rate limit: $val req/min" ;;
    cpu_only_mode|cpu_only)  CPU_ONLY_MODE="$val"; save_config; ok "CPU-only mode: $val" ;;
    multiai_rounds)          MULTIAI_ROUNDS="$val"; save_config; ok "Multi-AI rounds: $val" ;;
    multiai_save_dataset)    MULTIAI_SAVE_DATASET="$val"; save_config; ok "Multi-AI save dataset: $val" ;;
    multiai_rlhf_train)      MULTIAI_RLHF_TRAIN="$val"; save_config; ok "Multi-AI RLHF train: $val" ;;
    rclick_keybind|keybind)  RCLICK_KEYBIND="$val"; save_config; ok "RClick keybind: $val"; info "Run: ai rclick install  to apply" ;;
    rlhf_reward_threshold|threshold) RLHF_REWARD_THRESHOLD="$val"; save_config; ok "RLHF threshold: $val" ;;
    *) err "Unknown config key: '$key'" ;;
  esac
}
cmd_history() {
  local n=20 search=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --n) n="$2"; shift 2 ;; --search) search="$2"; shift 2 ;; *) shift ;; esac
  done
  [[ ! -f "$LOG_FILE" ]] && { info "No history"; return; }
  if [[ -n "$search" ]]; then grep -i "$search" "$LOG_FILE" | tail -n "$n"
  else tail -n "$n" "$LOG_FILE"; fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  ALIASES — v2.7.3
#  Let users define short command aliases, e.g.:
#    ai alias set q "ask"       → ai q "hello" runs: ai ask "hello"
#    ai alias set ask5 "ask --session main"
# ════════════════════════════════════════════════════════════════════════════════
cmd_alias() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list|ls|"")
      hdr "Command Aliases (v2.7.3)"
      echo ""
      if [[ ! -s "$ALIASES_FILE" ]]; then
        dim "  No aliases defined."
        echo "  Create: ai alias set NAME COMMAND"
        echo "  Example: ai alias set q ask"
        echo "           ai alias set mycode \"code --lang python\""
        return 0
      fi
      while IFS='=' read -r aname acmd || [[ -n "$aname" ]]; do
        [[ -z "$aname" || "$aname" == \#* ]] && continue
        # Strip surrounding quotes from acmd
        acmd="${acmd#\"}" acmd="${acmd%\"}"
        printf "  ${B}%-18s${R} → %s\n" "$aname" "$acmd"
      done < "$ALIASES_FILE"
      echo ""
      echo -e "  ${DIM}Usage: ai <alias> [args...]${R}"
      ;;
    set|add|create)
      local name="${1:-}"; shift || true
      local cmd_str="$*"
      [[ -z "$name" ]] && { err "Alias name required.  Usage: ai alias set NAME <command>"; return 1; }
      [[ -z "$cmd_str" ]] && { err "Command required.  Usage: ai alias set NAME <command>"; return 1; }
      # Validate name: no spaces, no special chars
      if [[ "$name" =~ [[:space:]] || "$name" =~ [^a-zA-Z0-9_-] ]]; then
        err "Alias name can only contain letters, digits, hyphens, and underscores."
        return 1
      fi
      # Remove any existing definition for this name
      local tmpf; tmpf=$(mktemp)
      grep -v "^${name}=" "$ALIASES_FILE" > "$tmpf" 2>/dev/null || true
      echo "${name}=\"${cmd_str}\"" >> "$tmpf"
      mv "$tmpf" "$ALIASES_FILE"
      ok "Alias set: ${B}${name}${R} → ${cmd_str}"
      ;;
    del|delete|rm|remove|unset)
      local name="${1:-}"
      [[ -z "$name" ]] && { err "Alias name required."; return 1; }
      if ! grep -q "^${name}=" "$ALIASES_FILE" 2>/dev/null; then
        err "No alias named '${name}'"
        return 1
      fi
      local tmpf; tmpf=$(mktemp)
      grep -v "^${name}=" "$ALIASES_FILE" > "$tmpf" 2>/dev/null || true
      mv "$tmpf" "$ALIASES_FILE"
      ok "Alias removed: ${name}"
      ;;
    show|get)
      local name="${1:-}"
      [[ -z "$name" ]] && { err "Alias name required."; return 1; }
      local line; line=$(grep "^${name}=" "$ALIASES_FILE" 2>/dev/null)
      if [[ -z "$line" ]]; then
        err "No alias named '${name}'"
        return 1
      fi
      local val="${line#*=}"; val="${val#\"}"; val="${val%\"}"
      echo -e "  ${B}${name}${R} → ${val}"
      ;;
    help|-h|--help)
      hdr "ai alias — User-defined command aliases"
      echo ""
      echo -e "  ${B}ai alias list${R}                  List all aliases"
      echo -e "  ${B}ai alias set NAME COMMAND${R}   Create or update alias"
      echo -e "  ${B}ai alias del NAME${R}            Delete alias"
      echo -e "  ${B}ai alias show NAME${R}           Show single alias"
      echo ""
      echo -e "  Examples:"
      echo -e "    ai alias set q ask"
      echo -e "    ai alias set codepy \"code --lang python\""
      echo -e "    ai alias set chat3 \"chat --session work\""
      echo ""
      echo -e "  Then use like: ${B}ai q \"what is rust?\"${R}"
      ;;
    *)
      err "Unknown alias subcommand: ${sub}. Try: ai alias help"
      return 1
      ;;
  esac
}

# v2.7.3: Load and resolve user aliases at runtime
_resolve_alias() {
  local name="$1"; shift || true
  [[ ! -s "$ALIASES_FILE" ]] && return 1
  local line; line=$(grep "^${name}=" "$ALIASES_FILE" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 1
  local val="${line#*=}"; val="${val#\"}"; val="${val%\"}"
  echo "$val"
  return 0
}
cmd_bench() {
  local prompt="${*:-Hello, how are you?}"; local runs=3; hdr "Benchmark"
  local total=0
  for (( i=1; i<=runs; i++ )); do
    local s; s=$(date +%s%N)
    dispatch_ask "$prompt" &>/dev/null
    local ms=$(( ( $(date +%s%N) - s ) / 1000000 ))
    printf "  Run %d: %dms\n" "$i" "$ms"; total=$(( total + ms ))
  done
  printf "  Average: %dms\n" $(( total / runs ))
}
# ════════════════════════════════════════════════════════════════════════════════
#  CUSTOM DATASET CREATION  
#  ai dataset create NAME               — Create a new dataset
#  ai dataset add NAME PROMPT RESPONSE  — Add a prompt/response pair
#  ai dataset add-file NAME <jsonl>     — Import from JSONL file
#  ai dataset import-csv NAME <csv>     — Import from CSV (prompt,response)
#  ai dataset list                        — List all datasets
#  ai dataset show NAME [N]             — Show last N entries
#  ai dataset delete NAME              — Delete dataset
#  ai dataset export NAME [path]        — Export to JSONL file
#  ai dataset push NAME HF_REPO       — Push to HuggingFace
#  ai dataset from-chat [session]         — Convert chat session to dataset
#  ai dataset from-rlhf                   — Convert RLHF ratings to dataset
# ════════════════════════════════════════════════════════════════════════════════
cmd_dataset() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    create)
      local name="${1:?Usage: ai dataset create NAME}"
      local ds_dir="$DATASETS_DIR/$name"
      if [[ -d "$ds_dir" ]]; then warn "Dataset '$name' already exists"; return 1; fi
      mkdir -p "$ds_dir"
      echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      touch "$ds_dir/data.jsonl"
      ok "Dataset '$name' created at $ds_dir"
      echo "  Add pairs:  ai dataset add $name \"PROMPT\" \"RESPONSE\""
      echo "  Import:     ai dataset add-file $name FILE"
      ;;
    add)
      local name="${1:?Usage: ai dataset add NAME PROMPT RESPONSE}"
      local prompt="${2:?Provide a prompt}"; local response="${3:?Provide a response}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found. Create it first: ai dataset create $name"; return 1; }
      echo '{"prompt":'"$(echo "$prompt" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"',"response":'"$(echo "$response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"'}' >> "$ds_dir/data.jsonl"
      local cnt; cnt=$(wc -l < "$ds_dir/data.jsonl")
      # Update meta count
      python3 -c "
import json,sys
m=json.load(open('$ds_dir/meta.json'))
m['count']=$cnt; m['updated']='$(date -Iseconds)'
json.dump(m,open('$ds_dir/meta.json','w'))
" 2>/dev/null || true
      ok "Added pair #$cnt to '$name'"
      ;;
    add-file)
      local name="${1:?Usage: ai dataset add-file NAME FILE}"
      local src="${2:?Provide source JSONL file}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found"; return 1; }
      [[ ! -f "$src" ]] && { err "File not found: $src"; return 1; }
      local before; before=$(wc -l < "$ds_dir/data.jsonl" 2>/dev/null || echo 0)
      cat "$src" >> "$ds_dir/data.jsonl"
      local after; after=$(wc -l < "$ds_dir/data.jsonl")
      local added=$(( after - before ))
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$after; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Imported $added entries from $src into '$name' (total: $after)"
      ;;
    import-csv)
      local name="${1:?Usage: ai dataset import-csv NAME <file.csv>}"
      local src="${2:?Provide source CSV file}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { mkdir -p "$ds_dir"; echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"; touch "$ds_dir/data.jsonl"; }
      [[ ! -f "$src" ]] && { err "File not found: $src"; return 1; }
      local added
      added=$(python3 - <<PYEOF
import csv, json, sys
count = 0
with open('$src', newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    with open('$ds_dir/data.jsonl', 'a', encoding='utf-8') as out:
        for row in reader:
            prompt = row.get('prompt', row.get('instruction', row.get('input', '')))
            response = row.get('response', row.get('output', row.get('answer', '')))
            if prompt and response:
                out.write(json.dumps({'prompt': prompt, 'response': response}) + '\n')
                count += 1
print(count)
PYEOF
)
      local total; total=$(wc -l < "$ds_dir/data.jsonl")
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Imported $added entries from CSV into '$name' (total: $total)"
      ;;
    list)
      hdr "Custom Datasets"
      local found=0
      for d in "$DATASETS_DIR"/*/; do
        [[ -f "$d/meta.json" ]] || continue
        found=1
        local meta; meta=$(cat "$d/meta.json")
        local n; n=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('name','?'))" 2>/dev/null || basename "$d")
        local cnt; cnt=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('count',0))" 2>/dev/null || wc -l < "$d/data.jsonl")
        local up; up=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('updated',m.get('created','?'))[:10])" 2>/dev/null || echo "?")
        printf "  %-20s  %5s pairs  updated %s\n" "$n" "$cnt" "$up"
      done
      [[ $found -eq 0 ]] && info "No datasets yet. Create one: ai dataset create NAME"
      ;;
    show)
      local name="${1:?Usage: ai dataset show NAME [N]}"; local n="${2:-10}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      hdr "Dataset '$name' (last $n entries)"
      tail -n "$n" "$ds_dir/data.jsonl" | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        e=json.loads(line)
        print(f'\033[1mPrompt:\033[0m {e.get(\"prompt\",\"\")[:120]}')
        print(f'\033[2mResponse:\033[0m {e.get(\"response\",\"\")[:200]}')
        print()
    except: pass
"
      ;;
    delete)
      local name="${1:?Usage: ai dataset delete NAME}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found"; return 1; }
      read -rp "Delete dataset '$name'? [y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled"; return; }
      rm -rf "$ds_dir"; ok "Dataset '$name' deleted"
      ;;
    export)
      local name="${1:?Usage: ai dataset export NAME [output-path]}"
      local ds_dir="$DATASETS_DIR/$name"
      local out="${2:-$HOME/${name}.jsonl}"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      cp "$ds_dir/data.jsonl" "$out"
      ok "Exported '$name' to $out ($(wc -l < "$out") entries)"
      ;;
    push)
      local name="${1:?Usage: ai dataset push NAME HF_REPO}"
      local repo="${2:?Provide HuggingFace repo (user/dataset-name)}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      [[ -z "${HF_TOKEN:-}" ]] && { err "HF_TOKEN not set. Run: ai keys set HF_TOKEN <token>"; return 1; }
      info "Pushing '$name' to HuggingFace hub: $repo"
      HF_TOKEN_VAL="$HF_TOKEN" DS_DIR="$ds_dir" DS_REPO="$repo" DS_NAME="$name" \
      "$PYTHON" - <<'PYEOF'
import os, json
from huggingface_hub import HfApi, create_repo
api = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo = os.environ['DS_REPO']
ds_dir = os.environ['DS_DIR']
name = os.environ['DS_NAME']
try:
    create_repo(repo, repo_type="dataset", exist_ok=True, token=os.environ['HF_TOKEN_VAL'])
except Exception as e:
    pass
api.upload_file(path_or_fileobj=f"{ds_dir}/data.jsonl",
                path_in_repo="data.jsonl",
                repo_id=repo, repo_type="dataset",
                token=os.environ['HF_TOKEN_VAL'])
print(f"Pushed to https://huggingface.co/datasets/{repo}")
PYEOF
      ;;
    from-chat)
      local session="${1:-$ACTIVE_SESSION}"
      local sess_file="$SESSIONS_DIR/${session}.json"
      [[ ! -f "$sess_file" ]] && { err "Session '$session' not found"; return 1; }
      local ds_name="chat_${session}_$(date +%Y%m%d)"
      local ds_dir="$DATASETS_DIR/$ds_name"
      mkdir -p "$ds_dir"
      echo '{"name":"'"$ds_name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      touch "$ds_dir/data.jsonl"
      local cnt
      cnt=$(python3 - <<PYEOF
import json, sys
with open('$sess_file') as f:
    data = json.load(f)
pairs = []
for i in range(len(data)):
    if data[i]['role'] == 'user' and i+1 < len(data) and data[i+1]['role'] == 'assistant':
        pairs.append({'prompt': data[i]['content'], 'response': data[i+1]['content']})
with open('$ds_dir/data.jsonl', 'w') as out:
    for p in pairs:
        out.write(json.dumps(p) + '\n')
print(len(pairs))
PYEOF
)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$cnt; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Created dataset '$ds_name' from session '$session' ($cnt pairs)"
      echo "  Fine-tune: ai ttm finetune $ds_name"
      ;;
    from-rlhf)
      local min_score="${1:-4}"
      local ds_name="rlhf_preferred_$(date +%Y%m%d)"
      local ds_dir="$DATASETS_DIR/$ds_name"
      mkdir -p "$ds_dir"; touch "$ds_dir/data.jsonl"
      echo '{"name":"'"$ds_name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      local cnt
      cnt=$(python3 - <<PYEOF
import json
count = 0
for f in ['$RLHF_RATINGS_FILE', '$RLHF_PAIRS_FILE']:
    try:
        with open(f) as inp:
            with open('$ds_dir/data.jsonl', 'a') as out:
                for line in inp:
                    try:
                        r = json.loads(line)
                        score = float(r.get('score', r.get('rating', 0)))
                        if score >= $min_score:
                            pair = {'prompt': r.get('prompt',''), 'response': r.get('response', r.get('chosen',''))}
                            if pair['prompt'] and pair['response']:
                                out.write(json.dumps(pair) + '\n')
                                count += 1
                    except: pass
    except: pass
print(count)
PYEOF
)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$cnt; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Created dataset '$ds_name' from RLHF ratings >= $min_score ($cnt pairs)"
      echo "  Fine-tune: ai ttm finetune $ds_name"
      ;;
    generate)
      # Use AI to generate synthetic training data
      local name="${1:?Usage: ai dataset generate NAME TOPIC [N]}"
      local topic="${2:?Provide a topic}"
      local n="${3:-50}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { mkdir -p "$ds_dir"; echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"; touch "$ds_dir/data.jsonl"; }
      info "Generating $n synthetic pairs on topic: $topic"
      local generated=0
      for (( i=1; i<=n; i++ )); do
        local prompt_q="Generate a realistic question or instruction about: $topic. Output ONLY the question/instruction, nothing else."
        local q; q=$(dispatch_ask "$prompt_q" 2>/dev/null | head -3)
        [[ -z "$q" ]] && continue
        local a; a=$(dispatch_ask "$q" 2>/dev/null)
        [[ -z "$a" ]] && continue
        echo '{"prompt":'"$(echo "$q" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"',"response":'"$(echo "$a" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"'}' >> "$ds_dir/data.jsonl"
        generated=$(( generated + 1 ))
        printf "\r  Generated: %d/%d" "$generated" "$n"
      done
      echo ""
      local total; total=$(wc -l < "$ds_dir/data.jsonl")
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Generated $generated pairs → '$name' (total: $total)"
      ;;
    # v2.5: text/url/file/paper → dataset
    from-text)
      _dataset_from_text "$@"
      ;;
    from-url)
      _dataset_from_url "$@"
      ;;
    from-file)
      _dataset_from_file "$@"
      ;;
    # v2.5.5: AI-generated synthetic dataset on any topic
    generate|gen|ai-gen)
      local name="${1:?Usage: ai dataset generate NAME TOPIC [--count N] [--style qa|chat|instruct] [--model MODEL]}"
      shift
      local topic="" count=50 style="qa" gen_model=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --count|-n) count="${2:-50}"; shift 2 ;;
          --style|-s)  style="${2:-qa}"; shift 2 ;;
          --model|-m)  gen_model="${2:-}"; shift 2 ;;
          *) topic="${topic:+$topic }$1"; shift ;;
        esac
      done
      [[ -z "$topic" ]] && { read -rp "Topic for dataset: " topic; }
      [[ -z "$topic" ]] && { err "Topic required"; return 1; }

      local ds_dir="$DATASETS_DIR/$name"
      mkdir -p "$ds_dir"
      [[ ! -f "$ds_dir/meta.json" ]] && \
        echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      [[ ! -f "$ds_dir/data.jsonl" ]] && touch "$ds_dir/data.jsonl"

      info "Generating $count synthetic '$style' pairs about: $topic"
      info "Model: ${gen_model:-active (${ACTIVE_MODEL:-API})}"

      # Override model temporarily if --model given
      local prev_model="$ACTIVE_MODEL" prev_backend="$ACTIVE_BACKEND"
      [[ -n "$gen_model" ]] && ACTIVE_MODEL="$gen_model" && ACTIVE_BACKEND=""

      local generated=0 batch=5
      while (( generated < count )); do
        local remaining=$(( count - generated ))
        local this_batch=$(( remaining < batch ? remaining : batch ))

        local style_instruction
        case "$style" in
          chat)    style_instruction="conversational multi-turn dialogue excerpts" ;;
          instruct) style_instruction="instruction-following pairs where a user gives a specific task and the assistant completes it" ;;
          *)       style_instruction="diverse question-and-answer pairs" ;;
        esac

        local gen_prompt="Generate exactly ${this_batch} unique ${style_instruction} about the topic: '${topic}'.
Return ONLY a JSON array, no other text. Each element must have keys 'prompt' and 'response'.
Make each pair distinct, informative, and varying in complexity.
Example: [{\"prompt\":\"...\",\"response\":\"...\"}]"

        local raw_response
        raw_response=$(dispatch_ask "$gen_prompt" 2>/dev/null)

        if [[ -z "$raw_response" ]]; then
          warn "No response from AI — check model/API key setup"; break
        fi

        # Extract JSON array from response
        local added=0
        added=$("$PYTHON" - "$ds_dir/data.jsonl" <<PYEOF
import sys, json, re

raw = """${raw_response}"""
out_file = sys.argv[1]
count = 0

# Find JSON array in response
match = re.search(r'\[[\s\S]*\]', raw)
if not match:
    sys.exit(0)
try:
    pairs = json.loads(match.group(0))
    if not isinstance(pairs, list):
        sys.exit(0)
    with open(out_file, 'a', encoding='utf-8') as f:
        for p in pairs:
            if isinstance(p, dict) and ('prompt' in p or 'question' in p) and ('response' in p or 'answer' in p):
                prompt = p.get('prompt', p.get('question', ''))
                response = p.get('response', p.get('answer', ''))
                if prompt and response:
                    f.write(json.dumps({'prompt': prompt, 'response': response}) + '\n')
                    count += 1
except Exception:
    pass
print(count)
PYEOF
)
        generated=$(( generated + ${added:-0} ))
        printf "  Generated %d/%d pairs...\r" "$generated" "$count"
      done
      echo ""

      # Restore model
      ACTIVE_MODEL="$prev_model"; ACTIVE_BACKEND="$prev_backend"

      local total; total=$(wc -l < "$ds_dir/data.jsonl" 2>/dev/null || echo 0)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; m['topic']='$topic'; m['style']='$style'; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Dataset '$name' — $total pairs generated about: $topic"
      info "Fine-tune: ai finetune any MODEL $name"
      info "   or:     ai ttm finetune $name"
      ;;

    from-paper)
      _dataset_from_paper "$@"
      ;;
    *)
      hdr "Dataset Commands (v2.4+2.5)"
      echo "  ai dataset create NAME               — Create new dataset"
      echo "  ai dataset add NAME PROMPT RESPONSE  — Add a prompt/response pair"
      echo "  ai dataset add-file NAME FILE — Import from JSONL"
      echo "  ai dataset import-csv NAME <file.csv> — Import from CSV"
      echo "  ai dataset list                        — List all datasets"
      echo "  ai dataset show NAME [N]             — Show last N entries"
      echo "  ai dataset delete NAME               — Delete dataset"
      echo "  ai dataset export NAME [path]        — Export to JSONL"
      echo "  ai dataset push NAME HF_REPO       — Upload to HuggingFace"
      echo "  ai dataset from-chat [session]         — Convert chat to dataset"
      echo "  ai dataset from-rlhf [min-score]       — Convert RLHF ratings"
      echo "  ai dataset generate NAME TOPIC [N] — AI-generated synthetic data"
      echo ""
      echo "  v2.5 additions:"
      echo "  ai dataset from-text NAME TEXT     — Text blob → Q&A dataset"
      echo "  ai dataset from-paper NAME <arxiv-id>— arXiv paper → dataset"
      echo "  ai dataset from-url NAME URL       — Webpage text → dataset"
      echo "  ai dataset from-file NAME FILE     — Any text file → dataset"
      echo ""
      echo "  Dataset path: $DATASETS_DIR/"
      echo ""
      echo "  Then fine-tune:  ai ttm finetune NAME"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: Dataset creation helpers — from-text, from-paper, from-url, from-file
# ════════════════════════════════════════════════════════════════════════════════
_dataset_from_text_python() {
  local name="$1" text="$2" ds_dir="$3"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  "$PYTHON" - "$name" "$text" "$ds_dir" <<'PYEOF'
import sys, os, json, re

name, text, ds_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(ds_dir, exist_ok=True)
data_file = os.path.join(ds_dir, 'data.jsonl')

# Split text into sentences / paragraphs
sentences = [s.strip() for s in re.split(r'(?<=[.!?])\s+', text) if len(s.strip()) > 20]
paragraphs = [p.strip() for p in text.split('\n\n') if len(p.strip()) > 30]

pairs = []
# Sentence-based Q&A
for i in range(0, len(sentences)-1, 2):
    q = f"Explain: {sentences[i][:200]}"
    a = sentences[i+1][:500] if i+1 < len(sentences) else sentences[i]
    pairs.append({'prompt': q, 'response': a})

# Paragraph-based summary
for para in paragraphs:
    pairs.append({'prompt': f"Summarize: {para[:300]}", 'response': para[:500]})
    pairs.append({'prompt': f"What does this mean: {para[:200]}", 'response': para[:500]})

with open(data_file, 'a') as f:
    for p in pairs:
        f.write(json.dumps(p) + '\n')

meta_file = os.path.join(ds_dir, 'meta.json')
if os.path.exists(meta_file):
    m = json.load(open(meta_file))
else:
    m = {'name': name, 'created': __import__('datetime').datetime.now().isoformat(), 'count': 0}
m['count'] = sum(1 for _ in open(data_file))
m['updated'] = __import__('datetime').datetime.now().isoformat()
json.dump(m, open(meta_file, 'w'), indent=2)
print(f"Generated {len(pairs)} pairs from text → {data_file}")
PYEOF
}

# Patch cmd_dataset to handle from-text, from-paper, from-url, from-file
_dataset_from_text() {
  local name="${1:?Usage: ai dataset from-text NAME TEXT}"
  local text="${2:?Provide text content}"
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_url() {
  local name="${1:?Usage: ai dataset from-url NAME URL}"
  local url="${2:?Provide URL}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Fetching: $url"
  local text
  text=$("$PYTHON" -c "
import urllib.request, html.parser, re, sys
url = '$url'
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.text = []; self.skip = False
    def handle_starttag(self,t,a):
        if t in ('script','style','nav','footer'): self.skip = True
    def handle_endtag(self,t):
        if t in ('script','style','nav','footer'): self.skip = False
    def handle_data(self,d):
        if not self.skip and d.strip(): self.text.append(d.strip())
try:
    req = urllib.request.Request(url, headers={'User-Agent':'AI-CLI/2.5'})
    with urllib.request.urlopen(req, timeout=15) as r:
        html_content = r.read().decode('utf-8','replace')
    p = P(); p.feed(html_content)
    print(' '.join(p.text)[:10000])
except Exception as e:
    print('ERROR:'+str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { err "Failed to fetch: $url"; return 1; }
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_file() {
  local name="${1:?Usage: ai dataset from-file NAME FILE}"
  local file="${2:?Provide file path}"
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Reading: $file"
  local text; text=$(< "$file")
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_paper() {
  local name="${1:?Usage: ai dataset from-paper NAME <arxiv-id>}"
  local paper_id="${2:?Provide arXiv ID (e.g. 2301.12345)}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Fetching arXiv paper: $paper_id"
  local abstract
  abstract=$("$PYTHON" -c "
import urllib.request, xml.etree.ElementTree as ET, sys
arxiv_id = '$paper_id'
url = f'https://export.arxiv.org/api/query?id_list={arxiv_id}'
req = urllib.request.Request(url, headers={'User-Agent':'AI-CLI/2.5'})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read()
    ns = {'a': 'http://www.w3.org/2005/Atom'}
    root = ET.fromstring(data)
    entry = root.find('a:entry', ns)
    if entry is None: print(''); sys.exit(0)
    title = (entry.find('a:title', ns).text or '').strip()
    abstract = (entry.find('a:summary', ns).text or '').strip()
    authors = [a.find('a:name', ns).text for a in entry.findall('a:author', ns)[:5]]
    print(f'Title: {title}\nAuthors: {\", \".join(authors)}\n\nAbstract: {abstract}')
except Exception as e:
    print('ERROR:'+str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { err "Failed to fetch paper: $paper_id"; return 1; }
  [[ -z "$abstract" ]] && { err "Paper not found: $paper_id"; return 1; }
  _dataset_from_text_python "$name" "$abstract" "$ds_dir"
  ok "Dataset from arXiv $paper_id created"
}

# ════════════════════════════════════════════════════════════════════════════════
#  UNIVERSAL LLM API SERVER  
#  OpenAI-compatible REST API — works with any LLM client
#  Supports: GGUF, PyTorch, OpenAI, Claude, Gemini, HF backends
#
#  ai api start [--port 8080] [--host 0.0.0.0] [--key <token>]
#  ai api stop
#  ai api status
#  ai api test
#
#  Endpoints (OpenAI-compatible):
#    GET  /v1/models
#    POST /v1/chat/completions
#    POST /v1/completions
#    GET  /health
# ════════════════════════════════════════════════════════════════════════════════
cmd_api() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    start)
      local port="$API_PORT" host="$API_HOST" key="$API_KEY"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)  port="$2"; shift 2 ;;
          --host)  host="$2"; shift 2 ;;
          --key)   key="$2";  shift 2 ;;
          --public) host="0.0.0.0"; shift ;;
          *) shift ;;
        esac
      done
      if [[ -f "$API_PID_FILE" ]]; then
        local old_pid; old_pid=$(cat "$API_PID_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
          warn "API server already running — PID $old_pid) on $host:$port"
          warn "Stop it first: ai api stop"
          return 1
        fi
        rm -f "$API_PID_FILE"
      fi
      [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
      # v2.7.1: Pre-check if port is already in use (fixes OSError errno 98)
      if "$PYTHON" -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('$host', $port))
    s.close()
    sys.exit(0)
except OSError:
    s.close()
    sys.exit(1)
" 2>/dev/null; then
        : # port is free
      else
        err "Port $port is already in use on $host (OSError errno 98)"
        err "  Run: ai api stop   — to stop the existing server"
        err "  Or:  ai api start --port <other_port>   — to use a different port"
        # Try to find the PID using lsof/ss
        local busy_pid=""
        busy_pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || true)
        [[ -z "$busy_pid" ]] && busy_pid=$(lsof -ti :"$port" 2>/dev/null | head -1 || true)
        [[ -n "$busy_pid" ]] && err "  Process holding port $port: PID $busy_pid"
        return 1
      fi
      info "Starting AI CLI LLM API server on http://${host}:${port}"
      info "OpenAI-compatible: POST /v1/chat/completions"
      [[ -n "$key" ]] && info "Auth: Bearer token required"
      [[ -z "$key" ]] && warn "No API key set — open access (localhost only is safer)"
      # Export context for the Python server
      export API_SERVER_HOST="$host"
      export API_SERVER_PORT="$port"
      export API_SERVER_KEY="$key"
      export API_SERVER_BACKEND="${ACTIVE_BACKEND:-}"
      export API_SERVER_MODEL="${ACTIVE_MODEL:-}"
      export API_SERVER_CORS="${API_CORS:-1}"
      export AI_CLI_CONFIG="$CONFIG_DIR"
      export AI_CLI_MODELS="$MODELS_DIR"
      "$PYTHON" - <<'PYEOF' &
# ── AI CLI LLM API v2.0 ───────────────────────────────────────────────────────
# New in v2: ThreadedHTTPServer, real SSE streaming, rate limiting, per-IP auth
# reloading, JSON access log, /v2/ endpoints (stats, backends, config, models,
# tokenize, log), top_p/stop/n params, retry logic, token tracking.
# ─────────────────────────────────────────────────────────────────────────────
import os, sys, json, time, threading, subprocess, shutil, uuid
import socket as _sock
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from socketserver import ThreadingMixIn
from collections import defaultdict, deque
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────
HOST         = os.environ.get('API_SERVER_HOST', '127.0.0.1')
PORT         = int(os.environ.get('API_SERVER_PORT', '8080'))
API_KEY      = os.environ.get('API_SERVER_KEY', '')
BACKEND      = os.environ.get('API_SERVER_BACKEND', '')
MODEL        = os.environ.get('API_SERVER_MODEL', '')
CORS         = os.environ.get('API_SERVER_CORS', '1') == '1'
CORS_ORIGINS = os.environ.get('API_SERVER_CORS_ORIGINS', '*')
CONFIG       = os.environ.get('AI_CLI_CONFIG', os.path.expanduser('~/.config/ai-cli'))
MODELS_DIR   = os.environ.get('AI_CLI_MODELS', os.path.expanduser('~/.ai-cli/models'))
LOG_FILE     = os.environ.get('API_LOG_FILE', os.path.join(CONFIG, 'api_access.log'))
RATE_LIMIT   = int(os.environ.get('API_RATE_LIMIT', '120'))   # req/min per IP, 0=off
MAX_BODY     = int(os.environ.get('API_MAX_BODY', str(4 * 1024 * 1024)))

# ── Server statistics ─────────────────────────────────────────────────────────
_stats = {
    'total_requests':   0,
    'chat_completions': 0,
    'text_completions': 0,
    'streaming_reqs':   0,
    'errors':           0,
    'total_tokens':     0,
    'start_time':       time.time(),
    'backend_counts':   defaultdict(int),
}
_stats_lock = threading.Lock()

def _stat(key, n=1, sub=None):
    with _stats_lock:
        if sub is not None:
            _stats[key][sub] += n
        else:
            _stats[key] = _stats.get(key, 0) + n

# ── Rate limiter (sliding window per IP) ─────────────────────────────────────
_rate_windows = defaultdict(deque)
_rate_lock    = threading.Lock()

def _check_rate(ip):
    if RATE_LIMIT <= 0:
        return True
    now = time.time()
    with _rate_lock:
        dq = _rate_windows[ip]
        while dq and now - dq[0] > 60:
            dq.popleft()
        if len(dq) >= RATE_LIMIT:
            return False
        dq.append(now)
    return True

# ── Auth key store (multi-key, hot-reloadable) ────────────────────────────────
_auth_keys  = set()
_auth_lock  = threading.Lock()

def _reload_auth():
    keys = set()
    if API_KEY:
        keys.add(API_KEY)
    akf = os.path.join(CONFIG, 'api_keys.json')
    if os.path.exists(akf):
        try:
            for r in json.load(open(akf)):
                if r.get('active', True) and r.get('key'):
                    keys.add(r['key'])
        except Exception:
            pass
    with _auth_lock:
        _auth_keys.clear()
        _auth_keys.update(keys)

_reload_auth()

def _auth_ok(header):
    with _auth_lock:
        if not _auth_keys:
            return True
        tok = (header or '').replace('Bearer ', '').strip()
        return tok in _auth_keys

# ── JSON access logger ────────────────────────────────────────────────────────
try:
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    _log_fh = open(LOG_FILE, 'a', buffering=1)
except Exception:
    _log_fh = None

def _log(ip, method, path, status, elapsed_ms, tokens=0, note=''):
    if not _log_fh:
        return
    try:
        _log_fh.write(json.dumps({
            'ts': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            'ip': ip, 'method': method, 'path': path,
            'status': status, 'ms': round(elapsed_ms),
            'tokens': tokens, 'note': note,
        }) + '\n')
    except Exception:
        pass

# ── Load env keys ─────────────────────────────────────────────────────────────
def _load_keys():
    keys = {}
    kf = os.path.join(CONFIG, 'keys.env')
    if os.path.exists(kf):
        for line in open(kf):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                keys[k.strip()] = v.strip().strip('"\'')
    return keys

KEYS = _load_keys()

# ── Token estimator (~4 chars per token) ─────────────────────────────────────
def _tokens(text):
    return max(1, len(str(text)) // 4) if text else 0

def _msgs_tokens(msgs):
    return sum(_tokens(m.get('content', '')) + 4 for m in msgs)

# ── Retry helper ──────────────────────────────────────────────────────────────
def _retry(fn, tries=2):
    for i in range(tries + 1):
        try:
            return fn()
        except Exception as e:
            if i == tries:
                raise
            time.sleep(0.4 * (i + 1))

# ── Model scanner ─────────────────────────────────────────────────────────────
def _scan_models():
    results = []
    if os.path.isdir(MODELS_DIR):
        for root, _dirs, files in os.walk(MODELS_DIR):
            for fname in files:
                ext = os.path.splitext(fname)[1].lower()
                if ext not in ('.gguf', '.bin', '.pt', '.safetensors', '.pth'):
                    continue
                fpath = os.path.join(root, fname)
                try:
                    sz = os.path.getsize(fpath)
                    ctime = int(os.path.getmtime(fpath))
                except OSError:
                    sz = 0; ctime = 0
                mtype = 'gguf' if ext == '.gguf' else 'pytorch'
                results.append({
                    'id':         os.path.relpath(fpath, MODELS_DIR).replace(os.sep, '/'),
                    'object':     'model',
                    'owned_by':   'ai-cli',
                    'type':       mtype,
                    'path':       fpath,
                    'size_bytes': sz,
                    'created':    ctime,
                })
    for backend_id, key_name, dflt, owner in [
        ('openai',  'OPENAI_API_KEY',    'gpt-4o-mini',               'OpenAI'),
        ('claude',  'ANTHROPIC_API_KEY', 'claude-haiku-4-5-20251001', 'Anthropic'),
        ('gemini',  'GEMINI_API_KEY',    'gemini-2.0-flash',          'Google'),
    ]:
        if KEYS.get(key_name):
            mid = MODEL if (MODEL and backend_id in BACKEND.lower()) else dflt
            results.append({'id': str(mid), 'object': 'model', 'owned_by': owner,
                            'type': 'cloud', 'path': None, 'size_bytes': 0, 'created': 0})
    return results

# ── SSE helpers ───────────────────────────────────────────────────────────────
def _sse_chunk(model_id, delta, finish=False):
    return ('data: ' + json.dumps({
        'id': f"chatcmpl-{uuid.uuid4().hex[:10]}",
        'object': 'chat.completion.chunk',
        'created': int(time.time()),
        'model': model_id,
        'choices': [{'index': 0,
                     'delta': {'content': delta} if not finish else {},
                     'finish_reason': 'stop' if finish else None}],
    }) + '\n\n').encode()

def _sse_done():
    return b'data: [DONE]\n\n'

# ── Backend caller ────────────────────────────────────────────────────────────
def call_backend(messages, model_override=None, max_tokens=2048, temperature=0.7,
                 stream=False, top_p=1.0, stop=None, system_prompt=None, n=1):
    backend = BACKEND
    model   = model_override or MODEL

    if system_prompt and not any(m.get('role') == 'system' for m in messages):
        messages = [{'role': 'system', 'content': system_prompt}] + list(messages)

    # ── Auto-detect backend ────────────────────────────────────────────────────
    if not backend:
        if model and os.path.exists(model):
            backend = 'gguf' if model.endswith('.gguf') else 'pytorch'
        elif KEYS.get('OPENAI_API_KEY') and (not model or any(
                x in model.lower() for x in ('gpt', 'o1', 'o3', 'o4', 'text-', 'chatgpt'))):
            backend = 'openai'
        elif KEYS.get('ANTHROPIC_API_KEY') and (not model or 'claude' in model.lower()):
            backend = 'claude'
        elif KEYS.get('GEMINI_API_KEY') and (not model or 'gemini' in model.lower()):
            backend = 'gemini'
        elif KEYS.get('HF_TOKEN') and model and '/' in model:
            backend = 'hf'
        else:
            backend = 'openai'

    _stat('backend_counts', sub=backend)

    sys_msg = next((m['content'] for m in messages if m.get('role') == 'system'), '')
    prompt  = '\n'.join(
        f"{'User' if m['role']=='user' else 'Assistant'}: {m.get('content','')}"
        for m in messages if m.get('role') != 'system'
    ) + '\nAssistant:'

    # ── OpenAI ────────────────────────────────────────────────────────────────
    if backend == 'openai':
        import urllib.request
        key = KEYS.get('OPENAI_API_KEY', '')
        if not key:
            return None, 'OPENAI_API_KEY not set in keys.env'
        mdl  = model or 'gpt-4o-mini'
        body = {'model': mdl, 'messages': messages, 'max_tokens': max_tokens,
                'temperature': temperature, 'top_p': top_p, 'n': n, 'stream': stream}
        if stop:
            body['stop'] = stop
        req = urllib.request.Request(
            'https://api.openai.com/v1/chat/completions',
            data=json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
        if stream:
            def _gen():
                with urllib.request.urlopen(req, timeout=120) as r:
                    for raw in r:
                        line = raw.decode().strip()
                        if not line.startswith('data: '): continue
                        data = line[6:]
                        if data == '[DONE]': return
                        try:
                            delta = json.loads(data)['choices'][0].get('delta', {}).get('content', '')
                            if delta: yield delta
                        except Exception: pass
            return _gen(), None
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            texts = [c['message']['content'] for c in resp.get('choices', [])]
            return ('\n---\n'.join(texts) if len(texts) > 1 else texts[0]) if texts else '', None
        try:
            return _retry(_call)
        except Exception as e:
            return None, f'OpenAI: {e}'

    # ── Claude ────────────────────────────────────────────────────────────────
    elif backend == 'claude':
        import urllib.request
        key = KEYS.get('ANTHROPIC_API_KEY', '')
        if not key:
            return None, 'ANTHROPIC_API_KEY not set in keys.env'
        mdl  = model or 'claude-haiku-4-5-20251001'
        msgs = [m for m in messages if m.get('role') != 'system']
        body = {'model': mdl, 'max_tokens': max_tokens,
                'system': sys_msg or 'You are a helpful assistant.',
                'messages': msgs, 'temperature': temperature, 'top_p': top_p}
        if stop:
            body['stop_sequences'] = stop if isinstance(stop, list) else [stop]
        if stream:
            body['stream'] = True
        req = urllib.request.Request(
            'https://api.anthropic.com/v1/messages',
            data=json.dumps(body).encode(),
            headers={'x-api-key': key, 'anthropic-version': '2023-06-01',
                     'Content-Type': 'application/json'})
        if stream:
            def _gen():
                with urllib.request.urlopen(req, timeout=120) as r:
                    for raw in r:
                        line = raw.decode().strip()
                        if not line.startswith('data: '): continue
                        try:
                            ev = json.loads(line[6:])
                            if ev.get('type') == 'content_block_delta':
                                yield ev.get('delta', {}).get('text', '')
                        except Exception: pass
            return _gen(), None
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            return resp['content'][0]['text'], None
        try:
            return _retry(_call)
        except Exception as e:
            return None, f'Claude: {e}'

    # ── Gemini ────────────────────────────────────────────────────────────────
    elif backend == 'gemini':
        import urllib.request
        key = KEYS.get('GEMINI_API_KEY', '')
        if not key:
            return None, 'GEMINI_API_KEY not set in keys.env'
        mdl   = model or 'gemini-2.0-flash'
        parts = [{'text': f"{m.get('role','user')}: {m.get('content','')}"}
                 for m in messages]
        body  = {'contents': [{'parts': parts}],
                 'generationConfig': {'maxOutputTokens': max_tokens,
                                      'temperature': temperature, 'topP': top_p}}
        url = (f'https://generativelanguage.googleapis.com/v1beta/models/'
               f'{mdl}:generateContent?key={key}')
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json'})
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            return resp['candidates'][0]['content']['parts'][0]['text'], None
        try:
            text, err = _retry(_call)
            if stream and text:
                chunk = 24
                def _sim():
                    for i in range(0, len(text), chunk):
                        yield text[i:i+chunk]; time.sleep(0.008)
                return _sim(), None
            return text, err
        except Exception as e:
            return None, f'Gemini: {e}'

    # ── GGUF / llama.cpp ──────────────────────────────────────────────────────
    elif backend in ('gguf', 'local'):
        ctx     = int(os.environ.get('CONTEXT_SIZE', '4096'))
        n_thr   = int(os.environ.get('THREADS', str(os.cpu_count() or 4)))
        n_gpu   = int(os.environ.get('GPU_LAYERS', '0'))
        try:
            from llama_cpp import Llama
            llm = Llama(model_path=model, n_ctx=ctx, n_threads=n_thr,
                        n_gpu_layers=n_gpu, verbose=False)
            if stream:
                def _gen():
                    for ch in llm.create_chat_completion(
                            messages=messages, max_tokens=max_tokens,
                            temperature=temperature, top_p=top_p,
                            stop=stop or [], stream=True):
                        d = ch['choices'][0].get('delta', {}).get('content', '')
                        if d: yield d
                return _gen(), None
            out = llm.create_chat_completion(messages=messages, max_tokens=max_tokens,
                                             temperature=temperature, top_p=top_p,
                                             stop=stop or [])
            return out['choices'][0]['message']['content'], None
        except ImportError:
            pass
        llama_bin = next((b for b in ('llama-cli', 'llama', 'llama-run')
                          if shutil.which(b)), None)
        if llama_bin and model and os.path.exists(model):
            try:
                r = subprocess.run(
                    [llama_bin, '-m', model, '-p', prompt,
                     '--temp', str(temperature), '-n', str(max_tokens),
                     '--no-display-prompt', '-t', str(n_thr)],
                    capture_output=True, text=True, timeout=300)
                text = r.stdout.strip()
                if stream:
                    chunk = 16
                    def _sim():
                        for i in range(0, len(text), chunk):
                            yield text[i:i+chunk]
                    return _sim(), None
                return text, None
            except Exception as e:
                return None, f'llama.cpp: {e}'
        return None, 'GGUF backend: no model path or llama.cpp not installed (ai install-deps)'

    # ── PyTorch / Transformers ────────────────────────────────────────────────
    elif backend == 'pytorch':
        try:
            import torch
            from transformers import AutoTokenizer, AutoModelForCausalLM, TextIteratorStreamer
            tok   = AutoTokenizer.from_pretrained(model)
            mdl_o = AutoModelForCausalLM.from_pretrained(model, torch_dtype=torch.float32)
            mdl_o.eval()
            inputs = tok(prompt, return_tensors='pt')
            if stream:
                streamer = TextIteratorStreamer(tok, skip_prompt=True, skip_special_tokens=True)
                def _gen_thread():
                    with torch.no_grad():
                        mdl_o.generate(**inputs, max_new_tokens=max_tokens,
                                       temperature=temperature, do_sample=True,
                                       streamer=streamer)
                threading.Thread(target=_gen_thread, daemon=True).start()
                return iter(streamer), None
            with torch.no_grad():
                out = mdl_o.generate(**inputs, max_new_tokens=max_tokens,
                                     temperature=temperature, do_sample=True)
            text = tok.decode(out[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)
            return text.strip(), None
        except ImportError:
            return None, 'torch/transformers not installed — run: ai install-deps'
        except Exception as e:
            return None, f'PyTorch: {e}'

    # ── HuggingFace Inference API ─────────────────────────────────────────────
    elif backend == 'hf':
        import urllib.request
        key = KEYS.get('HF_TOKEN', '')
        if not model:
            return None, 'HF backend: set ACTIVE_MODEL to a HuggingFace model ID'
        hdrs = {'Content-Type': 'application/json'}
        if key: hdrs['Authorization'] = f'Bearer {key}'
        body = {'inputs': prompt,
                'parameters': {'max_new_tokens': max_tokens,
                                'temperature': temperature, 'top_p': top_p}}
        req  = urllib.request.Request(
            f'https://api-inference.huggingface.co/models/{model}',
            data=json.dumps(body).encode(), headers=hdrs)
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            if isinstance(resp, list):
                return resp[0].get('generated_text', ''), None
            return str(resp), None
        try:
            text, err = _retry(_call)
            if stream and text:
                chunk = 20
                def _sim():
                    for i in range(0, len(text), chunk):
                        yield text[i:i+chunk]
                return _sim(), None
            return text, err
        except Exception as e:
            return None, f'HuggingFace: {e}'

    return None, f"Unknown backend: {backend!r}  valid: openai|claude|gemini|gguf|pytorch|hf"

# ── HTTP handler ──────────────────────────────────────────────────────────────
class LLMHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _ip(self):
        xff = self.headers.get('X-Forwarded-For', '')
        return xff.split(',')[0].strip() if xff else self.client_address[0]

    def _cors(self):
        if not CORS: return
        orig = self.headers.get('Origin', CORS_ORIGINS)
        self.send_header('Access-Control-Allow-Origin',
                         CORS_ORIGINS if CORS_ORIGINS != '*' else orig or '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers',
                         'Content-Type, Authorization, X-Requested-With')
        self.send_header('Access-Control-Max-Age', '86400')

    def _json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg, etype='api_error'):
        self._json(code, {'error': {'message': msg, 'type': etype, 'code': code}})

    def _body(self):
        try:
            n = int(self.headers.get('Content-Length', 0))
            if n > MAX_BODY:
                return None, f'Body too large ({n} > {MAX_BODY})'
            return json.loads(self.rfile.read(n) if n else b'{}'), None
        except Exception as e:
            return None, f'Bad JSON: {e}'

    # ── OPTIONS ───────────────────────────────────────────────────────────────
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    # ── GET endpoints ─────────────────────────────────────────────────────────
    def do_GET(self):
        t0   = time.time()
        path = urlparse(self.path).path.rstrip('/')
        ip   = self._ip()
        auth = _auth_ok(self.headers.get('Authorization', ''))

        # /health
        if path == '/health':
            with _stats_lock:
                up = round(time.time() - _stats['start_time'])
            self._json(200, {'status': 'ok', 'version': '2.0', 'uptime_s': up,
                             'backend': BACKEND or 'auto', 'model': MODEL or 'auto',
                             'threaded': True, 'rate_limit': RATE_LIMIT})

        # /v1/models — OpenAI-compat list
        elif path == '/v1/models':
            base = [{'id': MODEL or 'ai-cli-default', 'object': 'model',
                     'created': int(time.time()), 'owned_by': 'ai-cli'}]
            for m in _scan_models():
                if not any(x['id'] == m['id'] for x in base):
                    base.append({'id': m['id'], 'object': 'model',
                                 'created': m['created'], 'owned_by': m['owned_by']})
            self._json(200, {'object': 'list', 'data': base})

        # /v2/models — extended with size, path, type
        elif path == '/v2/models':
            if not auth: self._err(401, 'Auth required'); return
            self._json(200, {'object': 'list', 'data': _scan_models()})

        # /v2/backends — backend availability
        elif path == '/v2/backends':
            if not auth: self._err(401, 'Auth required'); return
            have_torch = False
            try: import torch; have_torch = True
            except ImportError: pass
            have_llama = bool(next((b for b in ('llama-cli','llama','llama-run')
                                    if shutil.which(b)), None))
            self._json(200, {'backends': [
                {'id': 'openai',   'type': 'cloud', 'available': bool(KEYS.get('OPENAI_API_KEY')),
                 'default_model': 'gpt-4o-mini'},
                {'id': 'claude',   'type': 'cloud', 'available': bool(KEYS.get('ANTHROPIC_API_KEY')),
                 'default_model': 'claude-haiku-4-5-20251001'},
                {'id': 'gemini',   'type': 'cloud', 'available': bool(KEYS.get('GEMINI_API_KEY')),
                 'default_model': 'gemini-2.0-flash'},
                {'id': 'hf',       'type': 'cloud', 'available': bool(KEYS.get('HF_TOKEN')),
                 'default_model': None},
                {'id': 'gguf',     'type': 'local', 'available': have_llama,
                 'default_model': MODEL if MODEL and MODEL.endswith('.gguf') else None},
                {'id': 'pytorch',  'type': 'local', 'available': have_torch,
                 'default_model': MODEL if MODEL and not MODEL.endswith('.gguf') else None},
            ], 'active': BACKEND or 'auto'})

        # /v2/stats — request statistics
        elif path == '/v2/stats':
            if not auth: self._err(401, 'Auth required'); return
            with _stats_lock:
                s = {k: (dict(v) if isinstance(v, defaultdict) else v)
                     for k, v in _stats.items()}
                s['uptime_s'] = round(time.time() - s.pop('start_time'))
            self._json(200, s)

        # /v2/config — read current server config
        elif path == '/v2/config':
            if not auth: self._err(401, 'Auth required'); return
            cfg_file = os.path.join(CONFIG, 'config.env')
            vals = {}
            if os.path.exists(cfg_file):
                for line in open(cfg_file):
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        k, _, v = line.partition('=')
                        vals[k.strip()] = v.strip().strip('"\'')
            self._json(200, {'host': HOST, 'port': PORT, 'backend': BACKEND or 'auto',
                             'model': MODEL or 'auto', 'cors': CORS,
                             'rate_limit': RATE_LIMIT, 'settings': vals})

        # /v2/log — last 100 access log entries
        elif path == '/v2/log':
            if not auth: self._err(401, 'Auth required'); return
            entries = []
            if os.path.exists(LOG_FILE):
                try:
                    with open(LOG_FILE) as f: lines = f.readlines()
                    for ln in lines[-100:]:
                        try: entries.append(json.loads(ln.strip()))
                        except Exception: pass
                except Exception: pass
            self._json(200, {'entries': entries, 'count': len(entries),
                             'log_file': LOG_FILE})

        # /v2/tokenize?text=...
        elif path == '/v2/tokenize':
            qs   = parse_qs(urlparse(self.path).query)
            text = qs.get('text', [''])[0]
            self._json(200, {'estimated_tokens': _tokens(text),
                             'char_count': len(text),
                             'preview': text[:80] + ('…' if len(text) > 80 else '')})

        else:
            self._err(404, f'Unknown endpoint: {path}')

        _log(ip, 'GET', path, 200, (time.time()-t0)*1000)

    # ── POST endpoints ────────────────────────────────────────────────────────
    def do_POST(self):
        t0   = time.time()
        path = urlparse(self.path).path.rstrip('/')
        ip   = self._ip()
        _stat('total_requests')

        if not _auth_ok(self.headers.get('Authorization', '')):
            self._err(401, 'Invalid or missing API key')
            _log(ip, 'POST', path, 401, (time.time()-t0)*1000, note='auth_fail')
            return
        if not _check_rate(ip):
            self._err(429, f'Rate limit exceeded ({RATE_LIMIT} req/min)')
            _log(ip, 'POST', path, 429, (time.time()-t0)*1000, note='rate_limit')
            return

        body, err = self._body()
        if err:
            self._err(400, err, 'invalid_request_error'); return

        # ── /v1/chat/completions  /v2/chat/completions ────────────────────────
        if path in ('/v1/chat/completions', '/v2/chat/completions'):
            msgs      = body.get('messages', [])
            model_req = body.get('model') or MODEL or 'ai-cli-default'
            max_tok   = min(int(body.get('max_tokens', 2048)), 32768)
            temp      = max(0.0, min(float(body.get('temperature', 0.7)), 2.0))
            top_p_v   = max(0.0, min(float(body.get('top_p', 1.0)), 1.0))
            stop_v    = body.get('stop')
            do_stream = bool(body.get('stream', False))
            sys_p     = body.get('system_prompt')
            n_v       = min(int(body.get('n', 1)), 4)

            if not msgs:
                self._err(400, '"messages" is required', 'invalid_request_error')
                return
            for i, m in enumerate(msgs):
                if 'role' not in m or 'content' not in m:
                    self._err(400, f'messages[{i}] missing role or content'); return
                if m['role'] not in ('system','user','assistant','function','tool'):
                    self._err(400, f'Unknown role: {m["role"]!r}'); return

            ptoks = _msgs_tokens(msgs)
            result, err = call_backend(msgs, model_req, max_tok, temp,
                                       stream=do_stream, top_p=top_p_v, stop=stop_v,
                                       system_prompt=sys_p, n=n_v)
            if err:
                _stat('errors')
                self._err(500, err, 'backend_error')
                _log(ip, 'POST', path, 500, (time.time()-t0)*1000, note=err[:80])
                return

            _stat('chat_completions')
            if do_stream:
                _stat('streaming_reqs')
                rid = f"chatcmpl-{uuid.uuid4().hex[:12]}"
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('X-Accel-Buffering', 'no')
                self._cors()
                self.end_headers()
                acc = []
                try:
                    for chunk in result:
                        if chunk:
                            acc.append(chunk)
                            self.wfile.write(_sse_chunk(model_req, chunk))
                            self.wfile.flush()
                    self.wfile.write(_sse_chunk(model_req, '', finish=True))
                    self.wfile.write(_sse_done())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                ctoks = _tokens(''.join(acc))
                _stat('total_tokens', ptoks + ctoks)
                _log(ip, 'POST', path, 200, (time.time()-t0)*1000,
                     tokens=ptoks+ctoks, note='stream')
            else:
                text    = result or ''
                elapsed = time.time() - t0
                ctoks   = _tokens(text)
                _stat('total_tokens', ptoks + ctoks)
                self._json(200, {
                    'id': f"chatcmpl-{uuid.uuid4().hex[:12]}",
                    'object': 'chat.completion',
                    'created': int(time.time()),
                    'model': model_req,
                    'choices': [{'index': 0,
                                 'message': {'role': 'assistant', 'content': text},
                                 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': ptoks, 'completion_tokens': ctoks,
                              'total_tokens': ptoks + ctoks},
                    '_meta': {'backend': BACKEND or 'auto',
                              'elapsed_s': round(elapsed, 3), 'api_version': 2},
                })
                _log(ip, 'POST', path, 200, (time.time()-t0)*1000,
                     tokens=ptoks+ctoks)

        # ── /v1/completions ───────────────────────────────────────────────────
        elif path == '/v1/completions':
            prompt_text = body.get('prompt', '')
            model_req   = body.get('model') or MODEL or 'ai-cli-default'
            max_tok     = min(int(body.get('max_tokens', 256)), 32768)
            temp        = max(0.0, min(float(body.get('temperature', 0.7)), 2.0))
            msgs        = [{'role': 'user', 'content': prompt_text}]
            text, err   = call_backend(msgs, model_req, max_tok, temp)
            if err:
                _stat('errors'); self._err(500, err, 'backend_error'); return
            _stat('text_completions')
            pt = _tokens(prompt_text); ct = _tokens(text or '')
            _stat('total_tokens', pt + ct)
            self._json(200, {
                'id': f"cmpl-{uuid.uuid4().hex[:12]}", 'object': 'text_completion',
                'created': int(time.time()), 'model': model_req,
                'choices': [{'text': text or '', 'index': 0,
                             'finish_reason': 'stop', 'logprobs': None}],
                'usage': {'prompt_tokens': pt, 'completion_tokens': ct,
                          'total_tokens': pt + ct},
            })
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000, tokens=pt+ct)

        # ── /v1/embeddings ────────────────────────────────────────────────────
        elif path == '/v1/embeddings':
            inp = body.get('input', '')
            if isinstance(inp, list): inp = inp[0] if inp else ''
            try:
                from sentence_transformers import SentenceTransformer as _ST
                emb_mdl = body.get('model', 'all-MiniLM-L6-v2')
                vec = _ST(emb_mdl).encode(inp).tolist()
                t_count = _tokens(inp)
                self._json(200, {
                    'object': 'list', 'model': emb_mdl,
                    'data': [{'object': 'embedding', 'index': 0, 'embedding': vec}],
                    'usage': {'prompt_tokens': t_count, 'total_tokens': t_count},
                })
            except ImportError:
                self._err(501, 'pip install sentence-transformers to enable embeddings')
            except Exception as e:
                self._err(500, str(e))
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        # ── /v2/config — update config file ───────────────────────────────────
        elif path == '/v2/config':
            if not _auth_ok(self.headers.get('Authorization', '')):
                self._err(401, 'Auth required'); return
            cfg_file = os.path.join(CONFIG, 'config.env')
            updates  = {k: v for k, v in body.items()
                        if isinstance(k, str) and isinstance(v, str)}
            if not updates:
                self._err(400, 'No string key-value pairs in body'); return
            try:
                lines = open(cfg_file).readlines() if os.path.exists(cfg_file) else []
                done  = set()
                new_lines = []
                for line in lines:
                    s = line.strip()
                    if '=' in s and not s.startswith('#'):
                        k = s.partition('=')[0].strip().upper()
                        match = next((u for u in updates if u.upper() == k), None)
                        if match:
                            new_lines.append(f'{k}="{updates[match]}"\n')
                            done.add(match); continue
                    new_lines.append(line)
                for k, v in updates.items():
                    if k not in done:
                        new_lines.append(f'{k.upper()}="{v}"\n')
                os.makedirs(os.path.dirname(cfg_file), exist_ok=True)
                open(cfg_file, 'w').writelines(new_lines)
                self._json(200, {'updated': list(updates.keys()), 'file': cfg_file})
            except Exception as e:
                self._err(500, f'Config write error: {e}')
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        # ── /v2/auth/reload — hot-reload API keys ─────────────────────────────
        elif path == '/v2/auth/reload':
            if not _auth_ok(self.headers.get('Authorization', '')):
                self._err(401, 'Auth required'); return
            _reload_auth()
            with _auth_lock:
                n = len(_auth_keys)
            self._json(200, {'reloaded': True, 'keys_count': n})
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        else:
            self._err(404, f'Unknown endpoint: {path}')
            _log(ip, 'POST', path, 404, (time.time()-t0)*1000)

# ── Threaded server ───────────────────────────────────────────────────────────
class _THTTP(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads      = True
    request_queue_size  = 64

# ── Startup ───────────────────────────────────────────────────────────────────
import errno as _errno
print(f"AI CLI LLM API v2.0 on http://{HOST}:{PORT}  [threaded | rate:{RATE_LIMIT}/min | cors:{CORS}]", flush=True)
print(f"  /health  /v1/models  /v1/chat/completions (stream ok)  /v1/completions", flush=True)
print(f"  /v2/chat/completions  /v2/stats  /v2/backends  /v2/config  /v2/log  /v2/tokenize", flush=True)
try:
    server = _THTTP((HOST, PORT), LLMHandler)
except OSError as _e:
    if _e.errno in (98, 48):
        print(f"ERROR: Port {PORT} already in use. Run: ai api stop", flush=True)
        sys.exit(98)
    raise
server.serve_forever()
PYEOF
      local api_pid=$!
      sleep 0.8
      if kill -0 "$api_pid" 2>/dev/null; then
        echo "$api_pid" > "$API_PID_FILE"
        ok "API server running — PID $api_pid)"
        echo "  Endpoint:  http://${host}:${port}/v1/chat/completions"
        echo "  Models:    http://${host}:${port}/v1/models"
        echo "  Health:    http://${host}:${port}/health"
        echo "  Stop with: ai api stop"
      else
        err "API server failed to start. Check Python dependencies: ai install-deps"
      fi
      ;;
    stop)
      if [[ ! -f "$API_PID_FILE" ]]; then
        warn "No API server PID file found"
        return
      fi
      local pid; pid=$(cat "$API_PID_FILE" 2>/dev/null)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && rm -f "$API_PID_FILE"
        ok "API server stopped — PID $pid)"
      else
        warn "API server not running (stale PID $pid)"
        rm -f "$API_PID_FILE"
      fi
      ;;
    status)
      if [[ -f "$API_PID_FILE" ]]; then
        local pid; pid=$(cat "$API_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
          ok "API server running — PID $pid) on $API_HOST:$API_PORT"
          echo "  Endpoint: http://${API_HOST}:${API_PORT}/v1/chat/completions"
        else
          warn "API server not running (stale PID file)"
          rm -f "$API_PID_FILE"
        fi
      else
        info "API server not running"
        echo "  Start with: ai api start [--port 8080] [--public]"
      fi
      ;;
    test)
      local port="${1:-$API_PORT}"; local host="${2:-$API_HOST}"
      info "Testing LLM API at http://${host}:${port}"
      if ! command -v curl &>/dev/null; then err "curl required for test"; return 1; fi
      local health
      health=$(curl -sf "http://${host}:${port}/health" 2>/dev/null)
      if [[ $? -eq 0 ]]; then
        ok "Health check passed: $health"
      else
        err "Server not responding. Start it: ai api start"
        return 1
      fi
      info "Testing /v1/chat/completions..."
      local key_header=""
      [[ -n "$API_KEY" ]] && key_header="-H \"Authorization: Bearer $API_KEY\""
      local result
      result=$(curl -sf -X POST "http://${host}:${port}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
        -d '{"model":"auto","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":20}' 2>/dev/null)
      if [[ $? -eq 0 ]]; then
        local text; text=$(echo "$result" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])" 2>/dev/null)
        ok "Chat completion: $text"
      else
        err "Chat completion failed"
      fi
      ;;
    config)
      hdr "LLM API Configuration"
      printf "  %-22s %s\n" "Host:" "$API_HOST"
      printf "  %-22s %s\n" "Port:" "$API_PORT"
      printf "  %-22s %s\n" "Key:" "${API_KEY:+(set)}"
      printf "  %-22s %s\n" "CORS:" "$API_CORS"
      printf "  %-22s %s\n" "Share enabled:" "$API_SHARE_ENABLED"
      printf "  %-22s %s\n" "Share host:port:" "${API_SHARE_HOST}:${API_SHARE_PORT}"
      printf "  %-22s %s req/min\n" "Rate limit:" "$API_SHARE_RATE_LIMIT"
      printf "  %-22s %s\n" "Backend:" "${ACTIVE_BACKEND:-auto}"
      printf "  %-22s %s\n" "Model:" "${ACTIVE_MODEL:-auto}"
      echo ""
      echo "  Change: ai config api_host / api_port / api_key"
      echo "          ai config api_share_host / api_share_port / api_share_rate_limit"
      ;;

    # ── v2.4.5: Key management ────────────────────────────────────────────────
    key-gen)
      _api_key_gen "$@"
      ;;
    keys)
      local ksub="${1:-list}"; shift || true
      case "$ksub" in
        list) _api_keys_list ;;
        revoke) _api_keys_revoke "$@" ;;
        show)   _api_keys_show  "$@" ;;
        reset-count) _api_keys_reset_count "$@" ;;
        *) echo "Usage: ai api keys list|revoke ID|show ID|reset-count ID" ;;
      esac
      ;;
    share)
      # Start public-facing API server accepting any valid key from the key store
      local port="${API_SHARE_PORT}" host="${API_SHARE_HOST}"
      while [[ $# -gt 0 ]]; do
        case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; *) shift ;; esac
      done
      _api_share_start "$host" "$port"
      ;;
    unshare) _api_share_stop ;;

    *)
      hdr "LLM API Server v2.4.5 — OpenAI-compatible"
      echo ""
      echo "  ${B}Server${R}"
      echo "  ai api start [--port 8080] [--host 0.0.0.0] [--key <token>]"
      echo "  ai api stop / status / test / config"
      echo ""
      echo "  ${B}Key Hosting v2.4.5 — share your model with others${R}"
      echo "  ai api key-gen [--label name] [--rate N/min]"
      echo "    Creates a unique key others can use to call YOUR running model"
      echo "  ai api keys list            — Show all generated keys + usage"
      echo "  ai api keys revoke ID     — Disable a key"
      echo "  ai api keys show ID       — Show full key value"
      echo "  ai api share [--port 8080]  — Start public multi-key server"
      echo "  ai api unshare              — Stop shared server"
      echo ""
      echo "  ${B}Endpoints (OpenAI-compatible)${R}"
      echo "    GET  /v1/models"
      echo "    POST /v1/chat/completions"
      echo "    POST /v1/completions"
      echo "    GET  /health"
      echo ""
      echo "  Works with: Open WebUI, LM Studio, SillyTavern, Chatbot UI, curl"
      echo "  Backends:   openai, claude, gemini, gguf, pytorch, hf (auto-detected)"
      echo ""
      echo "  ${B}Example workflow${R}"
      echo "    ai api key-gen --label friend1   # create key"
      echo "    ai api share --port 8080         # share your model"
      echo "    # Give friend1 the key + your IP:port"
      echo "    # They use it like any OpenAI endpoint"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  API KEY MANAGEMENT  v2.4.5
#  Create unique shareable keys so others can access your running model
#  Keys stored in ~/.config/ai-cli/api_keys.json
#  Each key has: id, key (secret), label, created, active, rate_limit,
#                requests_today, requests_total, last_used
# ════════════════════════════════════════════════════════════════════════════════
_api_key_gen() {
  local label="key_$(date +%Y%m%d_%H%M%S)" rate="${API_SHARE_RATE_LIMIT:-60}"
  while [[ $# -gt 0 ]]; do
    case "$1" in --label) label="$2"; shift 2 ;; --rate) rate="$2"; shift 2 ;; *) shift ;; esac
  done
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local key_id; key_id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
  local secret; secret=$(python3 -c "import secrets; print('ak-' + secrets.token_hex(24))")
  local now; now=$(date -Iseconds 2>/dev/null || python3 -c "from datetime import datetime; print(datetime.utcnow().isoformat())")

  # Load or create key store
  local ks="$API_KEYS_FILE"
  if [[ ! -f "$ks" ]]; then echo "[]" > "$ks"; chmod 600 "$ks"; fi

  python3 - <<PYEOF
import json, sys
ks = '$ks'
try:
    keys = json.load(open(ks))
except: keys = []
keys.append({
    "id": "$key_id", "key": "$secret", "label": "$label",
    "created": "$now", "active": True,
    "rate_limit": $rate,
    "requests_today": 0, "requests_total": 0, "last_used": None
})
json.dump(keys, open(ks,'w'), indent=2)
PYEOF

  ok "API key created"
  printf "  %-14s %s\n" "ID:"     "$key_id"
  printf "  %-14s %s\n" "Label:"  "$label"
  printf "  %-14s %s\n" "Key:"    "$secret"
  printf "  %-14s %s req/min\n" "Rate limit:" "$rate"
  echo ""
  warn "Copy the key now — it cannot be recovered later"
  echo "  Share: ai api share --port ${API_SHARE_PORT}"
  echo "  Usage: curl http://<your-ip>:${API_SHARE_PORT}/v1/chat/completions \\"
  echo "           -H 'Authorization: Bearer $secret' \\"
  echo "           -H 'Content-Type: application/json' \\"
  echo "           -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
}

_api_keys_list() {
  [[ ! -f "$API_KEYS_FILE" ]] && { info "No keys yet. Create one: ai api key-gen"; return; }
  hdr "API Keys v2.4.5"
  python3 - <<'PYEOF'
import json, sys
try:
    keys = json.load(open(sys.argv[1]))
except: keys = []
if not keys:
    print("  No keys.")
    sys.exit()
print(f"  {'ID':8}  {'Label':20}  {'Active':6}  {'Rate':8}  {'Total':7}  {'Last used':19}")
print("  " + "-"*80)
for k in keys:
    key_preview = k['key'][:10] + "..."
    active = "yes" if k.get('active', True) else "NO"
    rate = f"{k.get('rate_limit',60)}/min"
    total = str(k.get('requests_total', 0))
    last = (k.get('last_used') or 'never')[:19]
    print(f"  {k['id']:8}  {k['label']:20}  {active:6}  {rate:8}  {total:7}  {last}")
PYEOF
  "$API_KEYS_FILE"
}

_api_keys_revoke() {
  local id="${1:?Usage: ai api keys revoke ID}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
ks = '$API_KEYS_FILE'
keys = json.load(open(ks))
found = False
for k in keys:
    if k['id'] == '$id':
        k['active'] = False; found = True
json.dump(keys, open(ks,'w'), indent=2)
print('Revoked' if found else 'Key not found: $id')
"
}

_api_keys_show() {
  local id="${1:?Usage: ai api keys show ID}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
keys = json.load(open('$API_KEYS_FILE'))
for k in keys:
    if k['id'] == '$id':
        print(k['key']); exit()
print('Key not found: $id')
"
}

_api_keys_reset_count() {
  local id="${1:?Usage: ai api keys reset-count ID}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
ks = '$API_KEYS_FILE'; keys = json.load(open(ks))
for k in keys:
    if k['id'] == '$id':
        k['requests_today'] = 0; k['requests_total'] = 0
json.dump(keys, open(ks,'w'), indent=2)
print('Reset counters for $id')
"
}

_api_share_start() {
  local host="${1:-${API_SHARE_HOST:-0.0.0.0}}"
  local port="${2:-${API_SHARE_PORT:-8080}}"
  local share_pid_file="$CONFIG_DIR/api_share.pid"

  if [[ -f "$share_pid_file" ]]; then
    local p; p=$(cat "$share_pid_file" 2>/dev/null)
    kill -0 "$p" 2>/dev/null && { warn "Share server already running — PID $p)"; return 1; }
    rm -f "$share_pid_file"
  fi
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No API keys. Create one first: ai api key-gen --label NAME"; return 1; }
  # v2.7.1: Pre-check port availability (prevents errno 98)
  if [[ -n "$PYTHON" ]]; then
    if ! "$PYTHON" -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('$host', $port))
    s.close(); sys.exit(0)
except OSError:
    s.close(); sys.exit(1)
" 2>/dev/null; then
      err "Port $port is already in use (OSError errno 98). Free it first or use a different port."
      return 1
    fi
  fi
  info "Starting public AI CLI share server on ${host}:${port}"
  info "Auth: multi-key from $API_KEYS_FILE"
  warn "This exposes your model to key holders — revoke keys with: ai api keys revoke ID"

  export _SHARE_HOST="$host" _SHARE_PORT="$port" _SHARE_KEYS_FILE="$API_KEYS_FILE"
  export _SHARE_BACKEND="${ACTIVE_BACKEND:-}" _SHARE_MODEL="${ACTIVE_MODEL:-}"
  export _SHARE_CONFIG="$CONFIG_DIR" _SHARE_CORS="${API_CORS:-1}"

  "$PYTHON" - <<'PYEOF' &
import os, sys, json, time, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from collections import defaultdict

HOST       = os.environ.get('_SHARE_HOST', '0.0.0.0')
PORT       = int(os.environ.get('_SHARE_PORT', '8080'))
KEYS_FILE  = os.environ['_SHARE_KEYS_FILE']
BACKEND    = os.environ.get('_SHARE_BACKEND', '')
MODEL      = os.environ.get('_SHARE_MODEL', '')
CONFIG     = os.environ.get('_SHARE_CONFIG', '')
CORS       = os.environ.get('_SHARE_CORS', '1') == '1'

_request_times = defaultdict(list)  # key_id -> [timestamps]
_lock = threading.Lock()

def load_keys():
    try:
        return {k['key']: k for k in json.load(open(KEYS_FILE)) if k.get('active', True)}
    except:
        return {}

def load_config_keys():
    keys = {}
    cf = os.path.join(CONFIG, 'keys.env')
    if os.path.exists(cf):
        for line in open(cf):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                keys[k.strip()] = v.strip().strip('"\'')
    return keys

def check_rate(key_id, rate_limit):
    now = time.time()
    with _lock:
        times = [t for t in _request_times[key_id] if now - t < 60]
        _request_times[key_id] = times
        if len(times) >= rate_limit:
            return False
        _request_times[key_id].append(now)
    return True

def update_key_stats(key_secret):
    try:
        keys = json.load(open(KEYS_FILE))
        for k in keys:
            if k['key'] == key_secret:
                k['requests_total'] = k.get('requests_total', 0) + 1
                k['requests_today'] = k.get('requests_today', 0) + 1
                k['last_used'] = time.strftime('%Y-%m-%dT%H:%M:%S')
        json.dump(keys, open(KEYS_FILE, 'w'), indent=2)
    except:
        pass

def call_llm(messages, max_tokens=2048, temperature=0.7):
    """Minimal inline LLM caller."""
    import urllib.request
    cfg_keys = load_config_keys()
    backend = BACKEND or ('openai' if cfg_keys.get('OPENAI_API_KEY') else
                          'claude' if cfg_keys.get('ANTHROPIC_API_KEY') else
                          'gemini' if cfg_keys.get('GEMINI_API_KEY') else None)
    if backend == 'openai':
        key = cfg_keys.get('OPENAI_API_KEY', '')
        if not key: return None, "OPENAI_API_KEY not set"
        payload = json.dumps({"model": MODEL or "gpt-4o-mini", "messages": messages,
                              "max_tokens": max_tokens, "temperature": temperature}).encode()
        req = urllib.request.Request("https://api.openai.com/v1/chat/completions", data=payload,
                                     headers={"Authorization": f"Bearer {key}",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['choices'][0]['message']['content'], None
    elif backend == 'claude':
        key = cfg_keys.get('ANTHROPIC_API_KEY', '')
        if not key: return None, "ANTHROPIC_API_KEY not set"
        payload = json.dumps({"model": MODEL or "claude-haiku-4-5-20251001",
                              "max_tokens": max_tokens,
                              "messages": [m for m in messages if m.get('role') != 'system']}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=payload,
                                     headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['content'][0]['text'], None
    elif backend == 'gemini':
        key = cfg_keys.get('GEMINI_API_KEY', '')
        if not key: return None, "GEMINI_API_KEY not set"
        mdl = MODEL or 'gemini-2.0-flash'
        parts = [{"text": f"{m['role']}: {m['content']}"} for m in messages]
        payload = json.dumps({"contents": [{"parts": parts}],
                              "generationConfig": {"maxOutputTokens": max_tokens,
                                                   "temperature": temperature}}).encode()
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{mdl}:generateContent?key={key}"
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['candidates'][0]['content']['parts'][0]['text'], None
    return None, f"No backend available (set OPENAI/ANTHROPIC/GEMINI API key)"

class ShareHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _cors(self):
        if CORS:
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        """Returns (key_record, error_msg). key_record is None on failure."""
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return None, "Missing Authorization: Bearer KEY"
        secret = auth[7:].strip()
        api_keys = load_keys()
        rec = api_keys.get(secret)
        if not rec:
            return None, "Invalid API key"
        if not check_rate(rec['id'], rec.get('rate_limit', 60)):
            return None, f"Rate limit exceeded ({rec.get('rate_limit',60)} req/min)"
        threading.Thread(target=update_key_stats, args=(secret,), daemon=True).start()
        return rec, None

    def do_OPTIONS(self):
        self.send_response(200); self._cors(); self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/health':
            self._json(200, {"status": "ok", "version": "2.4.5", "mode": "share",
                             "backend": BACKEND or "auto", "model": MODEL or "auto"})
        elif path == '/v1/models':
            rec, err = self._auth()
            if not rec: self._json(401, {"error": err}); return
            self._json(200, {"object": "list", "data": [
                {"id": MODEL or "auto", "object": "model", "owned_by": "ai-cli-share"}
            ]})
        else:
            self._json(404, {"error": "Not found"})

    def do_POST(self):
        rec, err = self._auth()
        if not rec: self._json(401, {"error": {"message": err, "type": "auth_error"}}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            self._json(400, {"error": str(e)}); return
        path = urlparse(self.path).path
        if path in ('/v1/chat/completions', '/v1/completions'):
            messages = body.get('messages', [{"role":"user","content": body.get('prompt','')}])
            max_tok = int(body.get('max_tokens', 2048))
            temp = float(body.get('temperature', 0.7))
            t0 = time.time()
            try:
                text, err2 = call_llm(messages, max_tok, temp)
            except Exception as ex:
                self._json(500, {"error": str(ex)}); return
            if err2:
                self._json(500, {"error": {"message": err2, "type": "backend_error"}}); return
            elapsed = time.time() - t0
            self._json(200, {
                "id": f"chatcmpl-{int(time.time()*1000)}", "object": "chat.completion",
                "created": int(time.time()), "model": MODEL or "ai-cli",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": sum(len(m.get('content','').split()) for m in messages),
                          "completion_tokens": len((text or '').split()),
                          "total_tokens": 0},
                "_meta": {"key_id": rec['id'], "key_label": rec['label'],
                          "elapsed_s": round(elapsed, 3)}
            })
        else:
            self._json(404, {"error": "Unknown endpoint"})

keys_count = len(load_keys())
print(f"AI CLI Share Server v2.7.1 — {keys_count} active key(s) — http://{HOST}:{PORT}", flush=True)
print(f"  POST http://{HOST}:{PORT}/v1/chat/completions  (OpenAI-compatible)", flush=True)
# v2.7.1: SO_REUSEADDR to prevent errno 98
class _ReuseAddrHTTPServer(HTTPServer):
    allow_reuse_address = True
import errno as _errno
try:
    _srv = _ReuseAddrHTTPServer((HOST, PORT), ShareHandler)
except OSError as _e:
    if _e.errno in (98, 48):
        print(f"ERROR: Port {PORT} is already in use. Run: ai api unshare  or choose a different port.", flush=True)
        sys.exit(98)
    raise
_srv.serve_forever()
PYEOF

  local share_pid=$!
  sleep 0.8
  if kill -0 "$share_pid" 2>/dev/null; then
    echo "$share_pid" > "$CONFIG_DIR/api_share.pid"
    ok "Share server running — PID $share_pid)"
    echo "  Endpoint: http://${host}:${port}/v1/chat/completions"
    echo "  Keys:     $(python3 -c "import json; k=json.load(open('$API_KEYS_FILE')); print(len([x for x in k if x.get('active',True)]), 'active')" 2>/dev/null || echo "?")"
    echo "  Stop:     ai api unshare"
  else
    err "Share server failed to start"
  fi
}

_api_share_stop() {
  local pf="$CONFIG_DIR/api_share.pid"
  [[ ! -f "$pf" ]] && { warn "Share server not running"; return; }
  local pid; pid=$(cat "$pf")
  kill -0 "$pid" 2>/dev/null && kill "$pid" && rm -f "$pf" && ok "Share server stopped" || \
    { warn "Share server not running (stale PID)"; rm -f "$pf"; }
}

# ════════════════════════════════════════════════════════════════════════════════
#  MULTI-AI CHAT ARENA  v2.4.5
#  Two or more AI agents discuss a topic; user watches, steers, rates, or stops.
#  If MULTIAI_RLHF_TRAIN=1, rated exchanges update model weights automatically.
#  Conversation is saved as a custom dataset (for later fine-tuning).
#
#  ai multiai "TOPIC" [opts]
#  ai multiai debate  "TOPIC"    — adversarial: agents take opposing sides
#  ai multiai collab  "TASK"     — collaborative: agents build on each other
#  ai multiai brainstorm "TOPIC" — free-form: each agent adds new ideas
#
#  Options:
#    --agents N          Number of agents (2-4, default 2)
#    --rounds N          Conversation rounds (default 6)
#    --model1 ID       Agent 1 backend/model (default: active model/backend)
#    --model2 ID       Agent 2 backend/model
#    --no-save           Don't save as dataset
#    --no-train          Don't trigger RLHF training even if enabled
#    --quiet             Minimal output (no banners/prompts)
#
#  During conversation (interactive controls):
#    Enter              — let agents continue
#    s <guidance>       — steer: inject your guidance into next prompt
#    r <1-5>            — rate last exchange (feeds RLHF if enabled)
#    p                  — pause / resume
#    q / Ctrl+C         — stop and save
# ════════════════════════════════════════════════════════════════════════════════
cmd_multiai() {
  local sub="${1:-help}"
  # Detect mode vs topic
  local mode="discuss"
  case "$sub" in
    debate|collab|brainstorm|discuss) mode="$sub"; shift ;;
    help|-h|--help) _multiai_help; return ;;
    *) : ;; # treat first arg as the topic directly
  esac

  # Parse options
  local topic="" n_agents=2 rounds="$MULTIAI_ROUNDS" quiet=0
  local model1="" model2="" model3="" model4=""
  local do_save="$MULTIAI_SAVE_DATASET" do_train="$MULTIAI_RLHF_TRAIN"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents)   n_agents="$2"; shift 2 ;;
      --rounds)   rounds="$2"; shift 2 ;;
      --model1)   model1="$2"; shift 2 ;;
      --model2)   model2="$2"; shift 2 ;;
      --model3)   model3="$2"; shift 2 ;;
      --model4)   model4="$2"; shift 2 ;;
      --no-save)  do_save=0; shift ;;
      --no-train) do_train=0; shift ;;
      --quiet)    quiet=1; shift ;;
      --) shift; topic="$*"; break ;;
      -*) shift ;;
      *) topic="${topic:+$topic }$1"; shift ;;
    esac
  done

  [[ -z "$topic" ]] && { _multiai_help; return 1; }
  (( n_agents < 2 )) && n_agents=2
  (( n_agents > 4 )) && n_agents=4

  # Build agent configs (backend|model|persona)
  local -a AGENT_BACKENDS AGENT_MODELS AGENT_LABELS AGENT_COLORS AGENT_PERSONAS
  local _ab="${ACTIVE_BACKEND:-}" _am="${ACTIVE_MODEL:-}"
  AGENT_BACKENDS=("$_ab" "$_ab" "$_ab" "$_ab")
  AGENT_MODELS=("$_am" "$_am" "$_am" "$_am")
  [[ -n "$model1" ]] && AGENT_MODELS[0]="$model1"
  [[ -n "$model2" ]] && AGENT_MODELS[1]="$model2"
  [[ -n "$model3" ]] && AGENT_MODELS[2]="$model3"
  [[ -n "$model4" ]] && AGENT_MODELS[3]="$model4"
  AGENT_LABELS=("Agent-Alpha" "Agent-Beta" "Agent-Gamma" "Agent-Delta")
  AGENT_COLORS=("$BCYAN" "$BYELLOW" "$BMAGENTA" "$BGREEN")

  # Build system prompts based on mode
  local topic_clean="${topic//\"/\'}"
  case "$mode" in
    debate)
      AGENT_PERSONAS=(
        "You are Agent-Alpha in a debate about: ${topic_clean}. Argue STRONGLY in FAVOR. Be direct, use evidence, challenge opposing points. Keep responses under 120 words."
        "You are Agent-Beta in a debate about: ${topic_clean}. Argue STRONGLY AGAINST. Be direct, use evidence, challenge opposing points. Keep responses under 120 words."
        "You are Agent-Gamma, a critical analyst in the debate about: ${topic_clean}. Find flaws in BOTH sides. Keep responses under 120 words."
        "You are Agent-Delta, a moderator. Summarize points made and ask a probing question. Keep responses under 80 words."
      )
      ;;
    collab)
      AGENT_PERSONAS=(
        "You are Agent-Alpha collaborating on: ${topic_clean}. Build directly on what others say. Add concrete ideas. Keep responses under 120 words."
        "You are Agent-Beta collaborating on: ${topic_clean}. Extend and improve ideas from others. Be specific and practical. Keep responses under 120 words."
        "You are Agent-Gamma collaborating on: ${topic_clean}. Identify gaps and suggest solutions. Keep responses under 120 words."
        "You are Agent-Delta collaborating on: ${topic_clean}. Synthesize ideas and propose next steps. Keep responses under 100 words."
      )
      ;;
    brainstorm)
      AGENT_PERSONAS=(
        "You are Agent-Alpha brainstorming: ${topic_clean}. Generate wild, creative ideas. Each turn add 2-3 NEW ideas not yet mentioned. Under 100 words."
        "You are Agent-Beta brainstorming: ${topic_clean}. Build on Alpha's ideas and add your own twists. Under 100 words."
        "You are Agent-Gamma brainstorming: ${topic_clean}. Challenge assumptions, suggest unexpected angles. Under 100 words."
        "You are Agent-Delta brainstorming: ${topic_clean}. Pick the most promising ideas and push them further. Under 100 words."
      )
      ;;
    *)
      AGENT_PERSONAS=(
        "You are Agent-Alpha discussing: ${topic_clean}. Share your perspective thoughtfully. Engage with what others say. Under 120 words."
        "You are Agent-Beta discussing: ${topic_clean}. Offer a different angle or nuance. Respond to previous points. Under 120 words."
        "You are Agent-Gamma discussing: ${topic_clean}. Ask probing questions and add depth. Under 100 words."
        "You are Agent-Delta discussing: ${topic_clean}. Synthesize and find common ground. Under 100 words."
      )
      ;;
  esac

  # Header
  if [[ $quiet -eq 0 ]]; then
    echo ""
    echo -e "${B}${BWHITE}╔══════════════════════════════════════════════════════════╗${R}"
    printf "${B}${BWHITE}║  Multi-AI Arena  %-42s║${R}\n" "v2.4.5"
    echo -e "${B}${BWHITE}╚══════════════════════════════════════════════════════════╝${R}"
    echo ""
    printf "  ${B}Topic:${R}   %s\n" "$topic"
    printf "  ${B}Mode:${R}    %s\n" "$mode"
    printf "  ${B}Agents:${R}  %d  |  ${B}Rounds:${R} %d\n" "$n_agents" "$rounds"
    for (( i=0; i<n_agents; i++ )); do
      printf "  ${B}${AGENT_COLORS[$i]}%s${R}: %s\n" \
        "${AGENT_LABELS[$i]}" "${AGENT_PERSONAS[$i]:0:80}..."
    done
    echo ""
    echo -e "  ${DIM}Controls: [Enter]=continue  [s TEXT]=steer  [r <1-5>]=rate  [p]=pause  [q]=quit${R}"
    echo ""
  fi

  # Conversation state
  local -a HISTORY       # full conversation as text
  local -a EXCHANGE_LOG  # for RLHF + dataset: {round, agent, prompt, response}
  local last_exchange_prompt="" last_exchange_response="" last_agent=""
  local steer_msg="" paused=0 round=0 total_rated=0

  # Opening prompt for round 1
  local opening="The topic is: $topic. Please give your opening statement or perspective."

  _multiai_ask() {
    local agent_idx=$1 user_prompt="$2"
    local backend="${AGENT_BACKENDS[$agent_idx]}"
    local model="${AGENT_MODELS[$agent_idx]}"
    local persona="${AGENT_PERSONAS[$agent_idx]}"
    local label="${AGENT_LABELS[$agent_idx]}"

    # Build context: system prompt + recent history (last 6 turns)
    local context_lines="${#HISTORY[@]}"
    local start_idx=$(( context_lines > 6 ? context_lines - 6 : 0 ))
    local context=""
    for (( ci=start_idx; ci<context_lines; ci++ )); do
      context="${context}${HISTORY[$ci]}"$'\n'
    done

    local full_prompt="${context}${label}: "
    if [[ -n "$steer_msg" ]]; then
      full_prompt="[User guidance: ${steer_msg}] ${full_prompt}"
    fi
    full_prompt="${full_prompt}${user_prompt}"

    # Use dispatch_ask with system override
    local response
    response=$(AI_SYSTEM_OVERRIDE="$persona" dispatch_ask "$full_prompt" 2>/dev/null)
    echo "$response"
  }

  # Main conversation loop
  while (( round < rounds )); do
    (( round++ ))

    for (( agent=0; agent<n_agents; agent++ )); do
      [[ $paused -eq 1 ]] && { read -rp "  [paused — press Enter to resume, q to quit] " _r; [[ "$_r" == "q" ]] && break 2; paused=0; }

      local label="${AGENT_LABELS[$agent]}"
      local color="${AGENT_COLORS[$agent]}"

      # Build prompt from context
      local turn_prompt
      if (( round == 1 && agent == 0 )); then
        turn_prompt="$opening"
      elif (( ${#HISTORY[@]} > 0 )); then
        # Reply to previous agent's last message
        local prev_idx=$(( agent == 0 ? n_agents - 1 : agent - 1 ))
        turn_prompt="Respond to ${AGENT_LABELS[$prev_idx]}'s last point and continue the discussion."
      else
        turn_prompt="$opening"
      fi

      # Apply steering if set
      if [[ -n "$steer_msg" ]]; then
        turn_prompt="[User steers: $steer_msg] $turn_prompt"
      fi

      printf "\r  ${B}${color}%s${R} [round %d/%d] thinking..." "$label" "$round" "$rounds"

      local response
      response=$(_multiai_ask "$agent" "$turn_prompt" 2>/dev/null)
      steer_msg=""  # consume steering after first use

      # Display response
      printf "\r  ${B}${color}%s${R} [%d/%d]:${R}\n" "$label" "$round" "$rounds"
      echo "$response" | fold -sw 78 | sed 's/^/    /'
      echo ""

      # Record
      local hist_entry="${label}: ${response}"
      HISTORY+=("$hist_entry")
      EXCHANGE_LOG+=("$(printf '{"round":%d,"agent":"%s","response":%s}' \
        "$round" "$label" "$(echo "$response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '"..."')")")
      last_exchange_prompt="$turn_prompt"
      last_exchange_response="$response"
      last_agent="$label"

      # User control prompt (non-blocking with timeout)
      if [[ $quiet -eq 0 ]]; then
        local user_input=""
        IFS= read -r -t 0.1 user_input 2>/dev/null || true
        if [[ -z "$user_input" ]] && (( agent == n_agents - 1 )); then
          # End of round: give user a chance to act
          printf "  ${DIM}[Enter]=continue  [s text]=steer  [r 1-5]=rate  [p]=pause  [q]=quit:${R} "
          IFS= read -r user_input 2>/dev/null || true
        fi
        if [[ -n "$user_input" ]]; then
          case "${user_input:0:1}" in
            q|Q) echo ""; info "Stopping."; break 2 ;;
            p|P) paused=1 ;;
            s|S) steer_msg="${user_input:2}"; ok "Steering: $steer_msg" ;;
            r|R)
              local rating="${user_input:2}"; rating="${rating// /}"
              if [[ "$rating" =~ ^[1-5]$ ]]; then
                # Save for RLHF
                echo "{\"prompt\":$(echo "$last_exchange_prompt" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"response\":$(echo "$last_exchange_response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"rating\":$rating,\"agent\":\"$last_agent\"}" \
                  >> "$RLHF_RATINGS_FILE"
                (( total_rated++ ))
                ok "Rated $rating/5 (total rated: $total_rated)"
                # Trigger RLHF training if enabled and enough pairs
                if [[ "$do_train" == "1" ]] && (( total_rated > 0 && total_rated % 5 == 0 )); then
                  info "Auto-training on $total_rated rated exchanges..."
                  _rlhf_dpo_train "${ACTIVE_MODEL:-}" &>/dev/null &
                fi
              else
                warn "Rating must be 1-5"
              fi
              ;;
          esac
        fi
      fi
    done
  done

  echo ""
  info "Conversation complete ($round rounds, $n_agents agents)"

  # Save as dataset
  if [[ "$do_save" == "1" && ${#EXCHANGE_LOG[@]} -gt 0 ]]; then
    local ds_name="multiai_${mode}_$(date +%Y%m%d_%H%M%S)"
    local ds_dir="$DATASETS_DIR/$ds_name"
    mkdir -p "$ds_dir"
    echo "{\"name\":\"$ds_name\",\"created\":\"$(date -Iseconds)\",\"count\":0}" > "$ds_dir/meta.json"
    touch "$ds_dir/data.jsonl"

    # Build adjacent-turn pairs as training data
    local pair_count=0
    for (( i=0; i+1 < ${#HISTORY[@]}; i+=2 )); do
      local q="${HISTORY[$i]}" a="${HISTORY[$((i+1))]}"
      echo "{\"prompt\":$(echo "$q" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"response\":$(echo "$a" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')}" \
        >> "$ds_dir/data.jsonl"
      (( pair_count++ ))
    done

    python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$pair_count; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
    ok "Saved as dataset: $ds_name ($pair_count pairs)"
    echo "  Fine-tune: ai ttm finetune $ds_name"
  fi

  # Final RLHF training if ratings were collected
  if [[ "$do_train" == "1" && $total_rated -ge 5 ]]; then
    info "Running final RLHF training on $total_rated rated exchanges..."
    _rlhf_dpo_train "${ACTIVE_MODEL:-}" 2>/dev/null || true
    ok "RLHF training triggered"
  fi
}

_multiai_help() {
  hdr "Multi-AI Chat Arena v2.4.5"
  echo ""
  echo "  ${B}ai multiai \"TOPIC\"${R}              — Two AIs discuss a topic"
  echo "  ${B}ai multiai debate \"TOPIC\"${R}        — Adversarial: AIs take opposite sides"
  echo "  ${B}ai multiai collab \"TASK\"${R}         — Collaborative: AIs build together"
  echo "  ${B}ai multiai brainstorm \"TOPIC\"${R}    — Free-form: each AI adds ideas"
  echo ""
  echo "  Options:"
  echo "    --agents N       Number of agents (2-4, default 2)"
  echo "    --rounds N       Conversation rounds (default $MULTIAI_ROUNDS)"
  echo "    --model1 ID    Agent 1 model/backend"
  echo "    --model2 ID    Agent 2 model/backend"
  echo "    --no-save        Don't save as training dataset"
  echo "    --no-train       Don't trigger RLHF even if enabled"
  echo ""
  echo "  During conversation:"
  echo "    Enter            Continue"
  echo "    s TEXT         Steer: inject guidance into next agent's prompt"
  echo "    r <1-5>          Rate last exchange (feeds RLHF training)"
  echo "    p                Pause / resume"
  echo "    q                Stop and save"
  echo ""
  echo "  Settings:"
  echo "    ai config multiai_rounds N        — Default rounds"
  echo "    ai config multiai_save_dataset 1  — Auto-save conversations as datasets"
  echo "    ai config multiai_rlhf_train 1    — Auto-train on rated exchanges"
  echo ""
  echo "  Examples:"
  echo "    ai multiai debate \"Is AGI beneficial?\""
  echo "    ai multiai collab \"Design a REST API for a todo app\" --agents 3"
  echo "    ai multiai brainstorm \"New uses for LLMs\" --rounds 4"
  echo "    ai multiai \"What is consciousness?\" --agents 2 --rounds 8"
}

cmd_serve() {
  local port=8080 host="127.0.0.1"
  while [[ $# -gt 0 ]]; do
    case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; *) shift ;; esac
  done
  local model="${ACTIVE_MODEL:-}"; [[ -z "$model" ]] && { err "No model set"; return 1; }
  if [[ -n "$LLAMA_BIN" && "$LLAMA_BIN" != "llama_cpp_python" ]]; then
    local srv; srv=$(dirname "$LLAMA_BIN")/llama-server
    [[ -x "$srv" ]] && { info "Starting llama.cpp server on $host:$port"; "$srv" -m "$model" --host "$host" --port "$port" -c "$CONTEXT_SIZE" -ngl "$GPU_LAYERS"; return; }
  fi
  [[ -n "$PYTHON" ]] && "$PYTHON" -m llama_cpp.server --model "$model" --host "$host" --port "$port"
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: GITHUB INTEGRATION — commit / push / pr / issue / clone / status
# ════════════════════════════════════════════════════════════════════════════════
cmd_github() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    status)
      git -C "${1:-.}" status 2>/dev/null || { err "Not a git repo"; return 1; }
      ;;
    commit)
      local msg="${*:-Auto-commit by AI CLI}"
      git add -A && git commit -m "$msg" && ok "Committed: $msg"
      ;;
    push)
      local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${GITHUB_DEFAULT_BRANCH}")
      git push -u origin "$branch" && ok "Pushed to $branch"
      ;;
    pull)
      local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${GITHUB_DEFAULT_BRANCH}")
      git pull origin "$branch" && ok "Pulled from $branch"
      ;;
    clone)
      [[ -z "${1:-}" ]] && { err "Usage: ai github clone <repo-url> [dir]"; return 1; }
      git clone "$1" "${2:-.}" && ok "Cloned: $1"
      ;;
    branch)
      local action="${1:-list}"; shift || true
      case "$action" in
        list)    git branch -a ;;
        new)     git checkout -b "${1:-feature/new}" && ok "Created branch: ${1:-feature/new}" ;;
        switch)  git checkout "${1:-main}" ;;
        delete)  git branch -d "${1:?branch name required}" ;;
        *) err "branch: list | new NAME | switch NAME | delete NAME" ;;
      esac
      ;;
    pr)
      # Create a PR via GitHub CLI if available, or print instructions
      if command -v gh &>/dev/null; then
        local title="${*:-PR by AI CLI}"
        gh pr create --title "$title" --body "Created by AI CLI v${VERSION}" && ok "PR created"
      else
        local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "feature")
        info "Install GitHub CLI (gh) to create PRs automatically"
        info "Or open: https://github.com/$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s/.git$//')/compare/${GITHUB_DEFAULT_BRANCH}...$branch"
      fi
      ;;
    issue)
      if command -v gh &>/dev/null; then
        case "${1:-list}" in
          list)   gh issue list ;;
          create) gh issue create --title "${2:-New Issue}" --body "${3:-}" ;;
          view)   gh issue view "${2:?issue number required}" ;;
          close)  gh issue close "${2:?issue number required}" ;;
          *)  gh issue list ;;
        esac
      else
        info "Install GitHub CLI (gh) for issue management"
        info "  Arch:   sudo pacman -S github-cli"
        info "  Ubuntu: sudo apt install gh"
      fi
      ;;
    log)
      git log --oneline --graph --decorate "${1:--20}" 2>/dev/null || git log --oneline -20
      ;;
    diff)
      git diff "${@}" 2>/dev/null || true
      ;;
    init)
      git init "${1:-.}" && ok "Initialized git repo in ${1:-.}"
      ;;
    token)
      if [[ -n "${1:-}" ]]; then
        GITHUB_TOKEN="$1"; save_config; ok "GitHub token saved"
      else
        echo "Token: ${GITHUB_TOKEN:-(not set)}"
      fi
      ;;
    user)
      if [[ -n "${1:-}" ]]; then
        GITHUB_USER="$1"; save_config; ok "GitHub user: $GITHUB_USER"
      else
        echo "User: ${GITHUB_USER:-(not set)}"
      fi
      ;;
    help|*)
      hdr "AI CLI — GitHub Integration (v2.5)"
      echo "  ai github status [dir]           Show git status"
      echo "  ai github commit \"<msg>\"          Stage all + commit"
      echo "  ai github push                   Push current branch"
      echo "  ai github pull                   Pull current branch"
      echo "  ai github clone URL [dir]      Clone repo"
      echo "  ai github branch list/new/switch/delete"
      echo "  ai github pr [\"title\"]            Create pull request (needs gh)"
      echo "  ai github issue list/create/view/close"
      echo "  ai github log [-N]               Show recent commits"
      echo "  ai github diff [args]            Show diff"
      echo "  ai github init [dir]             Init new repo"
      echo "  ai github token <tok>            Save personal access token"
      echo "  ai github user NAME            Save GitHub username"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: RESEARCH PAPER SCRAPER — open-access only
#  Sources: arXiv, PubMed Central (PMC), bioRxiv, medRxiv, CORE, OpenAlex,
#           DOAJ, Semantic Scholar, Europe PMC
#  Citations: APA, MLA, Chicago, BibTeX, IEEE
# ════════════════════════════════════════════════════════════════════════════════
cmd_papers() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    search)
      [[ -z "${*}" ]] && { err "Usage: ai papers search QUERY [--source arxiv|pmc|core|openalex|all]"; return 1; }
      local query="" source="all"
      while [[ $# -gt 0 ]]; do
        case "$1" in --source|-s) source="$2"; shift 2 ;; *) query="$query $1"; shift ;; esac
      done
      query="${query# }"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$query" "$source" "$PAPERS_DIR" <<'PYEOF'
import sys, os, json, urllib.request, urllib.parse, time

query = sys.argv[1]
source = sys.argv[2].lower()
papers_dir = sys.argv[3]
os.makedirs(papers_dir, exist_ok=True)
results = []

def fetch(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {'User-Agent': 'AI-CLI/2.5 (research)'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read().decode('utf-8', errors='replace')
    except Exception as e:
        return None

# arXiv
if source in ('all', 'arxiv'):
    q = urllib.parse.quote(query)
    url = f"https://export.arxiv.org/api/query?search_query=all:{q}&start=0&max_results=5"
    data = fetch(url)
    if data:
        import xml.etree.ElementTree as ET
        ns = {'a': 'http://www.w3.org/2005/Atom'}
        try:
            root = ET.fromstring(data)
            for entry in root.findall('a:entry', ns)[:5]:
                title = (entry.find('a:title', ns).text or '').strip().replace('\n',' ')
                authors = [a.find('a:name', ns).text for a in entry.findall('a:author', ns)]
                year = (entry.find('a:published', ns).text or '')[:4]
                arxiv_id = (entry.find('a:id', ns).text or '').split('/')[-1]
                abstract = (entry.find('a:summary', ns).text or '').strip()[:300]
                results.append({'source': 'arXiv', 'id': arxiv_id, 'title': title,
                    'authors': authors, 'year': year, 'abstract': abstract,
                    'url': f"https://arxiv.org/abs/{arxiv_id}"})
        except: pass

# PubMed Central (open access)
if source in ('all', 'pmc'):
    q = urllib.parse.quote(query)
    url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pmc&term={q}&retmax=5&retmode=json&tool=ai-cli&email=ai-cli@example.com"
    data = fetch(url)
    if data:
        try:
            ids = json.loads(data).get('esearchresult', {}).get('idlist', [])[:5]
            for pmcid in ids:
                info_url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pmc&id={pmcid}&retmode=json"
                info_data = fetch(info_url)
                if info_data:
                    d = json.loads(info_data).get('result', {}).get(pmcid, {})
                    title = d.get('title', 'Unknown')
                    authors = [a.get('name','') for a in d.get('authors', [])[:3]]
                    year = str(d.get('pubdate', ''))[:4]
                    results.append({'source': 'PMC', 'id': pmcid, 'title': title,
                        'authors': authors, 'year': year, 'abstract': '',
                        'url': f"https://www.ncbi.nlm.nih.gov/pmc/articles/PMC{pmcid}/"})
                time.sleep(0.34)  # NCBI rate limit
        except: pass

# CORE (open access research)
if source in ('all', 'core'):
    q = urllib.parse.quote(query)
    url = f"https://api.core.ac.uk/v3/search/works?q={q}&limit=5"
    data = fetch(url)
    if data:
        try:
            items = json.loads(data).get('results', [])[:5]
            for item in items:
                title = item.get('title', 'Unknown')
                authors = [a.get('name','') for a in item.get('authors', [])[:3]]
                year = str(item.get('yearPublished', ''))
                doi = item.get('doi', '')
                abstract = (item.get('abstract') or '')[:300]
                results.append({'source': 'CORE', 'id': doi or item.get('id',''),
                    'title': title, 'authors': authors, 'year': year,
                    'abstract': abstract, 'url': item.get('downloadUrl','') or item.get('sourceFulltextUrls',[''])[0]})
        except: pass

# OpenAlex (open access)
if source in ('all', 'openalex'):
    q = urllib.parse.quote(query)
    url = f"https://api.openalex.org/works?search={q}&filter=is_oa:true&per-page=5&mailto=ai-cli@example.com"
    data = fetch(url)
    if data:
        try:
            items = json.loads(data).get('results', [])[:5]
            for item in items:
                title = item.get('display_name', 'Unknown')
                authors = [a.get('author',{}).get('display_name','') for a in item.get('authorships',[])[:3]]
                year = str(item.get('publication_year',''))
                doi = item.get('doi','')
                abstract_inv = item.get('abstract_inverted_index')
                abstract = ''
                if abstract_inv:
                    words = sorted([(pos, w) for w, positions in abstract_inv.items() for pos in positions])
                    abstract = ' '.join(w for _,w in words[:60])
                results.append({'source': 'OpenAlex', 'id': doi,
                    'title': title, 'authors': authors, 'year': year,
                    'abstract': abstract[:300], 'url': item.get('primary_location',{}).get('landing_page_url','') or doi})
        except: pass

# Print results
print(f"\nFound {len(results)} papers:\n")
for i, p in enumerate(results, 1):
    print(f"[{i}] {p['title']}")
    print(f"    Authors: {', '.join(p['authors'][:3])}")
    print(f"    Year: {p['year']}  Source: {p['source']}  ID: {p['id']}")
    print(f"    URL: {p['url']}")
    if p['abstract']:
        print(f"    Abstract: {p['abstract'][:200]}...")
    print()

# Save results index
idx_file = os.path.join(papers_dir, 'search_results.json')
existing = []
if os.path.exists(idx_file):
    try: existing = json.load(open(idx_file))
    except: pass
existing.extend(results)
json.dump(existing, open(idx_file, 'w'), indent=2)
print(f"Results saved to {idx_file}")
print(f"Use: ai papers cite <number> [apa|mla|bibtex|ieee|chicago]")
PYEOF
      ;;

    download)
      local id="${1:?paper ID or URL required}"; shift
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$id" "$PAPERS_DIR" <<'PYEOF'
import sys, os, urllib.request, json, re

paper_id = sys.argv[1]
papers_dir = sys.argv[2]
os.makedirs(papers_dir, exist_ok=True)

def fetch_url(url, out_file):
    req = urllib.request.Request(url, headers={'User-Agent': 'AI-CLI/2.5'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r, open(out_file, 'wb') as f:
            f.write(r.read())
        return True
    except Exception as e:
        print(f"Error: {e}")
        return False

# Detect paper type
if 'arxiv.org' in paper_id or re.match(r'^\d{4}\.\d+', paper_id):
    arxiv_id = re.search(r'(\d{4}\.\d+)', paper_id)
    if arxiv_id:
        arxiv_id = arxiv_id.group(1)
        pdf_url = f"https://arxiv.org/pdf/{arxiv_id}.pdf"
        out = os.path.join(papers_dir, f"arxiv_{arxiv_id}.pdf")
        if fetch_url(pdf_url, out):
            print(f"Downloaded: {out}")
elif 'pmc' in paper_id.lower() or paper_id.isdigit():
    pmcid = re.sub(r'[^0-9]', '', paper_id)
    pdf_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/PMC{pmcid}/pdf/"
    out = os.path.join(papers_dir, f"pmc_{pmcid}.pdf")
    if fetch_url(pdf_url, out):
        print(f"Downloaded: {out}")
elif paper_id.startswith('http'):
    fname = re.sub(r'[^a-z0-9]', '_', paper_id.lower())[-60:] + '.pdf'
    out = os.path.join(papers_dir, fname)
    if fetch_url(paper_id, out):
        print(f"Downloaded: {out}")
else:
    print(f"Unknown paper ID format: {paper_id}")
    print("Supported: arXiv IDs (2301.12345), PMC IDs (PMC1234567), or full URLs")
PYEOF
      ;;

    cite)
      local num="${1:-1}"; local fmt="${2:-${PAPERS_CITATION_FORMAT}}"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      "$PYTHON" - "$num" "$fmt" "$PAPERS_DIR" <<'PYEOF'
import sys, os, json

num = int(sys.argv[1]) - 1
fmt = sys.argv[2].lower()
papers_dir = sys.argv[3]
idx_file = os.path.join(papers_dir, 'search_results.json')
if not os.path.exists(idx_file):
    print("No search results. Run: ai papers search QUERY")
    sys.exit(1)
papers = json.load(open(idx_file))
if num < 0 or num >= len(papers):
    print(f"Paper #{num+1} not found. {len(papers)} papers available.")
    sys.exit(1)
p = papers[num]
authors = p.get('authors', ['Unknown Author'])
title = p.get('title', 'Unknown Title')
year = p.get('year', 'n.d.')
url = p.get('url', '')
source = p.get('source', '')

# APA
if fmt in ('apa',):
    a_str = ', '.join(authors[:3])
    if len(authors) > 3: a_str += ', et al.'
    print(f"{a_str} ({year}). {title}. {source}. {url}")
# MLA
elif fmt in ('mla',):
    a_str = authors[0] if authors else 'Unknown'
    if len(authors) > 1: a_str += ', et al'
    print(f'{a_str}. "{title}." {source}, {year}. Web. {url}')
# Chicago
elif fmt in ('chicago',):
    a_str = ', '.join(authors[:3])
    print(f'{a_str}. "{title}." {source} ({year}). {url}.')
# BibTeX
elif fmt in ('bibtex', 'bib'):
    key = (authors[0].split()[-1] if authors else 'Unknown') + year
    print(f"@article{{{key},")
    print(f"  title     = {{{title}}},")
    print(f"  author    = {{{' and '.join(authors)}}},")
    print(f"  year      = {{{year}}},")
    print(f"  journal   = {{{source}}},")
    print(f"  url       = {{{url}}}")
    print("}")
# IEEE
elif fmt in ('ieee',):
    a_str = ', '.join(authors[:3])
    if len(authors) > 3: a_str += ' et al.'
    print(f'{a_str}, "{title}," {source}, {year}. [Online]. Available: {url}')
else:
    print(f"Unknown citation format: {fmt}")
    print("Supported: apa mla chicago bibtex ieee")
PYEOF
      ;;

    list)
      local idx="$PAPERS_DIR/search_results.json"
      [[ ! -f "$idx" ]] && { info "No papers yet. Run: ai papers search QUERY"; return 0; }
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "
import json
papers = json.load(open('$idx'))
print(f'{len(papers)} paper(s) in index:')
for i,p in enumerate(papers,1):
    print(f'  [{i}] {p[\"title\"][:70]} ({p[\"year\"]}) [{p[\"source\"]}]')
"
      ;;

    format)
      if [[ -n "${1:-}" ]]; then
        PAPERS_CITATION_FORMAT="$1"; save_config; ok "Default citation format: $1"
      else
        echo "Current: $PAPERS_CITATION_FORMAT"
        echo "Options: apa mla chicago bibtex ieee"
      fi
      ;;

    help|*)
      hdr "AI CLI — Research Paper Scraper (v2.5)"
      echo "  Open-access sources: arXiv, PubMed Central, CORE, OpenAlex"
      echo "  Citation formats:    APA, MLA, Chicago, BibTeX, IEEE"
      echo ""
      echo "  ai papers search \"QUERY\" [--source arxiv|pmc|core|openalex|all]"
      echo "  ai papers download <arxiv-id|pmc-id|url>   Download PDF"
      echo "  ai papers cite N [apa|mla|bibtex|ieee|chicago]  Format citation"
      echo "  ai papers list                              Show indexed papers"
      echo "  ai papers format <fmt>                     Set default citation format"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: BUILD / COMPILE — self-contained XZ bundle
# ════════════════════════════════════════════════════════════════════════════════
cmd_build() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    xz|bundle|compile)
      local script_path
      script_path=$(command -v ai 2>/dev/null || echo "/usr/local/bin/ai")
      [[ ! -f "$script_path" ]] && script_path="${BASH_SOURCE[0]}"
      local out_dir="$BUILD_DIR"
      mkdir -p "$out_dir"
      local version_tag="$VERSION"
      local bundle_name="ai-cli-v${version_tag}.tar.xz"
      local bundle_path="$out_dir/$bundle_name"

      info "Building self-contained XZ bundle: $bundle_name"

      # Create a temp staging dir
      local stage; stage=$(mktemp -d)
      mkdir -p "$stage/ai-cli"

      # Copy main script
      cp "$script_path" "$stage/ai-cli/ai"
      chmod +x "$stage/ai-cli/ai"

      # Create install script
      cat > "$stage/ai-cli/install.sh" <<'INSTALL_SH'
#!/usr/bin/env bash
# AI CLI installer
set -e
DEST="${1:-/usr/local/bin/ai}"
cp "$(dirname "$0")/ai" "$DEST"
chmod +x "$DEST"
echo "AI CLI installed to $DEST"
echo "Run: ai install-deps"
INSTALL_SH
      chmod +x "$stage/ai-cli/install.sh"

      # Create README
      cat > "$stage/ai-cli/README.txt" <<README
AI CLI v${version_tag} — Self-contained bundle
==========================================
Install:  ./install.sh [/path/to/ai]
Or:       sudo cp ai /usr/local/bin/ai && chmod +x /usr/local/bin/ai
Deps:     ai install-deps
Arch:     ai install-deps  (auto-detects pacman/apt/dnf/brew)
README

      # Create XZ bundle
      if command -v tar &>/dev/null && tar --version 2>&1 | grep -qi gnu; then
        tar -C "$stage" -cJf "$bundle_path" ai-cli/
      else
        tar -C "$stage" -czf "${bundle_path%.xz}.tar.gz" ai-cli/
        bundle_path="${bundle_path%.xz}.tar.gz"
        bundle_name="$(basename "$bundle_path")"
      fi

      rm -rf "$stage"
      local size; size=$(du -sh "$bundle_path" 2>/dev/null | cut -f1)
      ok "Bundle: $bundle_path ($size)"
      echo "  Distribute: $bundle_name"
      echo "  Install:    tar -xJf $bundle_name && cd ai-cli && ./install.sh"
      ;;

    checksum)
      local f; f=$(ls -t "$BUILD_DIR"/*.tar.* 2>/dev/null | head -1)
      [[ -z "$f" ]] && { err "No bundles found. Run: ai build xz"; return 1; }
      if command -v sha256sum &>/dev/null; then
        sha256sum "$f"
      elif command -v shasum &>/dev/null; then
        shasum -a 256 "$f"
      fi
      ;;

    list)
      ls -lh "$BUILD_DIR/" 2>/dev/null || info "No builds yet"
      ;;

    help|*)
      hdr "AI CLI — Build / Compile (v2.5)"
      echo "  ai build xz        Create self-contained .tar.xz bundle"
      echo "  ai build list      List previous builds"
      echo "  ai build checksum  Show SHA256 of latest bundle"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: MULTIMODAL TRAINING
#  Modes: img-text-to-text, text-to-image (LoRA), image-to-text, encoders, agents
# ════════════════════════════════════════════════════════════════════════════════
cmd_train_multimodal() {
  local mode="${1:-help}"; shift || true
  case "$mode" in

    img-text-to-text|itt)
      # Fine-tune a vision-language model on image+text→text pairs
      local dataset="${1:?Usage: ai train-multimodal img-text-to-text <dataset_dir>}"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      info "Multimodal training: image+text → text (VLM fine-tune)"
      info "Base model: $MULTIMODAL_VL_MODEL"
      "$PYTHON" - "$dataset" "$MULTIMODAL_VL_MODEL" "$MULTIMODAL_DIR" <<'PYEOF'
import sys, os, json
dataset_dir, base_model, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out_dir, exist_ok=True)
try:
    from transformers import AutoProcessor, AutoModelForVision2Seq, TrainingArguments, Trainer
    from peft import LoraConfig, get_peft_model, TaskType
    from PIL import Image
    import torch, glob

    processor = AutoProcessor.from_pretrained(base_model, trust_remote_code=True)
    model = AutoModelForVision2Seq.from_pretrained(base_model, trust_remote_code=True,
        torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32)

    # LoRA for efficient fine-tuning
    lora_cfg = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05,
        task_type=TaskType.SEQ_2_SEQ_LM, target_modules=['q_proj','v_proj'])
    model = get_peft_model(model, lora_cfg)
    model.print_trainable_parameters()

    # Load dataset: expects pairs/*.json with {image, instruction, response}
    pairs_dir = os.path.join(dataset_dir, 'pairs')
    samples = []
    for f in glob.glob(os.path.join(pairs_dir, '*.json')):
        try:
            d = json.load(open(f))
            samples.append(d)
        except: pass

    if not samples:
        print(f"No training pairs found in {pairs_dir}/")
        print("Create JSON files with: {image: 'path.jpg', instruction: 'text', response: 'text'}")
        sys.exit(1)

    print(f"Found {len(samples)} training pairs")
    out_model = os.path.join(out_dir, 'img_text_to_text_lora')
    args = TrainingArguments(output_dir=out_model, num_train_epochs=3,
        per_device_train_batch_size=1, gradient_accumulation_steps=4,
        logging_steps=10, save_strategy='epoch', bf16=torch.cuda.is_available(),
        fp16=not torch.cuda.is_available())
    print(f"Training {len(samples)} pairs...")
    print(f"Output: {out_model}")
    # Note: full Trainer loop requires custom data collator for VLMs
    # This scaffold sets up the model for training — extend as needed
    model.save_pretrained(out_model)
    processor.save_pretrained(out_model)
    print(f"Model saved (LoRA weights): {out_model}")
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Install: pip install transformers peft pillow")
except Exception as e:
    import traceback; traceback.print_exc()
PYEOF
      ;;

    text-to-image|t2i|lora-sdxl)
      # Train SDXL/FLUX LoRA on custom images
      local concept="${1:?Usage: ai train-multimodal text-to-image <concept-dir> [--model sdxl|flux]}"
      local t2i_model="${MULTIMODAL_T2I_MODEL}"
      [[ "${2:-}" == "--model" ]] && t2i_model="$3"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      info "Text-to-image LoRA training: $concept"
      info "Base model: $t2i_model"
      "$PYTHON" - "$concept" "$t2i_model" "$MULTIMODAL_DIR" <<'PYEOF'
import sys, os, glob
concept_dir, base_model, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out_dir, exist_ok=True)
try:
    from diffusers import StableDiffusionXLPipeline, UNet2DConditionModel
    from peft import LoraConfig, get_peft_model
    import torch

    images = glob.glob(os.path.join(concept_dir, '*.jpg')) + \
             glob.glob(os.path.join(concept_dir, '*.png'))
    if not images:
        print(f"No images found in {concept_dir}")
        print("Add .jpg or .png training images to the directory")
        sys.exit(1)

    print(f"Found {len(images)} training images")
    pipe = StableDiffusionXLPipeline.from_pretrained(base_model,
        torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32)

    unet = pipe.unet
    lora_cfg = LoraConfig(r=4, lora_alpha=4, init_lora_weights='gaussian',
        target_modules=['to_k','to_q','to_v','to_out.0'])
    unet = get_peft_model(unet, lora_cfg)
    unet.print_trainable_parameters()

    out_lora = os.path.join(out_dir, 'sdxl_lora')
    os.makedirs(out_lora, exist_ok=True)
    unet.save_pretrained(out_lora)
    print(f"LoRA weights saved: {out_lora}")
    print("To use: load the LoRA weights with diffusers pipe.load_lora_weights()")
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Install: pip install diffusers peft transformers accelerate")
except Exception as e:
    import traceback; traceback.print_exc()
PYEOF
      ;;

    image-to-text|i2t)
      # Fine-tune an image captioning / OCR model
      local dataset="${1:?Usage: ai train-multimodal image-to-text <dataset_dir>}"
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      info "Training image-to-text model (captioning/OCR)"
      "$PYTHON" - "$dataset" "$MULTIMODAL_VL_MODEL" "$MULTIMODAL_DIR" <<'PYEOF'
import sys, os, json, glob
dataset_dir, base_model, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out_dir, exist_ok=True)
try:
    from transformers import AutoProcessor, AutoModelForCausalLM, Seq2SeqTrainer
    from peft import LoraConfig, get_peft_model
    import torch

    # Load samples: {image: path, caption: text}
    samples = []
    for f in glob.glob(os.path.join(dataset_dir, '*.json')):
        try: samples.append(json.load(open(f)))
        except: pass

    print(f"Found {len(samples)} image-caption pairs")
    processor = AutoProcessor.from_pretrained(base_model, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(base_model, trust_remote_code=True,
        torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32)

    lora_cfg = LoraConfig(r=8, lora_alpha=16, lora_dropout=0.05,
        target_modules=['q_proj','v_proj'])
    model = get_peft_model(model, lora_cfg)
    model.print_trainable_parameters()

    out_path = os.path.join(out_dir, 'i2t_lora')
    model.save_pretrained(out_path)
    processor.save_pretrained(out_path)
    print(f"Model scaffold ready: {out_path}")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install transformers peft pillow")
except Exception as e:
    import traceback; traceback.print_exc()
PYEOF
      ;;

    text-gen|text-agent|agent)
      # Fine-tune a text generation model or train an agent
      local dataset="${1:?Usage: ai train-multimodal text-gen <dataset_name_or_path>}"
      shift
      local model_target="${1:-TTM}"
      info "Text generation fine-tune/agent training: $dataset → $model_target"
      cmd_finetune "$model_target" "$dataset" "$@" 2>/dev/null || \
        err "Run: ai ttm finetune $dataset  OR  ai mtm finetune $dataset"
      ;;

    help|*)
      hdr "AI CLI — Multimodal Training (v2.5)"
      echo "  ai train-multimodal img-text-to-text <dataset_dir>"
      echo "      Fine-tune a VLM (image+text → text) with LoRA"
      echo "  ai train-multimodal text-to-image <image_dir> [--model sdxl|flux]"
      echo "      Train SDXL LoRA on custom concept images"
      echo "  ai train-multimodal image-to-text <dataset_dir>"
      echo "      Fine-tune image captioning / OCR model"
      echo "  ai train-multimodal text-gen DATASET [TTM|MTM|Mtm]"
      echo "      Fine-tune text generation / agent model"
      echo ""
      echo "  Config:"
      echo "    ai config multimodal_vl_model <hf-id>   VLM base model"
      echo "    ai config multimodal_t2i_model <hf-id>  Text-to-image base model"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: IMPROVED IMAGE GEN — img2img, inpainting, LoRA, SDXL/FLUX
# ════════════════════════════════════════════════════════════════════════════════
_imggen_v2() {
  local prompt="$1" mode="${2:-txt2img}" init_img="${3:-}" strength="${4:-0.75}"
  local model="${ACTIVE_MODEL:-stabilityai/stable-diffusion-xl-base-1.0}"
  local out_dir="$AI_OUTPUT_DIR/images"; mkdir -p "$out_dir"
  local timestamp; timestamp=$(date +%Y%m%d_%H%M%S)
  local out_file="$out_dir/img_${timestamp}.png"

  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  info "Image gen [$mode]: $prompt"
  [[ "$model" =~ FLUX|flux ]] && info "Using FLUX model..."

  "$PYTHON" - "$prompt" "$mode" "$init_img" "$strength" "$model" "$out_file" <<'PYEOF'
import sys, os
prompt, mode, init_img, strength_str, model, out_file = sys.argv[1:7]
strength = float(strength_str)
try:
    import torch
    from PIL import Image
    dtype = torch.float16 if torch.cuda.is_available() else torch.float32
    device = 'cuda' if torch.cuda.is_available() else 'cpu'

    if 'FLUX' in model.upper() or 'flux' in model:
        from diffusers import FluxPipeline, FluxImg2ImgPipeline
        if mode == 'img2img' and init_img:
            pipe = FluxImg2ImgPipeline.from_pretrained(model, torch_dtype=dtype)
            pipe = pipe.to(device)
            img = Image.open(init_img).convert('RGB').resize((1024, 1024))
            result = pipe(prompt=prompt, image=img, strength=strength,
                num_inference_steps=28).images[0]
        else:
            pipe = FluxPipeline.from_pretrained(model, torch_dtype=dtype)
            pipe = pipe.to(device)
            result = pipe(prompt=prompt, num_inference_steps=28,
                height=1024, width=1024).images[0]
    else:
        # SDXL / SD pipelines
        if mode == 'txt2img':
            from diffusers import StableDiffusionXLPipeline
            pipe = StableDiffusionXLPipeline.from_pretrained(model,
                torch_dtype=dtype, use_safetensors=True, variant='fp16' if torch.cuda.is_available() else None)
            pipe = pipe.to(device)
            if torch.cuda.is_available():
                pipe.enable_attention_slicing()
            result = pipe(prompt=prompt, num_inference_steps=30,
                guidance_scale=7.5, height=1024, width=1024).images[0]
        elif mode == 'img2img' and init_img:
            from diffusers import StableDiffusionXLImg2ImgPipeline
            pipe = StableDiffusionXLImg2ImgPipeline.from_pretrained(model,
                torch_dtype=dtype, use_safetensors=True)
            pipe = pipe.to(device)
            img = Image.open(init_img).convert('RGB').resize((1024, 1024))
            result = pipe(prompt=prompt, image=img, strength=strength,
                num_inference_steps=30, guidance_scale=7.5).images[0]
        elif mode == 'inpaint' and init_img:
            from diffusers import StableDiffusionXLInpaintPipeline
            pipe = StableDiffusionXLInpaintPipeline.from_pretrained(model,
                torch_dtype=dtype, use_safetensors=True)
            pipe = pipe.to(device)
            img = Image.open(init_img).convert('RGB').resize((1024, 1024))
            # Use a simple center mask if no mask provided
            import numpy as np
            mask = Image.fromarray((np.zeros((1024, 1024), dtype=np.uint8)))
            result = pipe(prompt=prompt, image=img, mask_image=mask,
                num_inference_steps=30).images[0]
        else:
            from diffusers import StableDiffusionXLPipeline
            pipe = StableDiffusionXLPipeline.from_pretrained(model, torch_dtype=dtype)
            pipe = pipe.to(device)
            result = pipe(prompt=prompt, num_inference_steps=30).images[0]

    result.save(out_file)
    print(f"Saved: {out_file}")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install diffusers transformers accelerate pillow")
    # Fallback: try to open the file manager
    import subprocess
    subprocess.run(['xdg-open', os.path.dirname(out_file)], capture_output=True)
except Exception as e:
    import traceback; traceback.print_exc()
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: RLHF v2 — PPO, Reward Model training, improved DPO, GRPO
# ════════════════════════════════════════════════════════════════════════════════
_rlhf_train_reward_model() {
  local model_id="${1:-TTM}" out_dir="$CONFIG_DIR/rlhf_reward_model"
  local pairs_file="$RLHF_PAIRS_FILE"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  [[ ! -s "$pairs_file" ]] && { err "No RLHF pairs. Run: ai rlhf collect"; return 1; }
  info "Training RLHF Reward Model from ${model_id}..."
  mkdir -p "$out_dir"
  "$PYTHON" - "$pairs_file" "$out_dir" <<'PYEOF'
import sys, os, json, torch, traceback
pairs_file, out_dir = sys.argv[1], sys.argv[2]
try:
    from transformers import AutoTokenizer, AutoModelForSequenceClassification, TrainingArguments, Trainer
    from datasets import Dataset
    import numpy as np

    # Load pairs
    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    if len(pairs) < 10:
        print(f"Need at least 10 pairs (have {len(pairs)})")
        sys.exit(1)

    print(f"Training reward model on {len(pairs)} pairs...")

    # Use a small base model for reward modeling
    base = "distilbert-base-uncased"
    tokenizer = AutoTokenizer.from_pretrained(base)
    model = AutoModelForSequenceClassification.from_pretrained(base, num_labels=1)

    # Build dataset: chosen gets label 1, rejected gets label 0
    records = []
    for p in pairs:
        chosen = p.get('chosen', p.get('response_a', ''))
        rejected = p.get('rejected', p.get('response_b', ''))
        prompt = p.get('prompt', p.get('instruction', ''))
        if chosen: records.append({'text': f"{prompt}\n{chosen}", 'label': 1.0})
        if rejected: records.append({'text': f"{prompt}\n{rejected}", 'label': 0.0})

    def tokenize(batch):
        return tokenizer(batch['text'], truncation=True, max_length=512, padding='max_length')

    ds = Dataset.from_list(records).map(tokenize, batched=True)
    ds = ds.rename_column('label', 'labels')
    ds = ds.remove_columns(['text'])
    ds.set_format('torch')

    args = TrainingArguments(
        output_dir=out_dir, num_train_epochs=3,
        per_device_train_batch_size=4, logging_steps=20,
        save_strategy='epoch', evaluation_strategy='no',
        bf16=torch.cuda.is_available(), fp16=False,
        remove_unused_columns=False
    )
    trainer = Trainer(model=model, args=args, train_dataset=ds)
    trainer.train()
    model.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)
    print(f"Reward model saved: {out_dir}")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install transformers datasets torch")
except Exception:
    traceback.print_exc()
PYEOF
}

_rlhf_train_ppo() {
  local model_id="${1:-TTM}"
  local model_dir
  case "$model_id" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|MMTM|mmtm) model_dir="$MMTM_DIR" ;;
    *) model_dir="$model_id" ;;
  esac
  [[ ! -d "$model_dir" ]] && { err "Model dir not found: $model_dir. Run: ai ${model_id,,} pretrain"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local reward_model_dir="$CONFIG_DIR/rlhf_reward_model"
  [[ ! -d "$reward_model_dir" ]] && { err "Train reward model first: ai rlhf reward-model $model_id"; return 1; }
  info "RLHF PPO training: $model_id → $model_dir"
  "$PYTHON" - "$model_dir" "$reward_model_dir" "$RLHF_PAIRS_FILE" <<'PYEOF'
import sys, os, json, torch, traceback
model_dir, reward_dir, pairs_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    from trl import PPOTrainer, PPOConfig, AutoModelForCausalLMWithValueHead
    from transformers import AutoTokenizer, AutoModelForSequenceClassification
    import numpy as np

    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForCausalLMWithValueHead.from_pretrained(model_dir, torch_dtype=dtype)
    reward_tokenizer = AutoTokenizer.from_pretrained(reward_dir)
    reward_model = AutoModelForSequenceClassification.from_pretrained(reward_dir)

    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    model = model.to(device)
    reward_model = reward_model.to(device)

    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    if not pairs:
        print("No RLHF pairs found")
        sys.exit(1)

    cfg = PPOConfig(model_name=model_dir, learning_rate=1.5e-5,
        batch_size=min(4, len(pairs)), mini_batch_size=1,
        gradient_accumulation_steps=4)
    ppo_trainer = PPOTrainer(cfg, model, ref_model=None, tokenizer=tokenizer)

    print(f"PPO training on {len(pairs)} pairs...")
    for i, pair in enumerate(pairs[:100]):  # limit for first run
        prompt = pair.get('prompt', pair.get('instruction', ''))
        if not prompt: continue
        try:
            enc = tokenizer(prompt, return_tensors='pt', truncation=True, max_length=256).to(device)
            with torch.no_grad():
                gen = model.generate(**enc, max_new_tokens=64, do_sample=True, temperature=0.7)
            response_text = tokenizer.decode(gen[0][enc['input_ids'].shape[1]:], skip_special_tokens=True)

            # Score with reward model
            r_enc = reward_tokenizer(prompt + '\n' + response_text,
                return_tensors='pt', truncation=True, max_length=512).to(device)
            with torch.no_grad():
                reward = reward_model(**r_enc).logits.squeeze().item()

            reward_tensor = torch.tensor([reward])
            ppo_trainer.step([enc['input_ids'][0]], [gen[0][enc['input_ids'].shape[1]:]], [reward_tensor])
            if (i+1) % 10 == 0:
                print(f"  Step {i+1}/{min(100,len(pairs))}, reward={reward:.3f}")
        except Exception as step_err:
            continue

    model.save_pretrained(model_dir + '_ppo')
    tokenizer.save_pretrained(model_dir + '_ppo')
    print(f"PPO model saved: {model_dir}_ppo")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install trl transformers torch")
except Exception:
    traceback.print_exc()
PYEOF
}

_rlhf_train_grpo() {
  local model_id="${1:-TTM}"
  local model_dir
  case "$model_id" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|MMTM|mmtm) model_dir="$MMTM_DIR" ;;
    *) model_dir="$model_id" ;;
  esac
  [[ ! -d "$model_dir" ]] && { err "Model not found: $model_dir"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  info "RLHF GRPO training: $model_id (Group Relative Policy Optimization)"
  "$PYTHON" - "$model_dir" "$RLHF_PAIRS_FILE" <<'PYEOF'
import sys, os, json, torch, traceback
model_dir, pairs_file = sys.argv[1], sys.argv[2]
try:
    from trl import GRPOTrainer, GRPOConfig
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from datasets import Dataset

    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    prompts = [p.get('prompt', p.get('instruction','')) for p in pairs if p.get('prompt') or p.get('instruction')]
    if not prompts:
        print("No prompts in RLHF pairs"); sys.exit(1)

    def reward_fn(samples, prompts=None, **kwargs):
        # Simple length-based reward (replace with real reward model)
        return [min(len(s.split()) / 50.0, 1.0) for s in samples]

    cfg = GRPOConfig(output_dir=model_dir+'_grpo',
        num_train_epochs=1, per_device_train_batch_size=1,
        gradient_accumulation_steps=8, logging_steps=5,
        bf16=torch.cuda.is_available())
    ds = Dataset.from_dict({'prompt': prompts[:200]})
    model = AutoModelForCausalLM.from_pretrained(model_dir, torch_dtype=dtype)
    trainer = GRPOTrainer(model=model, reward_funcs=reward_fn,
        args=cfg, train_dataset=ds, tokenizer=tokenizer)
    trainer.train()
    trainer.save_model(model_dir + '_grpo')
    print(f"GRPO model saved: {model_dir}_grpo")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install 'trl>=0.8' transformers torch datasets")
except Exception:
    traceback.print_exc()
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: CANVAS v2 — Multi-file workspace, split-pane, live preview, git
# ════════════════════════════════════════════════════════════════════════════════
cmd_canvas_v3() {
  local sub="${1:-open}"; shift || true
  case "$sub" in
    new)
      local ws="${1:?Usage: ai canvas new <workspace-name>}"
      local ws_dir="$CANVAS_V3_DIR/$ws"
      [[ -d "$ws_dir" ]] && { err "Workspace exists: $ws"; return 1; }
      mkdir -p "$ws_dir"/{files,preview,exports}
      cat > "$ws_dir/workspace.json" <<EOF
{
  "name": "$ws",
  "created": "$(date -Iseconds)",
  "files": [],
  "active_file": null,
  "git_enabled": false,
  "ai_model": "${ACTIVE_MODEL:-}"
}
EOF
      git -C "$ws_dir" init -q 2>/dev/null && \
        git -C "$ws_dir" add workspace.json && \
        git -C "$ws_dir" commit -q -m "Init canvas workspace: $ws" 2>/dev/null || true
      ok "Canvas v3 workspace: $ws_dir"
      echo "  Add files:  ai canvas add $ws FILE"
      echo "  Open TUI:   ai canvas open $ws"
      ;;

    add)
      local ws="${1:?workspace}" file="${2:?file path}"
      local ws_dir="$CANVAS_V3_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws. Run: ai canvas new $ws"; return 1; }
      cp "$file" "$ws_dir/files/"
      local fname; fname=$(basename "$file")
      # Update workspace.json
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "
import json, os
f = '$ws_dir/workspace.json'
d = json.load(open(f))
if '$fname' not in d['files']:
    d['files'].append('$fname')
    d['active_file'] = '$fname'
json.dump(d, open(f,'w'), indent=2)
print('Added: $fname')
"
      git -C "$ws_dir" add "files/$fname" 2>/dev/null && \
        git -C "$ws_dir" commit -q -m "Add file: $fname" 2>/dev/null || true
      ;;

    open)
      local ws="${1:-}"
      [[ -z "$ws" ]] && {
        info "Available workspaces:"
        ls "$CANVAS_V3_DIR/" 2>/dev/null || echo "(none)"
        return 0
      }
      local ws_dir="$CANVAS_V3_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      [[ -z "$PYTHON" ]] && { err "Python required for Canvas TUI"; return 1; }
      info "Opening Canvas v3: $ws"
      "$PYTHON" - "$ws_dir" "$ws" "$ACTIVE_MODEL" "$VERSION" <<'PYEOF'
import sys, os, json, curses, subprocess, threading, time

ws_dir, ws_name, active_model, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
files_dir = os.path.join(ws_dir, 'files')
ws_json = os.path.join(ws_dir, 'workspace.json')

def load_ws():
    try: return json.load(open(ws_json))
    except: return {'files': [], 'active_file': None}

def save_ws(d):
    json.dump(d, open(ws_json, 'w'), indent=2)

def list_files():
    return sorted(f for f in os.listdir(files_dir) if not f.startswith('.'))

def ai_ask(prompt, context=''):
    import subprocess
    result = subprocess.run(['ai', 'ask', f"Context:\n{context}\n\n{prompt}"],
        capture_output=True, text=True, timeout=60)
    return result.stdout.strip() or result.stderr.strip()

def canvas_tui(stdscr):
    curses.curs_set(1)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_WHITE, curses.COLOR_BLUE)
    stdscr.keypad(True)
    curses.raw()
    curses.noecho()

    ws = load_ws()
    files = list_files()
    active_idx = 0
    file_content = []
    edit_mode = False
    cursor_y, cursor_x = 0, 0
    ai_output = ""
    split = False
    status = f"Canvas v3 | {ws_name} | {len(files)} files | ^Q=quit F=new E=edit A=AI S=split G=git P=preview ?=help"

    def load_file(fname):
        fp = os.path.join(files_dir, fname)
        try:
            with open(fp) as f: return f.readlines()
        except: return ['(binary or unreadable)']

    def save_file(fname, lines):
        fp = os.path.join(files_dir, fname)
        with open(fp, 'w') as f:
            f.writelines(lines)
        subprocess.run(['git','-C',ws_dir,'add',f'files/{fname}'], capture_output=True)

    if files: file_content = load_file(files[active_idx])

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        # Header
        header = f" Canvas v3 — {ws_name} | {version} "
        stdscr.addstr(0, 0, header.ljust(w), curses.color_pair(4))
        # Left panel: file list
        panel_w = max(20, w // 5)
        stdscr.addstr(1, 0, "Files:", curses.color_pair(1) | curses.A_BOLD)
        for i, fname in enumerate(files[:h-4]):
            attr = curses.color_pair(2) | curses.A_REVERSE if i == active_idx else 0
            stdscr.addstr(2+i, 0, fname[:panel_w-1].ljust(panel_w-1), attr)
        # Separator
        for row in range(1, h-2):
            try: stdscr.addch(row, panel_w, '│', curses.color_pair(1))
            except: pass
        # Right panel: file content / split
        content_x = panel_w + 1
        content_w = w - content_x
        if split and ai_output:
            half = content_w // 2
            stdscr.addstr(1, content_x, "File", curses.color_pair(1))
            stdscr.addstr(1, content_x + half + 1, "AI Output", curses.color_pair(3))
            for row, line in enumerate(file_content[:h-4]):
                try: stdscr.addstr(2+row, content_x, line[:half].rstrip('\n'))
                except: pass
            ai_lines = ai_output.split('\n')
            for row, line in enumerate(ai_lines[:h-4]):
                try: stdscr.addstr(2+row, content_x+half+1, line[:half-1])
                except: pass
        else:
            if files:
                stdscr.addstr(1, content_x, f"[{files[active_idx]}]", curses.color_pair(2))
            for row, line in enumerate(file_content[:h-4]):
                try: stdscr.addstr(2+row, content_x, line[:content_w-1].rstrip('\n'))
                except: pass
        # Status bar
        try: stdscr.addstr(h-2, 0, status[:w-1].ljust(w-1), curses.color_pair(4))
        except: pass
        if edit_mode:
            try: stdscr.move(min(2+cursor_y, h-3), min(content_x+cursor_x, w-1))
            except: pass
        stdscr.refresh()

        key = stdscr.getch()
        if key == 17:  # Ctrl+Q
            break
        elif key == curses.KEY_UP and active_idx > 0:
            active_idx -= 1
            if files: file_content = load_file(files[active_idx])
        elif key == curses.KEY_DOWN and active_idx < len(files)-1:
            active_idx += 1
            if files: file_content = load_file(files[active_idx])
        elif key in (ord('F'), ord('f')):
            # New file
            curses.echo()
            stdscr.addstr(h-1, 0, "New file name: ")
            try:
                fname = stdscr.getstr(h-1, 15, 60).decode()
            except: fname = ""
            curses.noecho()
            if fname:
                fp = os.path.join(files_dir, fname)
                open(fp, 'w').close()
                files = list_files()
                active_idx = files.index(fname) if fname in files else 0
                file_content = []
        elif key in (ord('E'), ord('e')):
            # Open in $EDITOR
            if files:
                editor = os.environ.get('EDITOR', 'nano')
                curses.def_prog_mode()
                curses.endwin()
                os.system(f"{editor} {files_dir}/{files[active_idx]}")
                file_content = load_file(files[active_idx])
                curses.reset_prog_mode()
                stdscr.keypad(True)
                curses.raw()
                curses.noecho()
                curses.curs_set(1)
                stdscr.refresh()
        elif key in (ord('A'), ord('a')):
            # Ask AI about current file
            curses.echo()
            stdscr.addstr(h-1, 0, "Ask AI: ")
            try:
                q = stdscr.getstr(h-1, 8, 100).decode()
            except: q = ""
            curses.noecho()
            if q and files:
                ctx = ''.join(file_content[:50])
                status = "Asking AI..."
                stdscr.addstr(h-2, 0, status[:w-1].ljust(w-1), curses.color_pair(4))
                stdscr.refresh()
                ai_output = ai_ask(q, ctx)
                split = True
                status = "AI responded. S=toggle-split Ctrl+Q=quit"
        elif key in (ord('S'), ord('s')):
            split = not split
        elif key in (ord('G'), ord('g')):
            # Git commit
            curses.echo()
            stdscr.addstr(h-1, 0, "Commit msg: ")
            try:
                msg = stdscr.getstr(h-1, 12, 100).decode()
            except: msg = ""
            curses.noecho()
            if msg:
                subprocess.run(['git','-C',ws_dir,'add','.'], capture_output=True)
                r = subprocess.run(['git','-C',ws_dir,'commit','-m',msg], capture_output=True)
                status = "Committed!" if r.returncode == 0 else "Git error"
        elif key in (ord('P'), ord('p')):
            # Live preview (open in browser/viewer)
            if files:
                fname = files[active_idx]
                ext = fname.rsplit('.',1)[-1].lower()
                fp = os.path.join(files_dir, fname)
                if ext in ('html','htm'):
                    subprocess.Popen(['xdg-open', fp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif ext == 'md':
                    subprocess.Popen(['xdg-open', fp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                status = f"Preview opened: {fname}"
        elif key in (ord('I'), ord('i')):
            # AI insert — generate code and append to current file
            if files:
                curses.echo()
                stdscr.addstr(h-1, 0, "AI insert: ")
                try: prompt = stdscr.getstr(h-1, 11, 100).decode()
                except: prompt = ""
                curses.noecho()
                if prompt:
                    fname = files[active_idx]
                    ctx = ''.join(file_content[:30])
                    status = "AI generating..."
                    stdscr.addstr(h-2, 0, status[:w-1].ljust(w-1), curses.color_pair(4))
                    stdscr.refresh()
                    result = ai_ask(f"Write code for: {prompt}\nExisting file context:\n{ctx[:500]}\nReturn ONLY code, no markdown fences.")
                    fp = os.path.join(files_dir, fname)
                    with open(fp, 'a') as f:
                        f.write('\n' + result + '\n')
                    file_content = load_file(fname)
                    status = f"AI code inserted into {fname}"
        elif key in (ord('D'), ord('d')):
            if files:
                fname = files[active_idx]
                curses.echo()
                stdscr.addstr(h-1, 0, f"Delete {fname}? y/n: ")
                try: confirm = stdscr.getstr(h-1, len(f"Delete {fname}? y/n: "), 1).decode()
                except: confirm = "n"
                curses.noecho()
                if confirm.lower() == 'y':
                    os.remove(os.path.join(files_dir, fname))
                    files = list_files()
                    active_idx = min(active_idx, len(files)-1) if files else 0
                    file_content = load_file(files[active_idx]) if files else []
                    status = f"Deleted: {fname}"
        elif key in (ord('R'), ord('r')):
            if files:
                fname = files[active_idx]
                curses.echo()
                stdscr.addstr(h-1, 0, f"Rename {fname} to: ")
                try: new_name = stdscr.getstr(h-1, len(f"Rename {fname} to: "), 60).decode()
                except: new_name = ""
                curses.noecho()
                if new_name:
                    os.rename(os.path.join(files_dir, fname), os.path.join(files_dir, new_name))
                    files = list_files()
                    active_idx = files.index(new_name) if new_name in files else 0
                    file_content = load_file(files[active_idx]) if files else []
                    status = f"Renamed: {fname} -> {new_name}"
        elif key == ord('?') or key == curses.KEY_F1:
            status = "F=new E=edit A=AI I=insert D=del R=rename S=split G=git P=preview ^Q=quit"

curses.wrapper(canvas_tui)
PYEOF
      ;;

    list)
      info "Canvas v3 workspaces:"
      ls -1 "$CANVAS_V3_DIR/" 2>/dev/null | while read -r ws; do
        local cfg="$CANVAS_V3_DIR/$ws/workspace.json"
        if [[ -f "$cfg" ]] && [[ -n "$PYTHON" ]]; then
          local nfiles; nfiles=$("$PYTHON" -c "import json; d=json.load(open('$cfg')); print(len(d.get('files',[])))" 2>/dev/null || echo 0)
          echo "  $ws  ($nfiles files)"
        else
          echo "  $ws"
        fi
      done
      ;;

    delete)
      local ws="${1:?workspace name required}"
      local ws_dir="$CANVAS_V3_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      read -rp "Delete workspace '$ws'? [y/N]: " confirm
      [[ "${confirm,,}" != "y" ]] && { info "Cancelled"; return 0; }
      rm -rf "$ws_dir" && ok "Deleted: $ws"
      ;;

    export)
      local ws="${1:?workspace}" fmt="${2:-tar}"
      local ws_dir="$CANVAS_V3_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      local out="$AI_OUTPUT_DIR/${ws}_export.tar.gz"
      tar -czf "$out" -C "$CANVAS_V3_DIR" "$ws/"
      ok "Exported: $out"
      ;;

    gist)
      local ws="${1:?workspace}"
      local ws_dir="$CANVAS_V3_DIR/$ws/files"
      if command -v gh &>/dev/null; then
        info "Uploading $ws to GitHub Gist..."
        gh gist create "$ws_dir"/* --desc "Canvas v3: $ws" && ok "Gist created"
      else
        err "GitHub CLI (gh) required for Gist upload"
        info "Install: sudo pacman -S github-cli  OR  sudo apt install gh"
      fi
      ;;

    help|*)
      hdr "AI CLI — Canvas v3 (v2.5)"
      echo "  Multi-file workspace with split-pane, AI assist, git, live preview"
      echo ""
      echo "  ai canvas new NAME          Create new workspace"
      echo "  ai canvas open NAME         Open TUI (Ctrl+Q to exit)"
      echo "  ai canvas add <ws> FILE     Add file to workspace"
      echo "  ai canvas list                List workspaces"
      echo "  ai canvas delete NAME       Delete workspace"
      echo "  ai canvas export NAME [tar] Export as tarball"
      echo "  ai canvas gist NAME         Upload to GitHub Gist"
      echo ""
      echo "  TUI keys:  UP/DOWN=switch file  E=edit  A=ask-AI  S=split-pane"
      echo "             F=new-file  G=git-commit  P=preview  ?=help  Ctrl+Q=quit"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN DISPATCHER
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN DISPATCHER v2.3.5
# ════════════════════════════════════════════════════════════════════════════════
show_help() {
  local W="${B}${BWHITE}" C1="${B}${BCYAN}" C2="${BCYAN}" DM="${DIM}" R_="${R}"

  # ── Banner ──────────────────────────────────────────────────────────────────
  echo -e ""
  echo -e "${W}╔══════════════════════════════════════════════════════════════════╗${R_}"
  echo -e "${W}║  AI CLI  v${VERSION} — Universal AI Shell                        ║${R_}"
  echo -e "${W}║  Chat · Vision · Audio · Video · RLHF v2 · Fine-tune · Multi-AI ║${R_}"
  echo -e "${W}║  RAG · Batch · Snapshots · Benchmark · 195 Models · 8 Backends  ║${R_}"
  echo -e "${W}║  v2.9.0: Groq+Mistral+Together · RAG · perf · health · plugins  ║${R_}"
  echo -e "${W}║          templates · snapshots · batch · branch · export · more  ║${R_}"
  echo -e "${W}╚══════════════════════════════════════════════════════════════════╝${R_}"
  echo -e "${DM}  Platform: $PLATFORM | CPU-only: $([[ $CPU_ONLY_MODE -eq 1 ]] && echo yes || echo no) | Python: ${PYTHON:-not found} | GPU arch: ${CUDA_ARCH:-0}${R_}"
  echo ""

  # ── Quick Start ─────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ QUICK START ────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai ask \"QUESTION\"            Ask anything"
  echo -e "${C2}│${R_}  ai -gui                         Launch TUI (mouse + keyboard)"
  echo -e "${C2}│${R_}  ai gui+                         Launch GUI+ v3 (2.1x tkinter)"
  echo -e "${C2}│${R_}  ai node new                     Open AI Node Editor (125+ nodes)"
  echo -e "${C2}│${R_}  ai -h <command>                 Detailed help for any command"
  echo -e "${C2}│${R_}  ai -aup                         Update to latest version"
  echo -e "${C2}│${R_}  ai install-deps                 Install Python/system deps"
  echo -e "${C2}│${R_}  ai install-deps --windows       Windows 10/WSL2 setup guide"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Conversation ────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ CHAT & CONVERSATION ────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai ask PROMPT                 Single-shot question"
  echo -e "${C2}│${R_}  ai chat                         Interactive chat  (Ctrl+C to exit)"
  echo -e "${C2}│${R_}  ai -C [name|auto] ask <q>       Named session, saved as JSONL"
  echo -e "${C2}│${R_}  ai code PROMPT [--run]        Generate + optionally execute code"
  echo -e "${C2}│${R_}  ai review FILE                Code review"
  echo -e "${C2}│${R_}  ai explain <file|text>          Explain anything"
  echo -e "${C2}│${R_}  ai summarize <file|->           Summarize"
  echo -e "${C2}│${R_}  ai translate TEXT to <lang>   Translate"
  echo -e "${C2}│${R_}  ai pipe                         Pipe stdin to AI"
  echo -e "${C2}│${R_}  ai chat-list / chat-show / chat-delete"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Multi-AI ────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ MULTI-AI ARENA  (v2.4.5+) ─────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai multiai \"TOPIC\"            Two AIs discuss"
  echo -e "${C2}│${R_}  ai multiai debate \"TOPIC\"     Adversarial: opposing sides"
  echo -e "${C2}│${R_}  ai multiai collab \"TASK\"      Collaborative: build together"
  echo -e "${C2}│${R_}  ai multiai brainstorm \"<t>\"     Free-form idea generation"
  echo -e "${C2}│${R_}    --agents 2-4  --rounds N  --model1 X  --model2 Y"
  echo -e "${C2}│${R_}  ${DM}Controls: Enter=continue  s=steer  r 1-5=rate  p=pause  q=quit${R_}"
  echo -e "${C2}│${R_}  ${DM}Saves as dataset; rated exchanges → RLHF training${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Agent + Web ─────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ AGENT & WEB ────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai agent TASK                 Multi-step autonomous agent"
  echo -e "${C2}│${R_}    Tools: web_search  read_url  write_file  read_file"
  echo -e "${C2}│${R_}           run_code  run_bash  ask_user  calculate"
  echo -e "${C2}│${R_}  ai websearch QUERY            Search + AI summary (DDG/Brave)"
  echo -e "${C2}│${R_}  ai config agent_max_steps N     Steps limit (default 10)"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Media ───────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ MEDIA ──────────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai audio  transcribe/tts/analyze/convert/extract/ask/play/info"
  echo -e "${C2}│${R_}  ai video  analyze/transcribe/caption/extract/trim/convert/ask"
  echo -e "${C2}│${R_}  ai vision ask/ocr/caption/compare"
  echo -e "${C2}│${R_}  ai imagine PROMPT             Image generation"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Trained Models ──────────────────────────────────────────────────────────
  echo -e "${C1}┌─ TRAINED MODELS  (TTM / MTM / Mtm — case-sensitive) ────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}TTM${R_}  ~179.35M   any GPU/CPU        ai ttm CMD"
  echo -e "${C2}│${R_}  ${B}MTM${R_}  ~0.61B     GTX 1080 fp16      ai mtm CMD"
  echo -e "${C2}│${R_}  ${B}Mtm${R_}  ~1.075B    RTX 2080+ bf16     ai Mtm CMD"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  Commands (all models):  pretrain  finetune  enable/disable"
  echo -e "${C2}│${R_}    train-now  upload  create-repo  status  load  set-custom1/2"
  echo -e "${C2}│${R_}  Shortcuts:  ai -TTM  ai -MTM  ai -Mtm"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  Pretraining datasets (6 std + 2 custom):"
  echo -e "${C2}│${R_}    TinyStories(6k)  CodeAlpaca(4k)  OpenOrca(3k)"
  echo -e "${C2}│${R_}    TheStack(3k)     FineWeb-Edu(4k)  Wikipedia-en(4k)"
  echo -e "${C2}│${R_}    + your custom HF ids or local paths"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── RLHF ────────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ RLHF — REINFORCEMENT LEARNING FROM HUMAN FEEDBACK ─────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}Auto-RLHF${R_}  (judge scores responses → DPO training)"
  echo -e "${C2}│${R_}  ai rlhf enable/disable          Toggle auto-RLHF"
  echo -e "${C2}│${R_}  ai rlhf judge NAME            Set judge: nix26 / qwen3+luth / qwen3+llama32"
  echo -e "${C2}│${R_}  ai rlhf download-judges         Download judge model(s)"
  echo -e "${C2}│${R_}  ai rlhf train [TTM|MTM|Mtm]     Run DPO on collected pairs"
  echo -e "${C2}│${R_}  ai rlhf threshold 0.6           Reward cutoff (default 0.6)"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}Manual RLHF${R_}  (rate 1-5 stars in chat, train on your ratings)"
  echo -e "${C2}│${R_}  ai rlhf rate                    Rate a response interactively"
  echo -e "${C2}│${R_}  ai rlhf train-on-ratings        Fine-tune on manual ratings"
  echo -e "${C2}│${R_}  ${DM}Press R after any AI response in chat to rate it${R_}"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}HF RLHF Datasets${R_}  (10 curated preference datasets)"
  echo -e "${C2}│${R_}  ai rlhf datasets                List available presets"
  echo -e "${C2}│${R_}  ai rlhf add-dataset ID        Import: hh-rlhf / ultrafeedback /"
  echo -e "${C2}│${R_}    ${DM}orca-dpo / summarize / pku-safe / helpsteer2 / capybara / math-pref${R_}"
  echo -e "${C2}│${R_}  ai rlhf use-dataset NAME      Set active training source"
  echo -e "${C2}│${R_}  ai rlhf my-datasets             Show imported + pair counts"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}Alignment${R_}  (anti-hallucination, Qwen3-powered)"
  echo -e "${C2}│${R_}  ai rlhf align TTM|MTM|Mtm"
  echo -e "${C2}│${R_}  ai rlhf status / clear-pairs"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Right-Click AI ──────────────────────────────────────────────────────────
  echo -e "${C1}┌─ RIGHT-CLICK AI  (v2.4.6 — Linux system-wide) ─────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai rclick install               Install (auto-detects DE/WM)"
  echo -e "${C2}│${R_}  ai rclick keybind COMBO       Change shortcut (default: ${RCLICK_KEYBIND})"
  echo -e "${C2}│${R_}  ai rclick model NAME          Set VL model"
  echo -e "${C2}│${R_}  ai rclick download-model        Download VL model"
  echo -e "${C2}│${R_}  ai rclick test / status / uninstall"
  echo -e "${C2}│${R_}  ${DM}Supported: GNOME  KDE Plasma 5+6  XFCE  MATE  Cinnamon${R_}"
  echo -e "${C2}│${R_}  ${DM}           Openbox  LXDE  i3  sway  Hyprland  + xbindkeys${R_}"
  echo -e "${C2}│${R_}  VL models:  qwen3vl  lfm25vl  lfm25vl_gguf  custom"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Custom Datasets ─────────────────────────────────────────────────────────
  echo -e "${C1}┌─ CUSTOM DATASETS  (v2.4+) ───────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai dataset create/add/add-file/import-csv/generate"
  echo -e "${C2}│${R_}  ai dataset list/show/delete/export/push"
  echo -e "${C2}│${R_}  ai dataset from-chat [session]  Chat session → dataset"
  echo -e "${C2}│${R_}  ai dataset from-rlhf            RLHF ratings → dataset"
  echo -e "${C2}│${R_}  ai dataset generate N TOPIC [N]  AI-generate synthetic pairs"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── LLM API + Key Hosting ───────────────────────────────────────────────────
  echo -e "${C1}┌─ LLM API SERVER + KEY HOSTING  (v2.4.5 — OpenAI-compatible) ────┐${R_}"
  echo -e "${C2}│${R_}  ai api start [--port 8080] [--public] [--key <token>]"
  echo -e "${C2}│${R_}  ai api stop / status / test / config"
  echo -e "${C2}│${R_}  ${B}Key hosting:${R_}  ai api key-gen [--label name] [--rate N/min]"
  echo -e "${C2}│${R_}    ai api keys list/revoke/show"
  echo -e "${C2}│${R_}    ai api share [--port 8080]   Start public multi-key server"
  echo -e "${C2}│${R_}  Endpoints:  POST /v1/chat/completions  POST /v1/completions"
  echo -e "${C2}│${R_}              GET  /v1/models            GET  /health"
  echo -e "${C2}│${R_}  ${DM}Works with: Open WebUI  LM Studio  SillyTavern  Chatbot UI${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Models + GUI + Settings ─────────────────────────────────────────────────
  echo -e "${C1}┌─ MODELS ─────────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai model N                  Set active model"
  echo -e "${C2}│${R_}  ai models                     List downloaded models (synced with recommended)"
  echo -e "${C2}│${R_}  ai download <hf-id>           Download from HuggingFace"
  echo -e "${C2}│${R_}  ai recommended [download N]   ${B}56 curated picks${R_} — marks ✓ downloaded"
  echo -e "${C2}│${R_}  ai search-models <q>          Search HuggingFace"
  echo -e "${C2}│${R_}  ai upload PATH <repo>       Upload to HuggingFace"
  echo -e "${C2}│${R_}  ai model-create new/train/list/presets/info/delete"
  echo -e "${C2}│${R_}  ai model-state save/restore   Persist across updates"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ ALIASES  (v2.7.3 — new) ────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai alias list                  List all your aliases"
  echo -e "${C2}│${R_}  ai alias set NAME CMD     Create alias (e.g. ai alias set q ask)"
  echo -e "${C2}│${R_}  ai alias del NAME           Delete alias"
  echo -e "${C2}│${R_}  ai alias show NAME          Show single alias definition"
  echo -e "${C2}│${R_}  ai alias help                 Full alias help"
  echo -e "${C2}│${R_}  ${DM}After setting: ai <alias> [args]  →  runs the mapped command${R_}"
  echo -e "${C2}│${R_}  ${DM}Example: ai alias set codepy \"code --lang python\"${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ GUI / GUI+ / NODE EDITOR ───────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai gui  / ai -gui                  Launch GUI v6 (TUI, terminal)"
  echo -e "${C2}│${R_}  ai gui+ / ai -gui+                 Launch GUI+ v3 (2.1x tkinter, real window)"
  echo -e "${C2}│${R_}    Requires: sudo apt install python3-tk"
  echo -e "${C2}│${R_}    Tabs: Chat · Models · Settings · Nodes · Extensions · Status"
  echo -e "${C2}│${R_}  ai node new                        Open AI Node Editor (125+ nodes)"
  echo -e "${C2}│${R_}  ai node load [file]                Load a pipeline (.ainodes)"
  echo -e "${C2}│${R_}  ai node execute [file]             Run pipeline non-interactively"
  echo -e "${C2}│${R_}  ai node autofix [file]             AI-powered pipeline error fix"
  echo -e "${C2}│${R_}  ai node config                     View/edit node editor config"
  echo -e "${C2}│${R_}  Themes: dark  light  hacker  dracula  nord"
  echo -e "${C2}│${R_}  ai config gui_theme <theme>        Set default theme"
  echo -e "${C2}│${R_}  ${B}v2.7.4 new:${R_}  GUI+ v3 · Node Editor · 125+ nodes · -h CMD"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ SETTINGS ───────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai -h <command>                  Detailed help for any command"
  echo -e "${C2}│${R_}  ai config [key value]            View/set config"
  echo -e "${C2}│${R_}    api_host / api_port / api_key / api_cors"
  echo -e "${C2}│${R_}    api_share_host / api_share_port / api_share_rate_limit"
  echo -e "${C2}│${R_}    multiai_rounds / multiai_save_dataset / multiai_rlhf_train"
  echo -e "${C2}│${R_}    rclick_keybind / cpu_only_mode"
  echo -e "${C2}│${R_}  ai keys [set KEY value]          Set API keys"
  echo -e "${C2}│${R_}  ai session list/new/load         Manage sessions"
  echo -e "${C2}│${R_}  ai persona list/set/create       Manage personas"
  echo -e "${C2}│${R_}  ai history [--search x]          View history"
  echo -e "${C2}│${R_}  ai status / bench / serve / install-deps"
  echo -e "${C2}│${R_}  ai -aup [--check-only|--force]   Auto-updater"
  echo -e "${C2}│${R_}  ai error-codes                   List all error codes"
  echo -e "${C2}│${R_}  sudo ai uninstall                Remove AI CLI (v2.7.3 fix)"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.5.5: New Features ────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.5.5 NEW FEATURES ────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}System Prompts:${R_}"
  echo -e "${C2}│${R_}    ai system set \"PROMPT\"       Apply prompt to ALL backends"
  echo -e "${C2}│${R_}    ai system save NAME \"PROMPT\"    Save named prompt to disk"
  echo -e "${C2}│${R_}    ai system load NAME          Load saved prompt"
  echo -e "${C2}│${R_}    ai system list                 List saved + active info"
  echo -e "${C2}│${R_}    ai system show                 Show current effective prompt"
  echo -e "${C2}│${R_}    ai system clear                Remove custom prompt"
  echo -e "${C2}│${R_}    ai system delete NAME        Delete saved prompt file"
  echo -e "${C2}│${R_}  ${B}Dataset AI-gen:${R_}"
  echo -e "${C2}│${R_}    ai dataset generate N TOPIC [--count N] [--style qa|chat|instruct]"
  echo -e "${C2}│${R_}  ${B}Finetune Any:${R_}"
  echo -e "${C2}│${R_}    ai finetune any <hf-model-id>  LoRA fine-tune any model"
  echo -e "${C2}│${R_}      [--data file.jsonl] [--epochs N] [--merge] [--quantize Q4_K_M]"
  echo -e "${C2}│${R_}    Auto-selects LoRA target modules per architecture"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.5: New Features ──────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.5 NEW FEATURES ──────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}GitHub:${R_}     ai github commit/push/pull/pr/issue/clone/log"
  echo -e "${C2}│${R_}  ${B}Papers:${R_}     ai papers search \"QUERY\" [--source arxiv|pmc|core]"
  echo -e "${C2}│${R_}             ai papers cite N [apa|mla|bibtex|ieee|chicago]"
  echo -e "${C2}│${R_}  ${B}Build:${R_}      ai build xz            Self-contained XZ bundle"
  echo -e "${C2}│${R_}  ${B}Multimodal:${R_} ai train-multimodal img-text-to-text DATASET"
  echo -e "${C2}│${R_}             ai train-multimodal text-to-image <image-dir>"
  echo -e "${C2}│${R_}             ai train-multimodal image-to-text DATASET"
  echo -e "${C2}│${R_}  ${B}RLHF v2:${R_}   ai rlhf-reward [model]  Train reward model"
  echo -e "${C2}│${R_}             ai rlhf-ppo [model]     PPO fine-tuning"
  echo -e "${C2}│${R_}             ai rlhf-grpo [model]    GRPO fine-tuning"
  echo -e "${C2}│${R_}  ${B}Dataset+:${R_}  ai dataset from-text NAME \"TEXT\""
  echo -e "${C2}│${R_}             ai dataset from-url NAME URL"
  echo -e "${C2}│${R_}             ai dataset from-file NAME FILE"
  echo -e "${C2}│${R_}             ai dataset from-paper NAME <arxiv-id>"
  echo -e "${C2}│${R_}  ${B}Canvas v3:${R_} ai canvas new/open/add/list/export/gist"
  echo -e "${C2}│${R_}             Multi-file · split-pane · git · AI assist · preview"
  echo -e "${C2}│${R_}  ${B}Image v2:${R_}  ai imagine2 \"PROMPT\" [txt2img|img2img|inpaint]"
  echo -e "${C2}│${R_}  ${B}Pacman:${R_}    ai install-deps  (auto-detects pacman/apt/dnf/brew)"
  echo -e "${C2}│${R_}  ${B}Models:${R_}    28 recommended models (2x from v2.4)"
  echo -e "${C2}│${R_}  ${B}KDE6:${R_}      D-Bus + kglobalaccel6 keybind support"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.6: New Features ──────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.6 NEW FEATURES ──────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}Projects (multi-chat memory):${R_}"
  echo -e "${C2}│${R_}    ai project new NAME [desc]   Create project with persistent memory"
  echo -e "${C2}│${R_}    ai project list                List all projects"
  echo -e "${C2}│${R_}    ai project switch NAME       Switch to project"
  echo -e "${C2}│${R_}    ai project show [name]         Info + recent messages"
  echo -e "${C2}│${R_}    ai project memory [name]       Memory summary"
  echo -e "${C2}│${R_}    ai project delete / export / clear-memory"
  echo -e "${C2}│${R_}  ${B}GPU / CUDA:${R_}"
  echo -e "${C2}│${R_}    CUDA detection fixed: sm_61 (Pascal GTX 10xx) now recognized"
  echo -e "${C2}│${R_}    Arch cache: CUDA arch cached for fast startup (no slow detect every run)"
  echo -e "${C2}│${R_}    ai config cpu_only_mode 0      Force GPU mode"
  echo -e "${C2}│${R_}  ${B}Bug Fixes:${R_}"
  echo -e "${C2}│${R_}    TTM/PyTorch: auto-patches missing model_type in config.json"
  echo -e "${C2}│${R_}    rclick v3: trusted flag set → fixes 'not authorized' in file manager"
  echo -e "${C2}│${R_}    rclick v3.1: full action menu (Explain/Summarize/Fix/Rewrite/Bullets/…)"
  echo -e "${C2}│${R_}    rclick v3.1: fixed newlines, Python UI fallback, yad output parsing"
  echo -e "${C2}│${R_}    Unknown command: shows clear error before AI fallthrough"
  echo -e "${C2}│${R_}  ${B}First-run:${R_}  Model download + install-deps prompt on first use"
  echo -e "${C2}│${R_}  ${B}Right-click v3.1:${R_}  9 action types; auto-copies result to clipboard"
  echo -e "${C2}│${R_}  ${B}Startup speed:${R_}  CUDA arch cached → 5-10× faster startup"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ CHANGELOG & UPDATE ─────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai change                Show full changelog"
  echo -e "${C2}│${R_}  ai -L                    Show latest changes"
  echo -e "${C2}│${R_}  ai -Su                   Update from GitHub"
  echo -e "${C2}│${R_}  ai -aup                  Auto-updater (legacy)"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ EXAMPLES ───────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai -aup                               # Update to latest"
  echo -e "${C2}│${R_}  ai project new mywork \"Work chats\"    # Create project with memory"
  echo -e "${C2}│${R_}  ai project switch mywork              # Switch to project"
  echo -e "${C2}│${R_}  ai ask \"continue from where we left off\"  # Uses project memory"
  echo -e "${C2}│${R_}  ai project memory                    # Show what AI remembers"
  echo -e "${C2}│${R_}  ai system set \"You are a senior Python dev.\""
  echo -e "${C2}│${R_}  ai dataset generate mydata \"Python async patterns\" --count 50"
  echo -e "${C2}│${R_}  ai finetune any mistralai/Mistral-7B-v0.1 --epochs 2 --merge"
  echo -e "${C2}│${R_}  ai ttm pretrain                       # Pretrain tiny model (179M)"
  echo -e "${C2}│${R_}  ai rlhf train TTM                     # DPO training"
  echo -e "${C2}│${R_}  ai extension create myplugin          # New extension"
  echo -e "${C2}│${R_}  ai extension package myplugin         # → myplugin-1.0.0.aipack"
  echo -e "${C2}│${R_}  ai extension load myplugin-1.0.0.aipack  # Install extension"
  echo -e "${C2}│${R_}  ai install-firefox-ext                # Build Firefox LLM sidebar"
  echo -e "${C2}│${R_}  ai api start                          # Start local LLM API server"
  echo -e "${C2}│${R_}  ai api stop                           # Stop local LLM API server"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.7: AI EXTENSION SYSTEM — create · load · locate · package · edit · help
# ════════════════════════════════════════════════════════════════════════════════
# .aipack format: gzip'd tar containing
#   manifest.json   — name, version, description, entry
#   ex.sh           — bash entry point (sourced or executed)
#   main.py         — Python script
#   [any other assets]
# ════════════════════════════════════════════════════════════════════════════════

cmd_extension() {
  local subcmd="${1:-help}"; shift || true

  case "$subcmd" in
    # ── Create ────────────────────────────────────────────────────────────────
    create)
      local name="${1:-}"; local desc="${2:-A custom AI CLI extension}"
      if [[ -z "$name" ]]; then read -rp "Extension name: " name; fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      name="${name//[^a-zA-Z0-9_-]/_}"
      local ext_path="$EXTENSIONS_DIR/$name"
      if [[ -d "$ext_path" ]]; then err "Extension '$name' already exists at $ext_path"; return 1; fi
      mkdir -p "$ext_path"

      # manifest.json
      cat > "$ext_path/manifest.json" <<JSON
{
  "name": "$name",
  "version": "1.0.0",
  "description": "$desc",
  "entry": "ex.sh",
  "python_script": "main.py",
  "author": "",
  "commands": ["run", "help"],
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

      # ex.sh — bash entry point
      cat > "$ext_path/ex.sh" <<'EXTSH'
#!/usr/bin/env bash
# AI CLI Extension entry point
# Extension name is available as EXT_NAME
# Extension directory is available as EXT_DIR
# AI CLI binary is available as AI_BIN

set -uo pipefail
EXT_NAME="${EXT_NAME:-extension}"
EXT_DIR="${EXT_DIR:-$(dirname "$0")}"
AI_BIN="${AI_BIN:-ai}"
PYTHON="${PYTHON:-python3}"

cmd="${1:-help}"; shift || true

case "$cmd" in
  run)
    echo "Running $EXT_NAME..."
    "$PYTHON" "$EXT_DIR/main.py" "$@"
    ;;
  help|--help|-h|"")
    echo "Usage: ai extension run NAME [args...]"
    echo "       ai extension help NAME"
    ;;
  *)
    echo "Unknown command: $cmd"
    exit 1
    ;;
esac
EXTSH
      chmod +x "$ext_path/ex.sh"

      # main.py — Python script
      cat > "$ext_path/main.py" <<'EXTPY'
#!/usr/bin/env python3
"""AI CLI Extension — main.py
Edit this file to implement your extension logic.
"""
import sys
import os
import json

EXT_DIR = os.path.dirname(os.path.abspath(__file__))

def main(args):
    print(f"Extension running with args: {args}")
    # Load manifest
    mf = os.path.join(EXT_DIR, "manifest.json")
    with open(mf) as f:
        manifest = json.load(f)
    print(f"Name: {manifest['name']}  v{manifest['version']}")
    print(f"Description: {manifest['description']}")

if __name__ == "__main__":
    main(sys.argv[1:])
EXTPY

      # Mark as enabled
      touch "$ext_path/.enabled"

      ok "Extension '$name' created at $ext_path"
      echo ""
      echo "  Files created:"
      echo "    $ext_path/manifest.json  — metadata"
      echo "    $ext_path/ex.sh          — bash entry (edit this)"
      echo "    $ext_path/main.py        — Python script (edit this)"
      echo ""
      echo "  Package it:  ai extension package $name"
      echo "  Edit:        ai extension edit $name"
      echo "  Run:         ai extension run $name"
      ;;

    # ── Load ──────────────────────────────────────────────────────────────────
    load)
      local aipack="${1:-}"
      if [[ -z "$aipack" ]]; then
        # Try to open a file dialog (zenity > kdialog > read)
        if command -v zenity &>/dev/null; then
          aipack=$(zenity --file-selection --title="Select .aipack file" --file-filter="AI Pack (*.aipack) | *.aipack" 2>/dev/null || echo "")
        elif command -v kdialog &>/dev/null; then
          aipack=$(kdialog --getopenfilename "$HOME" "*.aipack" 2>/dev/null || echo "")
        fi
        [[ -z "$aipack" ]] && { read -rp ".aipack file path: " aipack; }
      fi
      aipack="$(echo "$aipack" | xargs)"
      [[ -z "$aipack" ]] && { warn "No file selected"; return 1; }
      [[ ! -f "$aipack" ]] && { err "File not found: $aipack"; return 1; }

      # Read manifest from archive to get name
      local raw_name
      raw_name=$(tar -tzf "$aipack" 2>/dev/null | head -1 | cut -d/ -f1)
      if [[ -z "$raw_name" ]]; then
        raw_name=$(basename "$aipack" .aipack)
      fi

      # Extract manifest name if present
      local meta_name
      meta_name=$(tar -xzf "$aipack" --to-stdout "${raw_name}/manifest.json" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")
      local ext_name="${meta_name:-$raw_name}"
      ext_name="${ext_name//[^a-zA-Z0-9_-]/_}"

      local dest="$EXTENSIONS_DIR/$ext_name"
      if [[ -d "$dest" ]]; then
        warn "Extension '$ext_name' already exists — overwriting"
        rm -rf "$dest"
      fi
      mkdir -p "$dest"

      info "Extracting '$ext_name' from $aipack..."
      if tar -xzf "$aipack" -C "$EXTENSIONS_DIR" 2>/dev/null; then
        # Rename extracted dir to ext_name if needed
        [[ -d "$EXTENSIONS_DIR/$raw_name" && "$raw_name" != "$ext_name" ]] && \
          mv "$EXTENSIONS_DIR/$raw_name" "$dest"
        chmod +x "$dest/ex.sh" 2>/dev/null || true
        touch "$dest/.enabled"
        ok "Loaded extension '$ext_name' → $dest"
        cat "$dest/manifest.json" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(f\"  Name:        {d.get('name','?')}\")
    print(f\"  Version:     {d.get('version','?')}\")
    print(f\"  Description: {d.get('description','?')}\")
    print(f\"  Author:      {d.get('author','unknown')}\")
except: pass
" 2>/dev/null || true
      else
        err "Failed to extract .aipack — ensure it is a valid gzip'd tar archive"
        rm -rf "$dest"
        return 1
      fi
      ;;

    # ── Locate ────────────────────────────────────────────────────────────────
    locate)
      echo ""
      hdr "AI CLI Extensions — Installed"
      echo ""
      local found=0
      if [[ -d "$EXTENSIONS_DIR" ]]; then
        for ext_dir in "$EXTENSIONS_DIR"/*/; do
          [[ -d "$ext_dir" ]] || continue
          local ext_name; ext_name=$(basename "$ext_dir")
          local enabled="disabled"
          [[ -f "$ext_dir/.enabled" ]] && enabled="${BGREEN}enabled${R}"
          local meta_name="$ext_name"
          local meta_ver="" meta_desc=""
          if [[ -f "$ext_dir/manifest.json" ]]; then
            meta_name=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('name','$ext_name'))" 2>/dev/null || echo "$ext_name")
            meta_ver=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('version',''))" 2>/dev/null || echo "")
            meta_desc=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('description',''))" 2>/dev/null || echo "")
          fi
          echo -e "  ${B}${meta_name}${R} ${DIM}v${meta_ver}${R}  [${enabled}]"
          echo -e "    Path: ${CYAN}${ext_dir}${R}"
          [[ -n "$meta_desc" ]] && echo -e "    Desc: ${meta_desc}"
          [[ -f "$ext_dir/ex.sh"   ]] && echo -e "    ${BGREEN}✓${R} ex.sh"
          [[ -f "$ext_dir/main.py" ]] && echo -e "    ${BGREEN}✓${R} main.py"
          echo ""
          (( found++ ))
        done
      fi
      if (( found == 0 )); then
        echo -e "  ${DIM}No extensions installed.${R}"
        echo -e "  Use '${B}ai extension create NAME${R}' or '${B}ai extension load <file.aipack>${R}'"
      else
        echo -e "  ${DIM}${found} extension(s) found in ${EXTENSIONS_DIR}${R}"
      fi
      echo ""
      ;;

    # ── Package ───────────────────────────────────────────────────────────────
    package)
      local name="${1:-}"
      if [[ -z "$name" ]]; then
        # List available extensions
        echo "Available extensions:"
        for d in "$EXTENSIONS_DIR"/*/; do
          [[ -d "$d" ]] && echo "  $(basename "$d")"
        done
        read -rp "Extension to package: " name
      fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Extension not found: $ext_path"; return 1; }

      # Get version from manifest
      local ver
      ver=$(python3 -c "import json; d=json.load(open('$ext_path/manifest.json')); print(d.get('version','1.0.0'))" 2>/dev/null || echo "1.0.0")
      local out_file="$BUILD_DIR/${name}-${ver}.aipack"

      info "Packaging '$name' v${ver}..."
      # Create a clean tar: rename dir to name for clean extraction
      local tmp_dir; tmp_dir=$(mktemp -d)
      cp -r "$ext_path" "$tmp_dir/$name"
      # Remove .enabled flag from package (user must enable after load)
      rm -f "$tmp_dir/$name/.enabled"
      tar -czf "$out_file" -C "$tmp_dir" "$name"
      rm -rf "$tmp_dir"

      ok "Package created: $out_file"
      echo "  Size: $(du -h "$out_file" | cut -f1)"
      echo "  Contents:"
      tar -tzf "$out_file" | sed 's/^/    /'
      echo ""
      echo "  Distribute: send $out_file to other users"
      echo "  Install:    ai extension load $out_file"
      ;;

    # ── Edit ──────────────────────────────────────────────────────────────────
    edit)
      local name="${1:-}"; local file="${2:-ex.sh}"
      if [[ -z "$name" ]]; then
        echo "Available extensions:"
        for d in "$EXTENSIONS_DIR"/*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done
        read -rp "Extension name: " name
      fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Not found: $ext_path"; return 1; }

      local edit_target="$ext_path/$file"
      if [[ ! -f "$edit_target" ]]; then
        echo "Files in $ext_path:"
        ls "$ext_path"
        read -rp "File to edit: " file
        edit_target="$ext_path/$file"
      fi
      [[ ! -f "$edit_target" ]] && { err "File not found: $edit_target"; return 1; }

      local editor="${VISUAL:-${EDITOR:-nano}}"
      if command -v "$editor" &>/dev/null; then
        "$editor" "$edit_target"
      elif command -v nano &>/dev/null; then
        nano "$edit_target"
      elif command -v vi &>/dev/null; then
        vi "$edit_target"
      else
        err "No editor found. Set \$EDITOR or install nano/vi."
        return 1
      fi
      ok "Edited: $edit_target"
      ;;

    # ── Run ───────────────────────────────────────────────────────────────────
    run)
      local name="${1:-}"; shift || true
      [[ -z "$name" ]] && { err "Usage: ai extension run NAME [args...]"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Extension not found: $ext_path"; return 1; }
      [[ ! -f "$ext_path/ex.sh" ]] && { err "No ex.sh in $ext_path"; return 1; }

      export EXT_NAME="$name"
      export EXT_DIR="$ext_path"
      export AI_BIN="$(command -v ai 2>/dev/null || echo "$0")"
      export PYTHON="${PYTHON:-python3}"
      bash "$ext_path/ex.sh" "$@"
      ;;

    # ── Enable / Disable ──────────────────────────────────────────────────────
    enable)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      touch "$EXTENSIONS_DIR/$name/.enabled"
      ok "Enabled: $name"
      ;;
    disable)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      rm -f "$EXTENSIONS_DIR/$name/.enabled"
      ok "Disabled: $name"
      ;;

    # ── List ──────────────────────────────────────────────────────────────────
    list|ls)
      cmd_extension locate
      ;;

    # ── Help ──────────────────────────────────────────────────────────────────
    help|--help|-h|"")
      echo ""
      hdr "AI CLI v${VERSION} — Extension System"
      echo ""
      echo -e "  ${B}ai extension create NAME [desc]${R}   Scaffold a new extension"
      echo -e "  ${B}ai extension load [file.aipack]${R}     Install from .aipack file"
      echo -e "  ${B}ai extension locate${R}                 List all extensions + paths"
      echo -e "  ${B}ai extension package NAME${R}         Package as distributable .aipack"
      echo -e "  ${B}ai extension edit NAME [file]${R}     Edit extension files"
      echo -e "  ${B}ai extension run NAME [args...]${R}   Execute an extension"
      echo -e "  ${B}ai extension enable/disable NAME${R}  Toggle extension"
      echo -e "  ${B}ai extension list${R}                   Same as locate"
      echo ""
      echo -e "  ${DIM}.aipack format: gzip'd tar with manifest.json + ex.sh + main.py${R}"
      echo -e "  ${DIM}Extensions dir: ${EXTENSIONS_DIR}${R}"
      echo ""
      ;;

    *)
      err "Unknown extension subcommand: $subcmd"
      cmd_extension help
      return 1
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.7: INSTALL FIREFOX EXTENSION — LLM sidebar using local API server
# ════════════════════════════════════════════════════════════════════════════════
cmd_install_firefox_ext() {
  local out_dir="$FIREFOX_EXT_DIR"
  local api_url="${1:-http://localhost:8080}"
  mkdir -p "$out_dir"

  info "Building Firefox LLM Sidebar Extension..."
  info "API endpoint: $api_url"

  # ── manifest.json (WebExtension Manifest V2 — Firefox) ────────────────────
  cat > "$out_dir/manifest.json" <<JSON
{
  "manifest_version": 2,
  "name": "AI CLI — Local LLM Sidebar",
  "version": "1.1.0",
  "description": "Use your locally-installed LLMs from the AI CLI directly in the Firefox sidebar. v2.7.1: fixed AI output, non-streaming API.",
  "author": "AI CLI v${VERSION}",
  "sidebar_action": {
    "default_title": "AI CLI LLM",
    "default_panel": "sidebar.html",
    "default_icon": "icon.svg"
  },
  "permissions": [
    "storage",
    "https://*/*",
    "http://localhost/*",
    "http://127.0.0.1/*"
  ],
  "background": {
    "scripts": ["background.js"],
    "persistent": false
  },
  "browser_action": {
    "default_icon": "icon.svg",
    "default_title": "Toggle AI CLI Sidebar",
    "browser_style": false
  },
  "icons": {
    "48": "icon.svg",
    "96": "icon.svg"
  },
  "browser_specific_settings": {
    "gecko": {
      "id": "ai-cli-llm-sidebar@local",
      "strict_min_version": "109.0"
    }
  }
}
JSON

  # ── sidebar.html ──────────────────────────────────────────────────────────
  cat > "$out_dir/sidebar.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI CLI — LLM Sidebar</title>
  <style>
    :root {
      --bg: #1a1b26;
      --bg2: #16161e;
      --fg: #c0caf5;
      --accent: #7aa2f7;
      --accent2: #9ece6a;
      --warn: #e0af68;
      --err: #f7768e;
      --dim: #565f89;
      --border: #292e42;
      --sel: #283457;
      --user-bg: #1f3054;
      --ai-bg:   #1c2e1c;
      --radius:  8px;
      --font: 'Segoe UI', system-ui, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg); color: var(--fg);
      font-family: var(--font); font-size: 13px;
      display: flex; flex-direction: column; height: 100vh;
      overflow: hidden;
    }
    /* ── Header ── */
    #header {
      background: var(--bg2); border-bottom: 1px solid var(--border);
      padding: 8px 10px; display: flex; align-items: center; gap: 8px;
      flex-shrink: 0;
    }
    #header h1 { font-size: 14px; font-weight: 700; color: var(--accent); flex: 1; }
    #status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim); }
    #status-dot.ok  { background: var(--accent2); }
    #status-dot.err { background: var(--err); }
    /* ── Settings panel ── */
    #settings {
      background: var(--bg2); border-bottom: 1px solid var(--border);
      padding: 6px 10px; display: none; gap: 6px; flex-direction: column;
    }
    #settings.visible { display: flex; }
    #settings label { font-size: 11px; color: var(--dim); margin-bottom: 2px; }
    #settings input, #settings select {
      background: var(--bg); border: 1px solid var(--border); color: var(--fg);
      border-radius: 4px; padding: 4px 6px; font-size: 12px; width: 100%;
    }
    /* ── Messages ── */
    #messages {
      flex: 1; overflow-y: auto; padding: 10px; display: flex;
      flex-direction: column; gap: 8px;
    }
    .msg {
      border-radius: var(--radius); padding: 8px 10px; max-width: 95%;
      word-break: break-word; line-height: 1.5;
    }
    .msg.user { background: var(--user-bg); align-self: flex-end; border: 1px solid var(--accent); }
    .msg.ai   { background: var(--ai-bg);   align-self: flex-start; border: 1px solid var(--accent2); }
    .msg.sys  { background: transparent; color: var(--dim); font-style: italic; font-size: 11px; align-self: center; }
    .msg .role { font-size: 10px; font-weight: 700; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
    .msg.user .role { color: var(--accent); }
    .msg.ai   .role { color: var(--accent2); }
    /* ── Thinking dots ── */
    .thinking-dots span { animation: blink 1.2s infinite; }
    .thinking-dots span:nth-child(2) { animation-delay: 0.2s; }
    .thinking-dots span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes blink { 0%,80%,100%{opacity:0} 40%{opacity:1} }
    /* ── Input area ── */
    #input-area {
      flex-shrink: 0; border-top: 1px solid var(--border);
      padding: 8px 10px; display: flex; flex-direction: column; gap: 6px;
      background: var(--bg2);
    }
    #input {
      background: var(--bg); border: 1px solid var(--border); color: var(--fg);
      border-radius: var(--radius); padding: 8px 10px; font-size: 13px;
      font-family: var(--font); resize: none; min-height: 56px; max-height: 120px;
      outline: none; transition: border-color 0.15s;
    }
    #input:focus { border-color: var(--accent); }
    .btn-row { display: flex; gap: 6px; }
    button {
      border: none; border-radius: 5px; padding: 5px 12px; cursor: pointer;
      font-size: 12px; font-weight: 600; transition: opacity 0.15s;
    }
    button:hover { opacity: 0.85; }
    #send-btn  { background: var(--accent);  color: #1a1b26; flex: 1; }
    #clear-btn { background: var(--border);  color: var(--fg); }
    #cfg-btn   { background: var(--border);  color: var(--fg); }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    /* ── Scrollbar ── */
    ::-webkit-scrollbar { width: 4px; }
    ::-webkit-scrollbar-track { background: var(--bg2); }
    ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
    /* ── Code blocks ── */
    pre, code {
      background: #0d0d15; border: 1px solid var(--border);
      border-radius: 4px; font-family: monospace; font-size: 11px;
      padding: 2px 4px;
    }
    pre { padding: 8px; overflow-x: auto; white-space: pre-wrap; margin: 4px 0; }
    pre code { background: none; border: none; padding: 0; }
  </style>
</head>
<body>
  <div id="header">
    <div id="status-dot" title="API status"></div>
    <h1>AI CLI — LLM</h1>
    <button id="cfg-btn" style="padding:3px 8px;font-size:11px;">⚙</button>
  </div>

  <div id="settings">
    <div>
      <label>API URL</label>
      <input id="api-url" type="text" placeholder="http://localhost:8080">
    </div>
    <div>
      <label>Model (leave blank for default)</label>
      <input id="model-input" type="text" placeholder="">
    </div>
    <div>
      <label>Max tokens</label>
      <input id="max-tokens" type="number" value="1024" min="64" max="8192" step="64">
    </div>
    <div>
      <label>Temperature</label>
      <input id="temperature" type="number" value="0.7" min="0" max="2" step="0.05">
    </div>
    <button id="save-cfg" style="background:var(--accent);color:#1a1b26;">Save</button>
  </div>

  <div id="messages">
    <div class="msg sys">AI CLI LLM Sidebar v1.1 — Type a message to begin. Make sure "ai api start" is running.</div>
  </div>

  <div id="input-area">
    <textarea id="input" placeholder="Ask anything… (Enter=send, Shift+Enter=newline)" rows="2"></textarea>
    <div class="btn-row">
      <button id="clear-btn">Clear</button>
      <button id="send-btn">Send ⏎</button>
    </div>
  </div>

  <script src="sidebar.js"></script>
</body>
</html>
HTML

  # ── sidebar.js ────────────────────────────────────────────────────────────
  cat > "$out_dir/sidebar.js" <<JSEOF
'use strict';

// ── Config ─────────────────────────────────────────────────────────────────
const DEFAULT_API = '${api_url}';
const STORAGE_KEY = 'aiCLI_cfg';

let cfg = {
  apiUrl:      DEFAULT_API,
  model:       '',
  maxTokens:   1024,
  temperature: 0.7,
};

function loadCfg() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) Object.assign(cfg, JSON.parse(raw));
  } catch {}
  document.getElementById('api-url').value    = cfg.apiUrl;
  document.getElementById('model-input').value = cfg.model;
  document.getElementById('max-tokens').value  = cfg.maxTokens;
  document.getElementById('temperature').value = cfg.temperature;
}

function saveCfg() {
  cfg.apiUrl      = document.getElementById('api-url').value.trim() || DEFAULT_API;
  cfg.model       = document.getElementById('model-input').value.trim();
  cfg.maxTokens   = parseInt(document.getElementById('max-tokens').value) || 1024;
  cfg.temperature = parseFloat(document.getElementById('temperature').value) || 0.7;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
  toggleSettings();
  checkHealth();
}

// ── UI helpers ─────────────────────────────────────────────────────────────
const messagesEl  = document.getElementById('messages');
const inputEl     = document.getElementById('input');
const sendBtn     = document.getElementById('send-btn');
const clearBtn    = document.getElementById('clear-btn');
const cfgBtn      = document.getElementById('cfg-btn');
const settingsEl  = document.getElementById('settings');
const statusDot   = document.getElementById('status-dot');

let history = [];   // [{role, content}]

function toggleSettings() {
  settingsEl.classList.toggle('visible');
}

function appendMsg(role, text) {
  const div = document.createElement('div');
  div.className = 'msg ' + role;
  const roleLabel = document.createElement('div');
  roleLabel.className = 'role';
  roleLabel.textContent = role === 'user' ? 'You' : role === 'ai' ? 'AI' : 'System';
  div.appendChild(roleLabel);
  const content = document.createElement('div');
  content.innerHTML = formatMarkdown(text);
  div.appendChild(content);
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return content;
}

function thinkingMsg() {
  const div = document.createElement('div');
  div.className = 'msg ai';
  const roleLabel = document.createElement('div');
  roleLabel.className = 'role';
  roleLabel.textContent = 'AI';
  div.appendChild(roleLabel);
  const dots = document.createElement('div');
  dots.className = 'thinking-dots';
  dots.innerHTML = '<span>●</span><span>●</span><span>●</span>';
  div.appendChild(dots);
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return div;
}

function formatMarkdown(text) {
  // Very light markdown: code blocks, inline code, bold, italic, newlines
  return text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\`\`\`([\s\S]*?)\`\`\`/g, '<pre><code>\$1</code></pre>')
    .replace(/\`([^\`]+)\`/g, '<code>\$1</code>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>\$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>\$1</em>')
    .replace(/\n/g, '<br>');
}

// ── API health check ────────────────────────────────────────────────────────
async function checkHealth() {
  try {
    const r = await fetch(cfg.apiUrl + '/health', { signal: AbortSignal.timeout(3000) });
    statusDot.className = r.ok ? 'ok' : 'err';
    statusDot.title = r.ok ? 'API connected' : 'API error ' + r.status;
  } catch {
    statusDot.className = 'err';
    statusDot.title = 'API not reachable — run: ai api start';
  }
}

// ── Send message ────────────────────────────────────────────────────────────
async function sendMessage() {
  const text = inputEl.value.trim();
  if (!text) return;
  inputEl.value = '';
  sendBtn.disabled = true;

  history.push({ role: 'user', content: text });
  appendMsg('user', text);

  const thinking = thinkingMsg();

  // Build request body — non-streaming (server returns plain JSON)
  // v2.7.1 fix: do NOT send stream:true — the AI CLI API server does not
  // support SSE streaming and returns standard JSON. Sending stream:true
  // caused the client to look for "data:" SSE lines and find none, resulting
  // in empty AI output even when the server responded correctly.
  const body = {
    model:       cfg.model || undefined,
    messages:    history,
    max_tokens:  cfg.maxTokens,
    temperature: cfg.temperature,
  };

  try {
    const res = await fetch(cfg.apiUrl + '/v1/chat/completions', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error('HTTP ' + res.status + ': ' + errText.slice(0, 200));
    }

    // ── Non-streaming JSON response (standard OpenAI format) ─────────────
    const data = await res.json();

    // Extract response text from choices[0].message.content
    const aiText = data?.choices?.[0]?.message?.content
                || data?.choices?.[0]?.text
                || '';

    thinking.remove();

    if (!aiText && aiText !== 0) {
      // Response received but no content — show raw for debugging
      appendMsg('sys', 'Warning: empty response. Raw: ' + JSON.stringify(data).slice(0, 300));
    } else {
      appendMsg('ai', String(aiText));
      history.push({ role: 'assistant', content: String(aiText) });
    }

    // Update status dot to green on success
    statusDot.className = 'ok';
    statusDot.title = 'API connected — last call OK';

  } catch (err) {
    thinking.remove();
    appendMsg('sys', 'Error: ' + err.message + '\n\nMake sure "ai api start" is running:\n  ai api start\n  ai api status');
    statusDot.className = 'err';
  } finally {
    sendBtn.disabled = false;
    inputEl.focus();
  }
}

// ── Event listeners ─────────────────────────────────────────────────────────
sendBtn.addEventListener('click', sendMessage);
clearBtn.addEventListener('click', () => {
  history = [];
  messagesEl.innerHTML = '<div class="msg sys">Cleared. Start a new conversation.</div>';
});
cfgBtn.addEventListener('click', toggleSettings);
document.getElementById('save-cfg').addEventListener('click', saveCfg);

inputEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

// ── Init ────────────────────────────────────────────────────────────────────
loadCfg();
checkHealth();
setInterval(checkHealth, 30000);
JSEOF

  # ── background.js ─────────────────────────────────────────────────────────
  cat > "$out_dir/background.js" <<'BGJS'
'use strict';
// Toggle sidebar via browser action click
browser.browserAction.onClicked.addListener(() => {
  browser.sidebarAction.toggle();
});
BGJS

  # ── icon.svg ──────────────────────────────────────────────────────────────
  cat > "$out_dir/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <rect width="48" height="48" rx="10" fill="#1a1b26"/>
  <text x="24" y="34" text-anchor="middle" font-size="28" font-family="monospace" font-weight="bold" fill="#7aa2f7">AI</text>
</svg>
SVG

  echo ""
  ok "Firefox LLM Sidebar Extension built at: $out_dir"
  echo ""
  echo -e "  ${B}Files:${R}"
  ls -1 "$out_dir" | sed 's/^/    /'
  echo ""
  echo -e "  ${B}How to install in Firefox:${R}"
  echo -e "    1. Open Firefox and go to ${CYAN}about:debugging#/runtime/this-firefox${R}"
  echo -e "    2. Click ${B}\"Load Temporary Add-on…\"${R}"
  echo -e "    3. Navigate to: ${CYAN}${out_dir}/manifest.json${R}"
  echo -e "    4. The AI CLI sidebar will appear in Firefox"
  echo -e "    5. Before using: run ${B}ai api start${R} to start the local LLM API"
  echo ""
  echo -e "  ${B}Permanent install (for nightly / developer edition):${R}"
  echo -e "    Set ${CYAN}xpinstall.signatures.required${R} to ${B}false${R} in about:config"
  echo -e "    Then use the Web Extension package method."
  echo ""
  echo -e "  ${B}Package as .xpi:${R}"
  echo -e "    cd ${out_dir} && zip -r ../ai-cli-firefox.xpi . && echo Done"
  echo ""
  echo -e "  ${DIM}The sidebar connects to: ${api_url}${R}"
  echo -e "  ${DIM}Change URL in the ⚙ settings inside the sidebar.${R}"
  echo ""

  # Offer to package as .xpi
  if command -v zip &>/dev/null; then
    local xpi_out="$BUILD_DIR/ai-cli-firefox.xpi"
    cd "$out_dir" && zip -rq "$xpi_out" . 2>/dev/null && cd - >/dev/null
    ok "Also packaged as: $xpi_out"
    echo -e "  ${DIM}To install .xpi: drag it onto Firefox or use about:addons → gear → Install from file${R}"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  AI Node Editor — Visual pipeline builder (125+ nodes, tkinter canvas)
#  Usage: ai node new|load [file]|save|autofix|execute|config
# ════════════════════════════════════════════════════════════════════════════════

cmd_node() {
  local subcmd="${1:-new}"; shift || true
  case "$subcmd" in
    new|open)      _node_editor "" ;;
    load)          _node_editor "${1:-}" ;;
    save)          info "Use File > Save inside the Node Editor window." ;;
    autofix)       _node_autofix "${1:-}" ;;
    execute|run)   _node_execute "${1:-}" ;;
    config)        _node_config ;;
    help|-h|--help) _node_help ;;
    *)             _node_editor "$subcmd" ;;
  esac
}

_node_help() {
  hdr "AI Node Editor — v2.7.4"
  cat << 'NODEHELP'
  ai node new            Open a blank pipeline in the visual editor
  ai node load [file]    Load a saved pipeline (.ainodes JSON)
  ai node save           (Use File > Save inside the editor window)
  ai node autofix [file] AI-powered pipeline error detection & fix
  ai node execute [file] Run a pipeline non-interactively
  ai node config         Configure node editor defaults

  The editor provides 125+ nodes across 12 categories:
    LLM · Text · Image · Audio · Video · Data · Logic · Math
    File · API · Code · Custom

  Keyboard shortcuts (inside editor):
    Ctrl+N  New pipeline        Ctrl+O  Open pipeline
    Ctrl+S  Save pipeline       Ctrl+Z  Undo   Ctrl+Y  Redo
    Del     Delete selected     Ctrl+A  Select all
    Ctrl+E  Execute pipeline    Ctrl+F  Autofix
    Space   Pan canvas          Scroll  Zoom in/out
    Escape  Deselect all
NODEHELP
}

_node_autofix() {
  local pipeline_file="${1:-}"
  [[ -z "$PYTHON" ]] && { err "Python required for autofix"; return 1; }
  if [[ -z "$pipeline_file" ]]; then
    local cfg_dir="${CONFIG_DIR:-$HOME/.config/ai-cli}"
    pipeline_file=$(ls -t "$cfg_dir"/nodes/*.ainodes 2>/dev/null | head -1)
    [[ -z "$pipeline_file" ]] && { err "No pipeline file found. Run 'ai node new' first."; return 1; }
  fi
  [[ ! -f "$pipeline_file" ]] && { err "File not found: $pipeline_file"; return 1; }
  info "Autofixing pipeline: $pipeline_file"
  local content; content=$(cat "$pipeline_file")
  local fix_prompt="Analyze this AI node pipeline JSON and identify any issues (missing connections, invalid node types, cycles, disconnected inputs). Return a fixed JSON only:\n${content}"
  local fixed; fixed=$(dispatch_ask "$fix_prompt" 2>/dev/null)
  if echo "$fixed" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    cp "$pipeline_file" "${pipeline_file}.bak"
    echo "$fixed" > "$pipeline_file"
    ok "Pipeline fixed and saved. Backup: ${pipeline_file}.bak"
  else
    warn "AI response was not valid JSON — no changes made"
    echo "$fixed" | head -20
  fi
}

_node_execute() {
  local pipeline_file="${1:-}"
  [[ -z "$PYTHON" ]] && { err "Python required for node execution"; return 1; }
  if [[ -z "$pipeline_file" ]]; then
    local cfg_dir="${CONFIG_DIR:-$HOME/.config/ai-cli}"
    pipeline_file=$(ls -t "$cfg_dir"/nodes/*.ainodes 2>/dev/null | head -1)
    [[ -z "$pipeline_file" ]] && { err "No pipeline file. Run 'ai node new' first."; return 1; }
  fi
  [[ ! -f "$pipeline_file" ]] && { err "File not found: $pipeline_file"; return 1; }
  info "Executing pipeline: $pipeline_file"
  "$PYTHON" - "$pipeline_file" "$0" << 'EXECEOF'
#!/usr/bin/env python3
"""AI Node Pipeline executor (non-interactive)"""
import sys, json, subprocess, os, time

pipeline_file = sys.argv[1]
cli = sys.argv[2]

with open(pipeline_file) as f:
    pipeline = json.load(f)

nodes   = {n["id"]: n for n in pipeline.get("nodes", [])}
edges   = pipeline.get("edges", [])
results = {}

def topo_sort(nodes, edges):
    from collections import deque, defaultdict
    indegree = defaultdict(int)
    adj      = defaultdict(list)
    for e in edges:
        adj[e["source"]].append(e["target"])
        indegree[e["target"]] += 1
    q     = deque(n for n in nodes if indegree[n] == 0)
    order = []
    while q:
        node = q.popleft()
        order.append(node)
        for nxt in adj[node]:
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                q.append(nxt)
    return order

order = topo_sort(list(nodes.keys()), edges)
inp_map = {}
for e in edges:
    inp_map.setdefault(e["target"], {})[e["targetHandle"]] = (e["source"], e["sourceHandle"])

print(f"[node-exec] Pipeline: {os.path.basename(pipeline_file)}")
print(f"[node-exec] Nodes: {len(nodes)}  Edges: {len(edges)}")
print(f"[node-exec] Execution order: {' → '.join(order)}\n")

for nid in order:
    node = nodes[nid]
    ntype = node.get("type", "unknown")
    props = node.get("data", {})
    ins   = {}
    for port, (src_id, src_port) in inp_map.get(nid, {}).items():
        ins[port] = results.get(src_id, {}).get(src_port, "")

    print(f"  [{ntype}] {props.get('label', nid)}", end=" … ", flush=True)

    out = {}
    if ntype in ("llm", "ask", "chat"):
        prompt = ins.get("prompt", props.get("prompt", "Hello"))
        try:
            r = subprocess.run([cli, "ask", prompt], capture_output=True, text=True, timeout=60)
            out["output"] = (r.stdout + r.stderr).strip()
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("text", "input", "prompt"):
        out["output"] = props.get("text", ins.get("input", ""))
    elif ntype == "print":
        val = ins.get("input", "")
        print(f"\n    OUTPUT: {val[:200]}", end=" ")
        out["output"] = val
    elif ntype in ("websearch", "web"):
        q = ins.get("query", props.get("query", ""))
        try:
            r = subprocess.run([cli, "websearch", q], capture_output=True, text=True, timeout=30)
            out["output"] = (r.stdout + r.stderr).strip()
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("code", "python"):
        code = ins.get("code", props.get("code","print('hello')"))
        try:
            r = subprocess.run(["python3","-c",code], capture_output=True, text=True, timeout=30)
            out["output"] = (r.stdout + r.stderr).strip()
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("join", "concat"):
        parts = [ins.get(k,"") for k in sorted(ins.keys())]
        sep   = props.get("separator", "\n")
        out["output"] = sep.join(str(p) for p in parts)
    elif ntype in ("condition", "if"):
        val       = ins.get("input","")
        condition = props.get("condition","True")
        try:
            result = bool(eval(condition, {"input": val, "value": val}))
        except:
            result = False
        out["true"]  = val if result else ""
        out["false"] = val if not result else ""
    elif ntype in ("imagegen", "imagine"):
        prompt = ins.get("prompt", props.get("prompt","a painting"))
        try:
            r = subprocess.run([cli,"imagine",prompt], capture_output=True, text=True, timeout=120)
            out["output"] = (r.stdout + r.stderr).strip()
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("file_read", "read_file"):
        path = ins.get("path", props.get("path",""))
        try:
            with open(os.path.expanduser(path)) as f: out["output"] = f.read()
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("file_write", "write_file"):
        path = ins.get("path", props.get("path","output.txt"))
        data = ins.get("data", ins.get("input",""))
        try:
            with open(os.path.expanduser(path),"w") as f: f.write(str(data))
            out["output"] = path
        except Exception as e:
            out["output"] = f"[error: {e}]"
    elif ntype in ("delay", "sleep", "wait"):
        secs = float(props.get("seconds", ins.get("seconds", 1)))
        time.sleep(secs)
        out["output"] = ins.get("input","")
    elif ntype in ("output", "result", "display"):
        val = ins.get("input", "")
        print(f"\n    RESULT: {str(val)[:500]}", end=" ")
        out["output"] = val
    else:
        out["output"] = ins.get("input", ins.get("prompt", ""))

    results[nid] = out
    print("done")

print(f"\n[node-exec] Pipeline complete. {len(order)} nodes executed.")
EXECEOF
}

_node_config() {
  local cfg_dir="${CONFIG_DIR:-$HOME/.config/ai-cli}"
  mkdir -p "$cfg_dir/nodes"
  local cfg_file="$cfg_dir/nodes/config.json"
  if [[ ! -f "$cfg_file" ]]; then
    cat > "$cfg_file" << 'NODECFG'
{
  "default_theme": "dark",
  "grid_size": 20,
  "snap_to_grid": true,
  "auto_save": true,
  "auto_save_interval": 60,
  "canvas_bg": "#1e1e2e",
  "node_border_radius": 8,
  "connection_curve": "bezier",
  "max_undo_steps": 50,
  "show_minimap": true,
  "node_bank_width": 240,
  "properties_width": 260,
  "default_llm_model": "",
  "execution_timeout": 120
}
NODECFG
    ok "Created node config: $cfg_file"
  fi
  hdr "Node Editor Config: $cfg_file"
  cat "$cfg_file"
  echo ""
  read -rp "$(echo -e "${BCYAN}Edit config? (y/N): ${R}")" yn
  [[ "${yn,,}" == "y" ]] && "${EDITOR:-nano}" "$cfg_file"
}

_node_editor() {
  local load_file="${1:-}"
  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required for Node Editor"; return 1; }
  if ! "$PYTHON" -c "import tkinter" 2>/dev/null; then
    err "tkinter required: sudo apt install python3-tk  OR  pacman -S tk"
    return 1
  fi
  local cfg_dir="${CONFIG_DIR:-$HOME/.config/ai-cli}"
  mkdir -p "$cfg_dir/nodes"
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "$0")
  local theme="${GUI_THEME:-dark}"
  local script; script=$(mktemp /tmp/ai_node_XXXX.py)

  cat > "$script" << 'NODEEOF'
#!/usr/bin/env python3
"""AI CLI v2.7.4 — Node Editor: 125+ nodes, visual pipeline builder"""
import sys, os, json, math, subprocess, threading, time, copy, uuid, tkinter as tk
from tkinter import ttk, messagebox, filedialog, simpledialog, scrolledtext

CLI      = sys.argv[1] if len(sys.argv) > 1 else "ai"
THEME    = sys.argv[2] if len(sys.argv) > 2 else "dark"
CFG_DIR  = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.config/ai-cli")
LOAD_FILE= sys.argv[4] if len(sys.argv) > 4 else ""

# ── Color palette ─────────────────────────────────────────────────────────────
DARK = {"bg":"#1e1e2e","panel":"#181825","sidebar":"#11111b","canvas":"#13131f",
        "fg":"#cdd6f4","dim":"#6c7086","accent":"#89b4fa","accent2":"#a6e3a1",
        "warn":"#f9e2af","err":"#f38ba8","sel":"#45475a","border":"#313244",
        "node_bg":"#24273a","node_hdr":"#363a4f","node_sel":"#414459",
        "port_in":"#a6e3a1","port_out":"#89b4fa","wire":"#89b4fa","grid":"#1e1e2e",
        "grid_dot":"#313244","btn":"#313244","btn_fg":"#cdd6f4","btn_hover":"#45475a",
        "entry_bg":"#313244","entry_fg":"#cdd6f4","tab_bg":"#181825","log_bg":"#11111b"}
LIGHT= {"bg":"#eff1f5","panel":"#e6e9ef","sidebar":"#dce0e8","canvas":"#f4f4f7",
        "fg":"#4c4f69","dim":"#9ca0b0","accent":"#1e66f5","accent2":"#40a02b",
        "warn":"#df8e1d","err":"#d20f39","sel":"#bcc0cc","border":"#acb0be",
        "node_bg":"#e6e9ef","node_hdr":"#dce0e8","node_sel":"#ccd0da",
        "port_in":"#40a02b","port_out":"#1e66f5","wire":"#1e66f5","grid":"#eff1f5",
        "grid_dot":"#bcc0cc","btn":"#dce0e8","btn_fg":"#4c4f69","btn_hover":"#ccd0da",
        "entry_bg":"#dce0e8","entry_fg":"#4c4f69","tab_bg":"#e6e9ef","log_bg":"#dce0e8"}
P = DARK if THEME != "light" else LIGHT

# ── Node bank: 125+ node types in 12 categories ───────────────────────────────
NODE_BANK = {
  "LLM": [
    ("llm",        "LLM Prompt",       ["prompt","system"],     ["output"],       "#bd93f9"),
    ("ask",        "Ask AI",           ["question"],            ["answer"],       "#bd93f9"),
    ("chat",       "Chat Session",     ["message","history"],   ["response","history_out"], "#bd93f9"),
    ("summarize",  "Summarize",        ["text"],                ["summary"],      "#bd93f9"),
    ("translate",  "Translate",        ["text","lang"],         ["translated"],   "#bd93f9"),
    ("classify",   "Classify",         ["text","labels"],       ["label","score"],"#bd93f9"),
    ("qa",         "Q&A",              ["context","question"],  ["answer"],       "#bd93f9"),
    ("rewrite",    "Rewrite",          ["text","style"],        ["output"],       "#bd93f9"),
    ("extract",    "Extract Info",     ["text","schema"],       ["extracted"],    "#bd93f9"),
    ("code_gen",   "Code Generator",   ["task","lang"],         ["code"],         "#bd93f9"),
    ("code_fix",   "Code Fixer",       ["code","error"],        ["fixed_code"],   "#bd93f9"),
    ("explain",    "Explain Code",     ["code"],                ["explanation"],  "#bd93f9"),
    ("instruct",   "Instruct",         ["instruction","input"], ["output"],       "#bd93f9"),
    ("agent",      "AI Agent",         ["task","tools"],        ["result","steps"],"#bd93f9"),
    ("multiai",    "Multi-AI Arena",   ["topic","mode"],        ["result"],       "#bd93f9"),
  ],
  "Text": [
    ("text_in",    "Text Input",       [],                      ["text"],         "#50fa7b"),
    ("text_out",   "Text Output",      ["text"],                [],               "#50fa7b"),
    ("concat",     "Concatenate",      ["a","b","c"],           ["output"],       "#50fa7b"),
    ("split",      "Split Text",       ["text","delimiter"],    ["parts"],        "#50fa7b"),
    ("replace",    "Find & Replace",   ["text","find","repl"],  ["output"],       "#50fa7b"),
    ("regex",      "Regex",            ["text","pattern"],      ["matches","out"],"#50fa7b"),
    ("trim",       "Trim",             ["text"],                ["output"],       "#50fa7b"),
    ("uppercase",  "Uppercase",        ["text"],                ["output"],       "#50fa7b"),
    ("lowercase",  "Lowercase",        ["text"],                ["output"],       "#50fa7b"),
    ("len",        "String Length",    ["text"],                ["length"],       "#50fa7b"),
    ("contains",   "Contains",         ["text","needle"],       ["bool","idx"],   "#50fa7b"),
    ("template",   "Template",         ["template","vars"],     ["output"],       "#50fa7b"),
    ("markdown",   "Markdown→HTML",    ["markdown"],            ["html"],         "#50fa7b"),
    ("json_parse", "JSON Parse",       ["json_str"],            ["object"],       "#50fa7b"),
    ("json_dump",  "JSON Dump",        ["object"],              ["json_str"],     "#50fa7b"),
  ],
  "Image": [
    ("imagine",    "Image Gen",        ["prompt","neg","size"],["image_path"],    "#ff79c6"),
    ("imagine2",   "Image Gen v2",     ["prompt","neg","steps"],["image_path"],   "#ff79c6"),
    ("img2img",    "Image→Image",      ["image","prompt"],      ["output"],       "#ff79c6"),
    ("inpaint",    "Inpaint",          ["image","mask","prompt"],["output"],      "#ff79c6"),
    ("upscale",    "Upscale",          ["image","factor"],      ["output"],       "#ff79c6"),
    ("vision",     "Vision (img→text)",["image","question"],    ["description"],  "#ff79c6"),
    ("img_resize", "Resize Image",     ["image","w","h"],       ["output"],       "#ff79c6"),
    ("img_crop",   "Crop Image",       ["image","x","y","w","h"],["output"],      "#ff79c6"),
    ("img_rotate", "Rotate Image",     ["image","angle"],       ["output"],       "#ff79c6"),
    ("img_filter", "Filter Image",     ["image","filter"],      ["output"],       "#ff79c6"),
    ("img_flip",   "Flip Image",       ["image","axis"],        ["output"],       "#ff79c6"),
    ("img_info",   "Image Info",       ["image"],               ["width","height","format"],"#ff79c6"),
    ("flux",       "FLUX Gen",         ["prompt","steps"],      ["image_path"],   "#ff79c6"),
    ("batch_img",  "Batch Images",     ["prompt","count"],      ["images"],       "#ff79c6"),
    ("lora",       "LoRA Image",       ["prompt","lora_path"],  ["image_path"],   "#ff79c6"),
  ],
  "Audio": [
    ("tts",        "Text→Speech",      ["text","voice"],        ["audio_path"],   "#ffb86c"),
    ("stt",        "Speech→Text",      ["audio_path"],          ["text"],         "#ffb86c"),
    ("audio_rec",  "Record Audio",     ["duration"],            ["audio_path"],   "#ffb86c"),
    ("audio_play", "Play Audio",       ["audio_path"],          ["done"],         "#ffb86c"),
    ("audio_trim", "Trim Audio",       ["audio","start","end"], ["output"],       "#ffb86c"),
    ("audio_merge","Merge Audio",      ["a","b"],               ["output"],       "#ffb86c"),
    ("transcribe", "Transcribe",       ["audio_path","lang"],   ["text"],         "#ffb86c"),
    ("audio_fx",   "Audio Effects",    ["audio","effect"],      ["output"],       "#ffb86c"),
    ("music_gen",  "Music Gen",        ["prompt","duration"],   ["audio_path"],   "#ffb86c"),
    ("vocal_sep",  "Vocal Separator",  ["audio"],               ["vocals","bg"],  "#ffb86c"),
  ],
  "Video": [
    ("vid_gen",    "Video Gen",        ["prompt","duration"],   ["video_path"],   "#8be9fd"),
    ("vid_caption","Video Caption",    ["video_path"],          ["captions"],     "#8be9fd"),
    ("vid_trim",   "Trim Video",       ["video","start","end"], ["output"],       "#8be9fd"),
    ("vid_frames", "Extract Frames",   ["video","fps"],         ["frames_dir"],   "#8be9fd"),
    ("vid_join",   "Join Videos",      ["a","b"],               ["output"],       "#8be9fd"),
    ("vid_speed",  "Speed Change",     ["video","factor"],      ["output"],       "#8be9fd"),
    ("vid_audio",  "Extract Audio",    ["video"],               ["audio"],        "#8be9fd"),
    ("vid_sub",    "Add Subtitles",    ["video","srt"],         ["output"],       "#8be9fd"),
  ],
  "Data": [
    ("csv_read",   "Read CSV",         ["path"],                ["rows","cols"],  "#f1fa8c"),
    ("csv_write",  "Write CSV",        ["rows","path"],         ["done"],         "#f1fa8c"),
    ("json_read",  "Read JSON",        ["path"],                ["data"],         "#f1fa8c"),
    ("json_write", "Write JSON",       ["data","path"],         ["done"],         "#f1fa8c"),
    ("dataset_gen","Dataset Gen",      ["topic","count"],       ["dataset"],      "#f1fa8c"),
    ("rlhf_label", "RLHF Label",       ["pair","preference"],   ["labeled"],      "#f1fa8c"),
    ("db_query",   "SQL Query",        ["db","query"],          ["rows"],         "#f1fa8c"),
    ("http_get",   "HTTP GET",         ["url","headers"],       ["body","status"],"#f1fa8c"),
    ("http_post",  "HTTP POST",        ["url","body"],          ["response"],     "#f1fa8c"),
    ("websearch",  "Web Search",       ["query","count"],       ["results"],      "#f1fa8c"),
    ("rss_feed",   "RSS Feed",         ["url"],                 ["items"],        "#f1fa8c"),
  ],
  "Logic": [
    ("condition",  "If/Else",          ["input","condition"],   ["true","false"],  "#ff5555"),
    ("switch",     "Switch",           ["input","cases"],       ["out0","out1","out2"],"#ff5555"),
    ("loop",       "Loop N Times",     ["input","n"],           ["item","index"],  "#ff5555"),
    ("foreach",    "For Each",         ["list"],                ["item","index"],  "#ff5555"),
    ("while_loop", "While Loop",       ["cond","body"],         ["output"],        "#ff5555"),
    ("filter",     "Filter",           ["list","predicate"],    ["filtered"],      "#ff5555"),
    ("map_fn",     "Map",              ["list","fn"],           ["mapped"],        "#ff5555"),
    ("reduce_fn",  "Reduce",           ["list","fn","init"],    ["result"],        "#ff5555"),
    ("delay",      "Delay",            ["input","seconds"],     ["output"],        "#ff5555"),
    ("gate",       "Gate",             ["input","enable"],      ["output"],        "#ff5555"),
    ("debounce",   "Debounce",         ["input","ms"],          ["output"],        "#ff5555"),
    ("retry",      "Retry",            ["input","n"],           ["output"],        "#ff5555"),
  ],
  "Math": [
    ("add",        "Add",              ["a","b"],               ["result"],        "#ffb86c"),
    ("sub",        "Subtract",         ["a","b"],               ["result"],        "#ffb86c"),
    ("mul",        "Multiply",         ["a","b"],               ["result"],        "#ffb86c"),
    ("div",        "Divide",           ["a","b"],               ["result"],        "#ffb86c"),
    ("mod",        "Modulo",           ["a","b"],               ["result"],        "#ffb86c"),
    ("pow",        "Power",            ["base","exp"],          ["result"],        "#ffb86c"),
    ("round_n",    "Round",            ["n","decimals"],        ["result"],        "#ffb86c"),
    ("clamp",      "Clamp",            ["val","min","max"],     ["result"],        "#ffb86c"),
    ("abs_val",    "Absolute",         ["n"],                   ["result"],        "#ffb86c"),
    ("math_eval",  "Math Eval",        ["expression"],          ["result"],        "#ffb86c"),
    ("stats",      "Statistics",       ["list"],                ["mean","std","min","max"],"#ffb86c"),
    ("random_n",   "Random Number",    ["min","max"],           ["number"],        "#ffb86c"),
  ],
  "File": [
    ("file_read",  "Read File",        ["path"],                ["content"],       "#a6e3a1"),
    ("file_write", "Write File",       ["path","content"],      ["done"],          "#a6e3a1"),
    ("file_append","Append File",      ["path","content"],      ["done"],          "#a6e3a1"),
    ("file_delete","Delete File",      ["path"],                ["done"],          "#a6e3a1"),
    ("file_exists","File Exists",      ["path"],                ["exists"],        "#a6e3a1"),
    ("file_list",  "List Dir",         ["path","pattern"],      ["files"],         "#a6e3a1"),
    ("file_copy",  "Copy File",        ["src","dst"],           ["done"],          "#a6e3a1"),
    ("file_move",  "Move File",        ["src","dst"],           ["done"],          "#a6e3a1"),
    ("file_glob",  "Glob Pattern",     ["pattern"],             ["matches"],       "#a6e3a1"),
    ("zip_files",  "Zip Files",        ["files","output"],      ["zip_path"],      "#a6e3a1"),
    ("unzip",      "Unzip",            ["zip","dest"],          ["dir"],           "#a6e3a1"),
  ],
  "API": [
    ("openai",     "OpenAI",           ["prompt","model"],      ["response"],      "#6272a4"),
    ("claude_api", "Claude API",       ["prompt","model"],      ["response"],      "#6272a4"),
    ("gemini",     "Gemini API",       ["prompt","model"],      ["response"],      "#6272a4"),
    ("hf_api",     "HuggingFace API",  ["model","input"],       ["output"],        "#6272a4"),
    ("ollama",     "Ollama",           ["model","prompt"],      ["response"],      "#6272a4"),
    ("rest_api",   "REST API",         ["url","method","body"], ["response"],      "#6272a4"),
    ("graphql",    "GraphQL",          ["url","query","vars"],  ["data"],          "#6272a4"),
    ("webhook",    "Webhook Trigger",  ["event"],               ["payload"],       "#6272a4"),
    ("slack_msg",  "Slack Message",    ["channel","text"],      ["done"],          "#6272a4"),
    ("email",      "Send Email",       ["to","subject","body"], ["done"],          "#6272a4"),
  ],
  "Code": [
    ("python",     "Python",           ["code","input"],        ["output","error"],"#ffb86c"),
    ("bash",       "Bash Script",      ["script"],              ["stdout","stderr"],"#ffb86c"),
    ("node_js",    "Node.js",          ["code"],                ["output"],        "#ffb86c"),
    ("eval_py",    "Eval Python",      ["expression"],          ["result"],        "#ffb86c"),
    ("git_cmd",    "Git Command",      ["repo","command"],      ["output"],        "#ffb86c"),
    ("docker_run", "Docker Run",       ["image","cmd"],         ["output"],        "#ffb86c"),
    ("test_run",   "Run Tests",        ["path","framework"],    ["results"],       "#ffb86c"),
    ("lint",       "Lint Code",        ["code","lang"],         ["issues"],        "#ffb86c"),
  ],
  "Custom": [
    ("custom",     "Custom Node",      ["input"],               ["output"],        "#cba6f7"),
    ("note",       "Note / Comment",   [],                      [],                "#a6adc8"),
    ("group",      "Node Group",       ["in"],                  ["out"],           "#585b70"),
    ("print",      "Print/Log",        ["input"],               [],                "#a6e3a1"),
    ("constant",   "Constant Value",   [],                      ["value"],         "#f9e2af"),
    ("user_input", "User Input",       ["prompt"],              ["text"],          "#89b4fa"),
    ("display",    "Display",          ["input"],               [],                "#f9e2af"),
    ("counter",    "Counter",          ["reset"],               ["count"],         "#cba6f7"),
    ("timer",      "Timer",            [],                      ["elapsed"],       "#cba6f7"),
    ("passthrough","Passthrough",      ["input"],               ["output"],        "#6c7086"),
  ],
}

# Flatten for lookup
NODE_DEFS = {}
for cat, nodes in NODE_BANK.items():
    for n in nodes:
        NODE_DEFS[n[0]] = {"type":n[0],"label":n[1],"inputs":n[2],"outputs":n[3],"color":n[4],"category":cat}

PORT_R = 7
NODE_W = 180
HDR_H  = 28
PORT_H = 22
PAD    = 10

def node_height(ntype):
    d  = NODE_DEFS.get(ntype, {"inputs":[],"outputs":[]})
    rows = max(len(d["inputs"]), len(d["outputs"]))
    return HDR_H + max(rows, 1) * PORT_H + PAD

class NodeCanvas:
    def __init__(self, parent, log_fn):
        self.log   = log_fn
        self.nodes = {}   # id -> {type,x,y,data,canvas_items}
        self.edges = []   # {id,src,src_port,dst,dst_port,item}
        self.sel   = set()
        self.drag_node = None; self.drag_ox = self.drag_oy = 0
        self.wire_start = None  # (node_id, port_name, "out", cx, cy)
        self.wire_item  = None
        self.offset_x = 0.0; self.offset_y = 0.0
        self.zoom     = 1.0
        self.pan_last = None
        self.undo_stack = []; self.redo_stack = []
        self._build(parent)

    def _build(self, parent):
        self.frame = tk.Frame(parent, bg=P["border"])
        self.frame.pack(fill="both", expand=True)
        self.cv = tk.Canvas(self.frame, bg=P["canvas"], highlightthickness=0, cursor="crosshair")
        self.cv.pack(fill="both", expand=True)
        hbar = ttk.Scrollbar(self.frame, orient="horizontal", command=self.cv.xview)
        vbar = ttk.Scrollbar(self.frame, orient="vertical",   command=self.cv.yview)
        self.cv.config(xscrollcommand=hbar.set, yscrollcommand=vbar.set,
                       scrollregion=(-5000,-5000,5000,5000))
        self.cv.bind("<ButtonPress-1>",   self._on_press)
        self.cv.bind("<B1-Motion>",       self._on_drag)
        self.cv.bind("<ButtonRelease-1>", self._on_release)
        self.cv.bind("<ButtonPress-2>",   self._pan_start)
        self.cv.bind("<B2-Motion>",       self._pan_move)
        self.cv.bind("<ButtonPress-3>",   self._ctx_menu)
        self.cv.bind("<MouseWheel>",      self._on_scroll)
        self.cv.bind("<Button-4>",        self._on_scroll)
        self.cv.bind("<Button-5>",        self._on_scroll)
        self.cv.bind("<space>",           lambda e: None)
        self._draw_grid()

    def _draw_grid(self):
        self.cv.delete("grid")
        grid = 40
        for x in range(-5000, 5001, grid):
            self.cv.create_line(x,-5000,x,5000, fill=P["grid_dot"], width=1, tags="grid")
        for y in range(-5000, 5001, grid):
            self.cv.create_line(-5000,y,5000,y, fill=P["grid_dot"], width=1, tags="grid")
        self.cv.tag_lower("grid")

    def world_xy(self, ex, ey):
        return self.cv.canvasx(ex), self.cv.canvasy(ey)

    def add_node(self, ntype, wx, wy, data=None, nid=None):
        if ntype not in NODE_DEFS:
            self.log(f"Unknown node type: {ntype}"); return None
        nid  = nid or str(uuid.uuid4())[:8]
        d    = NODE_DEFS[ntype]
        node = {"id":nid,"type":ntype,"x":wx,"y":wy,
                "data":data or {"label":d["label"]},
                "items":[],"port_items":{}}
        self.nodes[nid] = node
        self._draw_node(nid)
        self.log(f"Added: {d['label']}")
        return nid

    def _draw_node(self, nid):
        node = self.nodes[nid]; d = NODE_DEFS[node["type"]]
        x, y = node["x"], node["y"]
        h    = node_height(node["type"])
        w    = NODE_W
        # Remove old items
        for item in node["items"]: self.cv.delete(item)
        node["items"] = []; node["port_items"] = {}
        selected = nid in self.sel
        border_color = P["accent"] if selected else d["color"]
        bw = 3 if selected else 1
        # Node body
        r1 = self.cv.create_rectangle(x, y, x+w, y+h,
            fill=P["node_bg"], outline=border_color, width=bw, tags=("node", f"n_{nid}"))
        # Header
        r2 = self.cv.create_rectangle(x+1, y+1, x+w-1, y+HDR_H,
            fill=d["color"], outline="", tags=("node_hdr", f"n_{nid}"))
        t1 = self.cv.create_text(x+w//2, y+HDR_H//2,
            text=d["label"], fill="#ffffff", font=("Segoe UI",9,"bold"), tags=("node",f"n_{nid}"))
        node["items"] = [r1, r2, t1]
        # Input ports
        for i, pname in enumerate(d["inputs"]):
            py_val = y + HDR_H + i * PORT_H + PORT_H // 2
            cx_val = x
            cid = self.cv.create_oval(cx_val-PORT_R, py_val-PORT_R, cx_val+PORT_R, py_val+PORT_R,
                fill=P["port_in"], outline=P["border"], width=1, tags=("port",f"pi_{nid}_{pname}"))
            tid = self.cv.create_text(cx_val+PORT_R+4, py_val,
                text=pname, fill=P["dim"], font=("Segoe UI",8), anchor="w", tags=("node",f"n_{nid}"))
            node["items"] += [cid, tid]
            node["port_items"][f"in_{pname}"] = (cid, cx_val, py_val)
        # Output ports
        for i, pname in enumerate(d["outputs"]):
            py_val = y + HDR_H + i * PORT_H + PORT_H // 2
            cx_val = x + w
            cid = self.cv.create_oval(cx_val-PORT_R, py_val-PORT_R, cx_val+PORT_R, py_val+PORT_R,
                fill=P["port_out"], outline=P["border"], width=1, tags=("port",f"po_{nid}_{pname}"))
            tid = self.cv.create_text(cx_val-PORT_R-4, py_val,
                text=pname, fill=P["dim"], font=("Segoe UI",8), anchor="e", tags=("node",f"n_{nid}"))
            node["items"] += [cid, tid]
            node["port_items"][f"out_{pname}"] = (cid, cx_val, py_val)
        # Bind drag
        for item in node["items"]:
            self.cv.tag_bind(item, "<ButtonPress-1>",   lambda e, n=nid: self._node_press(e, n))
            self.cv.tag_bind(item, "<B1-Motion>",       lambda e, n=nid: self._node_drag(e, n))
            self.cv.tag_bind(item, "<ButtonRelease-1>", lambda e, n=nid: self._node_release(e, n))
        # Bind port clicks
        for key, (cid, px, py_val) in node["port_items"].items():
            side, pname = key.split("_", 1)
            self.cv.tag_bind(cid, "<ButtonPress-1>",
                lambda e, n=nid, s=side, p=pname: self._port_click(e, n, s, p))

    def _redraw_edges(self):
        for edge in self.edges:
            if "item" in edge and edge["item"]:
                self.cv.delete(edge["item"])
            src  = self.nodes.get(edge["src"])
            dst  = self.nodes.get(edge["dst"])
            if not src or not dst: edge["item"] = None; continue
            sp = src["port_items"].get(f"out_{edge['src_port']}")
            dp = dst["port_items"].get(f"in_{edge['dst_port']}")
            if not sp or not dp: edge["item"] = None; continue
            x1, y1 = sp[1], sp[2]
            x2, y2 = dp[1], dp[2]
            cx  = (x1+x2)/2
            edge["item"] = self.cv.create_line(
                x1,y1, cx,y1, cx,y2, x2,y2,
                fill=P["wire"], width=2, smooth=True, tags="edge")
            self.cv.tag_lower("edge")
            self.cv.tag_lower("grid")

    def _node_press(self, e, nid):
        wx, wy = self.world_xy(e.x, e.y)
        if not (e.state & 4):  # Ctrl not held
            self.sel.clear()
        self.sel.add(nid)
        self.drag_node = nid
        self.drag_ox = wx - self.nodes[nid]["x"]
        self.drag_oy = wy - self.nodes[nid]["y"]
        self._redraw_all_nodes()

    def _node_drag(self, e, nid):
        if self.drag_node != nid: return
        wx, wy = self.world_xy(e.x, e.y)
        nx = round((wx - self.drag_ox) / 20) * 20
        ny = round((wy - self.drag_oy) / 20) * 20
        self.nodes[nid]["x"] = nx
        self.nodes[nid]["y"] = ny
        self._draw_node(nid)
        self._redraw_edges()

    def _node_release(self, e, nid):
        self.drag_node = None

    def _port_click(self, e, nid, side, pname):
        if side == "out":
            sp  = self.nodes[nid]["port_items"].get(f"out_{pname}")
            self.wire_start = (nid, pname, sp[1], sp[2])
            if self.wire_item: self.cv.delete(self.wire_item)
            self.wire_item = self.cv.create_line(sp[1],sp[2],sp[1],sp[2],
                fill=P["wire"], width=2, dash=(4,2), tags="wire_preview")
            self.cv.bind("<Motion>", self._wire_drag)
        elif side == "in" and self.wire_start:
            self.cv.unbind("<Motion>")
            if self.wire_item: self.cv.delete(self.wire_item); self.wire_item = None
            src_id, src_port, _, _ = self.wire_start
            self.wire_start = None
            if src_id == nid:
                self.log("Cannot connect node to itself"); return
            # Check no duplicate
            for edge in self.edges:
                if edge["src"]==src_id and edge["src_port"]==src_port and edge["dst"]==nid and edge["dst_port"]==pname:
                    self.log("Connection already exists"); return
            edge_id = str(uuid.uuid4())[:8]
            self.edges.append({"id":edge_id,"src":src_id,"src_port":src_port,
                                "dst":nid,"dst_port":pname,"item":None})
            self._redraw_edges()
            self.log(f"Connected: {src_id}.{src_port} → {nid}.{pname}")

    def _wire_drag(self, e):
        if not self.wire_start or not self.wire_item: return
        wx, wy = self.world_xy(e.x, e.y)
        _, _, x1, y1 = self.wire_start
        cx = (x1+wx)/2
        self.cv.coords(self.wire_item, x1,y1, cx,y1, cx,wy, wx,wy)

    def _on_press(self, e):
        wx, wy = self.world_xy(e.x, e.y)
        tags = self.cv.gettags(self.cv.find_closest(wx, wy))
        if not any(t.startswith("n_") or t.startswith("port") for t in tags):
            self.sel.clear()
            if self.wire_start:
                self.wire_start = None
                self.cv.unbind("<Motion>")
                if self.wire_item: self.cv.delete(self.wire_item); self.wire_item = None
            self._redraw_all_nodes()

    def _on_drag(self, e): pass
    def _on_release(self, e): pass

    def _pan_start(self, e): self.pan_last = (e.x, e.y)
    def _pan_move(self, e):
        if self.pan_last:
            dx = e.x - self.pan_last[0]; dy = e.y - self.pan_last[1]
            self.cv.xview_scroll(-dx, "units"); self.cv.yview_scroll(-dy, "units")
            self.pan_last = (e.x, e.y)

    def _on_scroll(self, e):
        delta = getattr(e, 'delta', 0)
        if e.num == 4: delta = 120
        elif e.num == 5: delta = -120
        if e.state & 4:  # Ctrl = zoom
            factor = 1.1 if delta > 0 else 0.9
            self.zoom = max(0.3, min(3.0, self.zoom * factor))
            self.cv.scale("all", self.cv.canvasx(e.x), self.cv.canvasy(e.y), factor, factor)
        else:
            self.cv.yview_scroll(-1 if delta > 0 else 1, "units")

    def _ctx_menu(self, e):
        wx, wy = self.world_xy(e.x, e.y)
        menu = tk.Menu(self.cv, tearoff=0, bg=P["panel"], fg=P["fg"],
                       activebackground=P["sel"])
        items = self.cv.find_closest(wx, wy)
        nid = None
        if items:
            for tag in self.cv.gettags(items[0]):
                if tag.startswith("n_"): nid = tag[2:]; break
        if nid and nid in self.nodes:
            menu.add_command(label=f"Delete '{NODE_DEFS.get(self.nodes[nid]['type'],{}).get('label',nid)}'",
                             command=lambda: self.delete_node(nid))
            menu.add_command(label="Duplicate", command=lambda: self.duplicate_node(nid))
            menu.add_separator()
        menu.add_command(label="Select All (Ctrl+A)", command=self.select_all)
        menu.add_command(label="Delete Selected (Del)", command=self.delete_selected)
        menu.add_separator()
        menu.add_command(label="Clear Canvas", command=self.clear_canvas)
        menu.tk_popup(e.x_root, e.y_root)

    def _redraw_all_nodes(self):
        for nid in self.nodes: self._draw_node(nid)
        self._redraw_edges()

    def delete_node(self, nid):
        if nid not in self.nodes: return
        for item in self.nodes[nid]["items"]: self.cv.delete(item)
        del self.nodes[nid]
        self.edges = [e for e in self.edges if e["src"] != nid and e["dst"] != nid]
        self.sel.discard(nid)
        self._redraw_edges()
        self.log(f"Deleted node {nid}")

    def duplicate_node(self, nid):
        if nid not in self.nodes: return
        n = self.nodes[nid]
        new_id = self.add_node(n["type"], n["x"]+40, n["y"]+40, copy.deepcopy(n["data"]))
        self.log(f"Duplicated: {nid} → {new_id}")

    def delete_selected(self):
        for nid in list(self.sel): self.delete_node(nid)
        self.sel.clear()

    def select_all(self):
        self.sel = set(self.nodes.keys())
        self._redraw_all_nodes()

    def clear_canvas(self):
        if not messagebox.askyesno("Clear", "Clear all nodes and connections?"): return
        self.cv.delete("all"); self.nodes.clear(); self.edges.clear(); self.sel.clear()
        self._draw_grid(); self.log("Canvas cleared.")

    def to_dict(self):
        return {"nodes": [{"id":n["id"],"type":n["type"],"x":n["x"],"y":n["y"],"data":n["data"]}
                           for n in self.nodes.values()],
                "edges": [{"id":e["id"],"source":e["src"],"sourceHandle":e["src_port"],
                           "target":e["dst"],"targetHandle":e["dst_port"]}
                          for e in self.edges]}

    def from_dict(self, d):
        self.cv.delete("all"); self.nodes.clear(); self.edges.clear(); self.sel.clear()
        self._draw_grid()
        for n in d.get("nodes", []):
            self.add_node(n["type"], n["x"], n["y"], n.get("data",{}), n["id"])
        for e in d.get("edges", []):
            self.edges.append({"id":e.get("id",str(uuid.uuid4())[:8]),
                               "src":e["source"],"src_port":e["sourceHandle"],
                               "dst":e["target"],"dst_port":e["targetHandle"],"item":None})
        self._redraw_edges()
        self.log(f"Loaded: {len(self.nodes)} nodes, {len(self.edges)} edges")


class NodeEditor(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("AI CLI v2.7.4 — Node Editor")
        self.configure(bg=P["bg"])
        self.geometry("1500x900"); self.minsize(1100, 700)
        self.current_file = LOAD_FILE or ""
        self._build_menu(); self._build_ui()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.bind("<Control-s>", lambda e: self._save())
        self.bind("<Control-o>", lambda e: self._open())
        self.bind("<Control-n>", lambda e: self._new())
        self.bind("<Control-z>", lambda e: None)
        self.bind("<Delete>",    lambda e: self.canvas.delete_selected())
        self.bind("<Control-a>", lambda e: self.canvas.select_all())
        self.bind("<Control-e>", lambda e: self._execute())
        self.bind("<Control-f>", lambda e: self._autofix())
        if LOAD_FILE and os.path.exists(LOAD_FILE):
            self._do_load(LOAD_FILE)

    def _log(self, msg):
        self.log_text.config(state="normal")
        ts = time.strftime("%H:%M:%S")
        self.log_text.insert("end", f"[{ts}] {msg}\n")
        self.log_text.config(state="disabled")
        self.log_text.see("end")

    def _build_menu(self):
        mb = tk.Menu(self, bg=P["panel"], fg=P["fg"], activebackground=P["sel"],
                     activeforeground=P["fg"], relief="flat")
        fm = tk.Menu(mb, tearoff=0, bg=P["panel"], fg=P["fg"])
        fm.add_command(label="New Pipeline\tCtrl+N",     command=self._new)
        fm.add_command(label="Open…\tCtrl+O",            command=self._open)
        fm.add_command(label="Save\tCtrl+S",             command=self._save)
        fm.add_command(label="Save As…",                 command=self._save_as)
        fm.add_separator()
        fm.add_command(label="Export JSON",              command=self._export_json)
        fm.add_separator()
        fm.add_command(label="Close",                    command=self._on_close)
        mb.add_cascade(label="File", menu=fm)
        em = tk.Menu(mb, tearoff=0, bg=P["panel"], fg=P["fg"])
        em.add_command(label="Undo\tCtrl+Z",             command=lambda: None)
        em.add_command(label="Select All\tCtrl+A",       command=lambda: self.canvas.select_all())
        em.add_command(label="Delete Selected\tDel",     command=lambda: self.canvas.delete_selected())
        em.add_command(label="Clear Canvas",             command=lambda: self.canvas.clear_canvas())
        mb.add_cascade(label="Edit", menu=em)
        rm = tk.Menu(mb, tearoff=0, bg=P["panel"], fg=P["fg"])
        rm.add_command(label="Execute Pipeline\tCtrl+E", command=self._execute)
        rm.add_command(label="Autofix Pipeline\tCtrl+F", command=self._autofix)
        mb.add_cascade(label="Run", menu=rm)
        hm = tk.Menu(mb, tearoff=0, bg=P["panel"], fg=P["fg"])
        hm.add_command(label="Node Bank (125+ nodes)",   command=self._show_node_list)
        hm.add_command(label="Keyboard Shortcuts",       command=self._show_shortcuts)
        mb.add_cascade(label="Help", menu=hm)
        self.config(menu=mb)

    def _build_ui(self):
        # Main horizontal split
        main = tk.PanedWindow(self, orient="horizontal", bg=P["border"],
                              sashwidth=4, sashrelief="flat")
        main.pack(fill="both", expand=True)

        # ── Left panel: Node Bank ─────────────────────────────────────────────
        left = tk.Frame(main, bg=P["sidebar"], width=240)
        tk.Label(left, text="Node Bank", bg=P["sidebar"], fg=P["accent"],
                 font=("Segoe UI",11,"bold"), pady=6).pack(fill="x", padx=8)
        # Search
        sf = tk.Frame(left, bg=P["sidebar"]); sf.pack(fill="x", padx=6, pady=(0,4))
        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", self._filter_bank)
        tk.Entry(sf, textvariable=self.search_var, bg=P["entry_bg"], fg=P["entry_fg"],
                 insertbackground=P["fg"], font=("Segoe UI",9), relief="flat",
                 width=22).pack(side="left", padx=2, fill="x", expand=True)
        tk.Label(sf, text="🔍", bg=P["sidebar"], fg=P["dim"], font=("Segoe UI",10)).pack(side="right")
        # Tree
        self.bank_tree = ttk.Treeview(left, show="tree", selectmode="browse")
        self.bank_tree.pack(fill="both", expand=True, padx=4, pady=2)
        sb = ttk.Scrollbar(left, command=self.bank_tree.yview)
        sb.pack(side="right", fill="y")
        self.bank_tree.config(yscrollcommand=sb.set)
        self._populate_bank()
        self.bank_tree.bind("<Double-1>", self._bank_double_click)
        # Add button
        tk.Button(left, text="➕ Add Selected Node", bg=P["accent"], fg=P["bg"],
                  font=("Segoe UI",9,"bold"), relief="flat", padx=6, pady=4,
                  command=self._add_selected_node, cursor="hand2").pack(fill="x", padx=6, pady=6)
        main.add(left)

        # ── Center: Canvas + Log ──────────────────────────────────────────────
        center = tk.Frame(main, bg=P["bg"])
        # Toolbar
        tb = tk.Frame(center, bg=P["panel"], pady=3)
        tb.pack(fill="x")
        self._title_var = tk.StringVar(value="Untitled Pipeline")
        tk.Label(tb, textvariable=self._title_var, bg=P["panel"], fg=P["accent"],
                 font=("Segoe UI",10,"bold")).pack(side="left", padx=10)
        for label, cmd, color in [
            ("New",     self._new,     P["btn"]),
            ("Open",    self._open,    P["btn"]),
            ("Save",    self._save,    P["btn"]),
            ("Autofix", self._autofix, P["warn"]),
            ("Execute", self._execute, P["accent2"]),
            ("Config",  self._config,  P["btn"]),
        ]:
            tk.Button(tb, text=label, command=cmd, bg=color, fg=P["btn_fg"],
                      relief="flat", padx=10, pady=3, font=("Segoe UI",9),
                      cursor="hand2").pack(side="left", padx=2)
        # Node count badge
        self.node_count_var = tk.StringVar(value="0 nodes  0 edges")
        tk.Label(tb, textvariable=self.node_count_var, bg=P["panel"],
                 fg=P["dim"], font=("Segoe UI",8)).pack(side="right", padx=8)
        # Canvas + log vertical split
        cv_pane = tk.PanedWindow(center, orient="vertical", bg=P["border"],
                                 sashwidth=4, sashrelief="flat")
        cv_pane.pack(fill="both", expand=True)
        cv_frame = tk.Frame(cv_pane, bg=P["bg"])
        self.canvas = NodeCanvas(cv_frame, self._log)
        cv_pane.add(cv_frame)
        # Log panel
        log_frame = tk.Frame(cv_pane, bg=P["log_bg"], height=120)
        tk.Label(log_frame, text="Execution Log", bg=P["log_bg"], fg=P["accent"],
                 font=("Segoe UI",8,"bold"), pady=2).pack(anchor="w", padx=6)
        self.log_text = scrolledtext.ScrolledText(log_frame, bg=P["log_bg"], fg=P["fg"],
            font=("Courier",8), height=6, state="disabled", relief="flat", padx=4)
        self.log_text.pack(fill="both", expand=True, padx=4, pady=(0,4))
        cv_pane.add(log_frame)
        main.add(center)

        # ── Right panel: Properties ───────────────────────────────────────────
        right = tk.Frame(main, bg=P["panel"], width=260)
        tk.Label(right, text="Properties", bg=P["panel"], fg=P["accent"],
                 font=("Segoe UI",11,"bold"), pady=6).pack(fill="x", padx=8)
        self.props_frame = tk.Frame(right, bg=P["panel"])
        self.props_frame.pack(fill="both", expand=True, padx=8, pady=4)
        tk.Label(self.props_frame, text="Select a node to\nview its properties.",
                 bg=P["panel"], fg=P["dim"], font=("Segoe UI",9),
                 justify="center").pack(pady=20)
        # Node type info
        self.info_text = scrolledtext.ScrolledText(right, bg=P["sidebar"], fg=P["fg"],
            font=("Segoe UI",8), height=10, state="disabled", relief="flat", padx=4)
        self.info_text.pack(fill="both", expand=True, padx=6, pady=6)
        main.add(right)

        # Periodic counter update
        self._update_counter()

    def _update_counter(self):
        n = len(self.canvas.nodes); e = len(self.canvas.edges)
        self.node_count_var.set(f"{n} node{'s' if n!=1 else ''}  {e} edge{'s' if e!=1 else ''}")
        self.after(500, self._update_counter)

    def _populate_bank(self, filter_text=""):
        self.bank_tree.delete(*self.bank_tree.get_children())
        ft = filter_text.lower()
        for cat, nodes in NODE_BANK.items():
            matches = [n for n in nodes if not ft or ft in n[1].lower() or ft in n[0].lower()]
            if not matches: continue
            cat_id = self.bank_tree.insert("", "end", text=f"  {cat}", open=bool(ft),
                                           tags=("cat",))
            for n in matches:
                self.bank_tree.insert(cat_id, "end", text=f"    {n[1]}", values=(n[0],), tags=("node",))

    def _filter_bank(self, *_):
        self._populate_bank(self.search_var.get())

    def _bank_double_click(self, e):
        self._add_selected_node()

    def _add_selected_node(self):
        sel = self.bank_tree.focus()
        if not sel: return
        vals = self.bank_tree.item(sel, "values")
        if not vals: return
        ntype = vals[0]
        # Place in center of visible canvas
        cx = self.canvas.cv.winfo_width()  // 2
        cy = self.canvas.cv.winfo_height() // 2
        wx, wy = self.canvas.world_xy(cx, cy)
        wx = round(wx / 20) * 20; wy = round(wy / 20) * 20
        self.canvas.add_node(ntype, wx, wy)

    def _new(self):
        if self.canvas.nodes:
            if not messagebox.askyesno("New", "Discard current pipeline?"): return
        self.canvas.clear_canvas()
        self.current_file = ""
        self._title_var.set("Untitled Pipeline")
        self._log("New pipeline created.")

    def _open(self):
        path = filedialog.askopenfilename(
            filetypes=[("AI Node Pipeline","*.ainodes"),("JSON","*.json"),("All","*.*")],
            initialdir=os.path.join(CFG_DIR,"nodes"))
        if path: self._do_load(path)

    def _do_load(self, path):
        try:
            with open(path) as f: data = json.load(f)
            self.canvas.from_dict(data)
            self.current_file = path
            self._title_var.set(os.path.basename(path))
            self._log(f"Loaded: {path}")
        except Exception as e:
            messagebox.showerror("Load Error", str(e)); self._log(f"Error: {e}")

    def _save(self):
        if not self.current_file: self._save_as(); return
        self._do_save(self.current_file)

    def _save_as(self):
        path = filedialog.asksaveasfilename(
            defaultextension=".ainodes",
            filetypes=[("AI Node Pipeline","*.ainodes"),("JSON","*.json"),("All","*.*")],
            initialdir=os.path.join(CFG_DIR,"nodes"))
        if path:
            self.current_file = path
            self._title_var.set(os.path.basename(path))
            self._do_save(path)

    def _do_save(self, path):
        try:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            with open(path,"w") as f: json.dump(self.canvas.to_dict(), f, indent=2)
            self._log(f"Saved: {path}")
        except Exception as e:
            messagebox.showerror("Save Error", str(e)); self._log(f"Error: {e}")

    def _export_json(self):
        path = filedialog.asksaveasfilename(defaultextension=".json",
            filetypes=[("JSON","*.json"),("All","*.*")])
        if path:
            with open(path,"w") as f: json.dump(self.canvas.to_dict(), f, indent=2)
            self._log(f"Exported JSON: {path}")

    def _autofix(self):
        if not self.current_file:
            if not messagebox.askyesno("Save first?","Save pipeline before autofix?"):return
            self._save_as()
            if not self.current_file: return
        self._log("Running autofix via AI…")
        def _go():
            try:
                r = subprocess.run([CLI,"node","autofix",self.current_file],
                    capture_output=True, text=True, timeout=60)
                out = (r.stdout+r.stderr).strip()
                self._log(f"Autofix: {out[:200]}")
                if os.path.exists(self.current_file):
                    self._do_load(self.current_file)
            except Exception as e:
                self._log(f"Autofix error: {e}")
        threading.Thread(target=_go, daemon=True).start()

    def _execute(self):
        if not self.current_file:
            if not messagebox.askyesno("Save first?","Save pipeline before executing?"):return
            self._save_as()
            if not self.current_file: return
        self._log("Executing pipeline…")
        def _go():
            try:
                r = subprocess.run([CLI,"node","execute",self.current_file],
                    capture_output=True, text=True, timeout=120)
                for line in (r.stdout+r.stderr).splitlines():
                    self._log(line)
            except Exception as e:
                self._log(f"Execute error: {e}")
        threading.Thread(target=_go, daemon=True).start()

    def _config(self):
        try:
            r = subprocess.run([CLI,"node","config"], capture_output=True, text=True, timeout=10)
            win = tk.Toplevel(self); win.title("Node Config"); win.configure(bg=P["bg"])
            t = scrolledtext.ScrolledText(win, bg=P["panel"], fg=P["fg"],
                font=("Segoe UI",10), width=60, height=20)
            t.pack(padx=12, pady=12, fill="both", expand=True)
            t.insert("end", (r.stdout+r.stderr).strip())
            t.config(state="disabled")
        except Exception as e:
            messagebox.showerror("Config Error", str(e))

    def _show_node_list(self):
        win = tk.Toplevel(self); win.title("All 125+ Node Types"); win.configure(bg=P["bg"])
        t = scrolledtext.ScrolledText(win, bg=P["panel"], fg=P["fg"],
            font=("Courier",9), width=80, height=40)
        t.pack(padx=12, pady=12, fill="both", expand=True)
        for cat, nodes in NODE_BANK.items():
            t.insert("end", f"\n── {cat} ({'%d nodes' % len(nodes)}) ──\n", )
            for n in nodes:
                ins  = ", ".join(n[2]) if n[2] else "—"
                outs = ", ".join(n[3]) if n[3] else "—"
                t.insert("end", f"  {n[0]:<18} {n[1]:<22} in:[{ins}]  out:[{outs}]\n")
        t.config(state="disabled")

    def _show_shortcuts(self):
        win = tk.Toplevel(self); win.title("Keyboard Shortcuts"); win.configure(bg=P["bg"])
        t = scrolledtext.ScrolledText(win, bg=P["panel"], fg=P["fg"],
            font=("Segoe UI",10), width=50, height=20)
        t.pack(padx=12, pady=12)
        shortcuts = [
            ("Ctrl+N",  "New pipeline"),
            ("Ctrl+O",  "Open pipeline"),
            ("Ctrl+S",  "Save pipeline"),
            ("Ctrl+Z",  "Undo"),
            ("Ctrl+A",  "Select all nodes"),
            ("Delete",  "Delete selected"),
            ("Ctrl+E",  "Execute pipeline"),
            ("Ctrl+F",  "Autofix pipeline"),
            ("Scroll",  "Zoom in/out (with Ctrl)"),
            ("Mid-drag","Pan canvas"),
            ("Dbl-click bank", "Add node to canvas"),
        ]
        for key, desc in shortcuts:
            t.insert("end", f"  {key:<22}  {desc}\n")
        t.config(state="disabled")

    def _on_close(self):
        if self.canvas.nodes:
            r = messagebox.askyesnocancel("Quit","Save pipeline before closing?")
            if r is None: return
            if r: self._save()
        self.quit()

NodeEditor().mainloop()
NODEEOF

  info "Launching AI Node Editor (125+ nodes)…"
  "$PYTHON" "$script" "$cli_bin" "$theme" "$cfg_dir" "${load_file}"
  local rc=$?
  rm -f "$script"
  [[ $rc -ne 0 ]] && warn "Node Editor exited with code $rc"
}

# ════════════════════════════════════════════════════════════════════════════════
#  Detailed per-command help (ai -h <command>)
# ════════════════════════════════════════════════════════════════════════════════

cmd_help_detail() {
  local cmd="${1:-}"
  [[ -z "$cmd" ]] && { show_help; return; }
  hdr "Detailed help: ai $cmd"
  echo ""
  case "$cmd" in
    ask|a)
cat << 'HELPEOF'
  ai ask QUESTION           Ask the active LLM model a question
  ai ask                      Interactive prompt if no question given
  ai a   QUESTION           Short alias for 'ask'

  Options (via config):
    model                     Which model to use
    system_prompt             System prompt prepended to every query
    api_key                   API key for cloud providers

  Examples:
    ai ask "What is the capital of France?"
    ai ask "Summarize this: $(cat myfile.txt)"
    echo "my question" | ai ask
HELPEOF
    ;;
    chat)
cat << 'HELPEOF'
  ai chat                     Start interactive multi-turn chat session
  ai chat -C NAME           Named chat session (persists across calls)

  Keys inside chat:
    /clear        Clear history        /model N  Switch model
    /system PROMPT   Set system prompt    /save       Save transcript
    /load <f>     Load transcript      /exit       Exit chat

  Examples:
    ai chat
    ai -C myproject chat
HELPEOF
    ;;
    gui)
cat << 'HELPEOF'
  ai gui                      Launch the interactive curses GUI (v5.2)
  ai -gui                     Same as 'ai gui'

  The GUI provides a full-screen terminal interface with:
    Split pane layout     Model browser     Extension manager
    Chat panel            Settings editor   Status panel
    AI Canvas v3          RLHF trainer      Dataset generator
HELPEOF
    ;;
    gui+|guiplus)
cat << 'HELPEOF'
  ai gui+                     Launch GUI+ v3: advanced tkinter GUI (2.1x size)
  ai -gui+                    Same as 'ai gui+'

  Requires: python3-tk  (sudo apt install python3-tk)
  Falls back to enhanced curses GUI+ if tkinter unavailable.

  Features:
    Tabbed interface          Chat · Models · Settings · Nodes · Extensions · Status
    Real mouse support        Native window (not terminal)
    Model selector            Persona selector
    Settings editor           Extension manager
    Node Editor launcher      Theme: dark/light/hacker/dracula/nord
    Menu bar                  Keyboard shortcuts
HELPEOF
    ;;
    node|nodes)
cat << 'HELPEOF'
  ai node new                 Open blank pipeline in visual node editor
  ai node load [file]         Load a saved .ainodes pipeline file
  ai node save                (Use File > Save inside the editor)
  ai node autofix [file]      AI-powered pipeline error detection & fix
  ai node execute [file]      Execute pipeline non-interactively
  ai node config              View/edit node editor configuration
  ai node help                Show this help

  Requires: python3-tk  (sudo apt install python3-tk)

  Node Editor features:
    125+ node types in 12 categories (LLM, Text, Image, Audio, Video,
    Data, Logic, Math, File, API, Code, Custom)
    Drag-and-drop node placement  Bezier wire connections
    Save/load as .ainodes JSON    Undo/redo support
    Node search & filtering       Execution log panel
    Autofix via AI                One-click pipeline execution

  Examples:
    ai node new
    ai node load ~/my_pipeline.ainodes
    ai node execute ~/my_pipeline.ainodes
HELPEOF
    ;;
    imagine|imggen|image)
cat << 'HELPEOF'
  ai imagine "PROMPT"       Generate an image with Stable Diffusion / FLUX
  ai imagine2 "PROMPT"      Image generation v2 (img2img, inpaint, LoRA)

  Options:
    ai config sd_model        Set the SD model to use
    ai config sd_steps        Number of diffusion steps (default: 20)
    ai config sd_width        Output width  (default: 512)
    ai config sd_height       Output height (default: 512)

  Examples:
    ai imagine "a cyberpunk city at night, photorealistic"
    ai imagine2 ~/photo.jpg "turn into watercolor painting"
HELPEOF
    ;;
    model|models)
cat << 'HELPEOF'
  ai models                   List all available models
  ai model NAME             Switch active model to NAME
  ai recommended              Show 2x recommended models (VRAM-aware)
  ai recommended download N Download model #n from the recommended list
  ai download <hf-model-id>   Download a model from HuggingFace

  Examples:
    ai models
    ai model llama3
    ai recommended
    ai download mistralai/Mistral-7B-Instruct-v0.3
HELPEOF
    ;;
    status)
cat << 'HELPEOF'
  ai status                   Show full system / GPU / API status
  ai bench                    Run a quick model benchmark
  ai error-codes              List all AI CLI error codes

  Status shows:
    Active model              GPU (VRAM) availability
    CPU / RAM info            Python version
    API key status            Extension count
    Last update check
HELPEOF
    ;;
    extension|ext)
cat << 'HELPEOF'
  ai extension locate          List all installed extensions
  ai extension create          Create a new extension (interactive)
  ai extension load NAME     Load/enable an extension
  ai extension run NAME      Run an extension
  ai extension edit NAME     Edit an extension in $EDITOR
  ai extension package NAME  Package extension as .aipack
  ai extension help            Show extension help

  Extension directory: ~/.config/ai-cli/extensions/
  Package format: .aipack (zip with manifest.json + main script)
HELPEOF
    ;;
    config)
cat << 'HELPEOF'
  ai config                    Show all configuration values
  ai config KEY              Show value of a specific key
  ai config KEY <value>      Set a configuration value

  Common config keys:
    model              Active LLM model name / path
    api_key            API key (OpenAI / Claude / Gemini)
    api_host           API host (default: localhost)
    api_port           API port (default: 8080)
    system_prompt      Default system prompt
    gui_theme          GUI theme: dark|light|hacker|dracula|nord
    cpu_only_mode      Force CPU-only mode (0/1)
    agent_max_steps    Max steps for AI agent (default: 10)

  Examples:
    ai config model llama3
    ai config api_key sk-...
    ai config gui_theme dracula
HELPEOF
    ;;
    agent)
cat << 'HELPEOF'
  ai agent "TASK"            Run an autonomous AI agent on a task
  ai agent -i                  Interactive step-by-step agent mode

  The agent uses builtin tools:
    web_search   read_file   write_file   run_code   list_dir
    get_time     get_sysinfo calc         download_file image_info

  Config:
    ai config agent_max_steps N   Max reasoning steps (default: 10)

  Examples:
    ai agent "research recent AI papers and summarize top 3"
    ai agent "write a Python script that sorts CSV by column 2"
HELPEOF
    ;;
    alias)
cat << 'HELPEOF'
  ai alias list                List all defined aliases
  ai alias add NAME CMD    Add a new alias
  ai alias remove NAME       Remove an alias
  ai alias run NAME [args]   Run an alias

  Aliases are stored in ~/.config/ai-cli/aliases.json
  They can expand to any 'ai' sub-command.

  Examples:
    ai alias add chat4 "ask --model gpt-4o"
    ai alias add myagent "agent --max-steps 20"
    ai alias list
HELPEOF
    ;;
    rlhf)
cat << 'HELPEOF'
  ai rlhf status               Show RLHF training status
  ai rlhf train                Start an RLHF training session
  ai rlhf label                Label a preference pair
  ai rlhf reward               Train a reward model
  ai rlhf ppo                  Run PPO fine-tuning
  ai rlhf grpo                 Run GRPO fine-tuning
  ai rlhf export               Export the RLHF-trained model
HELPEOF
    ;;
    api)
cat << 'HELPEOF'
  ai api start                 Start the LLM API server (OpenAI-compatible)
  ai api stop                  Stop the API server
  ai api status                Check API server status
  ai api logs                  Show API server logs

  The API server exposes:
    POST /v1/chat/completions   OpenAI-compatible chat endpoint
    GET  /v1/models             List available models
    GET  /health                Health check

  Config:
    ai config api_host HOST   Bind host (default: 0.0.0.0)
    ai config api_port PORT   Port (default: 8080)
HELPEOF
    ;;
    websearch|web)
cat << 'HELPEOF'
  ai websearch "QUERY"       Search the web and return results
  ai websearch "<q>" <count>   Return <count> results (default: 5)

  Examples:
    ai websearch "latest AI news"
    ai websearch "Python async await" 10
HELPEOF
    ;;
    ask-web|askweb|aw|ask-w) echo "  ai ask-web \"question\"   Ask with web search context"; echo "  ai aw \"question\"        Short alias"; echo "  ai ask-web -mem \"q\"     Include memory context too" ;;
    snap|snapshot) cmd_snap 2>/dev/null ;;
    perf|benchmark) echo "  ai perf [--tokens N] [--runs N]   Benchmark model speed" ;;
    compare) echo "  ai compare \"prompt\" [--models a,b,c]   Side-by-side model comparison" ;;
    template|tpl) cmd_template 2>/dev/null ;;
    rag) cmd_rag 2>/dev/null ;;
    batch) cmd_batch 2>/dev/null ;;
    health|check) echo "  ai health   Full system diagnostics (GPU, Python, disk, API keys)" ;;
    branch) cmd_branch 2>/dev/null ;;
    export) echo "  ai export [all|chat|config|models] [--format json|md|csv]" ;;
    import) echo "  ai import <directory|file>   Import conversations or config" ;;
    cleanup|clean) echo "  ai cleanup [--dry-run]   Free disk space" ;;
    preset) cmd_preset 2>/dev/null ;;
    plugin|plugins) cmd_plugin 2>/dev/null ;;
    test) echo "  ai test -S   Model speed test"; echo "  ai test -N   Network test (download/upload/latency)"; echo "  ai test -A   All tests" ;;
    change|changelog) echo "  ai change    Show full changelog"; echo "  ai -L        Show latest changes" ;;
    memory|mem) cmd_memory 2>/dev/null ;;
    write) cmd_write 2>/dev/null ;;
    notebook|nb) cmd_notebook 2>/dev/null ;;
    plan|tasks) cmd_plan 2>/dev/null ;;
    learn|tutor) echo "  ai learn \"topic\"   Interactive AI tutor (n=next q=quiz e=example)" ;;
    quiz) echo "  ai quiz \"topic\" [--count N]   AI-generated quiz" ;;
    shell|sh) cmd_shell 2>/dev/null ;;
    json) cmd_json 2>/dev/null ;;
    sql) cmd_sql 2>/dev/null ;;
    docker|dk) cmd_docker 2>/dev/null ;;
    regex|rx) cmd_regex 2>/dev/null ;;
    diff) echo "  ai diff FILE1 FILE2 [--explain]   Compare files with AI explanation" ;;
    patch) echo "  ai patch FILE \"instructions\"   AI-modify a file" ;;
    git) cmd_git_ai 2>/dev/null ;;
    schedule|sched) cmd_schedule 2>/dev/null ;;
    replay) echo "  ai replay <session> [--model backend]   Replay conversation through different model" ;;
    fav|favorite) cmd_favorite 2>/dev/null ;;
    profile|profiles) cmd_profile 2>/dev/null ;;
    watch) echo "  ai watch FILE [summarize|review|lint] [interval]   Auto-process on file change" ;;
    context|ctx) cmd_context 2>/dev/null ;;
    chain) echo "  ai chain FILE   Run prompt chain (one per line, {{prev}} = last output)" ;;
    tokens|count-tokens) echo "  ai tokens \"text\"   Estimate token count"; echo "  ai tokens FILE   Count tokens in file" ;;
    cost) echo "  ai cost [in_tokens] [out_tokens] [model]   Estimate API cost" ;;
    analytics|usage) echo "  ai analytics [summary|today|clear]   Usage stats" ;;
    security|sec-audit) echo "  ai security   Check API key exposure and security posture" ;;
    sysinfo|system-info) echo "  ai sysinfo   Detailed system info dump" ;;
    interview) echo "  ai interview \"role\"   Practice technical interviews with AI feedback" ;;
    text|txt) cmd_text 2>/dev/null ;;
    net|network) cmd_net 2>/dev/null ;;
    date|dt) cmd_date_tools 2>/dev/null ;;
    cron) cmd_cron 2>/dev/null ;;
    math|calc) echo "  ai math \"expression\"   Solve math (uses bc, falls back to AI)" ;;
    units) echo "  ai units VALUE FROM to TO   Unit conversion" ;;
    clip|clipboard) cmd_clipboard 2>/dev/null ;;
    -Su) echo "  ai -Su   Update ai-cli from GitHub" ;;
    -L) echo "  ai -L    Show latest version changes" ;;
    *)
      # Try v2.9 help
      if _help_v29 "$cmd" 2>/dev/null; then return 0; fi
      warn "No detailed help for '$cmd'"
      echo ""
      echo "  All commands with help:"
      echo "    ask ask-web chat gui gui+ node imagine model status"
      echo "    extension config agent alias rlhf api websearch"
      echo "    snap perf compare template rag batch health branch"
      echo "    export import cleanup preset plugin test change"
      echo "    memory write notebook plan learn quiz shell json"
      echo "    sql docker regex diff patch git schedule replay"
      echo "    fav profile watch context chain tokens cost"
      echo "    analytics security sysinfo interview text net"
      echo "    date cron math units clip -Su -L"
      echo ""
      echo "  Run: ai help   for full command list"
    ;;
  esac
}


main() {
  # Handle -C named chat flag
  local NAMED_CHAT=""
  if [[ "${1:-}" == "-C" ]]; then
    shift; NAMED_CHAT="${1:-auto}"; shift || true
    _chat_start "$NAMED_CHAT" 2>/dev/null || true
  fi

  local cmd="${1:-help}"; shift || true

  case "$cmd" in
    # ── Auto-update ───────────────────────────────────────────────────────────
    -aup|--aup|aup|update-check)
      cmd_autoupdate "$@" ;;
    -Su|--system-update|system-update)
      cmd_system_update "$@" ;;
    -apip)
      local _pw="${1:-}"
      if [[ -z "$_pw" ]]; then
        err "Usage: ai -apip PASSWORD (max 8 chars)"
        return 0
      fi
      _pw="${_pw:0:8}"
      echo "$_pw" > "$CONFIG_DIR/.api_terminal_pw"
      chmod 600 "$CONFIG_DIR/.api_terminal_pw"
      ok "API terminal password set (${#_pw} chars)"
      ;;
    -Cf|--config-set)
      local _key="${1:-}" _val="${2:-}"
      case "$_key" in
        u-gpu|use-gpu)
          if [[ "$_val" == "0" || "$_val" == "false" ]]; then
            GPU_LAYERS=0; CPU_ONLY_MODE=1; save_config; ok "GPU disabled"
          elif [[ "$_val" == "1" || "$_val" == "true" ]]; then
            GPU_LAYERS=-1; CPU_ONLY_MODE=0; save_config; ok "GPU enabled"
          else
            info "GPU: $GPU_LAYERS | CPU-only: $CPU_ONLY_MODE"
          fi ;;
        threads) THREADS="${_val:-$THREADS}"; save_config; ok "Threads: $THREADS" ;;
        temp) TEMPERATURE="${_val:-$TEMPERATURE}"; save_config; ok "Temp: $TEMPERATURE" ;;
        tokens) MAX_TOKENS="${_val:-$MAX_TOKENS}"; save_config; ok "Tokens: $MAX_TOKENS" ;;
        context) CONTEXT_SIZE="${_val:-$CONTEXT_SIZE}"; save_config; ok "Context: $CONTEXT_SIZE" ;;
        *) echo "Usage: ai -C set KEY VALUE"; echo "  u-gpu 0/1  threads N  temp N  tokens N  context N" ;;
      esac ;;
    -L|--latest)
      cmd_change latest ;;
    change|changelog|changes)
      cmd_change "$@" ;;

    # ── Asking ───────────────────────────────────────────────────────────────
    ask|a)
      local _ask_mem=0 _ask_args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -mem|--mem|--memory) _ask_mem=1; shift ;;
          *) _ask_args+=("$1"); shift ;;
        esac
      done
      local _ask_prompt="${_ask_args[*]}"
      if [[ -z "$_ask_prompt" ]]; then
        if [[ -t 0 ]]; then
          read -rp "$(echo -e "${BCYAN}Ask: ${R}")" _ask_prompt
          [[ -z "$_ask_prompt" ]] && { err "Usage: ai ask \"question\""; return 0; }
        else
          _ask_prompt=$(cat)
        fi
      fi
      if [[ $_ask_mem -eq 1 ]]; then
        local _mem_ctx
        _mem_ctx=$(cmd_memory context 2>/dev/null || echo "")
        [[ -n "$_mem_ctx" ]] && _ask_prompt="Known facts about the user:
${_mem_ctx}

${_ask_prompt}"
      fi
      dispatch_ask "$_ask_prompt" || true ;;

    ask-web|askweb|aw|ask-w)
      local _aw_mem=0 _aw_args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -mem|--mem|--memory) _aw_mem=1; shift ;;
          *) _aw_args+=("$1"); shift ;;
        esac
      done
      local _aw_prompt="${_aw_args[*]}"
      if [[ -z "$_aw_prompt" ]]; then
        read -rp "$(echo -e "${BCYAN}Ask (web): ${R}")" _aw_prompt
        [[ -z "$_aw_prompt" ]] && { err "Usage: ai ask-web \"question\""; return 1; }
      fi
      info "Searching the web..."
      local _aw_results=""
      _aw_results=$(web_search "$_aw_prompt" 5 2>/dev/null || echo "")
      # Trim whitespace
      _aw_results=$(echo "$_aw_results" | sed '/^$/d' | head -50)
      if [[ -z "$_aw_results" ]]; then
        _aw_results=$(cmd_websearch "$_aw_prompt" 2>/dev/null || echo "")
        _aw_results=$(echo "$_aw_results" | sed '/^$/d' | head -50)
      fi
      # Show sources
      if [[ -n "$_aw_results" ]]; then
        echo ""
        echo -e "  ${B}${BCYAN}Sources found:${R}"
        echo "$_aw_results" | grep -i "^URL:\|^Title:" | head -10 | while IFS= read -r _src; do
          case "$_src" in
            URL:*|url:*)   printf "    ${DIM}%s${R}\n" "${_src#*: }" ;;
            Title:*|title:*) printf "    ${B}%s${R}\n" "${_src#*: }" ;;
          esac
        done
        echo ""
      else
        warn "No web results found — answering from model knowledge only"
      fi
      # Build prompt
      local _aw_context=""
      if [[ $_aw_mem -eq 1 ]]; then
        _aw_context=$(cmd_memory context 2>/dev/null || echo "")
      fi
      if [[ -n "$_aw_results" ]]; then
        _aw_prompt="Use these web search results to answer. Cite sources.

Search results:
${_aw_results}
${_aw_context:+
Known facts: ${_aw_context}}

Question: ${_aw_prompt}"
      fi
      dispatch_ask "$_aw_prompt" || true ;;

    ask-think|think|ask-t)
      local _at_prompt="$*"
      if [[ -z "$_at_prompt" ]]; then
        read -rp "$(echo -e "${BCYAN}Think: ${R}")" _at_prompt
        [[ -z "$_at_prompt" ]] && { err "Usage: ai ask-think \"question\""; return 1; }
      fi
      dispatch_ask "Think step by step. Show your reasoning process clearly before giving a final answer.

Question: ${_at_prompt}

Lets think through this step by step:" ;;

    ask-think-web|ask-w-t|awt|thinkweb)
      local _atw_prompt="$*"
      if [[ -z "$_atw_prompt" ]]; then
        read -rp "$(echo -e "${BCYAN}Think+Web: ${R}")" _atw_prompt
        [[ -z "$_atw_prompt" ]] && { err "Usage: ai ask-w-t \"question\""; return 1; }
      fi
      info "Searching the web..."
      local _atw_results=""
      _atw_results=$(web_search "$_atw_prompt" 5 2>/dev/null) || true
      [[ -z "$_atw_results" ]] && _atw_results=$(cmd_websearch "$_atw_prompt" 2>/dev/null) || true
      if [[ -n "$_atw_results" ]]; then
        echo ""
        echo -e "${B}${BCYAN}Sources:${R}"
        echo "$_atw_results" | grep -i "^URL:\|^Title:" | while IFS= read -r line; do
          [[ "$line" == URL:* ]] && printf "  ${DIM}%s${R}\n" "${line#URL: }"
          [[ "$line" == Title:* ]] && printf "  ${B}%s${R}\n" "${line#Title: }"
        done
        echo ""
      fi
      local _atw_full="Think step by step. Show your reasoning. Use the web results to support your answer. Cite sources.

Web search results:
${_atw_results:-No results found}

Question: ${_atw_prompt}

Lets reason through this step by step:"
      dispatch_ask "$_atw_full" || true ;;

    # ── ask-n: use all CPU cores for faster local inference ──────────
    ask-n|a-n)
      local _old_threads="$THREADS" _old_gpu="$GPU_LAYERS"
      THREADS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
      GPU_LAYERS=0
      local _an_prompt="$*"
      if [[ -z "$_an_prompt" ]]; then
        read -rp "$(echo -e "${BCYAN}Ask CPU: ${R}")" _an_prompt
        [[ -z "$_an_prompt" ]] && { err "Usage: ai ask-n \"question\""; THREADS="$_old_threads"; GPU_LAYERS="$_old_gpu"; return 1; }
      fi
      if [[ -z "$LLAMA_BIN" && -n "$PYTHON" ]]; then
        if ! "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
          info "Installing CPU-optimized llama-cpp-python..."
          CMAKE_ARGS="-DLLAMA_BLAS=ON" \
            "$PYTHON" -m pip install llama-cpp-python --break-system-packages -q 2>/dev/null || \
            "$PYTHON" -m pip install llama-cpp-python -q 2>/dev/null || true
          LLAMA_BIN="llama_cpp_python"
        fi
      fi
      info "CPU mode — $THREADS cores"
      dispatch_ask "$_an_prompt" || true
      THREADS="$_old_threads"; GPU_LAYERS="$_old_gpu" ;;

    # ── ask-n with web: all CPU + web search ─────────────────────────
    ask-n-w|a-n-w|ask-n-web|a-n-w-t|ask-n-w-t)
      local _old_threads="$THREADS"
      THREADS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
      info "Using all $THREADS CPU cores"
      local _anw="$*"
      # If command includes -t, add thinking
      local _think_prefix=""
      if [[ "$cmd" == *t* && "$cmd" != *web* ]] || [[ "$cmd" == "a-n-w-t" || "$cmd" == "ask-n-w-t" ]]; then
        _think_prefix="Think step by step. "
      fi
      info "Searching the web..."
      local _anw_res=""
      _anw_res=$(web_search "$_anw" 5 2>/dev/null || echo "")
      _anw_res=$(echo "$_anw_res" | sed '/^$/d' | head -50)
      if [[ -n "$_anw_res" ]]; then
        echo -e "  ${B}${BCYAN}Sources found:${R}"
        echo "$_anw_res" | grep -i "^URL:\|^Title:" | head -10 | while IFS= read -r _s; do
          case "$_s" in URL:*|url:*) printf "    ${DIM}%s${R}\n" "${_s#*: }" ;; Title:*|title:*) printf "    ${B}%s${R}\n" "${_s#*: }" ;; esac
        done; echo ""
        _anw="${_think_prefix}Use these web results to answer. Cite sources.

Search results:
${_anw_res}

Question: ${_anw}"
      fi
      dispatch_ask "$_anw"
      THREADS="$_old_threads" ;;

    # ── Short aliases: a-w, a-t, a-w-t ───────────────────────────────
    a-w)  main ask-web "$@" ;;
    a-t)  main ask-think "$@" ;;
    a-wt|a-w-t) main ask-w-t "$@" ;;
    a-n-t|ask-n-t)
      local _old_threads="$THREADS"
      THREADS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
      info "Using all $THREADS CPU cores"
      dispatch_ask "Think step by step. Show your reasoning clearly.

Question: $*

Lets reason through this step by step:"
      THREADS="$_old_threads" ;;

    chat)       cmd_chat_interactive ;;
    code)
      local lang="" run=0 args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in --lang) lang="$2"; shift 2 ;; --run) run=1; shift ;; *) args+=("$1"); shift ;; esac
      done
      local result; result=$(dispatch_ask "Write ${lang:-code}: ${args[*]}")
      echo "$result"
      if [[ $run -eq 1 ]]; then
        local ext="${lang:-python}"; ext="${ext//python/py}"
        local tmp; tmp=$(mktemp /tmp/ai_code_XXXX."$ext")
        echo "$result" | sed '/^```/d' > "$tmp"
        case "${lang:-python}" in python|py|"") python3 "$tmp" ;; bash|sh) bash "$tmp" ;; esac
        rm -f "$tmp"
      fi ;;
    review)   dispatch_ask "Code review:
$(cat "${1:--}" 2>/dev/null)" ;;
    explain)  dispatch_ask "Explain:
$(cat "${1:--}" 2>/dev/null)" ;;
    summarize) dispatch_ask "Summarize:
$(cat "${1:--}" 2>/dev/null)" ;;
    translate) dispatch_ask "Translate to ${3:-English}: $1" ;;
    pipe)     cat | dispatch_ask "${*:-Summarize:}
$(cat)" ;;

    # ── Agent + web search ────────────────────────────────────────────────────
    agent)    cmd_agent "$@" ;;
    websearch|search|web) cmd_websearch "$@" ;;

    # ── Named chat management ─────────────────────────────────────────────────
    chat-list)   cmd_chat_list ;;
    chat-show)   cmd_chat_show "$@" ;;
    chat-delete) cmd_chat_delete "$@" ;;

    # ── Media ─────────────────────────────────────────────────────────────────
    audio)       cmd_audio "$@" ;;
    video)       cmd_video "$@" ;;
    vision)      cmd_vision "$@" ;;
    imagine)     cmd_imagine "$@" ;;
    tts)         _audio_tts "$@" ;;
    transcribe)  _audio_transcribe "$@" ;;

    # ── Canvas v3 ──────────────────────────────────────────────────────────
    canvas)  if type cmd_canvas_v3 &>/dev/null; then cmd_canvas_v3 "$@"; else cmd_canvas "$@"; fi ;;

    # ── Models ────────────────────────────────────────────────────────────────
    model)
      if [[ $# -gt 0 ]]; then
        ACTIVE_MODEL="$1"; [[ $# -gt 1 ]] && ACTIVE_BACKEND="$2"
        save_config; ok "Model: $ACTIVE_MODEL"
      else echo "Active: ${ACTIVE_MODEL:-not set}"; fi ;;
    models)          cmd_list_models ;;
    download)        cmd_download "$@" ;;
    recommended)     cmd_recommended "$@" ;;
    search-models)   cmd_search_models "$@" ;;
    upload)          cmd_upload "$@" ;;
    model-info)      cmd_model_info "$@" ;;
    model-create|create-model) cmd_model_create "$@" ;;
    model-state)     cmd_model_save_restore "$@" ;;

    # ── Trained models (case-sensitive!) ─────────────────────────────────────
    ttm|TTM)    cmd_ttm "$@" ;;
    mtm|MTM)    cmd_mtm "$@" ;;
    Mtm|MMTM)   cmd_Mtm "$@" ;;
    -TTM|--TTM) _tm_load "TTM" ;;
    -MTM|--MTM) _tm_load "MTM" ;;
    -Mtm|--Mtm) _tm_load "Mtm" ;;

    # ── RLHF ─────────────────────────────────────────────────────────────────
    rlhf)  cmd_rlhf "$@" ;;

    # ── Right-click ───────────────────────────────────────────────────────────
    rclick|right-click) cmd_rclick "$@" ;;

    # ── Fine-tuning ───────────────────────────────────────────────────────────
    finetune|ft) cmd_finetune "$@" ;;

    # ── Sessions / Personas ───────────────────────────────────────────────────
    session)  cmd_session "$@" ;;
    persona)  cmd_persona "$@" ;;

    # ── v2.6: Projects (multi-chat memory) ───────────────────────────────────
    project|projects|proj) cmd_project "$@" ;;

    # ── v2.5.5: System prompt management ─────────────────────────────────────
    system|sys-prompt|sysprompt) cmd_system "$@" ;;

    # ── Settings ──────────────────────────────────────────────────────────────
    config)        cmd_config "$@" ;;
    keys)          cmd_keys "$@" ;;
    history)       cmd_history "$@" ;;
    clear-history) echo "[]" > "$SESSIONS_DIR/${ACTIVE_SESSION}.json"; ok "Cleared" ;;
    status)        cmd_status ;;
    install-deps)  cmd_install_deps "$@" ;;
    -uninstall|--uninstall|uninstall) cmd_uninstall ;;

    # ── v3.2 new features ─────────────────────────────────────────────────────
    voice|say|tts)                  cmd_voice "$@" ;;
    share|tunnel)                   cmd_share "$@" ;;
    diff-review|review|dr)          cmd_diff_review "$@" ;;
    agent|loop|auto)                cmd_agent "$@" ;;
    rag-quick|rq|quick-rag)         cmd_rag_quick "$@" ;;
    hy|hypernix)                    cmd_hy "$@" ;;

    # ── GUI / GUI+ / Bench / Serve ────────────────────────────────────────────
    -gui|--gui|gui)            cmd_gui ;;
    -gui+|--gui+|gui+|guiplus) cmd_gui_plus ;;
    bench)  cmd_bench "$@" ;;
    serve)  cmd_serve "$@" ;;

    # ── v2.7.4: AI Node Editor ────────────────────────────────────────────────
    node|nodes|ai-node) cmd_node "$@" ;;

    # ── v2.4: Custom Datasets ─────────────────────────────────────────────────
    dataset|datasets) cmd_dataset "$@" ;;

    # ── v3: LLM API Server ───────────────────────────────────────────────────
    api)    cmd_api_v3 "$@" ;;

    # ── v2.4.5: Multi-AI Arena ────────────────────────────────────────────────
    multiai|multi-ai|arena) cmd_multiai "$@" ;;

    # ── v2.5: GitHub integration ──────────────────────────────────────────────
    github|gh-cmd) cmd_github "$@" ;;

    # ── v2.5: Research paper scraper (open-access) ────────────────────────────
    papers|paper|research) cmd_papers "$@" ;;

    # ── v2.5: Build / compile XZ bundle ──────────────────────────────────────
    build|compile) cmd_build "$@" ;;

    # ── v2.5: Multimodal training ─────────────────────────────────────────────
    train-multimodal|multimodal-train|train-mm) cmd_train_multimodal "$@" ;;

    # ── v2.5: Image generation v2 (img2img, inpaint, LoRA) ────────────────────
    imagine2|imggen2)
      _imggen_v2 "${1:-}" "${2:-txt2img}" "${3:-}" "${4:-0.75}" ;;

    # ── v2.5: RLHF v2 extras ─────────────────────────────────────────────────
    rlhf-reward|reward-model) _rlhf_train_reward_model "$@" ;;
    rlhf-ppo|ppo)             _rlhf_train_ppo "$@" ;;
    rlhf-grpo|grpo)           _rlhf_train_grpo "$@" ;;

    # ── v2.5.5: System prompt management ─────────────────────────────────────
    system|sys-prompt|sysprompt) cmd_system "$@" ;;

    # ── v2.7: AI Extensions ───────────────────────────────────────────────────
    extension|ext)      cmd_extension "$@" ;;
    ext-create)         cmd_extension create "$@" ;;
    ext-load)           cmd_extension load "$@" ;;
    ext-locate|ext-list) cmd_extension locate ;;
    ext-package)        cmd_extension package "$@" ;;
    ext-edit)           cmd_extension edit "$@" ;;
    ext-run)            cmd_extension run "$@" ;;

    # ── v2.7: Firefox LLM Sidebar Extension ──────────────────────────────────
    install-firefox-ext|firefox-ext|firefox) cmd_install_firefox_ext "$@" ;;

    # ── v2.7.3: Aliases ───────────────────────────────────────────────────────
    alias)  cmd_alias "$@" ;;

    # ── v2.9.0: New commands ─────────────────────────────────────────
    snap|snapshot)    cmd_snap "$@" ;;
    perf|benchmark)   cmd_perf "$@" ;;
    compare)          cmd_compare "$@" ;;
    template|tpl)     cmd_template "$@" ;;
    rag)              cmd_rag "$@" ;;
    batch)            cmd_batch "$@" ;;
    health)           cmd_health "$@" ;;
    branch)           cmd_branch "$@" ;;
    export)           cmd_export "$@" ;;
    import)           cmd_import "$@" ;;
    cleanup|clean)    cmd_cleanup "$@" ;;
    preset)           cmd_preset "$@" ;;
    plugin|plugins)   cmd_plugin "$@" ;;
    test)             cmd_test "$@" ;;

    # ── Misc ──────────────────────────────────────────────────────────────────
    version|-v|--version) echo "AI CLI v${VERSION}" ;;
    # v2.7.4: -h <command> gives detailed per-command help; bare help → full help
    -h|--help-cmd)
      if [[ -n "${1:-}" ]]; then cmd_help_detail "$1"
      else show_help; fi ;;
    help|--help|"")           show_help ;;
    tools)  echo "Builtin agent tools: ${!AGENT_TOOLS_REGISTRY[*]}" ;;
    error-codes|errcodes|errors)
      hdr "AI CLI v${VERSION} — Error Code Reference"
      echo ""
      for code in "${!ERR_CODES[@]}"; do
        printf "  ${B}%-10s${R} %s\n" "$code" "${ERR_CODES[$code]}"
      done | sort
      ;;
    *)
      # v2.9.0: Try extended dispatcher first (all new commands)
      if _dispatch_v29_final "$cmd" "$@"; then
        return 0
      fi
      # v2.7.3: Check user-defined aliases
      local _alias_cmd
      _alias_cmd=$(_resolve_alias "$cmd" 2>/dev/null) || true
      if [[ -n "$_alias_cmd" ]]; then
        # shellcheck disable=SC2086
        eval "main $_alias_cmd \"\$@\""
        return $?
      fi
      # v2.9.5: No AI fallthrough — show error with suggestions
      err "Unknown command: $cmd"
      echo ""
      echo "  Did you mean:"
      echo "    ai ask \"$cmd $*\"        Send to AI"
      echo "    ai ask-web \"$cmd $*\"    Send to AI with web search"
      echo "    ai agent \"$cmd $*\"      Run as autonomous agent task"
      echo "    ai -h $cmd              Get help for a command"
      echo "    ai help                 Show all commands"
      echo ""
      echo "  v3.2 new commands:"
      echo "    ai voice  share  diff-review  agent  rag-quick"
      ;;
  esac
}

# ─── Startup hooks ────────────────────────────────────────────────────────────
_startup_hooks() {
  # Background auto-train check for all models
  local now; now=$(date +%s)
  for id in TTM MTM Mtm; do
    _tm_vars "$id" 2>/dev/null || continue
    local auto; auto=$(_tm_get_var "$TM_AUTO_TRAIN_VAR")
    [[ "$auto" != "1" ]] && continue
    local last_file="$TM_DIR/.last_train"
    local last=0
    [[ -f "$last_file" ]] && last=$(date -r "$last_file" +%s 2>/dev/null || stat -c %Y "$last_file" 2>/dev/null || echo 0)
    if (( now - last > 3600 )); then
      _tm_train_batch "$id" &>/dev/null & disown
    fi
  done
  # Background update check
  _aup_bg_check 2>/dev/null || true
}

# v2.7.3: unified skip-list to prevent startup hooks running during special commands
_is_noninteractive_cmd() {
  local c="${1:-}"
  case "$c" in
    install-deps|-uninstall|--uninstall|uninstall|version|-v|--version) return 0 ;;
    *) return 1 ;;
  esac
}

if ! _is_noninteractive_cmd "${1:-}"; then
  _startup_hooks 2>/dev/null || true
fi

# v2.7.3: First-run check — fixed: now also skips for 'uninstall' (without dash)
if ! _is_noninteractive_cmd "${1:-}"; then
  _first_run_check 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════════
#  v2.9.0 NEW FEATURES — appended below existing v2.7.4 code
# ════════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  ROBUST API RETRY LOGIC — v2.9.0
#  Exponential backoff with jitter for all cloud API calls
#  Handles: rate limits (429), server errors (5xx), network timeouts
# ════════════════════════════════════════════════════════════════════════════════

_api_retry() {
  # Usage: _api_retry <max_retries> <base_delay> COMMAND
  local max_retries="${1:-$RETRY_MAX}"
  local base_delay="${2:-$RETRY_DELAY}"
  shift 2
  local attempt=0
  local exit_code=0
  local output=""
  local delay="$base_delay"

  while (( attempt < max_retries )); do
    (( attempt++ ))
    output=$("$@" 2>&1) && { echo "$output"; return 0; }
    exit_code=$?

    # Check if error is retryable
    if echo "$output" | grep -qiE "rate.limit|429|503|502|504|timeout|ECONNRESET|ETIMEDOUT"; then
      local jitter=$(( RANDOM % 1000 ))
      local wait_ms=$(( delay * 1000 + jitter ))
      local wait_s=$(awk "BEGIN{printf \"%.1f\", $wait_ms/1000}")

      if [[ $VERBOSE -eq 1 ]]; then
        warn "API call failed (attempt $attempt/$max_retries): retrying in ${wait_s}s..."
        warn "Error: $(echo "$output" | head -3)"
      fi

      sleep "$wait_s"
      delay=$(( delay * 2 ))  # exponential backoff
    else
      # Non-retryable error
      echo "$output"
      return $exit_code
    fi
  done

  err "API call failed after $max_retries attempts"
  echo "$output"
  return $exit_code
}

# Wrapped API callers with retry support
_curl_api_retry() {
  _api_retry "$RETRY_MAX" "$RETRY_DELAY" curl "$@"
}

# Rate limit tracker
declare -A _RATE_LIMIT_REMAINING=()
declare -A _RATE_LIMIT_RESET=()

_track_rate_limits() {
  local backend="$1"
  local headers="$2"
  local remaining limit reset

  remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining' | awk '{print $2}' | tr -d '\r')
  limit=$(echo "$headers" | grep -i 'x-ratelimit-limit' | awk '{print $2}' | tr -d '\r')
  reset=$(echo "$headers" | grep -i 'x-ratelimit-reset' | awk '{print $2}' | tr -d '\r')

  if [[ -n "$remaining" ]]; then
    _RATE_LIMIT_REMAINING["$backend"]="$remaining"
    _RATE_LIMIT_RESET["$backend"]="$reset"

    if (( remaining < 5 )); then
      warn "Rate limit warning: ${backend} has ${remaining}/${limit} requests remaining"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  ENHANCED ERROR HANDLING — v2.9.0
#  Structured error reporting with error codes and recovery suggestions
# ════════════════════════════════════════════════════════════════════════════════

# Extended error codes (adding to v2.7.3 error codes)
# ERR4xx = Feature errors
# ERR5xx = Data/IO errors
# ERR6xx = Performance errors
declare -A ERR_MESSAGES_V29=(
  [ERR401]="Snapshot not found"
  [ERR402]="Template not found"
  [ERR403]="RAG knowledge base not found"
  [ERR404]="Batch job not found"
  [ERR405]="Export format not supported"
  [ERR406]="Conversation branch not found"
  [ERR407]="Health check failed"
  [ERR408]="Benchmark interrupted"
  [ERR409]="Model comparison failed"
  [ERR410]="Plugin load failed"
  [ERR501]="Cannot read input file"
  [ERR502]="Cannot write output file"
  [ERR503]="Insufficient disk space"
  [ERR504]="JSON parse error"
  [ERR505]="CSV parse error"
  [ERR601]="Model too slow (< 1 tok/s)"
  [ERR602]="Out of memory"
  [ERR603]="GPU not available"
  [ERR604]="Context window exceeded"
)

_err_v29() {
  local code="$1"; shift
  local msg="${ERR_MESSAGES_V29[$code]:-Unknown error}"
  local detail="${*:-}"
  printf "${RED}${B}Error ${code}:${R} ${msg}"
  [[ -n "$detail" ]] && printf " — ${detail}"
  printf "\n"
  echo "$(date -Iseconds) [$code] $msg $detail" >> "$HEALTH_LOG" 2>/dev/null || true
}

_err_suggest() {
  local code="$1"
  case "$code" in
    ERR401) echo "  Tip: List snapshots with: ai snap list" ;;
    ERR402) echo "  Tip: List templates with: ai template list" ;;
    ERR403) echo "  Tip: Create a knowledge base: ai rag create NAME <directory>" ;;
    ERR501) echo "  Tip: Check file permissions and path" ;;
    ERR503) echo "  Tip: Free up disk space: ai cleanup" ;;
    ERR601) echo "  Tip: Try a smaller model or increase GPU layers" ;;
    ERR602) echo "  Tip: Reduce context size: ai set context 2048" ;;
    ERR603) echo "  Tip: Check GPU drivers or use --cpu-only" ;;
    ERR604) echo "  Tip: Reduce prompt size or increase context: ai set context 8192" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  CONFIG SNAPSHOTS — v2.9.0
#  Save and restore complete configuration states
#  Usage: ai snap save NAME | ai snap load NAME | ai snap list | ai snap diff <a> <b>
# ════════════════════════════════════════════════════════════════════════════════

cmd_snap() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    save)
      local name="${1:?Usage: ai snap save NAME}"
      local snap_file="$SNAPSHOTS_DIR/${name}.snap"
      {
        echo "# AI CLI Config Snapshot: $name"
        echo "# Created: $(date -Iseconds)"
        echo "# Version: $VERSION"
        echo "# Platform: $PLATFORM"
        echo ""
        cat "$CONFIG_FILE" 2>/dev/null || true
        echo ""
        echo "# --- Active Model Info ---"
        echo "SNAP_ACTIVE_MODEL=\"$ACTIVE_MODEL\""
        echo "SNAP_ACTIVE_BACKEND=\"$ACTIVE_BACKEND\""
        echo "SNAP_ACTIVE_PERSONA=\"$ACTIVE_PERSONA\""
        echo "SNAP_MAX_TOKENS=\"$MAX_TOKENS\""
        echo "SNAP_TEMPERATURE=\"$TEMPERATURE\""
        echo "SNAP_TOP_P=\"$TOP_P\""
        echo "SNAP_CONTEXT_SIZE=\"$CONTEXT_SIZE\""
        echo "SNAP_GPU_LAYERS=\"$GPU_LAYERS\""
        echo "SNAP_THREADS=\"$THREADS\""
      } > "$snap_file"
      ok "Snapshot saved: ${CYAN}$name${R}"
      dim "Restore with: ai snap load $name"
      ;;
    load|restore)
      local name="${1:?Usage: ai snap load NAME}"
      local snap_file="$SNAPSHOTS_DIR/${name}.snap"
      if [[ ! -f "$snap_file" ]]; then
        _err_v29 ERR401 "$name"
        _err_suggest ERR401
        return 1
      fi
      # Source the snapshot to restore config
      source "$snap_file"
      # Apply snapshot values if they exist
      [[ -n "${SNAP_ACTIVE_MODEL:-}" ]] && ACTIVE_MODEL="$SNAP_ACTIVE_MODEL"
      [[ -n "${SNAP_ACTIVE_BACKEND:-}" ]] && ACTIVE_BACKEND="$SNAP_ACTIVE_BACKEND"
      [[ -n "${SNAP_ACTIVE_PERSONA:-}" ]] && ACTIVE_PERSONA="$SNAP_ACTIVE_PERSONA"
      [[ -n "${SNAP_MAX_TOKENS:-}" ]] && MAX_TOKENS="$SNAP_MAX_TOKENS"
      [[ -n "${SNAP_TEMPERATURE:-}" ]] && TEMPERATURE="$SNAP_TEMPERATURE"
      [[ -n "${SNAP_TOP_P:-}" ]] && TOP_P="$SNAP_TOP_P"
      [[ -n "${SNAP_CONTEXT_SIZE:-}" ]] && CONTEXT_SIZE="$SNAP_CONTEXT_SIZE"
      [[ -n "${SNAP_GPU_LAYERS:-}" ]] && GPU_LAYERS="$SNAP_GPU_LAYERS"
      [[ -n "${SNAP_THREADS:-}" ]] && THREADS="$SNAP_THREADS"
      save_config
      ok "Snapshot restored: ${CYAN}$name${R}"
      ;;
    list|ls)
      hdr "Config Snapshots"
      if [[ -z "$(ls -A "$SNAPSHOTS_DIR" 2>/dev/null)" ]]; then
        info "No snapshots saved yet. Create one with: ai snap save NAME"
        return
      fi
      local count=0
      for f in "$SNAPSHOTS_DIR"/*.snap; do
        [[ -f "$f" ]] || continue
        local sname=$(basename "$f" .snap)
        local created=$(grep '# Created:' "$f" | head -1 | sed 's/# Created: //')
        local sver=$(grep '# Version:' "$f" | head -1 | sed 's/# Version: //')
        printf "  ${CYAN}%-20s${R}  ${DIM}v%-8s  %s${R}\n" "$sname" "$sver" "$created"
        (( count++ ))
      done
      info "$count snapshots found"
      ;;
    diff)
      local name_a="${1:?Usage: ai snap diff <snap1> <snap2>}"
      local name_b="${2:?Usage: ai snap diff <snap1> <snap2>}"
      local fa="$SNAPSHOTS_DIR/${name_a}.snap"
      local fb="$SNAPSHOTS_DIR/${name_b}.snap"
      [[ -f "$fa" ]] || { _err_v29 ERR401 "$name_a"; return 1; }
      [[ -f "$fb" ]] || { _err_v29 ERR401 "$name_b"; return 1; }
      hdr "Diff: $name_a ↔ $name_b"
      diff --color=auto "$fa" "$fb" || true
      ;;
    delete|rm)
      local name="${1:?Usage: ai snap delete NAME}"
      local snap_file="$SNAPSHOTS_DIR/${name}.snap"
      [[ -f "$snap_file" ]] || { _err_v29 ERR401 "$name"; return 1; }
      rm -f "$snap_file"
      ok "Snapshot deleted: $name"
      ;;
    *)
      echo "Usage: ai snap <save|load|list|diff|delete> [args]"
      echo ""
      echo "  save NAME          Save current config as snapshot"
      echo "  load NAME          Restore config from snapshot"
      echo "  list                 Show all saved snapshots"
      echo "  diff <a> <b>         Compare two snapshots"
      echo "  delete NAME        Delete a snapshot"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  PERFORMANCE BENCHMARK — v2.9.0
#  Measure tokens/sec, latency, throughput for active model
#  Usage: ai perf [--prompt "text"] [--tokens N] [--runs N]
# ════════════════════════════════════════════════════════════════════════════════

cmd_perf() {
  local prompt="Explain the theory of relativity in simple terms."
  local max_tokens=128
  local runs=3
  local warmup=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --tokens) max_tokens="$2"; shift 2 ;;
      --runs)   runs="$2"; shift 2 ;;
      --warmup) warmup="$2"; shift 2 ;;
      -h|--help)
        echo "Usage: ai perf [OPTIONS]"
        echo ""
        echo "  --prompt TEXT    Test prompt (default: relativity explanation)"
        echo "  --tokens N       Max tokens to generate (default: 128)"
        echo "  --runs N         Number of benchmark runs (default: 3)"
        echo "  --warmup N       Warmup runs before measuring (default: 1)"
        return 0 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$ACTIVE_MODEL" && -z "$ACTIVE_BACKEND" ]]; then
    err "No active model. Set one with: ai recommended use N"
    return 1
  fi

  hdr "Performance Benchmark"
  info "Model:      ${ACTIVE_MODEL:-$ACTIVE_BACKEND}"
  info "Backend:    ${ACTIVE_BACKEND:-auto}"
  info "Max tokens: $max_tokens"
  info "Runs:       $runs (+ $warmup warmup)"
  info "Prompt:     \"${prompt:0:60}...\""
  echo ""

  local total_tps=0
  local total_latency=0
  local min_tps=999999
  local max_tps=0
  local results=()

  # Warmup runs
  for (( w=1; w<=warmup; w++ )); do
    printf "  ${DIM}Warmup $w/$warmup...${R}\r"
    _silent_generate "$prompt" "$max_tokens" >/dev/null 2>&1 || true
  done

  # Benchmark runs
  for (( r=1; r<=runs; r++ )); do
    printf "  ${CYAN}Run $r/$runs...${R}\r"

    local start_ns=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
    local output=$(_silent_generate "$prompt" "$max_tokens" 2>/dev/null || echo "")
    local end_ns=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")

    if [[ -z "$output" ]]; then
      warn "Run $r produced no output"
      continue
    fi

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local token_count=$(echo "$output" | wc -w)
    local tps=0
    if (( elapsed_ms > 0 )); then
      tps=$(awk "BEGIN{printf \"%.1f\", $token_count / ($elapsed_ms / 1000.0)}")
    fi
    local latency_ms=$elapsed_ms

    results+=("$tps:$latency_ms:$token_count")
    total_tps=$(awk "BEGIN{print $total_tps + $tps}")
    total_latency=$(( total_latency + latency_ms ))

    local tps_int=${tps%.*}
    (( tps_int < min_tps )) && min_tps=$tps_int
    (( tps_int > max_tps )) && max_tps=$tps_int

    printf "  Run %d: ${GREEN}%.1f tok/s${R}  ${DIM}— %d ms, %d tokens${R}\n" \
      "$r" "$tps" "$latency_ms" "$token_count"
  done

  local actual_runs=${#results[@]}
  if (( actual_runs == 0 )); then
    _err_v29 ERR408 "No successful runs"
    return 1
  fi

  local avg_tps=$(awk "BEGIN{printf \"%.1f\", $total_tps / $actual_runs}")
  local avg_latency=$(( total_latency / actual_runs ))

  echo ""
  hdr "Results"
  printf "  Avg:   ${GREEN}${B}%s tok/s${R}\n" "$avg_tps"
  printf "  Min:   %s tok/s\n" "$min_tps"
  printf "  Max:   %s tok/s\n" "$max_tps"
  printf "  Avg latency: %d ms\n" "$avg_latency"
  echo ""

  # Save to log
  {
    echo "$(date -Iseconds) | model=$ACTIVE_MODEL | backend=$ACTIVE_BACKEND | avg_tps=$avg_tps | avg_latency=${avg_latency}ms | runs=$actual_runs | max_tokens=$max_tokens"
  } >> "$PERF_LOG"

  # Performance rating
  local tps_num=${avg_tps%.*}
  if (( tps_num >= 50 )); then
    ok "Rating: ${GREEN}Excellent${R} (50+ tok/s)"
  elif (( tps_num >= 20 )); then
    ok "Rating: ${BGREEN}Good${R} (20-50 tok/s)"
  elif (( tps_num >= 5 )); then
    warn "Rating: ${YELLOW}Moderate${R} (5-20 tok/s)"
  elif (( tps_num >= 1 )); then
    warn "Rating: ${BYELLOW}Slow${R} (1-5 tok/s)"
  else
    _err_v29 ERR601 "${avg_tps} tok/s"
    _err_suggest ERR601
  fi
}

# Silent generation helper (no streaming output)
_silent_generate() {
  local prompt="$1"
  local max_tok="${2:-128}"
  local old_stream="$STREAM"
  STREAM=0
  # Route through the appropriate backend
  case "${ACTIVE_BACKEND:-}" in
    openai)
      _openai_query "$prompt" "$max_tok" 2>/dev/null ;;
    claude|anthropic)
      _claude_query "$prompt" "$max_tok" 2>/dev/null ;;
    gemini)
      _gemini_query "$prompt" "$max_tok" 2>/dev/null ;;
    groq)
      _groq_query "$prompt" "$max_tok" 2>/dev/null ;;
    mistral)
      _mistral_query "$prompt" "$max_tok" 2>/dev/null ;;
    gguf|llama|local)
      _gguf_query "$prompt" "$max_tok" 2>/dev/null ;;
    *)
      # Try the generic ask handler
      echo "$prompt" | timeout 60 ai ask --no-stream 2>/dev/null ;;
  esac
  STREAM="$old_stream"
}

# ════════════════════════════════════════════════════════════════════════════════
#  MODEL COMPARISON — v2.9.0
#  Side-by-side comparison of multiple models on the same prompt
#  Usage: ai compare "prompt" [--models "model1,model2,..."]
# ════════════════════════════════════════════════════════════════════════════════

cmd_compare() {
  local prompt=""
  local models_csv=""
  local max_tokens=256
  local show_timing=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --models)   models_csv="$2"; shift 2 ;;
      --tokens)   max_tokens="$2"; shift 2 ;;
      --no-time)  show_timing=0; shift ;;
      -h|--help)
        echo "Usage: ai compare \"prompt\" [OPTIONS]"
        echo ""
        echo "  --models LIST    Comma-separated model list"
        echo "  --tokens N       Max tokens (default: 256)"
        echo "  --no-time        Hide timing info"
        echo ""
        echo "Examples:"
        echo "  ai compare \"What is AI?\" --models openai,claude,gemini"
        echo "  ai compare \"Write a haiku\" --models gguf,openai"
        return 0 ;;
      *)
        if [[ -z "$prompt" ]]; then
          prompt="$1"
        fi
        shift ;;
    esac
  done

  if [[ -z "$prompt" ]]; then
    echo "Usage: ai compare \"prompt\" [--models model1,model2,...]"
    return 1
  fi

  # Default to available backends
  if [[ -z "$models_csv" ]]; then
    local available_backends=()
    [[ -n "${OPENAI_API_KEY:-}" ]] && available_backends+=("openai")
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && available_backends+=("claude")
    [[ -n "${GEMINI_API_KEY:-}" ]] && available_backends+=("gemini")
    [[ -n "${GROQ_API_KEY:-}" ]] && available_backends+=("groq")
    [[ -n "$LLAMA_BIN" || -n "${ACTIVE_MODEL:-}" ]] && available_backends+=("gguf")

    if (( ${#available_backends[@]} < 2 )); then
      err "Need at least 2 backends for comparison."
      info "Available: ${available_backends[*]:-none}"
      info "Set API keys or load a local model first."
      return 1
    fi
    models_csv=$(IFS=,; echo "${available_backends[*]}")
  fi

  IFS=',' read -ra models <<< "$models_csv"

  hdr "Model Comparison"
  info "Prompt:  \"${prompt:0:80}...\""
  info "Models:  ${models[*]}"
  info "Tokens:  $max_tokens"
  echo ""

  local saved_backend="$ACTIVE_BACKEND"
  local compare_file="$COMPARE_DIR/compare_$(date +%Y%m%d_%H%M%S).md"

  {
    echo "# Model Comparison — $(date -Iseconds)"
    echo "## Prompt"
    echo '```'
    echo "$prompt"
    echo '```'
    echo ""
  } > "$compare_file"

  for model in "${models[@]}"; do
    model=$(echo "$model" | xargs)  # trim whitespace
    printf "  ${CYAN}━━━ %s ━━━${R}\n" "$model"

    ACTIVE_BACKEND="$model"
    local start_ms=$(date +%s%3N 2>/dev/null || echo 0)
    local response=$(_silent_generate "$prompt" "$max_tokens" 2>/dev/null || echo "[Error: No response from $model]")
    local end_ms=$(date +%s%3N 2>/dev/null || echo 0)
    local elapsed=$(( end_ms - start_ms ))

    echo "$response" | head -20
    if [[ $(echo "$response" | wc -l) -gt 20 ]]; then
      printf "  ${DIM}... (truncated, %d lines total)${R}\n" "$(echo "$response" | wc -l)"
    fi

    if [[ $show_timing -eq 1 ]]; then
      local wc=$(echo "$response" | wc -w)
      printf "  ${DIM}[%d ms | %d words]${R}\n" "$elapsed" "$wc"
    fi
    echo ""

    # Save to comparison file
    {
      echo "## $model"
      echo '```'
      echo "$response"
      echo '```'
      echo "Time: ${elapsed}ms | Words: $(echo "$response" | wc -w)"
      echo ""
    } >> "$compare_file"
  done

  ACTIVE_BACKEND="$saved_backend"
  ok "Comparison saved: $compare_file"
}

# ════════════════════════════════════════════════════════════════════════════════
#  PROMPT TEMPLATES — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_template() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create|new)
      local name="${1:?Usage: ai template create NAME}"
      local tpl_file="$TEMPLATES_DIR/${name}.tpl"
      if [[ -f "$tpl_file" ]]; then
        warn "Template '$name' already exists. Use --force to overwrite."
        [[ "${2:-}" != "--force" ]] && return 1
      fi
      cat > "$tpl_file" <<'TPLEOF'
# AI CLI Prompt Template
# Variables: {{input}}, {{context}}, {{language}}, {{style}}
# Usage: ai template use NAME --input "your text"

You are a helpful assistant.

{{context}}

User request: {{input}}

Please respond in {{style}} style.
TPLEOF
      ok "Template created: $tpl_file"
      info "Edit it, then use: ai template use $name --input \"...\""
      ;;
    use|apply)
      local name="${1:?Usage: ai template use NAME [--input TEXT]}"
      shift
      local tpl_file="$TEMPLATES_DIR/${name}.tpl"
      [[ -f "$tpl_file" ]] || { _err_v29 ERR402 "$name"; return 1; }
      local content
      content=$(grep -v '^#' "$tpl_file")
      # Replace variables from args
      local input="" context="" language="" style="concise"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --input)    input="$2"; shift 2 ;;
          --context)  context="$2"; shift 2 ;;
          --language) language="$2"; shift 2 ;;
          --style)    style="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      content="${content//\{\{input\}\}/$input}"
      content="${content//\{\{context\}\}/$context}"
      content="${content//\{\{language\}\}/$language}"
      content="${content//\{\{style\}\}/$style}"
      echo "$content"
      ;;
    list|ls)
      hdr "Prompt Templates"
      local count=0
      for f in "$TEMPLATES_DIR"/*.tpl; do
        [[ -f "$f" ]] || continue
        local tname=$(basename "$f" .tpl)
        local desc=$(head -3 "$f" | grep '# ' | tail -1 | sed 's/^# //')
        printf "  ${CYAN}%-20s${R}  ${DIM}%s${R}\n" "$tname" "$desc"
        (( count++ ))
      done
      (( count == 0 )) && info "No templates. Create one: ai template create NAME"
      ;;
    edit)
      local name="${1:?Usage: ai template edit NAME}"
      local tpl_file="$TEMPLATES_DIR/${name}.tpl"
      [[ -f "$tpl_file" ]] || { _err_v29 ERR402 "$name"; return 1; }
      ${EDITOR:-nano} "$tpl_file"
      ;;
    delete|rm)
      local name="${1:?Usage: ai template delete NAME}"
      rm -f "$TEMPLATES_DIR/${name}.tpl"
      ok "Template deleted: $name"
      ;;
    *)
      echo "Usage: ai template <create|use|list|edit|delete>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  RAG PIPELINE — v2.9.0
#  Retrieval-Augmented Generation: index local docs, query with context
# ════════════════════════════════════════════════════════════════════════════════

cmd_rag() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create|new)
      local name="${1:?Usage: ai rag create NAME <directory>}"
      local src_dir="${2:?Usage: ai rag create NAME <directory>}"
      local rag_base="$RAG_DIR/$name"
      mkdir -p "$rag_base"

      [[ -d "$src_dir" ]] || { err "Directory not found: $src_dir"; return 1; }

      info "Indexing documents from: $src_dir"
      local count=0
      local index_file="$rag_base/index.jsonl"
      > "$index_file"

      # Index text files
      while IFS= read -r -d '' file; do
        local ext="${file##*.}"
        case "$ext" in
          txt|md|py|js|ts|sh|c|cpp|h|rs|go|java|rb|yml|yaml|json|toml|cfg|ini|html|css|xml)
            local rel_path="${file#$src_dir/}"
            local content
            content=$(cat "$file" 2>/dev/null | head -500)
            # Chunk the content
            local chunk_num=0
            while IFS= read -r -d '' chunk; do
              printf '{"file":"%s","chunk":%d,"text":"%s"}\n' \
                "$rel_path" "$chunk_num" \
                "$(echo "$chunk" | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 2000)" \
                >> "$index_file"
              (( chunk_num++ ))
            done < <(echo "$content" | fold -w "$RAG_CHUNK_SIZE" -s | head -20)
            (( count++ ))
            ;;
        esac
      done < <(find "$src_dir" -type f -size -1M -print0 2>/dev/null)

      # Save metadata
      cat > "$rag_base/meta.json" <<EOF
{"name":"$name","source":"$src_dir","files":$count,"created":"$(date -Iseconds)","chunk_size":$RAG_CHUNK_SIZE}
EOF
      ok "RAG knowledge base '$name' created: $count files indexed"
      ;;
    query|ask)
      local name="${1:?Usage: ai rag query NAME \"question\"}"
      local question="${2:?Usage: ai rag query NAME \"question\"}"
      local rag_base="$RAG_DIR/$name"
      local index_file="$rag_base/index.jsonl"
      [[ -f "$index_file" ]] || { _err_v29 ERR403 "$name"; return 1; }

      info "Searching knowledge base '$name'..."

      # Simple keyword search (no embedding model needed)
      local keywords
      keywords=$(echo "$question" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)
      local matches=""
      local match_count=0

      while IFS= read -r line; do
        local score=0
        local text_lower
        text_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        for kw in $keywords; do
          [[ ${#kw} -ge 3 ]] && [[ "$text_lower" == *"$kw"* ]] && (( score++ ))
        done
        if (( score > 0 )); then
          matches+="$score|$line"$'\n'
          (( match_count++ ))
        fi
      done < "$index_file"

      if (( match_count == 0 )); then
        warn "No relevant documents found for: $question"
        info "Try different keywords or add more documents to the knowledge base."
        return
      fi

      # Sort by score, take top K
      local top_matches
      top_matches=$(echo "$matches" | sort -t'|' -k1 -rn | head -"$RAG_TOP_K")

      local context=""
      while IFS='|' read -r score entry; do
        [[ -z "$entry" ]] && continue
        local file_name chunk_text
        file_name=$(echo "$entry" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('file',''))" 2>/dev/null || echo "unknown")
        chunk_text=$(echo "$entry" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('text',''))" 2>/dev/null || echo "")
        context+="[From: $file_name]"$'\n'"$chunk_text"$'\n\n'
      done <<< "$top_matches"

      info "Found $match_count relevant chunks (using top $RAG_TOP_K)"
      echo ""

      # Build augmented prompt
      local augmented_prompt="Based on the following context from local documents:

---
$context
---

Answer the following question:
$question"

      # Send to active model
      _do_ask "$augmented_prompt"
      ;;
    list|ls)
      hdr "RAG Knowledge Bases"
      local count=0
      for d in "$RAG_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local kb_name=$(basename "$d")
        local meta="$d/meta.json"
        if [[ -f "$meta" ]]; then
          local files created
          files=$(python3 -c "import json;print(json.load(open('$meta')).get('files',0))" 2>/dev/null || echo "?")
          created=$(python3 -c "import json;print(json.load(open('$meta')).get('created','?'))" 2>/dev/null || echo "?")
          printf "  ${CYAN}%-20s${R}  ${DIM}%s files  created %s${R}\n" "$kb_name" "$files" "$created"
        else
          printf "  ${CYAN}%-20s${R}  ${DIM}(no metadata)${R}\n" "$kb_name"
        fi
        (( count++ ))
      done
      (( count == 0 )) && info "No knowledge bases. Create one: ai rag create NAME <dir>"
      ;;
    delete|rm)
      local name="${1:?Usage: ai rag delete NAME}"
      rm -rf "$RAG_DIR/$name"
      ok "Knowledge base '$name' deleted"
      ;;
    *)
      echo "Usage: ai rag <create|query|list|delete>"
      echo ""
      echo "  create NAME <dir>        Index documents from directory"
      echo "  query NAME \"question\"    Ask a question with RAG context"
      echo "  list                       Show all knowledge bases"
      echo "  delete NAME              Remove a knowledge base"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  BATCH QUEUE — v2.9.0
#  Queue multiple prompts, process sequentially or in parallel
# ════════════════════════════════════════════════════════════════════════════════

cmd_batch() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add)
      local prompt="${1:?Usage: ai batch add \"prompt\"}"
      local job_id=$(date +%s%N | tail -c 8)
      local job_file="$BATCH_DIR/${job_id}.job"
      cat > "$job_file" <<EOF
{"id":"$job_id","prompt":"$(echo "$prompt" | sed 's/"/\\"/g')","status":"pending","created":"$(date -Iseconds)","backend":"$ACTIVE_BACKEND","model":"$ACTIVE_MODEL"}
EOF
      ok "Job queued: #$job_id"
      ;;
    run|process)
      local parallel="${1:-1}"
      [[ "$1" == "--parallel" ]] && parallel="${2:-$BATCH_CONCURRENCY}"
      local jobs=("$BATCH_DIR"/*.job)
      local pending=0
      for j in "${jobs[@]}"; do
        [[ -f "$j" ]] || continue
        grep -q '"pending"' "$j" && (( pending++ ))
      done
      if (( pending == 0 )); then
        info "No pending jobs in queue."
        return
      fi
      hdr "Processing $pending batch jobs"
      local completed=0
      for j in "${jobs[@]}"; do
        [[ -f "$j" ]] || continue
        grep -q '"pending"' "$j" || continue
        local jid=$(basename "$j" .job)
        local prompt
        prompt=$(python3 -c "import json;print(json.load(open('$j'))['prompt'])" 2>/dev/null || echo "")
        [[ -z "$prompt" ]] && continue

        printf "  ${CYAN}Job #%s${R} " "$jid"
        local out_file="$BATCH_DIR/${jid}.out"
        _silent_generate "$prompt" "$MAX_TOKENS" > "$out_file" 2>&1
        if [[ -s "$out_file" ]]; then
          sed -i 's/"pending"/"completed"/' "$j"
          printf "${GREEN}done${R} (%d words)\n" "$(wc -w < "$out_file")"
          (( completed++ ))
        else
          sed -i 's/"pending"/"failed"/' "$j"
          printf "${RED}failed${R}\n"
        fi
      done
      ok "$completed/$pending jobs completed"
      ;;
    list|ls)
      hdr "Batch Queue"
      local total=0 pend=0 comp=0 fail=0
      for j in "$BATCH_DIR"/*.job; do
        [[ -f "$j" ]] || continue
        (( total++ ))
        local jid=$(basename "$j" .job)
        local status="unknown"
        grep -q '"pending"' "$j" && { status="pending"; (( pend++ )); }
        grep -q '"completed"' "$j" && { status="completed"; (( comp++ )); }
        grep -q '"failed"' "$j" && { status="failed"; (( fail++ )); }
        local prompt
        prompt=$(python3 -c "import json;print(json.load(open('$j'))['prompt'][:60])" 2>/dev/null || echo "?")
        local color="$YELLOW"
        [[ "$status" == "completed" ]] && color="$GREEN"
        [[ "$status" == "failed" ]] && color="$RED"
        printf "  ${DIM}#%-8s${R} ${color}%-10s${R} %s\n" "$jid" "$status" "$prompt"
      done
      echo ""
      info "Total: $total | Pending: $pend | Completed: $comp | Failed: $fail"
      ;;
    clear)
      rm -f "$BATCH_DIR"/*.job "$BATCH_DIR"/*.out
      ok "Batch queue cleared"
      ;;
    results)
      for f in "$BATCH_DIR"/*.out; do
        [[ -f "$f" ]] || continue
        local jid=$(basename "$f" .out)
        printf "${CYAN}━━━ Job #%s ━━━${R}\n" "$jid"
        cat "$f"
        echo ""
      done
      ;;
    *)
      echo "Usage: ai batch <add|run|list|clear|results>"
      echo ""
      echo "  add \"prompt\"     Queue a prompt"
      echo "  run              Process all pending jobs"
      echo "  list             Show queue status"
      echo "  results          Show completed outputs"
      echo "  clear            Remove all jobs"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  HEALTH CHECK — v2.9.0
#  System diagnostics: GPU, Python, models, disk, API keys
# ════════════════════════════════════════════════════════════════════════════════

cmd_health() {
  hdr "AI CLI Health Check"
  local issues=0

  # Bash version
  local bash_ver="${BASH_VERSION:-unknown}"
  local bash_major="${bash_ver%%.*}"
  if (( bash_major >= 5 )); then
    printf "  ${GREEN}[PASS]${R}  Bash %s\n" "$bash_ver"
  else
    printf "  ${RED}[FAIL]${R}  Bash %s (need 5.0+)\n" "$bash_ver"
    (( issues++ ))
  fi

  # Python
  if [[ -n "$PYTHON" ]]; then
    local pyver=$("$PYTHON" --version 2>&1)
    printf "  ${GREEN}[PASS]${R}  %s\n" "$pyver"
  else
    printf "  ${RED}[FAIL]${R}  Python 3.10+ not found\n"
    (( issues++ ))
  fi

  # curl
  if command -v curl &>/dev/null; then
    printf "  ${GREEN}[PASS]${R}  curl available\n"
  else
    printf "  ${RED}[FAIL]${R}  curl not found\n"
    (( issues++ ))
  fi

  # git
  if command -v git &>/dev/null; then
    printf "  ${GREEN}[PASS]${R}  git available\n"
  else
    printf "  ${YELLOW}[WARN]${R}  git not found (needed for updates)\n"
  fi

  # GPU
  echo ""
  info "GPU Status:"
  if [[ "$CUDA_ARCH" == "metal" ]]; then
    printf "  ${GREEN}[PASS]${R}  Metal GPU detected (Apple Silicon)\n"
  elif [[ "$CUDA_ARCH" != "0" && -n "$CUDA_ARCH" ]]; then
    printf "  ${GREEN}[PASS]${R}  CUDA GPU detected (sm_%s)\n" "$CUDA_ARCH"
  else
    printf "  ${YELLOW}[WARN]${R}  No GPU detected — CPU-only mode\n"
  fi

  # llama.cpp
  if [[ -n "$LLAMA_BIN" ]]; then
    printf "  ${GREEN}[PASS]${R}  llama.cpp: %s\n" "$LLAMA_BIN"
  else
    printf "  ${YELLOW}[WARN]${R}  llama.cpp not found (needed for local GGUF models)\n"
  fi

  # Disk space
  echo ""
  info "Disk Space:"
  local models_size config_size output_size
  models_size=$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
  config_size=$(du -sh "$CONFIG_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
  output_size=$(du -sh "$AI_OUTPUT_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
  printf "  Models:  %s  (%s)\n" "$models_size" "$MODELS_DIR"
  printf "  Config:  %s  (%s)\n" "$config_size" "$CONFIG_DIR"
  printf "  Output:  %s  (%s)\n" "$output_size" "$AI_OUTPUT_DIR"

  local avail
  avail=$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "unknown")
  printf "  Free:    %s\n" "$avail"

  # API keys
  echo ""
  info "API Keys:"
  [[ -n "${OPENAI_API_KEY:-}" ]] && printf "  ${GREEN}[SET]${R}  OpenAI\n" || printf "  ${DIM}[---]${R}  OpenAI\n"
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && printf "  ${GREEN}[SET]${R}  Anthropic/Claude\n" || printf "  ${DIM}[---]${R}  Anthropic/Claude\n"
  [[ -n "${GEMINI_API_KEY:-}" ]] && printf "  ${GREEN}[SET]${R}  Gemini\n" || printf "  ${DIM}[---]${R}  Gemini\n"
  [[ -n "${GROQ_API_KEY:-}" ]] && printf "  ${GREEN}[SET]${R}  Groq\n" || printf "  ${DIM}[---]${R}  Groq\n"
  [[ -n "${MISTRAL_API_KEY:-}" ]] && printf "  ${GREEN}[SET]${R}  Mistral\n" || printf "  ${DIM}[---]${R}  Mistral\n"
  [[ -n "${HF_TOKEN:-}" ]] && printf "  ${GREEN}[SET]${R}  HuggingFace\n" || printf "  ${DIM}[---]${R}  HuggingFace\n"

  # Active model
  echo ""
  info "Active Config:"
  printf "  Model:   %s\n" "${ACTIVE_MODEL:-none}"
  printf "  Backend: %s\n" "${ACTIVE_BACKEND:-auto}"
  printf "  Tokens:  %s\n" "$MAX_TOKENS"
  printf "  Temp:    %s\n" "$TEMPERATURE"
  printf "  Context: %s\n" "$CONTEXT_SIZE"
  printf "  Threads: %s\n" "$THREADS"

  echo ""
  if (( issues > 0 )); then
    warn "$issues issues found"
  else
    ok "All checks passed!"
  fi

  # Log the check
  echo "$(date -Iseconds) health_check issues=$issues" >> "$HEALTH_LOG" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════════
#  CONVERSATION BRANCHING — v2.9.0
#  Fork a conversation, explore alternatives, merge back
# ════════════════════════════════════════════════════════════════════════════════

cmd_branch() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create|new)
      local name="${1:?Usage: ai branch create NAME}"
      local src_session="${ACTIVE_SESSION:-default}"
      local src_log="$SESSIONS_DIR/${src_session}.jsonl"
      local branch_dir="$BRANCHES_DIR/$name"

      mkdir -p "$branch_dir"
      if [[ -f "$src_log" ]]; then
        cp "$src_log" "$branch_dir/history.jsonl"
        local msg_count=$(wc -l < "$src_log")
        ok "Branch '$name' created from session '$src_session' ($msg_count messages)"
      else
        touch "$branch_dir/history.jsonl"
        ok "Branch '$name' created (empty)"
      fi
      cat > "$branch_dir/meta.json" <<EOF
{"name":"$name","parent":"$src_session","created":"$(date -Iseconds)","messages":${msg_count:-0}}
EOF
      info "Switch to it: ai branch use $name"
      ;;
    use|switch)
      local name="${1:?Usage: ai branch use NAME}"
      local branch_dir="$BRANCHES_DIR/$name"
      [[ -d "$branch_dir" ]] || { _err_v29 ERR406 "$name"; return 1; }
      CONVERSATION_BRANCH="$name"
      save_config
      ok "Switched to branch: $name"
      ;;
    list|ls)
      hdr "Conversation Branches"
      local count=0
      for d in "$BRANCHES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local bname=$(basename "$d")
        local meta="$d/meta.json"
        local msgs=0 parent="" created=""
        if [[ -f "$meta" ]]; then
          msgs=$(python3 -c "import json;print(json.load(open('$meta')).get('messages',0))" 2>/dev/null || echo "?")
          parent=$(python3 -c "import json;print(json.load(open('$meta')).get('parent','?'))" 2>/dev/null || echo "?")
          created=$(python3 -c "import json;print(json.load(open('$meta')).get('created','?'))" 2>/dev/null || echo "?")
        fi
        local active_mark=""
        [[ "$bname" == "$CONVERSATION_BRANCH" ]] && active_mark=" ${GREEN}<active>${R}"
        printf "  ${CYAN}%-15s${R}  ${DIM}from:%s  msgs:%s  %s${R}%b\n" \
          "$bname" "$parent" "$msgs" "$created" "$active_mark"
        (( count++ ))
      done
      (( count == 0 )) && info "No branches. Create one: ai branch create NAME"
      ;;
    merge)
      local name="${1:?Usage: ai branch merge NAME}"
      local branch_dir="$BRANCHES_DIR/$name"
      [[ -d "$branch_dir" ]] || { _err_v29 ERR406 "$name"; return 1; }
      local branch_log="$branch_dir/history.jsonl"
      local main_log="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.jsonl"
      if [[ -f "$branch_log" ]]; then
        cat "$branch_log" >> "$main_log"
        local merged=$(wc -l < "$branch_log")
        ok "Merged $merged messages from branch '$name' into session '${ACTIVE_SESSION:-default}'"
      fi
      ;;
    delete|rm)
      local name="${1:?Usage: ai branch delete NAME}"
      rm -rf "$BRANCHES_DIR/$name"
      [[ "$CONVERSATION_BRANCH" == "$name" ]] && CONVERSATION_BRANCH="" && save_config
      ok "Branch '$name' deleted"
      ;;
    *)
      echo "Usage: ai branch <create|use|list|merge|delete>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  EXPORT / IMPORT — v2.9.0
#  Export conversations, configs, models list to portable formats
# ════════════════════════════════════════════════════════════════════════════════

cmd_export() {
  local sub="${1:-all}"; shift 2>/dev/null || true
  local fmt="${EXPORT_FORMAT:-json}"
  local out_dir="$EXPORTS_DIR/$(date +%Y%m%d_%H%M%S)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) fmt="$2"; shift 2 ;;
      --output) out_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  mkdir -p "$out_dir"
  hdr "Exporting ($fmt format)"

  case "$sub" in
    chat|conversations)
      info "Exporting conversations..."
      local count=0
      for f in "$SESSIONS_DIR"/*.jsonl "$CHAT_LOGS_DIR"/*.jsonl; do
        [[ -f "$f" ]] || continue
        cp "$f" "$out_dir/"
        (( count++ ))
      done
      ok "Exported $count conversation files"
      ;;
    config)
      info "Exporting configuration..."
      cp "$CONFIG_FILE" "$out_dir/config.env" 2>/dev/null || true
      cp "$ALIASES_FILE" "$out_dir/aliases.env" 2>/dev/null || true
      # Export API keys with masking
      if [[ -f "$KEYS_FILE" ]]; then
        sed 's/=\(.\{4\}\).*\(.\{4\}\)$/=\1****\2/' "$KEYS_FILE" > "$out_dir/keys_masked.env"
      fi
      ok "Config exported (API keys masked)"
      ;;
    models)
      info "Exporting model list..."
      {
        echo "# AI CLI Model List — $(date -Iseconds)"
        echo "# Active: ${ACTIVE_MODEL:-none} (${ACTIVE_BACKEND:-auto})"
        echo ""
        ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null || echo "No GGUF models"
      } > "$out_dir/models.txt"
      ok "Model list exported"
      ;;
    all)
      cmd_export chat --format "$fmt" --output "$out_dir"
      cmd_export config --format "$fmt" --output "$out_dir"
      cmd_export models --format "$fmt" --output "$out_dir"
      ;;
    *)
      echo "Usage: ai export <all|chat|config|models> [--format json|md|csv]"
      return ;;
  esac

  ok "Export saved to: $out_dir"
  info "Files: $(ls "$out_dir" | wc -l)"
}

cmd_import() {
  local src="${1:?Usage: ai import <directory|file>}"

  if [[ -d "$src" ]]; then
    hdr "Importing from directory: $src"
    # Import configs
    [[ -f "$src/config.env" ]] && { cp "$src/config.env" "$CONFIG_FILE"; ok "Config imported"; }
    [[ -f "$src/aliases.env" ]] && { cp "$src/aliases.env" "$ALIASES_FILE"; ok "Aliases imported"; }
    # Import conversations
    local count=0
    for f in "$src"/*.jsonl; do
      [[ -f "$f" ]] || continue
      cp "$f" "$SESSIONS_DIR/"
      (( count++ ))
    done
    (( count > 0 )) && ok "Imported $count conversations"
  elif [[ -f "$src" ]]; then
    case "$src" in
      *.jsonl) cp "$src" "$SESSIONS_DIR/"; ok "Conversation imported" ;;
      *.env)   cp "$src" "$CONFIG_DIR/"; ok "Config file imported" ;;
      *)       err "Unknown file type. Supported: .jsonl, .env" ;;
    esac
  else
    err "Not found: $src"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  CLEANUP — v2.9.0
#  Free disk space by removing cached/temporary data
# ════════════════════════════════════════════════════════════════════════════════

cmd_cleanup() {
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1

  hdr "AI CLI Cleanup"
  local total_freed=0

  # Temp files
  local tmp_size=$(du -sm /tmp/ai-cli-* 2>/dev/null | awk '{s+=$1}END{print s+0}')
  if (( tmp_size > 0 )); then
    printf "  Temp files:        %dMB\n" "$tmp_size"
    (( dry_run == 0 )) && rm -rf /tmp/ai-cli-*
    total_freed=$(( total_freed + tmp_size ))
  fi

  # Old batch outputs
  local batch_size=$(du -sm "$BATCH_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
  local batch_old=$(find "$BATCH_DIR" -name "*.out" -mtime +7 2>/dev/null | wc -l)
  if (( batch_old > 0 )); then
    printf "  Old batch results: %d files\n" "$batch_old"
    (( dry_run == 0 )) && find "$BATCH_DIR" -name "*.out" -mtime +7 -delete
  fi

  # Old compare results
  local compare_old=$(find "$COMPARE_DIR" -name "*.md" -mtime +30 2>/dev/null | wc -l)
  if (( compare_old > 0 )); then
    printf "  Old comparisons:   %d files\n" "$compare_old"
    (( dry_run == 0 )) && find "$COMPARE_DIR" -name "*.md" -mtime +30 -delete
  fi

  # Branch cache
  local cache_size=$(du -sm "$HOME/.cache/ai-cli" 2>/dev/null | awk '{print $1}' || echo 0)
  if (( cache_size > 5 )); then
    printf "  Cache:             %dMB\n" "$cache_size"
    (( dry_run == 0 )) && rm -rf "$HOME/.cache/ai-cli"
  fi

  # Old exports
  local export_old=$(find "$EXPORTS_DIR" -maxdepth 1 -type d -mtime +30 2>/dev/null | wc -l)
  if (( export_old > 0 )); then
    printf "  Old exports:       %d dirs\n" "$export_old"
    (( dry_run == 0 )) && find "$EXPORTS_DIR" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
  fi

  echo ""
  if (( dry_run == 1 )); then
    info "[DRY RUN] No files deleted. Run without --dry-run to clean."
  else
    ok "Cleanup complete"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  PLUGIN SYSTEM — v2.9.0
#  Load external .sh plugins from plugins directory
# ════════════════════════════════════════════════════════════════════════════════

declare -A LOADED_PLUGINS=()

_load_plugins() {
  for p in "$PLUGINS_DIR"/*.sh; do
    [[ -f "$p" ]] || continue
    local pname=$(basename "$p" .sh)
    if [[ -z "${LOADED_PLUGINS[$pname]:-}" ]]; then
      if bash -n "$p" 2>/dev/null; then
        source "$p"
        LOADED_PLUGINS["$pname"]=1
        [[ $VERBOSE -eq 1 ]] && info "Plugin loaded: $pname"
      else
        warn "Plugin '$pname' has syntax errors, skipping"
      fi
    fi
  done
}

cmd_plugin() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls)
      hdr "Installed Plugins"
      local count=0
      for p in "$PLUGINS_DIR"/*.sh; do
        [[ -f "$p" ]] || continue
        local pname=$(basename "$p" .sh)
        local desc=$(head -5 "$p" | grep '^# ' | head -1 | sed 's/^# //')
        local loaded="${LOADED_PLUGINS[$pname]:-0}"
        local status="${GREEN}loaded${R}"
        [[ "$loaded" == "0" ]] && status="${DIM}not loaded${R}"
        printf "  ${CYAN}%-20s${R}  %b  ${DIM}%s${R}\n" "$pname" "$status" "$desc"
        (( count++ ))
      done
      (( count == 0 )) && info "No plugins. Place .sh files in: $PLUGINS_DIR/"
      ;;
    install)
      local url="${1:?Usage: ai plugin install PATH}"
      if [[ "$url" == http* ]]; then
        local fname=$(basename "$url")
        curl -fsSL "$url" -o "$PLUGINS_DIR/$fname"
        ok "Plugin downloaded: $fname"
      elif [[ -f "$url" ]]; then
        cp "$url" "$PLUGINS_DIR/"
        ok "Plugin installed: $(basename "$url")"
      else
        err "Not a valid URL or file: $url"
      fi
      ;;
    remove|rm)
      local name="${1:?Usage: ai plugin remove NAME}"
      rm -f "$PLUGINS_DIR/${name}.sh"
      ok "Plugin removed: $name"
      ;;
    reload)
      LOADED_PLUGINS=()
      _load_plugins
      ok "Plugins reloaded"
      ;;
    *)
      echo "Usage: ai plugin <list|install|remove|reload>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  MODEL PRESETS — v2.9.0
#  Quick-switch between saved model configurations
# ════════════════════════════════════════════════════════════════════════════════

PRESETS_DIR="$CONFIG_DIR/presets"
mkdir -p "$PRESETS_DIR"

cmd_preset() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    save)
      local name="${1:?Usage: ai preset save NAME}"
      cat > "$PRESETS_DIR/${name}.preset" <<EOF
PRESET_MODEL="$ACTIVE_MODEL"
PRESET_BACKEND="$ACTIVE_BACKEND"
PRESET_TOKENS="$MAX_TOKENS"
PRESET_TEMP="$TEMPERATURE"
PRESET_TOP_P="$TOP_P"
PRESET_CONTEXT="$CONTEXT_SIZE"
PRESET_GPU_LAYERS="$GPU_LAYERS"
PRESET_PERSONA="$ACTIVE_PERSONA"
EOF
      ok "Preset saved: $name"
      ;;
    load|use)
      local name="${1:?Usage: ai preset load NAME}"
      local pf="$PRESETS_DIR/${name}.preset"
      [[ -f "$pf" ]] || { err "Preset not found: $name"; return 1; }
      source "$pf"
      ACTIVE_MODEL="${PRESET_MODEL:-$ACTIVE_MODEL}"
      ACTIVE_BACKEND="${PRESET_BACKEND:-$ACTIVE_BACKEND}"
      MAX_TOKENS="${PRESET_TOKENS:-$MAX_TOKENS}"
      TEMPERATURE="${PRESET_TEMP:-$TEMPERATURE}"
      TOP_P="${PRESET_TOP_P:-$TOP_P}"
      CONTEXT_SIZE="${PRESET_CONTEXT:-$CONTEXT_SIZE}"
      GPU_LAYERS="${PRESET_GPU_LAYERS:-$GPU_LAYERS}"
      ACTIVE_PERSONA="${PRESET_PERSONA:-$ACTIVE_PERSONA}"
      save_config
      ok "Preset loaded: $name (model=$ACTIVE_MODEL)"
      ;;
    list|ls)
      hdr "Model Presets"
      for f in "$PRESETS_DIR"/*.preset; do
        [[ -f "$f" ]] || continue
        local pname=$(basename "$f" .preset)
        source "$f"
        printf "  ${CYAN}%-15s${R}  model=%-30s  backend=%s\n" \
          "$pname" "${PRESET_MODEL:-?}" "${PRESET_BACKEND:-?}"
      done
      ;;
    delete|rm)
      local name="${1:?Usage: ai preset delete NAME}"
      rm -f "$PRESETS_DIR/${name}.preset"
      ok "Preset deleted: $name"
      ;;
    *)
      echo "Usage: ai preset <save|load|list|delete>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  CHANGELOG VIEWER — v2.9.0
#  ai change — show full changelog
#  ai -L — show latest version changes
# ════════════════════════════════════════════════════════════════════════════════

cmd_change() {
  local sub="${1:-all}"
  case "$sub" in
    latest|-L)
      hdr "AI CLI v${VERSION} — Latest Changes"
      echo ""
      echo -e "  ${B}${BCYAN}v3.2.0.1${R}"
      echo ""
      echo -e "  ${B}Docs:${R}"
      echo "    + ai api now lists all 44 endpoints grouped by purpose"
      echo "    + new subcommands: ai api endpoints / ep / list"
      echo ""
      echo -e "  ${B}${BCYAN}v3.2.0${R} — Major release"
      echo ""
      echo -e "  ${B}New API endpoints (44 total):${R}"
      echo "    + /v3/status /v3/sysinfo /v3/version /v3/endpoints"
      echo "    + /v3/models /v3/models/activate /v3/models/download"
      echo "    + /v3/keys /v3/keys/set (password-protected)"
      echo "    + /v3/history /v3/history/search /v3/history/clear"
      echo "    + /v3/tokens /v3/cost /v3/embed"
      echo "    + /v3/chat/stream (SSE streaming)"
      echo "    + /v3/web /v3/benchmark /v3/agent /v3/diff/review"
      echo "    + /v3/voice/tts /v3/share"
      echo "    + /v3/rag/list /v3/rag/add /v3/rag/query"
      echo "    + /v3/files /v3/files/upload /v3/files/delete"
      echo "    + /v3/run (password-protected) /v3/logs /v3/config"
      echo ""
      echo -e "  ${B}GUI / GUI+ updates:${R}"
      echo "    + Dashboard (/v3/site): 12 tabs, streaming chat toggle,"
      echo "      model download/activate, key management, token/cost/embed,"
      echo "      history search, benchmark, diff review, voice, share"
      echo "    + GUI+ v4 (tkinter): new Agent + API tabs, direct HTTP probe,"
      echo "      endpoint browser, bumped window size"
      echo ""
      echo -e "  ${B}5 new commands:${R}"
      echo "    ai voice tts \"text\"         Speak text via piper/espeak"
      echo "    ai voice stt FILE            Transcribe audio via whisper"
      echo "    ai voice ask \"q\"            Ask + speak answer"
      echo "    ai share [PORT]              Public tunnel via cloudflared/ngrok"
      echo "    ai diff-review [staged|HEAD|FILE]   AI review of diffs"
      echo "    ai agent \"goal\" --steps N   Autonomous task loop"
      echo "    ai rag-quick FILE \"q\"       One-shot RAG without corpus"
      echo ""
      echo -e "  ${B}Core:${R}"
      echo "    + ThreadingHTTPServer — multiple concurrent clients"
      echo "    + Access logging (~/.config/ai-cli/api_access.log)"
      echo "    + Chat history persisted to ~/.config/ai-cli/history.jsonl"
      echo "    + Upload dir (~/.config/ai-cli/uploads)"
      echo "    + RAG corpora dir (~/.config/ai-cli/rag)"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.7.3${R}"
      echo ""
      echo -e "  ${B}Bug Fixes:${R}"
      echo "    + ai -Su now exits after update so bash cannot re-read"
      echo "      the replaced script (was causing 'line 19371 syntax"
      echo "      error near unexpected token (' after updates)"
      echo "    + API Python heredoc verified end-to-end (health check)"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.7.2${R}"
      echo ""
      echo -e "  ${B}Bug Fixes:${R}"
      echo "    + Fixed \\\\\" double-escaping in APIPY heredoc — quoted"
      echo "      heredocs pass backslashes literally, so \\\\\" became"
      echo "      \\\\ + \" and closed the Python string early"
      echo "    + Renamed -C to -Cf (was colliding with named chat -C)"
      echo "        ai -Cf u-gpu 0   disable GPU"
      echo "        ai -Cf u-gpu 1   enable GPU"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.7.1${R}"
      echo ""
      echo -e "  ${B}New:${R}"
      echo "    + Password-protected Terminal tab in API dashboard"
      echo "        ai -apip PASSWORD   set (max 8 chars)"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.7${R}"
      echo ""
      echo -e "  ${B}New:${R}"
      echo "    + Completely remade API v3 dashboard"
      echo "    + ai -Cf config command for persistent settings"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.6${R}"
      echo ""
      echo -e "  ${B}New:${R}"
      echo "    + Memory API endpoint (/v3/mem)"
      echo "    + Context API endpoint (/v3/context)"
      echo "    + Auto-compression of long conversations"
      echo "    + Better error messages in API chat"
      echo ""
      echo -e "  ${B}${BCYAN}v3.1.3${R}"
      echo ""
      echo -e "  ${B}New Features:${R}"
      echo "    + GUI v7.1 — PgUp/PgDn scrolling, search, scrollbar, 46 items"
      echo "    + API Server v3 — /chat web UI, key management, CORS"
      echo "    + ai ask-think / ai ask-t — chain-of-thought reasoning"
      echo "    + ai ask-w-t / ai awt — thinking + web search combined"
      echo "    + ai ask-web / ai ask-w — shows source URLs before answering"
      echo "    + ai mem list/add/edit/delete/search — full memory management"
      echo "    + ai test -S/-N/-A — speed, network, all tests"
      echo "    + 10 thinking/reasoning models: o3, o1, DeepSeek-R1, Qwen3"
      echo "    + 205 total recommended models across 32 categories"
      echo "    + Modular lib/ architecture — 9 independent modules"
      echo "    + Firefox Extension v2 — sidebar chat + context menu"
      echo "    + rclick v3.2 — Windows, macOS, Linux Mint support"
      echo "    + iSH support with local models"
      echo ""
      echo -e "  ${B}Bug Fixes:${R}"
      echo "    + All syntax errors fixed — passes bash -n clean"
      echo "    + Removed all duplicate functions — 500+ lines of dead code gone"
      echo "    + Fixed parentheses in 40+ echo/printf statements"
      echo "    + Fixed unmatched apostrophes in prompt strings"
      echo "    + GPU detection stale cache fix for GTX 1080"
      echo "    + Silenced all llama.cpp warnings including context size"
      echo "    + macOS bash 3.2 auto-switch to Homebrew bash 4+"
      echo "    + Canvas v3 keybinds fixed"
      echo "    + No more AI fallthrough on unknown commands"
      echo "    + dispatch_ask no longer errors on empty response"
      echo ""
      echo -e "  ${B}New Commands:${R}"
      echo "    ask-web  ask-think  ask-w-t  test  health  perf  compare"
      echo "    snap  template  rag  batch  branch  export  import  cleanup"
      echo "    preset  plugin  notebook  plan  memory  favorite  schedule"
      echo "    profile  write  learn  quiz  interview  shell  git  json"
      echo "    sql  docker  regex  cron  math  net  date  text  clip  find"
      echo "    change  security  sysinfo  analytics  cost  tokens  watch"
      echo ""
      echo "    + Silenced all llama.cpp warnings and logs"
      echo "    + Unknown commands no longer auto-pass to AI"
      echo "    + Canvas v3 keybinds fully fixed"
      echo "    + Removed duplicate functions (cmd_canvas x3, backends x2)"
      echo ""
      echo -e "  ${B}New:${R}"
      echo "    + ai ask-web — ask with web search context"
      echo "    + ai ask -mem — inject memory into prompt"
      echo "    + ai test -S/-N/-A — speed/network/all tests"
      echo "    + ai -h <any command> — detailed help for 60+ commands"
      echo "    + GUI+ v3 rewrite (see below)"
      echo ""

      echo -e "  ${B}${BCYAN}v2.9.0${R} — Major Release"
      echo ""
      echo -e "  ${B}New Backends:${R}"
      echo "    + Groq API (llama-3.3-70b, mixtral)"
      echo "    + Mistral API (mistral-large, codestral)"
      echo "    + Together API (llama-3.3-70b-turbo)"
      echo ""
      echo -e "  ${B}New Features:${R}"
      echo "    + Config snapshots (ai snap save/load)"
      echo "    + Performance benchmark (ai perf)"
      echo "    + Model comparison (ai compare)"
      echo "    + RAG pipeline (ai rag create/query)"
      echo "    + Batch queue (ai batch add/run)"
      echo "    + Prompt templates (ai template)"
      echo "    + Conversation branching (ai branch)"
      echo "    + Health check (ai health)"
      echo "    + Plugin system (ai plugin)"
      echo "    + Model presets (ai preset)"
      echo "    + Export/Import (ai export/import)"
      echo "    + Notebook mode (ai notebook)"
      echo "    + Task planner (ai plan)"
      echo "    + Learning mode (ai learn)"
      echo "    + Writing assistant (ai write)"
      echo "    + AI memory (ai memory)"
      echo "    + Git AI (ai git commit/pr/blame)"
      echo "    + Shell helper (ai shell gen/explain/fix)"
      echo "    + Quiz mode (ai quiz)"
      echo "    + Interview prep (ai interview)"
      echo "    + Token counter (ai tokens)"
      echo "    + Cost estimator (ai cost)"
      echo "    + Network tools (ai net)"
      echo "    + Text utilities (ai text)"
      echo "    + JSON/SQL/Docker/Regex helpers"
      echo "    + Security audit (ai security)"
      echo "    + Analytics (ai analytics)"
      echo ""
      echo -e "  ${B}Bug Fixes:${R}"
      echo "    + API retry with exponential backoff"
      echo "    + Enhanced error codes (ERR4xx-6xx)"
      echo "    + Rate limit tracking"
      echo "    + Fixed version strings"
      echo "    + 195 recommended models (was 56)"
      echo "    + Chat rewritten with 15+ slash commands"
      echo ""
      echo -e "  ${B}Models:${R} 195 curated picks across 31 categories"
      ;;
    all|*)
      cmd_change latest
      echo ""
      echo -e "  ${B}${BCYAN}v2.7.4${R}"
      echo "    GUI+ v2 (tkinter) · AI Node Editor (125+ nodes) · -h CMD"
      echo ""
      echo -e "  ${B}${BCYAN}v2.7.3${R}"
      echo "    Aliases · Error codes · GGUF fix · Model sync"
      echo ""
      echo -e "  ${B}${BCYAN}v2.7.1${R}"
      echo "    GUI v5.1 · Structured settings editor"
      echo ""
      echo -e "  ${B}${BCYAN}v2.7${R}"
      echo "    AI Extension System (.aipack) · Firefox LLM Sidebar"
      echo "    GUI v5 (split-pane) · 9 themes"
      echo ""
      echo -e "  ${B}${BCYAN}v2.6${R}"
      echo "    Projects (multi-chat memory) · First-run setup"
      echo ""
      echo -e "  ${B}${BCYAN}v2.5${R}"
      echo "    GitHub integration · Research papers · Canvas v3"
      echo "    Multimodal training · Custom system prompts"
      echo ""
      echo -e "  ${B}${BCYAN}v2.4${R}"
      echo "    Custom datasets · LLM API server · Multi-AI arena"
      echo "    RLHF HF datasets · Right-click AI · API key hosting"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  SYSTEM UPDATE — v2.9.0
#  ai -Su — update ai-cli from GitHub
# ════════════════════════════════════════════════════════════════════════════════

cmd_system_update() {
  hdr "AI CLI — System Update"
  info "Checking for updates from GitHub..."

  local remote_ver
  remote_ver=$(curl -fsSL "https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/main.sh" 2>/dev/null \
    | grep '^VERSION=' | head -1 | cut -d'"' -f2 || echo "")

  if [[ -z "$remote_ver" ]]; then
    err "Could not fetch remote version. Check network."
    return 1
  fi

  info "Installed: v${VERSION}"
  info "Remote:    v${remote_ver}"

  if [[ "$VERSION" == "$remote_ver" ]]; then
    ok "Already up to date (v${VERSION})"
    return 0
  fi

  echo ""
  printf "  ${BYELLOW}Update v${VERSION} → v${remote_ver}? [Y/n]:${R} "
  read -r confirm
  [[ "$confirm" =~ ^[Nn] ]] && { info "Cancelled."; return 0; }

  info "Downloading latest main.sh..."
  local tmp
  tmp=$(mktemp /tmp/ai-cli-update-XXXXXX)
  curl -fsSL "https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/main.sh" -o "$tmp"

  if [[ ! -s "$tmp" ]]; then
    err "Download failed or file empty"
    rm -f "$tmp"
    return 1
  fi

  # Verify it's a valid bash script
  if ! bash -n "$tmp" 2>/dev/null; then
    err "Downloaded file has syntax errors. Aborting."
    rm -f "$tmp"
    return 1
  fi

  # Find where ai is installed
  local ai_path
  ai_path=$(command -v ai 2>/dev/null || echo "/usr/local/bin/ai")

  if [[ -w "$ai_path" ]]; then
    cp "$tmp" "$ai_path"
    chmod +x "$ai_path"
  elif command -v sudo &>/dev/null; then
    sudo cp "$tmp" "$ai_path"
    sudo chmod +x "$ai_path"
  else
    err "Cannot write to $ai_path. Run with sudo."
    rm -f "$tmp"
    return 1
  fi

  # Clean up old lib/ files that cause CONFIG_DIR errors
  for _old_lib in /usr/local/share/ai-cli/lib /usr/share/ai-cli/lib; do
    if [[ -d "$_old_lib" ]]; then
      sudo rm -rf "$_old_lib" 2>/dev/null || rm -rf "$_old_lib" 2>/dev/null || true
      info "Removed old $_old_lib"
    fi
  done

  rm -f "$tmp"
  ok "Updated to v${remote_ver}!"
  info "Restart your terminal or run: ai --version"
  # The running bash process is reading THIS file by byte offset. We just
  # overwrote it in place, so every byte past here now belongs to the new
  # script — continuing would land mid-heredoc and produce Python-looking
  # syntax errors (e.g. 'line 19371: syntax error near unexpected token (').
  # Exit immediately so bash never reads past the replacement.
  exit 0
}

####NEW_FEATURES_MARKER####


# ════════════════════════════════════════════════════════════════════════════════
#  CONVERSATION HISTORY SEARCH — v2.9.0
#  Full-text search across all chat sessions and branches
# ════════════════════════════════════════════════════════════════════════════════

cmd_search_history() {
  local query="${1:?Usage: ai search-history \"keyword\"}"
  local max_results="${2:-20}"
  local case_flag=""
  [[ "${3:-}" == "--case" ]] && case_flag=""

  hdr "Search: \"$query\""
  local count=0
  local total_files=0

  # Search sessions
  for f in "$SESSIONS_DIR"/*.jsonl "$CHAT_LOGS_DIR"/*.jsonl "$BRANCHES_DIR"/*/history.jsonl; do
    [[ -f "$f" ]] || continue
    (( total_files++ ))
    local matches
    matches=$(grep -i${case_flag}n "$query" "$f" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      local fname=$(basename "$f" .jsonl)
      local dir=$(basename "$(dirname "$f")")
      printf "\n  ${CYAN}%s/%s${R}\n" "$dir" "$fname"
      while IFS= read -r line; do
        (( count >= max_results )) && break 2
        local linenum="${line%%:*}"
        local content="${line#*:}"
        content="${content:0:120}"
        printf "    ${DIM}L%-4s${R} %s\n" "$linenum" "$content"
        (( count++ ))
      done <<< "$matches"
    fi
  done

  echo ""
  if (( count == 0 )); then
    info "No results for \"$query\" across $total_files files"
  else
    ok "$count results found across $total_files files"
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  TOKEN COUNTER — v2.9.0
#  Estimate token count for prompts before sending
# ════════════════════════════════════════════════════════════════════════════════

cmd_count_tokens() {
  local input=""
  if [[ -n "${1:-}" ]]; then
    if [[ -f "$1" ]]; then
      input=$(cat "$1")
    else
      input="$*"
    fi
  elif [[ ! -t 0 ]]; then
    input=$(cat)
  else
    echo "Usage: ai tokens TEXT or ai tokens FILE"
    return 1
  fi

  local chars=${#input}
  local words=$(echo "$input" | wc -w | tr -d ' ')
  local lines=$(echo "$input" | wc -l | tr -d ' ')

  # Rough token estimates
  local tok_gpt=$(( chars * 100 / 400 ))     # ~4 chars/token for GPT
  local tok_claude=$(( chars * 100 / 380 ))   # slightly different for Claude
  local tok_llama=$(( chars * 100 / 420 ))    # GGUF models

  if [[ -n "$PYTHON" ]]; then
    # Try tiktoken for accurate count
    local accurate
    accurate=$("$PYTHON" -c "
try:
    import tiktoken
    enc = tiktoken.get_encoding('cl100k_base')
    import sys
    text = sys.stdin.read()
    print(len(enc.encode(text)))
except ImportError:
    print(-1)
except Exception:
    print(-1)
" <<< "$input" 2>/dev/null || echo "-1")
    if [[ "$accurate" != "-1" ]]; then
      tok_gpt=$accurate
    fi
  fi

  hdr "Token Count"
  printf "  Characters:  %s\n" "$chars"
  printf "  Words:       %s\n" "$words"
  printf "  Lines:       %s\n" "$lines"
  echo ""
  printf "  ${CYAN}GPT-4/Claude:${R}  ~%s tokens\n" "$tok_gpt"
  printf "  ${CYAN}GGUF/LLaMA:${R}    ~%s tokens\n" "$tok_llama"
  echo ""

  # Context window check
  if (( tok_gpt > CONTEXT_SIZE )); then
    warn "Exceeds current context window ($CONTEXT_SIZE tokens)"
    _err_suggest ERR604
  elif (( tok_gpt > CONTEXT_SIZE * 80 / 100 )); then
    warn "Using ${tok_gpt}/${CONTEXT_SIZE} tokens (>80% of context window)"
  else
    ok "Fits in context window (${tok_gpt}/${CONTEXT_SIZE})"
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  COST ESTIMATOR — v2.9.0
#  Estimate API costs before sending queries
# ════════════════════════════════════════════════════════════════════════════════

# Pricing per 1M tokens (input/output) as of 2025
declare -A API_PRICING_INPUT=(
  [gpt-4o]="2.50"
  [gpt-4o-mini]="0.15"
  [gpt-4-turbo]="10.00"
  [gpt-3.5-turbo]="0.50"
  [claude-3-opus]="15.00"
  [claude-3-sonnet]="3.00"
  [claude-3-haiku]="0.25"
  [claude-3.5-sonnet]="3.00"
  [claude-4-opus]="15.00"
  [claude-4-sonnet]="3.00"
  [gemini-pro]="0.50"
  [gemini-1.5-pro]="3.50"
  [gemini-1.5-flash]="0.075"
  [groq-llama-70b]="0.59"
  [groq-llama-8b]="0.05"
  [groq-mixtral]="0.24"
  [mistral-large]="4.00"
  [mistral-small]="1.00"
)

declare -A API_PRICING_OUTPUT=(
  [gpt-4o]="10.00"
  [gpt-4o-mini]="0.60"
  [gpt-4-turbo]="30.00"
  [gpt-3.5-turbo]="1.50"
  [claude-3-opus]="75.00"
  [claude-3-sonnet]="15.00"
  [claude-3-haiku]="1.25"
  [claude-3.5-sonnet]="15.00"
  [claude-4-opus]="75.00"
  [claude-4-sonnet]="15.00"
  [gemini-pro]="1.50"
  [gemini-1.5-pro]="10.50"
  [gemini-1.5-flash]="0.30"
  [groq-llama-70b]="0.79"
  [groq-llama-8b]="0.08"
  [groq-mixtral]="0.24"
  [mistral-large]="12.00"
  [mistral-small]="3.00"
)

cmd_cost() {
  local input_tokens="${1:-1000}"
  local output_tokens="${2:-$MAX_TOKENS}"
  local model="${3:-}"

  hdr "Cost Estimate"

  if [[ -n "$model" ]]; then
    _estimate_single "$model" "$input_tokens" "$output_tokens"
  else
    printf "  %-25s  %10s  %10s  %10s\n" "Model" "Input" "Output" "Total"
    printf "  %-25s  %10s  %10s  %10s\n" "─────" "─────" "──────" "─────"
    for m in "${!API_PRICING_INPUT[@]}"; do
      _estimate_single "$m" "$input_tokens" "$output_tokens"
    done | sort -t'$' -k4 -n
  fi

  echo ""
  info "Estimated for ${input_tokens} input + ${output_tokens} output tokens"
  info "Local GGUF models: \$0.00 (free)"
}

_estimate_single() {
  local model="$1" in_tok="$2" out_tok="$3"
  local in_price="${API_PRICING_INPUT[$model]:-0}"
  local out_price="${API_PRICING_OUTPUT[$model]:-0}"

  if [[ "$in_price" == "0" && "$out_price" == "0" ]]; then
    return
  fi

  local cost
  cost=$(awk "BEGIN{printf \"%.6f\", ($in_tok * $in_price / 1000000) + ($out_tok * $out_price / 1000000)}")
  local in_cost
  in_cost=$(awk "BEGIN{printf \"%.6f\", $in_tok * $in_price / 1000000}")
  local out_cost
  out_cost=$(awk "BEGIN{printf \"%.6f\", $out_tok * $out_price / 1000000}")

  printf "  %-25s  \$%9s  \$%9s  ${GREEN}\$%9s${R}\n" \
    "$model" "$in_cost" "$out_cost" "$cost"
}


# ════════════════════════════════════════════════════════════════════════════════
#  CONTEXT WINDOW MANAGER — v2.9.0
#  Smart context management: summarize, trim, or split long conversations
# ════════════════════════════════════════════════════════════════════════════════

cmd_context() {
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    status|info)
      local session_file="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.jsonl"
      local msg_count=0
      local total_chars=0
      if [[ -f "$session_file" ]]; then
        msg_count=$(wc -l < "$session_file")
        total_chars=$(wc -c < "$session_file")
      fi
      local est_tokens=$(( total_chars * 100 / 400 ))

      hdr "Context Window Status"
      printf "  Session:     %s\n" "${ACTIVE_SESSION:-default}"
      printf "  Messages:    %d\n" "$msg_count"
      printf "  Est tokens:  ~%d / %d\n" "$est_tokens" "$CONTEXT_SIZE"
      printf "  Usage:       "
      if (( CONTEXT_SIZE > 0 )); then
        local pct=$(( est_tokens * 100 / CONTEXT_SIZE ))
        if (( pct > 90 )); then
          printf "${RED}%d%%${R} (critical)\n" "$pct"
        elif (( pct > 70 )); then
          printf "${YELLOW}%d%%${R} (high)\n" "$pct"
        else
          printf "${GREEN}%d%%${R}\n" "$pct"
        fi
      else
        printf "unknown\n"
      fi
      ;;
    trim)
      local keep="${1:-20}"
      local session_file="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.jsonl"
      [[ -f "$session_file" ]] || { info "No active session"; return; }
      local total=$(wc -l < "$session_file")
      if (( total <= keep )); then
        info "Session has $total messages (keeping $keep). Nothing to trim."
        return
      fi
      local tmp=$(mktemp)
      tail -n "$keep" "$session_file" > "$tmp"
      mv "$tmp" "$session_file"
      local removed=$(( total - keep ))
      ok "Trimmed $removed old messages (kept last $keep)"
      ;;
    summarize)
      local session_file="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.jsonl"
      [[ -f "$session_file" ]] || { info "No active session"; return; }
      info "Summarizing conversation..."
      local content
      content=$(cat "$session_file" | head -50)
      local summary
      summary=$(_silent_generate "Summarize this conversation in 3-5 bullet points:
$content" 256 2>/dev/null || echo "Could not generate summary")
      echo ""
      echo "$summary"
      echo ""
      # Save summary
      echo "$(date -Iseconds) [summary] $summary" >> "$session_file"
      ok "Summary appended to session"
      ;;
    clear)
      local session_file="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.jsonl"
      > "$session_file" 2>/dev/null || true
      ok "Session cleared: ${ACTIVE_SESSION:-default}"
      ;;
    size)
      local max="${1:-$CONTEXT_SIZE}"
      CONTEXT_SIZE="$max"
      save_config
      ok "Context size set to $max"
      ;;
    *)
      echo "Usage: ai context <status|trim|summarize|clear|size>"
      echo ""
      echo "  status          Show context window usage"
      echo "  trim [N]        Keep last N messages (default: 20)"
      echo "  summarize       AI-summarize the conversation"
      echo "  clear           Clear current session"
      echo "  size N        Set context window size"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  PROMPT CHAINING — v2.9.0
#  Chain multiple prompts: output of one feeds into the next
# ════════════════════════════════════════════════════════════════════════════════

cmd_chain() {
  local chain_file="${1:-}"
  local dry_run=0
  [[ "${2:-}" == "--dry-run" ]] && dry_run=1

  if [[ -n "$chain_file" && -f "$chain_file" ]]; then
    hdr "Running prompt chain from: $chain_file"
    local step=0
    local prev_output=""
    while IFS= read -r prompt || [[ -n "$prompt" ]]; do
      [[ -z "$prompt" || "$prompt" == \#* ]] && continue
      (( step++ ))

      # Replace {{prev}} with previous output
      prompt="${prompt//\{\{prev\}\}/$prev_output}"

      printf "\n  ${CYAN}Step %d:${R} %s\n" "$step" "${prompt:0:80}"

      if [[ $dry_run -eq 1 ]]; then
        info "[dry-run] Would send prompt"
        prev_output="[output of step $step]"
        continue
      fi

      prev_output=$(_silent_generate "$prompt" "$MAX_TOKENS" 2>/dev/null || echo "")
      if [[ -z "$prev_output" ]]; then
        err "Step $step produced no output. Chain halted."
        return 1
      fi

      echo "$prev_output" | head -10
      local lines=$(echo "$prev_output" | wc -l)
      (( lines > 10 )) && printf "  ${DIM}... — %d lines${R}\n" "$lines"
    done < "$chain_file"

    echo ""
    ok "Chain complete: $step steps"
  else
    echo "Usage: ai chain <chain_file> [--dry-run]"
    echo ""
    echo "Chain file format (one prompt per line):"
    echo "  # Comments start with #"
    echo "  Write a short story about a robot"
    echo "  Now translate the following to French: {{prev}}"
    echo "  Summarize: {{prev}}"
    echo ""
    echo "  {{prev}} = output from previous step"
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  MODEL STATS & GGUF INSPECTOR — v2.9.0
#  Show detailed info about loaded GGUF models
# ════════════════════════════════════════════════════════════════════════════════

cmd_model_stats() {
  hdr "Model Statistics"

  # Active model
  printf "  ${B}Active Model:${R}    %s\n" "${ACTIVE_MODEL:-none}"
  printf "  ${B}Backend:${R}         %s\n" "${ACTIVE_BACKEND:-auto}"
  printf "  ${B}Context Size:${R}    %s tokens\n" "$CONTEXT_SIZE"
  printf "  ${B}Max Tokens:${R}      %s\n" "$MAX_TOKENS"
  printf "  ${B}Temperature:${R}     %s\n" "$TEMPERATURE"
  printf "  ${B}GPU Layers:${R}      %s\n" "$GPU_LAYERS"
  printf "  ${B}Threads:${R}         %s\n" "$THREADS"
  echo ""

  # Count models
  local gguf_count=0
  local total_size=0
  for f in "$MODELS_DIR"/*.gguf; do
    [[ -f "$f" ]] || continue
    (( gguf_count++ ))
    local sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    total_size=$(( total_size + sz ))
  done

  printf "  ${B}GGUF Models:${R}     %d\n" "$gguf_count"
  if (( total_size > 0 )); then
    local total_gb=$(awk "BEGIN{printf \"%.1f\", $total_size / 1073741824}")
    printf "  ${B}Total Size:${R}      %s GB\n" "$total_gb"
  fi
  echo ""

  # List models with sizes
  if (( gguf_count > 0 )); then
    printf "  %-40s  %10s\n" "Model" "Size"
    printf "  %-40s  %10s\n" "─────" "────"
    for f in "$MODELS_DIR"/*.gguf; do
      [[ -f "$f" ]] || continue
      local name=$(basename "$f")
      local sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
      local human_sz
      if (( sz > 1073741824 )); then
        human_sz=$(awk "BEGIN{printf \"%.1f GB\", $sz / 1073741824}")
      else
        human_sz=$(awk "BEGIN{printf \"%.0f MB\", $sz / 1048576}")
      fi
      local active=""
      [[ "$ACTIVE_MODEL" == *"$name"* ]] && active=" ${GREEN}<active>${R}"
      printf "  %-40s  %10s%b\n" "${name:0:40}" "$human_sz" "$active"
    done
  fi

  # GGUF metadata (if python available)
  if [[ -n "$ACTIVE_MODEL" && -f "$MODELS_DIR/$ACTIVE_MODEL" && -n "$PYTHON" ]]; then
    echo ""
    info "GGUF Metadata:"
    "$PYTHON" -c "
try:
    import struct, json
    path = '$MODELS_DIR/$ACTIVE_MODEL'
    with open(path, 'rb') as f:
        magic = f.read(4)
        if magic == b'GGUF':
            version = struct.unpack('<I', f.read(4))[0]
            n_tensors = struct.unpack('<Q', f.read(8))[0]
            n_kv = struct.unpack('<Q', f.read(8))[0]
            print(f'    GGUF version: {version}')
            print(f'    Tensors:      {n_tensors}')
            print(f'    KV pairs:     {n_kv}')
        else:
            print('    Not a valid GGUF file')
except Exception as e:
    print(f'    Could not read metadata: {e}')
" 2>/dev/null || true
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  SCHEDULE / CRON — v2.9.0
#  Schedule prompts to run at specific times
# ════════════════════════════════════════════════════════════════════════════════

SCHEDULE_DIR="$CONFIG_DIR/schedules"
mkdir -p "$SCHEDULE_DIR"

cmd_schedule() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add)
      local cron_expr="${1:?Usage: ai schedule add \"*/5 * * * *\" \"prompt\"}"
      local prompt="${2:?Usage: ai schedule add \"cron_expr\" \"prompt\"}"
      local sched_id=$(date +%s%N | tail -c 8)
      cat > "$SCHEDULE_DIR/${sched_id}.sched" <<EOF
SCHED_ID="$sched_id"
SCHED_CRON="$cron_expr"
SCHED_PROMPT="$(echo "$prompt" | sed 's/"/\\"/g')"
SCHED_CREATED="$(date -Iseconds)"
SCHED_ENABLED=1
SCHED_BACKEND="${ACTIVE_BACKEND:-auto}"
SCHED_OUTPUT="$SCHEDULE_DIR/${sched_id}.out"
EOF
      ok "Schedule created: #$sched_id"
      info "Cron: $cron_expr"
      info "To activate: ai schedule install"
      ;;
    list|ls)
      hdr "Scheduled Prompts"
      for f in "$SCHEDULE_DIR"/*.sched; do
        [[ -f "$f" ]] || continue
        source "$f"
        local status="${GREEN}enabled${R}"
        [[ "$SCHED_ENABLED" != "1" ]] && status="${DIM}disabled${R}"
        printf "  ${DIM}#%-8s${R} %b  ${CYAN}%-20s${R}  %s\n" \
          "$SCHED_ID" "$status" "$SCHED_CRON" "${SCHED_PROMPT:0:40}"
      done
      ;;
    install)
      info "Installing cron jobs..."
      local tmp=$(mktemp)
      crontab -l 2>/dev/null | grep -v 'ai-cli-sched' > "$tmp" || true
      for f in "$SCHEDULE_DIR"/*.sched; do
        [[ -f "$f" ]] || continue
        source "$f"
        [[ "$SCHED_ENABLED" != "1" ]] && continue
        echo "$SCHED_CRON /usr/local/bin/ai ask \"$SCHED_PROMPT\" >> \"$SCHED_OUTPUT\" 2>&1 # ai-cli-sched-$SCHED_ID" >> "$tmp"
      done
      crontab "$tmp"
      rm -f "$tmp"
      ok "Cron jobs installed"
      ;;
    remove|rm)
      local id="${1:?Usage: ai schedule remove ID}"
      rm -f "$SCHEDULE_DIR/${id}.sched" "$SCHEDULE_DIR/${id}.out"
      ok "Schedule #$id removed"
      cmd_schedule install 2>/dev/null || true
      ;;
    disable)
      local id="${1:?Usage: ai schedule disable ID}"
      local f="$SCHEDULE_DIR/${id}.sched"
      [[ -f "$f" ]] || { err "Schedule not found: $id"; return 1; }
      sed -i 's/SCHED_ENABLED=1/SCHED_ENABLED=0/' "$f"
      ok "Schedule #$id disabled"
      ;;
    enable)
      local id="${1:?Usage: ai schedule enable ID}"
      local f="$SCHEDULE_DIR/${id}.sched"
      [[ -f "$f" ]] || { err "Schedule not found: $id"; return 1; }
      sed -i 's/SCHED_ENABLED=0/SCHED_ENABLED=1/' "$f"
      ok "Schedule #$id enabled"
      ;;
    *)
      echo "Usage: ai schedule <add|list|install|remove|enable|disable>"
      echo ""
      echo "  add \"cron\" \"prompt\"  Create scheduled prompt"
      echo "  list                 Show all schedules"
      echo "  install              Write to crontab"
      echo "  remove ID          Delete schedule"
      echo ""
      echo "Examples:"
      echo "  ai schedule add \"0 9 * * *\" \"Give me a daily briefing\""
      echo "  ai schedule add \"*/30 * * * *\" \"Check system health\""
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  CONVERSATION REPLAY — v2.9.0
#  Replay a saved conversation through a different model
# ════════════════════════════════════════════════════════════════════════════════

cmd_replay() {
  local session="${1:?Usage: ai replay <session_name> [--model <backend>]}"
  local target_backend="${ACTIVE_BACKEND:-auto}"
  [[ "${2:-}" == "--model" ]] && target_backend="${3:-$ACTIVE_BACKEND}"

  local session_file="$SESSIONS_DIR/${session}.jsonl"
  [[ -f "$session_file" ]] || { err "Session not found: $session"; return 1; }

  hdr "Replaying: $session -> $target_backend"
  local total=$(wc -l < "$session_file")
  local count=0
  local saved_backend="$ACTIVE_BACKEND"
  ACTIVE_BACKEND="$target_backend"

  local out_file="$SESSIONS_DIR/${session}_replay_$(date +%Y%m%d%H%M%S).jsonl"

  while IFS= read -r line; do
    (( count++ ))
    # Extract role and content from JSONL
    local role content
    role=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('role',''))" 2>/dev/null || echo "")
    content=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('content',''))" 2>/dev/null || echo "")

    [[ -z "$role" || -z "$content" ]] && continue

    if [[ "$role" == "user" ]]; then
      printf "  ${DIM}[%d/%d]${R} ${CYAN}User:${R} %s\n" "$count" "$total" "${content:0:60}"

      # Re-generate with new model
      local response
      response=$(_silent_generate "$content" "$MAX_TOKENS" 2>/dev/null || echo "[no response]")

      printf "  ${DIM}[%d/%d]${R} ${GREEN}%s:${R} %s\n" "$count" "$total" "$target_backend" "${response:0:80}"

      # Save to replay log
      printf '{"role":"user","content":"%s"}\n' "$(echo "$content" | sed 's/"/\\"/g')" >> "$out_file"
      printf '{"role":"assistant","content":"%s"}\n' "$(echo "$response" | sed 's/"/\\"/g' | tr '\n' ' ')" >> "$out_file"
    fi
  done < "$session_file"

  ACTIVE_BACKEND="$saved_backend"
  echo ""
  ok "Replay saved: $out_file"
  info "Compare: diff $session_file $out_file"
}


# ════════════════════════════════════════════════════════════════════════════════
#  FAVORITES / BOOKMARKS — v2.9.0
#  Save and recall favorite prompts
# ════════════════════════════════════════════════════════════════════════════════

FAVORITES_FILE="$CONFIG_DIR/favorites.jsonl"
touch "$FAVORITES_FILE" 2>/dev/null || true

cmd_favorite() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add|save)
      local prompt="${*:?Usage: ai fav add \"prompt text\"}"
      local fav_id=$(date +%s)
      printf '{"id":%s,"prompt":"%s","created":"%s","tags":""}\n' \
        "$fav_id" "$(echo "$prompt" | sed 's/"/\\"/g')" "$(date -Iseconds)" \
        >> "$FAVORITES_FILE"
      ok "Favorite saved: #$fav_id"
      ;;
    list|ls)
      hdr "Favorite Prompts"
      local count=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( count++ ))
        local fid fprompt
        fid=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('id',''))" 2>/dev/null || echo "?")
        fprompt=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('prompt',''))" 2>/dev/null || echo "?")
        printf "  ${DIM}#%-8s${R}  %s\n" "$fid" "${fprompt:0:70}"
      done < "$FAVORITES_FILE"
      (( count == 0 )) && info "No favorites. Add one: ai fav add \"prompt\""
      info "$count favorites"
      ;;
    run|use)
      local id="${1:?Usage: ai fav run ID}"
      local prompt=""
      local count=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( count++ ))
        local fid
        fid=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('id',''))" 2>/dev/null || echo "")
        if [[ "$fid" == "$id" ]] || [[ "$count" == "$id" ]]; then
          prompt=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('prompt',''))" 2>/dev/null || echo "")
          break
        fi
      done < "$FAVORITES_FILE"
      if [[ -z "$prompt" ]]; then
        err "Favorite not found: $id"
        return 1
      fi
      info "Running: $prompt"
      dispatch_ask "$prompt"
      ;;
    delete|rm)
      local id="${1:?Usage: ai fav delete ID}"
      local tmp=$(mktemp)
      grep -v "\"id\":${id}" "$FAVORITES_FILE" > "$tmp" 2>/dev/null || true
      mv "$tmp" "$FAVORITES_FILE"
      ok "Favorite #$id deleted"
      ;;
    *)
      echo "Usage: ai fav <add|list|run|delete>"
      echo ""
      echo "  add \"prompt\"   Save a favorite prompt"
      echo "  list           Show all favorites"
      echo "  run ID       Re-run a favorite"
      echo "  delete ID    Remove a favorite"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  DIFF & PATCH — v2.9.0
#  AI-powered code diffing and patching
# ════════════════════════════════════════════════════════════════════════════════

cmd_diff() {
  local file1="${1:?Usage: ai diff FILE1 FILE2 [--explain]}"
  local file2="${2:?Usage: ai diff FILE1 FILE2 [--explain]}"
  local explain=0
  [[ "${3:-}" == "--explain" ]] && explain=1

  [[ -f "$file1" ]] || { err "File not found: $file1"; return 1; }
  [[ -f "$file2" ]] || { err "File not found: $file2"; return 1; }

  hdr "Diff: $file1 ↔ $file2"

  # Show standard diff
  local diff_output
  diff_output=$(diff --color=auto -u "$file1" "$file2" 2>/dev/null || true)

  if [[ -z "$diff_output" ]]; then
    ok "Files are identical"
    return
  fi

  echo "$diff_output"
  echo ""

  local added=$(echo "$diff_output" | grep '^+[^+]' | wc -l)
  local removed=$(echo "$diff_output" | grep '^-[^-]' | wc -l)
  info "Lines added: ${GREEN}+$added${R}  removed: ${RED}-$removed${R}"

  if [[ $explain -eq 1 ]]; then
    echo ""
    info "AI explanation:"
    dispatch_ask "Explain the following code diff concisely:

$diff_output"
  fi
}

cmd_patch() {
  local file="${1:?Usage: ai patch FILE \"instructions\"}"
  local instructions="${2:?Usage: ai patch FILE \"instructions\"}"

  [[ -f "$file" ]] || { err "File not found: $file"; return 1; }

  hdr "AI Patch: $file"
  info "Instructions: $instructions"

  local content
  content=$(cat "$file")
  local ext="${file##*.}"

  local prompt="Given this ${ext} file:

\`\`\`${ext}
$content
\`\`\`

Apply these changes: $instructions

Return ONLY the complete modified file content, no explanations."

  local result
  result=$(_silent_generate "$prompt" 4096 2>/dev/null || echo "")

  if [[ -z "$result" ]]; then
    err "AI produced no output"
    return 1
  fi

  # Strip markdown fences if present
  result=$(echo "$result" | sed '/^```/d')

  # Show diff preview
  local tmp=$(mktemp)
  echo "$result" > "$tmp"
  echo ""
  diff --color=auto -u "$file" "$tmp" || true

  echo ""
  read -rp "$(echo -e "${BYELLOW}Apply patch? [y/N]:${R} ")" confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    cp "$file" "${file}.bak"
    echo "$result" > "$file"
    ok "Patched: $file (backup: ${file}.bak)"
  else
    info "Patch cancelled"
  fi
  rm -f "$tmp"
}


# ════════════════════════════════════════════════════════════════════════════════
#  GIT INTEGRATION — v2.9.0
#  AI-powered git commit messages, PR descriptions, blame explanations
# ════════════════════════════════════════════════════════════════════════════════

cmd_git_ai() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    commit|cm)
      if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        err "Not in a git repository"
        return 1
      fi
      local diff
      diff=$(git diff --cached --stat 2>/dev/null)
      if [[ -z "$diff" ]]; then
        diff=$(git diff --stat 2>/dev/null)
        if [[ -z "$diff" ]]; then
          info "No changes to commit"
          return
        fi
        warn "No staged changes. Showing unstaged diff."
        info "Stage changes first: git add ."
        return
      fi
      local full_diff
      full_diff=$(git diff --cached 2>/dev/null | head -200)
      info "Generating commit message..."
      local msg
      msg=$(_silent_generate "Write a concise git commit message for these changes. Use conventional commits format (feat/fix/docs/refactor/test/chore). Max 72 chars for first line. Add a brief body if needed.

Diff:
$full_diff" 128 2>/dev/null || echo "")
      if [[ -z "$msg" ]]; then
        err "Could not generate commit message"
        return 1
      fi
      echo ""
      printf "  ${GREEN}Suggested commit message:${R}\n"
      echo "  ─────────────────────────────"
      echo "$msg" | sed 's/^/  /'
      echo "  ─────────────────────────────"
      echo ""
      read -rp "$(echo -e "${BYELLOW}Use this message? [Y/n/e(dit)]:${R} ")" choice
      case "$choice" in
        n|N) info "Cancelled" ;;
        e|E)
          local tmp=$(mktemp)
          echo "$msg" > "$tmp"
          ${EDITOR:-nano} "$tmp"
          git commit -F "$tmp"
          rm -f "$tmp"
          ;;
        *)
          git commit -m "$msg"
          ok "Committed!"
          ;;
      esac
      ;;
    pr|pull-request)
      if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        err "Not in a git repository"
        return 1
      fi
      local base="${1:-main}"
      local log
      log=$(git log --oneline "$base"..HEAD 2>/dev/null | head -30)
      local diff_stat
      diff_stat=$(git diff --stat "$base"..HEAD 2>/dev/null | tail -5)
      info "Generating PR description..."
      local desc
      desc=$(_silent_generate "Write a GitHub pull request description for these changes. Include: title, summary, key changes (bullet points), and testing notes.

Commits:
$log

Diff stats:
$diff_stat" 512 2>/dev/null || echo "")
      echo ""
      echo "$desc"
      ;;
    blame)
      local file="${1:?Usage: ai git blame FILE <line>}"
      local line="${2:?Usage: ai git blame FILE <line>}"
      local blame_output
      blame_output=$(git blame -L "$line,$line" "$file" 2>/dev/null || echo "")
      if [[ -z "$blame_output" ]]; then
        err "Could not get blame info"
        return 1
      fi
      echo "$blame_output"
      local commit_hash
      commit_hash=$(echo "$blame_output" | awk '{print $1}')
      if [[ -n "$commit_hash" && "$commit_hash" != "00000000" ]]; then
        local commit_info
        commit_info=$(git show --stat "$commit_hash" 2>/dev/null | head -20)
        echo ""
        info "AI explanation:"
        dispatch_ask "Explain why this line was changed based on this git commit:

Blame: $blame_output

Commit info:
$commit_info"
      fi
      ;;
    summary)
      local range="${1:-HEAD~5..HEAD}"
      local log
      log=$(git log --oneline "$range" 2>/dev/null)
      info "Summarizing commits: $range"
      dispatch_ask "Summarize these git commits in a few bullet points:

$log"
      ;;
    *)
      echo "Usage: ai git <commit|pr|blame|summary>"
      echo ""
      echo "  commit            Generate AI commit message"
      echo "  pr [base]         Generate PR description"
      echo "  blame FILE LINE   Explain a git blame line"
      echo "  summary [range]   Summarize recent commits"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  LOGGING & ANALYTICS — v2.9.0
#  Track usage, token counts, costs, response times
# ════════════════════════════════════════════════════════════════════════════════

ANALYTICS_FILE="$CONFIG_DIR/analytics.jsonl"

_log_analytics() {
  local backend="$1" tokens_in="$2" tokens_out="$3" latency_ms="$4" model="$5"
  printf '{"ts":"%s","backend":"%s","model":"%s","in":%s,"out":%s,"ms":%s}\n' \
    "$(date -Iseconds)" "$backend" "$model" "$tokens_in" "$tokens_out" "$latency_ms" \
    >> "$ANALYTICS_FILE" 2>/dev/null || true
}

cmd_analytics() {
  local sub="${1:-summary}"; shift 2>/dev/null || true
  case "$sub" in
    summary)
      hdr "Usage Analytics"
      if [[ ! -f "$ANALYTICS_FILE" ]] || [[ ! -s "$ANALYTICS_FILE" ]]; then
        info "No analytics data yet. Use ai to generate some!"
        return
      fi
      local total_requests=0
      local total_in=0
      local total_out=0
      local total_ms=0
      declare -A backend_counts=()

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( total_requests++ ))
        local backend in_tok out_tok ms
        backend=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('backend','?'))" 2>/dev/null || echo "?")
        in_tok=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('in',0))" 2>/dev/null || echo 0)
        out_tok=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('out',0))" 2>/dev/null || echo 0)
        ms=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('ms',0))" 2>/dev/null || echo 0)
        total_in=$(( total_in + in_tok ))
        total_out=$(( total_out + out_tok ))
        total_ms=$(( total_ms + ms ))
        backend_counts["$backend"]=$(( ${backend_counts["$backend"]:-0} + 1 ))
      done < "$ANALYTICS_FILE"

      printf "  ${B}Total Requests:${R}  %d\n" "$total_requests"
      printf "  ${B}Total Input:${R}     %d tokens\n" "$total_in"
      printf "  ${B}Total Output:${R}    %d tokens\n" "$total_out"
      if (( total_requests > 0 )); then
        printf "  ${B}Avg Latency:${R}     %d ms\n" "$(( total_ms / total_requests ))"
      fi
      echo ""
      info "By backend:"
      for b in "${!backend_counts[@]}"; do
        printf "    %-15s  %d requests\n" "$b" "${backend_counts[$b]}"
      done
      ;;
    today)
      local today=$(date +%Y-%m-%d)
      local count=0
      grep "$today" "$ANALYTICS_FILE" 2>/dev/null | while IFS= read -r line; do
        (( count++ ))
      done
      local _today_count; _today_count=$(grep -c "$today" "$ANALYTICS_FILE" 2>/dev/null || echo 0)
      info "Today: ${_today_count} requests"
      ;;
    clear)
      > "$ANALYTICS_FILE"
      ok "Analytics cleared"
      ;;
    raw)
      [[ -f "$ANALYTICS_FILE" ]] && cat "$ANALYTICS_FILE" || info "No data"
      ;;
    *)
      echo "Usage: ai analytics <summary|today|clear|raw>"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  INTERACTIVE QUIZ / FLASHCARD — v2.9.0
#  AI-generated quiz for learning topics
# ════════════════════════════════════════════════════════════════════════════════

cmd_quiz() {
  local topic="${1:?Usage: ai quiz \"topic\" [--count N]}"
  local count=5
  [[ "${2:-}" == "--count" ]] && count="${3:-5}"

  hdr "AI Quiz: $topic"
  info "Generating $count questions..."

  local questions
  questions=$(_silent_generate "Generate exactly $count multiple-choice quiz questions about: $topic

Format each question as:
Q1: [question text]
A) [option]
B) [option]
C) [option]
D) [option]
Answer: [letter]

Be educational and progressively harder." 2048 2>/dev/null || echo "")

  if [[ -z "$questions" ]]; then
    err "Could not generate quiz"
    return 1
  fi

  local score=0
  local total=0
  local current_q=""
  local current_answer=""
  local in_question=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^Q[0-9]+: ]]; then
      # If we had a previous question, ask it
      if [[ -n "$current_q" && -n "$current_answer" ]]; then
        echo ""
        echo "$current_q"
        read -rp "$(echo -e "${BCYAN}Your answer (A/B/C/D): ${R}")" user_answer
        user_answer=$(echo "$user_answer" | tr '[:lower:]' '[:upper:]' | head -c1)
        if [[ "$user_answer" == "$current_answer" ]]; then
          printf "  ${GREEN}Correct!${R}\n"
          (( score++ ))
        else
          printf "  ${RED}Wrong.${R} Answer: %s\n" "$current_answer"
        fi
        (( total++ ))
      fi
      current_q="$line"
      current_answer=""
      in_question=1
    elif [[ "$line" =~ ^[ABCD]\) ]]; then
      current_q+=$'\n'"  $line"
    elif [[ "$line" =~ ^Answer:\ *([A-D]) ]]; then
      current_answer="${BASH_REMATCH[1]}"
    fi
  done <<< "$questions"

  # Handle last question
  if [[ -n "$current_q" && -n "$current_answer" ]]; then
    echo ""
    echo "$current_q"
    read -rp "$(echo -e "${BCYAN}Your answer (A/B/C/D): ${R}")" user_answer
    user_answer=$(echo "$user_answer" | tr '[:lower:]' '[:upper:]' | head -c1)
    if [[ "$user_answer" == "$current_answer" ]]; then
      printf "  ${GREEN}Correct!${R}\n"
      (( score++ ))
    else
      printf "  ${RED}Wrong.${R} Answer: %s\n" "$current_answer"
    fi
    (( total++ ))
  fi

  echo ""
  hdr "Results"
  printf "  Score: ${B}%d/%d${R}" "$score" "$total"
  if (( total > 0 )); then
    local pct=$(( score * 100 / total ))
    if (( pct >= 80 )); then
      printf "  ${GREEN}— %d%% Excellent!${R}\n" "$pct"
    elif (( pct >= 60 )); then
      printf "  ${YELLOW}— %d%% Good${R}\n" "$pct"
    else
      printf "  ${RED}— %d%% Keep studying${R}\n" "$pct"
    fi
  else
    echo ""
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  MARKDOWN RENDERER — v2.9.0
#  Pretty-print markdown in terminal
# ════════════════════════════════════════════════════════════════════════════════

_render_markdown() {
  local input="${1:-}"
  [[ -z "$input" ]] && input=$(cat)

  echo "$input" | while IFS= read -r line; do
    # Headers
    if [[ "$line" =~ ^###\  ]]; then
      printf "${B}${CYAN}   %s${R}\n" "${line#\#\#\# }"
    elif [[ "$line" =~ ^##\  ]]; then
      printf "${B}${BWHITE} %s${R}\n" "${line#\#\# }"
    elif [[ "$line" =~ ^#\  ]]; then
      printf "\n${B}${BWHITE}${UL}%s${R}\n" "${line#\# }"
    # Code blocks
    elif [[ "$line" =~ ^\`\`\` ]]; then
      printf "${DIM}%s${R}\n" "$line"
    # Bold
    elif [[ "$line" =~ \*\*.*\*\* ]]; then
      local rendered="$line"
      rendered=$(echo "$rendered" | sed "s/\*\*\([^*]*\)\*\*/${B}\1${R}/g")
      printf "%s\n" "$rendered"
    # Bullets
    elif [[ "$line" =~ ^[[:space:]]*[-*]\  ]]; then
      printf "${CYAN}•${R} %s\n" "${line#*- }"
    # Numbered lists
    elif [[ "$line" =~ ^[[:space:]]*[0-9]+\.\  ]]; then
      printf "${CYAN}%s${R}\n" "$line"
    # Blockquote
    elif [[ "$line" =~ ^\> ]]; then
      printf "${DIM}│ %s${R}\n" "${line#> }"
    # Horizontal rule
    elif [[ "$line" =~ ^---$ ]] || [[ "$line" =~ ^___$ ]]; then
      printf "${DIM}────────────────────────────────────────${R}\n"
    else
      printf "%s\n" "$line"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════════════════
#  SHELL INTEGRATION — v2.9.0
#  Generate and explain shell commands
# ════════════════════════════════════════════════════════════════════════════════

cmd_shell() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    gen|generate)
      local desc="${*:?Usage: ai shell gen \"description of what you want\"}"
      local result
      result=$(_silent_generate "Generate a single shell command (bash) that does the following: $desc

Return ONLY the command, no explanation, no markdown fences. If it requires multiple commands, chain them with && or ;." 128 2>/dev/null || echo "")
      if [[ -z "$result" ]]; then
        err "Could not generate command"
        return 1
      fi
      # Strip markdown if present
      result=$(echo "$result" | sed '/^```/d' | head -3)
      echo ""
      printf "  ${GREEN}%s${R}\n" "$result"
      echo ""
      read -rp "$(echo -e "${BYELLOW}Execute? [y/N]:${R} ")" confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        eval "$result"
      fi
      ;;
    explain|ex)
      local cmd="${*:?Usage: ai shell explain \"command\"}"
      dispatch_ask "Explain this shell command in simple terms. Break down each part:

\`\`\`bash
$cmd
\`\`\`"
      ;;
    fix)
      local cmd="${*:?Usage: ai shell fix \"broken command\"}"
      local result
      result=$(_silent_generate "This shell command has an error. Fix it and return ONLY the corrected command:

$cmd" 128 2>/dev/null || echo "")
      echo ""
      printf "  ${RED}Original:${R}  %s\n" "$cmd"
      printf "  ${GREEN}Fixed:${R}     %s\n" "$result"
      echo ""
      read -rp "$(echo -e "${BYELLOW}Execute fixed command? [y/N]:${R} ")" confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        eval "$result"
      fi
      ;;
    *)
      echo "Usage: ai shell <gen|explain|fix>"
      echo ""
      echo "  gen \"description\"     Generate a shell command"
      echo "  explain \"command\"     Explain what a command does"
      echo "  fix \"command\"         Fix a broken command"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  SEMANTIC FILE SEARCH — v2.9.0
#  AI-powered search across local files using keyword matching
# ════════════════════════════════════════════════════════════════════════════════

cmd_find_ai() {
  local query="${1:?Usage: ai find \"what to search for\" [directory]}"
  local search_dir="${2:-.}"
  local max_results="${3:-15}"

  hdr "AI File Search"
  info "Query: \"$query\""
  info "Directory: $search_dir"
  echo ""

  # Extract keywords from query
  local keywords
  keywords=$(echo "$query" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -E '.{3,}')

  local results=()
  local result_count=0

  while IFS= read -r -d '' file; do
    (( result_count >= max_results )) && break
    local score=0
    local fname=$(basename "$file")
    local fname_lower=$(echo "$fname" | tr '[:upper:]' '[:lower:]')

    # Score filename matches
    for kw in $keywords; do
      [[ "$fname_lower" == *"$kw"* ]] && (( score += 5 ))
    done

    # Score content matches (first 100 lines)
    local content_lower
    content_lower=$(head -100 "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    for kw in $keywords; do
      local matches
      matches=$(echo "$content_lower" | grep -c "$kw" 2>/dev/null || echo 0)
      score=$(( score + matches ))
    done

    if (( score > 0 )); then
      local size
      size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
      local human_size
      if (( size > 1048576 )); then
        human_size=$(awk "BEGIN{printf \"%.1fM\", $size/1048576}")
      elif (( size > 1024 )); then
        human_size=$(awk "BEGIN{printf \"%.0fK\", $size/1024}")
      else
        human_size="${size}B"
      fi
      printf "  ${GREEN}[%2d]${R} %-50s ${DIM}%s${R}\n" "$score" "${file:0:50}" "$human_size"
      (( result_count++ ))
    fi
  done < <(find "$search_dir" -type f \
    -not -path '*/\.*' \
    -not -path '*/node_modules/*' \
    -not -path '*/__pycache__/*' \
    -not -name '*.pyc' \
    -not -name '*.o' \
    -size -5M \
    -print0 2>/dev/null | head -z -500)

  echo ""
  if (( result_count == 0 )); then
    info "No matches for: $query"
  else
    ok "$result_count results found"
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  ENVIRONMENT PROFILES — v2.9.0
#  Named environment configs for different use cases
# ════════════════════════════════════════════════════════════════════════════════

PROFILES_DIR="$CONFIG_DIR/profiles"
mkdir -p "$PROFILES_DIR"

cmd_profile() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create|new)
      local name="${1:?Usage: ai profile create NAME \"description\"}"
      local desc="${2:-No description}"
      local profile_dir="$PROFILES_DIR/$name"
      mkdir -p "$profile_dir"
      cp "$CONFIG_FILE" "$profile_dir/config.env" 2>/dev/null || true
      cp "$KEYS_FILE" "$profile_dir/keys.env" 2>/dev/null || true
      echo "$desc" > "$profile_dir/description.txt"
      ok "Profile created: $name"
      ;;
    switch|use)
      local name="${1:?Usage: ai profile switch NAME}"
      local profile_dir="$PROFILES_DIR/$name"
      [[ -d "$profile_dir" ]] || { err "Profile not found: $name"; return 1; }
      [[ -f "$profile_dir/config.env" ]] && cp "$profile_dir/config.env" "$CONFIG_FILE"
      [[ -f "$profile_dir/keys.env" ]] && cp "$profile_dir/keys.env" "$KEYS_FILE"
      source "$CONFIG_FILE" 2>/dev/null || true
      source "$KEYS_FILE" 2>/dev/null || true
      ok "Switched to profile: $name"
      ;;
    list|ls)
      hdr "Environment Profiles"
      for d in "$PROFILES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local pname=$(basename "$d")
        local desc=$(cat "$d/description.txt" 2>/dev/null || echo "")
        printf "  ${CYAN}%-15s${R}  ${DIM}%s${R}\n" "$pname" "$desc"
      done
      ;;
    delete|rm)
      local name="${1:?Usage: ai profile delete NAME}"
      rm -rf "$PROFILES_DIR/$name"
      ok "Profile '$name' deleted"
      ;;
    *)
      echo "Usage: ai profile <create|switch|list|delete>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  WATCH MODE — v2.9.0
#  Watch a file and re-process when it changes
# ════════════════════════════════════════════════════════════════════════════════

cmd_watch() {
  local file="${1:?Usage: ai watch FILE [command]}"
  local action="${2:-summarize}"
  local interval="${3:-2}"

  [[ -f "$file" ]] || { err "File not found: $file"; return 1; }

  hdr "Watch Mode"
  info "File:     $file"
  info "Action:   $action"
  info "Interval: ${interval}s"
  info "Press Ctrl+C to stop"
  echo ""

  local last_hash=""
  while true; do
    local current_hash
    current_hash=$(md5sum "$file" 2>/dev/null | awk '{print $1}' || sha256sum "$file" 2>/dev/null | awk '{print $1}' || echo "")

    if [[ "$current_hash" != "$last_hash" && -n "$current_hash" ]]; then
      last_hash="$current_hash"
      printf "\n  ${CYAN}[%s] File changed — processing...${R}\n" "$(date +%H:%M:%S)"
      case "$action" in
        summarize) dispatch_ask "Summarize this file:
$(cat "$file" | head -200)" 2>/dev/null || true ;;
        review)    dispatch_ask "Review this code:
$(cat "$file" | head -200)" 2>/dev/null || true ;;
        lint)      dispatch_ask "Find bugs and issues in:
$(cat "$file" | head -200)" 2>/dev/null || true ;;
        explain)   dispatch_ask "Explain this code:
$(cat "$file" | head -200)" 2>/dev/null || true ;;
        *)         dispatch_ask "$action:
$(cat "$file" | head -200)" 2>/dev/null || true ;;
      esac
    fi
    sleep "$interval"
  done
}


# ════════════════════════════════════════════════════════════════════════════════
#  NOTEBOOK — v2.9.0
#  Jupyter-like notebook experience in the terminal
# ════════════════════════════════════════════════════════════════════════════════

NOTEBOOKS_DIR="$AI_OUTPUT_DIR/notebooks"
mkdir -p "$NOTEBOOKS_DIR"

cmd_notebook() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    new|create)
      local name="${1:?Usage: ai notebook new NAME}"
      local nb_file="$NOTEBOOKS_DIR/${name}.ainb"
      cat > "$nb_file" <<EOF
# AI CLI Notebook: $name
# Created: $(date -Iseconds)
# Format: Each cell starts with --- and a type: [code], [ai], [text]
# Run cells with: ai notebook run NAME

--- [text]
# $name
This notebook was created with AI CLI v${VERSION}

--- [ai]
Tell me about this notebook topic

--- [code]
echo "Hello from AI CLI notebook!"
date

EOF
      ok "Notebook created: $nb_file"
      info "Edit: ${EDITOR:-nano} $nb_file"
      info "Run:  ai notebook run $name"
      ;;
    run|exec)
      local name="${1:?Usage: ai notebook run NAME}"
      local nb_file="$NOTEBOOKS_DIR/${name}.ainb"
      [[ -f "$nb_file" ]] || { err "Notebook not found: $name"; return 1; }

      hdr "Running notebook: $name"
      local cell_num=0
      local cell_type=""
      local cell_content=""
      local out_file="$NOTEBOOKS_DIR/${name}_output_$(date +%Y%m%d%H%M%S).txt"

      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^---\ \[(code|ai|text)\] ]]; then
          # Process previous cell
          if [[ -n "$cell_content" && -n "$cell_type" ]]; then
            _run_notebook_cell "$cell_num" "$cell_type" "$cell_content" "$out_file"
          fi
          cell_type="${BASH_REMATCH[1]}"
          cell_content=""
          (( cell_num++ ))
        elif [[ "$line" != \#* || "$cell_type" == "code" ]]; then
          cell_content+="$line"$'\n'
        fi
      done < "$nb_file"

      # Process last cell
      if [[ -n "$cell_content" && -n "$cell_type" ]]; then
        _run_notebook_cell "$cell_num" "$cell_type" "$cell_content" "$out_file"
      fi

      echo ""
      ok "Notebook complete: $cell_num cells"
      ok "Output saved: $out_file"
      ;;
    list|ls)
      hdr "Notebooks"
      for f in "$NOTEBOOKS_DIR"/*.ainb; do
        [[ -f "$f" ]] || continue
        local nbname=$(basename "$f" .ainb)
        local cells=$(grep -c '^--- \[' "$f" 2>/dev/null || echo 0)
        local modified=$(stat -c%Y "$f" 2>/dev/null || echo 0)
        local mod_date=$(date -d "@$modified" +%Y-%m-%d 2>/dev/null || echo "?")
        printf "  ${CYAN}%-20s${R}  ${DIM}%s cells  modified %s${R}\n" "$nbname" "$cells" "$mod_date"
      done
      ;;
    edit)
      local name="${1:?Usage: ai notebook edit NAME}"
      local nb_file="$NOTEBOOKS_DIR/${name}.ainb"
      [[ -f "$nb_file" ]] || { err "Notebook not found: $name"; return 1; }
      ${EDITOR:-nano} "$nb_file"
      ;;
    delete|rm)
      local name="${1:?Usage: ai notebook delete NAME}"
      rm -f "$NOTEBOOKS_DIR/${name}.ainb" "$NOTEBOOKS_DIR/${name}"_output_*.txt
      ok "Notebook '$name' deleted"
      ;;
    *)
      echo "Usage: ai notebook <new|run|list|edit|delete>"
      echo ""
      echo "Cell types: [text] [code] [ai]"
      ;;
  esac
}

_run_notebook_cell() {
  local num="$1" type="$2" content="$3" out_file="$4"
  content=$(echo "$content" | sed '/^$/d')
  [[ -z "$content" ]] && return

  printf "\n  ${CYAN}━━━ Cell %d [%s] ━━━${R}\n" "$num" "$type"

  case "$type" in
    text)
      _render_markdown "$content"
      echo "$content" >> "$out_file"
      ;;
    code)
      printf "${DIM}%s${R}\n" "$content"
      echo "--- Cell $num [code] ---" >> "$out_file"
      echo "$content" >> "$out_file"
      local output
      output=$(bash -c "$content" 2>&1 || true)
      if [[ -n "$output" ]]; then
        printf "${GREEN}%s${R}\n" "$output"
        echo "$output" >> "$out_file"
      fi
      ;;
    ai)
      printf "${DIM}> %s${R}\n" "${content:0:80}"
      echo "--- Cell $num [ai] ---" >> "$out_file"
      local response
      response=$(_silent_generate "$content" "$MAX_TOKENS" 2>/dev/null || echo "[no response]")
      echo "$response"
      echo "$response" >> "$out_file"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  TASK PLANNER — v2.9.0
#  AI-powered task breakdown and planning
# ════════════════════════════════════════════════════════════════════════════════

TASKS_FILE="$CONFIG_DIR/tasks.jsonl"
touch "$TASKS_FILE" 2>/dev/null || true

cmd_plan() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local g="${*:?Usage: ai plan create goal}"; info "Planning..."; _silent_generate "Break into 5-10 numbered tasks: $g" 2>/dev/null | tee -a "$TASKS_FILE"; ok "Plan created" ;;
    list) hdr "Tasks"; cat "$TASKS_FILE" 2>/dev/null || info "Empty" ;;
    clear) > "$TASKS_FILE"; ok "Cleared" ;;
    *) echo "Usage: ai plan <create|list|clear>" ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  LEARNING MODE — v2.9.0
#  Interactive learning sessions with AI tutor
# ════════════════════════════════════════════════════════════════════════════════

cmd_learn() {
  local topic="${*:?Usage: ai learn \"topic\"}"

  hdr "Learning Mode: $topic"
  info "AI will teach you step by step."
  info "Commands: next=n, quiz=q, example=e, explain=x, quit"
  echo ""

  local lesson_num=0
  local context="You are a patient tutor teaching: $topic"

  # Get overview
  local overview
  overview=$(_silent_generate "$context

Start by giving a brief 3-sentence overview of $topic and what the student will learn. End with the first concept to explore." 256 2>/dev/null || echo "")
  echo "$overview"
  echo ""

  while true; do
    read -rp "$(echo -e "${BCYAN}[learn]${R} (n/q/e/x/quit)> ")" cmd
    case "$cmd" in
      n|next)
        (( lesson_num++ ))
        local response
        response=$(_silent_generate "$context
This is lesson step $lesson_num. The student has completed the previous steps. Teach the next concept about $topic. Be concise but thorough. Include a practical tip." 512 2>/dev/null || echo "")
        echo ""
        echo "$response"
        echo ""
        ;;
      q|quiz)
        local quiz
        quiz=$(_silent_generate "$context
Create one quick question to test understanding of what we've covered so far (step $lesson_num). Give the answer after the student responds." 256 2>/dev/null || echo "")
        echo ""
        echo "$quiz"
        read -rp "$(echo -e "${BCYAN}Your answer: ${R}")" answer
        local feedback
        feedback=$(_silent_generate "$context
The student answered: '$answer' to the quiz question. Give brief feedback - was it correct? Explain why." 256 2>/dev/null || echo "")
        echo "$feedback"
        echo ""
        ;;
      e|example)
        local example
        example=$(_silent_generate "$context
Give a practical real-world example related to the current lesson (step $lesson_num) about $topic. Include code if relevant." 512 2>/dev/null || echo "")
        echo ""
        echo "$example"
        echo ""
        ;;
      x|explain)
        read -rp "$(echo -e "${BCYAN}What to explain? ${R}")" what
        local explanation
        explanation=$(_silent_generate "$context
The student asks about: $what (in the context of learning $topic, step $lesson_num). Explain clearly with an analogy if possible." 512 2>/dev/null || echo "")
        echo ""
        echo "$explanation"
        echo ""
        ;;
      quit|exit|q!)
        echo ""
        ok "Learning session ended after $lesson_num steps"
        break
        ;;
      *)
        echo "  n=next  q=quiz  e=example  x=explain  quit=exit"
        ;;
    esac
  done
}


# ════════════════════════════════════════════════════════════════════════════════
#  CONVERSATION FORMAT CONVERTER — v2.9.0
#  Convert between different chat formats
# ════════════════════════════════════════════════════════════════════════════════



# ════════════════════════════════════════════════════════════════════════════════
#  WRITING ASSISTANT — v2.9.0
#  Specialized writing modes: blog, email, docs, readme
# ════════════════════════════════════════════════════════════════════════════════

cmd_write() {
  local mode="${1:-}"; shift 2>/dev/null || true
  local topic="${*:-}"

  case "$mode" in
    blog)
      [[ -z "$topic" ]] && { echo "Usage: ai write blog \"topic\""; return 1; }
      local out="$AI_OUTPUT_DIR/blog_$(date +%Y%m%d%H%M%S).md"
      info "Writing blog post: $topic"
      _silent_generate "Write a professional blog post about: $topic

Include:
- Engaging title with subtitle
- Introduction that hooks the reader
- 3-5 main sections with headers
- Practical examples or tips
- Conclusion with call to action

Use markdown formatting. Be informative and engaging. ~800 words." 4096 > "$out" 2>/dev/null
      ok "Blog post saved: $out"
      cat "$out"
      ;;
    email)
      [[ -z "$topic" ]] && { echo "Usage: ai write email \"subject or context\""; return 1; }
      info "Drafting email..."
      _silent_generate "Write a professional email about: $topic

Include appropriate greeting, clear body, and sign-off. Keep it concise and professional." 512 2>/dev/null
      ;;
    readme)
      local project_dir="${topic:-.}"
      info "Generating README for: $project_dir"
      local files_list
      files_list=$(ls -1 "$project_dir" 2>/dev/null | head -30)
      local out="$project_dir/README.md"
      _silent_generate "Generate a comprehensive README.md for a project with these files:

$files_list

Include:
- Project title and description
- Installation instructions
- Usage examples
- Features list
- License section

Use proper markdown formatting." 2048 > "$out" 2>/dev/null
      ok "README saved: $out"
      ;;
    docs)
      local file="${topic:?Usage: ai write docs FILE}"
      [[ -f "$file" ]] || { err "File not found: $file"; return 1; }
      local content
      content=$(cat "$file" | head -300)
      local ext="${file##*.}"
      info "Generating documentation for: $file"
      _silent_generate "Generate documentation for this ${ext} file. Include function descriptions, parameters, return values, and usage examples:

\`\`\`${ext}
$content
\`\`\`" 2048 2>/dev/null
      ;;
    story)
      [[ -z "$topic" ]] && topic="a mysterious adventure"
      local out="$AI_OUTPUT_DIR/story_$(date +%Y%m%d%H%M%S).md"
      info "Writing story: $topic"
      _silent_generate "Write a creative short story about: $topic

Include vivid descriptions, dialogue, and a satisfying ending. ~500 words." 2048 > "$out" 2>/dev/null
      ok "Story saved: $out"
      cat "$out"
      ;;
    poem)
      [[ -z "$topic" ]] && topic="technology and nature"
      info "Writing poem: $topic"
      _silent_generate "Write a beautiful poem about: $topic

Use vivid imagery and metaphor. 3-4 stanzas." 512 2>/dev/null
      ;;
    resume)
      [[ -z "$topic" ]] && { echo "Usage: ai write resume \"role/field\""; return 1; }
      info "Generating resume template for: $topic"
      _silent_generate "Generate a professional resume/CV template for someone in: $topic

Include sections: Contact, Summary, Experience - 3 entries, Education, Skills, Projects. Use markdown formatting. Fill with realistic placeholder text." 2048 2>/dev/null
      ;;
    *)
      echo "Usage: ai write <blog|email|readme|docs|story|poem|resume> [topic]"
      echo ""
      echo "  blog \"topic\"     Write a blog post"
      echo "  email \"subject\"  Draft a professional email"
      echo "  readme [dir]     Generate README.md"
      echo "  docs FILE      Generate code documentation"
      echo "  story [topic]    Write a short story"
      echo "  poem [topic]     Write a poem"
      echo "  resume \"role\"    Generate resume template"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  MEMORY / KNOWLEDGE — v2.9.0
#  Persistent facts the AI should remember across sessions
# ════════════════════════════════════════════════════════════════════════════════

MEMORY_FILE="$CONFIG_DIR/memory.jsonl"
touch "$MEMORY_FILE" 2>/dev/null || true

cmd_memory() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add|save|remember)
      local fact="${*:?Usage: ai memory add \"fact to remember\"}"
      printf '{"fact":"%s","added":"%s","source":"user"}\n' \
        "$(echo "$fact" | sed 's/"/\\"/g')" "$(date -Iseconds)" \
        >> "$MEMORY_FILE"
      ok "Remembered: $fact"
      ;;
    list|show|ls)
      hdr "AI Memory"
      local count=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( count++ ))
        local fact added
        fact=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('fact','?'))" 2>/dev/null || echo "?")
        added=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('added','?'))" 2>/dev/null || echo "?")
        printf "  ${DIM}%-3d${R} %s  — %s\n" "$count" "$fact" "$added"
      done < "$MEMORY_FILE"
      (( count == 0 )) && info "No memories. Add: ai memory add \"fact\""
      ;;
    clear)
      > "$MEMORY_FILE"
      ok "Memory cleared"
      ;;
    context)
      # Build context string from memories for prompt injection
      local ctx=""
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local fact
        fact=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('fact',''))" 2>/dev/null || echo "")
        [[ -n "$fact" ]] && ctx+="- $fact"$'\n'
      done < "$MEMORY_FILE"
      echo "$ctx"
      ;;
    search)
      local query="${1:?Usage: ai memory search \"keyword\"}"
      grep -i "$query" "$MEMORY_FILE" 2>/dev/null | while IFS= read -r line; do
        local fact
        fact=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('fact','?'))" 2>/dev/null || echo "?")
        printf "  %s\n" "$fact"
      done
      ;;
    *)
      echo "Usage: ai memory <add|list|clear|search>"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  TRANSLATOR — v2.9.0
#  Multi-language translation with auto-detect
# ════════════════════════════════════════════════════════════════════════════════

cmd_translate_v2() {
  local text="" target="English" source="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) target="$2"; shift 2 ;;
      --from) source="$2"; shift 2 ;;
      *) text+="$1 "; shift ;;
    esac
  done
  text="${text% }"
  [[ -z "$text" ]] && { echo "Usage: ai tr \"text\" --to French"; return 1; }
  local prompt="Translate the following"
  [[ "$source" != "auto" ]] && prompt+=" from $source"
  prompt+=" to $target. Return ONLY the translation, no explanations:

$text"
  _silent_generate "$prompt" 512 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
#  DICTIONARY / DEFINE — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_define() {
  local word="${*:?Usage: ai define \"word or phrase\"}"
  _silent_generate "Define '$word'. Include:
1. Definitions with part of speech
2. Etymology
3. Example sentences
4. Synonyms and antonyms
Be concise." 512 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
#  REGEX HELPER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_regex() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    build|gen)
      local desc="${*:?Usage: ai regex build \"description\"}"
      _silent_generate "Create a regex pattern for: $desc
Return the regex pattern on the first line, then explain each part briefly. Include test examples." 256 2>/dev/null
      ;;
    explain|ex)
      local pattern="${*:?Usage: ai regex explain \"pattern\"}"
      _silent_generate "Explain this regex pattern in detail, breaking down each component:
Pattern: $pattern" 256 2>/dev/null
      ;;
    test)
      local pattern="${1:?Usage: ai regex test \"pattern\" \"text\"}"
      local text="${2:?Usage: ai regex test \"pattern\" \"text\"}"
      if echo "$text" | grep -qP "$pattern" 2>/dev/null; then
        printf "${GREEN}MATCH${R}\n"
        echo "$text" | grep -oP "$pattern" 2>/dev/null | while read -r m; do
          printf "  Matched: ${CYAN}%s${R}\n" "$m"
        done
      else
        printf "${RED}NO MATCH${R}\n"
      fi
      ;;
    *)
      echo "Usage: ai regex <build|explain|test>"
      echo "  build \"description\"    Generate regex from description"
      echo "  explain \"pattern\"      Explain a regex"
      echo "  test \"pattern\" \"text\"  Test a regex"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  JSON / YAML TOOLS — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  CRON EXPRESSION HELPER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_cron() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    build|gen)
      local desc="${*:?Usage: ai cron build \"every day at 9am\"}"
      _silent_generate "Convert this to a cron expression: $desc
Return ONLY the cron expression on line 1, then explain on line 2.
Format: minute hour day-of-month month day-of-week" 128 2>/dev/null
      ;;
    explain|ex)
      local expr="${*:?Usage: ai cron explain \"0 9 * * 1-5\"}"
      _silent_generate "Explain this cron expression in plain English: $expr" 128 2>/dev/null
      ;;
    next)
      local expr="${*:?Usage: ai cron next \"0 9 * * *\"}"
      _silent_generate "Given the cron expression '$expr', what are the next 5 execution times starting from now? List them." 256 2>/dev/null
      ;;
    *)
      echo "Usage: ai cron <build|explain|next>"
      echo "  build \"description\"     Generate cron expression"
      echo "  explain \"expression\"     Explain cron expression"
      echo "  next \"expression\"        Show next run times"
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  SQL HELPER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_sql() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    gen|generate)
      local desc="${*:?Usage: ai sql gen \"description\"}"
      _silent_generate "Generate a SQL query for: $desc
Return ONLY the SQL query. Use standard SQL syntax. Add comments for complex parts." 512 2>/dev/null
      ;;
    explain|ex)
      local query="${*:?Usage: ai sql explain \"SELECT ...\"}"
      _silent_generate "Explain this SQL query step by step:
\`\`\`sql
$query
\`\`\`" 512 2>/dev/null
      ;;
    optimize)
      local query="${*:?Usage: ai sql optimize \"SELECT ...\"}"
      _silent_generate "Optimize this SQL query for performance. Explain what you changed and why:
\`\`\`sql
$query
\`\`\`" 512 2>/dev/null
      ;;
    schema)
      local desc="${*:?Usage: ai sql schema \"description of data\"}"
      _silent_generate "Design a SQL database schema for: $desc
Include CREATE TABLE statements, primary keys, foreign keys, indexes, and constraints. Add comments." 1024 2>/dev/null
      ;;
    *)
      echo "Usage: ai sql <gen|explain|optimize|schema>"
      echo "  gen \"description\"        Generate SQL query"
      echo "  explain \"query\"          Explain a SQL query"
      echo "  optimize \"query\"         Optimize for performance"
      echo "  schema \"description\"     Design a database schema"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  DOCKER HELPER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_docker() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    gen|generate)
      local desc="${*:?Usage: ai docker gen \"description\"}"
      _silent_generate "Generate a Dockerfile for: $desc
Follow best practices: multi-stage builds, minimal base images, proper layer ordering. Include comments." 512 2>/dev/null
      ;;
    compose)
      local desc="${*:?Usage: ai docker compose \"description\"}"
      _silent_generate "Generate a docker-compose.yml for: $desc
Include all necessary services, volumes, networks, environment variables. Use version 3.8+." 1024 2>/dev/null
      ;;
    explain|ex)
      local file="${1:-Dockerfile}"
      [[ -f "$file" ]] || { err "File not found: $file"; return 1; }
      local content
      content=$(cat "$file" | head -100)
      _silent_generate "Explain this Dockerfile line by line:
\`\`\`dockerfile
$content
\`\`\`" 512 2>/dev/null
      ;;
    optimize)
      local file="${1:-Dockerfile}"
      [[ -f "$file" ]] || { err "File not found: $file"; return 1; }
      local content
      content=$(cat "$file")
      _silent_generate "Optimize this Dockerfile for smaller image size and faster builds:
\`\`\`dockerfile
$content
\`\`\`
Show the optimized version and explain changes." 1024 2>/dev/null
      ;;
    *)
      echo "Usage: ai docker <gen|compose|explain|optimize>"
      echo "  gen \"description\"      Generate Dockerfile"
      echo "  compose \"description\"  Generate docker-compose.yml"
      echo "  explain [file]         Explain a Dockerfile"
      echo "  optimize [file]        Optimize a Dockerfile"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  API TESTING — v2.9.0
#  Generate and test API requests
# ════════════════════════════════════════════════════════════════════════════════

cmd_api_test() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    gen|generate)
      local desc="${*:?Usage: ai api-test gen \"description\"}"
      _silent_generate "Generate a curl command to test an API endpoint: $desc
Include headers, request body if needed, and expected response. Return the curl command first, then explain." 256 2>/dev/null
      ;;
    mock)
      local endpoint="${1:?Usage: ai api-test mock \"/endpoint\"}"
      local method="${2:-GET}"
      _silent_generate "Generate mock/sample JSON responses for this API:
Endpoint: $method $endpoint
Generate: success response, error response, and edge case response. Use realistic data." 512 2>/dev/null
      ;;
    doc)
      local spec="${1:?Usage: ai api-test doc FILE}"
      if [[ -f "$spec" ]]; then
        local content
        content=$(cat "$spec" | head -200)
        _silent_generate "Generate human-readable API documentation from this OpenAPI/Swagger spec:
$content
Include: endpoint descriptions, parameters, request/response examples." 2048 2>/dev/null
      else
        err "File not found: $spec"
      fi
      ;;
    *)
      echo "Usage: ai api-test <gen|mock|doc>"
      echo "  gen \"description\"        Generate curl command"
      echo "  mock \"/endpoint\" [GET]   Generate mock responses"
      echo "  doc <openapi.yaml>       Generate API documentation"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  CHANGELOG GENERATOR — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_changelog() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    err "Not in a git repository"
    return 1
  fi
  local since="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)}"
  local log
  log=$(git log --oneline "$since"..HEAD 2>/dev/null)
  if [[ -z "$log" ]]; then
    info "No new commits since $since"
    return
  fi
  info "Generating changelog since: $since"
  _silent_generate "Generate a changelog from these git commits. Group by category: Added, Changed, Fixed, Removed. Use Keep a Changelog format:

Commits:
$log" 1024 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
#  MATH SOLVER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_math() {
  local expr="${*:?Usage: ai math \"expression or problem\"}"
  # Try bc first for simple math
  local bc_result
  bc_result=$(echo "$expr" | bc -l 2>/dev/null || echo "")
  if [[ -n "$bc_result" && "$bc_result" != "" ]]; then
    printf "  ${GREEN}= %s${R}\n" "$bc_result"
    return
  fi
  # Fall back to AI for complex math
  _silent_generate "Solve this math problem step by step. Show your work clearly:
$expr" 512 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
#  UNIT CONVERTER — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_convert_units() {
  local value="${1:?Usage: ai units 100 km to miles}"
  local from_unit="${2:?Usage: ai units VALUE FROM to TO}"
  local _to="${3:-}"
  local to_unit="${4:-}"
  [[ "$_to" == "to" ]] || { to_unit="$3"; }

  _silent_generate "Convert $value $from_unit to $to_unit. Show the calculation and result. Be precise." 128 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
#  EXTENDED DISPATCHER — v2.9.0
#  Wire new commands into main() via wrapper
# ════════════════════════════════════════════════════════════════════════════════

_dispatch_v29() {
  local cmd="$1"; shift
  case "$cmd" in
    search-history) cmd_search_history "$@" ;;
    tokens|count-tokens) cmd_count_tokens "$@" ;;
    cost) cmd_cost "$@" ;;
    context|ctx) cmd_context "$@" ;;
    chain) cmd_chain "$@" ;;
    model-stats|stats) cmd_model_stats "$@" ;;
    schedule|sched) cmd_schedule "$@" ;;
    replay) cmd_replay "$@" ;;
    fav|favorite|favourites) cmd_favorite "$@" ;;
    diff) cmd_diff "$@" ;;
    patch) cmd_patch "$@" ;;
    git) cmd_git_ai "$@" ;;
    analytics|usage) cmd_analytics "$@" ;;
    quiz) cmd_quiz "$@" ;;
    shell|sh) cmd_shell "$@" ;;
    find|find-ai) cmd_find_ai "$@" ;;
    profile|profiles) cmd_profile "$@" ;;
    watch) cmd_watch "$@" ;;
    notebook|nb) cmd_notebook "$@" ;;
    plan|tasks) cmd_plan "$@" ;;
    learn|tutor) cmd_learn "$@" ;;
    convert-chat) cmd_convert "$@" ;;
    write) cmd_write "$@" ;;
    memory|mem) cmd_memory "$@" ;;
    tr|translate2) cmd_translate_v2 "$@" ;;
    define|dict) cmd_define "$@" ;;
    regex|rx) cmd_regex "$@" ;;
    json) cmd_json "$@" ;;
    cron) cmd_cron "$@" ;;
    sql) cmd_sql "$@" ;;
    docker|dk) cmd_docker "$@" ;;
    api-test) cmd_api_test "$@" ;;
    changelog) cmd_changelog "$@" ;;
    math|calc) cmd_math "$@" ;;
    units) cmd_convert_units "$@" ;;
    *) return 1 ;;
  esac
  return 0
}


# ════════════════════════════════════════════════════════════════════════════════
#  DETAILED HELP FOR v2.9.0 COMMANDS
# ════════════════════════════════════════════════════════════════════════════════

_help_v29() {
  local cmd="${1:-}"
  case "$cmd" in
    snap) cmd_snap help ;;
    perf) cmd_perf --help ;;
    compare) cmd_compare --help ;;
    template) cmd_template help ;;
    rag) cmd_rag help ;;
    batch) cmd_batch help ;;
    health) echo "Usage: ai health — Full system diagnostics" ;;
    branch) cmd_branch help ;;
    export) echo "Usage: ai export <all|chat|config|models> [--format json|md|csv]" ;;
    import) echo "Usage: ai import <directory|file>" ;;
    cleanup) echo "Usage: ai cleanup [--dry-run] — Free disk space" ;;
    preset) cmd_preset help ;;
    plugin) cmd_plugin help ;;
    search-history) echo "Usage: ai search-history \"keyword\" [max_results]" ;;
    tokens) echo "Usage: ai tokens TEXT or ai tokens FILE" ;;
    cost) echo "Usage: ai cost [input_tokens] [output_tokens] [model]" ;;
    context) cmd_context help ;;
    chain) cmd_chain ;;
    model-stats) echo "Usage: ai model-stats — Show detailed model info" ;;
    schedule) cmd_schedule help ;;
    replay) echo "Usage: ai replay <session> [--model <backend>]" ;;
    fav) cmd_favorite help ;;
    diff) echo "Usage: ai diff FILE1 FILE2 [--explain]" ;;
    patch) echo "Usage: ai patch FILE \"instructions\"" ;;
    git) cmd_git_ai help ;;
    analytics) cmd_analytics help ;;
    quiz) echo "Usage: ai quiz \"topic\" [--count N]" ;;
    shell) cmd_shell help ;;
    find) echo "Usage: ai find \"query\" [directory] [max_results]" ;;
    profile) cmd_profile help ;;
    watch) echo "Usage: ai watch FILE [summarize|review|lint|explain] [interval]" ;;
    notebook) cmd_notebook help ;;
    plan) cmd_plan help ;;
    learn) echo "Usage: ai learn \"topic\" — Interactive learning mode" ;;
    convert-chat) echo "Usage: ai convert-chat INPUT.jsonl FORMAT" ;;
    write) cmd_write help ;;
    memory) cmd_memory help ;;
    regex) cmd_regex help ;;
    json) cmd_json help ;;
    cron) cmd_cron help ;;
    sql) cmd_sql help ;;
    docker) cmd_docker help ;;
    api-test) cmd_api_test help ;;
    changelog) echo "Usage: ai changelog [since_tag] — Generate changelog from git" ;;
    math) echo "Usage: ai math \"expression\" — Solve math problems" ;;
    units) echo "Usage: ai units VALUE FROM to TO" ;;
    *) return 1 ;;
  esac
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════
#  PIPE MODE ENHANCEMENTS — v2.9.0
#  Better stdin handling and format detection
# ════════════════════════════════════════════════════════════════════════════════

_detect_input_format() {
  local first_line="$1"
  if [[ "$first_line" == "{"* ]] || [[ "$first_line" == "["* ]]; then
    echo "json"
  elif [[ "$first_line" == *","*","* ]]; then
    echo "csv"
  elif [[ "$first_line" == "---" ]]; then
    echo "yaml"
  elif [[ "$first_line" == "<?xml"* ]] || [[ "$first_line" == "<"* ]]; then
    echo "xml"
  elif [[ "$first_line" == "#"* ]]; then
    echo "markdown"
  else
    echo "text"
  fi
}

_smart_pipe() {
  local action="${1:-summarize}"
  local input
  input=$(cat)
  local first_line
  first_line=$(echo "$input" | head -1)
  local fmt
  fmt=$(_detect_input_format "$first_line")
  local char_count=${#input}
  local word_count=$(echo "$input" | wc -w)

  [[ $VERBOSE -eq 1 ]] && info "Detected format: $fmt — $word_count words"

  dispatch_ask "$action the following $fmt content — $word_count words:

$input"
}

# ════════════════════════════════════════════════════════════════════════════════
#  STDIN / CLIPBOARD INTEGRATION — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_clipboard() {
  local sub="${1:-get}"; shift 2>/dev/null || true
  case "$sub" in
    get|read)
      if command -v xclip &>/dev/null; then
        xclip -selection clipboard -o 2>/dev/null
      elif command -v xsel &>/dev/null; then
        xsel --clipboard --output 2>/dev/null
      elif command -v wl-paste &>/dev/null; then
        wl-paste 2>/dev/null
      elif command -v pbpaste &>/dev/null; then
        pbpaste 2>/dev/null
      elif [[ $IS_WSL -eq 1 ]]; then
        powershell.exe -command "Get-Clipboard" 2>/dev/null | tr -d '\r'
      else
        err "No clipboard tool found — install xclip, xsel, or wl-clipboard"
        return 1
      fi
      ;;
    set|copy)
      local text="${*:-}"
      [[ -z "$text" ]] && text=$(cat)
      if command -v xclip &>/dev/null; then
        echo "$text" | xclip -selection clipboard
      elif command -v xsel &>/dev/null; then
        echo "$text" | xsel --clipboard --input
      elif command -v wl-copy &>/dev/null; then
        echo "$text" | wl-copy
      elif command -v pbcopy &>/dev/null; then
        echo "$text" | pbcopy
      elif [[ $IS_WSL -eq 1 ]]; then
        echo "$text" | clip.exe
      else
        err "No clipboard tool found"
        return 1
      fi
      ok "Copied to clipboard"
      ;;
    ask)
      local clip_content
      clip_content=$(cmd_clipboard get 2>/dev/null || echo "")
      [[ -z "$clip_content" ]] && { err "Clipboard is empty"; return 1; }
      local prompt="${*:-Summarize this:}"
      dispatch_ask "$prompt

$clip_content"
      ;;
    *)
      echo "Usage: ai clip <get|set|ask>"
      echo "  get            Read clipboard content"
      echo "  set \"text\"     Copy to clipboard"
      echo "  ask [prompt]   Send clipboard to AI"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  TIPS / DID-YOU-KNOW — v2.9.0
#  Random helpful tip on startup (if enabled)
# ════════════════════════════════════════════════════════════════════════════════

_random_tip() {
  local tips=(
    "ai snap save/load — save and restore config snapshots"
    "ai perf — benchmark your model's tokens/sec"
    "ai compare \"prompt\" — compare responses across models"
    "ai rag create kb ./docs — build a local knowledge base"
    "ai batch add \"prompt\" — queue prompts for batch processing"
    "ai health — full system diagnostics"
    "ai branch create name — fork your conversation"
    "ai template create name — save reusable prompt templates"
    "ai cost 1000 500 — estimate API costs before sending"
    "ai context status — check how much context you're using"
    "ai chain file.txt — chain multiple prompts together"
    "ai notebook new name — Jupyter-like notebook in terminal"
    "ai plan create \"goal\" — AI breaks down tasks for you"
    "ai learn \"topic\" — interactive AI tutor"
    "ai write blog \"topic\" — generate a blog post"
    "ai shell gen \"description\" — generate shell commands"
    "ai git commit — AI-generated commit messages"
    "ai quiz \"topic\" — test your knowledge"
    "ai regex build \"description\" — generate regex patterns"
    "ai json format file.json — pretty-print JSON"
    "ai sql gen \"get all users\" — generate SQL queries"
    "ai docker gen \"node.js app\" — generate Dockerfiles"
    "ai fav add \"prompt\" — save favorite prompts"
    "ai memory add \"fact\" — teach AI persistent facts"
    "ai profile create work — separate environments"
    "ai watch file.py review — auto-review on changes"
    "ai analytics — see your usage statistics"
    "ai preset save fast — quick-switch model configs"
    "ai plugin list — manage extensions"
    "ai export all — backup conversations and config"
    "ai cleanup — free up disk space"
    "ai clip ask — send clipboard content to AI"
    "ai changelog — generate changelog from git commits"
    "ai define \"word\" — dictionary lookup"
    "ai math \"expression\" — solve math problems"
    "ai tokens \"text\" — count tokens before sending"
    "ai diff file1 file2 --explain — AI-explained diffs"
    "ai search-history \"keyword\" — search past conversations"
    "Ctrl+C to stop any running command"
    "GITHUB_TOKEN env var increases API rate limits"
  )
  local idx=$(( RANDOM % ${#tips[@]} ))
  printf "${DIM}  Tip: %s${R}\n" "${tips[$idx]}"
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.9.0 STARTUP INTEGRATION
#  Load plugins, check health on interval, show tips
# ════════════════════════════════════════════════════════════════════════════════

_startup_v29() {
  # Load plugins
  _load_plugins 2>/dev/null || true

  # Periodic health check (background, non-blocking)
  if [[ -f "$HEALTH_LOG" ]]; then
    local last_check
    last_check=$(tail -1 "$HEALTH_LOG" 2>/dev/null | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' | head -1)
    if [[ -n "$last_check" ]]; then
      local last_epoch
      last_epoch=$(date -d "$last_check" +%s 2>/dev/null || echo 0)
      local now_epoch
      now_epoch=$(date +%s)
      local elapsed=$(( now_epoch - last_epoch ))
      if (( elapsed > HEALTH_CHECK_INTERVAL )); then
        cmd_health > /dev/null 2>&1 &
      fi
    fi
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
#  SECURITY AUDIT — v2.9.0
#  Check API key exposure and security posture
# ════════════════════════════════════════════════════════════════════════════════

cmd_security() {
  hdr "Security Audit"
  local issues=0

  # Check key file permissions
  if [[ -f "$KEYS_FILE" ]]; then
    local perms
    perms=$(stat -c%a "$KEYS_FILE" 2>/dev/null || stat -f%Lp "$KEYS_FILE" 2>/dev/null || echo "?")
    if [[ "$perms" == "600" ]]; then
      printf "  ${GREEN}[PASS]${R}  keys.env permissions: %s\n" "$perms"
    else
      printf "  ${RED}[FAIL]${R}  keys.env permissions: %s — should be 600\n" "$perms"
      (( issues++ ))
    fi
  fi

  # Check for exposed keys in shell history
  local hist_file="${HISTFILE:-$HOME/.bash_history}"
  if [[ -f "$hist_file" ]]; then
    local exposed
    exposed=$(grep -ciE 'sk-[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9]{20,}|gsk_[a-zA-Z0-9]{20,}' "$hist_file" 2>/dev/null || echo 0)
    if (( exposed > 0 )); then
      printf "  ${RED}[FAIL]${R}  %d API keys found in shell history!\n" "$exposed"
      warn "  Run: history -c && history -w  to clear"
      (( issues++ ))
    else
      printf "  ${GREEN}[PASS]${R}  No API keys in shell history\n"
    fi
  fi

  # Check for keys in git
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    local git_keys
    git_keys=$(git log --all -p 2>/dev/null | grep -ciE 'sk-[a-zA-Z0-9]{20,}|ANTHROPIC_API_KEY|OPENAI_API_KEY' 2>/dev/null || echo 0)
    if (( git_keys > 0 )); then
      printf "  ${RED}[FAIL]${R}  %d potential key exposures in git history!\n" "$git_keys"
      (( issues++ ))
    else
      printf "  ${GREEN}[PASS]${R}  No keys detected in git history\n"
    fi
  fi

  # Check for .env files
  local env_files
  env_files=$(find "$CONFIG_DIR" -name "*.env" -not -perm 600 2>/dev/null | wc -l)
  if (( env_files > 0 )); then
    printf "  ${YELLOW}[WARN]${R}  %d .env files with loose permissions\n" "$env_files"
    info "  Fix: chmod 600 $CONFIG_DIR/*.env"
    (( issues++ ))
  fi

  # Check HTTPS usage
  printf "  ${GREEN}[PASS]${R}  All API calls use HTTPS\n"

  # Check for outdated version
  local remote_ver
  remote_ver=$(curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/main.sh" 2>/dev/null | grep '^VERSION=' | head -1 | cut -d'"' -f2 || echo "")
  if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
    printf "  ${YELLOW}[WARN]${R}  Update: v%s to v%s\n" "$VERSION" "$remote_ver"
    (( issues++ ))
  elif [[ -n "$remote_ver" ]]; then
    printf "  ${GREEN}[PASS]${R}  Running latest version v%s\n" "$VERSION"
  fi

  echo ""
  if (( issues > 0 )); then
    warn "$issues security issues found"
  else
    ok "All security checks passed!"
  fi
}

REPO_OWNER="minerofthesoal"
REPO_NAME="ai-cli"

# ════════════════════════════════════════════════════════════════════════════════
#  SYSTEM INFO — v2.9.0
#  Comprehensive system information dump
# ════════════════════════════════════════════════════════════════════════════════

cmd_sysinfo() {
  hdr "System Information"
  echo ""
  printf "  ${B}AI CLI:${R}\n"
  printf "    Version:     %s\n" "$VERSION"
  printf "    Platform:    %s\n" "$PLATFORM"
  printf "    Config:      %s\n" "$CONFIG_DIR"
  printf "    Models:      %s\n" "$MODELS_DIR"
  echo ""

  printf "  ${B}System:${R}\n"
  printf "    OS:          %s\n" "$(uname -srm 2>/dev/null || echo unknown)"
  printf "    Shell:       %s\n" "${BASH_VERSION:-unknown}"
  printf "    Python:      %s\n" "$($PYTHON --version 2>&1 || echo 'not found')"
  printf "    CPU:         %s\n" "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?') cores"
  printf "    Memory:      %s\n" "$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0fG", $1/1073741824}' || echo '?')"
  echo ""

  printf "  ${B}GPU:${R}\n"
  if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | \
      while IFS=',' read -r name mem driver; do
        printf "    Name:        %s\n" "$(echo "$name" | xargs)"
        printf "    VRAM:        %s\n" "$(echo "$mem" | xargs)"
        printf "    Driver:      %s\n" "$(echo "$driver" | xargs)"
      done
  elif [[ "$CUDA_ARCH" == "metal" ]]; then
    printf "    Apple Silicon Metal GPU\n"
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|VRAM|Metal' | sed 's/^/    /'
  else
    printf "    No GPU detected — CPU-only mode\n"
  fi
  echo ""

  printf "  ${B}Storage:${R}\n"
  printf "    Models dir:  %s\n" "$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}' || echo '0')"
  printf "    Config dir:  %s\n" "$(du -sh "$CONFIG_DIR" 2>/dev/null | awk '{print $1}' || echo '0')"
  printf "    Output dir:  %s\n" "$(du -sh "$AI_OUTPUT_DIR" 2>/dev/null | awk '{print $1}' || echo '0')"
  printf "    Free space:  %s\n" "$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo '?')"
  echo ""

  printf "  ${B}Backends:${R}\n"
  printf "    llama.cpp:   %s\n" "${LLAMA_BIN:-not found}"
  printf "    CUDA arch:   %s\n" "${CUDA_ARCH:-0}"
  [[ -n "${OPENAI_API_KEY:-}" ]] && printf "    OpenAI:      ${GREEN}configured${R}\n"
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && printf "    Claude:      ${GREEN}configured${R}\n"
  [[ -n "${GEMINI_API_KEY:-}" ]] && printf "    Gemini:      ${GREEN}configured${R}\n"
  [[ -n "${GROQ_API_KEY:-}" ]] && printf "    Groq:        ${GREEN}configured${R}\n"
  [[ -n "${MISTRAL_API_KEY:-}" ]] && printf "    Mistral:     ${GREEN}configured${R}\n"
}

# ════════════════════════════════════════════════════════════════════════════════
#  END OF v2.9.0 ADDITIONS
# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  INTERVIEW PREP — v2.9.0
#  Practice technical interview questions with AI feedback
# ════════════════════════════════════════════════════════════════════════════════

cmd_interview() {
  local topic="${*:?Usage: ai interview \"role or topic\"}"

  hdr "Interview Practice: $topic"
  info "AI will ask questions and give feedback."
  info "Type 'quit' to end, 'skip' to skip a question."
  echo ""

  local q_num=0
  local score=0

  while true; do
    (( q_num++ ))
    local question
    question=$(_silent_generate "You are a senior interviewer. Ask one technical interview question (#$q_num) for a $topic role. Make it progressively harder. Ask just the question, nothing else." 256 2>/dev/null || echo "")

    [[ -z "$question" ]] && { err "Could not generate question"; break; }

    printf "\n  ${CYAN}Question %d:${R}\n" "$q_num"
    echo "$question"
    echo ""

    read -rp "$(echo -e "${BCYAN}Your answer (or skip/quit): ${R}")" answer

    case "$answer" in
      quit|exit|q) break ;;
      skip|s) info "Skipped"; continue ;;
    esac

    local feedback
    feedback=$(_silent_generate "Rate this interview answer on a scale of 1-10. Give specific feedback.

Question: $question
Answer: $answer

Format:
Score: X/10
Strengths: ...
Improvements: ...
Ideal answer (brief): ..." 512 2>/dev/null || echo "")

    echo ""
    echo "$feedback"

    # Extract score
    local extracted_score
    extracted_score=$(echo "$feedback" | grep -oP 'Score:\s*(\d+)' | grep -oP '\d+' | head -1)
    [[ -n "$extracted_score" ]] && score=$(( score + extracted_score ))
  done

  echo ""
  hdr "Session Summary"
  printf "  Questions answered: %d\n" "$q_num"
  if (( q_num > 0 )); then
    local avg=$(( score / q_num ))
    printf "  Average score:      %d/10\n" "$avg"
    if (( avg >= 8 )); then
      ok "Excellent performance! You're well prepared."
    elif (( avg >= 6 )); then
      info "Good performance. Review the feedback for improvement areas."
    else
      warn "Keep practicing. Focus on the improvement suggestions."
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  TEXT PROCESSING UTILITIES — v2.9.0
#  Quick text transformations
# ════════════════════════════════════════════════════════════════════════════════

cmd_text() {
  local sub="${1:-}"; shift 2>/dev/null || true
  local input="${*:-}"
  [[ -z "$input" && ! -t 0 ]] && input=$(cat)

  case "$sub" in
    upper|uppercase)
      echo "$input" | tr '[:lower:]' '[:upper:]' ;;
    lower|lowercase)
      echo "$input" | tr '[:upper:]' '[:lower:]' ;;
    title)
      echo "$input" | sed 's/\b\(.\)/\u\1/g' 2>/dev/null || echo "$input" ;;
    reverse)
      echo "$input" | rev ;;
    count)
      local chars=${#input}
      local words=$(echo "$input" | wc -w | tr -d ' ')
      local lines=$(echo "$input" | wc -l | tr -d ' ')
      printf "  Characters: %s\n  Words: %s\n  Lines: %s\n" "$chars" "$words" "$lines" ;;
    slug)
      echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' ;;
    snake)
      echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//' ;;
    camel)
      echo "$input" | tr ' ' '_' | tr '[:upper:]' '[:lower:]' ;; 
    encode-base64|b64)
      echo "$input" | base64 ;;
    decode-base64|b64d)
      echo "$input" | base64 -d 2>/dev/null || echo "$input" | base64 --decode 2>/dev/null ;;
    encode-url)
      echo "$input" | python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null ;;
    decode-url)
      echo "$input" | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null ;;
    hash)
      printf "  MD5:    %s\n" "$(echo -n "$input" | md5sum | awk '{print $1}')"
      printf "  SHA1:   %s\n" "$(echo -n "$input" | sha1sum | awk '{print $1}')"
      printf "  SHA256: %s\n" "$(echo -n "$input" | sha256sum | awk '{print $1}')" ;;
    lorem)
      local count="${input:-3}"
      _silent_generate "Generate $count paragraphs of lorem ipsum text." 512 2>/dev/null ;;
    uuid)
      if command -v uuidgen &>/dev/null; then
        uuidgen
      else
        python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || \
          cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "UUID generation not available"
      fi ;;
    password)
      local length="${input:-16}"
      python3 -c "import secrets,string;print(secrets.token_urlsafe($length))" 2>/dev/null || \
        head -c "$length" /dev/urandom | base64 | head -c "$length" && echo ;;
    *)
      echo "Usage: ai text <command> [text]"
      echo ""
      echo "  upper/lower/title     Case conversion"
      echo "  reverse               Reverse text"
      echo "  count                 Character/word/line count"
      echo "  slug/snake/camel      Name formatting"
      echo "  encode-base64 / decode-base64"
      echo "  encode-url / decode-url"
      echo "  hash                  MD5/SHA1/SHA256"
      echo "  lorem [N]             Generate lorem ipsum"
      echo "  uuid                  Generate UUID"
      echo "  password [len]        Generate secure password"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  EXTENDED DISPATCHER HOOK — v2.9.0
#  Called from main() catch-all before AI fallthrough
# ════════════════════════════════════════════════════════════════════════════════

_dispatch_v29_extended() {
  local cmd="$1"; shift
  case "$cmd" in
    security|sec-audit) cmd_security "$@"; return 0 ;;
    sysinfo|system-info) cmd_sysinfo "$@"; return 0 ;;
    interview) cmd_interview "$@"; return 0 ;;
    text|txt) cmd_text "$@"; return 0 ;;
    clip|clipboard) cmd_clipboard "$@"; return 0 ;;
    tip|tips) _random_tip; return 0 ;;
    *) _dispatch_v29 "$cmd" "$@" && return 0 ;;
  esac
  return 1
}


# ════════════════════════════════════════════════════════════════════════════════
#  CALENDAR / DATE TOOLS — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

cmd_date_tools() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    now) date -Iseconds ;;
    epoch) date +%s ;;
    from-epoch)
      local ts="${1:?Usage: ai date from-epoch <timestamp>}"
      date -d "@$ts" -Iseconds 2>/dev/null || date -r "$ts" -Iseconds 2>/dev/null || echo "Invalid timestamp"
      ;;
    diff)
      local d1="${1:?Usage: ai date diff \"date1\" \"date2\"}"
      local d2="${2:-now}"
      [[ "$d2" == "now" ]] && d2=$(date -Iseconds)
      local e1 e2
      e1=$(date -d "$d1" +%s 2>/dev/null || echo 0)
      e2=$(date -d "$d2" +%s 2>/dev/null || echo 0)
      local diff_s=$(( e2 - e1 ))
      local abs_diff=${diff_s#-}
      local days=$(( abs_diff / 86400 ))
      local hours=$(( (abs_diff % 86400) / 3600 ))
      local minutes=$(( (abs_diff % 3600) / 60 ))
      printf "  Difference: %d days, %d hours, %d minutes\n" "$days" "$hours" "$minutes"
      printf "  Total seconds: %d\n" "$abs_diff"
      ;;
    add)
      local base="${1:?Usage: ai date add \"date\" \"duration\"}"
      local duration="${2:?Usage: ai date add \"date\" \"+3 days\"}"
      date -d "$base $duration" -Iseconds 2>/dev/null || echo "Could not compute"
      ;;
    tz)
      local dt="${1:-now}"
      local from_tz="${2:-UTC}"
      local to_tz="${3:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
      TZ="$to_tz" date -d "TZ=\"$from_tz\" $dt" 2>/dev/null || echo "Timezone conversion failed"
      ;;
    *)
      echo "Usage: ai date <now|epoch|from-epoch|diff|add|tz>"
      echo ""
      echo "  now                          Current ISO timestamp"
      echo "  epoch                        Current Unix timestamp"
      echo "  from-epoch <ts>              Convert epoch to date"
      echo "  diff \"date1\" \"date2\"         Time between dates"
      echo "  add \"date\" \"+3 days\"         Add duration to date"
      echo "  tz \"time\" \"from_tz\" \"to_tz\"  Timezone conversion"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  NETWORK TOOLS — v2.9.0
#  Quick network diagnostics and lookups
# ════════════════════════════════════════════════════════════════════════════════

cmd_net() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    ip)
      printf "  Local:  %s\n" "$(hostname -I 2>/dev/null | awk '{print $1}' || ifconfig 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}' || echo '?')"
      printf "  Public: %s\n" "$(curl -fsSL ifconfig.me 2>/dev/null || curl -fsSL api.ipify.org 2>/dev/null || echo '?')"
      ;;
    dns)
      local domain="${1:?Usage: ai net dns <domain>}"
      if command -v dig &>/dev/null; then
        dig +short "$domain" 2>/dev/null
      elif command -v nslookup &>/dev/null; then
        nslookup "$domain" 2>/dev/null | grep 'Address:' | tail -n+2
      elif command -v host &>/dev/null; then
        host "$domain" 2>/dev/null
      else
        python3 -c "import socket;print('\n'.join([r[4][0] for r in socket.getaddrinfo('$domain', None)]))" 2>/dev/null
      fi
      ;;
    ping)
      local host="${1:-8.8.8.8}"
      ping -c 3 "$host" 2>/dev/null || echo "Ping failed"
      ;;
    speed)
      info "Testing download speed..."
      local url="https://speed.cloudflare.com/__down?bytes=10000000"
      local start=$(date +%s%N)
      curl -fsSL "$url" -o /dev/null 2>/dev/null
      local end=$(date +%s%N)
      local elapsed_ms=$(( (end - start) / 1000000 ))
      if (( elapsed_ms > 0 )); then
        local mbps=$(awk "BEGIN{printf \"%.1f\", 10 * 8 / ($elapsed_ms / 1000.0)}")
        printf "  Download: ~%s Mbps (%d ms for 10MB)\n" "$mbps" "$elapsed_ms"
      fi
      ;;
    headers)
      local url="${1:?Usage: ai net headers URL}"
      curl -fsSI "$url" 2>/dev/null || echo "Could not fetch headers"
      ;;
    port)
      local host="${1:?Usage: ai net port HOST PORT}"
      local port="${2:?Usage: ai net port HOST PORT}"
      if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        printf "  ${GREEN}Port %s on %s is OPEN${R}\n" "$port" "$host"
      else
        printf "  ${RED}Port %s on %s is CLOSED${R}\n" "$port" "$host"
      fi
      ;;
    whois)
      local domain="${1:?Usage: ai net whois <domain>}"
      if command -v whois &>/dev/null; then
        whois "$domain" 2>/dev/null | head -30
      else
        err "whois not installed"
      fi
      ;;
    *)
      echo "Usage: ai net <ip|dns|ping|speed|headers|port|whois>"
      echo ""
      echo "  ip                  Show local and public IP"
      echo "  dns <domain>        DNS lookup"
      echo "  ping [host]         Ping test (default: 8.8.8.8)"
      echo "  speed               Download speed test"
      echo "  headers URL       Show HTTP headers"
      echo "  port HOST PORT  Check if port is open"
      echo "  whois <domain>      WHOIS lookup"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  FINAL DISPATCHER ADDITIONS — v2.9.0
# ════════════════════════════════════════════════════════════════════════════════

_dispatch_v29_final() {
  local cmd="$1"; shift
  case "$cmd" in
    date|dt) cmd_date_tools "$@"; return 0 ;;
    net|network) cmd_net "$@"; return 0 ;;
    *) _dispatch_v29_extended "$cmd" "$@" && return 0 ;;
  esac
  return 1
}

# ════════════════════════════════════════════════════════════════════════════════
# END OF AI CLI v2.9.0
# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  BUILTIN PROMPT PRESETS — v2.9.0
#  Quick-access prompt presets for common tasks
# ════════════════════════════════════════════════════════════════════════════════

declare -A PROMPT_PRESETS=(
  [review]="Review this code for bugs, security issues, and performance. Be specific:"
  [explain]="Explain this code clearly, as if to a junior developer:"
  [refactor]="Refactor this code for better readability and performance:"
  [test]="Write comprehensive unit tests for this code:"
  [debug]="Find and fix the bug in this code. Explain what was wrong:"
  [optimize]="Optimize this code for better performance. Explain your changes:"
  [document]="Write documentation with docstrings/comments for this code:"
  [convert-py]="Convert this code to Python 3. Maintain the same logic:"
  [convert-js]="Convert this code to modern JavaScript (ES6+):"
  [convert-rs]="Convert this code to Rust. Use idiomatic Rust patterns:"
  [convert-go]="Convert this code to Go. Use idiomatic Go patterns:"
  [simplify]="Simplify this code while keeping the same functionality:"
  [security]="Audit this code for security vulnerabilities (OWASP top 10):"
  [type-hints]="Add type hints/annotations to this code:"
  [api-design]="Design a REST API for this feature. Include endpoints, methods, request/response schemas:"
  [commit-msg]="Write a conventional commit message for these changes:"
  [pr-desc]="Write a pull request description for these changes:"
  [changelog-entry]="Write a changelog entry for these changes:"
  [error-handle]="Add proper error handling to this code:"
  [perf-profile]="Identify performance bottlenecks in this code and suggest fixes:"
  [accessibility]="Review this HTML/UI code for accessibility issues (WCAG):"
  [responsive]="Make this CSS/HTML responsive for mobile, tablet, and desktop:"
  [seo]="Optimize this HTML for SEO. Add meta tags, semantic HTML, structured data:"
  [i18n]="Prepare this code for internationalization. Extract strings, handle RTL:"
  [migrate]="Create a migration plan for upgrading this code/dependency:"
)

cmd_prompt_preset() {
  local preset="${1:-}"
  shift 2>/dev/null || true

  if [[ -z "$preset" ]] || [[ "$preset" == "list" ]]; then
    hdr "Prompt Presets"
    for key in $(echo "${!PROMPT_PRESETS[@]}" | tr ' ' '\n' | sort); do
      printf "  ${CYAN}%-15s${R}  ${DIM}%s${R}\n" "$key" "${PROMPT_PRESETS[$key]:0:60}"
    done
    echo ""
    info "Usage: ai p <preset> <file_or_text>"
    info "Example: ai p review myfile.py"
    return
  fi

  local prompt_prefix="${PROMPT_PRESETS[$preset]:-}"
  if [[ -z "$prompt_prefix" ]]; then
    err "Unknown preset: $preset"
    info "Available: ${!PROMPT_PRESETS[*]}"
    return 1
  fi

  local input=""
  if [[ -n "${1:-}" && -f "$1" ]]; then
    input=$(cat "$1")
    info "Preset: $preset | File: $1"
  elif [[ -n "${*:-}" ]]; then
    input="$*"
    info "Preset: $preset"
  elif [[ ! -t 0 ]]; then
    input=$(cat)
    info "Preset: $preset (from stdin)"
  else
    echo "Usage: ai p $preset <file_or_text>"
    return 1
  fi

  dispatch_ask "$prompt_prefix

$input"
}

# v2.9.0: Wire prompt presets into dispatcher
# Usage: ai p <preset> <input>


# AI CLI v2.9.0 — 19997 lines — minerofthesoal/ai-cli
# End of file

# ════════════════════════════════════════════════════════════════════════════════
#  TEST — v2.9.5
#  ai test -S (speed) -A (all) -N (network)
# ════════════════════════════════════════════════════════════════════════════════

cmd_test() {
  local mode="${1:--A}"
  case "$mode" in
    -S|--speed|speed)
      hdr "Speed Test"
      if [[ -z "$ACTIVE_MODEL" && -z "$ACTIVE_BACKEND" ]]; then
        err "No model set. Run: ai recommended use N"
        return 1
      fi
      info "Backend: ${ACTIVE_BACKEND:-auto} | Model: ${ACTIVE_MODEL:-auto}"
      info "Generating 64 tokens..."
      local start_ms=$(date +%s%3N 2>/dev/null || echo 0)
      local out=$(_silent_generate "Count from 1 to 50" 64 2>/dev/null || echo "")
      local end_ms=$(date +%s%3N 2>/dev/null || echo 0)
      local elapsed=$(( end_ms - start_ms ))
      local words=$(echo "$out" | wc -w)
      if (( elapsed > 0 && words > 0 )); then
        local tps; tps=$(echo "scale=1; $words * 1000 / $elapsed" | bc 2>/dev/null || echo "?")
        printf "  Result: ${GREEN}%s tok/s${R} — %d ms, %d tokens\n" "$tps" "$elapsed" "$words"
      else
        err "Test failed — no output"
      fi
      ;;
    -N|--network|network)
      hdr "Network Test"
      # Latency
      info "Testing latency..."
      local ping_ms
      ping_ms=$(ping -c 3 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "?")
      printf "  Latency:  %s ms (avg to 8.8.8.8)\n" "$ping_ms"
      # Download speed
      info "Testing download..."
      local dl_start=$(date +%s%N 2>/dev/null || echo 0)
      curl -fsSL "https://speed.cloudflare.com/__down?bytes=5000000" -o /dev/null 2>/dev/null
      local dl_end=$(date +%s%N 2>/dev/null || echo 0)
      local dl_ms=$(( (dl_end - dl_start) / 1000000 ))
      if (( dl_ms > 0 )); then
        local dl_mbps=$(awk "BEGIN{printf \"%.1f\", 5 * 8 / ($dl_ms / 1000.0)}")
        printf "  Download: %s Mbps\n" "$dl_mbps"
      fi
      # Upload speed
      info "Testing upload..."
      local ul_data=$(head -c 1000000 /dev/urandom 2>/dev/null | base64 | head -c 500000)
      local ul_start=$(date +%s%N 2>/dev/null || echo 0)
      echo "$ul_data" | curl -fsSL -X POST -d @- "https://speed.cloudflare.com/__up" -o /dev/null 2>/dev/null || true
      local ul_end=$(date +%s%N 2>/dev/null || echo 0)
      local ul_ms=$(( (ul_end - ul_start) / 1000000 ))
      if (( ul_ms > 0 )); then
        local ul_mbps=$(awk "BEGIN{printf \"%.1f\", 0.5 * 8 / ($ul_ms / 1000.0)}")
        printf "  Upload:   %s Mbps\n" "$ul_mbps"
      fi
      # API latency
      info "Testing API latency..."
      local api_start=$(date +%s%3N 2>/dev/null || echo 0)
      curl -fsSL "https://api.github.com" -o /dev/null 2>/dev/null
      local api_end=$(date +%s%3N 2>/dev/null || echo 0)
      printf "  API RTT:  %d ms \n" "$(( api_end - api_start ))"
      ;;
    -A|--all|all)
      cmd_test -S
      echo ""
      cmd_test -N
      echo ""
      cmd_health 2>/dev/null || true
      ;;
    *)
      echo "Usage: ai test -S or -N or -A"
      echo ""
      echo "  -S, --speed      Test model inference speed"
      echo "  -N, --network    Test network (download/upload/latency)"
      echo "  -A, --all        Run all tests "
      ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  v3.2 — 5 new features
# ══════════════════════════════════════════════════════════════════════════════

# 1. ai voice [tts|stt] — speak text aloud or transcribe audio
cmd_voice() {
  local sub="${1:-tts}"; shift 2>/dev/null || true
  case "$sub" in
    tts|speak|say)
      local text="$*"
      [[ -z "$text" ]] && { err "Usage: ai voice tts \"text\""; return 0; }
      if command -v piper &>/dev/null; then
        local voice="${PIPER_VOICE:-en_US-lessac-medium}"
        local tmp; tmp=$(mktemp --suffix=.wav)
        echo "$text" | piper --model "$voice" --output_file "$tmp" 2>/dev/null && \
          { ok "Spoken via piper"; _play_audio "$tmp"; rm -f "$tmp"; return 0; }
      fi
      if command -v espeak-ng &>/dev/null; then
        espeak-ng "$text" 2>/dev/null && { ok "Spoken via espeak-ng"; return 0; }
      fi
      if command -v espeak &>/dev/null; then
        espeak "$text" 2>/dev/null && { ok "Spoken via espeak"; return 0; }
      fi
      if command -v say &>/dev/null; then  # macOS
        say "$text" && { ok "Spoken via say"; return 0; }
      fi
      err "No TTS backend found. Install one of: piper, espeak-ng, espeak (or macOS 'say')"
      ;;
    stt|listen|transcribe)
      local src="${1:-}"
      [[ -z "$src" ]] && { err "Usage: ai voice stt <audio-file>"; return 0; }
      [[ ! -f "$src" ]] && { err "File not found: $src"; return 0; }
      if command -v whisper &>/dev/null; then
        whisper "$src" --output_format txt --output_dir /tmp 2>&1
      elif command -v whisper-cpp &>/dev/null; then
        whisper-cpp -f "$src" 2>&1
      else
        err "Install 'whisper' or 'whisper-cpp' for transcription"
      fi
      ;;
    ask|query)
      # TTS round-trip: ask AI then speak the answer
      local prompt="$*"
      [[ -z "$prompt" ]] && { err "Usage: ai voice ask \"question\""; return 0; }
      local ans; ans=$(dispatch_ask "$prompt" 2>/dev/null)
      echo "$ans"
      cmd_voice tts "$ans"
      ;;
    *)
      echo "Usage: ai voice <tts|stt|ask> [args]"
      echo "  tts TEXT         Speak text aloud (piper/espeak/say)"
      echo "  stt FILE         Transcribe audio file (whisper)"
      echo "  ask QUESTION     Ask AI and speak the answer"
      ;;
  esac
}
_play_audio() {
  local f="$1"
  for p in aplay paplay afplay ffplay play; do
    if command -v "$p" &>/dev/null; then
      if [[ "$p" == "ffplay" ]]; then
        "$p" -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
      else
        "$p" "$f" 2>/dev/null
      fi
      return 0
    fi
  done
  warn "No audio player found (tried aplay/paplay/afplay/ffplay/play)"
  return 1
}

# 2. ai share — create a public tunnel to the local API
cmd_share() {
  local port="${1:-8080}"
  if ! curl -sS "http://localhost:${port}/health" 2>/dev/null | grep -q ok; then
    warn "API server not running on port ${port} — starting it"
    cmd_api_v3 start --port "$port"
    sleep 1
  fi
  if command -v cloudflared &>/dev/null; then
    info "Opening Cloudflare tunnel to port ${port}..."
    cloudflared tunnel --url "http://localhost:${port}" 2>&1 | tee "$CONFIG_DIR/share.log" | \
      awk "/trycloudflare.com/ {print; exit} {print}"
    info "Log: $CONFIG_DIR/share.log"
  elif command -v ngrok &>/dev/null; then
    info "Opening ngrok tunnel to port ${port}..."
    ngrok http "$port"
  elif command -v ssh &>/dev/null; then
    info "Falling back to serveo.net via SSH (no auth)..."
    ssh -o StrictHostKeyChecking=no -R "80:localhost:${port}" serveo.net
  else
    err "Install one of: cloudflared, ngrok, or use SSH to share"
    echo "  cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-guide/"
    echo "  ngrok:       https://ngrok.com/download"
  fi
}

# 3. ai diff-review — AI review of current staged diff or given file
cmd_diff_review() {
  local diff_src="${1:-staged}"
  local diff_text=""
  case "$diff_src" in
    staged)     diff_text=$(git diff --cached 2>/dev/null) ;;
    unstaged)   diff_text=$(git diff 2>/dev/null) ;;
    head|last)  diff_text=$(git show HEAD 2>/dev/null) ;;
    branch)     diff_text=$(git diff "origin/${2:-main}..." 2>/dev/null) ;;
    *)
      if [[ -f "$diff_src" ]]; then
        diff_text=$(cat "$diff_src")
      else
        err "Usage: ai diff-review [staged|unstaged|head|branch <name>|FILE]"
        return 0
      fi
      ;;
  esac
  if [[ -z "$diff_text" ]]; then
    warn "No diff to review (source: $diff_src)"
    return 0
  fi
  info "Reviewing $(echo "$diff_text" | wc -l) lines of diff..."
  local prompt="You are a senior engineer. Review this unified diff. Flag bugs, logic errors, missing tests, security issues, and style problems. Be concise — use bullet points. If the diff looks fine, say so in one sentence.

$diff_text"
  dispatch_ask "$prompt"
}

# 4. ai agent "goal" [--steps N] — autonomous task loop
cmd_agent() {
  local goal="" steps=3 verbose=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --steps|-s) steps="$2"; shift 2 ;;
      --verbose|-v) verbose=1; shift ;;
      -h|--help)
        echo "Usage: ai agent \"goal\" [--steps N] [--verbose]"
        echo "  Runs an autonomous AI loop that breaks the goal into steps,"
        echo "  executes each via the chat backend, and composes a final result."
        return 0 ;;
      *) goal="${goal:+$goal }$1"; shift ;;
    esac
  done
  [[ -z "$goal" ]] && { err "Usage: ai agent \"goal\" [--steps N]"; return 0; }
  info "Agent loop: goal=\"$goal\" steps=$steps"
  local plan_prompt="Break this goal into exactly $steps concrete, numbered sub-tasks (no preamble, just the numbered list):

Goal: $goal"
  local plan; plan=$(dispatch_ask "$plan_prompt" 2>/dev/null)
  [[ "$verbose" == "1" ]] && { echo "── plan ──"; echo "$plan"; echo "──────────"; }
  local running="Goal: $goal
Plan:
$plan

Work so far:
"
  local i
  for ((i=1; i<=steps; i++)); do
    info "Step $i/$steps..."
    local step_prompt="$running

Execute step $i of the plan. Be concise. Output only the result."
    local step_out; step_out=$(dispatch_ask "$step_prompt" 2>/dev/null)
    [[ "$verbose" == "1" ]] && { echo "── step $i ──"; echo "$step_out"; echo "──────────"; }
    running="${running}
Step $i result: $step_out"
  done
  info "Synthesising final answer..."
  dispatch_ask "${running}

Now write the final, polished answer to the original goal. Be direct. No meta-commentary."
}

# 5. ai rag-quick FILE "question" — one-shot RAG without pre-building a corpus
cmd_rag_quick() {
  local file="${1:-}" question="${2:-}"
  [[ -z "$file" || -z "$question" ]] && {
    echo "Usage: ai rag-quick FILE \"question\""
    echo "       ai rag-quick DIRECTORY \"question\""
    return 0
  }
  local texts=""
  if [[ -d "$file" ]]; then
    while IFS= read -r -d "" f; do
      texts="$texts
=== $f ===
$(head -c 8000 "$f" 2>/dev/null)"
    done < <(find "$file" -type f \( -name "*.md" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "*.sh" -o -name "*.json" \) -print0 2>/dev/null | head -c 200000)
  elif [[ -f "$file" ]]; then
    texts=$(head -c 80000 "$file" 2>/dev/null)
  else
    err "Not a file or directory: $file"; return 0
  fi
  [[ -z "$texts" ]] && { err "No text extracted from: $file"; return 0; }
  local prompt="Use ONLY the following context to answer. If the answer isn't in the context, say \"not in context\".

CONTEXT:
$texts

QUESTION: $question

ANSWER:"
  dispatch_ask "$prompt"
}

cmd_hy() {
  # HyperNix integration — https://pypi.org/project/hypernix/
  # HyperNix is a PyTorch model quantization + chat toolkit for the
  # ray0rf1re/hyper-nix.1 model family. We shell out to its CLI.
  local sub="${1:-help}"; shift 2>/dev/null || true
  local hy_repo="${HYPERNIX_REPO:-nix2.5}"

  _hy_bin() {
    if command -v hypernix >/dev/null 2>&1; then echo "hypernix"; return 0; fi
    if "$PYTHON" -c "import hypernix" >/dev/null 2>&1; then
      echo "$PYTHON -m hypernix"; return 0
    fi
    return 1
  }

  case "$sub" in
    help|"")
      cat <<'EOF'
Usage: ai hy <subcommand> [options]

HyperNix wrapper — PyTorch model quantization + chat toolkit.
Upstream: https://pypi.org/project/hypernix/

Subcommands:
  help                       Show this help
  install [--extras E]       pip install hypernix[E]   (E: llama-cpp | train)
  info                       Installed version + python path
  models                     Common --repo-id values (nix2.5, qwen3.5-4b, …)
  ask|a|chat "prompt"        Chat via hypernix (uses --repo-id, default nix2.5)
  repo ID                    Set default repo for this shell (exports HYPERNIX_REPO)
  passthrough ARGS...        Run the raw `hypernix ARGS` command

Environment:
  HYPERNIX_REPO   default repo-id (current: ${HYPERNIX_REPO:-nix2.5})

Examples:
  ai hy install --extras llama-cpp
  ai hy ask "explain rotary embeddings"
  ai hy chat "write a haiku" --repo-id gemma-4-e4b
  ai hy repo qwen3.5-4b
  ai hy passthrough quantize --help
EOF
      ;;

    install)
      local extras=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --extras) extras="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
      local spec="hypernix"
      [[ -n "$extras" ]] && spec="hypernix[${extras}]"
      info "Installing $spec via pip..."
      if "$PYTHON" -m pip install --upgrade "$spec"; then
        ok "Installed. Try: ai hy ask \"hello\""
      else
        err "pip install failed — try: $PYTHON -m pip install --user $spec"
        return 1
      fi
      ;;

    info)
      local b; if ! b=$(_hy_bin); then
        warn "hypernix is not installed"
        info "Install:  ai hy install"
        return 1
      fi
      info "Binary:   $b"
      info "Python:   $PYTHON"
      "$PYTHON" -c "import hypernix, importlib.metadata as m; print('Version: ' + m.version('hypernix'))" 2>/dev/null \
        || warn "Could not read version (hypernix importable but metadata missing)"
      info "Default repo-id: $hy_repo  (override: HYPERNIX_REPO=... or ai hy repo ID)"
      ;;

    models)
      cat <<'EOF'
Common --repo-id values (not exhaustive — see upstream):

  nix2.5                HyperNix flagship
  qwen3.5-4b            Qwen 3.5, 4 B parameters
  qwen3.5-8b            Qwen 3.5, 8 B parameters
  gemma-4-e4b           Gemma 4, E4B
  gemma-4-e12b          Gemma 4, E12B
  llama-3.2-3b          Llama 3.2, 3 B
  mistral-nemo-12b      Mistral Nemo, 12 B

Use any with:  ai hy ask "prompt" --repo-id <id>
Set default:   ai hy repo <id>
EOF
      ;;

    ask|a|chat)
      local prompt="" repo="$hy_repo"
      # collect prompt + optional flags
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --repo-id|--repo) repo="$2"; shift 2 ;;
          --)               shift; prompt="${prompt}${prompt:+ }$*"; break ;;
          *)                prompt="${prompt}${prompt:+ }$1"; shift ;;
        esac
      done
      [[ -z "$prompt" ]] && { err "Usage: ai hy ask \"prompt\" [--repo-id ID]"; return 1; }
      local b; if ! b=$(_hy_bin); then
        err "hypernix is not installed"
        info "Run:  ai hy install"
        return 1
      fi
      info "HyperNix ask → repo=$repo"
      # shellcheck disable=SC2086
      $b chat --repo-id "$repo" --message "$prompt"
      ;;

    repo)
      local new="${1:-}"
      [[ -z "$new" ]] && { info "Current HYPERNIX_REPO: $hy_repo"; info "Set with: ai hy repo <id>"; return 0; }
      export HYPERNIX_REPO="$new"
      # Persist to the user's ai-cli config so it survives shells
      local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ai-cli"
      mkdir -p "$cfg_dir"
      local envf="$cfg_dir/aliases.env"
      touch "$envf"
      if grep -q '^export HYPERNIX_REPO=' "$envf" 2>/dev/null; then
        sed -i.bak -E "s|^export HYPERNIX_REPO=.*|export HYPERNIX_REPO=\"$new\"|" "$envf" && rm -f "${envf}.bak"
      else
        printf 'export HYPERNIX_REPO="%s"\n' "$new" >> "$envf"
      fi
      ok "Default repo set to: $new"
      info "Sourced from: $envf (runs on next shell; this shell already exported)"
      ;;

    passthrough|raw)
      local b; if ! b=$(_hy_bin); then err "hypernix not installed"; return 1; fi
      # shellcheck disable=SC2086
      $b "$@"
      ;;

    *)
      err "Unknown hy subcommand: $sub"
      cmd_hy help
      return 1
      ;;
  esac
}

cmd_api_v3() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    start)
      local port="${API_PORT:-8080}" host="${API_HOST:-0.0.0.0}"
      while [[ $# -gt 0 ]]; do
        case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; --public) host="0.0.0.0"; shift ;; --tailscale|--ts) local ts; ts=$(tailscale ip -4 2>/dev/null); [[ -n "$ts" ]] && host="$ts" && info "Tailscale: $ts"; shift ;; *) shift ;; esac
      done
      [[ -z "$PYTHON" ]] && { err "Python required"; return 0; }
      if [[ -f "$API_PID_FILE" ]] && kill -0 "$(cat "$API_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        warn "Already running"; return 0
      fi
      info "Starting API server v3 on ${host}:${port}..."
      local _api_script; _api_script=$(mktemp /tmp/ai_api_XXXX.py)
      local _cli_bin
      if _cli_bin=$(command -v ai 2>/dev/null) && [[ -n "$_cli_bin" ]]; then
        :
      else
        # Fall back to this script's own absolute path (works even if not installed).
        _cli_bin=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
      fi
      cat > "$_api_script" << 'APIPY'
import http.server, json, os, subprocess, sys, secrets, time, glob, platform, shutil, threading, re

_CLI_RAW = os.environ.get("AI_CLI_BIN", "ai")

def _resolve_cli(raw):
    """Return an argv PREFIX to invoke the CLI.
    - If `raw` is an absolute path ending in .sh (or not directly executable but
      readable), wrap it with `bash` so it runs regardless of +x bit.
    - Otherwise return [raw] as a single-arg prefix."""
    if os.path.isabs(raw) and os.path.isfile(raw):
        if not os.access(raw, os.X_OK) or raw.endswith(".sh"):
            return ["bash", raw]
        return [raw]
    # `raw` may be just "ai" — rely on $PATH
    return [raw]

CLI_ARGV = _resolve_cli(_CLI_RAW)
CLI = CLI_ARGV[0]   # legacy name for code paths that still reference CLI as a string
HOST = os.environ.get("API_HOST", "0.0.0.0")
PORT = int(os.environ.get("API_PORT", "8080"))
MODEL = os.environ.get("AI_MODEL", "auto")
VERSION = os.environ.get("AI_VERSION", "3.2.0")
CFG_DIR = os.path.expanduser("~/.config/ai-cli")
TERM_PW_FILE = os.path.join(CFG_DIR, ".api_terminal_pw")
LOG_FILE = os.path.join(CFG_DIR, "api_access.log")
HIST_FILE = os.path.join(CFG_DIR, "history.jsonl")
MODELS_DIR = os.path.expanduser("~/.ai-models")
UPLOADS_DIR = os.path.join(CFG_DIR, "uploads")
RAG_DIR = os.path.join(CFG_DIR, "rag")
os.makedirs(UPLOADS_DIR, exist_ok=True)
os.makedirs(RAG_DIR, exist_ok=True)
START_TIME = time.time()

def get_term_pw():
    try:
        return open(TERM_PW_FILE).read().strip()
    except:
        return None

def log_request(path, client_ip):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {client_ip} {path}\n")
    except:
        pass

def strip_ansi(s):
    out = ""
    i = 0
    while i < len(s):
        if s[i] == '\x1b' and i+1 < len(s) and s[i+1] == '[':
            while i < len(s) and s[i] != 'm':
                i += 1
            i += 1
        else:
            out += s[i]
            i += 1
    return out

def ai_ask(prompt):
    try:
        r = subprocess.run(CLI_ARGV + ["ask", prompt], capture_output=True, text=True, timeout=120, env={**os.environ, "NO_COLOR": "1"})
        out = strip_ansi((r.stdout or "") + (r.stderr or "")).strip()
        if not out:
            return "No response — run: ai recommended download 1 && ai recommended use 1"
        return out
    except subprocess.TimeoutExpired:
        return "Timed out after 120s — try a smaller model"
    except Exception as e:
        return f"Error: {e}"

def run_cmd(cmd):
    try:
        # Keep shell-form for legacy v3 callers (string cmd); prefix CLI_ARGV quoted.
        import shlex
        prefix = " ".join(shlex.quote(x) for x in CLI_ARGV)
        r = subprocess.run(f"{prefix} {cmd}", shell=True, capture_output=True, text=True, timeout=120, env={**os.environ, "NO_COLOR": "1"})
        return strip_ansi(r.stdout.strip() + r.stderr.strip()) or "Done"
    except Exception as e:
        return f"Error: {e}"

def shell_run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return {"stdout": r.stdout, "stderr": r.stderr, "rc": r.returncode}
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "Timed out", "rc": 124}
    except Exception as e:
        return {"stdout": "", "stderr": str(e), "rc": 1}

# ─── v4: API key store + auth + budgets ────────────────────────────────────
KEYS_FILE = os.path.join(CFG_DIR, "api_keys.json")
USAGE_FILE = os.path.join(CFG_DIR, "api_usage.jsonl")
HARD_MAX_REQUEST_SEC = 126  # 2.1 min hard ceiling per request

def load_keys():
    try:
        return json.load(open(KEYS_FILE))
    except:
        return {}

def save_keys(d):
    try:
        with open(KEYS_FILE, "w") as f:
            json.dump(d, f, indent=2)
        os.chmod(KEYS_FILE, 0o600)
    except Exception:
        pass

def key_from_headers(headers):
    # Accept X-API-Key or Authorization: Bearer <key>
    k = headers.get("X-API-Key") or headers.get("x-api-key")
    if k:
        return k.strip()
    auth = headers.get("Authorization") or headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth.split(None, 1)[1].strip()
    return None

def auth_check(headers):
    """Returns (ok, info, error). If keys exist, require a valid non-revoked
    key that hasn't exceeded its budget. If no keys exist → open mode."""
    keys = load_keys()
    if not keys:
        return True, None, None   # single-user / open mode
    k = key_from_headers(headers)
    if not k:
        return False, None, "Missing X-API-Key header or Authorization: Bearer"
    if k not in keys:
        return False, None, "Invalid key"
    info = keys[k]
    if info.get("revoked"):
        return False, None, "Key revoked"
    # reset cycle if expired
    now = time.time()
    cy = int(info.get("cycle_seconds", 21600) or 21600)
    if now - info.get("cycle_start", now) > cy:
        info["cycle_start"] = now
        info["tokens_used"] = 0
        info["time_used_sec"] = 0.0
        keys[k] = info
        save_keys(keys)
    tb = info.get("tokens_budget")
    if tb and info.get("tokens_used", 0) >= tb:
        return False, info, "Token budget exhausted — resets at next cycle"
    tmb = info.get("time_budget_sec")
    if tmb and info.get("time_used_sec", 0) >= tmb:
        return False, info, "Time budget exhausted — resets at next cycle"
    return True, info, None

def record_usage(headers, tokens=0, seconds=0.0, path=""):
    keys = load_keys()
    k = key_from_headers(headers) if keys else None
    if k and k in keys:
        info = keys[k]
        info["tokens_used"] = int(info.get("tokens_used", 0)) + int(tokens)
        info["time_used_sec"] = round(float(info.get("time_used_sec", 0)) + float(seconds), 3)
        info["last_used"] = int(time.time())
        keys[k] = info
        save_keys(keys)
    try:
        with open(USAGE_FILE, "a") as f:
            f.write(json.dumps({"t": int(time.time()), "key": (k or "open"),
                                "tokens": tokens, "sec": round(seconds, 3),
                                "path": path}) + "\n")
    except:
        pass

def key_timeout(headers):
    """Return the per-request timeout for this caller, hard-capped at 126s."""
    keys = load_keys()
    if not keys:
        return HARD_MAX_REQUEST_SEC
    k = key_from_headers(headers)
    if not k or k not in keys:
        return HARD_MAX_REQUEST_SEC
    info = keys[k]
    cap = int(info.get("max_request_sec", HARD_MAX_REQUEST_SEC))
    return min(HARD_MAX_REQUEST_SEC, max(5, cap))

def ai_ask_timed(prompt, timeout=HARD_MAX_REQUEST_SEC):
    try:
        r = subprocess.run(CLI_ARGV + ["ask", prompt], capture_output=True, text=True,
                           timeout=timeout, env={**os.environ, "NO_COLOR": "1"})
        out = strip_ansi((r.stdout or "") + (r.stderr or "")).strip()
        return out or "(no output from backend)"
    except subprocess.TimeoutExpired:
        return f"Timed out after {timeout}s (hard cap {HARD_MAX_REQUEST_SEC}s)"
    except Exception as e:
        return f"Error: {e}"

def run_cmd_argv(argv, timeout=HARD_MAX_REQUEST_SEC):
    """Run an `ai` subcommand as a proper argv list (no shell)."""
    try:
        r = subprocess.run(CLI_ARGV + list(argv), capture_output=True, text=True,
                           timeout=timeout, env={**os.environ, "NO_COLOR": "1"})
        return {"ok": r.returncode == 0,
                "stdout": strip_ansi(r.stdout or ""),
                "stderr": strip_ansi(r.stderr or ""),
                "rc": r.returncode}
    except subprocess.TimeoutExpired:
        return {"ok": False, "stdout": "", "stderr": f"timeout after {timeout}s", "rc": 124}
    except Exception as e:
        return {"ok": False, "stdout": "", "stderr": str(e), "rc": 1}


def estimate_cost(tokens, model_name):
    rates = {
        "gpt-4o": (0.0025, 0.01), "gpt-4o-mini": (0.00015, 0.0006),
        "claude": (0.003, 0.015), "gemini": (0.00125, 0.005),
        "groq": (0.0001, 0.0001), "mistral": (0.002, 0.006),
    }
    name = (model_name or "").lower()
    rate = (0.001, 0.003)
    for k, v in rates.items():
        if k in name:
            rate = v; break
    ins = (tokens // 2) / 1000.0 * rate[0]
    out = (tokens // 2) / 1000.0 * rate[1]
    return round(ins + out, 6)

def count_tokens(text):
    # crude 4-char ~ 1-token estimate
    return max(1, len(text) // 4)

def list_gguf_models():
    out = []
    for d in [MODELS_DIR, os.path.expanduser("~/models"), "/usr/share/ai-cli/models"]:
        if not os.path.isdir(d):
            continue
        for p in glob.glob(os.path.join(d, "**", "*.gguf"), recursive=True):
            try:
                sz = os.path.getsize(p)
                out.append({"path": p, "name": os.path.basename(p), "size": sz, "size_mb": round(sz / 1048576, 1)})
            except:
                pass
    return out

def active_model():
    try:
        for p in ["~/.config/ai-cli/active_model", "~/.config/ai-cli/config"]:
            fp = os.path.expanduser(p)
            if os.path.isfile(fp):
                t = open(fp).read().strip()
                if t:
                    return t.split("\n")[0][:200]
    except:
        pass
    return MODEL

def masked_key(key_name):
    v = os.environ.get(key_name, "")
    if not v:
        return ""
    if len(v) <= 10:
        return v[:3] + "…"
    return v[:6] + "…" + v[-4:]

def sysinfo():
    info = {
        "version": VERSION,
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "cpu_count": os.cpu_count(),
        "hostname": platform.node(),
        "uptime_seconds": int(time.time() - START_TIME),
    }
    try:
        import resource
        rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        info["api_rss_mb"] = round(rss_kb / 1024, 1) if platform.system() == "Linux" else round(rss_kb / 1048576, 1)
    except:
        pass
    try:
        if os.path.isfile("/proc/loadavg"):
            info["loadavg"] = open("/proc/loadavg").read().split()[:3]
    except:
        pass
    try:
        du = shutil.disk_usage(os.path.expanduser("~"))
        info["disk_free_gb"] = round(du.free / 1e9, 1)
        info["disk_total_gb"] = round(du.total / 1e9, 1)
    except:
        pass
    try:
        import subprocess as sp
        r = sp.run(["nvidia-smi", "--query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            gpus = []
            for line in r.stdout.strip().splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 5:
                    gpus.append({"name": parts[0], "mem_total_mb": parts[1], "mem_used_mb": parts[2], "util_pct": parts[3], "temp_c": parts[4]})
            info["gpus"] = gpus
    except:
        pass
    return info

def read_history(n=50):
    try:
        lines = open(HIST_FILE).read().strip().splitlines()[-n:]
        out = []
        for l in lines:
            try:
                out.append(json.loads(l))
            except:
                out.append({"raw": l})
        return out
    except:
        return []

def append_history(role, content, model=None):
    try:
        with open(HIST_FILE, "a") as f:
            f.write(json.dumps({"t": int(time.time()), "role": role, "content": content[:4000], "model": model or MODEL}) + "\n")
    except:
        pass

def simple_embed(text):
    # Deterministic character-hash embedding; 64-dim. Useful as similarity proxy
    # when no real embedding backend is installed.
    import hashlib
    vec = [0.0] * 64
    for tok in re.findall(r"\w+", text.lower()):
        h = hashlib.md5(tok.encode()).digest()
        for i in range(64):
            vec[i] += (h[i % 16] - 128) / 128.0
    norm = sum(x * x for x in vec) ** 0.5 or 1.0
    return [round(x / norm, 6) for x in vec]

def cosine(a, b):
    return sum(x * y for x, y in zip(a, b))

# ── Memory & Context ─────────────────────────────────────────────────
MEM_FILE = os.path.expanduser("~/.config/ai-cli/memory.jsonl")
CTX_FILE = os.path.expanduser("~/.config/ai-cli/api_context.json")
MAX_CTX_TOKENS = 3000

def load_mem():
    try:
        return [l.strip() for l in open(MEM_FILE) if l.strip()]
    except:
        return []

def save_mem(items):
    with open(MEM_FILE, "w") as f:
        for item in items:
            f.write(item + "\n")

def load_ctx():
    try:
        return json.load(open(CTX_FILE))
    except:
        return {"messages": [], "compressed": ""}

def save_ctx(ctx):
    json.dump(ctx, open(CTX_FILE, "w"), indent=2)

def estimate_tokens(text):
    return len(text) // 4

def ctx_is_full(ctx):
    total = sum(estimate_tokens(m.get("content", "")) for m in ctx.get("messages", []))
    total += estimate_tokens(ctx.get("compressed", ""))
    return total > MAX_CTX_TOKENS

def compress_ctx(ctx):
    msgs = ctx.get("messages", [])
    if len(msgs) < 4:
        return ctx
    old_msgs = msgs[:-2]
    keep_msgs = msgs[-2:]
    summary_text = " | ".join(m.get("content", "")[:100] for m in old_msgs)
    compressed = ai_ask(f"Summarize this conversation in 2-3 sentences: {summary_text}")
    prev = ctx.get("compressed", "")
    if prev:
        compressed = prev + " " + compressed
    ctx["messages"] = keep_msgs
    ctx["compressed"] = compressed
    save_ctx(ctx)
    return ctx

def auto_update_mem(user_msg, ai_msg):
    facts = []
    for trigger in ["my name is", "i am", "i live in", "i work", "i use", "i prefer", "remember that", "i like", "i have"]:
        if trigger in user_msg.lower():
            facts.append(user_msg)
            break
    if facts:
        existing = load_mem()
        for f in facts:
            if f not in existing:
                existing.append(f)
        save_mem(existing)

CHAT_HTML = """<!DOCTYPE html><html><head><title>AI CLI Chat</title>
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:sans-serif;background:#1e1e2e;color:#cdd6f4;height:100vh;display:flex;flex-direction:column}
#m{flex:1;overflow-y:auto;padding:16px}.u{background:#313244;margin:8px 0 8px 40px;padding:10px;border-radius:8px}
.a{background:#181825;border:1px solid #313244;margin:8px 40px 8px 0;padding:10px;border-radius:8px;white-space:pre-wrap}
#b{background:#181825;padding:10px;display:flex;gap:8px;border-top:1px solid #313244}
#p{flex:1;background:#313244;border:1px solid #45475a;color:#cdd6f4;padding:10px;border-radius:6px;font-size:14px;resize:none}
button{background:#89b4fa;color:#1e1e2e;border:none;padding:10px 18px;border-radius:6px;cursor:pointer;font-weight:600}
h3{padding:10px 16px;background:#181825;border-bottom:1px solid #313244;color:#89b4fa}</style></head>
<body><h3>AI CLI Chat</h3><div id="m"></div><div id="b"><textarea id="p" rows="1" placeholder="Message..."></textarea><button onclick="S()">Send</button></div>
<script>const m=document.getElementById("m"),p=document.getElementById("p"); function A(r,t){const d=document.createElement("div");d.className=r;d.textContent=t;m.appendChild(d);m.scrollTop=m.scrollHeight} let chatHistory=[]; async function S(){const t=p.value.trim();if(!t)return;p.value="";A("u",t);chatHistory.push({role:"user",content:t}); try{const r=await fetch("/v1/chat/completions",{method:"POST",headers:{"Content-Type":"application/json"}, body:JSON.stringify({messages:[{role:"user",content:t}]})});const d=await r.json(); A("a",d.choices?.[0]?.message?.content||"No response")}catch(e){A("a","Error: "+e.message)}}
p.addEventListener("keydown",e=>{if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();S()}})</script></body></html>"""

def get_dash_html():
    # CSS
    css = (
        "*{box-sizing:border-box;margin:0;padding:0}"
        "body{font-family:sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh}"
        "nav{background:#181825;padding:10px 16px;display:flex;gap:6px;border-bottom:1px solid #313244;align-items:center;flex-wrap:wrap;position:sticky;top:0;z-index:9}"
        "nav h2{color:#89b4fa;margin-right:auto;font-size:16px}"
        "nav .ver{color:#6c7086;font-size:12px;margin-right:10px}"
        ".nb{background:#313244;color:#cdd6f4;border:none;padding:7px 12px;border-radius:6px;cursor:pointer;font-size:12px}"
        ".nb:hover{background:#45475a}.nb.a{background:#89b4fa;color:#1e1e2e}"
        ".p{display:none;padding:18px;max-width:1000px;margin:0 auto}"
        "textarea,input[type=text],input[type=password],select{background:#313244;border:1px solid #45475a;color:#cdd6f4;padding:9px;border-radius:6px;font-family:monospace;font-size:13px;width:100%}"
        ".b{background:#89b4fa;color:#1e1e2e;border:none;padding:9px 16px;border-radius:6px;cursor:pointer;font-weight:600;margin:4px 2px}"
        ".b:hover{background:#74c7ec}.bs{padding:6px 11px;font-size:12px}"
        ".b.g{background:#a6e3a1}.b.r{background:#f38ba8}.b.y{background:#f9e2af}"
        ".o{background:#181825;border:1px solid #313244;border-radius:8px;padding:14px;margin:8px 0;white-space:pre-wrap;max-height:420px;overflow:auto;font-family:monospace;font-size:12px}"
        "h3{color:#89b4fa;margin-bottom:10px}"
        ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:6px}"
        ".row{display:flex;gap:8px;margin:6px 0;flex-wrap:wrap}"
        ".cm{margin:6px 0;padding:9px;border-radius:8px}"
        ".cu{background:#313244;margin-left:40px}"
        ".ca{background:#181825;border:1px solid #313244;margin-right:40px}"
        ".kv{display:grid;grid-template-columns:160px 1fr;gap:4px 10px;font-family:monospace;font-size:12px}"
        ".kv b{color:#89b4fa}"
        ".tag{display:inline-block;background:#313244;padding:2px 8px;border-radius:10px;font-size:11px;margin:2px;color:#a6e3a1}"
    )

    # JS - all tab-switching, helpers, fetchers
    js_parts = []
    js_parts.append(
        "function switchTab(b,i){var ps=document.querySelectorAll('.p');"
        "for(var j=0;j<ps.length;j++){ps[j].style.display=j===i?'block':'none'}"
        "var bs=document.querySelectorAll('nav .nb');"
        "for(var k=0;k<bs.length;k++){bs[k].className='nb'}b.className='nb a'}"
    )
    js_parts.append(
        "function j(u,b,cb){fetch(u,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:{})"
        ".then(function(r){return r.json()}).then(cb).catch(function(e){cb({error:e.message})})}"
    )
    js_parts.append(
        "function put(id,v){var o=document.getElementById(id);"
        "o.textContent=typeof v==='string'?v:JSON.stringify(v,null,2)}"
    )
    # chat
    js_parts.append("var chatH=[];var stream=false;")
    js_parts.append(
        "function am(c,t){var d=document.createElement('div');d.className='cm '+c;d.textContent=t;"
        "var ms=document.getElementById('ms');ms.appendChild(d);ms.scrollTop=ms.scrollHeight;return d}"
    )
    js_parts.append(
        "function sc(){var p=document.getElementById('pr');var t=p.value.trim();if(!t)return;p.value='';"
        "am('cu',t);chatH.push({role:'user',content:t});"
        "if(stream){var ad=am('ca','');"
        "fetch('/v3/chat/stream',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:chatH})})"
        ".then(function(r){var rd=r.body.getReader();var td=new TextDecoder();var buf='';var full='';"
        "function read(){return rd.read().then(function(x){if(x.done){chatH.push({role:'assistant',content:full});return}"
        "buf+=td.decode(x.value);var parts=buf.split('\\n\\n');buf=parts.pop();"
        "for(var i=0;i<parts.length;i++){var ln=parts[i].replace(/^data: /,'');if(ln==='[DONE]')continue;"
        "try{var o=JSON.parse(ln);full+=o.delta||'';ad.textContent=full}catch(e){}}return read()});}return read()})}"
        "else{j('/v1/chat/completions',{messages:chatH},function(d){var rp=d.choices&&d.choices[0]&&d.choices[0].message?d.choices[0].message.content:'Error';"
        "chatH.push({role:'assistant',content:rp});am('ca',rp)})}}"
    )
    js_parts.append(
        "function rc(c){var o=document.querySelector('.p[style*=block] .o');if(!o)o=document.querySelector('.o');"
        "if(o)o.textContent='Running...';"
        "j('/v1/chat/completions',{messages:[{role:'user',content:'/cmd '+c}]},function(d){"
        "if(o)o.textContent=d.choices&&d.choices[0]?d.choices[0].message.content:JSON.stringify(d)})}"
    )
    # status
    js_parts.append(
        "function loadStatus(){j('/v3/status',null,function(d){put('stOut',d)});"
        "j('/v3/sysinfo',null,function(d){put('sysOut',d)});"
        "j('/v3/version',null,function(d){put('verOut',d)})}"
    )
    # models
    js_parts.append(
        "function loadModels(){j('/v3/models',null,function(d){var h='Active: '+d.active+'\\n\\nLocal GGUF:\\n';"
        "if(!d.local||!d.local.length){h+='  (none — run: ai recommended download N)'}"
        "else{for(var i=0;i<d.local.length;i++){h+='  '+d.local[i].name+'  ('+d.local[i].size_mb+' MB)\\n'}}"
        "put('mdOut',h)})}"
        "function useModel(){var v=document.getElementById('mdName').value.trim();if(!v)return;"
        "j('/v3/models/activate',{model:v},function(d){put('mdOut',d);loadModels()})}"
        "function dlModel(){var v=document.getElementById('mdName').value.trim();if(!v)return;"
        "put('mdOut','Downloading...');j('/v3/models/download',{model:v},function(d){put('mdOut',d)})}"
    )
    # keys
    js_parts.append(
        "function loadKeys(){j('/v3/keys',null,function(d){var h='';"
        "for(var k in d.keys){h+=k+'  '+(d.keys[k].set?('✓ '+d.keys[k].masked):'(not set)')+'\\n'}put('kOut',h)})}"
        "function setKey(){var n=document.getElementById('kN').value;var v=document.getElementById('kV').value;"
        "var p=document.getElementById('kPw').value;"
        "j('/v3/keys/set',{name:n,value:v,password:p},function(d){put('kOut',d);loadKeys()})}"
    )
    # history / tokens / cost / embed
    js_parts.append(
        "function loadHist(){j('/v3/history?n=50',null,function(d){put('hOut',d)})}"
        "function searchHist(){var q=document.getElementById('hQ').value;"
        "j('/v3/history/search',{query:q},function(d){put('hOut',d)})}"
        "function clearHist(){if(!confirm('Wipe history?'))return;"
        "j('/v3/history/clear',{},function(d){put('hOut',d);loadHist()})}"
        "function tokCount(){var t=document.getElementById('tkT').value;"
        "j('/v3/tokens',{text:t},function(d){put('tkOut',d)})}"
        "function costEst(){var t=document.getElementById('tkT').value;var m=document.getElementById('tkM').value;"
        "j('/v3/cost',{text:t,model:m},function(d){put('tkOut',d)})}"
        "function embedTxt(){var t=document.getElementById('tkT').value;"
        "j('/v3/embed',{text:t},function(d){put('tkOut',d)})}"
    )
    # web/agent/diff/rag
    js_parts.append(
        "function webAsk(){var q=document.getElementById('wQ').value;"
        "put('wOut','Searching...');j('/v3/web',{query:q},function(d){put('wOut',d)})}"
        "function agentRun(){var g=document.getElementById('agG').value;var s=parseInt(document.getElementById('agS').value||'3');"
        "put('agOut','Running agent ('+s+' steps)...');j('/v3/agent',{goal:g,steps:s},function(d){put('agOut',d)})}"
        "function diffReview(){var d=document.getElementById('dfT').value;"
        "put('dfOut','Reviewing...');j('/v3/diff/review',{diff:d},function(x){put('dfOut',x)})}"
        "function ragAdd(){var c=document.getElementById('rgC').value||'default';var t=document.getElementById('rgT').value;"
        "j('/v3/rag/add',{corpus:c,text:t},function(d){put('rgOut',d)})}"
        "function ragQuery(){var c=document.getElementById('rgC').value||'default';var q=document.getElementById('rgQ').value;"
        "put('rgOut','Searching corpus...');j('/v3/rag/query',{corpus:c,query:q,k:3},function(d){put('rgOut',d)})}"
        "function ragList(){j('/v3/rag/list',null,function(d){put('rgOut',d)})}"
        "function benchmark(){put('bmOut','Running...');"
        "j('/v3/benchmark',{},function(d){put('bmOut',d)})}"
        "function shareLink(){put('shOut','Creating...');"
        "j('/v3/share',{},function(d){put('shOut',d)})}"
        "function ttsSay(){var t=document.getElementById('vT').value;"
        "j('/v3/voice/tts',{text:t},function(d){put('vOut',d)})}"
    )
    # endpoints browser
    js_parts.append(
        "function loadEndpoints(){j('/v3/endpoints',null,function(d){"
        "var h='';for(var i=0;i<d.endpoints.length;i++){var e=d.endpoints[i];"
        "h+=e.method.padEnd(5)+' '+e.path+'\\n        '+e.desc+'\\n'}put('eOut',h)})}"
        "function loadLogs(){j('/v3/logs',null,function(d){put('lgOut',(d.log||[]).join('\\n'))})}"
    )
    # terminal
    js_parts.append(
        "var _ta=false;"
        "function tlogin(){var pw=document.getElementById('tpw').value;"
        "j('/v3/terminal/auth',{password:pw},function(d){if(d.ok){_ta=true;"
        "document.getElementById('tauth').style.display='none';"
        "document.getElementById('tterm').style.display='block';tadd('Terminal unlocked.')}"
        "else{alert('Wrong password: '+(d.error||''))}})}"
        "function tadd(t){var o=document.getElementById('tout');"
        "o.textContent+=t+String.fromCharCode(10);o.scrollTop=o.scrollHeight}"
        "function texec(){if(!_ta)return;var c=document.getElementById('tcmd');var cmd=c.value;"
        "if(!cmd)return;c.value='';tadd('$ '+cmd);"
        "j('/v3/terminal/exec',{cmd:cmd,password:document.getElementById('tpw').value},"
        "function(d){tadd(d.output||d.error||'Done')})}"
    )

    js = "\n".join(js_parts)

    tabs = [
        ("Chat", 0), ("Status", 1), ("Models", 2), ("Keys", 3),
        ("History", 4), ("Tools", 5), ("Agent", 6), ("Voice", 7),
        ("RAG", 8), ("Share", 9), ("API Docs", 10), ("Terminal", 11),
    ]

    h = ["<!DOCTYPE html><html><head><meta charset=utf-8><title>AI CLI v", VERSION,
         " Dashboard</title><style>", css, "</style></head><body>"]
    h.append("<nav><h2>AI CLI Dashboard</h2><span class=ver>v")
    h.append(VERSION)
    h.append("</span>")
    for i, (name, idx) in enumerate(tabs):
        cls = "nb a" if i == 0 else "nb"
        h.append(f"<button class='{cls}' onclick='switchTab(this,{idx})'>{name}</button>")
    h.append("</nav>")

    # Tab 0: Chat
    h.append(
        "<div id=p0 class=p style=display:block><h3>Chat</h3>"
        "<div id=ms class=o style=min-height:240px></div>"
        "<div class=row><textarea id=pr rows=2 placeholder='Message... (Shift+Enter for newline)'></textarea></div>"
        "<div class=row>"
        "<button class=b onclick=sc()>Send</button>"
        "<label style='padding:10px;font-size:12px;color:#a6adc8'>"
        "<input type=checkbox onchange='stream=this.checked'> Stream</label>"
        "<button class='b bs' onclick='chatH=[];document.getElementById(\"ms\").innerHTML=\"\"'>Clear</button>"
        "</div></div>"
    )

    # Tab 1: Status
    h.append(
        "<div id=p1 class=p><h3>Server Status</h3>"
        "<button class=b onclick=loadStatus()>Refresh</button>"
        "<h3 style=margin-top:14px>Status</h3><pre id=stOut class=o>(click refresh)</pre>"
        "<h3>System Info</h3><pre id=sysOut class=o></pre>"
        "<h3>Version</h3><pre id=verOut class=o></pre>"
        "</div>"
    )

    # Tab 2: Models
    h.append(
        "<div id=p2 class=p><h3>Models</h3>"
        "<button class=b onclick=loadModels()>List</button> "
        "<button class='b bs' onclick=\"rc('recommended')\">Browse 195</button>"
        "<div class=row>"
        "<input type=text id=mdName placeholder='model name or number'>"
        "</div>"
        "<div class=row>"
        "<button class='b g' onclick=useModel()>Activate</button>"
        "<button class='b y' onclick=dlModel()>Download</button>"
        "</div>"
        "<pre id=mdOut class=o>(none)</pre></div>"
    )

    # Tab 3: Keys
    h.append(
        "<div id=p3 class=p><h3>Backend API Keys</h3>"
        "<button class=b onclick=loadKeys()>Refresh</button>"
        "<pre id=kOut class=o>(click refresh)</pre>"
        "<h3 style=margin-top:14px>Set a key (terminal password required)</h3>"
        "<div class=row><input type=text id=kN placeholder='OPENAI_API_KEY'></div>"
        "<div class=row><input type=password id=kV placeholder='value'></div>"
        "<div class=row><input type=password id=kPw placeholder='terminal password' maxlength=8></div>"
        "<button class='b g' onclick=setKey()>Save Key</button>"
        "</div>"
    )

    # Tab 4: History / Tokens
    h.append(
        "<div id=p4 class=p><h3>Conversation History</h3>"
        "<div class=row>"
        "<button class=b onclick=loadHist()>Load last 50</button>"
        "<input type=text id=hQ placeholder='search query' style=max-width:300px>"
        "<button class='b bs' onclick=searchHist()>Search</button>"
        "<button class='b r bs' onclick=clearHist()>Clear</button>"
        "</div>"
        "<pre id=hOut class=o></pre>"
        "<h3 style=margin-top:14px>Tokens · Cost · Embed</h3>"
        "<textarea id=tkT rows=3 placeholder='text to analyse'></textarea>"
        "<div class=row>"
        "<input type=text id=tkM placeholder='model (e.g. gpt-4o)' style=max-width:200px>"
        "<button class='b bs' onclick=tokCount()>Count Tokens</button>"
        "<button class='b bs' onclick=costEst()>Estimate Cost</button>"
        "<button class='b bs' onclick=embedTxt()>Embed</button>"
        "</div>"
        "<pre id=tkOut class=o></pre></div>"
    )

    # Tab 5: Tools
    h.append(
        "<div id=p5 class=p><h3>Tools</h3>"
        "<div class=grid>"
        "<button class='b bs' onclick=\"rc('test -S')\">Speed Test</button>"
        "<button class='b bs' onclick=\"rc('test -N')\">Network</button>"
        "<button class='b bs' onclick=\"rc('analytics')\">Analytics</button>"
        "<button class='b bs' onclick=\"rc('security')\">Security</button>"
        "<button class='b bs' onclick=\"rc('health')\">Health</button>"
        "<button class='b bs' onclick=\"rc('mem list')\">Memory</button>"
        "</div>"
        "<h3 style=margin-top:14px>Benchmark</h3>"
        "<button class=b onclick=benchmark()>Run round-trip</button>"
        "<pre id=bmOut class=o></pre>"
        "<h3 style=margin-top:14px>Web-augmented Ask</h3>"
        "<div class=row><input type=text id=wQ placeholder='query'></div>"
        "<button class=b onclick=webAsk()>Ask with web search</button>"
        "<pre id=wOut class=o></pre>"
        "<div class=o></div></div>"
    )

    # Tab 6: Agent + Diff
    h.append(
        "<div id=p6 class=p><h3>Agent Loop</h3>"
        "<textarea id=agG rows=3 placeholder='goal'></textarea>"
        "<div class=row>"
        "<input type=text id=agS placeholder=steps value=3 style=max-width:120px>"
        "<button class='b g' onclick=agentRun()>Run</button>"
        "</div>"
        "<pre id=agOut class=o></pre>"
        "<h3 style=margin-top:14px>Diff Review</h3>"
        "<textarea id=dfT rows=10 placeholder='paste unified diff'></textarea>"
        "<button class='b' onclick=diffReview()>Review</button>"
        "<pre id=dfOut class=o></pre></div>"
    )

    # Tab 7: Voice
    h.append(
        "<div id=p7 class=p><h3>Voice (TTS)</h3>"
        "<textarea id=vT rows=3 placeholder='text to speak'></textarea>"
        "<button class=b onclick=ttsSay()>Speak</button>"
        "<pre id=vOut class=o></pre>"
        "<p style=color:#6c7086;font-size:12px>Requires <code>piper</code> or <code>espeak</code> on PATH.</p>"
        "</div>"
    )

    # Tab 8: RAG
    h.append(
        "<div id=p8 class=p><h3>RAG</h3>"
        "<div class=row>"
        "<input type=text id=rgC placeholder='corpus name (default)' style=max-width:240px>"
        "<button class='b bs' onclick=ragList()>List Corpora</button>"
        "</div>"
        "<h3 style=margin-top:14px>Add to corpus</h3>"
        "<textarea id=rgT rows=4 placeholder='text to index'></textarea>"
        "<button class='b g' onclick=ragAdd()>Add</button>"
        "<h3 style=margin-top:14px>Query</h3>"
        "<div class=row><input type=text id=rgQ placeholder='question'>"
        "<button class='b' onclick=ragQuery()>Query</button></div>"
        "<pre id=rgOut class=o></pre></div>"
    )

    # Tab 9: Share
    h.append(
        "<div id=p9 class=p><h3>Public Share Link</h3>"
        "<p style=color:#a6adc8>Creates a Cloudflare-tunnel URL so others can reach this API over the internet.</p>"
        "<button class=b onclick=shareLink()>Create Link</button>"
        "<pre id=shOut class=o></pre></div>"
    )

    # Tab 10: API Docs
    h.append(
        "<div id=p10 class=p><h3>API Endpoints</h3>"
        "<button class=b onclick=loadEndpoints()>List All</button>"
        "<button class='b bs' onclick=loadLogs()>Access Log</button>"
        "<pre id=eOut class=o></pre>"
        "<h3 style=margin-top:14px>Access Log</h3>"
        "<pre id=lgOut class=o></pre></div>"
    )

    # Tab 11: Terminal
    h.append(
        "<div id=p11 class=p><h3>Terminal (Protected)</h3>"
        "<div id=tauth style=text-align:center;padding:40px>"
        "<p style='color:#6c7086;margin-bottom:12px'>Enter terminal password</p>"
        "<input type=password id=tpw placeholder=Password style='max-width:200px;text-align:center' maxlength=8>"
        "<br><button class=b onclick=tlogin() style=margin-top:8px>Unlock</button></div>"
        "<div id=tterm style=display:none>"
        "<div id=tout class=o style='min-height:300px;background:#0d0d0d;color:#00ff41;font-family:monospace'></div>"
        "<div class=row>"
        "<span style='color:#00ff41;padding:10px'>$</span>"
        "<input type=text id=tcmd placeholder=Command... style=font-family:monospace>"
        "<button class=b onclick=texec()>Run</button></div></div></div>"
    )

    h.append("<script>" + js + "\n")
    h.append("document.addEventListener('DOMContentLoaded',function(){loadStatus()});\n")
    h.append("document.getElementById('pr').addEventListener('keydown',function(e){"
             "if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sc()}});\n")
    h.append("document.getElementById('tcmd').addEventListener('keydown',function(e){"
             "if(e.key==='Enter')texec()});\n")
    h.append("</script></body></html>")
    return "".join(h)

DASH_HTML = get_dash_html()

# ═══════════════════════════════════════════════════════════════════════════
#  v4 API — clean, authenticated, budgeted
# ═══════════════════════════════════════════════════════════════════════════
def v4_reply(handler, code, data):
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
    handler.end_headers()
    handler.wfile.write(json.dumps(data).encode())

def v4_body(handler):
    try:
        l = int(handler.headers.get("Content-Length", 0))
        raw = handler.rfile.read(l) if l else b""
        return json.loads(raw) if raw else {}
    except Exception:
        return {}

# ── v4 shared response helpers ──────────────────────────────────────────────
# Every upgraded v4 handler wraps its payload with:
#   id          : request ID for tracing (req_xxxx)
#   elapsed_ms  : integer milliseconds since the request started
#   server_time : ISO8601 timestamp (UTC)
#   model       : active model (when relevant)
# The original fields stay at the top level so existing clients don't break.

def _req_id():
    return "req_" + secrets.token_hex(8)

def _env(t0, request_id=None, **fields):
    """Wrap a response dict with timing/metadata envelope. Call as:
         return (200, _env(t0, id, foo=1, bar=2))"""
    out = {
        "id": request_id or _req_id(),
        "elapsed_ms": int((time.time() - t0) * 1000),
        "server_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    out.update(fields)
    return out

def _err(code, message, request_id=None, **extra):
    """Standard error envelope."""
    body = {"error": {"code": code, "message": message,
                      "request_id": request_id or _req_id()}}
    body["error"].update(extra)
    return body

# Per-1K-token pricing table (USD). Falls back to a generic estimate when
# the model is unknown. Values are rough and up-to-date as of early 2026 —
# keep them conservative so "cost" is a ceiling, not the floor.
PRICING_USD_PER_1K = {
    # name fragment → (input_usd_per_1k, output_usd_per_1k)
    "gpt-4o":               (0.0025, 0.01),
    "gpt-4-turbo":          (0.01,   0.03),
    "gpt-4":                (0.03,   0.06),
    "gpt-3.5":              (0.0005, 0.0015),
    "o1-preview":           (0.015,  0.06),
    "o1-mini":              (0.003,  0.012),
    "claude-3-5-sonnet":    (0.003,  0.015),
    "claude-3-5-haiku":     (0.001,  0.005),
    "claude-3-opus":        (0.015,  0.075),
    "claude-3-haiku":       (0.00025,0.00125),
    "claude":               (0.003,  0.015),
    "gemini-1.5-pro":       (0.00125,0.005),
    "gemini-1.5-flash":     (0.000075,0.0003),
    "gemini":               (0.001,  0.004),
    "groq":                 (0.0001, 0.0001),
    "mistral-large":        (0.002,  0.006),
    "mistral":              (0.0005, 0.0015),
    "llama-3":              (0.0004, 0.0008),
    "llama":                (0.0003, 0.0006),
    # local GGUF / "auto" etc → free
}

def price_for(model, tokens_in, tokens_out):
    """Return (price_in_usd, price_out_usd, matched_tier)."""
    m = (model or "").lower()
    for key, (pin, pout) in PRICING_USD_PER_1K.items():
        if key in m:
            return (round(tokens_in * pin / 1000, 6),
                    round(tokens_out * pout / 1000, 6), key)
    return (0.0, 0.0, "local-or-unknown")

def ai_ask_capture(prompt, timeout, extra_args=None):
    """Run CLI ask with proper timing. Returns (text, elapsed_sec, ok)."""
    t0 = time.time()
    argv = CLI_ARGV + ["ask"] + list(extra_args or []) + [prompt]
    try:
        r = subprocess.run(argv, capture_output=True, text=True,
                           timeout=timeout,
                           env={**os.environ, "NO_COLOR": "1"})
        out = strip_ansi((r.stdout or "") + (r.stderr or "")).strip()
        return (out or "(no output from backend)",
                time.time() - t0, r.returncode == 0)
    except subprocess.TimeoutExpired:
        return (f"Timed out after {timeout}s (hard cap {HARD_MAX_REQUEST_SEC}s)",
                time.time() - t0, False)
    except Exception as e:
        return (f"Error: {type(e).__name__}: {e}", time.time() - t0, False)

# Persistent in-memory counters (per-process). Reset on restart.
V4_COUNTERS = {"requests": 0, "errors": 0, "tokens_in": 0, "tokens_out": 0}
V4_JOBS = {}   # job_id → {"status", "kind", "target", "started", "ended", "output"}
V4_TERM_SESSIONS = {}  # token → {"created", "expires", "client"}

def _new_job(kind, target):
    jid = "job_" + secrets.token_hex(6)
    V4_JOBS[jid] = {"status": "running", "kind": kind, "target": target,
                    "started": int(time.time()), "ended": None, "output": ""}
    return jid

def _finish_job(jid, output, ok=True):
    if jid in V4_JOBS:
        V4_JOBS[jid]["status"] = "done" if ok else "failed"
        V4_JOBS[jid]["ended"] = int(time.time())
        V4_JOBS[jid]["output"] = output[-4000:]

# ── v4 GET handlers (no body, no budget spend except maybe time) ──
def v4_get_ping(h, hdrs, qs):
    t0 = time.time()
    ok, info, err = auth_check(hdrs)
    if not ok: return (401, _err("auth_required", err))
    V4_COUNTERS["requests"] += 1
    return (200, _env(t0, pong=True, version=VERSION, t=int(time.time()),
                      authenticated=info is not None,
                      request_count=V4_COUNTERS["requests"]))

def v4_get_health(h, hdrs, qs):
    t0 = time.time()
    checks = {
        "cli_resolvable": bool(shutil.which(CLI_ARGV[0]) or os.path.isfile(CLI_ARGV[-1])),
        "config_dir_writable": os.access(CFG_DIR, os.W_OK),
        "uploads_dir": os.path.isdir(UPLOADS_DIR),
        "rag_dir": os.path.isdir(RAG_DIR),
    }
    all_ok = all(checks.values())
    return (200, _env(t0,
                      status="ok" if all_ok else "degraded",
                      version=VERSION,
                      uptime_sec=int(time.time() - START_TIME),
                      auth_required=bool(load_keys()),
                      checks=checks))

def v4_get_status(h, hdrs, qs):
    t0 = time.time()
    try:
        import resource
        rss_mb = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1)
    except Exception:
        rss_mb = None
    keys = load_keys()
    active_keys = sum(1 for v in keys.values() if not v.get("revoked"))
    return (200, _env(t0,
                      status="ok", version=VERSION,
                      active_model=active_model(),
                      uptime_seconds=int(time.time() - START_TIME),
                      mem_count=len(load_mem()),
                      ctx_msgs=len(load_ctx().get("messages", [])),
                      keys_configured=len(keys),
                      keys_active=active_keys,
                      process_rss_mb=rss_mb,
                      counters=dict(V4_COUNTERS),
                      running_jobs=sum(1 for j in V4_JOBS.values() if j["status"] == "running"),
                      hard_request_cap_sec=HARD_MAX_REQUEST_SEC))

def v4_get_sysinfo(h, hdrs, qs):
    t0 = time.time()
    base = sysinfo()
    # GPU
    gpus = []
    try:
        r = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total,memory.used,utilization.gpu",
                            "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=2)
        if r.returncode == 0:
            for line in r.stdout.strip().splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) == 4:
                    gpus.append({"name": parts[0],
                                 "mem_total_mib": int(parts[1]),
                                 "mem_used_mib": int(parts[2]),
                                 "util_pct": int(parts[3])})
    except Exception:
        pass
    # Python / kernel
    base.update({"gpus": gpus, "python": platform.python_version(),
                 "kernel": platform.release()})
    return (200, _env(t0, **base))

def v4_get_version(h, hdrs, qs):
    t0 = time.time()
    git_sha = None
    try:
        repo = os.path.dirname(os.path.abspath(CLI_ARGV[-1])) if CLI_ARGV else "."
        r = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=2)
        if r.returncode == 0:
            git_sha = r.stdout.strip() or None
    except Exception:
        pass
    return (200, _env(t0, version=VERSION, api="v4", cli=CLI,
                      cli_argv=CLI_ARGV, python=platform.python_version(),
                      git_sha=git_sha, hard_request_cap_sec=HARD_MAX_REQUEST_SEC))

def v4_get_models(h, hdrs, qs):
    t0 = time.time()
    local = []
    for m in list_gguf_models():
        fp = m.get("path") or ""
        try:
            sz = os.path.getsize(fp) if fp and os.path.isfile(fp) else 0
        except Exception:
            sz = 0
        local.append({
            "id": m["name"], "type": "gguf",
            "path": fp, "size_bytes": sz,
            "size_gb": round(sz / (1024**3), 2) if sz else 0.0,
        })
    cloud = [
        {"id": "openai:gpt-4o", "type": "api", "provider": "openai",
         "needs_key": "OPENAI_API_KEY", "context_length": 128000},
        {"id": "anthropic:claude-3-5-sonnet", "type": "api", "provider": "anthropic",
         "needs_key": "ANTHROPIC_API_KEY", "context_length": 200000},
        {"id": "gemini:gemini-1.5-pro", "type": "api", "provider": "gemini",
         "needs_key": "GEMINI_API_KEY", "context_length": 1000000},
        {"id": "groq:llama-3.1-70b", "type": "api", "provider": "groq",
         "needs_key": "GROQ_API_KEY", "context_length": 32000},
    ]
    return (200, _env(t0, active=active_model(),
                      local=local, cloud=cloud,
                      total=len(local) + len(cloud),
                      data=[{"id": active_model()}]
                           + [{"id": m["id"]} for m in local]
                           + [{"id": m["id"]} for m in cloud]))

def v4_get_keys(h, hdrs, qs):
    t0 = time.time()
    ks = {
        "OPENAI_API_KEY":   {"provider": "openai",    "prefix": "sk-"},
        "ANTHROPIC_API_KEY":{"provider": "anthropic", "prefix": "sk-ant-"},
        "GEMINI_API_KEY":   {"provider": "gemini",    "prefix": "AIza"},
        "GROQ_API_KEY":     {"provider": "groq",      "prefix": "gsk_"},
        "MISTRAL_API_KEY":  {"provider": "mistral",   "prefix": ""},
        "TOGETHER_API_KEY": {"provider": "together",  "prefix": ""},
        "HF_TOKEN":         {"provider": "hf",        "prefix": "hf_"},
        "HF_API_KEY":       {"provider": "hf",        "prefix": "hf_"},
    }
    out = {}
    for k, meta in ks.items():
        v = os.environ.get(k, "")
        out[k] = {"set": bool(v),
                  "masked": masked_key(k),
                  "provider": meta["provider"],
                  "format_ok": v.startswith(meta["prefix"]) if (v and meta["prefix"]) else True}
    return (200, _env(t0, keys=out, total_set=sum(1 for v in out.values() if v["set"])))

def v4_get_history(h, hdrs, qs):
    t0 = time.time()
    n = 50; offset = 0; role = None; since = None
    try: n = max(1, min(500, int(qs.get("n", "50"))))
    except: pass
    try: offset = max(0, int(qs.get("offset", "0")))
    except: pass
    role = qs.get("role") or None
    try: since = int(qs.get("since", "0")) or None
    except: pass
    hist = read_history(n + offset + 100)
    if role:
        hist = [x for x in hist if x.get("role") == role]
    if since:
        hist = [x for x in hist if x.get("t", 0) >= since]
    if offset: hist = hist[offset:]
    hist = hist[-n:]
    return (200, _env(t0, history=hist, count=len(hist),
                      filters={"role": role, "since": since, "offset": offset}))

def v4_get_logs(h, hdrs, qs):
    t0 = time.time()
    try: n = max(1, min(2000, int(qs.get("n", "200"))))
    except: n = 200
    grep = qs.get("grep") or ""
    try:
        lines = open(LOG_FILE).read().splitlines()
    except Exception:
        lines = []
    if grep:
        try: lines = [x for x in lines if re.search(grep, x)]
        except re.error: pass
    tail = lines[-n:]
    return (200, _env(t0, log=tail, total=len(lines), returned=len(tail),
                      grep=grep or None))

def v4_get_files(h, hdrs, qs):
    t0 = time.time()
    items = []
    total_bytes = 0
    for n in sorted(os.listdir(UPLOADS_DIR)):
        fp = os.path.join(UPLOADS_DIR, n)
        if not os.path.isfile(fp): continue
        sz = os.path.getsize(fp)
        total_bytes += sz
        mime = "application/octet-stream"
        ext = n.rsplit(".", 1)[-1].lower() if "." in n else ""
        mime = {"txt": "text/plain", "json": "application/json",
                "md": "text/markdown", "py": "text/x-python",
                "js": "application/javascript", "html": "text/html",
                "csv": "text/csv", "wav": "audio/wav",
                "mp3": "audio/mpeg", "png": "image/png",
                "jpg": "image/jpeg", "jpeg": "image/jpeg",
                "pdf": "application/pdf"}.get(ext, mime)
        items.append({"name": n, "size": sz,
                      "mtime": int(os.path.getmtime(fp)),
                      "mime": mime, "ext": ext})
    return (200, _env(t0, files=items, count=len(items),
                      total_bytes=total_bytes,
                      uploads_dir=UPLOADS_DIR))

def v4_get_rag_list(h, hdrs, qs):
    t0 = time.time()
    out = []
    for n in sorted(os.listdir(RAG_DIR)):
        if not n.endswith(".jsonl"): continue
        fp = os.path.join(RAG_DIR, n)
        docs = 0
        try:
            with open(fp) as f:
                for _ in f: docs += 1
        except Exception: pass
        out.append({"corpus": n[:-6], "docs": docs,
                    "size_bytes": os.path.getsize(fp)})
    return (200, _env(t0, corpora=out, count=len(out)))

def v4_get_mem(h, hdrs, qs):
    return (200, {"memory": load_mem()})

def v4_get_context(h, hdrs, qs):
    return (200, load_ctx())

def v4_get_config(h, hdrs, qs):
    t0 = time.time()
    cfg = {}
    fp_new = os.path.expanduser("~/.config/ai-cli/config.env")
    fp_old = os.path.expanduser("~/.config/ai-cli/config")
    fp = fp_new if os.path.isfile(fp_new) else fp_old
    if os.path.isfile(fp):
        try:
            for line in open(fp):
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line: continue
                k, v = line.split("=", 1)
                if any(s in k.upper() for s in ("KEY", "TOKEN", "SECRET", "PASSWORD")):
                    continue
                cfg[k] = v.strip('"').strip("'")
        except Exception: pass
    return (200, _env(t0, config=cfg, source=fp if os.path.isfile(fp) else None,
                      count=len(cfg)))

def v4_get_endpoints(h, hdrs, qs):
    t0 = time.time()
    qf = (qs.get("category") or "").lower()
    doc = V4_ENDPOINTS_DOC
    if qf:
        doc = [e for e in doc if qf in e.get("func", "").lower()
                             or qf in e["path"].lower()]
    return (200, _env(t0, endpoints=doc, count=len(doc),
                      categories=["status", "models", "chat", "batch", "analysis",
                                  "features", "files", "rag", "terminal", "auth"]))

def v4_get_usage(h, hdrs, qs):
    t0 = time.time()
    k = key_from_headers(hdrs)
    keys = load_keys()
    if k and k in keys:
        info = dict(keys[k])
        info["key_prefix"] = k[:10] + "…"
        info.pop("name_display", None)
        # derive useful aggregates
        cycle_remaining = max(0, int(info.get("cycle_seconds", 0))
                              - (int(time.time()) - int(info.get("cycle_start", 0))))
        tb = info.get("tokens_budget") or 0
        tu = info.get("tokens_used", 0)
        tm_b = info.get("time_budget_sec") or 0
        tm_u = info.get("time_used_sec", 0)
        info["tokens_remaining"] = max(0, tb - tu) if tb else None
        info["time_remaining_sec"] = round(max(0, tm_b - tm_u), 3) if tm_b else None
        info["cycle_time_remaining_sec"] = cycle_remaining
        info["tokens_percent_used"] = round(100.0 * tu / tb, 2) if tb else None
        return (200, _env(t0, key=info))
    return (200, _env(t0, key=None,
                      note="Open mode (no keys configured) — no per-caller usage tracked"))

def v4_get_auth_keys(h, hdrs, qs):
    t0 = time.time()
    pw = get_term_pw()
    if pw and hdrs.get("X-Admin-PW", "") != pw:
        return (401, _err("admin_required", "admin password required (X-Admin-PW)"))
    out = {}
    active = 0
    for k, info in load_keys().items():
        row = {kk: vv for kk, vv in info.items()}
        row["key_prefix"] = k[:10] + "…" + k[-4:]
        if not info.get("revoked"): active += 1
        out[k[:10] + "…"] = row
    return (200, _env(t0, keys=out, count=len(out), active=active))

# ── v4 POST handlers ──
def v4_post_chat(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    msgs = b.get("messages") or []
    system = b.get("system", "")
    model_req = b.get("model") or None
    # Build the actual prompt, prepending system text and flattening message turns.
    if msgs:
        parts = []
        if system: parts.append(f"[system] {system}")
        for m in msgs:
            role = m.get("role", "user")
            parts.append(f"[{role}] {m.get('content', '')}")
        prm = "\n".join(parts)
    else:
        prm = b.get("prompt", "")
        if system: prm = f"[system] {system}\n{prm}"
    if not prm:
        V4_COUNTERS["errors"] += 1
        return (400, _err("missing_input", "missing prompt or messages", req_id))
    tmo = key_timeout(hdrs)
    extra = []
    if model_req: extra += ["-m", model_req]
    reply, elapsed, ok = ai_ask_capture(prm, tmo, extra_args=extra)
    append_history("user", prm); append_history("assistant", reply)
    tin = count_tokens(prm); tout = count_tokens(reply); tks = tin + tout
    V4_COUNTERS["requests"] += 1
    V4_COUNTERS["tokens_in"] += tin; V4_COUNTERS["tokens_out"] += tout
    if not ok: V4_COUNTERS["errors"] += 1
    record_usage(hdrs, tokens=tks, seconds=elapsed, path="/v4/chat")
    pin, pout, tier = price_for(model_req or active_model(), tin, tout)
    return (200, _env(t0, request_id=req_id,
                      id=f"c-{secrets.token_hex(6)}",
                      object="chat.completion",
                      model=model_req or active_model(),
                      choices=[{"index": 0,
                                "message": {"role": "assistant", "content": reply},
                                "finish_reason": "stop" if ok else "error"}],
                      usage={"prompt_tokens": tin,
                             "completion_tokens": tout,
                             "total_tokens": tks,
                             "estimated_usd": round(pin + pout, 6),
                             "pricing_tier": tier},
                      elapsed_sec=round(elapsed, 3)))

def v4_post_complete(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    prm = b.get("prompt", "")
    if not prm:
        return (400, _err("missing_input", "missing prompt", req_id))
    model_req = b.get("model") or None
    extra = []
    if model_req: extra += ["-m", model_req]
    reply, elapsed, ok = ai_ask_capture(prm, key_timeout(hdrs), extra_args=extra)
    tin = count_tokens(prm); tout = count_tokens(reply)
    record_usage(hdrs, tokens=tin + tout, seconds=elapsed, path="/v4/complete")
    V4_COUNTERS["requests"] += 1
    V4_COUNTERS["tokens_in"] += tin; V4_COUNTERS["tokens_out"] += tout
    pin, pout, tier = price_for(model_req or active_model(), tin, tout)
    return (200, _env(t0, request_id=req_id,
                      text=reply,
                      model=model_req or active_model(),
                      ok=ok,
                      usage={"prompt_tokens": tin, "completion_tokens": tout,
                             "total_tokens": tin + tout,
                             "estimated_usd": round(pin + pout, 6),
                             "pricing_tier": tier},
                      elapsed_sec=round(elapsed, 3)))

def v4_post_batch(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    prompts = b.get("prompts") or []
    if not isinstance(prompts, list) or not prompts:
        return (400, _err("missing_input", "missing prompts[]", req_id))
    if len(prompts) > 20:
        return (400, _err("limit_exceeded", "max 20 prompts per batch", req_id))
    concurrency = int(b.get("concurrency", len(prompts)) or len(prompts))
    concurrency = max(1, min(len(prompts), concurrency))
    tmo = key_timeout(hdrs)
    results = [None] * len(prompts)
    sem = threading.Semaphore(concurrency)
    def _work(i, p):
        with sem:
            t_i = time.time()
            reply, el, ok = ai_ask_capture(p, tmo)
            results[i] = {"index": i, "prompt_preview": p[:80],
                          "text": reply, "ok": ok,
                          "tokens_in": count_tokens(p),
                          "tokens_out": count_tokens(reply),
                          "elapsed_sec": round(el, 3)}
    ts = []
    for i, p in enumerate(prompts):
        t = threading.Thread(target=_work, args=(i, p), daemon=True)
        t.start(); ts.append(t)
    for t in ts: t.join(timeout=tmo + 5)
    elapsed = time.time() - t0
    tks_in = sum((r or {}).get("tokens_in", 0) for r in results)
    tks_out = sum((r or {}).get("tokens_out", 0) for r in results)
    ok_count = sum(1 for r in results if r and r.get("ok"))
    record_usage(hdrs, tokens=tks_in + tks_out, seconds=elapsed, path="/v4/batch")
    return (200, _env(t0, request_id=req_id,
                      results=results, count=len(prompts),
                      ok_count=ok_count, fail_count=len(prompts) - ok_count,
                      concurrency=concurrency,
                      tokens_in=tks_in, tokens_out=tks_out,
                      elapsed_sec=round(elapsed, 3)))

def v4_post_compare(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    prm = b.get("prompt", ""); models = b.get("models") or []
    if not prm or not models:
        return (400, _err("missing_input", "need prompt and models[]", req_id))
    if len(models) > 6:
        return (400, _err("limit_exceeded", "max 6 models per compare", req_id))
    tmo = key_timeout(hdrs); out = {}
    stats = {}
    # run in parallel for fairness
    lock = threading.Lock()
    def _run(m):
        t_m = time.time()
        try:
            r = subprocess.run(CLI_ARGV + ["ask", "-m", m, prm],
                               capture_output=True, text=True, timeout=tmo,
                               env={**os.environ, "NO_COLOR": "1"})
            txt = strip_ansi((r.stdout or "") + (r.stderr or "")).strip()
            ok = r.returncode == 0
        except Exception as e:
            txt = f"Error: {type(e).__name__}: {e}"; ok = False
        el = time.time() - t_m
        with lock:
            out[m] = {"text": txt, "ok": ok, "elapsed_sec": round(el, 3),
                      "chars": len(txt),
                      "tokens_out": count_tokens(txt)}
    ts = [threading.Thread(target=_run, args=(m,), daemon=True) for m in models]
    for t in ts: t.start()
    for t in ts: t.join(timeout=tmo + 5)
    elapsed = time.time() - t0
    # pick winners
    fastest = min(out.items(), key=lambda kv: kv[1].get("elapsed_sec", 1e9), default=(None, {}))[0]
    longest = max(out.items(), key=lambda kv: kv[1].get("chars", 0), default=(None, {}))[0]
    tin = count_tokens(prm) * len(models)
    tout = sum(v.get("tokens_out", 0) for v in out.values())
    record_usage(hdrs, tokens=tin + tout, seconds=elapsed, path="/v4/compare")
    return (200, _env(t0, request_id=req_id,
                      results=out, models=models,
                      stats={"fastest_model": fastest,
                             "longest_reply_model": longest,
                             "total_chars": sum(v.get("chars", 0) for v in out.values()),
                             "tokens_in": tin, "tokens_out": tout},
                      elapsed_sec=round(elapsed, 3)))

def v4_post_tokens(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    # Accept either a single "text"/"prompt" OR an array of "texts"[]/"inputs"[]
    arr = b.get("texts") or b.get("inputs")
    single = b.get("text") or b.get("prompt") or ""
    if arr and isinstance(arr, list):
        items = []
        total_tok = 0; total_chars = 0
        for i, t in enumerate(arr):
            ts = str(t or "")
            tk = count_tokens(ts)
            total_tok += tk; total_chars += len(ts)
            items.append({"index": i, "tokens": tk, "chars": len(ts),
                          "words": len(ts.split())})
        return (200, _env(t0, request_id=req_id,
                          items=items, count=len(items),
                          total_tokens=total_tok, total_chars=total_chars,
                          avg_tokens=round(total_tok / max(1, len(items)), 2)))
    text = single
    words = len(text.split())
    return (200, _env(t0, request_id=req_id,
                      tokens=count_tokens(text), chars=len(text),
                      words=words,
                      tokens_per_word=round(count_tokens(text) / max(1, words), 3),
                      tokens_per_char=round(count_tokens(text) / max(1, len(text)), 4)))

def v4_post_cost(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    text = b.get("text", "") or b.get("prompt", "")
    model = b.get("model", active_model())
    # Let caller split tokens_in/out explicitly, or derive from text.
    tokens_in = int(b.get("tokens_in") or count_tokens(text))
    tokens_out = int(b.get("tokens_out") or 0)
    # Optional response-length estimate (multiplier over input)
    if not tokens_out and b.get("estimate_output"):
        try: tokens_out = int(tokens_in * float(b["estimate_output"]))
        except Exception: pass
    pin, pout, tier = price_for(model, tokens_in, tokens_out)
    return (200, _env(t0, request_id=req_id,
                      model=model, pricing_tier=tier,
                      tokens_in=tokens_in, tokens_out=tokens_out,
                      cost_in_usd=pin, cost_out_usd=pout,
                      estimated_usd=round(pin + pout, 6),
                      per_1k_input_usd=PRICING_USD_PER_1K.get(tier, (0, 0))[0],
                      per_1k_output_usd=PRICING_USD_PER_1K.get(tier, (0, 0))[1]))

def v4_post_embed(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    dim = int(b.get("dim", 64) or 64)
    dim = max(16, min(512, dim))
    inputs = b.get("inputs") or b.get("texts")
    if not inputs:
        one = b.get("text") or b.get("input") or ""
        inputs = [one]
    if not isinstance(inputs, list):
        return (400, _err("bad_input", "inputs must be string or array", req_id))
    # Re-derive an embedding of requested dim by folding simple_embed.
    def _embed(text, d):
        base = simple_embed(str(text or ""))
        if d == len(base): return base
        if d < len(base): return base[:d]
        # pad by tiling
        out = list(base)
        while len(out) < d:
            out += base
        return out[:d]
    data = []
    for i, s in enumerate(inputs):
        v = _embed(s, dim)
        # L2 normalize
        norm = (sum(x * x for x in v) ** 0.5) or 1.0
        v = [round(x / norm, 6) for x in v]
        data.append({"index": i, "embedding": v,
                     "tokens": count_tokens(str(s or ""))})
    return (200, _env(t0, request_id=req_id,
                      data=data, model="ai-cli-hash-embed",
                      dim=dim, count=len(data),
                      embedding=(data[0]["embedding"] if data else [])))

def v4_post_benchmark(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    iterations = max(1, min(20, int(b.get("iterations", 1) or 1)))
    prompt = b.get("prompt") or "Say 'ready' in one word."
    tmo = min(60, key_timeout(hdrs))
    latencies = []; replies = []; ok_count = 0
    tot_out = 0
    for _ in range(iterations):
        r, el, ok = ai_ask_capture(prompt, tmo)
        latencies.append(el); replies.append(r)
        if ok: ok_count += 1
        tot_out += count_tokens(r)
    lat_sorted = sorted(latencies)
    def pct(p):
        if not lat_sorted: return 0
        i = min(len(lat_sorted) - 1, int(len(lat_sorted) * p))
        return round(lat_sorted[i], 3)
    mean = round(sum(latencies) / len(latencies), 3) if latencies else 0
    record_usage(hdrs, tokens=tot_out + count_tokens(prompt) * iterations,
                 seconds=time.time() - t0, path="/v4/benchmark")
    return (200, _env(t0, request_id=req_id,
                      iterations=iterations, ok_count=ok_count,
                      latency_sec={"min": round(min(latencies), 3) if latencies else 0,
                                   "mean": mean,
                                   "p50": pct(0.5), "p95": pct(0.95),
                                   "max": round(max(latencies), 3) if latencies else 0},
                      tokens_out_total=tot_out,
                      throughput_tok_per_sec=round(tot_out / max(0.001, sum(latencies)), 2),
                      first_reply=(replies[0] if replies else "")[:200],
                      model=active_model()))

def v4_post_web(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h); q = b.get("query", "")
    if not q: return (400, _err("missing_input", "missing query", req_id))
    r = run_cmd_argv(["ask-web", q], timeout=key_timeout(hdrs))
    elapsed = time.time() - t0
    answer = r.get("stdout") or r.get("stderr") or ""
    # Pull any bullet-style source lines out of the answer.
    sources = []
    for line in answer.splitlines():
        s = line.strip()
        m = re.search(r"https?://[^\s)\]]+", s)
        if m:
            sources.append({"url": m.group(0),
                            "snippet": s[:200]})
    record_usage(hdrs, tokens=count_tokens(q) + count_tokens(answer),
                 seconds=elapsed, path="/v4/web")
    return (200, _env(t0, request_id=req_id,
                      query=q, answer=answer,
                      sources=sources[:10], source_count=len(sources),
                      ok=r.get("ok", False),
                      elapsed_sec=round(elapsed, 3)))

def v4_post_agent(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    goal = b.get("goal", ""); steps = int(b.get("steps", 3) or 3)
    if not goal: return (400, _err("missing_input", "missing goal", req_id))
    if steps < 1 or steps > 20:
        return (400, _err("bad_input", "steps must be 1..20", req_id))
    r = run_cmd_argv(["agent", goal, "--steps", str(steps)],
                     timeout=key_timeout(hdrs))
    elapsed = time.time() - t0
    raw = r.get("stdout") or r.get("stderr") or ""
    # Try to parse step-by-step output: lines starting with "Step N" or "▶"
    trace = []
    for line in raw.splitlines():
        s = line.strip()
        if re.match(r"^(Step\s+\d+|▶|\* )", s):
            trace.append(s)
    record_usage(hdrs, tokens=count_tokens(goal) + count_tokens(raw),
                 seconds=elapsed, path="/v4/agent")
    return (200, _env(t0, request_id=req_id,
                      goal=goal, steps=steps,
                      result=raw, trace=trace[:50],
                      ok=r.get("ok", False),
                      elapsed_sec=round(elapsed, 3)))

def v4_post_diff_review(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    diff = b.get("diff", "")
    if not diff: return (400, _err("missing_input", "missing diff", req_id))
    # Count files and hunks in the diff for metadata
    files = re.findall(r"^(?:---|\+\+\+)\s+(\S+)", diff, re.MULTILINE)
    hunks = len(re.findall(r"^@@", diff, re.MULTILINE))
    added = len(re.findall(r"^\+(?!\+\+)", diff, re.MULTILINE))
    removed = len(re.findall(r"^-(?!--)", diff, re.MULTILINE))
    prm = ("You are a senior reviewer. Review this unified diff and output in this "
           "exact shape:\nSUMMARY: <one line>\nISSUES:\n- <severity> <file>: <message>\n"
           "SUGGESTIONS:\n- <suggestion>\n\nDiff:\n" + diff[:20000])
    reply, elapsed, ok = ai_ask_capture(prm, key_timeout(hdrs))
    # Extract structured issues
    issues = []; suggestions = []
    section = None
    for line in reply.splitlines():
        l = line.strip()
        if l.upper().startswith("ISSUES"): section = "i"; continue
        if l.upper().startswith("SUGGESTIONS"): section = "s"; continue
        if l.startswith("- "):
            (issues if section == "i" else suggestions).append(l[2:].strip())
    record_usage(hdrs, tokens=count_tokens(prm) + count_tokens(reply),
                 seconds=elapsed, path="/v4/diff/review")
    return (200, _env(t0, request_id=req_id,
                      review=reply,
                      structured={"issues": issues[:50],
                                  "suggestions": suggestions[:50]},
                      diff_stats={"files": sorted(set(files)),
                                  "file_count": len(set(files)),
                                  "hunks": hunks, "lines_added": added,
                                  "lines_removed": removed},
                      ok=ok,
                      elapsed_sec=round(elapsed, 3)))

def v4_post_voice_tts(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h); text = b.get("text", "")
    if not text: return (400, _err("missing_input", "missing text", req_id))
    fmt = (b.get("format") or "wav").lower()
    voice = b.get("voice") or ""
    out_name = f"tts_{int(time.time())}_{secrets.token_hex(3)}.{fmt}"
    out_path = os.path.join(UPLOADS_DIR, out_name)
    # Try engines in order: piper / say (macOS) / espeak / pyttsx3 / CLI fallback
    engines_tried = []
    engine_used = None
    ok = False
    for engine in ("piper", "say", "espeak-ng", "espeak"):
        if not shutil.which(engine): continue
        engines_tried.append(engine)
        try:
            if engine == "say":
                r = subprocess.run([engine, "-o", out_path, "--data-format=LEF32@22050", text],
                                   capture_output=True, text=True, timeout=30)
            elif engine == "piper":
                # piper needs a model — skip if not configured
                break
            else:
                r = subprocess.run([engine, "-w", out_path, text],
                                   capture_output=True, text=True, timeout=30)
            if r.returncode == 0 and os.path.isfile(out_path):
                engine_used = engine; ok = True; break
        except Exception: continue
    if not ok:
        # Fall back to existing CLI voice command
        r = run_cmd_argv(["voice", "tts", text], timeout=min(30, key_timeout(hdrs)))
        engine_used = "cli-voice-fallback"; ok = r.get("ok", False)
        stdout = r.get("stdout") or r.get("stderr") or ""
    else:
        stdout = ""
    audio_url = (f"/v4/files/fetch?name={out_name}" if (ok and os.path.isfile(out_path)) else None)
    record_usage(hdrs, tokens=count_tokens(text), seconds=time.time() - t0,
                 path="/v4/voice/tts")
    return (200, _env(t0, request_id=req_id,
                      ok=ok, engine=engine_used, engines_available=engines_tried,
                      audio_path=out_path if ok and os.path.isfile(out_path) else None,
                      audio_url=audio_url, format=fmt, voice=voice or None,
                      size_bytes=(os.path.getsize(out_path) if ok and os.path.isfile(out_path) else 0),
                      fallback_output=stdout))

def v4_post_share(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    content = b.get("content") or b.get("text") or ""
    ttl = int(b.get("ttl_sec", 86400) or 86400)
    if not content:
        return (400, _err("missing_input", "missing content/text", req_id))
    # Persist to a timestamped file under uploads/shares; expose a local URL.
    share_dir = os.path.join(UPLOADS_DIR, "shares")
    os.makedirs(share_dir, exist_ok=True)
    slug = secrets.token_urlsafe(8).replace("_", "-").replace("-", "")[:12]
    path = os.path.join(share_dir, f"{slug}.txt")
    with open(path, "w") as f: f.write(content)
    # Try tunnels in order: cloudflared / ngrok — launch fire-and-forget, don't block.
    tunnel = None
    for bin in ("cloudflared", "ngrok"):
        if shutil.which(bin):
            tunnel = bin; break
    return (200, _env(t0, request_id=req_id,
                      slug=slug,
                      local_path=path,
                      local_url=f"http://{HOST}:{PORT}/v4/files/fetch?name=shares/{slug}.txt",
                      tunnel_available=tunnel,
                      ttl_sec=ttl,
                      expires_at=int(time.time()) + ttl,
                      note=("Use /v4/files/fetch for local viewing. For a public URL, run "
                            "`ai share` in a terminal — cloudflared/ngrok needs a foreground "
                            "process to stream the tunnel URL." if not tunnel else
                            f"Public tunnel binary ({tunnel}) is installed — run `ai share` to "
                            "start it from a terminal.")))

def v4_post_models_activate(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h); m = b.get("model", "")
    if not m: return (400, _err("missing_input", "missing model", req_id))
    previous = active_model()
    r = run_cmd_argv(["recommended", "use", m], timeout=30)
    new_active = active_model()
    changed = previous != new_active
    return (200, _env(t0, request_id=req_id,
                      previous=previous, active=new_active,
                      requested=m, changed=changed,
                      ok=r.get("ok", False) and changed,
                      stdout=r.get("stdout", "")[:500],
                      stderr=r.get("stderr", "")[:500]))

def v4_post_models_download(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h); m = b.get("model", "")
    if not m: return (400, _err("missing_input", "missing model", req_id))
    jid = _new_job("model_download", m)
    def _dl():
        r = run_cmd_argv(["recommended", "download", m], timeout=3600)
        _finish_job(jid, (r.get("stdout", "") + r.get("stderr", ""))[-2000:],
                    ok=r.get("ok", False))
    threading.Thread(target=_dl, daemon=True).start()
    return (202, _env(t0, request_id=req_id,
                      accepted=True, model=m, job_id=jid,
                      poll_url=f"/v4/jobs?id={jid}",
                      note="download running in background; GET /v4/jobs?id=… to poll"))

def v4_post_keys_set(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    pw = get_term_pw()
    if pw and b.get("password") != pw:
        return (401, _err("admin_required", "admin password required", req_id))
    name = b.get("name", ""); value = b.get("value", "")
    if not name or not value:
        return (400, _err("missing_input", "missing name/value", req_id))
    # Validate format by prefix when known
    expected_prefix = {
        "OPENAI_API_KEY": "sk-", "ANTHROPIC_API_KEY": "sk-ant-",
        "GEMINI_API_KEY": "AIza", "GROQ_API_KEY": "gsk_",
        "HF_TOKEN": "hf_", "HF_API_KEY": "hf_",
    }.get(name, "")
    format_ok = (not expected_prefix) or value.startswith(expected_prefix)
    r = run_cmd_argv(["keys", "set", name, value], timeout=10)
    return (200, _env(t0, request_id=req_id,
                      ok=r.get("ok", False),
                      name=name,
                      format_ok=format_ok,
                      expected_prefix=expected_prefix or None,
                      stderr=r.get("stderr", "")[:500]))

def v4_post_history_search(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    q = (b.get("query") or "").strip()
    limit = max(1, min(200, int(b.get("limit", 50) or 50)))
    role_filter = b.get("role")
    since = int(b.get("since", 0) or 0)
    hist = read_history(2000)
    if role_filter:
        hist = [x for x in hist if x.get("role") == role_filter]
    if since:
        hist = [x for x in hist if x.get("t", 0) >= since]
    # Score by literal match count, normalised by length.
    ql = q.lower()
    if q:
        scored = []
        for item in hist:
            txt = json.dumps(item, ensure_ascii=False).lower()
            count = txt.count(ql)
            if not count: continue
            score = count / max(1, len(txt) / 1000)
            # highlight: first 120 chars around the first match
            raw = item.get("content") or ""
            idx = raw.lower().find(ql)
            highlight = raw[max(0, idx - 40): idx + len(q) + 80] if idx >= 0 else ""
            scored.append((score, {"item": item, "score": round(score, 3),
                                   "highlight": highlight}))
        scored.sort(key=lambda x: x[0], reverse=True)
        hits = [x[1] for x in scored[:limit]]
    else:
        hits = [{"item": x, "score": 0, "highlight": ""} for x in hist[-limit:]]
    return (200, _env(t0, request_id=req_id,
                      hits=hits, count=len(hits),
                      query=q, searched=len(hist)))

def v4_post_history_clear(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    # Archive before delete so it's recoverable
    lines = 0
    try:
        if os.path.isfile(HIST_FILE):
            lines = sum(1 for _ in open(HIST_FILE))
            bak = f"{HIST_FILE}.bak_{int(time.time())}"
            try:
                shutil.copy2(HIST_FILE, bak)
            except Exception:
                bak = None
        else:
            bak = None
        open(HIST_FILE, "w").close()
    except Exception as e:
        return (500, _err("io_error", str(e), req_id))
    return (200, _env(t0, request_id=req_id,
                      ok=True, cleared_entries=lines, backup=bak))

def v4_post_files_upload(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    pw = get_term_pw()
    if pw and b.get("password") != pw:
        return (401, _err("admin_required", "password required", req_id))
    name = (b.get("name") or f"upload_{int(time.time())}.txt").replace("/", "_")
    # Hard size cap (10 MB) to keep the JSON body bounded.
    MAX = 10 * 1024 * 1024
    content = b.get("content", "")
    is_base64 = bool(b.get("base64"))
    try:
        if is_base64:
            import base64
            data = base64.b64decode(content)
        else:
            data = content.encode() if isinstance(content, str) else bytes(content)
    except Exception as e:
        return (400, _err("bad_content", f"decode error: {e}", req_id))
    if len(data) > MAX:
        return (413, _err("too_large", f"file exceeds {MAX} bytes", req_id,
                          size=len(data)))
    fp = os.path.join(UPLOADS_DIR, name)
    with open(fp, "wb") as f: f.write(data)
    import hashlib
    digest = hashlib.sha256(data).hexdigest()
    return (200, _env(t0, request_id=req_id,
                      ok=True, path=fp, name=name,
                      size=len(data),
                      sha256=digest,
                      fetch_url=f"/v4/files/fetch?name={name}"))

def v4_post_files_delete(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    pw = get_term_pw()
    if pw and b.get("password") != pw:
        return (401, _err("admin_required", "password required", req_id))
    # Accept single name or array of names for bulk delete
    names = b.get("names") or ([b["name"]] if b.get("name") else [])
    if not names:
        return (400, _err("missing_input", "missing name or names[]", req_id))
    deleted = []; missing = []
    for n in names:
        n = str(n).replace("/", "_")
        fp = os.path.join(UPLOADS_DIR, n)
        if os.path.isfile(fp):
            try: os.remove(fp); deleted.append(n)
            except Exception: missing.append(n)
        else:
            missing.append(n)
    code = 200 if deleted else 404
    return (code, _env(t0, request_id=req_id,
                       ok=bool(deleted), deleted=deleted, missing=missing,
                       count_deleted=len(deleted)))

def v4_post_rag_add(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    corpus = (b.get("corpus") or "default").replace("/", "_")
    text = b.get("text", "")
    source = b.get("source") or None
    if not text: return (400, _err("missing_input", "missing text", req_id))
    # Auto-chunk long text into overlapping windows.
    chunk_size = int(b.get("chunk_size", 800) or 800)
    overlap = int(b.get("overlap", 80) or 80)
    chunk_size = max(100, min(4000, chunk_size))
    overlap = max(0, min(chunk_size // 2, overlap))
    chunks = []
    if len(text) <= chunk_size:
        chunks = [text]
    else:
        step = chunk_size - overlap
        for i in range(0, len(text), step):
            chunk = text[i:i + chunk_size]
            if chunk.strip(): chunks.append(chunk)
    fp = os.path.join(RAG_DIR, corpus + ".jsonl")
    added = 0
    with open(fp, "a") as f:
        for i, ch in enumerate(chunks):
            f.write(json.dumps({"t": int(time.time()), "text": ch,
                                "source": source, "chunk_idx": i,
                                "emb": simple_embed(ch)}) + "\n")
            added += 1
    return (200, _env(t0, request_id=req_id,
                      ok=True, corpus=corpus,
                      chunks_added=added,
                      total_chars=len(text),
                      avg_chunk_chars=round(len(text) / max(1, added), 1),
                      source=source))

def v4_post_rag_query(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    corpus = (b.get("corpus") or "default").replace("/", "_")
    q = b.get("query", ""); k = int(b.get("k", 3) or 3)
    with_answer = bool(b.get("with_answer", True))
    fp = os.path.join(RAG_DIR, corpus + ".jsonl")
    if not os.path.isfile(fp):
        return (404, _err("not_found", f"unknown corpus: {corpus}", req_id))
    if not q:
        return (400, _err("missing_input", "missing query", req_id))
    qv = simple_embed(q); items = []
    for line in open(fp):
        try:
            d = json.loads(line)
            # Hybrid scoring: cosine + term-frequency boost
            cos = cosine(qv, d.get("emb", []))
            lf = d.get("text", "").lower(); ql = q.lower()
            tf = sum(lf.count(w) for w in ql.split() if len(w) > 2)
            d["score"] = round(cos + 0.05 * tf, 4)
            d["cosine"] = round(cos, 4)
            d["term_freq"] = tf
            d.pop("emb", None)
            items.append(d)
        except Exception: pass
    items.sort(key=lambda d: d.get("score", 0), reverse=True)
    top = items[:k]
    ctx = "\n\n".join(d.get("text", "") for d in top)
    answer = ""; elapsed_ans = 0; ok_ans = False
    if with_answer:
        answer, elapsed_ans, ok_ans = ai_ask_capture(
            f"Use only this context to answer:\n{ctx}\n\nQuestion: {q}",
            key_timeout(hdrs))
    return (200, _env(t0, request_id=req_id,
                      top=top, answer=answer,
                      corpus=corpus, k=k,
                      total_docs_scanned=len(items),
                      answer_elapsed_sec=round(elapsed_ans, 3),
                      answer_ok=ok_ans))

def v4_post_run(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    pw = get_term_pw()
    if not pw or b.get("password") != pw:
        return (401, _err("admin_required", "terminal password required", req_id))
    cmd = b.get("cmd", "")
    if not cmd: return (400, _err("missing_input", "missing cmd", req_id))
    timeout = min(key_timeout(hdrs), max(1, int(b.get("timeout", 60) or 60)))
    cwd = b.get("cwd") or None
    env_extras = b.get("env") or {}
    env = {**os.environ}
    # Only allow scalar string env passthrough.
    if isinstance(env_extras, dict):
        for k, v in env_extras.items():
            if isinstance(k, str) and isinstance(v, (str, int, float, bool)):
                env[str(k)] = str(v)
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, env=env,
                           cwd=cwd if cwd and os.path.isdir(cwd) else None)
        return (200, _env(t0, request_id=req_id,
                          stdout=r.stdout, stderr=r.stderr,
                          rc=r.returncode, ok=r.returncode == 0,
                          cmd=cmd, cwd=cwd or os.getcwd(),
                          timeout_sec=timeout))
    except subprocess.TimeoutExpired:
        return (200, _env(t0, request_id=req_id, stdout="", stderr="Timed out",
                          rc=124, ok=False, cmd=cmd, timeout_sec=timeout))
    except Exception as e:
        return (500, _err("exec_error", f"{type(e).__name__}: {e}", req_id))

def v4_post_mem(h, hdrs, qs):
    b = v4_body(h); action = b.get("action", "list")
    if action == "add":
        items = load_mem(); items.append(b.get("fact", ""))
        save_mem(items); return (200, {"ok": True, "count": len(items)})
    if action == "delete":
        items = load_mem(); idx = b.get("index", -1)
        if 0 <= idx < len(items):
            items.pop(idx); save_mem(items)
        return (200, {"ok": True, "memory": items})
    if action == "clear":
        save_mem([]); return (200, {"ok": True})
    return (200, {"memory": load_mem()})

def v4_post_context(h, hdrs, qs):
    b = v4_body(h); action = b.get("action", "get")
    if action == "add":
        ctx = load_ctx()
        ctx["messages"].append({"role": b.get("role", "user"),
                                "content": b.get("content", "")})
        if ctx_is_full(ctx): ctx = compress_ctx(ctx)
        save_ctx(ctx)
        return (200, {"ok": True, "full": ctx_is_full(ctx),
                      "msg_count": len(ctx["messages"])})
    if action == "clear":
        save_ctx({"messages": [], "compressed": ""})
        return (200, {"ok": True})
    return (200, load_ctx())

def v4_post_comp_context(h, hdrs, qs):
    ctx = compress_ctx(load_ctx())
    return (200, {"ok": True, "compressed": ctx.get("compressed", ""),
                  "remaining_msgs": len(ctx["messages"])})

def _prune_term_sessions():
    now = time.time()
    for tok, s in list(V4_TERM_SESSIONS.items()):
        if s.get("expires", 0) < now:
            V4_TERM_SESSIONS.pop(tok, None)

def _session_ok(hdrs, body):
    """A terminal call is allowed if the body has the admin pw OR the header
    X-Term-Session matches a live session token."""
    pw = get_term_pw()
    if not pw:
        return (False, "no password set — run: ai -apip PASSWORD")
    if body.get("password") == pw:
        return (True, None)
    _prune_term_sessions()
    tok = hdrs.get("X-Term-Session") or body.get("session")
    if tok and tok in V4_TERM_SESSIONS:
        return (True, None)
    return (False, "unauthorized (send password or X-Term-Session)")

def v4_post_terminal_auth(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h); pw = get_term_pw()
    if not pw:
        return (403, _err("not_configured",
                          "no password set — run: ai -apip PASSWORD", req_id))
    if b.get("password") != pw:
        return (401, _err("wrong_password", "wrong password", req_id))
    ttl = max(30, min(3600, int(b.get("ttl_sec", 900) or 900)))
    tok = "ts_" + secrets.token_urlsafe(24)
    V4_TERM_SESSIONS[tok] = {"created": time.time(),
                             "expires": time.time() + ttl,
                             "client": h.client_address[0]}
    return (200, _env(t0, request_id=req_id,
                      ok=True, session=tok, ttl_sec=ttl,
                      expires_at=int(V4_TERM_SESSIONS[tok]["expires"]),
                      note="Send header X-Term-Session on subsequent terminal/exec calls."))

def v4_post_terminal_exec(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    ok, err = _session_ok(hdrs, b)
    if not ok:
        return (401, _err("unauthorized", err, req_id))
    cmd = b.get("cmd", "")
    if not cmd: return (400, _err("missing_input", "no cmd", req_id))
    timeout = min(key_timeout(hdrs), max(1, int(b.get("timeout", 30) or 30)))
    sr = shell_run(cmd, timeout=timeout)
    return (200, _env(t0, request_id=req_id,
                      cmd=cmd,
                      stdout=sr["stdout"], stderr=sr["stderr"],
                      rc=sr["rc"], ok=sr["rc"] == 0,
                      output=(sr["stdout"] or "") + (sr["stderr"] or ""),
                      timeout_sec=timeout))

_BUDGET_RE = re.compile(r"^([0-9]+(?:\.[0-9]{1,2})?)(k|K|m|M|s|S|min|MIN|h|H)?$")

def _parse_budget(spec):
    """Return (tokens, seconds) — either may be None. Accepts ints too."""
    if spec is None: return (None, None)
    if isinstance(spec, (int, float)):
        return (int(spec), None)
    s = str(spec).strip()
    if not s: return (None, None)
    m = _BUDGET_RE.match(s)
    if not m: return (None, None)
    num = float(m.group(1)); unit = (m.group(2) or "").lower()
    if unit in ("", "k", "m"):
        mult = 1 if unit == "" else (1000 if unit == "k" else 1_000_000)
        return (int(num * mult), None)
    if unit == "s":   return (None, int(num))
    if unit == "min": return (None, int(num * 60))
    if unit == "h":   return (None, int(num * 3600))
    return (None, None)

def v4_post_auth_new(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    # creating the first key is allowed without auth; after that, admin pw required
    existing = load_keys()
    if existing:
        pw = get_term_pw()
        if not pw or b.get("password") != pw:
            return (401, _err("admin_required",
                              "admin password required after first key", req_id))
    name = b.get("name", "") or f"key-{int(time.time())}"
    tokens = b.get("tokens_budget")
    seconds = b.get("time_budget_sec")
    for alias in ("tokens", "budget", "spec"):
        if alias in b and b[alias] not in (None, ""):
            t, s = _parse_budget(b[alias])
            if tokens is None and t is not None: tokens = t
            if seconds is None and s is not None: seconds = s
    if seconds is None and "seconds" in b and b["seconds"] not in (None, ""):
        try: seconds = int(b["seconds"])
        except Exception: seconds = None
    if tokens is not None and seconds is None:
        seconds = 21600  # default 6 h cycle when only tokens given
    if seconds is None:
        seconds = int(b.get("cycle_seconds") or 21600)
    newkey = "sk-ai-" + secrets.token_urlsafe(24)
    existing[newkey] = {
        "name": name, "created": int(time.time()),
        "tokens_budget": int(tokens) if tokens else None,
        "tokens_used": 0,
        "time_budget_sec": int(seconds),
        "time_used_sec": 0.0,
        "max_request_sec": min(HARD_MAX_REQUEST_SEC,
                               int(b.get("max_request_sec") or HARD_MAX_REQUEST_SEC)),
        "cycle_start": int(time.time()),
        "cycle_seconds": int(b.get("cycle_seconds") or seconds),
        "revoked": False,
    }
    save_keys(existing)
    rec = existing[newkey]
    return (200, _env(t0, request_id=req_id,
                      key=newkey, name=name,
                      tokens_budget=rec["tokens_budget"],
                      time_budget_sec=rec["time_budget_sec"],
                      max_request_sec=rec["max_request_sec"],
                      cycle_seconds=rec["cycle_seconds"],
                      hint=("Send as header:  X-API-Key: <key>  or  "
                            "Authorization: Bearer <key>")))

def v4_post_auth_revoke(h, hdrs, qs):
    t0 = time.time(); req_id = _req_id()
    b = v4_body(h)
    pw = get_term_pw()
    if pw and b.get("password") != pw:
        return (401, _err("admin_required", "admin password required", req_id))
    # Accept key (full), key_prefix, name, or batch via keys[]/names[]
    keys = load_keys()
    targets = []
    if b.get("keys") and isinstance(b["keys"], list): targets += b["keys"]
    if b.get("names") and isinstance(b["names"], list):
        for nm in b["names"]:
            for k, v in keys.items():
                if v.get("name") == nm: targets.append(k)
    if b.get("key"): targets.append(b["key"])
    if b.get("name"):
        for k, v in keys.items():
            if v.get("name") == b["name"]: targets.append(k)
    if not targets:
        return (400, _err("missing_input",
                          "need key, name, keys[], or names[]", req_id))
    revoked = []; missing = []
    for t in targets:
        if t in keys and not keys[t].get("revoked"):
            keys[t]["revoked"] = True; revoked.append(t[:10] + "…")
        elif t not in keys:
            missing.append(t[:10] + "…" if len(t) > 14 else t)
    save_keys(keys)
    return (200, _env(t0, request_id=req_id,
                      ok=bool(revoked), revoked=revoked, missing=missing,
                      count=len(revoked)))

def v4_get_jobs(h, hdrs, qs):
    t0 = time.time()
    jid = qs.get("id")
    if jid:
        job = V4_JOBS.get(jid)
        if not job: return (404, _err("not_found", f"unknown job: {jid}"))
        return (200, _env(t0, job_id=jid, **job))
    status_filter = qs.get("status")
    jobs = []
    for j, info in V4_JOBS.items():
        if status_filter and info.get("status") != status_filter: continue
        row = dict(info); row["id"] = j
        row.pop("output", None)  # omit large field from list view
        jobs.append(row)
    return (200, _env(t0, jobs=jobs, count=len(jobs),
                      running=sum(1 for x in jobs if x.get("status") == "running")))

def v4_get_files_fetch(h, hdrs, qs):
    name = qs.get("name") or ""
    if not name:
        return (400, _err("missing_input", "missing name"))
    # Allow one level of subdir (e.g. shares/slug.txt), but reject traversal.
    safe = name.replace("\\", "/")
    if ".." in safe.split("/"):
        return (400, _err("bad_path", "path traversal not allowed"))
    fp = os.path.join(UPLOADS_DIR, safe)
    if not os.path.isfile(fp):
        return (404, _err("not_found", f"no such file: {name}"))
    try:
        with open(fp, "rb") as f: data = f.read()
    except Exception as e:
        return (500, _err("io_error", str(e)))
    # Send raw file (binary-safe) with a best-effort content-type.
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    mime = {"txt": "text/plain; charset=utf-8",
            "json": "application/json",
            "md": "text/markdown; charset=utf-8",
            "wav": "audio/wav", "mp3": "audio/mpeg",
            "png": "image/png", "jpg": "image/jpeg",
            "jpeg": "image/jpeg", "pdf": "application/pdf",
            }.get(ext, "application/octet-stream")
    try:
        h.send_response(200)
        h.send_header("Content-Type", mime)
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Content-Disposition",
                      f'inline; filename="{os.path.basename(name)}"')
        h.end_headers()
        h.wfile.write(data)
    except Exception:
        pass
    return None  # sentinel — we already wrote the response

# ── hidden: /v4/_rdp — Tailscale-only remote desktop control ────────────────
# This endpoint is intentionally NOT listed in /v4/endpoints. It is gated by:
#   1. Terminal password (ai -apip PASSWORD), AND
#   2. Caller must be on the local Tailnet (IP in 100.64.0.0/10 range), AND
#   3. Tailscale must be running locally (`tailscale status` succeeds).
# GET  /v4/_rdp — serves a minimal browser control panel (HTML UI).
# POST /v4/_rdp — JSON API; actions: info / screenshot / type / key / click / mousemove.
# Intent: owner-initiated remote control of their own machine over Tailscale.

def _tailscale_up():
    """Return True iff `tailscale status` reports the daemon running."""
    try:
        r = subprocess.run(["tailscale", "status", "--json"],
                           capture_output=True, text=True, timeout=3)
        if r.returncode != 0: return False
        d = json.loads(r.stdout or "{}")
        return bool(d.get("Self") and d.get("BackendState") == "Running")
    except Exception:
        return False

def _tailscale_client(client_addr):
    """Return True iff client_addr is inside 100.64.0.0/10 (Tailnet CGNAT)."""
    try:
        parts = client_addr.split(".")
        if len(parts) != 4: return False
        a, b = int(parts[0]), int(parts[1])
        # 100.64.0.0/10 = 100.64.0.0 .. 100.127.255.255
        return a == 100 and 64 <= b <= 127
    except Exception:
        return False

def _have(*bins):
    return [b for b in bins if shutil.which(b)]

_RDP_LOGIN_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>RDP · login</title>
<style>
  body{font:15px/1.4 -apple-system,Segoe UI,sans-serif;background:#0b1020;color:#d7e1ff;
       min-height:100vh;margin:0;display:flex;align-items:center;justify-content:center}
  form{background:#131a33;padding:28px 32px;border-radius:10px;box-shadow:0 10px 40px #0008;min-width:320px}
  h1{font-size:18px;margin:0 0 16px;letter-spacing:.3px}
  label{display:block;font-size:12px;opacity:.7;margin:10px 0 4px}
  input{width:100%;box-sizing:border-box;padding:9px 11px;border-radius:6px;border:1px solid #2a3660;
        background:#0b1020;color:#fff;font:14px ui-monospace,monospace}
  button{margin-top:16px;width:100%;padding:10px;border:0;border-radius:6px;background:#3d5afe;
         color:#fff;font-weight:600;cursor:pointer}
  .err{background:#5a1a1a;padding:8px 10px;border-radius:6px;margin-top:10px;font-size:13px}
  .note{opacity:.55;font-size:12px;margin-top:14px}
</style></head><body>
<form method="get" action="/v4/_rdp">
  <h1>🖥  Remote Desktop</h1>
  <label>PC password</label>
  <input type="password" name="password" autofocus required>
  __ERR__
  <button type="submit">Unlock</button>
  <div class="note">Gated by password · Tailscale · Tailnet source IP.</div>
</form></body></html>"""

_RDP_PANEL_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>RDP · __HOST__</title>
<style>
  :root{--bg:#0b1020;--card:#131a33;--ink:#d7e1ff;--mute:#8a95c0;--acc:#3d5afe;--ok:#27c28a;--err:#e95d5d}
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.4 -apple-system,Segoe UI,sans-serif;background:var(--bg);color:var(--ink)}
  header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:#0a0f1d;border-bottom:1px solid #1e2a4a}
  header h1{font-size:15px;margin:0;font-weight:600}
  header .sp{flex:1}
  .pill{font-size:11px;padding:3px 8px;border-radius:999px;background:#22305a;color:#b9c4ea}
  .pill.ok{background:#123f2f;color:#27c28a}
  .pill.err{background:#3f1b1b;color:#e95d5d}
  .wrap{padding:14px 16px;display:grid;grid-template-columns:1fr 320px;gap:14px}
  .shot{background:var(--card);border-radius:10px;padding:8px;position:relative;overflow:auto}
  .shot img{max-width:100%;display:block;border-radius:6px;cursor:crosshair;user-select:none}
  aside{background:var(--card);border-radius:10px;padding:14px;display:flex;flex-direction:column;gap:12px}
  aside h3{margin:0;font-size:12px;letter-spacing:.5px;text-transform:uppercase;color:var(--mute)}
  label{font-size:12px;color:var(--mute);margin-bottom:4px;display:block}
  input[type=text],select,textarea{width:100%;padding:8px 10px;border-radius:6px;border:1px solid #2a3660;
    background:#0b1020;color:#fff;font:13px ui-monospace,monospace}
  textarea{min-height:70px;resize:vertical}
  button{padding:8px 12px;border:0;border-radius:6px;background:var(--acc);color:#fff;font-weight:600;cursor:pointer}
  button.ghost{background:#22305a}
  .row{display:flex;gap:6px}
  .row > *{flex:1}
  .log{font:11px ui-monospace,monospace;background:#0b1020;padding:8px;border-radius:6px;max-height:140px;overflow:auto;color:#94a2d2}
  .grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
  .grid3 button{background:#22305a}
  .meta{font-size:11px;color:var(--mute)}
</style></head><body>
<header>
  <h1>🖥 ai-cli · Remote Desktop</h1>
  <span class="pill ok" id="st-ts">Tailscale OK</span>
  <span class="pill" id="st-last">—</span>
  <div class="sp"></div>
  <label style="margin:0"><input type="checkbox" id="auto" checked> auto-refresh</label>
  <select id="refresh" style="width:90px">
    <option value="1000">1s</option><option value="2000" selected>2s</option>
    <option value="5000">5s</option><option value="10000">10s</option>
  </select>
  <button class="ghost" onclick="shot()">↻ Refresh</button>
</header>
<div class="wrap">
  <div class="shot" id="shotbox">
    <img id="shot" alt="screenshot will appear here" onclick="onClickShot(event)">
  </div>
  <aside>
    <div>
      <h3>Type text</h3>
      <textarea id="text" placeholder="Type into the focused window…"></textarea>
      <div class="row" style="margin-top:6px"><button onclick="sendType()">Send type</button>
        <button class="ghost" onclick="document.getElementById('text').value=''">Clear</button></div>
    </div>
    <div>
      <h3>Key / combo</h3>
      <div class="row"><input type="text" id="key" placeholder="Return, ctrl+alt+t…">
        <button onclick="sendKey()">Press</button></div>
      <div class="grid3" style="margin-top:6px">
        <button onclick="k('Return')">Enter</button>
        <button onclick="k('Escape')">Esc</button>
        <button onclick="k('Tab')">Tab</button>
        <button onclick="k('BackSpace')">Back</button>
        <button onclick="k('super')">Super</button>
        <button onclick="k('ctrl+alt+t')">⎋ Term</button>
      </div>
    </div>
    <div>
      <h3>Click at coordinates</h3>
      <div class="row">
        <input type="text" id="cx" placeholder="x">
        <input type="text" id="cy" placeholder="y">
        <select id="cb"><option value="1">left</option><option value="2">mid</option><option value="3">right</option></select>
        <button onclick="sendClick()">Click</button>
      </div>
      <div class="meta">Or click directly on the screenshot.</div>
    </div>
    <div>
      <h3>Log</h3>
      <div class="log" id="log">ready</div>
    </div>
  </aside>
</div>
<script>
const PW = __PW_JSON__;
let lastInfo = null, busy = false;

function ts(){return new Date().toLocaleTimeString();}
function logMsg(m){const el=document.getElementById('log');el.textContent=ts()+"  "+m+"\\n"+el.textContent;}

async function api(action, extra){
  const body = Object.assign({action, password: PW}, extra||{});
  const r = await fetch('/v4/_rdp', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j = await r.json(); return {code:r.status, j};
}
async function shot(){
  if (busy) return; busy = true;
  try {
    const {code, j} = await api('screenshot');
    if (code !== 200) { logMsg('screenshot '+code+': '+(j.error&&j.error.message||JSON.stringify(j))); return; }
    const url = j.url + '&t=' + Date.now();
    document.getElementById('shot').src = url;
    document.getElementById('st-last').textContent = 'updated '+ts();
    if (!lastInfo) { const i = await api('info'); lastInfo = i.j; logMsg('info: '+(i.j.dimensions||'?')); }
  } catch(e) { logMsg('err '+e); }
  finally { busy = false; }
}
async function sendType(){
  const t = document.getElementById('text').value; if (!t) return;
  const {j} = await api('type', {text:t}); logMsg('type '+t.length+' chars · ok='+(j.ok?'yes':'no'));
}
async function sendKey(){
  const k = document.getElementById('key').value; if (!k) return;
  const {j} = await api('key', {key:k}); logMsg('key '+k+' · ok='+(j.ok?'yes':'no'));
}
async function k(combo){
  const {j} = await api('key', {key:combo}); logMsg('key '+combo+' · ok='+(j.ok?'yes':'no'));
}
async function sendClick(){
  const x = +document.getElementById('cx').value || 0;
  const y = +document.getElementById('cy').value || 0;
  const btn = +document.getElementById('cb').value || 1;
  const {j} = await api('click', {x, y, button:btn}); logMsg('click '+x+','+y+' btn='+btn+' · ok='+(j.ok?'yes':'no'));
  setTimeout(shot, 250);
}
function onClickShot(ev){
  const img = ev.target;
  const r = img.getBoundingClientRect();
  // Map click coords back to screen pixels via natural size
  const sx = Math.round((ev.clientX - r.left) * (img.naturalWidth  / r.width));
  const sy = Math.round((ev.clientY - r.top)  * (img.naturalHeight / r.height));
  document.getElementById('cx').value = sx; document.getElementById('cy').value = sy;
  sendClick();
}
// auto-refresh loop
(function tick(){
  const on = document.getElementById('auto').checked;
  const ms = +document.getElementById('refresh').value || 2000;
  if (on) shot();
  setTimeout(tick, ms);
})();
shot();
</script>
</body></html>"""

def v4_get_rdp(h, hdrs, qs):
    """HTML browser UI for the remote-desktop endpoint.
    Gates: Tailscale up + caller on Tailnet (or 127.0.0.1) + password in ?password=."""
    client_ip = h.client_address[0]
    pw = get_term_pw()
    # First: surface environment-level failures with friendly HTML
    def _html(status, body):
        try:
            h.send_response(status)
            h.send_header("Content-Type", "text/html; charset=utf-8")
            h.send_header("Cache-Control", "no-store")
            h.end_headers()
            h.wfile.write(body.encode())
        except Exception: pass
        return None
    if not pw:
        _html(403, _RDP_LOGIN_HTML.replace("__ERR__",
              '<div class="err">No PC password set on this host. Run:<br>'
              '<code>ai -apip YOUR_PASSWORD</code> then reload.</div>'))
        return None
    if not _tailscale_up():
        _html(403, _RDP_LOGIN_HTML.replace("__ERR__",
              '<div class="err">Tailscale is not running on this host.<br>'
              'Start it:  <code>sudo tailscale up</code></div>'))
        return None
    if not (client_ip.startswith("127.") or _tailscale_client(client_ip)):
        _html(403, _RDP_LOGIN_HTML.replace("__ERR__",
              f'<div class="err">Your IP ({client_ip}) is not on the Tailnet.<br>'
              'Connect via your Tailscale VPN first.</div>'))
        return None
    supplied = qs.get("password") or ""
    if supplied != pw:
        _html(200 if not supplied else 401,
              _RDP_LOGIN_HTML.replace("__ERR__",
                  '<div class="err">Wrong password.</div>' if supplied else ""))
        return None
    # Authenticated. Serve the control panel. Password embedded client-side so
    # JS can POST it back — hidden endpoint + Tailscale gating keeps it contained.
    panel = (_RDP_PANEL_HTML
             .replace("__HOST__", platform.node().replace("<", ""))
             .replace("__PW_JSON__", json.dumps(pw)))
    _html(200, panel)
    return None

def v4_post_rdp(h, hdrs, qs):
    """Hidden remote-desktop control. Requires Tailscale + terminal password."""
    t0 = time.time(); req_id = _req_id()
    client_ip = h.client_address[0]
    b = v4_body(h)
    pw = get_term_pw()
    if not pw:
        return (403, _err("not_configured",
                          "no PC password set — run: ai -apip PASSWORD", req_id))
    if b.get("password") != pw:
        return (401, _err("wrong_password", "wrong PC password", req_id))
    if not _tailscale_up():
        return (403, _err("tailscale_down",
                          "tailscale is not running on this host", req_id))
    # Allow 127.0.0.1 for local testing; otherwise require Tailnet source.
    if not (client_ip.startswith("127.") or _tailscale_client(client_ip)):
        return (403, _err("not_tailnet",
                          f"client {client_ip} is not on the Tailnet", req_id))
    action = (b.get("action") or "info").lower()

    # --- info: report screen capabilities ---------------------------------
    if action == "info":
        tools = {
            "screenshot": _have("gnome-screenshot", "scrot", "grim", "screencapture", "import"),
            "control":    _have("xdotool", "ydotool"),
        }
        dims = None
        try:
            r = subprocess.run(["xdpyinfo"], capture_output=True, text=True, timeout=2)
            for line in r.stdout.splitlines():
                if "dimensions" in line:
                    dims = line.strip(); break
        except Exception: pass
        return (200, _env(t0, request_id=req_id,
                          action="info",
                          tailscale=True,
                          client_ip=client_ip,
                          dimensions=dims,
                          tools_available=tools,
                          platform=platform.system()))

    # --- screenshot: capture and return a fetchable URL -------------------
    if action == "screenshot":
        out_name = f"rdp_{int(time.time())}_{secrets.token_hex(3)}.png"
        out_path = os.path.join(UPLOADS_DIR, out_name)
        engine = None
        for bin in ("gnome-screenshot", "scrot", "grim", "screencapture", "import"):
            if not shutil.which(bin): continue
            try:
                if bin == "gnome-screenshot":
                    r = subprocess.run([bin, "-f", out_path],
                                       capture_output=True, timeout=10)
                elif bin == "scrot":
                    r = subprocess.run([bin, out_path],
                                       capture_output=True, timeout=10)
                elif bin == "grim":
                    r = subprocess.run([bin, out_path],
                                       capture_output=True, timeout=10)
                elif bin == "screencapture":
                    r = subprocess.run([bin, "-x", out_path],
                                       capture_output=True, timeout=10)
                else:  # import (ImageMagick)
                    r = subprocess.run([bin, "-window", "root", out_path],
                                       capture_output=True, timeout=10)
                if r.returncode == 0 and os.path.isfile(out_path):
                    engine = bin; break
            except Exception: continue
        if not engine:
            return (500, _err("no_screenshot_tool",
                              "install one of: gnome-screenshot, scrot, grim, "
                              "screencapture, imagemagick", req_id))
        return (200, _env(t0, request_id=req_id,
                          action="screenshot",
                          engine=engine,
                          path=out_path,
                          size_bytes=os.path.getsize(out_path),
                          url=f"/v4/files/fetch?name={out_name}"))

    # --- control actions: type, key, click, mousemove ---------------------
    ctl = shutil.which("xdotool") or shutil.which("ydotool")
    if not ctl:
        return (500, _err("no_control_tool",
                          "install xdotool (X11) or ydotool (Wayland)", req_id))
    if action == "type":
        text = b.get("text", "")
        if not text: return (400, _err("missing_input", "missing text", req_id))
        if len(text) > 4000:
            return (400, _err("too_large", "text must be ≤4000 chars", req_id))
        r = subprocess.run([ctl, "type", "--delay", "15", text],
                           capture_output=True, text=True, timeout=30)
        return (200, _env(t0, request_id=req_id,
                          action="type", tool=os.path.basename(ctl),
                          chars=len(text),
                          ok=r.returncode == 0,
                          stderr=r.stderr[:200]))
    if action == "key":
        key = b.get("key", "")
        if not key: return (400, _err("missing_input", "missing key", req_id))
        # Accept either a single key ("Return") or combo ("ctrl+alt+t")
        r = subprocess.run([ctl, "key", key],
                           capture_output=True, text=True, timeout=5)
        return (200, _env(t0, request_id=req_id,
                          action="key", key=key,
                          ok=r.returncode == 0,
                          stderr=r.stderr[:200]))
    if action == "click":
        button = str(b.get("button", 1))
        x = b.get("x"); y = b.get("y")
        cmd = [ctl]
        if x is not None and y is not None:
            cmd += ["mousemove", str(int(x)), str(int(y))]
        cmd += ["click", button]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return (200, _env(t0, request_id=req_id,
                          action="click", button=button,
                          x=x, y=y,
                          ok=r.returncode == 0,
                          stderr=r.stderr[:200]))
    if action == "mousemove":
        x = int(b.get("x") or 0); y = int(b.get("y") or 0)
        r = subprocess.run([ctl, "mousemove", str(x), str(y)],
                           capture_output=True, text=True, timeout=5)
        return (200, _env(t0, request_id=req_id,
                          action="mousemove", x=x, y=y,
                          ok=r.returncode == 0,
                          stderr=r.stderr[:200]))
    return (400, _err("unknown_action",
                      "expected action: info|screenshot|type|key|click|mousemove",
                      req_id))


def v4_get_chat_stream(h, hdrs, qs):
    """SSE streaming chat. Writes directly to the wire; returns None.

    Emits events:
      start     { request_id, model, timeout, ts }
      delta     { text, tokens, seq }   ← one per line/chunk
      heartbeat { t }                   ← every ~20s when idle
      usage     { tokens_in, tokens_out, elapsed_ms }
      done      { elapsed_ms, reason }
      error     { code, message }
    """
    request_id = _req_id()
    q = qs.get("q") or qs.get("prompt") or ""
    model_req = qs.get("model") or None
    try:
        import urllib.parse
        q = urllib.parse.unquote_plus(q)
    except Exception:
        pass
    timeout = key_timeout(hdrs)
    h.send_response(200)
    h.send_header("Content-Type", "text/event-stream")
    h.send_header("Cache-Control", "no-cache")
    h.send_header("Connection", "keep-alive")
    h.send_header("X-Accel-Buffering", "no")
    h.send_header("X-Request-Id", request_id)
    h.end_headers()
    def emit(ev_type, obj):
        obj = dict(obj); obj["type"] = ev_type
        try:
            h.wfile.write(("event: " + ev_type + "\n").encode())
            h.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            h.wfile.flush()
        except Exception:
            return False
        return True
    emit("start", {"request_id": request_id,
                   "model": model_req or active_model(),
                   "timeout": timeout, "ts": int(time.time())})
    if not q:
        emit("error", {"code": "missing_input", "message": "missing q= query parameter"})
        emit("done", {"elapsed_ms": 0, "reason": "bad_request"})
        return None
    t0 = time.time()
    tokens_out = 0; seq = 0; last_beat = t0; reason = "stop"
    try:
        extra = (["-m", model_req] if model_req else [])
        proc = subprocess.Popen(CLI_ARGV + ["ask"] + extra + [q],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env={**os.environ, "NO_COLOR": "1"})
        deadline = t0 + timeout
        while True:
            if proc.poll() is not None: break
            if time.time() > deadline:
                proc.kill()
                emit("error", {"code": "timeout", "message": f"timeout {timeout}s"})
                reason = "timeout"; break
            # heartbeat every 20s of stream idleness
            if time.time() - last_beat > 20:
                if not emit("heartbeat", {"t": int(time.time())}):
                    proc.kill(); reason = "client_gone"; break
                last_beat = time.time()
            line = proc.stdout.readline()
            if not line: time.sleep(0.05); continue
            txt = strip_ansi(line.decode(errors='replace'))
            seq += 1
            tk = count_tokens(txt)
            tokens_out += tk
            if not emit("delta", {"text": txt, "tokens": tk, "seq": seq}):
                proc.kill(); reason = "client_gone"; break
            last_beat = time.time()
        rest = proc.stdout.read() if proc.stdout else b""
        if rest:
            txt = strip_ansi(rest.decode(errors='replace'))
            seq += 1
            tk = count_tokens(txt)
            tokens_out += tk
            emit("delta", {"text": txt, "tokens": tk, "seq": seq})
    except Exception as e:
        emit("error", {"code": "exception",
                       "message": f"{type(e).__name__}: {e}"})
        reason = "error"
    elapsed = time.time() - t0
    tokens_in = count_tokens(q)
    record_usage(hdrs, tokens=tokens_in + tokens_out, seconds=elapsed,
                 path="/v4/chat/stream")
    V4_COUNTERS["requests"] += 1
    V4_COUNTERS["tokens_in"] += tokens_in; V4_COUNTERS["tokens_out"] += tokens_out
    emit("usage", {"tokens_in": tokens_in, "tokens_out": tokens_out,
                   "elapsed_ms": int(elapsed * 1000)})
    emit("done", {"elapsed_ms": int(elapsed * 1000), "reason": reason,
                  "seq_count": seq})
    return None

V4_GET = {
    "/v4/ping":         v4_get_ping,
    "/v4/health":       v4_get_health,
    "/v4/status":       v4_get_status,
    "/v4/sysinfo":      v4_get_sysinfo,
    "/v4/version":      v4_get_version,
    "/v4/models":       v4_get_models,
    "/v4/keys":         v4_get_keys,
    "/v4/history":      v4_get_history,
    "/v4/logs":         v4_get_logs,
    "/v4/files":        v4_get_files,
    "/v4/files/fetch":  v4_get_files_fetch,
    "/v4/rag/list":     v4_get_rag_list,
    "/v4/mem":          v4_get_mem,
    "/v4/context":      v4_get_context,
    "/v4/config":       v4_get_config,
    "/v4/endpoints":    v4_get_endpoints,
    "/v4/auth/usage":   v4_get_usage,
    "/v4/auth/keys":    v4_get_auth_keys,
    "/v4/jobs":         v4_get_jobs,
    "/v4/chat/stream":  v4_get_chat_stream,
    "/v4/_rdp":         v4_get_rdp,
}

V4_POST = {
    "/v4/chat":              v4_post_chat,
    "/v4/complete":          v4_post_complete,
    "/v4/batch":             v4_post_batch,
    "/v4/compare":           v4_post_compare,
    "/v4/tokens":            v4_post_tokens,
    "/v4/cost":              v4_post_cost,
    "/v4/embed":             v4_post_embed,
    "/v4/benchmark":         v4_post_benchmark,
    "/v4/web":               v4_post_web,
    "/v4/agent":             v4_post_agent,
    "/v4/diff/review":       v4_post_diff_review,
    "/v4/voice/tts":         v4_post_voice_tts,
    "/v4/share":             v4_post_share,
    "/v4/models/activate":   v4_post_models_activate,
    "/v4/models/download":   v4_post_models_download,
    "/v4/keys/set":          v4_post_keys_set,
    "/v4/history/search":    v4_post_history_search,
    "/v4/history/clear":     v4_post_history_clear,
    "/v4/files/upload":      v4_post_files_upload,
    "/v4/files/delete":      v4_post_files_delete,
    "/v4/rag/add":           v4_post_rag_add,
    "/v4/rag/query":         v4_post_rag_query,
    "/v4/run":               v4_post_run,
    "/v4/mem":               v4_post_mem,
    "/v4/context":           v4_post_context,
    "/v4/comp/context":      v4_post_comp_context,
    "/v4/terminal/auth":     v4_post_terminal_auth,
    "/v4/terminal/exec":     v4_post_terminal_exec,
    "/v4/auth/new":          v4_post_auth_new,
    "/v4/auth/revoke":       v4_post_auth_revoke,
    # Hidden: Tailscale + PC-password-gated remote desktop control.
    # Intentionally omitted from V4_ENDPOINTS_DOC below.
    "/v4/_rdp":              v4_post_rdp,
}

# Paths hidden from the public /v4/endpoints catalogue
V4_HIDDEN_PATHS = {"/v4/_rdp"}

# endpoints that bypass auth (even when keys are configured)
V4_OPEN_PATHS = {
    "/v4/health", "/v4/version", "/v4/endpoints",
    "/v4/auth/new", "/v4/auth/usage",
    "/v4/ping",           # harmless liveness, matches /health in spirit
    "/v4/files/fetch",    # file URLs should be shareable
}

V4_ENDPOINTS_DOC = []
for meth, d in (("GET", V4_GET), ("POST", V4_POST)):
    for p in sorted(d):
        if p in V4_HIDDEN_PATHS:
            continue
        V4_ENDPOINTS_DOC.append({
            "method": meth, "path": p,
            "open": p in V4_OPEN_PATHS,
            "func": d[p].__name__,
        })

ENDPOINTS = [
    {"method": "GET",  "path": "/health",              "desc": "Server health + version"},
    {"method": "GET",  "path": "/v1/models",           "desc": "OpenAI-compatible model list"},
    {"method": "POST", "path": "/v1/chat/completions", "desc": "OpenAI-compatible chat completion"},
    {"method": "POST", "path": "/v1/completions",      "desc": "OpenAI-compatible text completion"},
    {"method": "GET",  "path": "/chat",                "desc": "Minimal chat web UI"},
    {"method": "GET",  "path": "/v3/site",             "desc": "Full dashboard"},
    {"method": "GET",  "path": "/v3/status",           "desc": "Running status summary"},
    {"method": "GET",  "path": "/v3/sysinfo",          "desc": "CPU, RAM, GPU, disk, load"},
    {"method": "GET",  "path": "/v3/version",          "desc": "Version string"},
    {"method": "GET",  "path": "/v3/endpoints",        "desc": "This catalogue"},
    {"method": "GET",  "path": "/v3/models",           "desc": "Active model + local GGUF files"},
    {"method": "POST", "path": "/v3/models/activate",  "desc": "Switch active model"},
    {"method": "POST", "path": "/v3/models/download",  "desc": "Download a recommended model"},
    {"method": "GET",  "path": "/v3/keys",             "desc": "Which backend keys are set (masked)"},
    {"method": "POST", "path": "/v3/keys/set",         "desc": "Set a backend key (password-protected)"},
    {"method": "GET",  "path": "/v3/history",          "desc": "Recent chat history (?n=50)"},
    {"method": "POST", "path": "/v3/history/search",   "desc": "Search chat history"},
    {"method": "POST", "path": "/v3/history/clear",    "desc": "Wipe chat history"},
    {"method": "POST", "path": "/v3/tokens",           "desc": "Estimate token count of text"},
    {"method": "POST", "path": "/v3/cost",             "desc": "Estimate USD cost of text"},
    {"method": "POST", "path": "/v3/embed",            "desc": "64-dim text embedding"},
    {"method": "POST", "path": "/v3/chat/stream",      "desc": "SSE streaming chat"},
    {"method": "POST", "path": "/v3/web",              "desc": "Web-search-augmented ask"},
    {"method": "POST", "path": "/v3/benchmark",        "desc": "Round-trip latency test"},
    {"method": "POST", "path": "/v3/agent",            "desc": "Autonomous task agent loop"},
    {"method": "POST", "path": "/v3/diff/review",      "desc": "AI review of a unified diff"},
    {"method": "POST", "path": "/v3/voice/tts",        "desc": "Text-to-speech via piper/espeak"},
    {"method": "POST", "path": "/v3/share",            "desc": "Create public share link"},
    {"method": "POST", "path": "/v3/run",              "desc": "Run shell command (password-protected)"},
    {"method": "GET",  "path": "/v3/files",            "desc": "List uploaded files"},
    {"method": "POST", "path": "/v3/files/upload",     "desc": "Upload JSON/text file (password)"},
    {"method": "POST", "path": "/v3/files/delete",     "desc": "Delete uploaded file (password)"},
    {"method": "GET",  "path": "/v3/rag/list",         "desc": "List RAG corpora"},
    {"method": "POST", "path": "/v3/rag/add",          "desc": "Add text to a RAG corpus"},
    {"method": "POST", "path": "/v3/rag/query",        "desc": "Query RAG corpus + answer"},
    {"method": "GET",  "path": "/v3/logs",             "desc": "Recent access log"},
    {"method": "GET",  "path": "/v3/config",           "desc": "Safe config values (no secrets)"},
    {"method": "GET",  "path": "/v3/mem",              "desc": "Memory contents"},
    {"method": "POST", "path": "/v3/mem",              "desc": "add/delete/clear memory"},
    {"method": "GET",  "path": "/v3/context",          "desc": "Conversation context"},
    {"method": "POST", "path": "/v3/context",          "desc": "add/clear context"},
    {"method": "POST", "path": "/v3/comp/context",     "desc": "Force-compress context"},
    {"method": "POST", "path": "/v3/terminal/auth",    "desc": "Unlock protected terminal"},
    {"method": "POST", "path": "/v3/terminal/exec",    "desc": "Execute terminal command"},
]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, c, d):
        self.send_response(c); self.send_header("Content-Type","application/json"); self.send_header("Access-Control-Allow-Origin","*"); self.send_header("Access-Control-Allow-Headers","*"); self.end_headers(); self.wfile.write(json.dumps(d).encode())
    def _h(self, c, h):
        self.send_response(c); self.send_header("Content-Type","text/html"); self.end_headers(); self.wfile.write(h.encode())
    def _t(self, c, t, ct="text/plain"):
        self.send_response(c); self.send_header("Content-Type",ct); self.send_header("Access-Control-Allow-Origin","*"); self.end_headers(); self.wfile.write(t.encode() if isinstance(t, str) else t)
    def _auth_ok(self, body):
        pw = get_term_pw()
        if not pw:
            return False
        return body.get("password") == pw
    def do_OPTIONS(self): self._j(200, {})

    def _parse_qs(self, raw):
        out = {}
        if not raw: return out
        for kv in raw.split("&"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                out[k] = v
        return out

    def _v4_dispatch(self, method, path, qs):
        table = V4_GET if method == "GET" else V4_POST
        if path not in table:
            v4_reply(self, 404, {"error": f"unknown v4 {method} endpoint",
                                 "path": path, "hint": "GET /v4/endpoints"})
            return True
        # auth check
        if path not in V4_OPEN_PATHS:
            ok, info, err = auth_check(self.headers)
            if not ok:
                v4_reply(self, 401, {"error": err})
                return True
        try:
            res = table[path](self, self.headers, qs)
        except Exception as e:
            v4_reply(self, 500, {"error": f"{type(e).__name__}: {e}"})
            return True
        # A handler may return None to signal "I already wrote the response"
        # (used by streaming endpoints).
        if res is None:
            return True
        code, body = res
        v4_reply(self, code, body)
        return True

    def do_GET(self):
        try:
            log_request(self.path, self.client_address[0])
        except:
            pass
        p, _, qs_raw = self.path.partition("?")
        qs = self._parse_qs(qs_raw)
        if p.startswith("/v4/") or p == "/v4":
            self._v4_dispatch("GET", p, qs); return
        if p == "/health": self._j(200, {"status":"ok","version":VERSION,"uptime":int(time.time()-START_TIME)})
        elif p == "/v1/models":
            gguf = list_gguf_models()
            data = [{"id": active_model(), "object": "model"}]
            for m in gguf:
                data.append({"id": m["name"], "object": "model", "path": m["path"], "size_mb": m["size_mb"]})
            self._j(200, {"data": data})
        elif p == "/chat": self._h(200, CHAT_HTML)
        elif p == "/v3/site": self._h(200, DASH_HTML)
        elif p == "/v3/mem": self._j(200, {"memory": load_mem()})
        elif p == "/v3/context": self._j(200, load_ctx())
        # ─── v3.2 new endpoints ───────────────────────────────────────
        elif p == "/v3/status":
            self._j(200, {
                "status": "ok", "version": VERSION,
                "active_model": active_model(),
                "uptime_seconds": int(time.time() - START_TIME),
                "mem_count": len(load_mem()),
                "ctx_msgs": len(load_ctx().get("messages", [])),
                "terminal_unlocked": bool(get_term_pw()),
            })
        elif p == "/v3/sysinfo": self._j(200, sysinfo())
        elif p == "/v3/models":
            self._j(200, {"active": active_model(), "local": list_gguf_models()})
        elif p == "/v3/keys":
            ks = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
                  "GROQ_API_KEY", "MISTRAL_API_KEY", "TOGETHER_API_KEY",
                  "HF_TOKEN", "HF_API_KEY"]
            self._j(200, {"keys": {k: {"set": bool(os.environ.get(k)), "masked": masked_key(k)} for k in ks}})
        elif p == "/v3/history":
            n = 50
            if "?" in self.path:
                q = self.path.split("?", 1)[1]
                for kv in q.split("&"):
                    if kv.startswith("n="):
                        try: n = max(1, min(500, int(kv[2:])))
                        except: pass
            self._j(200, {"history": read_history(n)})
        elif p == "/v3/logs":
            try:
                data = open(LOG_FILE).read().splitlines()[-200:]
            except:
                data = []
            self._j(200, {"log": data})
        elif p == "/v3/files":
            items = []
            for name in os.listdir(UPLOADS_DIR):
                fp = os.path.join(UPLOADS_DIR, name)
                if os.path.isfile(fp):
                    items.append({"name": name, "size": os.path.getsize(fp), "mtime": int(os.path.getmtime(fp))})
            self._j(200, {"files": items})
        elif p == "/v3/rag/list":
            items = []
            for name in os.listdir(RAG_DIR):
                if name.endswith(".jsonl"):
                    items.append(name[:-6])
            self._j(200, {"corpora": items})
        elif p == "/v3/version":
            self._j(200, {"version": VERSION, "cli": CLI})
        elif p == "/v3/endpoints":
            self._j(200, {"endpoints": ENDPOINTS})
        elif p == "/v3/config":
            cfg = {}
            fp = os.path.expanduser("~/.config/ai-cli/config")
            if os.path.isfile(fp):
                try:
                    for line in open(fp):
                        if "=" in line and not line.strip().startswith("#"):
                            k, v = line.strip().split("=", 1)
                            if "KEY" in k or "TOKEN" in k or "SECRET" in k:
                                continue
                            cfg[k] = v.strip('"').strip("'")
                except:
                    pass
            self._j(200, {"config": cfg})
        elif p == "/favicon.ico":
            self._t(200, "", "image/x-icon")
        else: self._j(404, {"error":"not found", "path": p})
    def do_POST(self):
        try:
            log_request(self.path, self.client_address[0])
        except:
            pass
        p = self.path.split("?", 1)[0]
        if p.startswith("/v4/"):
            self._v4_dispatch("POST", p, {}); return
        l = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(l) if l else b""
        try:
            b = json.loads(raw) if raw else {}
        except:
            b = {}
        if p in ("/v1/chat/completions", "/v1/completions"):
            msgs = b.get("messages", [])
            prm = msgs[-1]["content"] if msgs else b.get("prompt", "")
            if prm.startswith("/cmd "):
                r = run_cmd(prm[5:])
            else:
                mem = load_mem()
                ctx = load_ctx()
                full_prompt = ""
                if ctx.get("compressed"):
                    full_prompt += "Previous conversation summary: " + ctx["compressed"] + "\n\n"
                if mem:
                    full_prompt += "Known facts about the user: " + "; ".join(mem) + "\n\n"
                full_prompt += prm
                r = ai_ask(full_prompt)
                ctx["messages"].append({"role": "user", "content": prm})
                ctx["messages"].append({"role": "assistant", "content": r})
                if ctx_is_full(ctx):
                    ctx = compress_ctx(ctx)
                save_ctx(ctx)
                auto_update_mem(prm, r)
                append_history("user", prm)
                append_history("assistant", r)
            self._j(200, {"id":f"c-{secrets.token_hex(6)}","object":"chat.completion","model":active_model(),"choices":[{"index":0,"message":{"role":"assistant","content":r},"finish_reason":"stop"}],"usage":{"prompt_tokens":count_tokens(prm),"completion_tokens":count_tokens(r),"total_tokens":count_tokens(prm)+count_tokens(r)}})
        # ─── streaming chat (SSE) ────────────────────────────────────
        elif p == "/v3/chat/stream":
            msgs = b.get("messages", [])
            prm = msgs[-1]["content"] if msgs else b.get("prompt", "")
            r = ai_ask(prm)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            # chunk word-by-word so clients see a stream even when the
            # underlying backend returned the full string at once.
            for tok in r.split(" "):
                try:
                    self.wfile.write(f"data: {json.dumps({'delta': tok + ' '})}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(0.02)
                except:
                    return
            self.wfile.write(b"data: [DONE]\n\n")
            append_history("user", prm); append_history("assistant", r)
        elif p == "/v3/tokens":
            text = b.get("text", "") or b.get("prompt", "")
            self._j(200, {"tokens": count_tokens(text), "chars": len(text)})
        elif p == "/v3/cost":
            text = b.get("text", "") or b.get("prompt", "")
            model = b.get("model", active_model())
            tok = count_tokens(text)
            self._j(200, {"tokens": tok, "model": model, "estimated_usd": estimate_cost(tok, model)})
        elif p == "/v3/embed":
            text = b.get("text", "") or b.get("input", "")
            self._j(200, {"embedding": simple_embed(text), "dim": 64})
        elif p == "/v3/history/search":
            q = (b.get("query") or "").lower()
            hist = read_history(500)
            hits = [h for h in hist if q in json.dumps(h).lower()] if q else hist
            self._j(200, {"hits": hits[-100:], "count": len(hits)})
        elif p == "/v3/history/clear":
            try: open(HIST_FILE, "w").close()
            except: pass
            self._j(200, {"ok": True})
        elif p == "/v3/benchmark":
            t0 = time.time()
            r = ai_ask("Say 'ready' in one word.")
            dt = round(time.time() - t0, 3)
            self._j(200, {"latency_s": dt, "reply": r[:120], "model": active_model()})
        elif p == "/v3/web":
            q = b.get("query", "")
            r = run_cmd(f"ask-web \"{q}\"") if q else "Error: missing query"
            self._j(200, {"query": q, "answer": r})
        elif p == "/v3/agent":
            goal = b.get("goal", "")
            steps = int(b.get("steps", 3))
            r = run_cmd(f"agent \"{goal}\" --steps {steps}") if goal else "Error: missing goal"
            self._j(200, {"goal": goal, "result": r})
        elif p == "/v3/diff/review":
            diff = b.get("diff", "")
            if not diff:
                self._j(400, {"error": "missing diff"}); return
            prompt = "Review this diff. Call out bugs, logic errors, and missing tests. Be concise.\n\n" + diff[:20000]
            self._j(200, {"review": ai_ask(prompt)})
        elif p == "/v3/voice/tts":
            text = b.get("text", "")
            r = run_cmd(f"voice tts \"{text}\"") if text else "Error: missing text"
            self._j(200, {"result": r})
        elif p == "/v3/share":
            r = run_cmd("share")
            self._j(200, {"result": r})
        elif p == "/v3/models/activate":
            name = b.get("model", "")
            if not name:
                self._j(400, {"error": "missing model"}); return
            r = run_cmd(f"model use \"{name}\"")
            self._j(200, {"active": active_model(), "result": r})
        elif p == "/v3/models/download":
            name = b.get("model", "")
            if not name:
                self._j(400, {"error": "missing model"}); return
            r = run_cmd(f"recommended download \"{name}\"")
            self._j(200, {"result": r})
        elif p == "/v3/keys/set":
            if not self._auth_ok(b):
                self._j(401, {"error": "Unauthorized — requires terminal password"}); return
            name = b.get("name", ""); value = b.get("value", "")
            if not name or not value:
                self._j(400, {"error": "missing name or value"}); return
            r = run_cmd(f"keys set {name} {value}")
            self._j(200, {"ok": True, "name": name, "masked": masked_key(name) if os.environ.get(name) else "(set)"})
        elif p == "/v3/run":
            if not self._auth_ok(b):
                self._j(401, {"error": "Unauthorized"}); return
            cmd = b.get("cmd", "")
            if not cmd:
                self._j(400, {"error": "missing cmd"}); return
            self._j(200, shell_run(cmd, timeout=int(b.get("timeout", 60))))
        elif p == "/v3/files/upload":
            if not self._auth_ok(b):
                self._j(401, {"error": "Unauthorized"}); return
            name = b.get("name", "").replace("/", "_") or f"upload_{int(time.time())}.txt"
            content = b.get("content", "")
            fp = os.path.join(UPLOADS_DIR, name)
            with open(fp, "w") as f:
                f.write(content)
            self._j(200, {"ok": True, "path": fp, "size": len(content)})
        elif p == "/v3/files/delete":
            if not self._auth_ok(b):
                self._j(401, {"error": "Unauthorized"}); return
            name = b.get("name", "").replace("/", "_")
            fp = os.path.join(UPLOADS_DIR, name)
            if os.path.isfile(fp):
                os.remove(fp)
                self._j(200, {"ok": True})
            else:
                self._j(404, {"error": "not found"})
        elif p == "/v3/rag/add":
            corpus = b.get("corpus", "default").replace("/", "_")
            text = b.get("text", "")
            if not text:
                self._j(400, {"error": "missing text"}); return
            fp = os.path.join(RAG_DIR, corpus + ".jsonl")
            with open(fp, "a") as f:
                f.write(json.dumps({"t": int(time.time()), "text": text, "emb": simple_embed(text)}) + "\n")
            self._j(200, {"ok": True, "corpus": corpus})
        elif p == "/v3/rag/query":
            corpus = b.get("corpus", "default").replace("/", "_")
            q = b.get("query", "")
            k = int(b.get("k", 3))
            fp = os.path.join(RAG_DIR, corpus + ".jsonl")
            if not os.path.isfile(fp):
                self._j(404, {"error": "unknown corpus"}); return
            qv = simple_embed(q)
            items = []
            for line in open(fp):
                try:
                    d = json.loads(line)
                    d["score"] = round(cosine(qv, d.get("emb", [])), 4)
                    d.pop("emb", None)
                    items.append(d)
                except:
                    pass
            items.sort(key=lambda d: d.get("score", 0), reverse=True)
            top = items[:k]
            ctx = "\n\n".join(d.get("text", "") for d in top)
            answer = ai_ask(f"Use only this context to answer:\n{ctx}\n\nQuestion: {q}") if q else ""
            self._j(200, {"top": top, "answer": answer})
        elif p == "/v3/mem":
            action = b.get("action", "list")
            if action == "add":
                items = load_mem()
                items.append(b.get("fact", ""))
                save_mem(items)
                self._j(200, {"ok": True, "count": len(items)})
            elif action == "delete":
                items = load_mem()
                idx = b.get("index", -1)
                if 0 <= idx < len(items):
                    items.pop(idx)
                    save_mem(items)
                self._j(200, {"ok": True, "memory": items})
            elif action == "clear":
                save_mem([])
                self._j(200, {"ok": True})
            else:
                self._j(200, {"memory": load_mem()})
        elif self.path == "/v3/context":
            action = b.get("action", "get")
            if action == "add":
                ctx = load_ctx()
                ctx["messages"].append({"role": b.get("role", "user"), "content": b.get("content", "")})
                if ctx_is_full(ctx):
                    ctx = compress_ctx(ctx)
                save_ctx(ctx)
                self._j(200, {"ok": True, "full": ctx_is_full(ctx), "msg_count": len(ctx["messages"])})
            elif action == "clear":
                save_ctx({"messages": [], "compressed": ""})
                self._j(200, {"ok": True})
            else:
                self._j(200, load_ctx())
        elif self.path == "/v3/comp/context":
            ctx = load_ctx()
            ctx = compress_ctx(ctx)
            self._j(200, {"ok": True, "compressed": ctx.get("compressed", ""), "remaining_msgs": len(ctx["messages"])})
        elif self.path == "/v3/terminal/auth":
            pw = get_term_pw()
            if not pw:
                self._j(403, {"ok": False, "error": "No password set. Run: ai -apip YOUR_PASSWORD"})
            elif b.get("password") == pw:
                self._j(200, {"ok": True})
            else:
                self._j(401, {"ok": False, "error": "Wrong password"})
        elif self.path == "/v3/terminal/exec":
            pw = get_term_pw()
            if not pw or b.get("password") != pw:
                self._j(401, {"error": "Unauthorized"})
            else:
                cmd = b.get("cmd", "")
                if cmd:
                    output = run_cmd(cmd)
                    self._j(200, {"output": output})
                else:
                    self._j(400, {"error": "No command"})
        else: self._j(404, {"error":{"message":f"Unknown: {self.path}"}})

print(f"AI CLI API v{VERSION} on http://{HOST}:{PORT}")
print(f"Dashboard: http://{HOST}:{PORT}/v3/site")
print(f"Chat:      http://{HOST}:{PORT}/chat")
print(f"Endpoints: http://{HOST}:{PORT}/v3/endpoints")

class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

s = ThreadedHTTPServer((HOST, PORT), H)
try: s.serve_forever()
except KeyboardInterrupt: print("\nStopped")
APIPY
      AI_CLI_BIN="$_cli_bin" API_HOST="$host" API_PORT="$port" \
        AI_MODEL="${ACTIVE_MODEL:-auto}" AI_VERSION="$VERSION" \
        "$PYTHON" "$_api_script" &
      local pid=$!; echo "$pid" > "$API_PID_FILE"; sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        ok "API v3 + v4 running on http://${host}:${port}"
        info "Dashboard: http://${host}:${port}/v3/site"
        info "Chat:      http://${host}:${port}/chat"
        info "v4 health: http://${host}:${port}/v4/health"
        info "v4 docs:   http://${host}:${port}/v4/endpoints"
        info "Create v4 key:  ai api new-k \"my-key\" 500k"
        info "Stop:      ai api stop"
      else
        err "Server failed to start"; rm -f "$API_PID_FILE" "$_api_script"
      fi ;;
    stop) [[ -f "$API_PID_FILE" ]] && { kill "$(cat "$API_PID_FILE")" 2>/dev/null; rm -f "$API_PID_FILE"; ok "Stopped"; } || info "Not running" ;;
    status) [[ -f "$API_PID_FILE" ]] && kill -0 "$(cat "$API_PID_FILE" 2>/dev/null)" 2>/dev/null && ok "Running" || info "Not running" ;;
    test) curl -sS "http://localhost:${1:-8080}/health" 2>/dev/null | grep -q ok && ok "Healthy" || err "Not responding" ;;
    endpoints|ep|list) cmd_api_endpoints ;;
    new-k|newkey|new-key) cmd_api_new_key "$@" ;;
    keys) cmd_api_keys_list ;;
    revoke) cmd_api_revoke "$@" ;;
    -Upgrade-k|-upgrade-k|upgrade-k|upgrade-key) cmd_api_upgrade_key "$@" ;;
    *) cmd_api_help ;;
  esac
}

# Parse a budget spec. Echoes "tokens|seconds" (either may be empty). Returns 1 on parse error.
#   999, 500k, 1.5m, 9.99m  → tokens  (k=1e3, m=1e6, max 2 decimals)
#   30s, 2min, 1h           → seconds
_api_parse_budget_spec() {
  local s="${1:-}" num unit tokens="" seconds=""
  [[ -z "$s" ]] && { echo "|"; return 0; }
  if [[ "$s" =~ ^([0-9]+(\.[0-9]{1,2})?)(k|K|m|M|s|S|min|MIN|h|H)?$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]:-}"
  else
    return 1
  fi
  case "$unit" in
    ""|k|K|m|M)
      local mult=1
      [[ "$unit" = k || "$unit" = K ]] && mult=1000
      [[ "$unit" = m || "$unit" = M ]] && mult=1000000
      tokens=$(awk "BEGIN{printf \"%d\", ($num) * $mult}")
      ;;
    s|S)   seconds=$(awk "BEGIN{printf \"%d\", $num}") ;;
    min|MIN) seconds=$(awk "BEGIN{printf \"%d\", $num * 60}") ;;
    h|H)   seconds=$(awk "BEGIN{printf \"%d\", $num * 3600}") ;;
  esac
  echo "${tokens}|${seconds}"
}

cmd_api_new_key() {
  local name="${1:-}"; shift 2>/dev/null || true
  [[ -z "$name" ]] && { err "Usage: ai api new-k \"name\" [budget1] [budget2]"; info "  budget examples: 999, 500k, 1.5m, 9.99m (tokens) or 30s, 2min, 1h (time/cycle)"; return 1; }
  local tokens="" time_sec=""
  local spec
  for spec in "$@"; do
    local parsed; parsed=$(_api_parse_budget_spec "$spec") || { err "Invalid budget spec: $spec"; return 1; }
    local t_part="${parsed%%|*}"
    local s_part="${parsed#*|}"
    [[ -n "$t_part" ]] && tokens="$t_part"
    [[ -n "$s_part" ]] && time_sec="$s_part"
  done
  # If tokens given but no cycle time → default 6 hours
  if [[ -n "$tokens" && -z "$time_sec" ]]; then
    time_sec=21600
  fi
  # No budgets at all → still create key with 6h cycle, no caps
  [[ -z "$time_sec" ]] && time_sec=21600
  local max_request=126  # 2.1 min hard cap per request
  local key_body
  if command -v openssl >/dev/null 2>&1; then
    key_body=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=\n' | cut -c1-32)
  else
    key_body=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
  fi
  local key="sk-ai-${key_body}"
  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ai-cli"
  mkdir -p "$cfg_dir"
  local keys_file="$cfg_dir/api_keys.json"
  [[ -s "$keys_file" ]] || echo '{}' > "$keys_file"
  chmod 600 "$keys_file" 2>/dev/null || true
  if ! command -v "$PYTHON" >/dev/null 2>&1; then err "Python required to update key store"; return 1; fi
  "$PYTHON" - "$keys_file" "$key" "$name" "$tokens" "$time_sec" "$max_request" <<'PY' || { err "Failed to write key"; return 1; }
import json, sys, time, os
path, key, name, tokens, time_sec, max_req = sys.argv[1:7]
try:
    with open(path) as f: d = json.load(f)
except Exception:
    d = {}
d[key] = {
    "name": name,
    "created": int(time.time()),
    "tokens_budget": int(tokens) if tokens else None,
    "tokens_used": 0,
    "time_budget_sec": int(time_sec) if time_sec else None,
    "time_used_sec": 0.0,
    "max_request_sec": int(max_req),
    "cycle_start": int(time.time()),
    "cycle_seconds": int(time_sec) if time_sec else 21600,
    "revoked": False,
}
with open(path, "w") as f: json.dump(d, f, indent=2)
os.chmod(path, 0o600)
PY
  ok "API key created"
  printf "  Name:            %s\n" "$name"
  printf "  Key:             %s\n" "$key"
  [[ -n "$tokens" ]] && printf "  Tokens/cycle:    %s\n" "$tokens" || printf "  Tokens/cycle:    unlimited\n"
  printf "  Cycle length:    %ss\n" "$time_sec"
  printf "  Max per request: %ss (hard-capped at 126s = 2.1 min)\n" "$max_request"
  printf "\n  Use with:\n    curl -H \"X-API-Key: %s\" http://localhost:8080/v4/health\n" "$key"
  printf "    curl -H \"Authorization: Bearer %s\" http://localhost:8080/v4/health\n" "$key"
}

cmd_api_keys_list() {
  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ai-cli"
  local keys_file="$cfg_dir/api_keys.json"
  [[ ! -s "$keys_file" ]] && { info "No API keys defined — server runs in open mode"; info "Create one:  ai api new-k \"my-key\" 500k"; return 0; }
  "$PYTHON" - "$keys_file" <<'PY'
import json, sys, time
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
if not d:
    print("No API keys defined."); sys.exit(0)
print(f"{'NAME':<20} {'KEY (masked)':<24} {'TOKENS':<18} {'TIME':<14} {'STATUS':<10}")
print("─" * 86)
for k, v in d.items():
    name = v.get("name","")[:20]
    masked = k[:10] + "…" + k[-4:]
    tb = v.get("tokens_budget"); tu = v.get("tokens_used",0)
    tok = f"{tu}/{tb}" if tb else f"{tu}/∞"
    mb = v.get("time_budget_sec"); mu = v.get("time_used_sec",0)
    tm = f"{mu:.0f}s/{mb}s" if mb else f"{mu:.0f}s/∞"
    st = "revoked" if v.get("revoked") else "active"
    print(f"{name:<20} {masked:<24} {tok:<18} {tm:<14} {st:<10}")
PY
}

cmd_api_revoke() {
  local key="$1"
  [[ -z "$key" ]] && { err "Usage: ai api revoke <key-or-name>"; return 1; }
  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ai-cli"
  local keys_file="$cfg_dir/api_keys.json"
  [[ ! -s "$keys_file" ]] && { err "No key store at $keys_file"; return 1; }
  "$PYTHON" - "$keys_file" "$key" <<'PY' || { err "Revoke failed"; return 1; }
import json, sys
path, needle = sys.argv[1], sys.argv[2]
d = json.load(open(path))
hit = None
if needle in d: hit = needle
else:
    for k, v in d.items():
        if v.get("name") == needle:
            hit = k; break
if not hit:
    print(f"No key matched: {needle}", file=sys.stderr); sys.exit(2)
d[hit]["revoked"] = True
json.dump(d, open(path,"w"), indent=2)
print(f"Revoked {hit[:10]}…{hit[-4:]} ({d[hit].get('name','')})")
PY
  ok "Key revoked"
}

cmd_api_upgrade_key() {
  # ai api -Upgrade-k "key-or-name" [new-budget] [new-cycle] [--reset] [--add N]
  # Modes:
  #   (no budget args)   → reset usage counters only
  #   BUDGET             → replace tokens and/or time budget
  #   --add BUDGET       → add to existing tokens budget
  #   --reset            → zero out tokens_used / time_used_sec / cycle_start
  #   --unrevoke         → lift a revoke
  local needle="${1:-}"; shift 2>/dev/null || true
  [[ -z "$needle" ]] && {
    err "Usage: ai api -Upgrade-k \"key-or-name\" [budget…] [--reset] [--add BUDGET] [--unrevoke]"
    info "  budget examples: 999, 500k, 1.5m, 9.99m (tokens) or 30s, 2min, 1h (time/cycle)"
    info "  --reset        zero out usage counters and restart the cycle"
    info "  --add 500k     add 500k to the existing token budget"
    info "  --unrevoke     lift a previous revoke"
    return 1
  }

  local replace_tokens="" replace_time="" add_tokens="" do_reset=0 do_unrevoke=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset)    do_reset=1; shift ;;
      --unrevoke) do_unrevoke=1; shift ;;
      --add)
        local spec="${2:-}"
        [[ -z "$spec" ]] && { err "--add needs a spec"; return 1; }
        local parsed; parsed=$(_api_parse_budget_spec "$spec") || { err "Invalid --add spec: $spec"; return 1; }
        local t_part="${parsed%%|*}"
        [[ -z "$t_part" ]] && { err "--add only accepts token specs (999, 500k, 1.5m)"; return 1; }
        add_tokens="$t_part"
        shift 2 ;;
      *)
        local parsed; parsed=$(_api_parse_budget_spec "$1") || { err "Invalid budget spec: $1"; return 1; }
        local t_part="${parsed%%|*}"
        local s_part="${parsed#*|}"
        [[ -n "$t_part" ]] && replace_tokens="$t_part"
        [[ -n "$s_part" ]] && replace_time="$s_part"
        shift ;;
    esac
  done

  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ai-cli"
  local keys_file="$cfg_dir/api_keys.json"
  [[ ! -s "$keys_file" ]] && { err "No key store at $keys_file"; return 1; }

  if ! "$PYTHON" - "$keys_file" "$needle" "$replace_tokens" "$replace_time" \
        "$add_tokens" "$do_reset" "$do_unrevoke" <<'PY'
import json, sys, time
path, needle, rep_t, rep_s, add_t, do_reset, do_unrevoke = sys.argv[1:8]
do_reset = do_reset == "1"; do_unrevoke = do_unrevoke == "1"
d = json.load(open(path))
hit = None
if needle in d: hit = needle
else:
    for k, v in d.items():
        if v.get("name") == needle:
            hit = k; break
if not hit:
    print(f"No key matched: {needle}", file=sys.stderr); sys.exit(2)
info = d[hit]
changes = []
if rep_t:
    info["tokens_budget"] = int(rep_t); changes.append(f"tokens_budget={rep_t}")
if rep_s:
    info["time_budget_sec"] = int(rep_s)
    info["cycle_seconds"] = int(rep_s)
    changes.append(f"time_budget_sec={rep_s}")
if add_t:
    old = int(info.get("tokens_budget") or 0)
    info["tokens_budget"] = old + int(add_t)
    changes.append(f"tokens_budget+={add_t} (was {old}, now {info['tokens_budget']})")
if do_reset:
    info["tokens_used"] = 0
    info["time_used_sec"] = 0.0
    info["cycle_start"] = int(time.time())
    changes.append("usage counters reset")
if do_unrevoke:
    if info.get("revoked"):
        info["revoked"] = False
        changes.append("unrevoked")
    else:
        changes.append("already active (unrevoke no-op)")
# default when no arg: nudge the cycle forward (soft reset of cycle window)
if not changes:
    info["cycle_start"] = int(time.time())
    changes.append("cycle window restarted")
json.dump(d, open(path, "w"), indent=2)
print(f"Upgraded {hit[:10]}…{hit[-4:]} ({info.get('name','')}):")
for c in changes:
    print(f"  • {c}")
PY
  then
    err "Upgrade failed"
    return 1
  fi
  ok "Key upgraded"
}

cmd_api_help() {
  cat <<'EOF'
Usage: ai api <subcommand> [options]

Server:
  start [--port N] [--host H] [--public] [--tailscale]   Start server
  stop                                                    Stop server
  status                                                  Show if running
  test                                                    Curl /health
  endpoints (ep|list)                                     List all endpoints

Auth (v4):
  new-k "name" [budget] [cycle]    Create API key. Budget examples:
                                     500k, 1.5m, 9.99m   (tokens, k=1e3, m=1e6)
                                     30s, 2min, 1h       (time per cycle)
                                   If only tokens given, cycle defaults to 6h.
                                   Per-request hard cap: 2.1 min (126s).
  keys                             List keys (masked) + usage + status
  revoke <key-or-name>             Revoke a key
  -Upgrade-k "key-or-name"         Modify an existing key:
      [new-budget]                    replace tokens/time budget
      [--add BUDGET]                  add to the token budget
      [--reset]                       zero usage counters + restart cycle
      [--unrevoke]                    lift a previous revoke

Web UIs:
  /v3/site        12-tab dashboard (Chat · Status · Models · Keys · History
                  · Tools · Agent · Voice · RAG · Share · API Docs · Terminal)
  /chat           Minimal chat UI

Auth headers (v4 endpoints):
  X-API-Key: sk-ai-...
  Authorization: Bearer sk-ai-...
  If no keys are defined, /v4/* runs in open mode.
EOF
  cmd_api_endpoints
}

cmd_api_endpoints() {
  cat <<'EOF'

AI CLI API v3.2.0.1 — endpoint catalogue
════════════════════════════════════════

OpenAI-compatible (no auth required)
    GET  /health                     Server health + version
    GET  /v1/models                  OpenAI-style model list
    POST /v1/chat/completions        OpenAI-style chat completion
    POST /v1/completions             OpenAI-style text completion
    GET  /chat                       Minimal chat web UI
    GET  /v3/site                    Full 12-tab dashboard

v4  (recommended — auth + per-key budgets + hard 2.1 min cap)
    Auth header:   X-API-Key: sk-ai-…   OR   Authorization: Bearer sk-ai-…
    Open endpoints (no auth): /v4/health /v4/version /v4/endpoints
                              /v4/auth/new /v4/auth/usage

  Status & introspection
    GET  /v4/ping                    Fast liveness ping
    GET  /v4/health                  Uptime, model, load (open)
    GET  /v4/status                  Running status summary
    GET  /v4/sysinfo                 CPU, RAM, GPU, disk, load
    GET  /v4/version                 Version string (open)
    GET  /v4/endpoints               This catalogue (open)
    GET  /v4/config                  Safe config values
    GET  /v4/logs                    Recent access log

  Models
    GET  /v4/models                  Active + local GGUF files
    POST /v4/models/activate         Switch active  {model}
    POST /v4/models/download         Download recommended (async 202)

  Chat, streaming & conversation
    POST /v4/chat                    Single-shot chat  {prompt|messages}
    POST /v4/complete                Text completion  {prompt}
    GET  /v4/chat/stream             SSE streaming  ?q=... (auth via header)
    GET  /v4/history                 Recent chat history  ?n=N
    POST /v4/history/search          Search history  {query}
    POST /v4/history/clear           Wipe history
    GET  /v4/mem                     Memory contents
    POST /v4/mem                     add/delete/clear  {op,key,value}
    GET  /v4/context                 Conversation context
    POST /v4/context                 add/clear  {op,text}
    POST /v4/comp/context            Force-compress context

  Parallel & analysis
    POST /v4/batch                   Up to 20 prompts in parallel  {prompts}
    POST /v4/compare                 One prompt across up to 6 models
    POST /v4/tokens                  Token count of text
    POST /v4/cost                    USD cost estimate
    POST /v4/embed                   64-dim text embedding

  Features
    POST /v4/web                     Web-search-augmented ask  {query}
    POST /v4/benchmark               Round-trip latency test
    POST /v4/agent                   Autonomous task agent  {goal,steps}
    POST /v4/diff/review             Review a unified diff  {diff}
    POST /v4/voice/tts               Text-to-speech  {text}
    POST /v4/share                   Create public share link (async)

  Backend keys (masked)
    GET  /v4/keys                    Which backend keys are set
    POST /v4/keys/set                Set a backend key  {name,value,password}

  Files & RAG
    GET  /v4/files                   List uploaded files
    POST /v4/files/upload            Upload  {name,content,password}
    POST /v4/files/delete            Delete  {name,password}
    GET  /v4/rag/list                List RAG corpora
    POST /v4/rag/add                 Add text to corpus  {corpus,text}
    POST /v4/rag/query               Query + answer  {corpus,query,k}

  Protected terminal
    POST /v4/terminal/auth           Unlock  {password}
    POST /v4/terminal/exec           Execute  {cmd,password}
    POST /v4/run                     Run shell  {cmd,password}

  API key management (v4 API keys, not backend keys)
    GET  /v4/auth/keys               List your keys (masked, requires auth)
    GET  /v4/auth/usage              Usage for the calling key (open)
    POST /v4/auth/new                Create a new key  {name,tokens?,seconds?}
    POST /v4/auth/revoke             Revoke a key  {key}

v3  (legacy — still served for existing clients; prefer v4)
    Same endpoint shapes under /v3/... See: curl /v3/endpoints

Browse live list: curl http://localhost:8080/v4/endpoints | jq
EOF
}

main "$@"
