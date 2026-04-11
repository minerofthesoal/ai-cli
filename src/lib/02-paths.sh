# ============================================================================
# MODULE: 02-paths.sh
# Directory paths + mkdir + source config
# Source lines 162-212 of main-v2.7.3
# ============================================================================

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
CANVAS_V2_DIR="$AI_OUTPUT_DIR/canvas_v2"                  # v2.5:   Canvas v2 workspaces
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
         "$MULTIMODAL_DIR" "$CANVAS_V2_DIR" "$BUILD_DIR" "$PROJECTS_DIR" \
         "$EXTENSIONS_DIR" "$FIREFOX_EXT_DIR"
touch "$KEYS_FILE" && chmod 600 "$KEYS_FILE"
touch "$ALIASES_FILE" 2>/dev/null || true

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
