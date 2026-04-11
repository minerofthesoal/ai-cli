#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — Build Script                                                      ║
# ║  Assembles src/lib/*.sh modules into a single distributable binary          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   bash build/build.sh              # Output: dist/ai
#   bash build/build.sh --output /tmp/ai-test
#   bash build/build.sh --verify     # Build + quick sanity check
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/src/lib"
DIST_DIR="$PROJECT_ROOT/dist"
OUTPUT="${1:-$DIST_DIR/ai}"
VERIFY=0

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --output=*) OUTPUT="${arg#--output=}" ;;
    --output)   shift; OUTPUT="${1:-$DIST_DIR/ai}" ;;
    --verify)   VERIFY=1 ;;
    --help|-h)
      echo "Usage: build.sh [--output <path>] [--verify]"
      exit 0 ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT")"

echo "╔══ AI CLI Build ════════════════════════════════════════════════════════╗"
echo "║  Source:  $LIB_DIR"
echo "║  Output:  $OUTPUT"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Write shebang + set options ───────────────────────────────────────────────
{
  printf '#!/usr/bin/env bash\n'
  printf '# AI CLI v%s — Single-file distributable (assembled by build/build.sh)\n' \
    "$(grep -m1 '^VERSION=' "$LIB_DIR/00-env.sh" | cut -d'"' -f2)"
  printf '# Built: %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  printf '# Source: https://github.com/minerofthesoal/ai-cli\n'
  printf '#\n'
  printf '# Linux/Mac:   chmod +x ai && sudo cp ai /usr/local/bin/ai\n'
  printf '# Windows 10:  Run in Git Bash / WSL\n'
  printf '#\n'
  printf 'set -euo pipefail\n'
  printf '\n'
} > "$OUTPUT"

# ── Concatenate all lib modules in numeric order ──────────────────────────────
module_count=0
line_count=0

for lib_file in "$LIB_DIR"/[0-9]*.sh; do
  [[ -f "$lib_file" ]] || continue
  fname="$(basename "$lib_file")"

  # Add a clear section separator
  {
    printf '\n'
    printf '# ════════════════════════════════════════════════════════════════════════════\n'
    printf '# MODULE: %s\n' "$fname"
    printf '# ════════════════════════════════════════════════════════════════════════════\n'
    printf '\n'
  } >> "$OUTPUT"

  # Append module content, stripping the module header block we added during split
  # (The header is the first 6 lines: 5 comment lines + 1 blank)
  tail -n +7 "$lib_file" >> "$OUTPUT"

  lines=$(wc -l < "$lib_file")
  line_count=$(( line_count + lines ))
  module_count=$(( module_count + 1 ))
  printf "  [%02d] %-30s %5d lines\n" "$module_count" "$fname" "$lines"
done

# ── Append entry point (startup + main call) ──────────────────────────────────
{
  printf '\n'
  printf '# ════════════════════════════════════════════════════════════════════════════\n'
  printf '# ENTRY POINT\n'
  printf '# ════════════════════════════════════════════════════════════════════════════\n'
  printf '\n'
  printf 'if ! _is_noninteractive_cmd "${1:-}"; then\n'
  printf '  _startup_hooks 2>/dev/null || true\n'
  printf 'fi\n'
  printf '\n'
  printf 'if ! _is_noninteractive_cmd "${1:-}"; then\n'
  printf '  _first_run_check 2>/dev/null || true\n'
  printf 'fi\n'
  printf '\n'
  printf 'main "$@"\n'
} >> "$OUTPUT"

chmod +x "$OUTPUT"

total_lines=$(wc -l < "$OUTPUT")
echo ""
echo "╔══ Build complete ══════════════════════════════════════════════════════╗"
printf "║  Modules: %-3d   Source lines: %-6d   Output: %-2d lines\n" \
  "$module_count" "$line_count" "$total_lines"
echo "╚════════════════════════════════════════════════════════════════════════╝"

# ── Optional verification ─────────────────────────────────────────────────────
if [[ $VERIFY -eq 1 ]]; then
  echo ""
  echo "  Verifying syntax..."
  if bash -n "$OUTPUT"; then
    echo "  ✓ Syntax OK"
  else
    echo "  ✗ Syntax errors found!" >&2
    exit 1
  fi
  echo ""
  echo "  Checking version output..."
  bash "$OUTPUT" version 2>/dev/null && echo "  ✓ Version command works"
  echo ""
  echo "  ✓ Build verified successfully"
fi
