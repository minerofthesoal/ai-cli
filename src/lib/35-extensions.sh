# ============================================================================
# MODULE: 35-extensions.sh
# AI extensions system (.aipack packages)
# Source lines 12680-13014 of main-v2.7.3
# ============================================================================

cmd_extension() {
  local subcmd="${1:-help}"; shift || true

  case "$subcmd" in
    # ── Create ────────────────────────────────────────────────────────────────
    create)
      local name="${1:-}"; local desc="${2:-A custom AI CLI extension}"
      if [[ -z "$name" ]]; then read -rp "Extension name: " name; fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      name="${name//[^a-zA-Z0-9_-]/_}"
      local ext_path="$EXTENSIONS_DIR/$name"
      if [[ -d "$ext_path" ]]; then err "Extension '$name' already exists at $ext_path"; return 1; fi
      mkdir -p "$ext_path"

      # manifest.json
      cat > "$ext_path/manifest.json" <<JSON
{
  "name": "$name",
  "version": "1.0.0",
  "description": "$desc",
  "entry": "ex.sh",
  "python_script": "main.py",
  "author": "",
  "commands": ["run", "help"],
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

      # ex.sh — bash entry point
      cat > "$ext_path/ex.sh" <<'EXTSH'
#!/usr/bin/env bash
# AI CLI Extension entry point
# Extension name is available as EXT_NAME
# Extension directory is available as EXT_DIR
# AI CLI binary is available as AI_BIN

set -euo pipefail
EXT_NAME="${EXT_NAME:-extension}"
EXT_DIR="${EXT_DIR:-$(dirname "$0")}"
AI_BIN="${AI_BIN:-ai}"
PYTHON="${PYTHON:-python3}"

cmd="${1:-help}"; shift || true

case "$cmd" in
  run)
    echo "Running $EXT_NAME..."
    "$PYTHON" "$EXT_DIR/main.py" "$@"
    ;;
  help|--help|-h|"")
    echo "Usage: ai extension run <name> [args...]"
    echo "       ai extension help <name>"
    ;;
  *)
    echo "Unknown command: $cmd"
    exit 1
    ;;
esac
EXTSH
      chmod +x "$ext_path/ex.sh"

      # main.py — Python script
      cat > "$ext_path/main.py" <<'EXTPY'
#!/usr/bin/env python3
"""AI CLI Extension — main.py
Edit this file to implement your extension logic.
"""
import sys
import os
import json

EXT_DIR = os.path.dirname(os.path.abspath(__file__))

def main(args):
    print(f"Extension running with args: {args}")
    # Load manifest
    mf = os.path.join(EXT_DIR, "manifest.json")
    with open(mf) as f:
        manifest = json.load(f)
    print(f"Name: {manifest['name']}  v{manifest['version']}")
    print(f"Description: {manifest['description']}")

if __name__ == "__main__":
    main(sys.argv[1:])
EXTPY

      # Mark as enabled
      touch "$ext_path/.enabled"

      ok "Extension '$name' created at $ext_path"
      echo ""
      echo "  Files created:"
      echo "    $ext_path/manifest.json  — metadata"
      echo "    $ext_path/ex.sh          — bash entry (edit this)"
      echo "    $ext_path/main.py        — Python script (edit this)"
      echo ""
      echo "  Package it:  ai extension package $name"
      echo "  Edit:        ai extension edit $name"
      echo "  Run:         ai extension run $name"
      ;;

    # ── Load ──────────────────────────────────────────────────────────────────
    load)
      local aipack="${1:-}"
      if [[ -z "$aipack" ]]; then
        # Try to open a file dialog (zenity > kdialog > read)
        if command -v zenity &>/dev/null; then
          aipack=$(zenity --file-selection --title="Select .aipack file" --file-filter="AI Pack (*.aipack) | *.aipack" 2>/dev/null || echo "")
        elif command -v kdialog &>/dev/null; then
          aipack=$(kdialog --getopenfilename "$HOME" "*.aipack" 2>/dev/null || echo "")
        fi
        [[ -z "$aipack" ]] && { read -rp ".aipack file path: " aipack; }
      fi
      aipack="$(echo "$aipack" | xargs)"
      [[ -z "$aipack" ]] && { warn "No file selected"; return 1; }
      [[ ! -f "$aipack" ]] && { err "File not found: $aipack"; return 1; }

      # Read manifest from archive to get name
      local raw_name
      raw_name=$(tar -tzf "$aipack" 2>/dev/null | head -1 | cut -d/ -f1)
      if [[ -z "$raw_name" ]]; then
        raw_name=$(basename "$aipack" .aipack)
      fi

      # Extract manifest name if present
      local meta_name
      meta_name=$(tar -xzf "$aipack" --to-stdout "${raw_name}/manifest.json" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "")
      local ext_name="${meta_name:-$raw_name}"
      ext_name="${ext_name//[^a-zA-Z0-9_-]/_}"

      local dest="$EXTENSIONS_DIR/$ext_name"
      if [[ -d "$dest" ]]; then
        warn "Extension '$ext_name' already exists — overwriting"
        rm -rf "$dest"
      fi
      mkdir -p "$dest"

      info "Extracting '$ext_name' from $aipack..."
      if tar -xzf "$aipack" -C "$EXTENSIONS_DIR" 2>/dev/null; then
        # Rename extracted dir to ext_name if needed
        [[ -d "$EXTENSIONS_DIR/$raw_name" && "$raw_name" != "$ext_name" ]] && \
          mv "$EXTENSIONS_DIR/$raw_name" "$dest"
        chmod +x "$dest/ex.sh" 2>/dev/null || true
        touch "$dest/.enabled"
        ok "Loaded extension '$ext_name' → $dest"
        cat "$dest/manifest.json" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(f\"  Name:        {d.get('name','?')}\")
    print(f\"  Version:     {d.get('version','?')}\")
    print(f\"  Description: {d.get('description','?')}\")
    print(f\"  Author:      {d.get('author','unknown')}\")
except: pass
" 2>/dev/null || true
      else
        err "Failed to extract .aipack — ensure it is a valid gzip'd tar archive"
        rm -rf "$dest"
        return 1
      fi
      ;;

    # ── Locate ────────────────────────────────────────────────────────────────
    locate)
      echo ""
      hdr "AI CLI Extensions — Installed"
      echo ""
      local found=0
      if [[ -d "$EXTENSIONS_DIR" ]]; then
        for ext_dir in "$EXTENSIONS_DIR"/*/; do
          [[ -d "$ext_dir" ]] || continue
          local ext_name; ext_name=$(basename "$ext_dir")
          local enabled="disabled"
          [[ -f "$ext_dir/.enabled" ]] && enabled="${BGREEN}enabled${R}"
          local meta_name="$ext_name"
          local meta_ver="" meta_desc=""
          if [[ -f "$ext_dir/manifest.json" ]]; then
            meta_name=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('name','$ext_name'))" 2>/dev/null || echo "$ext_name")
            meta_ver=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('version',''))" 2>/dev/null || echo "")
            meta_desc=$(python3 -c "import json; d=json.load(open('$ext_dir/manifest.json')); print(d.get('description',''))" 2>/dev/null || echo "")
          fi
          echo -e "  ${B}${meta_name}${R} ${DIM}v${meta_ver}${R}  [${enabled}]"
          echo -e "    Path: ${CYAN}${ext_dir}${R}"
          [[ -n "$meta_desc" ]] && echo -e "    Desc: ${meta_desc}"
          [[ -f "$ext_dir/ex.sh"   ]] && echo -e "    ${BGREEN}✓${R} ex.sh"
          [[ -f "$ext_dir/main.py" ]] && echo -e "    ${BGREEN}✓${R} main.py"
          echo ""
          (( found++ ))
        done
      fi
      if (( found == 0 )); then
        echo -e "  ${DIM}No extensions installed.${R}"
        echo -e "  Use '${B}ai extension create <name>${R}' or '${B}ai extension load <file.aipack>${R}'"
      else
        echo -e "  ${DIM}${found} extension(s) found in ${EXTENSIONS_DIR}${R}"
      fi
      echo ""
      ;;

    # ── Package ───────────────────────────────────────────────────────────────
    package)
      local name="${1:-}"
      if [[ -z "$name" ]]; then
        # List available extensions
        echo "Available extensions:"
        for d in "$EXTENSIONS_DIR"/*/; do
          [[ -d "$d" ]] && echo "  $(basename "$d")"
        done
        read -rp "Extension to package: " name
      fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Extension not found: $ext_path"; return 1; }

      # Get version from manifest
      local ver
      ver=$(python3 -c "import json; d=json.load(open('$ext_path/manifest.json')); print(d.get('version','1.0.0'))" 2>/dev/null || echo "1.0.0")
      local out_file="$BUILD_DIR/${name}-${ver}.aipack"

      info "Packaging '$name' v${ver}..."
      # Create a clean tar: rename dir to name for clean extraction
      local tmp_dir; tmp_dir=$(mktemp -d)
      cp -r "$ext_path" "$tmp_dir/$name"
      # Remove .enabled flag from package (user must enable after load)
      rm -f "$tmp_dir/$name/.enabled"
      tar -czf "$out_file" -C "$tmp_dir" "$name"
      rm -rf "$tmp_dir"

      ok "Package created: $out_file"
      echo "  Size: $(du -h "$out_file" | cut -f1)"
      echo "  Contents:"
      tar -tzf "$out_file" | sed 's/^/    /'
      echo ""
      echo "  Distribute: send $out_file to other users"
      echo "  Install:    ai extension load $out_file"
      ;;

    # ── Edit ──────────────────────────────────────────────────────────────────
    edit)
      local name="${1:-}"; local file="${2:-ex.sh}"
      if [[ -z "$name" ]]; then
        echo "Available extensions:"
        for d in "$EXTENSIONS_DIR"/*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done
        read -rp "Extension name: " name
      fi
      [[ -z "$name" ]] && { err "Name required"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Not found: $ext_path"; return 1; }

      local edit_target="$ext_path/$file"
      if [[ ! -f "$edit_target" ]]; then
        echo "Files in $ext_path:"
        ls "$ext_path"
        read -rp "File to edit: " file
        edit_target="$ext_path/$file"
      fi
      [[ ! -f "$edit_target" ]] && { err "File not found: $edit_target"; return 1; }

      local editor="${VISUAL:-${EDITOR:-nano}}"
      if command -v "$editor" &>/dev/null; then
        "$editor" "$edit_target"
      elif command -v nano &>/dev/null; then
        nano "$edit_target"
      elif command -v vi &>/dev/null; then
        vi "$edit_target"
      else
        err "No editor found. Set \$EDITOR or install nano/vi."
        return 1
      fi
      ok "Edited: $edit_target"
      ;;

    # ── Run ───────────────────────────────────────────────────────────────────
    run)
      local name="${1:-}"; shift || true
      [[ -z "$name" ]] && { err "Usage: ai extension run <name> [args...]"; return 1; }
      local ext_path="$EXTENSIONS_DIR/$name"
      [[ ! -d "$ext_path" ]] && { err "Extension not found: $ext_path"; return 1; }
      [[ ! -f "$ext_path/ex.sh" ]] && { err "No ex.sh in $ext_path"; return 1; }

      export EXT_NAME="$name"
      export EXT_DIR="$ext_path"
      export AI_BIN="$(command -v ai 2>/dev/null || echo "$0")"
      export PYTHON="${PYTHON:-python3}"
      bash "$ext_path/ex.sh" "$@"
      ;;

    # ── Enable / Disable ──────────────────────────────────────────────────────
    enable)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      touch "$EXTENSIONS_DIR/$name/.enabled"
      ok "Enabled: $name"
      ;;
    disable)
      local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
      rm -f "$EXTENSIONS_DIR/$name/.enabled"
      ok "Disabled: $name"
      ;;

    # ── List ──────────────────────────────────────────────────────────────────
    list|ls)
      cmd_extension locate
      ;;

    # ── Help ──────────────────────────────────────────────────────────────────
    help|--help|-h|"")
      echo ""
      hdr "AI CLI v${VERSION} — Extension System"
      echo ""
      echo -e "  ${B}ai extension create <name> [desc]${R}   Scaffold a new extension"
      echo -e "  ${B}ai extension load [file.aipack]${R}     Install from .aipack file"
      echo -e "  ${B}ai extension locate${R}                 List all extensions + paths"
      echo -e "  ${B}ai extension package <name>${R}         Package as distributable .aipack"
      echo -e "  ${B}ai extension edit <name> [file]${R}     Edit extension files"
      echo -e "  ${B}ai extension run <name> [args...]${R}   Execute an extension"
      echo -e "  ${B}ai extension enable/disable <name>${R}  Toggle extension"
      echo -e "  ${B}ai extension list${R}                   Same as locate"
      echo ""
      echo -e "  ${DIM}.aipack format: gzip'd tar with manifest.json + ex.sh + main.py${R}"
      echo -e "  ${DIM}Extensions dir: ${EXTENSIONS_DIR}${R}"
      echo ""
      ;;

    *)
      err "Unknown extension subcommand: $subcmd"
      cmd_extension help
      return 1
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.7: INSTALL FIREFOX EXTENSION — LLM sidebar using local API server
# ════════════════════════════════════════════════════════════════════════════════
