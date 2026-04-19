#!/usr/bin/env bash
# AI CLI v3.1.0 — Workspace module
# Snap, templates, RAG, batch, branch, export, notebook, plan, memory, presets, plugins

cmd_snap() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    save) local n="${1:?Usage: ai snap save <name>}"; cp "$CONFIG_FILE" "$SNAPSHOTS_DIR/${n}.snap" 2>/dev/null; ok "Saved: $n" ;;
    load) local n="${1:?Usage: ai snap load <name>}"; [[ -f "$SNAPSHOTS_DIR/${n}.snap" ]] && { source "$SNAPSHOTS_DIR/${n}.snap"; save_config; ok "Loaded: $n"; } || err "Not found: $n" ;;
    list) hdr "Snapshots"; for f in "$SNAPSHOTS_DIR"/*.snap; do [[ -f "$f" ]] && echo "  $(basename "$f" .snap)"; done ;;
    delete) rm -f "$SNAPSHOTS_DIR/${1}.snap"; ok "Deleted" ;;
    *) echo "Usage: ai snap <save|load|list|delete> <name>" ;;
  esac
}

cmd_template() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local n="${1:?name}"; echo '# Template: {{input}}' > "$TEMPLATES_DIR/${n}.tpl"; ok "Created: $n" ;;
    use) local n="${1:?name}"; shift; local c; c=$(cat "$TEMPLATES_DIR/${n}.tpl" 2>/dev/null) || { err "Not found"; return 1; }; c="${c//\{\{input\}\}/$*}"; dispatch_ask "$c" ;;
    list) hdr "Templates"; for f in "$TEMPLATES_DIR"/*.tpl; do [[ -f "$f" ]] && echo "  $(basename "$f" .tpl)"; done ;;
    delete) rm -f "$TEMPLATES_DIR/${1}.tpl"; ok "Deleted" ;;
    *) echo "Usage: ai template <create|use|list|delete>" ;;
  esac
}

cmd_rag() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local n="${1:?name}" d="${2:?directory}"; mkdir -p "$RAG_DIR/$n"
      find "$d" -type f -size -1M \( -name "*.txt" -o -name "*.md" -o -name "*.py" -o -name "*.js" -o -name "*.sh" \) -exec cat {} + 2>/dev/null | head -50000 > "$RAG_DIR/$n/index.txt"
      ok "Indexed: $n ($(wc -l < "$RAG_DIR/$n/index.txt") lines)" ;;
    query) local n="${1:?name}" q="${2:?question}"; [[ -f "$RAG_DIR/$n/index.txt" ]] || { err "Not found: $n"; return 1; }
      local ctx; ctx=$(grep -i "${q%% *}" "$RAG_DIR/$n/index.txt" 2>/dev/null | head -20)
      dispatch_ask "Context from knowledge base '$n':
$ctx

Question: $q" ;;
    list) hdr "RAG Bases"; for d in "$RAG_DIR"/*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done ;;
    delete) rm -rf "$RAG_DIR/$1"; ok "Deleted" ;;
    *) echo "Usage: ai rag <create|query|list|delete>" ;;
  esac
}

cmd_batch() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add) local p="${*:?prompt}"; local id=$(date +%s%N | tail -c 8); echo "$p" > "$BATCH_DIR/${id}.prompt"; ok "Queued: #$id" ;;
    run) for f in "$BATCH_DIR"/*.prompt; do [[ -f "$f" ]] || continue; local id=$(basename "$f" .prompt); info "#$id..."; dispatch_ask "$(cat "$f")" > "$BATCH_DIR/${id}.out" 2>&1; ok "#$id done"; done ;;
    list) for f in "$BATCH_DIR"/*.prompt; do [[ -f "$f" ]] || continue; echo "  #$(basename "$f" .prompt): $(head -c 60 "$f")"; done ;;
    results) for f in "$BATCH_DIR"/*.out; do [[ -f "$f" ]] && { echo "--- #$(basename "$f" .out) ---"; cat "$f"; echo ""; }; done ;;
    clear) rm -f "$BATCH_DIR"/*.prompt "$BATCH_DIR"/*.out; ok "Cleared" ;;
    *) echo "Usage: ai batch <add|run|list|results|clear>" ;;
  esac
}

cmd_branch() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local n="${1:?name}"; mkdir -p "$BRANCHES_DIR/$n"; cp "$SESSIONS_DIR/${ACTIVE_SESSION}.json" "$BRANCHES_DIR/$n/history.json" 2>/dev/null; ok "Branch: $n" ;;
    use) local n="${1:?name}"; [[ -d "$BRANCHES_DIR/$n" ]] || { err "Not found"; return 1; }; cp "$BRANCHES_DIR/$n/history.json" "$SESSIONS_DIR/${ACTIVE_SESSION}.json" 2>/dev/null; ok "Switched to: $n" ;;
    list) hdr "Branches"; for d in "$BRANCHES_DIR"/*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done ;;
    delete) rm -rf "$BRANCHES_DIR/$1"; ok "Deleted" ;;
    *) echo "Usage: ai branch <create|use|list|delete>" ;;
  esac
}

cmd_export() {
  local sub="${1:-all}"; local out="$EXPORTS_DIR/$(date +%Y%m%d_%H%M%S)"; mkdir -p "$out"
  case "$sub" in
    chat) cp "$SESSIONS_DIR"/*.json "$out/" 2>/dev/null; ok "Exported chats to $out" ;;
    config) cp "$CONFIG_FILE" "$out/" 2>/dev/null; ok "Exported config to $out" ;;
    all) cp "$SESSIONS_DIR"/*.json "$CONFIG_FILE" "$out/" 2>/dev/null; ok "Exported all to $out" ;;
    *) echo "Usage: ai export <all|chat|config>" ;;
  esac
}

cmd_import() { local s="${1:?path}"; [[ -f "$s" ]] && cp "$s" "$CONFIG_DIR/" && ok "Imported" || { [[ -d "$s" ]] && cp "$s"/* "$CONFIG_DIR/" 2>/dev/null && ok "Imported"; } || err "Not found"; }

cmd_notebook() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    new) local n="${1:?name}"; printf "# Notebook: %s\n\n--- [text]\nWelcome\n\n--- [ai]\nHello!\n\n--- [code]\necho hello\n" "$n" > "$NOTEBOOKS_DIR/${n}.ainb"; ok "Created: $n" ;;
    run) local n="${1:?name}"; [[ -f "$NOTEBOOKS_DIR/${n}.ainb" ]] || { err "Not found"; return 1; }
      local type="" content=""
      while IFS= read -r line; do
        if [[ "$line" =~ ^---\ \[(code|ai|text)\] ]]; then
          [[ -n "$content" && -n "$type" ]] && { case "$type" in code) bash -c "$content" 2>&1 ;; ai) _silent_generate "$content" ;; text) echo "$content" ;; esac; }
          type="${BASH_REMATCH[1]}"; content=""
        else content+="$line"$'\n'
        fi
      done < "$NOTEBOOKS_DIR/${n}.ainb"
      [[ -n "$content" && -n "$type" ]] && { case "$type" in code) bash -c "$content" 2>&1 ;; ai) _silent_generate "$content" ;; text) echo "$content" ;; esac; } ;;
    list) for f in "$NOTEBOOKS_DIR"/*.ainb; do [[ -f "$f" ]] && echo "  $(basename "$f" .ainb)"; done ;;
    edit) ${EDITOR:-nano} "$NOTEBOOKS_DIR/${1:?name}.ainb" ;;
    *) echo "Usage: ai notebook <new|run|list|edit>" ;;
  esac
}

cmd_plan() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local g="${*:?goal}"; info "Planning..."; _silent_generate "Break into 5-10 numbered tasks: $g" >> "$TASKS_FILE"; ok "Plan created" ;;
    list) hdr "Tasks"; cat "$TASKS_FILE" 2>/dev/null || info "Empty" ;;
    clear) > "$TASKS_FILE"; ok "Cleared" ;;
    *) echo "Usage: ai plan <create|list|clear>" ;;
  esac
}

cmd_memory() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add|remember) echo "${*:?Usage: ai mem add FACT}" >> "$MEMORY_FILE"; ok "Remembered: $*" ;;
    list|show|ls)
      hdr "AI Memory"
      if [[ ! -s "$MEMORY_FILE" ]]; then
        info "No memories yet. Add one: ai mem add \"your name is John\""
        return
      fi
      local n=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( n++ ))
        printf "  ${BCYAN}%3d${R}  %s\n" "$n" "$line"
      done < "$MEMORY_FILE"
      echo ""
      info "$n memories | Edit: ai mem edit | Clear: ai mem clear" ;;
    edit) ${EDITOR:-nano} "$MEMORY_FILE"; ok "Memory file saved" ;;
    delete|rm)
      local n="${1:?Usage: ai mem delete NUMBER}"
      sed -i "${n}d" "$MEMORY_FILE" 2>/dev/null || sed -i '' "${n}d" "$MEMORY_FILE" 2>/dev/null
      ok "Memory #$n deleted" ;;
    context) cat "$MEMORY_FILE" 2>/dev/null ;;
    clear) > "$MEMORY_FILE"; ok "Memory cleared" ;;
    search) grep -in "${1:?keyword}" "$MEMORY_FILE" 2>/dev/null || info "No matches" ;;
    *)
      echo "Usage: ai mem <add|list|edit|delete|clear|search>"
      echo ""
      echo "  add \"fact\"     Remember a fact"
      echo "  list           Show all memories with numbers"
      echo "  edit           Open memory file in editor"
      echo "  delete N       Delete memory by number"
      echo "  search WORD    Search memories"
      echo "  clear          Delete all memories"
      echo "  context        Output raw for prompt injection"
      ;;
  esac
}

cmd_preset() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    save) local n="${1:?name}"; cp "$CONFIG_FILE" "$PRESETS_DIR/${n}.preset"; ok "Saved: $n" ;;
    load) local n="${1:?name}"; [[ -f "$PRESETS_DIR/${n}.preset" ]] && { source "$PRESETS_DIR/${n}.preset"; save_config; ok "Loaded: $n"; } || err "Not found" ;;
    list) for f in "$PRESETS_DIR"/*.preset; do [[ -f "$f" ]] && echo "  $(basename "$f" .preset)"; done ;;
    delete) rm -f "$PRESETS_DIR/${1}.preset"; ok "Deleted" ;;
    *) echo "Usage: ai preset <save|load|list|delete>" ;;
  esac
}

cmd_plugin() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    list) hdr "Plugins"; for f in "$PLUGINS_DIR"/*.sh; do [[ -f "$f" ]] && echo "  $(basename "$f" .sh)"; done ;;
    install) local u="${1:?url/path}"; [[ -f "$u" ]] && cp "$u" "$PLUGINS_DIR/" || curl -fsSL "$u" -o "$PLUGINS_DIR/$(basename "$u")" 2>/dev/null; ok "Installed" ;;
    remove) rm -f "$PLUGINS_DIR/${1:?name}.sh"; ok "Removed" ;;
    reload) for f in "$PLUGINS_DIR"/*.sh; do [[ -f "$f" ]] && source "$f"; done; ok "Reloaded" ;;
    *) echo "Usage: ai plugin <list|install|remove|reload>" ;;
  esac
}

cmd_favorite() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add) echo "${*:?prompt}" >> "$FAVORITES_FILE"; ok "Saved" ;;
    list) hdr "Favorites"; nl -ba "$FAVORITES_FILE" 2>/dev/null || info "Empty" ;;
    run) local n="${1:?number}"; local p; p=$(sed -n "${n}p" "$FAVORITES_FILE" 2>/dev/null); [[ -n "$p" ]] && dispatch_ask "$p" || err "Not found" ;;
    delete) sed -i "${1:?number}d" "$FAVORITES_FILE" 2>/dev/null; ok "Deleted" ;;
    *) echo "Usage: ai fav <add|list|run|delete>" ;;
  esac
}

cmd_schedule() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    add) local cron="${1:?cron}" prompt="${2:?prompt}"; local id=$(date +%s); echo "$cron ai ask \"$prompt\"" > "$SCHEDULE_DIR/${id}.sched"; ok "Scheduled: #$id" ;;
    list) for f in "$SCHEDULE_DIR"/*.sched; do [[ -f "$f" ]] && echo "  #$(basename "$f" .sched): $(cat "$f")"; done ;;
    install) local tmp=$(mktemp); crontab -l 2>/dev/null | grep -v 'ai-cli-sched' > "$tmp"; for f in "$SCHEDULE_DIR"/*.sched; do [[ -f "$f" ]] && echo "$(cat "$f") # ai-cli-sched" >> "$tmp"; done; crontab "$tmp"; rm "$tmp"; ok "Installed" ;;
    remove) rm -f "$SCHEDULE_DIR/${1}.sched"; ok "Removed" ;;
    *) echo "Usage: ai schedule <add|list|install|remove>" ;;
  esac
}

cmd_profile() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    create) local n="${1:?name}"; mkdir -p "$PROFILES_DIR/$n"; cp "$CONFIG_FILE" "$KEYS_FILE" "$PROFILES_DIR/$n/" 2>/dev/null; ok "Created: $n" ;;
    switch) local n="${1:?name}"; [[ -d "$PROFILES_DIR/$n" ]] || { err "Not found"; return 1; }; cp "$PROFILES_DIR/$n"/* "$CONFIG_DIR/" 2>/dev/null; source "$CONFIG_FILE"; ok "Switched: $n" ;;
    list) for d in "$PROFILES_DIR"/*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done ;;
    *) echo "Usage: ai profile <create|switch|list>" ;;
  esac
}
