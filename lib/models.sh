#!/usr/bin/env bash
# Return if sourced before config is loaded
[[ -z "${VERSION:-}" ]] && return 0 2>/dev/null || true
# AI CLI v3.1.0 — Models module
# Recommended models list, download, model management

declare -A RECOMMENDED_MODELS
RECOMMENDED_MODELS=(
  [1]="Amu/supertiny-llama3-0.25B-v0.1|gguf|0.25B|Supertiny Llama3 — ANY CPU"
  [2]="bartowski/Phi-3.1-mini-128k-instruct-GGUF|gguf|3.8B|Phi-3 Mini 128k"
  [3]="bartowski/SmolLM2-1.7B-Instruct-GGUF|gguf|1.7B|SmolLM2 ultra-fast"
  [4]="bartowski/Qwen2.5-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 multilingual"
  [5]="Qwen/Qwen2.5-0.5B-Instruct-GGUF|gguf|0.5B|Qwen2.5 smallest"
  [6]="bartowski/Llama-3.2-3B-Instruct-GGUF|gguf|3B|Llama 3.2 3B"
  [7]="bartowski/gemma-2-2b-it-GGUF|gguf|2B|Gemma 2 2B"
  [8]="bartowski/Mistral-7B-Instruct-v0.2-GGUF|gguf|7B|Mistral 7B"
  [9]="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|gguf|8B|Llama 3.1 8B"
  [10]="bartowski/Qwen2.5-7B-Instruct-GGUF|gguf|7B|Qwen2.5 7B"
  [11]="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF|gguf|7B|Qwen2.5 Coder"
  [12]="bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|gguf|7B|DeepSeek-R1 7B"
  [13]="bartowski/Llama-3.3-70B-Instruct-GGUF|gguf|70B|Llama 3.3 70B"
  [14]="bartowski/Phi-4-GGUF|gguf|14B|Phi-4 14B"
  [15]="bartowski/Qwen3-8B-GGUF|gguf|8B|Qwen3 8B"
  [16]="gpt-4o|openai|API|GPT-4o"
  [17]="gpt-4o-mini|openai|API|GPT-4o mini"
  [18]="claude-sonnet-4-6|claude|API|Claude Sonnet 4.6"
  [19]="claude-opus-4-7|claude|API|Claude Opus 4.7"
  [20]="gemini-2.5-flash|gemini|API|Gemini 2.5 Flash"
  [21]="llama-3.3-70b-versatile|groq|API|Groq Llama 70B"
  [22]="mistral-large-latest|mistral|API|Mistral Large"
  [23]="meta-llama/Llama-3.3-70B-Instruct-Turbo|together|API|Together Llama 70B"
  [24]="openai/whisper-large-v3|hf|1.5B|Whisper Large v3"
  [25]="black-forest-labs/FLUX.1-schnell|diffusers|FLUX|FLUX Schnell"
)

cmd_recommended() {
  local sub="${1:-list}"; shift 2>/dev/null || true
  case "$sub" in
    download)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Usage: ai recommended download <N>"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err "No model #$n"; return 1; }
      cmd_download "$(echo "$entry" | cut -d'|' -f1)" ;;
    use)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Usage: ai recommended use <N>"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err "No model #$n"; return 1; }
      ACTIVE_MODEL="$(echo "$entry"|cut -d'|' -f1)"; ACTIVE_BACKEND="$(echo "$entry"|cut -d'|' -f2)"
      save_config; ok "Model: $ACTIVE_MODEL ($ACTIVE_BACKEND)" ;;
    *)
      hdr "Recommended Models (${#RECOMMENDED_MODELS[@]})"
      echo ""
      for key in $(echo "${!RECOMMENDED_MODELS[@]}" | tr ' ' '\n' | sort -n); do
        local entry="${RECOMMENDED_MODELS[$key]}"
        local repo=$(echo "$entry"|cut -d'|' -f1)
        local btype=$(echo "$entry"|cut -d'|' -f2)
        local sz=$(echo "$entry"|cut -d'|' -f3)
        local desc=$(echo "$entry"|cut -d'|' -f4)
        local mark="  "
        [[ "$ACTIVE_MODEL" == "$repo" ]] && mark="${BGREEN}▶${R}"
        printf "  %b ${B}%2d.${R} %-6s %-50s %s\n" "$mark" "$key" "$sz" "$repo" "$desc"
      done
      echo ""
      echo -e "  Download: ${B}ai recommended download <N>${R}"
      echo -e "  Use:      ${B}ai recommended use <N>${R}"
      ;;
  esac
}

cmd_download() {
  local repo="${1:?Usage: ai download <hf-repo-id>}"
  [[ -z "$PYTHON" ]] && { err "Python required for download"; return 1; }
  info "Downloading: $repo"
  "$PYTHON" -c "
from huggingface_hub import snapshot_download, hf_hub_download
import os, sys, glob
repo = '$repo'
dest = '$MODELS_DIR'
try:
    # Try GGUF first
    from huggingface_hub import list_repo_files
    files = list_repo_files(repo)
    gguf = [f for f in files if f.endswith('.gguf')]
    if gguf:
        best = sorted([f for f in gguf if 'Q4_K_M' in f] or [f for f in gguf if 'Q4' in f] or gguf[:1])[0]
        print(f'Downloading {best}...')
        path = hf_hub_download(repo, best, local_dir=dest)
        print(f'Saved: {path}')
    else:
        path = snapshot_download(repo, local_dir=os.path.join(dest, repo.split('/')[-1]))
        print(f'Saved: {path}')
except Exception as e:
    print(f'Download error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1
  ok "Download complete"
}

cmd_list_models() {
  hdr "Downloaded Models"
  echo ""
  local found=0
  for f in "$MODELS_DIR"/*.gguf; do
    [[ -f "$f" ]] || continue; found=1
    local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
    local mark="  "
    [[ "$(basename "$f")" == "$(basename "${ACTIVE_MODEL:-}")" ]] && mark="${BGREEN}▶${R}"
    printf "  %b %-50s %6s\n" "$mark" "$(basename "$f")" "$size"
  done
  (( found == 0 )) && dim "(no GGUF models — run: ai recommended download 1)"
  echo ""
  printf "  Active: %s (%s)\n" "${ACTIVE_MODEL:-none}" "${ACTIVE_BACKEND:-auto}"
}
