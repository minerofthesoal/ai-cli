# ============================================================================
# MODULE: 25-aliases.sh
# User-defined command aliases (v2.7.3)
# Source lines 8730-8841 of main-v2.7.3
# ============================================================================

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
        echo "  Create: ai alias set <name> <command...>"
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
      [[ -z "$name" ]] && { err "Alias name required.  Usage: ai alias set <name> <command>"; return 1; }
      [[ -z "$cmd_str" ]] && { err "Command required.  Usage: ai alias set <name> <command>"; return 1; }
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
      echo -e "  ${B}ai alias set <name> <cmd...>${R}   Create or update alias"
      echo -e "  ${B}ai alias del <name>${R}            Delete alias"
      echo -e "  ${B}ai alias show <name>${R}           Show single alias"
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
#  CUSTOM DATASET CREATION  (v2.4)
