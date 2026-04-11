# ============================================================================
# MODULE: 12-chat.sh
# Named chat sessions + JSONL save + HF dataset sync
# Source lines 4113-4228 of main-v2.7.3
# ============================================================================

# ════════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════════
#  NAMED CHAT (-C) WITH JSONL SAVE + HF DATASET SYNC
# ════════════════════════════════════════════════════════════════════════════════
CURRENT_CHAT_NAME=""
CURRENT_CHAT_FILE=""

_chat_start() {
  local name="$1"
  # auto: generate a name based on timestamp
  if [[ "$name" == "auto" ]]; then
    name="chat_$(date +%Y%m%d_%H%M%S)"
  fi
  # Sanitize name
  name="${name//[^a-zA-Z0-9_-]/_}"
  CURRENT_CHAT_NAME="$name"
  CURRENT_CHAT_FILE="$CHAT_LOGS_DIR/${name}.jsonl"
  ok "Chat started: $name"
  echo "  Saving to: $CURRENT_CHAT_FILE"
  [[ "$HF_DATASET_SYNC" == "1" ]] && echo "  HF sync:   enabled → $HF_DATASET_REPO"
}

_chat_append() {
  local role="$1"; local content="$2"
  [[ -z "$CURRENT_CHAT_FILE" ]] && return 0
  local ts; ts=$(date -Iseconds)
  local record; record=$(printf '{"timestamp":"%s","session":"%s","role":"%s","content":%s}' \
    "$ts" "$CURRENT_CHAT_NAME" "$role" "$(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')")
  echo "$record" >> "$CURRENT_CHAT_FILE"

  # Background sync to HF if enabled
  if [[ "$HF_DATASET_SYNC" == "1" ]] && [[ -n "${HF_DATASET_KEY:-}" ]]; then
    _hf_dataset_sync_bg
  fi
}

_hf_dataset_sync_bg() {
  # Run in background — upload the current chat jsonl to the dataset repo
  local chat_file="$CURRENT_CHAT_FILE"
  local chat_name="$CURRENT_CHAT_NAME"
  local hf_key="$HF_DATASET_KEY"
  local repo="$HF_DATASET_REPO"
  [[ -z "$PYTHON" ]] && return 0

  ( HF_CHAT_FILE="$chat_file" HF_CHAT_NAME="$chat_name" \
    HF_KEY="$hf_key" HF_REPO="$repo" \
    "$PYTHON" - <<'PYEOF' &>/dev/null
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    sys.exit(0)
chat_file = os.environ['HF_CHAT_FILE']
chat_name = os.environ['HF_CHAT_NAME']
hf_key    = os.environ['HF_KEY']
repo      = os.environ['HF_REPO']
if not os.path.exists(chat_file): sys.exit(0)
api = HfApi(token=hf_key)
try:
    api.create_repo(repo_id=repo, repo_type='dataset', exist_ok=True, private=False)
    api.upload_file(
        path_or_fileobj=chat_file,
        path_in_repo=f"chats/{chat_name}.jsonl",
        repo_id=repo,
        repo_type='dataset',
        commit_message=f"sync: {chat_name}",
    )
except Exception as e:
    pass
PYEOF
  ) &
}

cmd_chat_list() {
  hdr "Saved Chats"
  local count=0
  for f in "$CHAT_LOGS_DIR"/*.jsonl; do
    [[ -f "$f" ]] || continue
    count=$(( count + 1 ))
    local name; name=$(basename "$f" .jsonl)
    local lines; lines=$(wc -l < "$f")
    printf "  ${B}%-30s${R} %3d messages\n" "$name" "$lines"
  done
  [[ $count -eq 0 ]] && dim "  No saved chats. Use: ai -C [name] ask ..."
}

cmd_chat_show() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: ai chat-show <name>"; return 1; }
  local f="$CHAT_LOGS_DIR/${name}.jsonl"
  [[ ! -f "$f" ]] && { err "Chat '$name' not found"; return 1; }
  hdr "Chat: $name"
  echo ""
  while IFS= read -r line; do
    local role; role=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('role','?'))" 2>/dev/null || echo "?")
    local content; content=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('content',''))" 2>/dev/null || echo "")
    if [[ "$role" == "user" ]]; then
      echo -e "${B}${BCYAN}You:${R} $content"
    else
      echo -e "${B}${BGREEN}AI:${R} $content"
    fi
    echo ""
  done < "$f"
}

cmd_chat_delete() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local f="$CHAT_LOGS_DIR/${name}.jsonl"
  [[ ! -f "$f" ]] && { err "Chat '$name' not found"; return 1; }
  read -rp "Delete chat '$name'? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled"; return 0; }
  rm -f "$f"; ok "Deleted $name"
}

# ════════════════════════════════════════════════════════════════════════════════
#  AUDIO SUPPORT
