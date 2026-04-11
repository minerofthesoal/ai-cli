# ============================================================================
# MODULE: 03-config.sh
# Runtime config defaults + save_config + log_history
# Source lines 212-396 of main-v2.7.3
# ============================================================================

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

