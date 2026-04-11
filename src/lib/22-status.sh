# ============================================================================
# MODULE: 22-status.sh
# System status / diagnostics
# Source lines 8303-8366 of main-v2.7.3
# ============================================================================

#  STATUS
# ════════════════════════════════════════════════════════════════════════════════
cmd_status() {
  hdr "AI CLI v${VERSION} — Status"; echo ""
  printf "  %-22s %s\n" "Platform:"   "$PLATFORM"
  printf "  %-22s %s\n" "OS:"         "$(uname -s -r 2>/dev/null || echo unknown)"
  printf "  %-22s %s\n" "Python:"     "${PYTHON:-not found}"
  printf "  %-22s %s\n" "llama.cpp:"  "${LLAMA_BIN:-not found}"
  printf "  %-22s %s\n" "ffmpeg:"     "$(command -v ffmpeg 2>/dev/null || echo 'not found')"
  printf "  %-22s %s\n" "CPU-only:"   "$([[ $CPU_ONLY_MODE -eq 1 ]] && echo 'YES (Windows/no GPU)' || echo 'no')"
  echo ""
  if command -v nvidia-smi &>/dev/null; then
    printf "  %-22s %s\n" "GPU:" "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null|head -1)"
    printf "  %-22s %s\n" "VRAM:" "$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null|head -1)"
    printf "  %-22s %s\n" "Compute:" "$CUDA_ARCH"
    if (( CUDA_ARCH >= 61 )); then
      printf "  %-22s ${BGREEN}✓ CUDA supported${R}\n" "Support:"
    else
      printf "  %-22s ${BRED}✗ Legacy GPU (CPU only)${R}\n" "Support:"
    fi
  else
    printf "  %-22s %s\n" "GPU:" "none (CPU-only mode)"
  fi
  echo ""
  printf "  %-22s %s\n" "Active model:"   "${ACTIVE_MODEL:-not set}"
  printf "  %-22s %s\n" "Backend:"        "${ACTIVE_BACKEND:-auto}"
  printf "  %-22s %s\n" "Session:"        "${ACTIVE_SESSION:-default}"
  printf "  %-22s %s\n" "Persona:"        "${ACTIVE_PERSONA:-default}"
  printf "  %-22s %s\n" "Canvas:"         "${CANVAS_ACTIVE:-none}"
  printf "  %-22s %s\n" "GUI theme:"      "${GUI_THEME:-dark}"
  echo ""
  printf "  %-22s %s (v%s)\n" "TTM:"  "$TTM_AUTO_TRAIN" "$TTM_VERSION"
  printf "  %-22s %s (v%s)\n" "MTM:"  "$MTM_AUTO_TRAIN" "$MTM_VERSION"
  printf "  %-22s %s (v%s)\n" "Mtm:"  "$MMTM_AUTO_TRAIN" "$MMTM_VERSION"
  printf "  %-22s %s → %s\n" "HF sync:" "$HF_DATASET_SYNC" "$HF_DATASET_REPO"
  echo ""
  # v2.4: API server status
  local api_status="not running"
  if [[ -f "$API_PID_FILE" ]]; then
    local apid; apid=$(cat "$API_PID_FILE" 2>/dev/null)
    kill -0 "$apid" 2>/dev/null && api_status="${BGREEN}running${R} (PID $apid) on $API_HOST:$API_PORT"
  fi
  printf "  %-22s " "LLM API (v2.4):"; echo -e "$api_status"
  printf "  %-22s %s\n" "Datasets (v2.4):" "$(ls "$DATASETS_DIR" 2>/dev/null | wc -l) dataset(s)"
  echo ""
  printf "  %-22s %s\n" "Temperature:"  "$TEMPERATURE"
  printf "  %-22s %s\n" "Max tokens:"   "$MAX_TOKENS"
  printf "  %-22s %s\n" "Context:"      "$CONTEXT_SIZE"
  printf "  %-22s %s\n" "GPU layers:"   "$GPU_LAYERS"
  echo ""
  hdr "API Keys"
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY HF_TOKEN HF_DATASET_KEY BRAVE_API_KEY; do
    local v; v=$(eval "echo \"\${$k:-}\"")
    if [[ -n "$v" ]]; then printf "  %-24s ${BGREEN}set${R} (%s…%s)\n" "$k:" "${v:0:4}" "${v: -4}"
    else printf "  %-24s ${DIM}not set${R}\n" "$k:"; fi
  done
  echo ""
  printf "  %-22s %s\n" "GGUF models:" "$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | wc -l)"
  printf "  %-22s %s\n" "Chat logs:"   "$(ls "$CHAT_LOGS_DIR"/*.jsonl 2>/dev/null | wc -l || echo 0)"
  printf "  %-22s %s\n" "Datasets:"    "$(ls "$DATASETS_DIR" 2>/dev/null | wc -l)"
}

# ════════════════════════════════════════════════════════════════════════════════
#  HELP
