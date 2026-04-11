# ============================================================================
# MODULE: 34-canvas-v2.sh
# Canvas v2 — multi-file workspace with git + live preview
# Source lines 12045-12679 of main-v2.7.3
# ============================================================================

cmd_canvas_v2() {
  local sub="${1:-open}"; shift || true
  case "$sub" in
    new)
      local ws="${1:?Usage: ai canvas-v2 new <workspace-name>}"
      local ws_dir="$CANVAS_V2_DIR/$ws"
      [[ -d "$ws_dir" ]] && { err "Workspace exists: $ws"; return 1; }
      mkdir -p "$ws_dir"/{files,preview,exports}
      cat > "$ws_dir/workspace.json" <<EOF
{
  "name": "$ws",
  "created": "$(date -Iseconds)",
  "files": [],
  "active_file": null,
  "git_enabled": false,
  "ai_model": "${ACTIVE_MODEL:-}"
}
EOF
      git -C "$ws_dir" init -q 2>/dev/null && \
        git -C "$ws_dir" add workspace.json && \
        git -C "$ws_dir" commit -q -m "Init canvas workspace: $ws" 2>/dev/null || true
      ok "Canvas v2 workspace: $ws_dir"
      echo "  Add files:  ai canvas-v2 add $ws <file>"
      echo "  Open TUI:   ai canvas-v2 open $ws"
      ;;

    add)
      local ws="${1:?workspace}" file="${2:?file path}"
      local ws_dir="$CANVAS_V2_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws. Run: ai canvas-v2 new $ws"; return 1; }
      cp "$file" "$ws_dir/files/"
      local fname; fname=$(basename "$file")
      # Update workspace.json
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "
import json, os
f = '$ws_dir/workspace.json'
d = json.load(open(f))
if '$fname' not in d['files']:
    d['files'].append('$fname')
    d['active_file'] = '$fname'
json.dump(d, open(f,'w'), indent=2)
print('Added: $fname')
"
      git -C "$ws_dir" add "files/$fname" 2>/dev/null && \
        git -C "$ws_dir" commit -q -m "Add file: $fname" 2>/dev/null || true
      ;;

    open)
      local ws="${1:-}"
      [[ -z "$ws" ]] && {
        info "Available workspaces:"
        ls "$CANVAS_V2_DIR/" 2>/dev/null || echo "(none)"
        return 0
      }
      local ws_dir="$CANVAS_V2_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      [[ -z "$PYTHON" ]] && { err "Python required for Canvas TUI"; return 1; }
      info "Opening Canvas v2: $ws"
      "$PYTHON" - "$ws_dir" "$ws" "$ACTIVE_MODEL" "$VERSION" <<'PYEOF'
import sys, os, json, curses, subprocess, threading, time

ws_dir, ws_name, active_model, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
files_dir = os.path.join(ws_dir, 'files')
ws_json = os.path.join(ws_dir, 'workspace.json')

def load_ws():
    try: return json.load(open(ws_json))
    except: return {'files': [], 'active_file': None}

def save_ws(d):
    json.dump(d, open(ws_json, 'w'), indent=2)

def list_files():
    return sorted(f for f in os.listdir(files_dir) if not f.startswith('.'))

def ai_ask(prompt, context=''):
    import subprocess
    result = subprocess.run(['ai', 'ask', f"Context:\n{context}\n\n{prompt}"],
        capture_output=True, text=True, timeout=60)
    return result.stdout.strip() or result.stderr.strip()

def canvas_tui(stdscr):
    curses.curs_set(1)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_WHITE, curses.COLOR_BLUE)

    ws = load_ws()
    files = list_files()
    active_idx = 0
    file_content = []
    edit_mode = False
    cursor_y, cursor_x = 0, 0
    ai_output = ""
    split = False
    status = f"Canvas v2 | {ws_name} | {len(files)} files | Ctrl+Q=quit F=new-file E=edit A=ask-AI S=split G=git"

    def load_file(fname):
        fp = os.path.join(files_dir, fname)
        try:
            with open(fp) as f: return f.readlines()
        except: return ['(binary or unreadable)']

    def save_file(fname, lines):
        fp = os.path.join(files_dir, fname)
        with open(fp, 'w') as f:
            f.writelines(lines)
        subprocess.run(['git','-C',ws_dir,'add',f'files/{fname}'], capture_output=True)

    if files: file_content = load_file(files[active_idx])

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        # Header
        header = f" Canvas v2 — {ws_name} | {version} "
        stdscr.addstr(0, 0, header.ljust(w), curses.color_pair(4))
        # Left panel: file list
        panel_w = max(20, w // 5)
        stdscr.addstr(1, 0, "Files:", curses.color_pair(1) | curses.A_BOLD)
        for i, fname in enumerate(files[:h-4]):
            attr = curses.color_pair(2) | curses.A_REVERSE if i == active_idx else 0
            stdscr.addstr(2+i, 0, fname[:panel_w-1].ljust(panel_w-1), attr)
        # Separator
        for row in range(1, h-2):
            try: stdscr.addch(row, panel_w, '│', curses.color_pair(1))
            except: pass
        # Right panel: file content / split
        content_x = panel_w + 1
        content_w = w - content_x
        if split and ai_output:
            half = content_w // 2
            stdscr.addstr(1, content_x, "File", curses.color_pair(1))
            stdscr.addstr(1, content_x + half + 1, "AI Output", curses.color_pair(3))
            for row, line in enumerate(file_content[:h-4]):
                try: stdscr.addstr(2+row, content_x, line[:half].rstrip('\n'))
                except: pass
            ai_lines = ai_output.split('\n')
            for row, line in enumerate(ai_lines[:h-4]):
                try: stdscr.addstr(2+row, content_x+half+1, line[:half-1])
                except: pass
        else:
            if files:
                stdscr.addstr(1, content_x, f"[{files[active_idx]}]", curses.color_pair(2))
            for row, line in enumerate(file_content[:h-4]):
                try: stdscr.addstr(2+row, content_x, line[:content_w-1].rstrip('\n'))
                except: pass
        # Status bar
        try: stdscr.addstr(h-2, 0, status[:w-1].ljust(w-1), curses.color_pair(4))
        except: pass
        if edit_mode:
            try: stdscr.move(min(2+cursor_y, h-3), min(content_x+cursor_x, w-1))
            except: pass
        stdscr.refresh()

        key = stdscr.getch()
        if key == 17:  # Ctrl+Q
            break
        elif key == curses.KEY_UP and active_idx > 0:
            active_idx -= 1
            if files: file_content = load_file(files[active_idx])
        elif key == curses.KEY_DOWN and active_idx < len(files)-1:
            active_idx += 1
            if files: file_content = load_file(files[active_idx])
        elif key in (ord('F'), ord('f')):
            # New file
            curses.echo()
            stdscr.addstr(h-1, 0, "New file name: ")
            try:
                fname = stdscr.getstr(h-1, 15, 60).decode()
            except: fname = ""
            curses.noecho()
            if fname:
                fp = os.path.join(files_dir, fname)
                open(fp, 'w').close()
                files = list_files()
                active_idx = files.index(fname) if fname in files else 0
                file_content = []
        elif key in (ord('E'), ord('e')):
            # Open in $EDITOR
            if files:
                editor = os.environ.get('EDITOR', 'nano')
                curses.endwin()
                os.system(f"{editor} {files_dir}/{files[active_idx]}")
                file_content = load_file(files[active_idx])
                stdscr = curses.initscr()
                curses.cbreak(); stdscr.keypad(True)
        elif key in (ord('A'), ord('a')):
            # Ask AI about current file
            curses.echo()
            stdscr.addstr(h-1, 0, "Ask AI: ")
            try:
                q = stdscr.getstr(h-1, 8, 100).decode()
            except: q = ""
            curses.noecho()
            if q and files:
                ctx = ''.join(file_content[:50])
                status = "Asking AI..."
                stdscr.addstr(h-2, 0, status[:w-1].ljust(w-1), curses.color_pair(4))
                stdscr.refresh()
                ai_output = ai_ask(q, ctx)
                split = True
                status = "AI responded. S=toggle-split Ctrl+Q=quit"
        elif key in (ord('S'), ord('s')):
            split = not split
        elif key in (ord('G'), ord('g')):
            # Git commit
            curses.echo()
            stdscr.addstr(h-1, 0, "Commit msg: ")
            try:
                msg = stdscr.getstr(h-1, 12, 100).decode()
            except: msg = ""
            curses.noecho()
            if msg:
                subprocess.run(['git','-C',ws_dir,'add','.'], capture_output=True)
                r = subprocess.run(['git','-C',ws_dir,'commit','-m',msg], capture_output=True)
                status = "Committed!" if r.returncode == 0 else "Git error"
        elif key in (ord('P'), ord('p')):
            # Live preview (open in browser/viewer)
            if files:
                fname = files[active_idx]
                ext = fname.rsplit('.',1)[-1].lower()
                fp = os.path.join(files_dir, fname)
                if ext in ('html','htm'):
                    subprocess.Popen(['xdg-open', fp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif ext == 'md':
                    subprocess.Popen(['xdg-open', fp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                status = f"Preview opened: {fname}"
        elif key == ord('?') or key == curses.KEY_F1:
            status = "Keys: UP/DOWN=files F=new E=edit A=ask-AI S=split G=commit P=preview Ctrl+Q=quit"

curses.wrapper(canvas_tui)
PYEOF
      ;;

    list)
      info "Canvas v2 workspaces:"
      ls -1 "$CANVAS_V2_DIR/" 2>/dev/null | while read -r ws; do
        local cfg="$CANVAS_V2_DIR/$ws/workspace.json"
        if [[ -f "$cfg" ]] && [[ -n "$PYTHON" ]]; then
          local nfiles; nfiles=$("$PYTHON" -c "import json; d=json.load(open('$cfg')); print(len(d.get('files',[])))" 2>/dev/null || echo 0)
          echo "  $ws  ($nfiles files)"
        else
          echo "  $ws"
        fi
      done
      ;;

    delete)
      local ws="${1:?workspace name required}"
      local ws_dir="$CANVAS_V2_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      read -rp "Delete workspace '$ws'? [y/N]: " confirm
      [[ "${confirm,,}" != "y" ]] && { info "Cancelled"; return 0; }
      rm -rf "$ws_dir" && ok "Deleted: $ws"
      ;;

    export)
      local ws="${1:?workspace}" fmt="${2:-tar}"
      local ws_dir="$CANVAS_V2_DIR/$ws"
      [[ ! -d "$ws_dir" ]] && { err "Workspace not found: $ws"; return 1; }
      local out="$AI_OUTPUT_DIR/${ws}_export.tar.gz"
      tar -czf "$out" -C "$CANVAS_V2_DIR" "$ws/"
      ok "Exported: $out"
      ;;

    gist)
      local ws="${1:?workspace}"
      local ws_dir="$CANVAS_V2_DIR/$ws/files"
      if command -v gh &>/dev/null; then
        info "Uploading $ws to GitHub Gist..."
        gh gist create "$ws_dir"/* --desc "Canvas v2: $ws" && ok "Gist created"
      else
        err "GitHub CLI (gh) required for Gist upload"
        info "Install: sudo pacman -S github-cli  OR  sudo apt install gh"
      fi
      ;;

    help|*)
      hdr "AI CLI — Canvas v2 (v2.5)"
      echo "  Multi-file workspace with split-pane, AI assist, git, live preview"
      echo ""
      echo "  ai canvas-v2 new <name>          Create new workspace"
      echo "  ai canvas-v2 open <name>         Open TUI (Ctrl+Q to exit)"
      echo "  ai canvas-v2 add <ws> <file>     Add file to workspace"
      echo "  ai canvas-v2 list                List workspaces"
      echo "  ai canvas-v2 delete <name>       Delete workspace"
      echo "  ai canvas-v2 export <name> [tar] Export as tarball"
      echo "  ai canvas-v2 gist <name>         Upload to GitHub Gist"
      echo ""
      echo "  TUI keys:  UP/DOWN=switch file  E=edit  A=ask-AI  S=split-pane"
      echo "             F=new-file  G=git-commit  P=preview  ?=help  Ctrl+Q=quit"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN DISPATCHER
# ════════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN DISPATCHER v2.3.5
# ════════════════════════════════════════════════════════════════════════════════
show_help() {
  local W="${B}${BWHITE}" C1="${B}${BCYAN}" C2="${BCYAN}" DM="${DIM}" R_="${R}"

  # ── Banner ──────────────────────────────────────────────────────────────────
  echo -e ""
  echo -e "${W}╔══════════════════════════════════════════════════════════════════╗${R_}"
  echo -e "${W}║  AI CLI  v${VERSION} — Universal AI Shell                        ║${R_}"
  echo -e "${W}║  Chat · Vision · Audio · Video · RLHF v2 · Fine-tune · Multi-AI ║${R_}"
  echo -e "${W}║  Aliases · ErrorCodes · GGUF-fix · ModelSync · 56 Rec Models    ║${R_}"
  echo -e "${W}║  v2.7.3: uninstall fix · GUI v5.2 · GGUF fix · alias cmd        ║${R_}"
  echo -e "${W}║          error codes · ask fix · 2x recommended · model sync    ║${R_}"
  echo -e "${W}╚══════════════════════════════════════════════════════════════════╝${R_}"
  echo -e "${DM}  Platform: $PLATFORM | CPU-only: $([[ $CPU_ONLY_MODE -eq 1 ]] && echo yes || echo no) | Python: ${PYTHON:-not found} | GPU arch: ${CUDA_ARCH:-0}${R_}"
  echo ""

  # ── Quick Start ─────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ QUICK START ────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai ask \"<question>\"            Ask anything"
  echo -e "${C2}│${R_}  ai -gui                         Launch TUI (mouse + keyboard)"
  echo -e "${C2}│${R_}  ai -aup                         Update to latest version"
  echo -e "${C2}│${R_}  ai install-deps                 Install Python/system deps"
  echo -e "${C2}│${R_}  ai install-deps --windows       Windows 10/WSL2 setup guide"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Conversation ────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ CHAT & CONVERSATION ────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai ask <prompt>                 Single-shot question"
  echo -e "${C2}│${R_}  ai chat                         Interactive chat  (Ctrl+C to exit)"
  echo -e "${C2}│${R_}  ai -C [name|auto] ask <q>       Named session, saved as JSONL"
  echo -e "${C2}│${R_}  ai code <prompt> [--run]        Generate + optionally execute code"
  echo -e "${C2}│${R_}  ai review <file>                Code review"
  echo -e "${C2}│${R_}  ai explain <file|text>          Explain anything"
  echo -e "${C2}│${R_}  ai summarize <file|->           Summarize"
  echo -e "${C2}│${R_}  ai translate <text> to <lang>   Translate"
  echo -e "${C2}│${R_}  ai pipe                         Pipe stdin to AI"
  echo -e "${C2}│${R_}  ai chat-list / chat-show / chat-delete"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Multi-AI ────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ MULTI-AI ARENA  (v2.4.5+) ─────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai multiai \"<topic>\"            Two AIs discuss"
  echo -e "${C2}│${R_}  ai multiai debate \"<topic>\"     Adversarial: opposing sides"
  echo -e "${C2}│${R_}  ai multiai collab \"<task>\"      Collaborative: build together"
  echo -e "${C2}│${R_}  ai multiai brainstorm \"<t>\"     Free-form idea generation"
  echo -e "${C2}│${R_}    --agents 2-4  --rounds N  --model1 X  --model2 Y"
  echo -e "${C2}│${R_}  ${DM}Controls: Enter=continue  s=steer  r 1-5=rate  p=pause  q=quit${R_}"
  echo -e "${C2}│${R_}  ${DM}Saves as dataset; rated exchanges → RLHF training${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Agent + Web ─────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ AGENT & WEB ────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai agent <task>                 Multi-step autonomous agent"
  echo -e "${C2}│${R_}    Tools: web_search  read_url  write_file  read_file"
  echo -e "${C2}│${R_}           run_code  run_bash  ask_user  calculate"
  echo -e "${C2}│${R_}  ai websearch <query>            Search + AI summary (DDG/Brave)"
  echo -e "${C2}│${R_}  ai config agent_max_steps N     Steps limit (default 10)"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Media ───────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ MEDIA ──────────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai audio  transcribe/tts/analyze/convert/extract/ask/play/info"
  echo -e "${C2}│${R_}  ai video  analyze/transcribe/caption/extract/trim/convert/ask"
  echo -e "${C2}│${R_}  ai vision ask/ocr/caption/compare"
  echo -e "${C2}│${R_}  ai imagine <prompt>             Image generation"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Trained Models ──────────────────────────────────────────────────────────
  echo -e "${C1}┌─ TRAINED MODELS  (TTM / MTM / Mtm — case-sensitive) ────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}TTM${R_}  ~179.35M   any GPU/CPU        ai ttm <cmd>"
  echo -e "${C2}│${R_}  ${B}MTM${R_}  ~0.61B     GTX 1080 fp16      ai mtm <cmd>"
  echo -e "${C2}│${R_}  ${B}Mtm${R_}  ~1.075B    RTX 2080+ bf16     ai Mtm <cmd>"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  Commands (all models):  pretrain  finetune  enable/disable"
  echo -e "${C2}│${R_}    train-now  upload  create-repo  status  load  set-custom1/2"
  echo -e "${C2}│${R_}  Shortcuts:  ai -TTM  ai -MTM  ai -Mtm"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  Pretraining datasets (6 std + 2 custom):"
  echo -e "${C2}│${R_}    TinyStories(6k)  CodeAlpaca(4k)  OpenOrca(3k)"
  echo -e "${C2}│${R_}    TheStack(3k)     FineWeb-Edu(4k)  Wikipedia-en(4k)"
  echo -e "${C2}│${R_}    + your custom HF ids or local paths"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── RLHF ────────────────────────────────────────────────────────────────────
  echo -e "${C1}┌─ RLHF — REINFORCEMENT LEARNING FROM HUMAN FEEDBACK ─────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}Auto-RLHF${R_}  (judge scores responses → DPO training)"
  echo -e "${C2}│${R_}  ai rlhf enable/disable          Toggle auto-RLHF"
  echo -e "${C2}│${R_}  ai rlhf judge <name>            Set judge: nix26 / qwen3+luth / qwen3+llama32"
  echo -e "${C2}│${R_}  ai rlhf download-judges         Download judge model(s)"
  echo -e "${C2}│${R_}  ai rlhf train [TTM|MTM|Mtm]     Run DPO on collected pairs"
  echo -e "${C2}│${R_}  ai rlhf threshold 0.6           Reward cutoff (default 0.6)"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}Manual RLHF${R_}  (rate 1-5 stars in chat, train on your ratings)"
  echo -e "${C2}│${R_}  ai rlhf rate                    Rate a response interactively"
  echo -e "${C2}│${R_}  ai rlhf train-on-ratings        Fine-tune on manual ratings"
  echo -e "${C2}│${R_}  ${DM}Press R after any AI response in chat to rate it${R_}"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}HF RLHF Datasets${R_}  (10 curated preference datasets)"
  echo -e "${C2}│${R_}  ai rlhf datasets                List available presets"
  echo -e "${C2}│${R_}  ai rlhf add-dataset <id>        Import: hh-rlhf / ultrafeedback /"
  echo -e "${C2}│${R_}    ${DM}orca-dpo / summarize / pku-safe / helpsteer2 / capybara / math-pref${R_}"
  echo -e "${C2}│${R_}  ai rlhf use-dataset <name>      Set active training source"
  echo -e "${C2}│${R_}  ai rlhf my-datasets             Show imported + pair counts"
  echo -e "${C2}│${R_}"
  echo -e "${C2}│${R_}  ${B}Alignment${R_}  (anti-hallucination, Qwen3-powered)"
  echo -e "${C2}│${R_}  ai rlhf align TTM|MTM|Mtm"
  echo -e "${C2}│${R_}  ai rlhf status / clear-pairs"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Right-Click AI ──────────────────────────────────────────────────────────
  echo -e "${C1}┌─ RIGHT-CLICK AI  (v2.4.6 — Linux system-wide) ─────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai rclick install               Install (auto-detects DE/WM)"
  echo -e "${C2}│${R_}  ai rclick keybind <combo>       Change shortcut (default: ${RCLICK_KEYBIND})"
  echo -e "${C2}│${R_}  ai rclick model <name>          Set VL model"
  echo -e "${C2}│${R_}  ai rclick download-model        Download VL model"
  echo -e "${C2}│${R_}  ai rclick test / status / uninstall"
  echo -e "${C2}│${R_}  ${DM}Supported: GNOME  KDE Plasma 5+6  XFCE  MATE  Cinnamon${R_}"
  echo -e "${C2}│${R_}  ${DM}           Openbox  LXDE  i3  sway  Hyprland  + xbindkeys${R_}"
  echo -e "${C2}│${R_}  VL models:  qwen3vl  lfm25vl  lfm25vl_gguf  custom"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Custom Datasets ─────────────────────────────────────────────────────────
  echo -e "${C1}┌─ CUSTOM DATASETS  (v2.4+) ───────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai dataset create/add/add-file/import-csv/generate"
  echo -e "${C2}│${R_}  ai dataset list/show/delete/export/push"
  echo -e "${C2}│${R_}  ai dataset from-chat [session]  Chat session → dataset"
  echo -e "${C2}│${R_}  ai dataset from-rlhf            RLHF ratings → dataset"
  echo -e "${C2}│${R_}  ai dataset generate <n> <topic> [N]  AI-generate synthetic pairs"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── LLM API + Key Hosting ───────────────────────────────────────────────────
  echo -e "${C1}┌─ LLM API SERVER + KEY HOSTING  (v2.4.5 — OpenAI-compatible) ────┐${R_}"
  echo -e "${C2}│${R_}  ai api start [--port 8080] [--public] [--key <token>]"
  echo -e "${C2}│${R_}  ai api stop / status / test / config"
  echo -e "${C2}│${R_}  ${B}Key hosting:${R_}  ai api key-gen [--label name] [--rate N/min]"
  echo -e "${C2}│${R_}    ai api keys list/revoke/show"
  echo -e "${C2}│${R_}    ai api share [--port 8080]   Start public multi-key server"
  echo -e "${C2}│${R_}  Endpoints:  POST /v1/chat/completions  POST /v1/completions"
  echo -e "${C2}│${R_}              GET  /v1/models            GET  /health"
  echo -e "${C2}│${R_}  ${DM}Works with: Open WebUI  LM Studio  SillyTavern  Chatbot UI${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Models + GUI + Settings ─────────────────────────────────────────────────
  echo -e "${C1}┌─ MODELS ─────────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai model <n>                  Set active model"
  echo -e "${C2}│${R_}  ai models                     List downloaded models (synced with recommended)"
  echo -e "${C2}│${R_}  ai download <hf-id>           Download from HuggingFace"
  echo -e "${C2}│${R_}  ai recommended [download N]   ${B}56 curated picks${R_} — marks ✓ downloaded"
  echo -e "${C2}│${R_}  ai search-models <q>          Search HuggingFace"
  echo -e "${C2}│${R_}  ai upload <path> <repo>       Upload to HuggingFace"
  echo -e "${C2}│${R_}  ai model-create new/train/list/presets/info/delete"
  echo -e "${C2}│${R_}  ai model-state save/restore   Persist across updates"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ ALIASES  (v2.7.3 — new) ────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai alias list                  List all your aliases"
  echo -e "${C2}│${R_}  ai alias set <name> <cmd>     Create alias (e.g. ai alias set q ask)"
  echo -e "${C2}│${R_}  ai alias del <name>           Delete alias"
  echo -e "${C2}│${R_}  ai alias show <name>          Show single alias definition"
  echo -e "${C2}│${R_}  ai alias help                 Full alias help"
  echo -e "${C2}│${R_}  ${DM}After setting: ai <alias> [args]  →  runs the mapped command${R_}"
  echo -e "${C2}│${R_}  ${DM}Example: ai alias set codepy \"code --lang python\"${R_}"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ GUI  (TUI — terminal, mouse + keyboard, v5.2) ──────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai -gui / ai gui                    Launch GUI"
  echo -e "${C2}│${R_}  Themes: dark  light  hacker  matrix  ocean  solarized  nord  gruvbox"
  echo -e "${C2}│${R_}  ai config gui_theme <theme>         Set default theme"
  echo -e "${C2}│${R_}  Chat commands: /web /agent /model /theme /rate  Ctrl+Q=exit"
  echo -e "${C2}│${R_}  ${B}v5.2 new:${R_}  Aliases panel, error codes panel, model sync indicator"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ SETTINGS ───────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai config [key value]            View/set config"
  echo -e "${C2}│${R_}    api_host / api_port / api_key / api_cors"
  echo -e "${C2}│${R_}    api_share_host / api_share_port / api_share_rate_limit"
  echo -e "${C2}│${R_}    multiai_rounds / multiai_save_dataset / multiai_rlhf_train"
  echo -e "${C2}│${R_}    rclick_keybind / cpu_only_mode"
  echo -e "${C2}│${R_}  ai keys [set KEY value]          Set API keys"
  echo -e "${C2}│${R_}  ai session list/new/load         Manage sessions"
  echo -e "${C2}│${R_}  ai persona list/set/create       Manage personas"
  echo -e "${C2}│${R_}  ai history [--search x]          View history"
  echo -e "${C2}│${R_}  ai status / bench / serve / install-deps"
  echo -e "${C2}│${R_}  ai -aup [--check-only|--force]   Auto-updater"
  echo -e "${C2}│${R_}  ai error-codes                   List all error codes"
  echo -e "${C2}│${R_}  sudo ai uninstall                Remove AI CLI (v2.7.3 fix)"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.5.5: New Features ────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.5.5 NEW FEATURES ────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}System Prompts:${R_}"
  echo -e "${C2}│${R_}    ai system set \"<prompt>\"       Apply prompt to ALL backends"
  echo -e "${C2}│${R_}    ai system save <name> \"<p>\"    Save named prompt to disk"
  echo -e "${C2}│${R_}    ai system load <name>          Load saved prompt"
  echo -e "${C2}│${R_}    ai system list                 List saved + active info"
  echo -e "${C2}│${R_}    ai system show                 Show current effective prompt"
  echo -e "${C2}│${R_}    ai system clear                Remove custom prompt"
  echo -e "${C2}│${R_}    ai system delete <name>        Delete saved prompt file"
  echo -e "${C2}│${R_}  ${B}Dataset AI-gen:${R_}"
  echo -e "${C2}│${R_}    ai dataset generate <n> <topic> [--count N] [--style qa|chat|instruct]"
  echo -e "${C2}│${R_}  ${B}Finetune Any:${R_}"
  echo -e "${C2}│${R_}    ai finetune any <hf-model-id>  LoRA fine-tune any model"
  echo -e "${C2}│${R_}      [--data file.jsonl] [--epochs N] [--merge] [--quantize Q4_K_M]"
  echo -e "${C2}│${R_}    Auto-selects LoRA target modules per architecture"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.5: New Features ──────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.5 NEW FEATURES ──────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}GitHub:${R_}     ai github commit/push/pull/pr/issue/clone/log"
  echo -e "${C2}│${R_}  ${B}Papers:${R_}     ai papers search \"<query>\" [--source arxiv|pmc|core]"
  echo -e "${C2}│${R_}             ai papers cite <N> [apa|mla|bibtex|ieee|chicago]"
  echo -e "${C2}│${R_}  ${B}Build:${R_}      ai build xz            Self-contained XZ bundle"
  echo -e "${C2}│${R_}  ${B}Multimodal:${R_} ai train-multimodal img-text-to-text <dataset>"
  echo -e "${C2}│${R_}             ai train-multimodal text-to-image <image-dir>"
  echo -e "${C2}│${R_}             ai train-multimodal image-to-text <dataset>"
  echo -e "${C2}│${R_}  ${B}RLHF v2:${R_}   ai rlhf-reward [model]  Train reward model"
  echo -e "${C2}│${R_}             ai rlhf-ppo [model]     PPO fine-tuning"
  echo -e "${C2}│${R_}             ai rlhf-grpo [model]    GRPO fine-tuning"
  echo -e "${C2}│${R_}  ${B}Dataset+:${R_}  ai dataset from-text <name> \"<text>\""
  echo -e "${C2}│${R_}             ai dataset from-url <name> <url>"
  echo -e "${C2}│${R_}             ai dataset from-file <name> <file>"
  echo -e "${C2}│${R_}             ai dataset from-paper <name> <arxiv-id>"
  echo -e "${C2}│${R_}  ${B}Canvas v2:${R_} ai canvas-v2 new/open/add/list/export/gist"
  echo -e "${C2}│${R_}             Multi-file · split-pane · git · AI assist · preview"
  echo -e "${C2}│${R_}  ${B}Image v2:${R_}  ai imagine2 \"<prompt>\" [txt2img|img2img|inpaint]"
  echo -e "${C2}│${R_}  ${B}Pacman:${R_}    ai install-deps  (auto-detects pacman/apt/dnf/brew)"
  echo -e "${C2}│${R_}  ${B}Models:${R_}    28 recommended models (2x from v2.4)"
  echo -e "${C2}│${R_}  ${B}KDE6:${R_}      D-Bus + kglobalaccel6 keybind support"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── v2.6: New Features ──────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.6 NEW FEATURES ──────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}Projects (multi-chat memory):${R_}"
  echo -e "${C2}│${R_}    ai project new <name> [desc]   Create project with persistent memory"
  echo -e "${C2}│${R_}    ai project list                List all projects"
  echo -e "${C2}│${R_}    ai project switch <name>       Switch to project"
  echo -e "${C2}│${R_}    ai project show [name]         Info + recent messages"
  echo -e "${C2}│${R_}    ai project memory [name]       Memory summary"
  echo -e "${C2}│${R_}    ai project delete / export / clear-memory"
  echo -e "${C2}│${R_}  ${B}GPU / CUDA:${R_}"
  echo -e "${C2}│${R_}    CUDA detection fixed: sm_61 (Pascal GTX 10xx) now recognized"
  echo -e "${C2}│${R_}    Arch cache: CUDA arch cached for fast startup (no slow detect every run)"
  echo -e "${C2}│${R_}    ai config cpu_only_mode 0      Force GPU mode"
  echo -e "${C2}│${R_}  ${B}Bug Fixes:${R_}"
  echo -e "${C2}│${R_}    TTM/PyTorch: auto-patches missing model_type in config.json"
  echo -e "${C2}│${R_}    rclick v3: trusted flag set → fixes 'not authorized' in file manager"
  echo -e "${C2}│${R_}    rclick v3.1: full action menu (Explain/Summarize/Fix/Rewrite/Bullets/…)"
  echo -e "${C2}│${R_}    rclick v3.1: fixed newlines, Python UI fallback, yad output parsing"
  echo -e "${C2}│${R_}    Unknown command: shows clear error before AI fallthrough"
  echo -e "${C2}│${R_}  ${B}First-run:${R_}  Model download + install-deps prompt on first use"
  echo -e "${C2}│${R_}  ${B}Right-click v3.1:${R_}  9 action types; auto-copies result to clipboard"
  echo -e "${C2}│${R_}  ${B}Startup speed:${R_}  CUDA arch cached → 5-10× faster startup"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  # ── Examples ────────────────────────────────────────────────────────────────
  # ── v2.7.1: New Features ──────────────────────────────────────────────────────
  echo -e "${C1}┌─ v2.7 / v2.7.1 NEW FEATURES ────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ${B}GUI v5.1 (v2.7.1 update):${R_}"
  echo -e "${C2}│${R_}    Structured settings editor: only editable keys shown"
  echo -e "${C2}│${R_}    Edit individual settings inline with Enter, saved via ai config"
  echo -e "${C2}│${R_}  ${B}GUI v5 (v2.7):${R_}"
  echo -e "${C2}│${R_}    Split-pane layout: sidebar + content panel"
  echo -e "${C2}│${R_}    Edit-on-click / Enter: items open inline editors"
  echo -e "${C2}│${R_}    New themes: dracula + all v2.6 themes"
  echo -e "${C2}│${R_}    / quick-search to filter menu items"
  echo -e "${C2}│${R_}    F5 refresh, Tab to switch focus sidebar↔content"
  echo -e "${C2}│${R_}  ${B}AI Extension System (.aipack):${R_}"
  echo -e "${C2}│${R_}    ai extension create <name>    Scaffold new extension"
  echo -e "${C2}│${R_}    ai extension load <file>      Load from .aipack file"
  echo -e "${C2}│${R_}    ai extension locate           Show all + file paths + status"
  echo -e "${C2}│${R_}    ai extension package <name>   Build distributable .aipack"
  echo -e "${C2}│${R_}    ai extension edit <name>      Open editor for extension files"
  echo -e "${C2}│${R_}    ai extension run <name>       Execute an extension"
  echo -e "${C2}│${R_}    .aipack: gzip tar with ex.sh + main.py + manifest.json"
  echo -e "${C2}│${R_}  ${B}Firefox LLM Sidebar:${R_}"
  echo -e "${C2}│${R_}    ai install-firefox-ext        Build & install Firefox extension"
  echo -e "${C2}│${R_}    Connects to local AI CLI API server (ai api start)"
  echo -e "${C2}│${R_}    v2.7.1: fixed AI output (non-streaming JSON response)"
  echo -e "${C2}│${R_}    Full settings: API URL, model, max tokens, temperature"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""

  echo -e "${C1}┌─ EXAMPLES ───────────────────────────────────────────────────────┐${R_}"
  echo -e "${C2}│${R_}  ai -aup                               # Update to latest"
  echo -e "${C2}│${R_}  ai project new mywork \"Work chats\"    # Create project with memory"
  echo -e "${C2}│${R_}  ai project switch mywork              # Switch to project"
  echo -e "${C2}│${R_}  ai ask \"continue from where we left off\"  # Uses project memory"
  echo -e "${C2}│${R_}  ai project memory                    # Show what AI remembers"
  echo -e "${C2}│${R_}  ai system set \"You are a senior Python dev.\""
  echo -e "${C2}│${R_}  ai dataset generate mydata \"Python async patterns\" --count 50"
  echo -e "${C2}│${R_}  ai finetune any mistralai/Mistral-7B-v0.1 --epochs 2 --merge"
  echo -e "${C2}│${R_}  ai ttm pretrain                       # Pretrain tiny model (179M)"
  echo -e "${C2}│${R_}  ai rlhf train TTM                     # DPO training"
  echo -e "${C2}│${R_}  ai extension create myplugin          # New extension"
  echo -e "${C2}│${R_}  ai extension package myplugin         # → myplugin-1.0.0.aipack"
  echo -e "${C2}│${R_}  ai extension load myplugin-1.0.0.aipack  # Install extension"
  echo -e "${C2}│${R_}  ai install-firefox-ext                # Build Firefox LLM sidebar"
  echo -e "${C2}│${R_}  ai api start                          # Start local LLM API server"
  echo -e "${C2}│${R_}  ai api stop                           # Stop local LLM API server"
  echo -e "${C1}└──────────────────────────────────────────────────────────────────┘${R_}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.7: AI EXTENSION SYSTEM — create · load · locate · package · edit · help
# ════════════════════════════════════════════════════════════════════════════════
# .aipack format: gzip'd tar containing
#   manifest.json   — name, version, description, entry
#   ex.sh           — bash entry point (sourced or executed)
#   main.py         — Python script
#   [any other assets]
# ════════════════════════════════════════════════════════════════════════════════

