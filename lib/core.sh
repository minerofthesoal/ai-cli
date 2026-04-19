#!/usr/bin/env bash
# AI CLI v3.1.0 — Core module
# Sourced by main.sh — provides colors, logging, config, platform detection

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R="\033[0m"; B="\033[1m"; DIM="\033[2m"; IT="\033[3m"; UL="\033[4m"
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"
  MAGENTA="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"; GRAY="\033[90m"
  BRED="\033[91m"; BGREEN="\033[92m"; BYELLOW="\033[93m"; BBLUE="\033[94m"
  BMAGENTA="\033[95m"; BCYAN="\033[96m"; BWHITE="\033[97m"
else
  R="" B="" DIM="" IT="" UL=""
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" WHITE="" GRAY=""
  BRED="" BGREEN="" BYELLOW="" BBLUE="" BMAGENTA="" BCYAN="" BWHITE=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────
hdr()  { echo -e "\n${B}${BWHITE}$*${R}"; }
ok()   { echo -e "${BGREEN}✓${R} $*"; }
info() { echo -e "${BCYAN}ℹ${R} $*"; }
warn() { echo -e "${BYELLOW}⚠${R} $*"; }
err()  { echo -e "${BRED}✗${R} $*" >&2; }
dim()  { echo -e "${DIM}  $*${R}"; }

# ── Platform Detection ────────────────────────────────────────────────────────
detect_platform() {
  local os; os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin) echo "macos" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
      elif [[ -f /dev/location ]] || [[ "$(uname -r 2>/dev/null)" == *ish* ]]; then echo "ish"
      else echo "linux"; fi ;;
    *) echo "unknown" ;;
  esac
}

PLATFORM="$(detect_platform)"
IS_WINDOWS=0; IS_WSL=0; IS_MACOS=0; IS_ISH=0
[[ "$PLATFORM" == "windows" ]] && IS_WINDOWS=1
[[ "$PLATFORM" == "wsl"     ]] && IS_WSL=1
[[ "$PLATFORM" == "macos"   ]] && IS_MACOS=1
[[ "$PLATFORM" == "ish"     ]] && IS_ISH=1

# ── Python / llama.cpp Discovery ──────────────────────────────────────────────
find_python() {
  for c in python3.12 python3.11 python3.10 python3 python; do
    local p; p=$(command -v "$c" 2>/dev/null) || continue
    local v; v=$("$p" -c "import sys; print(sys.version_info.major,sys.version_info.minor)" 2>/dev/null) || continue
    read -r ma mi <<< "$v"
    (( ma==3 && mi>=10 )) && { echo "$p"; return 0; }
  done
  echo ""
}

find_llama() {
  for b in llama-cli llama llama-run llama-main; do
    command -v "$b" &>/dev/null && { command -v "$b"; return 0; }
  done
  for d in "$HOME/.local/bin" "$HOME/llama.cpp/build/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
    for b in llama-cli llama llama-run main; do
      [[ -x "$d/$b" ]] && { echo "$d/$b"; return 0; }
    done
  done
  local py; py=$(find_python)
  [[ -n "$py" ]] && "$py" -c "import llama_cpp" 2>/dev/null && { echo "llama_cpp_python"; return 0; }
  echo ""
}

# ── CUDA Detection ────────────────────────────────────────────────────────────
_CUDA_CACHE="$HOME/.ai/cache/cuda_arch"

detect_cuda_arch() {
  if command -v nvidia-smi &>/dev/null; then
    local cap
    cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' \n')
    [[ -n "$cap" && "$cap" != "N/A" ]] && { echo "$cap" | tr -d '.'; return 0; }
    cap=$(nvidia-smi -q 2>/dev/null | awk '/CUDA Capability/{gsub(/[^0-9.]/,"",$NF); print $NF; exit}' | tr -d '.')
    [[ -n "$cap" && "$cap" != "0" ]] && { echo "$cap"; return 0; }
  fi
  if [[ -d /proc/driver/nvidia/gpus ]] || ls /dev/nvidia[0-9]* &>/dev/null 2>&1; then
    echo "61"; return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal" && { echo "metal"; return 0; }
  fi
  echo "0"
}

detect_cuda_arch_cached() {
  local _now; _now=$(date +%s)
  local _stale=0
  [[ ! -f "$_CUDA_CACHE" ]] && _stale=1
  if [[ -f "$_CUDA_CACHE" ]]; then
    local _age=$(( _now - $(stat -c %Y "$_CUDA_CACHE" 2>/dev/null || stat -f %m "$_CUDA_CACHE" 2>/dev/null || echo 0) ))
    (( _age > 86400 )) && _stale=1
    [[ "$(cat "$_CUDA_CACHE" 2>/dev/null)" == "0" ]] && (( _age > 300 )) && _stale=1
  fi
  if [[ $_stale -eq 1 ]]; then
    mkdir -p "$(dirname "$_CUDA_CACHE")"
    detect_cuda_arch > "$_CUDA_CACHE" 2>/dev/null || echo "0" > "$_CUDA_CACHE"
  fi
  cat "$_CUDA_CACHE"
}

PYTHON="$(find_python)"
LLAMA_BIN="$(find_llama)"
CUDA_ARCH="$(detect_cuda_arch_cached)"

# ── Paths & Config ────────────────────────────────────────────────────────────
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
PLUGINS_DIR="$CONFIG_DIR/plugins"
TEMPLATES_DIR="$CONFIG_DIR/prompt_templates"
SNAPSHOTS_DIR="$CONFIG_DIR/snapshots"
RAG_DIR="$CONFIG_DIR/rag"
BATCH_DIR="$CONFIG_DIR/batch_queue"
EXPORTS_DIR="$AI_OUTPUT_DIR/exports"
BRANCHES_DIR="$CONFIG_DIR/chat_branches"
PRESETS_DIR="$CONFIG_DIR/presets"
COMPARE_DIR="$CONFIG_DIR/compare_results"
HEALTH_LOG="$CONFIG_DIR/health.log"
PERF_LOG="$CONFIG_DIR/perf_benchmarks.log"
ANALYTICS_FILE="$CONFIG_DIR/analytics.jsonl"
MEMORY_FILE="$CONFIG_DIR/memory.jsonl"
FAVORITES_FILE="$CONFIG_DIR/favorites.jsonl"
TASKS_FILE="$CONFIG_DIR/tasks.jsonl"
NOTEBOOKS_DIR="$AI_OUTPUT_DIR/notebooks"
SCHEDULE_DIR="$CONFIG_DIR/schedules"
PROFILES_DIR="$CONFIG_DIR/profiles"

mkdir -p "$CONFIG_DIR" "$MODELS_DIR" "$SESSIONS_DIR" "$PERSONAS_DIR" \
         "$AI_OUTPUT_DIR" "$CANVAS_DIR" "$FINETUNE_DIR" "$PLUGINS_DIR" \
         "$TEMPLATES_DIR" "$SNAPSHOTS_DIR" "$RAG_DIR" "$BATCH_DIR" \
         "$EXPORTS_DIR" "$BRANCHES_DIR" "$PRESETS_DIR" "$COMPARE_DIR" \
         "$NOTEBOOKS_DIR" "$SCHEDULE_DIR" "$PROFILES_DIR"
touch "$KEYS_FILE" 2>/dev/null && chmod 600 "$KEYS_FILE" 2>/dev/null || true
touch "$MEMORY_FILE" "$FAVORITES_FILE" "$TASKS_FILE" "$ANALYTICS_FILE" 2>/dev/null || true

# ── Load Config ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -f "$KEYS_FILE"   ]] && source "$KEYS_FILE"

# ── Runtime Defaults ──────────────────────────────────────────────────────────
ACTIVE_MODEL="${ACTIVE_MODEL:-}"
ACTIVE_BACKEND="${ACTIVE_BACKEND:-}"
ACTIVE_PERSONA="${ACTIVE_PERSONA:-default}"
ACTIVE_SESSION="${ACTIVE_SESSION:-default}"
MAX_TOKENS="${MAX_TOKENS:-2048}"
TEMPERATURE="${TEMPERATURE:-0.7}"
TOP_P="${TOP_P:-0.9}"
CONTEXT_SIZE="${CONTEXT_SIZE:-4096}"
GPU_LAYERS="${GPU_LAYERS:--1}"
THREADS="${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
STREAM="${STREAM:-1}"
VERBOSE="${VERBOSE:-0}"
RETRY_MAX="${RETRY_MAX:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"
RAG_TOP_K="${RAG_TOP_K:-5}"
EXPORT_FORMAT="${EXPORT_FORMAT:-json}"
CUSTOM_SYSTEM_PROMPT="${CUSTOM_SYSTEM_PROMPT:-}"

# ── CPU-only Mode ─────────────────────────────────────────────────────────────
CPU_ONLY_MODE="${CPU_ONLY_MODE:-0}"
[[ $IS_WINDOWS -eq 1 || $IS_ISH -eq 1 ]] && CPU_ONLY_MODE=1
if [[ "${CUDA_ARCH:-0}" == "0" ]]; then
  if command -v nvidia-smi &>/dev/null || [[ -d /proc/driver/nvidia/gpus ]]; then
    rm -f "$_CUDA_CACHE" 2>/dev/null
    CUDA_ARCH="$(detect_cuda_arch)"
    echo "$CUDA_ARCH" > "$_CUDA_CACHE" 2>/dev/null || true
  fi
fi
[[ "${CUDA_ARCH:-0}" == "0" ]] && CPU_ONLY_MODE=1
[[ "${CUDA_ARCH:-0}" != "0" && "${GPU_LAYERS:-0}" == "0" ]] && GPU_LAYERS=-1

# ── Save Config ───────────────────────────────────────────────────────────────
save_config() {
  cat > "$CONFIG_FILE" <<CONF
ACTIVE_MODEL="$ACTIVE_MODEL"
ACTIVE_BACKEND="$ACTIVE_BACKEND"
ACTIVE_PERSONA="$ACTIVE_PERSONA"
ACTIVE_SESSION="$ACTIVE_SESSION"
MAX_TOKENS="$MAX_TOKENS"
TEMPERATURE="$TEMPERATURE"
TOP_P="$TOP_P"
CONTEXT_SIZE="$CONTEXT_SIZE"
GPU_LAYERS="$GPU_LAYERS"
THREADS="$THREADS"
STREAM="$STREAM"
VERBOSE="$VERBOSE"
CPU_ONLY_MODE="$CPU_ONLY_MODE"
CUSTOM_SYSTEM_PROMPT="$CUSTOM_SYSTEM_PROMPT"
RETRY_MAX="$RETRY_MAX"
RAG_TOP_K="$RAG_TOP_K"
EXPORT_FORMAT="$EXPORT_FORMAT"
CONF
}

log_history() { echo "$(date -Iseconds) [$1] $2" >> "$LOG_FILE" 2>/dev/null || true; }
