#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI v2.7.3 — Universal AI CLI                                          ║
# ║  Multi-file source layout — run this directly or build with: make build    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Usage (development):  bash src/main.sh <command> [args...]
# Usage (installed):    ai <command> [args...]
# Build single binary:  make build   → dist/ai
# Install:              make install → /usr/local/bin/ai
#
set -euo pipefail

# ── Locate lib directory relative to this script ──────────────────────────────
_AI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AI_LIB_DIR="$_AI_SCRIPT_DIR/lib"

if [[ ! -d "$_AI_LIB_DIR" ]]; then
  echo "ERROR: lib/ directory not found at $_AI_LIB_DIR" >&2
  echo "Run from the project root or build a binary: make build" >&2
  exit 1
fi

# ── Source all modules in numeric order ───────────────────────────────────────
for _ai_lib in "$_AI_LIB_DIR"/[0-9]*.sh; do
  # shellcheck source=/dev/null
  source "$_ai_lib"
done
unset _ai_lib _AI_LIB_DIR _AI_SCRIPT_DIR

# ── Startup hooks (skipped for non-interactive commands) ──────────────────────
if ! _is_noninteractive_cmd "${1:-}"; then
  _startup_hooks 2>/dev/null || true
fi

# ── First-run check ───────────────────────────────────────────────────────────
if ! _is_noninteractive_cmd "${1:-}"; then
  _first_run_check 2>/dev/null || true
fi

# ── Dispatch ──────────────────────────────────────────────────────────────────
main "$@"
