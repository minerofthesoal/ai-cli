# ============================================================================
# MODULE: 00-env.sh
# Platform / Python / CUDA detection
# Source lines 1-149 of main-v2.7.3
# ============================================================================

VERSION="2.7.3"

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
      # Check if running inside WSL
      if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl"
      else echo "linux"; fi ;;
    *)                    echo "unknown" ;;
  esac
}
PLATFORM="$(detect_platform)"
IS_WINDOWS=0; IS_WSL=0; IS_MACOS=0
[[ "$PLATFORM" == "windows" ]] && IS_WINDOWS=1
[[ "$PLATFORM" == "wsl"     ]] && IS_WSL=1
[[ "$PLATFORM" == "macos"   ]] && IS_MACOS=1

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
  for b in llama-cli llama llama-run llama-main llama.cpp; do
    command -v "$b" &>/dev/null && { command -v "$b"; return 0; }
  done
  for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/llama.cpp/build/bin" \
            "$HOME/llama.cpp/build" "$HOME/llama.cpp" "/usr/local/bin" \
            "/opt/llama.cpp/bin" "/opt/homebrew/bin"; do
    for b in llama-cli llama llama-run main; do
      [[ -x "$d/$b" ]] && { echo "$d/$b"; return 0; }
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

