#!/usr/bin/env bash
# Return if sourced before config is loaded
[[ -z "${VERSION:-}" ]] && return 0 2>/dev/null || true
# AI CLI v3.1.0 — Chat module
# Interactive chat, ask, ask-web

cmd_chat_interactive() {
  hdr "AI Chat v3.1 — Session: $ACTIVE_SESSION"
  info "Backend: ${ACTIVE_BACKEND:-auto} | Model: ${ACTIVE_MODEL:-auto}"
  echo -e "  ${DIM}Type /help for commands${R}"
  echo ""

  local last_prompt="" msg_count=0 multiline=0
  while true; do
    if [[ $multiline -eq 1 ]]; then
      printf "${BCYAN}${B}You (multi): ${R}"
      local lines=""
      while IFS= read -r line; do [[ -z "$line" ]] && break; lines+="$line"$'\n'; done
      local input="${lines%$'\n'}"
    else
      printf "${BCYAN}${B}You: ${R}"
      local input; read -r input || break
    fi
    [[ -z "$input" ]] && continue

    case "$input" in
      /quit|/exit|/q) info "Chat ended ($msg_count messages)"; break ;;
      /clear) echo "[]" > "$SESSIONS_DIR/${ACTIVE_SESSION}.json"; msg_count=0; ok "Cleared" ;;
      /retry) [[ -n "$last_prompt" ]] && { printf "${BGREEN}AI: ${R}"; dispatch_ask "$last_prompt"; echo ""; } || warn "Nothing to retry" ;;
      /model*) local m="${input#/model }"; [[ -n "$m" && "$m" != "/model" ]] && { ACTIVE_MODEL="$m"; save_config; ok "Model: $m"; } || info "Model: ${ACTIVE_MODEL:-auto}" ;;
      /persona*) local p="${input#/persona }"; [[ -n "$p" && "$p" != "/persona" ]] && { ACTIVE_PERSONA="$p"; save_config; ok "Persona: $p"; } || info "Persona: ${ACTIVE_PERSONA:-default}" ;;
      /system*) local s="${input#/system }"; [[ -n "$s" && "$s" != "/system" ]] && { CUSTOM_SYSTEM_PROMPT="$s"; save_config; ok "System prompt set"; } || info "System: $(_get_effective_system | head -c 80)" ;;
      /multiline) multiline=$(( 1 - multiline )); if [[ $multiline -eq 1 ]]; then ok "Multiline ON"; else ok "Multiline OFF"; fi ;;
      /temp*) local t="${input#/temp }"; [[ "$t" =~ ^[0-9.]+$ ]] && { TEMPERATURE="$t"; save_config; ok "Temp: $t"; } || info "Temp: $TEMPERATURE" ;;
      /export) mkdir -p "$EXPORTS_DIR"; cp "$SESSIONS_DIR/${ACTIVE_SESSION}.json" "$EXPORTS_DIR/chat_$(date +%Y%m%d%H%M%S).json" 2>/dev/null; ok "Exported" ;;
      /web*) local q="${input#/web }"; info "Web search..."; dispatch_ask "$(web_search "$q" 3 2>/dev/null || echo "")

$q" ;;
      /help|/h) echo "  /quit /clear /retry /model <m> /persona <p> /system <s>"
                echo "  /temp <n> /multiline /export /web <query> /help" ;;
      /*) warn "Unknown: $input (try /help)" ;;
      *) last_prompt="$input"; printf "${BGREEN}AI: ${R}"; dispatch_ask "$input"; echo ""; (( msg_count++ )) ;;
    esac
  done
}
