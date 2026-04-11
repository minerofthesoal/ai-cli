# ============================================================================
# MODULE: 37-dispatcher.sh
# main() command dispatcher + startup hooks
# Source lines 13460-13695 of main-v2.7.3
# ============================================================================

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

    # ── Asking ───────────────────────────────────────────────────────────────
    ask|a)
      # v2.7.3: Handle empty prompt — prompt interactively
      local _ask_prompt="$*"
      if [[ -z "$_ask_prompt" ]]; then
        if [[ -t 0 ]]; then
          read -rp "$(echo -e "${BCYAN}Ask: ${R}")" _ask_prompt
          [[ -z "$_ask_prompt" ]] && { err "No prompt given. Usage: ai ask \"<question>\""; return 1; }
        else
          # stdin may have piped content
          _ask_prompt=$(cat)
        fi
      fi
      dispatch_ask "$_ask_prompt" ;;
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

    # ── Canvas ────────────────────────────────────────────────────────────────
    canvas)  cmd_canvas "$@" ;;

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

    # ── GUI / Bench / Serve ───────────────────────────────────────────────────
    -gui|--gui|gui) cmd_gui ;;
    bench)  cmd_bench "$@" ;;
    serve)  cmd_serve "$@" ;;

    # ── v2.4: Custom Datasets ─────────────────────────────────────────────────
    dataset|datasets) cmd_dataset "$@" ;;

    # ── v2.4: LLM API Server ──────────────────────────────────────────────────
    api)    cmd_api "$@" ;;

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

    # ── v2.5: Canvas v2 ───────────────────────────────────────────────────────
    canvas-v2|canvasv2|canvas2) cmd_canvas_v2 "$@" ;;

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

    # ── Misc ──────────────────────────────────────────────────────────────────
    version|-v|--version) echo "AI CLI v${VERSION}" ;;
    help|-h|--help|"")    show_help ;;
    tools)  echo "Builtin agent tools: ${!AGENT_TOOLS_REGISTRY[*]}" ;;
    error-codes|errcodes|errors)
      hdr "AI CLI v${VERSION} — Error Code Reference"
      echo ""
      for code in "${!ERR_CODES[@]}"; do
        printf "  ${B}%-10s${R} %s\n" "$code" "${ERR_CODES[$code]}"
      done | sort
      ;;
    *)
      # v2.7.3: Check user-defined aliases first before AI fallthrough
      local _alias_cmd
      _alias_cmd=$(_resolve_alias "$cmd" 2>/dev/null) || true
      if [[ -n "$_alias_cmd" ]]; then
        # Expand alias and re-dispatch
        # shellcheck disable=SC2086
        eval "main $_alias_cmd \"\$@\""
        return $?
      fi
      # Unknown command — show helpful error, then try AI fallthrough
      echo -e "${DIM}[ai] No command named \"${cmd}\". Checking aliases and passing to AI...${R}" >&2
      echo -e "${DIM}[ai] Run 'ai help' to see all commands. Run 'ai alias' to see aliases.${R}" >&2
      dispatch_ask "$cmd $*" ;;
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
