# ============================================================================
# MODULE: 24-helpers.sh
# Misc helpers: personas, sessions, config, history, project
# Source lines 8433-8730 of main-v2.7.3
# ============================================================================

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
      [[ $found -eq 0 ]] && info "No projects yet. Run: ai project new <name>" ;;

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
      echo "  new <name> [desc]    Create a new project (persistent chat memory)"
      echo "  list                 List all projects"
      echo "  switch <name>        Switch to a project"
      echo "  show [name]          Show project info and recent messages"
      echo "  memory [name]        Show memory summary"
      echo "  delete <name>        Delete a project"
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
