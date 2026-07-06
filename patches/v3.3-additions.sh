#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
# AI CLI v3.3 Additions
# Sourced automatically by main.sh
# ════════════════════════════════════════════════════════════════════════════════

# ── LM Studio / Ollama / External Model Directory Detection ──────────────────
detect_lmstudio_dir() {
  local _lms_paths=(
    "$HOME/.lmstudio/models"
    "$HOME/.cache/lm-studio/models"
    "$HOME/Library/Application Support/LM Studio/models"
    "/opt/lmstudio/models"
  )
  for p in "${_lms_paths[@]}"; do
    [[ -d "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
}
detect_ollama() {
  if command -v ollama &>/dev/null; then
    echo "binary"
    return 0
  fi
  if curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo "api"
    return 0
  fi
  echo ""
}
detect_gpt4all_dir() {
  local _g4a_paths=(
    "$HOME/.local/share/nomic.ai/GPT4All"
    "$HOME/.config/nomic.ai/GPT4All"
    "$HOME/Library/Application Support/nomic.ai/GPT4All"
  )
  for p in "${_g4a_paths[@]}"; do
    [[ -d "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
}
detect_textgen_dir() {
  local _tg_paths=(
    "$HOME/text-generation-webui/models"
    "$HOME/oobabooga_linux/models"
  )
  for p in "${_tg_paths[@]}"; do
    [[ -d "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
}

# Auto-detect and use LM Studio models folder if available
_LMSTUDIO_DIR="$(detect_lmstudio_dir)"
_OLLAMA_STATUS="$(detect_ollama)"
_GPT4ALL_DIR="$(detect_gpt4all_dir)"
_TEXTGEN_DIR="$(detect_textgen_dir)"

# ════════════════════════════════════════════════════════════════════════════════
# v3.3 NEW FEATURES
# ════════════════════════════════════════════════════════════════════════════════

# ── v3.3: Setup Wizard ───────────────────────────────────────────────────────
cmd_setup() {
  local W="${B}${BWHITE}" C1="${B}${BCYAN}" C2="${BCYAN}" DM="${DIM}" R_="${R}"
  echo -e ""
  echo -e "${W}╔══════════════════════════════════════════════════════════════════════╗${R_}"
  echo -e "${W}║  AI CLI Setup Wizard  v${VERSION}                                        ║${R_}"
  echo -e "${W}╚══════════════════════════════════════════════════════════════════════╝${R_}"
  echo ""

  # Step 1: GPU Detection
  echo -e "${C1}Step 1: Hardware Detection${R_}"
  echo "─────────────────────────"
  local _has_gpu=0
  if command -v nvidia-smi &>/dev/null; then
    echo -e "  ${BGREEN}NVIDIA GPU detected${R_}"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | while IFS=, read -r name mem; do
      echo "    $name (${mem})"
    done
    _has_gpu=1
  elif [[ "$PLATFORM" == "macos" ]]; then
    echo -e "  ${BGREEN}macOS detected${R_} (Metal GPU may be available)"
    _has_gpu=1
  elif [[ -d /dev/dri ]]; then
    echo -e "  ${BYELLOW}Intel/AMD GPU detected${R_} (ROCm/Vulkan may work)"
    _has_gpu=1
  else
    echo -e "  ${BYELLOW}No GPU detected${R_} — CPU-only mode"
  fi
  echo ""

  # Step 2: Model Directory
  echo -e "${C1}Step 2: Model Storage${R_}"
  echo "────────────────────"
  echo "  Current: $MODELS_DIR"
  if [[ -n "$_LMSTUDIO_DIR" ]]; then
    echo -e "  ${BGREEN}LM Studio found:${R_} $_LMSTUDIO_DIR"
    echo -n "  Use LM Studio folder? [Y/n]: "
    read -r _ans
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then
      MODELS_DIR="$_LMSTUDIO_DIR"
      export AI_CLI_MODELS="$MODELS_DIR"
      save_config
      echo -e "  ${BGREEN}Updated to LM Studio folder${R_}"
    fi
  else
    echo "  No LM Studio installation found"
    echo -n "  Enter model directory (Enter=keep current): "
    read -r _mdir
    [[ -n "$_mdir" ]] && { MODELS_DIR="$_mdir"; export AI_CLI_MODELS="$MODELS_DIR"; save_config; echo "  Updated."; }
  fi
  mkdir -p "$MODELS_DIR"
  echo ""

  # Step 3: External Tools
  if [[ -n "$_OLLAMA_STATUS" ]]; then
    echo -e "${C1}Step 3: External Tools${R_}"
    echo "─────────────────────"
    echo -e "  ${BGREEN}Ollama detected${R_} ($_OLLAMA_STATUS)"
    echo -n "  Import Ollama models? [y/N]: "
    read -r _ans
    [[ "$_ans" =~ ^[Yy]$ ]] && cmd_import_models --ollama 2>/dev/null || true
    echo ""
  fi

  # Step 4: API Keys
  echo -e "${C1}Step 4: API Keys${R_} (Enter=skip)"
  echo "───────────────"
  local _key_names=("OPENAI_API_KEY" "ANTHROPIC_API_KEY" "GEMINI_API_KEY" "GROQ_API_KEY" "MISTRAL_API_KEY" "TOGETHER_API_KEY")
  local _key_labels=("OpenAI" "Claude (Anthropic)" "Google Gemini" "Groq" "Mistral" "Together")
  for i in "${!_key_names[@]}"; do
    local _kname="${_key_names[$i]}"
    local _klabel="${_key_labels[$i]}"
    local _current="${!_kname:-}"
    if [[ -n "$_current" ]]; then
      echo -e "  ${_klabel}: ${BGREEN}✓ set${R_}"
    else
      echo -n "  ${_klabel}: "
      read -r _val
      if [[ -n "$_val" ]]; then
        eval "$_kname=\"$_val\""
        echo "export $_kname=\"$_val\"" >> "$KEYS_FILE"
        echo -e "  ${BGREEN}Saved${R_}"
      fi
    fi
  done
  echo ""

  # Step 5: Default Model
  echo -e "${C1}Step 5: Default Model${R_}"
  echo "────────────────────"
  echo "  Options:"
  echo "    1) Small local model (Qwen 0.5B - fast, any hardware)"
  echo "    2) Medium local model (Qwen 7B - balanced)"
  echo "    3) Large local model (Llama 70B - powerful)"
  echo "    4) Cloud API (OpenAI GPT-4o)"
  echo "    5) Cloud API (Claude Sonnet)"
  echo "    6) Skip - set later"
  echo -n "  Choose [1-6]: "
  read -r _mchoice
  case "$_mchoice" in
    1) ACTIVE_MODEL="bartowski/Qwen2.5-0.5B-Instruct-GGUF"; ACTIVE_BACKEND="gguf"; save_config; echo "  Set: Qwen 0.5B" ;;
    2) ACTIVE_MODEL="bartowski/Qwen2.5-7B-Instruct-GGUF"; ACTIVE_BACKEND="gguf"; save_config; echo "  Set: Qwen 7B" ;;
    3) ACTIVE_MODEL="bartowski/Llama-3.3-70B-Instruct-GGUF"; ACTIVE_BACKEND="gguf"; save_config; echo "  Set: Llama 70B" ;;
    4) ACTIVE_MODEL="gpt-4o"; ACTIVE_BACKEND="openai"; save_config; echo "  Set: GPT-4o" ;;
    5) ACTIVE_MODEL="claude-sonnet-4-5"; ACTIVE_BACKEND="claude"; save_config; echo "  Set: Claude Sonnet" ;;
    *) echo "  Skipped. Run 'ai recommended' later to browse models." ;;
  esac
  echo ""

  # Step 6: Shell Completions
  echo -e "${C1}Step 6: Shell Completions${R_}"
  echo "────────────────────────"
  local _shell="$(basename "$SHELL")"
  echo "  Detected shell: $_shell"
  echo -n "  Generate completions? [Y/n]: "
  read -r _ans
  if [[ ! "$_ans" =~ ^[Nn]$ ]]; then
    case "$_shell" in
      bash) cmd_completion bash 2>/dev/null && echo "  Run: ai completion bash >> ~/.bashrc" ;;
      zsh)  cmd_completion zsh 2>/dev/null  && echo "  Run: ai completion zsh >> ~/.zshrc" ;;
      fish) cmd_completion fish 2>/dev/null && echo "  Run: ai completion fish > ~/.config/fish/completions/ai.fish" ;;
      *) echo "  Unsupported shell. Try: ai completion bash|zsh|fish" ;;
    esac
  fi
  echo ""

  # Step 7: Download starter model
  echo -e "${C1}Step 7: Starter Model${R_}"
  echo "────────────────────"
  echo -n "  Download a small starter model (~500MB)? [y/N]: "
  read -r _ans
  if [[ "$_ans" =~ ^[Yy]$ ]]; then
    echo "  Downloading Qwen2.5-0.5B..."
    cmd_download_model "bartowski/Qwen2.5-0.5B-Instruct-GGUF" 2>/dev/null || warn "Download failed. Run 'ai recommended' later."
  fi
  echo ""

  echo -e "${W}╔══════════════════════════════════════════════════════════════════════╗${R_}"
  echo -e "${W}║  Setup complete!  Quick commands:                                    ║${R_}"
  echo -e "${W}║    ai ask \"Hello!\"   ai status   ai recommended   ai --help        ║${R_}"
  echo -e "${W}╚══════════════════════════════════════════════════════════════════════╝${R_}"
  touch "$FIRST_RUN_FILE"
}

# ── v3.3: Shell Completions ──────────────────────────────────────────────────
cmd_completion() {
  local shell="${1:-bash}"
  case "$shell" in
    bash)
      cat << 'COMPEOF'
# AI CLI bash completions
_ai_complete() {
  local cur prev words cword
  _init_completion || return
  local cmds="ask a chat code review explain summarize translate pipe
    ask-web ask-think ask-think-web model models download recommended
    search-models use model-create model-state import-models
    multiai agent websearch audio video vision imagine imagine2
    voice tts stt share diff-review rag-quick canvas snapshot
    perf compare batch template notebook plan learn quiz
    shell json sql docker regex diff patch git schedule
    replay fav favorite profile watch context chain tokens
    cost analytics security sysinfo interview text net date
    cron math units clipboard gui gui+ node
    config keys session persona system alias
    profile completion setup status health
    api rlhf ttm mtm Mtm dataset extension
    plugin test change -aup -Su -L -h -gui -gui+ -C -Cf"
  local config_keys="model api_key api_host api_port api_cors
    temperature max_tokens context_size gpu_layers threads
    system_prompt gui_theme cpu_only_mode agent_max_steps
    multiai_rounds rclick_keybind"
  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
  elif [[ "$prev" == "model" || "$prev" == "use" || "$prev" == "fav" ]]; then
    local models=$(ai models 2>/dev/null | grep -oE '[^/]+-GGUF|gpt-[^ ]*|claude-[^ ]*|gemini-[^ ]*' | head -20)
    COMPREPLY=($(compgen -W "$models" -- "$cur"))
  elif [[ "$prev" == "config" ]]; then
    COMPREPLY=($(compgen -W "$config_keys" -- "$cur"))
  elif [[ "$prev" == "session" || "$prev" == "persona" ]]; then
    COMPREPLY=($(compgen -W "list new load set delete" -- "$cur"))
  elif [[ "$prev" == "help" || "$prev" == "-h" || "$prev" == "--help" ]]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
  else
    COMPREPLY=($(compgen -f -- "$cur"))
  fi
}
complete -F _ai_complete ai
COMPEOF
      ;;
    zsh)
      cat << 'COMPEOF'
#compdef ai
_ai_complete() {
  local -a cmds=(
    "ask:Ask the AI" "a:Short for ask" "chat:Interactive chat"
    "code:Generate code" "review:Code review" "explain:Explain"
    "summarize:Summarize" "translate:Translate" "pipe:Pipe stdin"
    "ask-web:Web search ask" "ask-think:Reasoning ask"
    "ask-think-web:Think + web" "model:Set model" "models:List models"
    "download:Download model" "recommended:Curated models"
    "search-models:Search HF" "use:Quick model switch"
    "import-models:Import external" "multiai:Multi-AI chat"
    "agent:Autonomous agent" "websearch:Web search"
    "audio:Audio tools" "video:Video tools"
    "vision:Vision tools" "imagine:Generate image"
    "voice:Voice tools" "share:Public tunnel"
    "diff-review:Review git diff" "rag-quick:Quick RAG"
    "canvas:Workspace" "snapshot:Save config"
    "perf:Benchmark" "compare:Compare models"
    "batch:Batch process" "gui:TUI" "gui+:GUI+"
    "node:Node editor" "config:Configuration"
    "keys:API keys" "session:Sessions"
    "persona:Personas" "system:System prompts"
    "alias:Aliases" "profile:Config profiles"
    "completion:Shell completions" "setup:Setup wizard"
    "status:System status" "health:Diagnostics"
    "api:API server" "rlhf:RLHF training"
    "dataset:Datasets" "extension:Extensions"
    "plugin:Plugins" "test:Tests"
    "change:Changelog" "-aup:Auto-update"
    "-Su:System update" "-L:Latest changes"
    "-h:Help" "-gui:Launch TUI"
  )
  _describe 'command' cmds
}
compdef _ai_complete ai
COMPEOF
      ;;
    fish)
      cat << 'COMPEOF'
# AI CLI fish completions
complete -c ai -f
complete -c ai -n '__fish_use_subcommand' -a 'ask a chat code review explain summarize translate pipe ask-web ask-think ask-think-web model models download recommended search-models use import-models multiai agent websearch audio video vision imagine voice share diff-review rag-quick canvas snapshot perf compare batch gui gui+ node config keys session persona system alias profile completion setup status health api rlhf dataset extension plugin test change'
complete -c ai -n '__fish_seen_subcommand_from ask a chat' -a '('
complete -c ai -n '__fish_seen_subcommand_from help -h' -a 'ask chat model status gui agent config'
complete -c ai -n '__fish_seen_subcommand_from config' -a 'model api_key temperature max_tokens context_size gpu_layers threads system_prompt gui_theme cpu_only_mode agent_max_steps'
complete -c ai -n '__fish_seen_subcommand_from model use' -a '(ai models 2>/dev/null | string match -r "[^ ]+$" | head -20)'
complete -c ai -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
COMPEOF
      ;;
    *)
      err "Unknown shell: $shell. Supported: bash, zsh, fish"
      return 1
      ;;
  esac
}

# ── v3.3: Model Import from External Tools ───────────────────────────────────
cmd_import_models() {
  local _mode="auto" _lm_path="" _do_link=0 _dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lmstudio) _lm_path="$2"; shift 2 ;;
      --ollama) _mode="ollama"; shift ;;
      --gpt4all) _mode="gpt4all"; shift ;;
      --textgen) _mode="textgen"; shift ;;
      --link) _do_link=1; shift ;;
      --dry-run) _dry=1; shift ;;
      *) shift ;;
    esac
  done

  hdr "Model Import"
  local _imported=0

  # LM Studio
  if [[ "$_mode" == "auto" || "$_mode" == "lmstudio" ]]; then
    local _lms="${_lm_path:-$(detect_lmstudio_dir)}"
    if [[ -n "$_lms" ]]; then
      echo "LM Studio: $_lms"
      local _lms_models=()
      while IFS= read -r -d '' f; do
        _lms_models+=("$f")
      done < <(find "$_lms" -maxdepth 3 -name "*.gguf" -print0 2>/dev/null)
      if [[ ${#_lms_models[@]} -gt 0 ]]; then
        echo "  Found ${#_lms_models[@]} GGUF model(s)"
        for m in "${_lms_models[@]}"; do
          local _basename; _basename=$(basename "$m")
          local _linkname; _linkname=$(echo "$_basename" | sed 's/[^a-zA-Z0-9._-]/_/g')
          local _dest="$MODELS_DIR/$_linkname"
          if [[ $_dry -eq 1 ]]; then
            echo "  [dry-run] Would link: $m → $_dest"
          elif [[ $_do_link -eq 1 ]]; then
            ln -sf "$m" "$_dest" 2>/dev/null && { echo "  ✓ Linked: $_basename"; ((_imported++)); }
          else
            echo "  Found: $_basename"
          fi
        done
      else
        echo "  No GGUF models found"
      fi
    else
      echo "LM Studio: not detected"
    fi
  fi

  # Ollama
  if [[ "$_mode" == "auto" || "$_mode" == "ollama" ]]; then
    local _oll; _oll=$(detect_ollama)
    if [[ -n "$_oll" ]]; then
      echo ""
      echo "Ollama: detected ($_oll)"
      local _models=""
      if [[ "$_oll" == "binary" ]]; then
        _models=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$')
      else
        _models=$(curl -s http://localhost:11434/api/tags 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('\\n'.join(m['name'] for m in d.get('models',[])))" 2>/dev/null)
      fi
      if [[ -n "$_models" ]]; then
        echo "  Available models:"
        echo "$_models" | while IFS= read -r m; do
          echo "    • $m (use: ai use ollama://$m)"
        done
      fi
    else
      echo "Ollama: not detected"
    fi
  fi

  # GPT4All
  if [[ "$_mode" == "auto" || "$_mode" == "gpt4all" ]]; then
    local _g4a; _g4a=$(detect_gpt4all_dir)
    if [[ -n "$_g4a" ]]; then
      echo ""
      echo "GPT4All: $_g4a"
      local _g4a_count; _g4a_count=$(find "$_g4a" -maxdepth 2 -name "*.gguf" -o -name "*.bin" 2>/dev/null | wc -l)
      echo "  Found $_g4a_count model file(s)"
    fi
  fi

  echo ""
  if [[ $_imported -gt 0 ]]; then
    ok "Imported $_imported model(s) into $MODELS_DIR"
  fi
  echo "  Run 'ai models' to see all available models"
  echo "  Run 'ai use <name>' to activate a model"
}

# ── v3.3: Config Profiles ────────────────────────────────────────────────────
cmd_profile() {
  local subcmd="${1:-list}"; shift || true
  case "$subcmd" in
    save)
      local name="${1:-}"
      [[ -z "$name" ]] && { err "Usage: ai profile save NAME"; return 1; }
      local pfile="$CONFIG_DIR/profiles/${name}.env"
      mkdir -p "$CONFIG_DIR/profiles"
      cat > "$pfile" <<PROF
# AI CLI Profile: $name
# Saved: $(date)
ACTIVE_MODEL="${ACTIVE_MODEL}"
ACTIVE_BACKEND="${ACTIVE_BACKEND}"
TEMPERATURE="${TEMPERATURE}"
MAX_TOKENS="${MAX_TOKENS}"
CONTEXT_SIZE="${CONTEXT_SIZE}"
GPU_LAYERS="${GPU_LAYERS}"
THREADS="${THREADS}"
CPU_ONLY_MODE="${CPU_ONLY_MODE}"
CUSTOM_SYSTEM_PROMPT="${CUSTOM_SYSTEM_PROMPT}"
PROF
      ok "Profile '$name' saved"
      ;;
    load)
      local name="${1:-}"
      [[ -z "$name" ]] && { err "Usage: ai profile load NAME"; return 1; }
      local pfile="$CONFIG_DIR/profiles/${name}.env"
      [[ ! -f "$pfile" ]] && { err "Profile '$name' not found. Run: ai profile list"; return 1; }
      source "$pfile"
      save_config
      ok "Profile '$name' loaded"
      info "Model: ${ACTIVE_MODEL:-none} | Backend: ${ACTIVE_BACKEND:-none}"
      ;;
    list)
      local pdir="$CONFIG_DIR/profiles"
      if [[ ! -d "$pdir" ]] || [[ -z "$(ls -A "$pdir" 2>/dev/null)" ]]; then
        info "No profiles saved. Run: ai profile save NAME"
        return 0
      fi
      echo ""
      echo -e "  ${B}${BCYAN}Saved Profiles:${R}"
      for f in "$pdir"/*.env; do
        local pname; pname=$(basename "$f" .env)
        local _m; _m=$(grep "^ACTIVE_MODEL=" "$f" 2>/dev/null | cut -d'"' -f2)
        echo -e "    ${BGREEN}•${R} $pname  ${DIM}($_m)${R}"
      done
      echo ""
      ;;
    delete|del)
      local name="${1:-}"
      local pfile="$CONFIG_DIR/profiles/${name}.env"
      [[ -f "$pfile" ]] && { rm "$pfile"; ok "Deleted profile '$name'"; } || err "Profile not found"
      ;;
    reset)
      echo -n "Reset to factory defaults? [y/N]: "
      read -r _ans
      if [[ "$_ans" =~ ^[Yy]$ ]]; then
        ACTIVE_MODEL=""; ACTIVE_BACKEND=""; TEMPERATURE="0.7"; MAX_TOKENS="2048"
        CONTEXT_SIZE="4096"; GPU_LAYERS="-1"; THREADS="$(nproc 2>/dev/null || echo 4)"
        CPU_ONLY_MODE="0"; CUSTOM_SYSTEM_PROMPT=""
        save_config
        ok "Reset to defaults"
      fi
      ;;
    *)
      err "Usage: ai profile save|load|list|delete|reset"
      ;;
  esac
}

# ── v3.3: Model Favorites ────────────────────────────────────────────────────
cmd_model_fav() {
  local subcmd="${1:-list}"; shift || true
  local fav_file="$CONFIG_DIR/model_favorites.txt"
  touch "$fav_file"
  case "$subcmd" in
    list|"")
      if [[ ! -s "$fav_file" ]]; then
        info "No favorite models. Add: ai model fav <model-name>"
        return 0
      fi
      echo ""
      echo -e "  ${B}${BCYAN}Favorite Models:${R}"
      local i=1
      while IFS= read -r line; do
        echo -e "    ${BGREEN}$i)${R} $line"
        ((i++))
      done < "$fav_file"
      echo ""
      ;;
    add|*)
      local name="${subcmd:-$1}"
      [[ "$subcmd" == "add" ]] && name="${1:-}"
      [[ -z "$name" ]] && { err "Usage: ai model fav <model-name>"; return 1; }
      if grep -qx "$name" "$fav_file" 2>/dev/null; then
        info "'$name' already in favorites"
      else
        echo "$name" >> "$fav_file"
        ok "Added '$name' to favorites"
      fi
      ;;
    del|delete|remove)
      local name="${1:-}"
      [[ -z "$name" ]] && { err "Usage: ai model fav del NAME"; return 1; }
      if grep -qx "$name" "$fav_file" 2>/dev/null; then
        grep -vx "$name" "$fav_file" > "$fav_file.tmp" && mv "$fav_file.tmp" "$fav_file"
        ok "Removed '$name' from favorites"
      else
        warn "'$name' not in favorites"
      fi
      ;;
  esac
}

# ── v3.3: Model Tags ─────────────────────────────────────────────────────────
cmd_model_tags() {
  local subcmd="${1:-list}"; shift || true
  local tags_file="$CONFIG_DIR/model_tags.json"
  [[ ! -f "$tags_file" ]] && echo "{}" > "$tags_file"
  case "$subcmd" in
    list|"")
      echo ""
      echo -e "  ${B}${BCYAN}Model Tags:${R}"
      "$PYTHON" -c "
import json,sys
d=json.load(open('$tags_file'))
if not d: print('  No tags yet. Use: ai model tag <model> <tag1,tag2>'); sys.exit()
for m,tags in d.items(): print(f'  {m}: {\", \".join(tags)}')
" 2>/dev/null
      echo ""
      ;;
    tag|add)
      local model="${1:-}" tags="${2:-}"
      [[ -z "$model" || -z "$tags" ]] && { err "Usage: ai model tag <model> <tag1,tag2>"; return 1; }
      "$PYTHON" -c "
import json
d=json.load(open('$tags_file'))
d['$model'] = list(set(d.get('$model',[]) + '$tags'.split(',')))
json.dump(d,open('$tags_file','w'),indent=2)
" 2>/dev/null
      ok "Tagged '$model' with: $tags"
      ;;
    untag|remove)
      local model="${1:-}" tag="${2:-}"
      [[ -z "$model" ]] && { err "Usage: ai model untag <model> [tag]"; return 1; }
      "$PYTHON" -c "
import json
d=json.load(open('$tags_file'))
if '$tag' and '$model' in d:
    d['$model'] = [t for t in d.get('$model',[]) if t != '$tag']
elif '$model' in d:
    del d['$model']
json.dump(d,open('$tags_file','w'),indent=2)
" 2>/dev/null
      ok "Removed tag from '$model'"
      ;;
    search)
      local tag="${1:-}"
      [[ -z "$tag" ]] && { err "Usage: ai model tags search <tag>"; return 1; }
      echo ""
      echo -e "  ${B}${BCYAN}Models tagged '$tag':${R}"
      "$PYTHON" -c "
import json
d=json.load(open('$tags_file'))
for m,tags in d.items():
    if '$tag' in tags: print(f'  - {m}')
" 2>/dev/null
      echo ""
      ;;
  esac
}

# ── v3.3: Model Info ─────────────────────────────────────────────────────────
cmd_model_info() {
  echo ""
  echo -e "  ${B}${BWHITE}Model Information${R}"
  echo "  ════════════════════════════════════════"
  echo "  Active Model:     ${ACTIVE_MODEL:-(none)}"
  echo "  Active Backend:   ${ACTIVE_BACKEND:-(auto)}"
  echo "  Models Directory: $MODELS_DIR"
  echo "  GGUF Files:       $(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l)"
  if [[ -n "$_LMSTUDIO_DIR" ]]; then
    echo -e "  LM Studio:        ${BGREEN}detected${R} at $_LMSTUDIO_DIR"
    echo "  LM Studio GGUFs:  $(find "$_LMSTUDIO_DIR" -maxdepth 3 -name '*.gguf' 2>/dev/null | wc -l)"
  else
    echo "  LM Studio:        not detected"
  fi
  if [[ -n "$_OLLAMA_STATUS" ]]; then
    echo -e "  Ollama:           ${BGREEN}detected${R} ($_OLLAMA_STATUS)"
  else
    echo "  Ollama:           not detected"
  fi
  echo "  Temperature:      $TEMPERATURE"
  echo "  Max Tokens:       $MAX_TOKENS"
  echo "  Context Size:     $CONTEXT_SIZE"
  echo "  GPU Layers:       $GPU_LAYERS"
  echo "  Threads:          $THREADS"
  echo "  CPU-Only Mode:    $([[ $CPU_ONLY_MODE -eq 1 ]] && echo yes || echo no)"
  echo ""
}

# ── v3.3: Use (Quick Model Switch) ───────────────────────────────────────────
cmd_use() {
  local target="${1:-}"
  [[ -z "$target" ]] && { err "Usage: ai use <model>"; return 1; }

  # Handle ollama:// prefix
  if [[ "$target" == ollama://* ]]; then
    local _oname="${target#ollama://}"
    ACTIVE_MODEL="ollama://$_oname"
    ACTIVE_BACKEND="ollama"
    save_config
    ok "Switched to Ollama model: $_oname"
    return 0
  fi

  # Handle lmstudio:// prefix
  if [[ "$target" == lmstudio://* ]]; then
    local _lname="${target#lmstudio://}"
    ACTIVE_MODEL="lmstudio://$_lname"
    ACTIVE_BACKEND="lmstudio"
    save_config
    ok "Switched to LM Studio model: $_lname"
    return 0
  fi

  # Handle numbered model from recommended list
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    local _idx=$((target))
    local _model_line="${RECOMMENDED_MODELS[$_idx]}"
    if [[ -n "$_model_line" ]]; then
      local _mname; _mname=$(echo "$_model_line" | cut -d'|' -f1)
      ACTIVE_MODEL="$_mname"
      ACTIVE_BACKEND="$(echo "$_model_line" | cut -d'|' -f2)"
      save_config
      ok "Switched to model #$_idx: $_mname"
      return 0
    fi
  fi

  # Try to match by name
  local _matched=""
  for _entry in "${RECOMMENDED_MODELS[@]}"; do
    local _mname; _mname=$(echo "$_entry" | cut -d'|' -f1)
    if [[ "$_mname" == *"$target"* ]]; then
      _matched="$_mname"
      ACTIVE_BACKEND="$(echo "$_entry" | cut -d'|' -f2)"
      break
    fi
  done

  if [[ -n "$_matched" ]]; then
    ACTIVE_MODEL="$_matched"
    save_config
    ok "Switched to: $_matched"
  else
    # Fallback: set directly
    ACTIVE_MODEL="$target"
    save_config
    ok "Switched to: $target"
  fi
}

# ── v3.3: Enhanced Status ────────────────────────────────────────────────────
cmd_status_v33() {
  echo ""
  echo -e "  ${B}${BWHITE}AI CLI Status${R}  v${VERSION}"
  echo "  ════════════════════════════════════════"
  echo "  Platform:         $PLATFORM"
  echo "  Python:           ${PYTHON:-not found}"
  echo "  CPU Threads:      $THREADS"
  echo "  GPU Architecture: ${CUDA_ARCH:-0}"
  echo "  CPU-Only Mode:    $([[ $CPU_ONLY_MODE -eq 1 ]] && echo yes || echo no)"
  echo "  Config Dir:       $CONFIG_DIR"
  echo "  Models Dir:       $MODELS_DIR"
  echo "  Active Model:     ${ACTIVE_MODEL:-(none)}"
  echo "  Active Backend:   ${ACTIVE_BACKEND:-(auto)}"
  echo "  GPU Layers:       $GPU_LAYERS"
  echo "  Context Size:     $CONTEXT_SIZE"
  echo "  Temperature:      $TEMPERATURE"
  echo "  Max Tokens:       $MAX_TOKENS"
  echo ""
  echo -e "  ${B}${BCYAN}External Integrations:${R}"
  if [[ -n "$_LMSTUDIO_DIR" ]]; then
    local _lcount; _lcount=$(find "$_LMSTUDIO_DIR" -maxdepth 3 -name '*.gguf' 2>/dev/null | wc -l)
    echo -e "    ${BGREEN}LM Studio${R}      $_LMSTUDIO_DIR ($_lcount models)"
  else
    echo -e "    ${DM}LM Studio      not detected${R}"
  fi
  if [[ -n "$_OLLAMA_STATUS" ]]; then
    echo -e "    ${BGREEN}Ollama${R}         detected ($_OLLAMA_STATUS)"
  else
    echo -e "    ${DM}Ollama         not detected${R}"
  fi
  if [[ -n "$_GPT4ALL_DIR" ]]; then
    echo -e "    ${BGREEN}GPT4All${R}        $_GPT4ALL_DIR"
  else
    echo -e "    ${DM}GPT4All        not detected${R}"
  fi
  echo ""
}

# ── v3.3: Conversation Export ────────────────────────────────────────────────
cmd_export_chat() {
  local format="${1:-md}" session="${2:-$ACTIVE_SESSION}"
  local src="$SESSIONS_DIR/${session}.jsonl"
  [[ ! -f "$src" ]] && { err "No session '$session' found"; return 1; }
  echo ""
  case "$format" in
    md|markdown)
      echo "# AI CLI Conversation: $session"
      echo ""
      echo "*Exported: $(date)*"
      echo "*Model: ${ACTIVE_MODEL:-unknown}*"
      echo ""
      while IFS= read -r line; do
        local role; role=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('role','user'))" 2>/dev/null || echo "user")
        local content; content=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null || echo "")
        if [[ "$role" == "user" ]]; then
          echo "## User"
          echo ""
          echo "$content"
          echo ""
        elif [[ "$role" == "assistant" ]]; then
          echo "## Assistant"
          echo ""
          echo '```'
          echo "$content"
          echo '```'
          echo ""
        fi
      done < "$src"
      ;;
    json)
      cat "$src"
      ;;
    *)
      err "Unknown format: $format. Use: md, json"
      return 1
      ;;
  esac
}

# ── v3.3: Health Check ───────────────────────────────────────────────────────
cmd_health_v33() {
  local issues=0
  echo ""
  echo -e "  ${B}${BWHITE}Health Check${R}"
  echo "  ════════════════════════════════════════"

  echo -n "  Python 3.10+ ... "
  if [[ -n "$PYTHON" ]]; then
    local pyver; pyver=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    echo -e "${BGREEN}OK${R} ($pyver)"
  else
    echo -e "${BRED}FAIL${R} (Python 3.10+ not found)"
    ((issues++))
  fi

  echo -n "  GPU ... "
  if [[ "${CUDA_ARCH:-0}" != "0" && "${CUDA_ARCH:-0}" != "metal" ]]; then
    echo -e "${BGREEN}OK${R} (CUDA arch ${CUDA_ARCH})"
  elif [[ "${CUDA_ARCH:-0}" == "metal" ]]; then
    echo -e "${BGREEN}OK${R} (Apple Metal)"
  else
    echo -e "${BYELLOW}WARN${R} (no GPU detected — CPU-only)"
  fi

  echo -n "  Models directory ... "
  if [[ -d "$MODELS_DIR" && -w "$MODELS_DIR" ]]; then
    local mcount; mcount=$(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | wc -l)
    echo -e "${BGREEN}OK${R} ($mcount GGUF files)"
  else
    echo -e "${BRED}FAIL${R} ($MODELS_DIR not accessible)"
    ((issues++))
  fi

  echo -n "  API keys ... "
  local key_count=0
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GROQ_API_KEY MISTRAL_API_KEY; do
    [[ -n "${!k:-}" ]] && ((key_count++))
  done
  if [[ $key_count -gt 0 ]]; then
    echo -e "${BGREEN}OK${R} ($key_count configured)"
  else
    echo -e "${BYELLOW}WARN${R} (none configured — local models only)"
  fi

  echo -n "  llama.cpp ... "
  if [[ -n "$LLAMA_BIN" ]]; then
    echo -e "${BGREEN}OK${R} ($LLAMA_BIN)"
  else
    echo -e "${BYELLOW}WARN${R} (not found — local GGUF won't work)"
  fi

  echo -n "  Disk space ... "
  local df_out; df_out=$(df -h "$MODELS_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
  if [[ -n "$df_out" ]]; then
    echo -e "${BGREEN}OK${R} ($df_out available)"
  else
    echo -e "${BYELLOW}WARN${R} (could not check)"
  fi

  echo ""
  if [[ $issues -eq 0 ]]; then
    echo -e "  ${BGREEN}All checks passed ✓${R}"
  else
    echo -e "  ${BRED}$issues issue(s) found${R}. Run 'ai setup' to fix."
  fi
  echo ""
}

# ── v3.3: Model Quantization Recommendations ─────────────────────────────────
cmd_recommend_quant() {
  local vram_gb=0
  if command -v nvidia-smi &>/dev/null; then
    vram_gb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{print int($1/1024)}')
  elif [[ "$PLATFORM" == "macos" ]]; then
    vram_gb=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "VRAM" | head -1 | grep -oE '[0-9]+' | head -1)
    [[ -z "$vram_gb" ]] && vram_gb=16
  fi
  local ram_gb; ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "8")

  echo ""
  echo -e "  ${B}${BWHITE}Quantization Recommendations${R}"
  echo "  ════════════════════════════════════════"
  echo "  Detected VRAM: ${vram_gb}GB"
  echo "  System RAM:    ${ram_gb}GB"
  echo ""
  echo "  Model Size → Recommended Quantization:"
  echo ""

  local _v; _v="${vram_gb}"
  if [[ $_v -ge 80 ]]; then
    echo "    7B  →  Q8_0 or Q6_K  (best quality)"
    echo "    13B →  Q6_K or Q5_K_M"
    echo "    30B →  Q5_K_M or Q4_K_M"
    echo "    70B →  Q4_K_M or Q3_K_M"
  elif [[ $_v -ge 24 ]]; then
    echo "    7B  →  Q6_K  (best quality)"
    echo "    13B →  Q5_K_M"
    echo "    30B →  Q4_K_M"
    echo "    70B →  Q3_K_M  (slow)"
  elif [[ $_v -ge 12 ]]; then
    echo "    7B  →  Q5_K_M  (recommended)"
    echo "    13B →  Q4_K_M"
    echo "    30B →  Q3_K_M  (slow)"
    echo "    70B →  Not recommended (use API)"
  elif [[ $_v -ge 8 ]]; then
    echo "    7B  →  Q4_K_M  (recommended)"
    echo "    13B →  Q3_K_M  (slow)"
    echo "    30B →  Not recommended (use API)"
  elif [[ $_v -ge 4 ]]; then
    echo "    3B  →  Q6_K"
    echo "    7B  →  Q3_K_M  (slow, acceptable)"
    echo "    13B →  Not recommended (use API)"
  else
    echo "    Use cloud APIs or 1-3B models with Q4_K_M"
    echo "    Consider: ai use gpt-4o-mini  (fast, cheap API)"
  fi
  echo ""
  echo "  Quantization quality (best → fastest):"
  echo "    F16 > Q8_0 > Q6_K > Q5_K_M > Q4_K_M > Q3_K_M > Q2_K"
  echo ""
}

# ── v3.3: Enhanced Favorite Command ──────────────────────────────────────────
cmd_favorite() {
  local subcmd="${1:-list}"; shift || true
  case "$subcmd" in
    list|"")
      cmd_model_fav list "$@"
      ;;
    add|set)
      cmd_model_fav add "$1"
      ;;
    del|delete|remove)
      cmd_model_fav del "$1"
      ;;
    *)
      cmd_model_fav add "$subcmd"
      ;;
  esac
}