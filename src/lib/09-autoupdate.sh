# ============================================================================
# MODULE: 09-autoupdate.sh
# Auto-update checker + cmd_autoupdate
# Source lines 3408-3558 of main-v2.7.3
# ============================================================================

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
