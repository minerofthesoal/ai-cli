# ============================================================================
# MODULE: 08-rclick.sh
# Right-click system-wide 'Ask AI' context menu
# Source lines 2235-3408 of main-v2.7.3
# ============================================================================

# ════════════════════════════════════════════════════════════════════════════════
#  RIGHT-CLICK CONTEXT MENU — Linux system-wide "Ask AI" integration  (v2.4.6)
#  Works on: GNOME, KDE Plasma 5/6, XFCE, LXDE, MATE, Cinnamon, Openbox,
#            i3, sway, Hyprland, river, dwm, any WM/DE
#  Grabs selected text (X11 primary / Wayland / clipboard), sends to AI,
#  shows result in best available display method.
#  Custom keybind support: ai rclick keybind <key-combo>
# ════════════════════════════════════════════════════════════════════════════════

# Vision-Language model options for right-click
declare -A RCLICK_VL_MODELS
RCLICK_VL_MODELS=(
  [qwen3vl]="Qwen/Qwen3-VL-2B-Thinking-GGUF|Qwen3-VL-2B-Thinking-Q4_K_M.gguf|Qwen3 VL 2B Thinking — best reasoning"
  [lfm25vl]="LiquidAI/LFM2.5-VL-1.6B|model.safetensors|LFM2.5 VL 1.6B (PyTorch)"
  [lfm25vl_gguf]="LiquidAI/LFM2.5-VL-1.6B-GGUF|lfm2.5-vl-1.6b-q4_k_m.gguf|LFM2.5 VL 1.6B GGUF — fast"
  [custom]="custom||Custom model (set RCLICK_CUSTOM_MODEL)"
)

# Default keybind — user can change via: ai rclick keybind <combo>
RCLICK_KEYBIND="${RCLICK_KEYBIND:-Super+Shift+a}"

_rclick_install_deps() {
  info "Installing right-click context menu dependencies..."
  local pkgs=()
  # Detect display server: Wayland or X11
  local is_wayland=0
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=1
  [[ -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && is_wayland=1

  if command -v apt-get &>/dev/null; then
    pkgs=(libnotify-bin xdg-utils python3-tk)
    if [[ $is_wayland -eq 1 ]]; then
      pkgs+=(wl-clipboard)
      # Try to get ydotool for Wayland input simulation
      command -v ydotool &>/dev/null || pkgs+=(ydotool) 2>/dev/null || true
    else
      pkgs+=(xdotool xclip xsel zenity)
      command -v python3 &>/dev/null && pkgs+=(python3-tkinter python3-gi)
    fi
    sudo apt-get install -y -q "${pkgs[@]}" 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    if [[ $is_wayland -eq 1 ]]; then
      sudo dnf install -y libnotify wl-clipboard python3-tkinter 2>/dev/null || true
    else
      sudo dnf install -y xdotool xclip xsel libnotify zenity python3-tkinter 2>/dev/null || true
    fi
  elif command -v pacman &>/dev/null; then
    if [[ $is_wayland -eq 1 ]]; then
      sudo pacman -S --noconfirm libnotify wl-clipboard tk 2>/dev/null || true
    else
      sudo pacman -S --noconfirm xdotool xclip xsel libnotify zenity tk 2>/dev/null || true
    fi
  elif command -v zypper &>/dev/null; then
    sudo zypper install -y xdotool xclip libnotify-tools zenity python3-tk 2>/dev/null || true
  fi
  ok "Dependencies installed"
}

_rclick_get_selection() {
  # Robust text retrieval: Wayland primary → X11 primary → clipboard
  local text=""
  # Wayland
  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-paste &>/dev/null && text=$(wl-paste --primary --no-newline 2>/dev/null || true)
    [[ -z "$text" ]] && command -v wl-paste &>/dev/null && text=$(wl-paste --no-newline 2>/dev/null || true)
  fi
  # X11 primary (highlighted text)
  if [[ -z "$text" ]]; then
    command -v xclip &>/dev/null && text=$(xclip -selection primary -o 2>/dev/null || true)
    [[ -z "$text" ]] && command -v xsel &>/dev/null && text=$(xsel --primary --output 2>/dev/null || true)
  fi
  # Clipboard fallback
  if [[ -z "$text" ]]; then
    command -v xclip  &>/dev/null && text=$(xclip -selection clipboard -o 2>/dev/null || true)
    [[ -z "$text" ]] && command -v xsel     &>/dev/null && text=$(xsel --clipboard --output 2>/dev/null || true)
    [[ -z "$text" ]] && command -v wl-paste &>/dev/null && text=$(wl-paste --no-newline 2>/dev/null || true)
  fi
  echo "${text:0:4000}"
}

# Convert user-friendly key combo to gsettings format
# e.g. "Super+Shift+a" → "<Super><Shift>a"
_rclick_key_to_gsettings() {
  local key="$1"
  local out=""
  IFS='+' read -ra parts <<< "$key"
  local last="${parts[-1]}"
  for (( i=0; i<${#parts[@]}-1; i++ )); do
    local mod="${parts[$i]}"
    case "${mod,,}" in
      super|win|meta) out+="<Super>" ;;
      ctrl|control)   out+="<Ctrl>"  ;;
      alt)            out+="<Alt>"   ;;
      shift)          out+="<Shift>" ;;
      *)              out+="<${mod}>" ;;
    esac
  done
  out+="${last,,}"
  echo "$out"
}

# Convert user-friendly key combo to sway/i3 bindsym format
# e.g. "Super+Shift+a" → "$mod+Shift+a"  (or "Ctrl+Shift+a" stays as-is)
_rclick_key_to_sway() {
  local key="$1"
  # Replace Super/Win with $mod
  echo "$key" | sed 's/Super/$mod/Ig;s/Win/$mod/Ig'
}

# Write the ai-rclick script to /usr/local/bin/ai-rclick  (v3.1 — v2.7.1)
# Fixes: build_prompt newlines (printf), Python show_result heredoc, yad parsing,
#        cleaner output, new actions (Rewrite, To bullet points, Copy result).
_rclick_write_script() {
  local script_path="/usr/local/bin/ai-rclick"
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "ai")
  local vl_model="${RCLICK_VL_MODEL:-qwen3vl}"
  local vl_dir="$MODELS_DIR/rclick_vl"

  cat > /tmp/ai_rclick_v3.1.sh << RCLICK_SCRIPT
#!/usr/bin/env bash
# AI Right-Click Handler v3.1 — installed by ai-cli v2.7.1
# Fixes: newline handling, Python UI fallback, yad output, cleaner results
# New: Rewrite, To bullet points, Copy to clipboard action
# Supports: X11, Wayland, all major DEs/WMs
CLI_BIN="${cli_bin}"
VL_MODEL_DIR="${vl_dir}"
VL_TYPE="${vl_model}"

# ── Copy text to clipboard ─────────────────────────────────────────────────────
copy_to_clipboard() {
  local text="\$1"
  if [[ -n "\${WAYLAND_DISPLAY:-}" || -n "\${SWAYSOCK:-}" || -n "\${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-copy &>/dev/null && echo "\$text" | wl-copy 2>/dev/null && return
  fi
  command -v xclip  &>/dev/null && echo "\$text" | xclip -selection clipboard 2>/dev/null && return
  command -v xsel   &>/dev/null && echo "\$text" | xsel --clipboard --input 2>/dev/null && return
}

# ── Get selected text (X11 primary / Wayland / clipboard) ─────────────────────
get_text() {
  local t=""
  # Wayland primary selection
  if [[ -n "\${WAYLAND_DISPLAY:-}" || -n "\${SWAYSOCK:-}" || -n "\${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    command -v wl-paste &>/dev/null && t=\$(wl-paste --primary --no-newline 2>/dev/null || true)
  fi
  # X11 primary (highlighted text — most reliable for "select then trigger")
  if [[ -z "\$t" ]]; then
    command -v xclip &>/dev/null && t=\$(xclip -selection primary -o 2>/dev/null || true)
    [[ -z "\$t" ]] && command -v xsel &>/dev/null && t=\$(xsel --primary --output 2>/dev/null || true)
  fi
  # Clipboard fallback
  if [[ -z "\$t" ]]; then
    command -v xclip  &>/dev/null && t=\$(xclip -selection clipboard -o 2>/dev/null || true)
    [[ -z "\$t" ]] && command -v xsel     &>/dev/null && t=\$(xsel --clipboard --output 2>/dev/null || true)
    [[ -z "\$t" ]] && command -v wl-paste &>/dev/null && t=\$(wl-paste --no-newline 2>/dev/null || true)
  fi
  echo "\${t:0:4000}"
}

# ── Show result in best available UI ──────────────────────────────────────────
# v3.1 fix: Python fallback now writes code to temp file (heredoc-to-stdin was broken)
show_result() {
  local title="\$1" body="\$2" tmp
  tmp=\$(mktemp /tmp/ai_result_XXXXX.txt)
  printf '%s\n' "\$body" > "\$tmp"
  # Always save last result for recovery
  cp "\$tmp" /tmp/ai_rclick_last_result.txt

  if command -v zenity &>/dev/null; then
    zenity --text-info --title="\$title" --filename="\$tmp" \
           --width=760 --height=520 --font="Monospace 10" 2>/dev/null &
  elif command -v kdialog &>/dev/null; then
    kdialog --title "\$title" --textbox "\$tmp" 760 520 2>/dev/null &
  elif command -v yad &>/dev/null; then
    yad --text-info --filename="\$tmp" --title="\$title" \
        --width=760 --height=520 --wrap --button=Close:0 2>/dev/null &
  elif command -v xmessage &>/dev/null; then
    xmessage -file "\$tmp" -title "\$title" -buttons OK 2>/dev/null &
  elif command -v python3 &>/dev/null; then
    # v3.1 fix: write Python UI code to a temp file (heredoc-to-stdin broken with &)
    local _py_tmp; _py_tmp=\$(mktemp /tmp/ai_rclick_ui_XXXX.py)
    cat > "\$_py_tmp" << 'INNER_PYEOF'
import sys, pathlib, tkinter as tk
from tkinter import scrolledtext, font as tkfont
title_arg = sys.argv[1] if len(sys.argv) > 1 else "AI Result"
file_arg  = sys.argv[2] if len(sys.argv) > 2 else ""
root = tk.Tk()
root.title(title_arg)
root.geometry("820x560")
root.configure(bg='#1a1b26')
try:
    mf = tkfont.Font(family="Monospace", size=10)
except Exception:
    mf = None
txt = scrolledtext.ScrolledText(root, wrap=tk.WORD, font=mf,
    padx=10, pady=10, bg='#16161e', fg='#c0caf5',
    insertbackground='#7aa2f7', relief='flat')
txt.pack(fill='both', expand=True, padx=4, pady=4)
content = pathlib.Path(file_arg).read_text(errors='replace') if file_arg else ""
txt.insert('1.0', content)
txt.config(state='disabled')
btn_frame = tk.Frame(root, bg='#1a1b26'); btn_frame.pack(fill='x', pady=4, padx=4)
def do_copy():
    root.clipboard_clear()
    root.clipboard_append(txt.get('1.0', 'end-1c'))
    root.update()
tk.Button(btn_frame, text='Copy to Clipboard', command=do_copy,
    bg='#7aa2f7', fg='#1a1b26', relief='flat', padx=8).pack(side='left', padx=4)
tk.Button(btn_frame, text='Close', command=root.destroy,
    bg='#292e42', fg='#c0caf5', relief='flat', padx=8).pack(side='right', padx=4)
root.mainloop()
INNER_PYEOF
    python3 "\$_py_tmp" "\$title" "\$tmp" &
    (sleep 120 && rm -f "\$_py_tmp") &
  elif command -v foot &>/dev/null; then
    foot -e bash -c "cat '\$tmp'; echo; printf 'Press Enter to close...'; read -r _" &
  elif command -v alacritty &>/dev/null; then
    alacritty -e bash -c "cat '\$tmp'; echo; printf 'Press Enter to close...'; read -r _" &
  elif command -v xterm &>/dev/null; then
    xterm -title "\$title" -e "cat '\$tmp'; printf 'Press Enter...'; read -r _" &
  else
    # Last resort: notification + file
    notify-send "\$title" "\${body:0:300}..." -t 20000 -i dialog-information 2>/dev/null || true
    echo "Full result saved: /tmp/ai_rclick_last_result.txt"
  fi
  # Cleanup after 90 s
  (sleep 90 && rm -f "\$tmp") &
}

# ── Action menu (v3.1) ────────────────────────────────────────────────────────
choose_action() {
  local ctx="\${1:0:80}"
  local has_files="\${2:-0}"
  local action=""

  # Full action list — new in v3.1: Rewrite, Bullet points, To JSON
  local opts=(
    "Explain this"
    "Summarize"
    "Fix code / errors"
    "Find bugs"
    "Generate tests"
    "Rewrite / improve"
    "Improve writing"
    "Translate to English"
    "To bullet points"
    "Ask a question..."
  )
  [[ "\$has_files" == "1" ]] && opts+=("Analyze file(s)" "Summarize file(s)")

  if command -v zenity &>/dev/null; then
    local list_args=()
    for o in "\${opts[@]}"; do list_args+=(FALSE "\$o"); done
    action=\$(zenity --list --radiolist \
      --title="AI Right-Click v3.1" \
      --text="Context: \${ctx:0:60}...\n\nChoose an action:" \
      --column="" --column="Action" \
      "\${list_args[@]}" --width=440 --height=440 2>/dev/null) || return 1
  elif command -v kdialog &>/dev/null; then
    local menu_args=()
    local i=1
    for o in "\${opts[@]}"; do menu_args+=("\$i" "\$o"); ((i++)); done
    local choice
    choice=\$(kdialog --menu "AI: \${ctx:0:60}..." "\${menu_args[@]}" 2>/dev/null) || return 1
    action="\${opts[\$((choice-1))]}"
  elif command -v yad &>/dev/null; then
    # v3.1 fix: use --print-column=2 to avoid column-header/FALSE prefix in output
    local yad_rows=()
    for o in "\${opts[@]}"; do yad_rows+=(FALSE "\$o"); done
    action=\$(yad --list --radiolist \
      --title="AI Right-Click v3.1" \
      --text="Context: \${ctx:0:60}..." \
      --column="●" --column="Action" \
      --print-column=2 \
      "\${yad_rows[@]}" \
      --width=400 --height=400 2>/dev/null | sed 's/|//g' | tr -d '\n') || return 1
  elif command -v python3 &>/dev/null; then
    # v3.1 fix: write Python picker to temp file (heredoc-to-stdin broken with &)
    local _py_pick; _py_pick=\$(mktemp /tmp/ai_rclick_pick_XXXX.py)
    cat > "\$_py_pick" << 'INNER_PYEOF'
import sys, tkinter as tk
ctx  = sys.argv[1] if len(sys.argv) > 1 else ""
opts = sys.argv[2:]
root = tk.Tk()
root.title("AI Right-Click v3.1")
root.geometry("420x480")
root.configure(bg='#1a1b26')
tk.Label(root, text=f"Context: {ctx[:70]}...",
    wraplength=400, justify='left', bg='#1a1b26', fg='#c0caf5',
    font=('', 9)).pack(padx=10, pady=(8,2), anchor='w')
tk.Label(root, text="Choose action:", font=('', 10, 'bold'),
    bg='#1a1b26', fg='#7aa2f7').pack(padx=10, anchor='w')
frame = tk.Frame(root, bg='#16161e'); frame.pack(fill='both', expand=True, padx=8, pady=4)
result = tk.StringVar(value=opts[0] if opts else "")
for o in opts:
    tk.Radiobutton(frame, text=o, variable=result, value=o,
        anchor='w', bg='#16161e', fg='#c0caf5',
        selectcolor='#283457', activebackground='#1f2335',
        font=('', 10)).pack(fill='x', padx=4, pady=1)
chosen = []
def ok():
    v = result.get()
    if v: chosen.append(v)
    root.destroy()
bf = tk.Frame(root, bg='#1a1b26'); bf.pack(pady=6)
tk.Button(bf, text='OK', width=12, command=ok,
    bg='#7aa2f7', fg='#1a1b26', relief='flat').pack(side='left', padx=4)
tk.Button(bf, text='Cancel', width=12, command=root.destroy,
    bg='#292e42', fg='#c0caf5', relief='flat').pack(side='left', padx=4)
root.bind('<Return>', lambda e: ok())
root.bind('<Escape>', lambda e: root.destroy())
root.mainloop()
if chosen: print(chosen[0])
INNER_PYEOF
    action=\$(python3 "\$_py_pick" "\$ctx" "\${opts[@]}" 2>/dev/null) || { rm -f "\$_py_pick"; return 1; }
    rm -f "\$_py_pick"
  else
    action="Explain this"  # headless fallback
  fi
  [[ -z "\$action" ]] && return 1
  echo "\$action"
}

# ── Custom question input ─────────────────────────────────────────────────────
ask_custom_question() {
  local ctx="\${1:0:100}"
  local q=""
  if command -v zenity &>/dev/null; then
    q=\$(zenity --entry --title="Ask AI" \
      --text="Context: \${ctx:0:60}...\n\nYour question:" --width=520 2>/dev/null) || return 1
  elif command -v kdialog &>/dev/null; then
    q=\$(kdialog --title "Ask AI" --inputbox "Your question about: \${ctx:0:60}..." "" 2>/dev/null) || return 1
  elif command -v python3 &>/dev/null; then
    local _py_ask; _py_ask=\$(mktemp /tmp/ai_rclick_ask_XXXX.py)
    cat > "\$_py_ask" << 'INNER_PYEOF'
import sys, tkinter as tk
from tkinter import simpledialog
ctx = sys.argv[1] if len(sys.argv) > 1 else ""
root = tk.Tk(); root.withdraw()
q = simpledialog.askstring('Ask AI',
    f'Context: {ctx[:60]}...\n\nYour question:',
    parent=root)
print(q or '')
INNER_PYEOF
    q=\$(python3 "\$_py_ask" "\$ctx" 2>/dev/null); rm -f "\$_py_ask"
    q=\$(echo "\$q" | tr -d '\r')
  else
    q="Explain this"
  fi
  [[ -z "\$q" ]] && return 1
  echo "\$q"
}

# ── Build AI prompt from action + context ─────────────────────────────────────
# v3.1 fix: use printf for proper newline handling (echo doesn't interpolate \n)
build_prompt() {
  local action="\$1"
  local context="\$2"
  local files="\$3"
  case "\$action" in
    "Explain this")
      printf 'Explain the following clearly and concisely:\n\n%s\n' "\$context" ;;
    "Summarize")
      printf 'Summarize the following in a few sentences:\n\n%s\n' "\$context" ;;
    "Fix code / errors")
      printf 'Fix any bugs or errors in the following code. Show the corrected version with an explanation of changes:\n\n%s\n' "\$context" ;;
    "Find bugs")
      printf 'Identify all bugs, issues, and potential problems in the following code. Be specific:\n\n%s\n' "\$context" ;;
    "Generate tests")
      printf 'Generate comprehensive unit tests for the following code:\n\n%s\n' "\$context" ;;
    "Rewrite / improve")
      printf 'Rewrite and improve the following code or text. Make it cleaner, more efficient, and well-structured:\n\n%s\n' "\$context" ;;
    "Improve writing")
      printf 'Improve the clarity, grammar, and style of the following text:\n\n%s\n' "\$context" ;;
    "Translate to English")
      printf 'Translate the following to English:\n\n%s\n' "\$context" ;;
    "To bullet points")
      printf 'Convert the following into clear, concise bullet points:\n\n%s\n' "\$context" ;;
    "Analyze file(s)")
      printf 'Analyze the following file(s) and provide insights:\n\nContext: %s\n\nFiles: %s\n' "\$context" "\$files" ;;
    "Summarize file(s)")
      printf 'Summarize the content of the following file(s):\n\nContext: %s\n\nFiles: %s\n' "\$context" "\$files" ;;
    *)
      printf '%s\n\nContext:\n%s\n' "\$action" "\$context" ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local files_str=""
  local has_files=0
  if [[ \$# -gt 0 ]]; then
    files_str="\$*"
    has_files=1
  fi

  local selected; selected=\$(get_text)

  # If no text selected but files given, use first filename as context
  if [[ -z "\$selected" && \$has_files -eq 1 ]]; then
    selected="\$1"
  fi

  if [[ -z "\$selected" && \$has_files -eq 0 ]]; then
    notify-send "AI Right-Click v3.1" \
      "No text selected and no files passed. Highlight text first, then press the shortcut." \
      -t 6000 -i dialog-information 2>/dev/null || \
      { echo "ai-rclick: no text selected" >&2; }
    exit 0
  fi

  local action
  action=\$(choose_action "\$selected" "\$has_files") || exit 0
  [[ -z "\$action" ]] && exit 0

  local full_prompt
  if [[ "\$action" == "Ask a question..." ]]; then
    local custom_q
    custom_q=\$(ask_custom_question "\$selected") || exit 0
    full_prompt=\$(printf '%s\n\nContext:\n%s\n' "\$custom_q" "\$selected")
  else
    full_prompt=\$(build_prompt "\$action" "\$selected" "\$files_str")
    # Include file contents for file actions (v3.1: safer wc -c check)
    if [[ \$has_files -eq 1 && "\$action" == *"file"* ]]; then
      for f in "\$@"; do
        if [[ -f "\$f" ]]; then
          local fsz; fsz=\$(wc -c < "\$f" 2>/dev/null || echo 0)
          if (( fsz < 8192 )); then
            full_prompt+=\$(printf '\n\n--- %s ---\n' "\$f")
            full_prompt+=\$(head -100 "\$f" 2>/dev/null)
          fi
        fi
      done
    fi
  fi

  notify-send "AI Right-Click v3.1" "Processing: \${action}..." \
    -t 3000 -i dialog-information 2>/dev/null || true

  local result
  result=\$("\$CLI_BIN" ask "\$full_prompt" 2>&1)
  # v3.1: strip leading/trailing blank lines from result for cleaner output
  result=\$(echo "\$result" | sed '/^[[:space:]]*\$/{ /./!d; }' | sed -e '1{/^$/d}' 2>/dev/null || echo "\$result")

  if [[ -z "\$result" ]]; then
    result="[No response — is 'ai' installed and a model configured?]
Run: ai status   to check your setup.
Run: ai ask 'hello'  to test."
  fi

  # Offer to copy result to clipboard before showing dialog
  copy_to_clipboard "\$result" 2>/dev/null || true

  show_result "AI — \${action}" "\$result"
}

main "\$@"
RCLICK_SCRIPT

  sudo cp /tmp/ai_rclick_v3.1.sh "$script_path"
  sudo chmod a+x "$script_path"
  # v2.6.0.1: Multi-method trust marking — fixes 'not authorized to execute' in file managers
  # Method 1: GIO metadata::trusted (GNOME 42+ Nautilus — must use -t string and "yes")
  if command -v gio &>/dev/null; then
    sudo gio set -t string "$script_path" metadata::trusted yes 2>/dev/null || \
      sudo gio set "$script_path" metadata::trusted true 2>/dev/null || true
  fi
  # Method 2: setfattr / attr (xattr fallback for older GNOME or non-gio systems)
  command -v setfattr &>/dev/null && \
    sudo setfattr -n user.nautilus-trusted -v "" "$script_path" 2>/dev/null || true
  command -v attr &>/dev/null && \
    sudo attr -s "user.nautilus-trusted" -V "" "$script_path" 2>/dev/null || true
  rm -f /tmp/ai_rclick_v3.1.sh
  ok "Installed: $script_path (rclick v3.1, trust flags set)"
}

_rclick_download_vl() {
  local vl="${RCLICK_VL_MODEL:-qwen3vl}"
  local vl_dir="$MODELS_DIR/rclick_vl"
  mkdir -p "$vl_dir"

  local entry="${RCLICK_VL_MODELS[$vl]:-${RCLICK_VL_MODELS[qwen3vl]}}"
  IFS='|' read -r repo filename desc <<< "$entry"
  [[ "$repo" == "custom" ]] && { err "Set RCLICK_CUSTOM_MODEL first"; return 1; }
  [[ -z "$filename" ]] && { err "No filename for $vl"; return 1; }

  if [[ "$filename" == *.gguf ]]; then
    local dest="$vl_dir/$filename"
    [[ -f "$dest" ]] && { ok "Already present: $filename"; return; }
    info "Downloading $desc..."
    curl -L --retry 5 --progress-bar \
      ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
      "https://huggingface.co/${repo}/resolve/main/${filename}" \
      -o "$dest"
    ok "Downloaded: $dest"
  else
    [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
    info "Downloading PyTorch model: $desc..."
    HF_REPO="$repo" DEST="$vl_dir" HF_TOKEN_VAL="${HF_TOKEN:-}" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("huggingface_hub not installed. Run: pip install huggingface_hub"); sys.exit(1)
snapshot_download(repo_id=os.environ['HF_REPO'],
                  local_dir=os.environ['DEST'],
                  token=os.environ.get('HF_TOKEN_VAL') or None)
print(f"Downloaded to {os.environ['DEST']}")
PYEOF
  fi
}

# ── DE-specific integrations ───────────────────────────────────────────────────

_rclick_install_gnome() {
  local keybind_gs; keybind_gs=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
  info "Installing GNOME Nautilus right-click actions (v3.1)..."
  mkdir -p "$HOME/.local/share/nautilus/scripts"
  local cli_full; cli_full=$(command -v ai 2>/dev/null || echo "/usr/local/bin/ai")

  # v2.6: Use full path and generate multiple action scripts
  for action_name in "Ask AI" "Summarize" "Explain this" "Fix code" "Find bugs" "Rewrite" "Improve writing" "To bullet points" "Translate to English"; do
    local action_file="$HOME/.local/share/nautilus/scripts/${action_name}"
    printf '#!/usr/bin/env bash\n/usr/local/bin/ai-rclick "$@"\n' > "$action_file"
    chmod a+x "$action_file"
    # v2.6.0.1: Mark as trusted — fixes 'not authorized to execute' in GNOME/Nautilus
    # Must use -t string and "yes" for GNOME 42+; fall back to xattr/attr methods
    if command -v gio &>/dev/null; then
      gio set -t string "$action_file" metadata::trusted yes 2>/dev/null || \
        gio set "$action_file" metadata::trusted true 2>/dev/null || true
    fi
    command -v setfattr &>/dev/null && \
      setfattr -n user.nautilus-trusted -v "" "$action_file" 2>/dev/null || true
    command -v attr &>/dev/null && \
      attr -s "user.nautilus-trusted" -V "" "$action_file" 2>/dev/null || true
  done
  ok "GNOME Nautilus: Scripts menu → AI actions (right-click Scripts)"

  # Also register with Files/Nemo (Cinnamon)
  if [[ -d "$HOME/.local/share/nemo/scripts" ]]; then
    for action_name in "Ask AI" "Summarize" "Explain this" "Fix code"; do
      local nemo_file="$HOME/.local/share/nemo/scripts/${action_name}"
      cp "$HOME/.local/share/nautilus/scripts/${action_name}" "$nemo_file" 2>/dev/null || true
      chmod a+x "$nemo_file" 2>/dev/null || true
      if command -v gio &>/dev/null; then
        gio set -t string "$nemo_file" metadata::trusted yes 2>/dev/null || true
      fi
    done
    ok "Cinnamon Nemo: Scripts menu → AI actions"
  fi

  info "Installing GNOME Shell keyboard shortcut ($RCLICK_KEYBIND)..."
  local base="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick"
  # Append to existing custom-keybindings list (don't overwrite others)
  local cur_list
  cur_list=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")
  if [[ "$cur_list" != *"ai-rclick"* ]]; then
    local new_list="${cur_list%']'},'${base}/']"
    new_list="${new_list/\[@as \[/[}"
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
      "$new_list" 2>/dev/null || \
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
      "['${base}/']" 2>/dev/null || true
  fi
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    name "Ask AI" 2>/dev/null || true
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    command "ai-rclick" 2>/dev/null || true
  gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${base}/" \
    binding "$keybind_gs" 2>/dev/null || true
  ok "GNOME shortcut: $RCLICK_KEYBIND → ai-rclick"
}

_rclick_install_kde() {
  # Detect Plasma version
  local plasma_ver=5
  command -v kwriteconfig6 &>/dev/null && plasma_ver=6
  plasmashell --version 2>/dev/null | grep -q "^plasmashell 6" && plasma_ver=6

  info "Installing KDE Dolphin right-click service menu (Plasma $plasma_ver)..."

  # Plasma 5 service menu path
  local p5="$HOME/.local/share/kservices5/ServiceMenus"
  # Plasma 6 service menu path (KIO servicemenus)
  local p6="$HOME/.local/share/kio/servicemenus"
  mkdir -p "$p5" "$p6"

  # Write .desktop for Plasma 5 (KonqPopupMenu/Plugin style) — v3.1 with more actions
  # v2.6.0.1: Added X-KDE-SubstituteUID=false to prevent KDE auth dialog
  cat > "$p5/ai-rclick.desktop" <<'DESK5'
[Desktop Entry]
Type=Service
ServiceTypes=KonqPopupMenu/Plugin
MimeType=all/all;
Actions=ask_ai;summarize;explain;fix_code;find_bugs;rewrite;improve;bullets;translate
X-KDE-StartupNotify=false
X-KDE-Priority=TopLevel
X-KDE-Submenu=AI Tools (v3.1)
X-KDE-SubstituteUID=false

[Desktop Action ask_ai]
Name=Ask AI...
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action summarize]
Name=Summarize
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action explain]
Name=Explain this
Icon=help-contextual
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action fix_code]
Name=Fix code / errors
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action find_bugs]
Name=Find bugs
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action rewrite]
Name=Rewrite / improve
Icon=document-edit
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action improve]
Name=Improve writing
Icon=accessories-text-editor
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action bullets]
Name=To bullet points
Icon=format-list-unordered
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action translate]
Name=Translate to English
Icon=applications-education-language
Exec=/usr/local/bin/ai-rclick %F
DESK5
  chmod a+x "$p5/ai-rclick.desktop" 2>/dev/null || true

  # Write .desktop for Plasma 6 (KIO servicemenu style — Actions= format) — v3.1
  # v2.6.0.1: Added X-KDE-SubstituteUID=false to prevent KDE auth dialog
  cat > "$p6/ai-rclick.desktop" <<'DESK6'
[Desktop Entry]
Type=Service
MimeType=all/all;
Actions=ask_ai;summarize;explain;fix_code;find_bugs;rewrite;improve;bullets;translate
X-KDE-Submenu=AI Tools (v3.1)
X-KDE-StartupNotify=false
X-KDE-SubstituteUID=false

[Desktop Action ask_ai]
Name=Ask AI...
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action summarize]
Name=Summarize
Icon=applications-science
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action explain]
Name=Explain this
Icon=help-contextual
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action fix_code]
Name=Fix code / errors
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action find_bugs]
Name=Find bugs
Icon=tools-report-bug
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action rewrite]
Name=Rewrite / improve
Icon=document-edit
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action improve]
Name=Improve writing
Icon=accessories-text-editor
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action bullets]
Name=To bullet points
Icon=format-list-unordered
Exec=/usr/local/bin/ai-rclick %F

[Desktop Action translate]
Name=Translate to English
Icon=applications-education-language
Exec=/usr/local/bin/ai-rclick %F
DESK6
  chmod a+x "$p6/ai-rclick.desktop" 2>/dev/null || true

  ok "KDE Dolphin (Plasma $plasma_ver): right-click → Ask AI"

  # ── KDE Plasma 6: register global shortcut via D-Bus + kglobalaccel6 ────────
  local keybind_kde
  keybind_kde=$(echo "$RCLICK_KEYBIND" | sed 's/Super/Meta/Ig; s/Ctrl/Ctrl/g')

  if [[ $plasma_ver -eq 6 ]] && command -v kwriteconfig6 &>/dev/null; then
    # Write to kglobalshortcutsrc
    kwriteconfig6 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "_k_friendly_name" "Ask AI" 2>/dev/null || true
    kwriteconfig6 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "Ask AI" "${keybind_kde},none,Ask AI" 2>/dev/null || true

    # Register via kglobalaccel6 D-Bus if available
    if command -v qdbus6 &>/dev/null || command -v qdbus &>/dev/null; then
      local QDBUS
      QDBUS=$(command -v qdbus6 2>/dev/null || command -v qdbus)
      # Reload kglobalaccel to pick up new shortcut
      $QDBUS org.kde.kglobalaccel /kglobalaccel \
        org.kde.kglobalaccel.Component.reloadActionIdentifiers \
        2>/dev/null || true
    fi

    # Also register as custom shortcut via khotkeys (Plasma 6 fallback)
    local khotkeys="$HOME/.config/khotkeysrc"
    if [[ ! -f "$khotkeys" ]] || ! grep -q "ai-rclick" "$khotkeys" 2>/dev/null; then
      cat >> "$khotkeys" <<KHOTKEYS

[Data_ai_rclick]
Comment=Ask AI (ai-cli)
DataCount=1
Enabled=true
Name=Ask AI
SystemGroup=0
Type=SIMPLE_ACTION_DATA

[Data_ai_rclick_Actions]
ActionsCount=1

[Data_ai_rclick_Actions0]
CommandURL=ai-rclick
Type=COMMAND_URL

[Data_ai_rclick_Triggers]
TriggersCount=1

[Data_ai_rclick_Triggers0]
Key=${keybind_kde}
Type=SHORTCUT
Uuid={ai-rclick-uuid}
KHOTKEYS
    fi
    ok "KDE Plasma 6 shortcut: $RCLICK_KEYBIND → ai-rclick"
    info "  Reload shortcuts: qdbus6 org.kde.kglobalaccel /kglobalaccel reloadActionIdentifiers"

  elif command -v kwriteconfig5 &>/dev/null; then
    kwriteconfig5 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "_k_friendly_name" "Ask AI" 2>/dev/null || true
    kwriteconfig5 --file kglobalshortcutsrc --group "ai-rclick.desktop" \
      --key "Ask AI" "${keybind_kde},none,Ask AI" 2>/dev/null || true
    ok "KDE Plasma 5 shortcut: $RCLICK_KEYBIND → ai-rclick"
  else
    warn "KDE: Manually add shortcut in System Settings > Shortcuts > Custom Shortcuts"
    info "  Command: ai-rclick   Shortcut: $RCLICK_KEYBIND"
  fi

  # Plasma 6: install xdg-open handler so Nautilus scripts work too
  if [[ $plasma_ver -eq 6 ]]; then
    local update_cmd
    update_cmd=$(command -v kbuildsycoca6 2>/dev/null || command -v kbuildsycoca5 2>/dev/null || true)
    [[ -n "$update_cmd" ]] && "$update_cmd" --noincremental 2>/dev/null &
  fi
}

_rclick_install_xfce() {
  info "Installing XFCE Thunar right-click action..."
  local uca="$HOME/.config/Thunar/uca.xml"
  mkdir -p "$(dirname "$uca")"
  [[ ! -f "$uca" ]] && echo '<actions></actions>' > "$uca"
  if ! grep -q "ai-rclick" "$uca" 2>/dev/null; then
    python3 - <<PYEOF
import xml.etree.ElementTree as ET
ET.register_namespace('', '')
try:
    tree = ET.parse('$uca')
    root = tree.getroot()
except:
    import xml.etree.ElementTree as ET2
    root = ET2.Element('actions')
    tree = ET2.ElementTree(root)
action = ET.SubElement(root, 'action')
for tag, text in [('icon','dialog-question'),('name','Ask AI'),
                  ('command','ai-rclick'),
                  ('description','Ask AI about selected text/file'),
                  ('patterns','*'),('directories','1'),('text-files','1'),
                  ('other-files','1')]:
    ET.SubElement(action, tag).text = text
tree.write('$uca', xml_declaration=True, encoding='utf-8')
print("XFCE Thunar action installed")
PYEOF
  fi
  ok "XFCE Thunar: right-click → Ask AI"

  # XFCE keyboard shortcut via xfconf
  if command -v xfconf-query &>/dev/null; then
    local keybind_xfce
    keybind_xfce=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
    xfconf-query -c xfce4-keyboard-shortcuts -p \
      "/commands/custom/${keybind_xfce}" \
      --create -t string -s "ai-rclick" 2>/dev/null || true
    ok "XFCE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_mate() {
  info "Installing MATE Caja right-click action..."
  mkdir -p "$HOME/.config/caja/scripts"
  printf '#!/usr/bin/env bash\nai-rclick "$@"\n' > "$HOME/.config/caja/scripts/Ask AI"
  chmod +x "$HOME/.config/caja/scripts/Ask AI"
  ok "MATE Caja: right-click → Scripts > Ask AI"

  if command -v dconf &>/dev/null; then
    local keybind_gs; keybind_gs=$(_rclick_key_to_gsettings "$RCLICK_KEYBIND")
    dconf write /org/mate/desktop/keybindings/ask-ai/action "'ai-rclick'" 2>/dev/null || true
    dconf write /org/mate/desktop/keybindings/ask-ai/binding "'${keybind_gs}'" 2>/dev/null || true
    dconf write /org/mate/desktop/keybindings/ask-ai/name "'Ask AI'" 2>/dev/null || true
    ok "MATE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_lxde() {
  info "Installing LXDE/LXQt right-click (openbox menu)..."
  local ob_menu="$HOME/.config/openbox/menu.xml"
  if [[ -f "$ob_menu" ]] && ! grep -q "ai-rclick" "$ob_menu"; then
    sed -i 's|</openbox_menu>|  <menu id="ask-ai-menu" label="Ask AI" execute="ai-rclick"/>\n</openbox_menu>|' \
      "$ob_menu" 2>/dev/null || true
    ok "Openbox menu updated: Ask AI entry added"
  fi
  # LXDE keyboard shortcut
  local lxde_kb="$HOME/.config/openbox/lxde-rc.xml"
  if [[ -f "$lxde_kb" ]] && ! grep -q "ai-rclick" "$lxde_kb"; then
    local keybind_ob; keybind_ob=$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')
    sed -i "s|</keyboard>|  <keybind key=\"${keybind_ob}\">\n      <action name=\"Execute\"><command>ai-rclick</command></action>\n    </keybind>\n  </keyboard>|" \
      "$lxde_kb" 2>/dev/null || true
    ok "LXDE shortcut: $RCLICK_KEYBIND → ai-rclick"
  fi
}

_rclick_install_sway_i3() {
  local wm=""
  command -v sway &>/dev/null && wm="sway"
  command -v i3   &>/dev/null && [[ -z "$wm" ]] && wm="i3"
  [[ -n "${SWAYSOCK:-}" ]] && wm="sway"

  local keybind_sym; keybind_sym=$(_rclick_key_to_sway "$RCLICK_KEYBIND")
  local cfg_file=""
  case "$wm" in
    sway) cfg_file="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config" ;;
    i3)   cfg_file="${XDG_CONFIG_HOME:-$HOME/.config}/i3/config"   ;;
  esac

  if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
    if ! grep -q "ai-rclick" "$cfg_file"; then
      printf '\n# Ask AI shortcut (ai-cli v2.4.6)\nbindsym %s exec ai-rclick\n' \
        "$keybind_sym" >> "$cfg_file"
      ok "${wm^}: Added '$keybind_sym → ai-rclick' in $cfg_file"
    else
      ok "${wm^}: ai-rclick keybind already in $cfg_file"
    fi
    info "Reload config: ${wm} reload  (or restart ${wm})"
  elif [[ -n "$wm" ]]; then
    # Config file not found — create snippet
    local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/$wm"
    mkdir -p "$cfg_dir"
    printf '# Ask AI shortcut (ai-cli v2.4.6)\nbindsym %s exec ai-rclick\n' \
      "$keybind_sym" >> "$cfg_dir/config"
    ok "${wm^}: Created $cfg_dir/config with keybind"
  else
    echo "  Add to your sway/i3 config:  bindsym $keybind_sym exec ai-rclick"
  fi
}

_rclick_install_hyprland() {
  info "Installing Hyprland keybinding..."
  local hcfg="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
  local keybind_hypr
  # Hyprland format: SUPER SHIFT, A, exec, ai-rclick
  keybind_hypr=$(echo "$RCLICK_KEYBIND" | \
    sed 's/Super/SUPER/Ig;s/Ctrl/CTRL/Ig;s/Alt/ALT/Ig;s/Shift/SHIFT/Ig' | \
    awk -F'+' 'BEGIN{OFS=""} {mods=""; for(i=1;i<NF;i++) mods=mods" "$i; key=$NF; print mods", "key", exec, ai-rclick"}' | \
    sed 's/^ //')
  mkdir -p "$(dirname "$hcfg")"
  if [[ ! -f "$hcfg" ]] || ! grep -q "ai-rclick" "$hcfg"; then
    printf '\n# Ask AI shortcut (ai-cli v2.4.6)\nbind = %s\n' "$keybind_hypr" >> "$hcfg"
    ok "Hyprland: Added 'bind = $keybind_hypr' in $hcfg"
  else
    ok "Hyprland: ai-rclick keybind already in $hcfg"
  fi
  info "Reload: hyprctl reload"
}

_rclick_install_openbox() {
  info "Installing Openbox keybinding..."
  local rc="${XDG_CONFIG_HOME:-$HOME/.config}/openbox/rc.xml"
  if [[ -f "$rc" ]] && ! grep -q "ai-rclick" "$rc"; then
    local keybind_ob; keybind_ob=$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')
    sed -i "s|</keyboard>|  <keybind key=\"${keybind_ob}\">\n      <action name=\"Execute\"><command>ai-rclick</command></action>\n    </keybind>\n  </keyboard>|" \
      "$rc" 2>/dev/null || true
    ok "Openbox: Added keybind $RCLICK_KEYBIND → ai-rclick"
    info "Reload: openbox --reconfigure"
  else
    echo "  Add to $rc <keyboard> section:"
    printf '    <keybind key="%s">\n      <action name="Execute"><command>ai-rclick</command></action>\n    </keybind>\n' \
      "$(echo "$RCLICK_KEYBIND" | sed 's/Super/W/Ig;s/\+/-/g')"
  fi
}

_rclick_install_xbindkeys() {
  # Universal X11 fallback using xbindkeys
  if ! command -v xbindkeys &>/dev/null; then
    info "xbindkeys not installed. For universal X11 keybind support:"
    info "  apt install xbindkeys   OR   pacman -S xbindkeys"
    return
  fi
  local cfg="$HOME/.xbindkeysrc"
  local keybind_xbk
  keybind_xbk=$(echo "$RCLICK_KEYBIND" | \
    sed 's/Super/Mod4/Ig;s/Ctrl/Control/Ig' | \
    awk -F'+' 'BEGIN{OFS="+"} {key=$NF; printf "\"%s\"\n  ", $0}')
  if [[ ! -f "$cfg" ]] || ! grep -q "ai-rclick" "$cfg"; then
    {
      echo ""
      echo "# Ask AI (ai-cli v2.4.6)"
      echo '"ai-rclick"'
      echo "  $(echo "$RCLICK_KEYBIND" | sed 's/Super/Mod4/Ig;s/Ctrl/Control/Ig;s/+/ + /g')"
    } >> "$cfg"
    ok "xbindkeys: Added $RCLICK_KEYBIND → ai-rclick in $cfg"
    info "Reload: pkill xbindkeys; xbindkeys &"
  fi
}

cmd_rclick() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    install)
      _rclick_install_deps
      _rclick_write_script

      # Auto-detect ALL present DEs/WMs and install for each
      local de="${XDG_CURRENT_DESKTOP:-}"
      local installed=()

      # GNOME / Cinnamon / Unity / Budgie (all use gsettings)
      if [[ -n "${GNOME_DESKTOP_SESSION_ID:-}" ]] \
         || [[ "$de" =~ (GNOME|Unity|Budgie|Cinnamon) ]]; then
        _rclick_install_gnome && installed+=("GNOME/Cinnamon")
      fi
      # KDE Plasma 5 / 6
      if [[ "$de" =~ (KDE) ]] || command -v plasmashell &>/dev/null; then
        _rclick_install_kde && installed+=("KDE")
      fi
      # XFCE
      if [[ "$de" =~ (XFCE|Xfce) ]] || command -v xfce4-session &>/dev/null; then
        _rclick_install_xfce && installed+=("XFCE")
      fi
      # MATE
      if [[ "$de" =~ (MATE) ]] || command -v mate-session &>/dev/null; then
        _rclick_install_mate && installed+=("MATE")
      fi
      # LXDE / LXQt
      if [[ "$de" =~ (LXDE|LXQt) ]] || command -v lxsession &>/dev/null; then
        _rclick_install_lxde && installed+=("LXDE")
      fi
      # Hyprland
      if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || command -v hyprctl &>/dev/null; then
        _rclick_install_hyprland && installed+=("Hyprland")
      fi
      # sway
      if [[ -n "${SWAYSOCK:-}" ]] || command -v sway &>/dev/null; then
        _rclick_install_sway_i3 && installed+=("sway")
      fi
      # i3
      if [[ "$de" =~ (i3) ]] || command -v i3 &>/dev/null && [[ ! " ${installed[*]} " =~ "sway" ]]; then
        _rclick_install_sway_i3 && installed+=("i3")
      fi
      # Openbox (standalone)
      if command -v openbox &>/dev/null && [[ ! " ${installed[*]} " =~ "LXDE" ]]; then
        _rclick_install_openbox && installed+=("Openbox")
      fi

      # If nothing matched or as extra fallback, install xbindkeys
      if [[ ${#installed[@]} -eq 0 ]]; then
        warn "Could not detect DE/WM — installing all compatible integrations..."
        _rclick_install_gnome  2>/dev/null || true
        _rclick_install_kde    2>/dev/null || true
        _rclick_install_xfce   2>/dev/null || true
        _rclick_install_openbox 2>/dev/null || true
        _rclick_install_xbindkeys 2>/dev/null || true
      fi
      # Always offer xbindkeys as a universal fallback
      [[ ! " ${installed[*]} " =~ "xbindkeys" ]] && \
        command -v xbindkeys &>/dev/null && _rclick_install_xbindkeys 2>/dev/null || true

      RCLICK_ENABLED="1"; save_config
      echo ""
      ok "Right-click AI installed!"
      [[ ${#installed[@]} -gt 0 ]] && info "  DEs configured: ${installed[*]}"
      info "  Shortcut: $RCLICK_KEYBIND   (select text first, then press)"
      info "  Or right-click in file manager → Ask AI"
      info "  Change shortcut: ai rclick keybind <combo>  e.g. Ctrl+Shift+a"
      ;;

    keybind)
      local kb="${1:-}"
      if [[ -z "$kb" ]]; then
        echo "  Current keybind: ${RCLICK_KEYBIND}"
        echo ""
        echo "  Usage: ai rclick keybind <combo>"
        echo "  Examples:"
        echo "    ai rclick keybind Super+Shift+a    (default)"
        echo "    ai rclick keybind Ctrl+Shift+a"
        echo "    ai rclick keybind Super+Alt+a"
        echo "    ai rclick keybind F12"
        echo ""
        echo "  After changing: run 'ai rclick install' to apply"
        return
      fi
      RCLICK_KEYBIND="$kb"; save_config
      ok "Keybind set: $kb"
      info "Run 'ai rclick install' to apply to your DE/WM"
      ;;

    uninstall)
      sudo rm -f /usr/local/bin/ai-rclick
      rm -f "$HOME/.local/share/nautilus/scripts/Ask AI"
      rm -f "$HOME/.local/share/nemo/scripts/Ask AI"
      rm -f "$HOME/.local/share/kservices5/ServiceMenus/ai-rclick.desktop"
      rm -f "$HOME/.local/share/kio/servicemenus/ai-rclick.desktop"
      rm -f "$HOME/.config/caja/scripts/Ask AI"
      # Remove GNOME shortcut
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null | \
           sed "s|, *'/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick/'||g" | \
           sed "s|'/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-rclick/', *||g"
        )" 2>/dev/null || true
      RCLICK_ENABLED="0"; save_config
      ok "Right-click AI uninstalled"
      ;;

    model)
      local m="${1:-}"
      if [[ -z "$m" ]]; then
        hdr "VL Model Options for Right-Click"
        for k in "${!RCLICK_VL_MODELS[@]}"; do
          IFS='|' read -r repo _ desc <<< "${RCLICK_VL_MODELS[$k]}"
          printf "  ${B}%-16s${R} %s\n" "$k:" "$desc"
        done
        read -rp "Choose [qwen3vl/lfm25vl/lfm25vl_gguf/custom]: " m
      fi
      [[ -z "${RCLICK_VL_MODELS[$m]:-}" ]] && { err "Unknown: $m"; return 1; }
      RCLICK_VL_MODEL="$m"; save_config
      ok "VL model set: $m"
      info "Run 'ai rclick install' to reinstall script with new model"
      ;;

    download-model) _rclick_download_vl ;;

    test)
      info "Testing right-click AI..."
      local text="Right-click AI test from ai-cli v2.4.6. If you see this, it works!"
      command -v wl-copy  &>/dev/null && echo "$text" | wl-copy 2>/dev/null || true
      command -v xclip    &>/dev/null && echo "$text" | xclip -selection clipboard 2>/dev/null || true
      command -v xsel     &>/dev/null && echo "$text" | xsel --clipboard --input 2>/dev/null || true
      if command -v ai-rclick &>/dev/null; then
        AI_RCLICK_SKIP_QUESTION=1 ai-rclick 2>/dev/null || bash /usr/local/bin/ai-rclick
      else
        err "ai-rclick not installed. Run: ai rclick install"
        return 1
      fi
      ;;

    status)
      hdr "Right-Click AI Status (v2.4.6)"
      local script_loc; script_loc=$(command -v ai-rclick 2>/dev/null || echo 'NOT INSTALLED')
      local disp="X11"
      [[ -n "${WAYLAND_DISPLAY:-}${SWAYSOCK:-}${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && disp="Wayland"
      printf "  %-22s %s\n" "Enabled:"       "$RCLICK_ENABLED"
      printf "  %-22s %s\n" "VL model:"      "${RCLICK_VL_MODEL:-not set}"
      printf "  %-22s %s\n" "Keybind:"       "$RCLICK_KEYBIND"
      printf "  %-22s %s\n" "Script:"        "$script_loc"
      printf "  %-22s %s\n" "DE/WM:"         "${XDG_CURRENT_DESKTOP:-unknown}"
      printf "  %-22s %s\n" "Display server:" "$disp"
      printf "  %-22s %s\n" "Clipboard tools:" \
        "$(for t in xclip xsel wl-paste wl-copy; do command -v $t &>/dev/null && echo -n "$t "; done; echo)"
      ;;

    fix-auth|fixauth)
      # v2.6.0.1: Re-apply trust/execute flags to all rclick scripts
      # Fixes 'not authorized to execute this file' without a full reinstall
      hdr "Fixing rclick authorization flags..."
      local _script="/usr/local/bin/ai-rclick"
      if [[ -f "$_script" ]]; then
        sudo chmod a+x "$_script"
        if command -v gio &>/dev/null; then
          sudo gio set -t string "$_script" metadata::trusted yes 2>/dev/null || true
        fi
        command -v setfattr &>/dev/null && \
          sudo setfattr -n user.nautilus-trusted -v "" "$_script" 2>/dev/null || true
        ok "Fixed: $_script"
      else
        warn "ai-rclick not found at $_script — run: ai rclick install"
      fi
      # Fix Nautilus scripts directory
      for d in "$HOME/.local/share/nautilus/scripts" "$HOME/.local/share/nemo/scripts"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/Ask\ AI "$d"/Summarize "$d"/Explain\ this "$d"/Fix\ code "$d"/Translate\ to\ English "$d"/Find\ bugs; do
          [[ -f "$f" ]] || continue
          chmod a+x "$f"
          if command -v gio &>/dev/null; then
            gio set -t string "$f" metadata::trusted yes 2>/dev/null || true
          fi
          command -v setfattr &>/dev/null && \
            setfattr -n user.nautilus-trusted -v "" "$f" 2>/dev/null || true
          ok "Fixed: $f"
        done
      done
      # Fix KDE .desktop files
      for f in \
          "$HOME/.local/share/kservices5/ServiceMenus/ai-rclick.desktop" \
          "$HOME/.local/share/kio/servicemenus/ai-rclick.desktop"; do
        [[ -f "$f" ]] || continue
        chmod a+x "$f"
        ok "Fixed: $f"
      done
      ok "Authorization fix complete. If Nautilus still shows the error, log out and back in."
      ;;

    *)
      hdr "Right-Click AI Context Menu (v2.6.0.1)"
      echo ""
      echo "  ${B}ai rclick install${R}             — Install for all detected DEs/WMs"
      echo "  ${B}ai rclick fix-auth${R}            — Fix 'not authorized' error (v2.6.0.1)"
      echo "  ${B}ai rclick keybind <combo>${R}      — Change keyboard shortcut"
      echo "  ${B}ai rclick uninstall${R}           — Remove all integrations"
      echo "  ${B}ai rclick model <name>${R}         — Set VL model"
      echo "  ${B}ai rclick download-model${R}       — Download VL model"
      echo "  ${B}ai rclick test${R}                 — Test with clipboard content"
      echo "  ${B}ai rclick status${R}               — Show full status"
      echo ""
      echo "  ${B}Supported DEs/WMs (all auto-detected):${R}"
      echo "    GNOME · KDE Plasma 5+6 · XFCE · MATE · Cinnamon"
      echo "    Openbox · LXDE/LXQt · i3 · sway · Hyprland"
      echo "    X11 universal: xbindkeys fallback"
      echo ""
      echo "  ${B}Default keybind:${R} $RCLICK_KEYBIND  (select text first)"
      echo "  Change:  ai rclick keybind Ctrl+Shift+a"
      echo ""
      echo "  ${B}VL models:${R}"
      for k in "${!RCLICK_VL_MODELS[@]}"; do
        IFS='|' read -r _ _ desc <<< "${RCLICK_VL_MODELS[$k]}"
        printf "    ${B}%-16s${R} %s\n" "$k" "$desc"
      done
      ;;
  esac
}


# ════════════════════════════════════════════════════════════════════════════════
#  AUTO-UPDATER — checks github.com/minerofthesoal/ai-cli for new releases
