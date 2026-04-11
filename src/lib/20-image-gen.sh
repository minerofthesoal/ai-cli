# ============================================================================
# MODULE: 20-image-gen.sh
# Image generation: txt2img, img2img, inpaint, FLUX
# Source lines 7778-8108 of main-v2.7.3
# ============================================================================

#  IMAGE GENERATION
# ════════════════════════════════════════════════════════════════════════════════
cmd_imagine() {
  local prompt="" out="" steps=30 size="1024x1024"
  local mode="txt2img" init_img="" strength="0.75" lora=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)      out="$2";      shift 2 ;;
      --steps)    steps="$2";   shift 2 ;;
      --size)     size="$2";    shift 2 ;;
      --img2img)  mode="img2img"; init_img="$2"; shift 2 ;;
      --inpaint)  mode="inpaint"; init_img="$2"; shift 2 ;;
      --strength) strength="$2"; shift 2 ;;
      --lora)     lora="$2";    shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ ${#args[@]} -gt 0 ]] && prompt="${args[*]}"
  [[ -z "$prompt" ]] && { read -rp "Image prompt: " prompt; }
  [[ -z "$out" ]] && out="$AI_OUTPUT_DIR/generated_$(date +%Y%m%d_%H%M%S).png"
  mkdir -p "$(dirname "$out")"

  # Try OpenAI DALL-E for txt2img first
  if [[ -n "${OPENAI_API_KEY:-}" && "$mode" == "txt2img" ]]; then
    local dall_e_size="1024x1024"
    local url
    url=$(curl -sS https://api.openai.com/v1/images/generations \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"dall-e-3\",\"prompt\":$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"n\":1,\"size\":\"$dall_e_size\"}" 2>/dev/null | \
      python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data'][0]['url'])" 2>/dev/null)
    [[ -n "$url" ]] && curl -sL "$url" -o "$out" && ok "Image (DALL-E 3): $out" && return 0
  fi

  # Local diffusers (SDXL / FLUX / SD2)
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local model="${ACTIVE_MODEL:-stabilityai/stable-diffusion-xl-base-1.0}"

  # Use _imggen_v2 for SDXL/FLUX with img2img/inpaint support
  _imggen_v2 "$prompt" "$mode" "$init_img" "$strength"
}

cmd_chat_interactive() {
  local chat_name="${CURRENT_CHAT_NAME:-}"
  hdr "AI Chat — Session: $ACTIVE_SESSION"
  [[ -n "$chat_name" ]] && info "Chat log: $CURRENT_CHAT_FILE"
  echo "  Commands: /quit /clear /session <n> /persona <n> /model <m>"
  echo ""

  while true; do
    printf "${BCYAN}${B}You: ${R}"
    local input; read -r input || break
    [[ -z "$input" ]] && continue

    case "$input" in
      /quit|/exit|/q) break ;;
      /clear)
        echo "[]" > "$SESSIONS_DIR/${ACTIVE_SESSION}.json"
        info "History cleared"
        ;;
      /session*)
        local n="${input#/session }"; ACTIVE_SESSION="$n"; save_config; info "Session: $n"
        ;;
      /persona*)
        local n="${input#/persona }"; ACTIVE_PERSONA="$n"; save_config; info "Persona: $n"
        ;;
      /model*)
        local m="${input#/model }"; ACTIVE_MODEL="$m"; save_config; info "Model: $m"
        ;;
      /save)
        info "Chat saved: $CURRENT_CHAT_FILE"
        ;;
      *)
        [[ -n "$CURRENT_CHAT_FILE" ]] && _chat_append "user" "$input"
        printf "${BGREEN}${B}AI: ${R}"
        dispatch_ask "$input"
        echo ""
        ;;
    esac
  done
}
cmd_list_models() {
  hdr "Downloaded Models (v2.7.3)"
  local found=0

  # Helper: find recommended entry number for a model file/dir
  _rec_num_for() {
    local name="$1"
    for k in "${!RECOMMENDED_MODELS[@]}"; do
      local repo; repo=$(echo "${RECOMMENDED_MODELS[$k]}" | cut -d'|' -f1)
      local bname; bname=$(basename "$repo")
      echo "$name" | grep -qi "$bname" && { echo "$k"; return 0; }
      echo "$bname" | grep -qi "$(basename "$name" .gguf)" && { echo "$k"; return 0; }
    done
    echo ""
  }

  echo ""
  echo -e "  ${BCYAN}GGUF Models:${R}"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue; found=1
    local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
    local active_mark="  "
    if [[ "$f" == "$ACTIVE_MODEL" || "$(basename "$f")" == "$(basename "${ACTIVE_MODEL:-}")" ]]; then
      active_mark="${BGREEN}▶${R}"
    fi
    local rec_n; rec_n=$(_rec_num_for "$(basename "$f")" 2>/dev/null)
    local rec_str=""
    [[ -n "$rec_n" ]] && rec_str=" ${DIM}[rec #${rec_n}]${R}"
    printf "  %b  ${B}%-52s${R} %6s%b\n" "$active_mark" "$(basename "$f")" "$size" "$rec_str"
  done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | sort)
  [[ $found -eq 0 ]] && dim "    (none)"

  echo ""
  echo -e "  ${BCYAN}PyTorch / HuggingFace Models:${R}"
  local found_pt=0
  for d in "$MODELS_DIR"/*/; do
    [[ -d "$d" && -f "$d/config.json" ]] || continue; found_pt=1; found=1
    local dname; dname=$(basename "$d")
    local active_mark="  "
    [[ "${d%/}" == "$ACTIVE_MODEL" ]] && active_mark="${BGREEN}▶${R}"
    local rec_n; rec_n=$(_rec_num_for "$dname" 2>/dev/null)
    local rec_str=""
    [[ -n "$rec_n" ]] && rec_str=" ${DIM}[rec #${rec_n}]${R}"
    printf "  %b  ${B}%-52s${R} (pytorch)%b\n" "$active_mark" "$dname" "$rec_str"
  done
  [[ $found_pt -eq 0 ]] && dim "    (none)"

  echo ""
  [[ $found -eq 0 ]] && dim "  No models downloaded yet."
  echo -e "  ${BGREEN}▶${R} = active model   ${DIM}[rec #N]${R} = recommended entry number"
  echo -e "  Download: ${B}ai recommended download <N>${R}  |  ${B}ai download <hf-repo>${R}"
  [[ -n "${ACTIVE_MODEL:-}" ]] && echo -e "  Active:   ${BGREEN}${ACTIVE_MODEL}${R} (backend: ${ACTIVE_BACKEND:-auto})"
}

cmd_download() {
  local repo="${1:-}"; local file_filter="${2:-}"
  [[ -z "$repo" ]] && { read -rp "HuggingFace repo (user/model): " repo; }
  [[ -z "$repo" ]] && { err "Repo required"; return 1; }
  if [[ "$repo" =~ ^sk-|^hf_|^AIza ]]; then
    local key_type="OPENAI_API_KEY"
    [[ "$repo" =~ ^hf_ ]] && key_type="HF_TOKEN"
    [[ "$repo" =~ ^AIza ]] && key_type="GEMINI_API_KEY"
    _set_key "$key_type" "$repo"; return 0
  fi
  mkdir -p "$MODELS_DIR"
  if [[ -z "$file_filter" ]]; then
    local files
    files=$(curl -sS --max-time 30 "https://huggingface.co/api/models/${repo}" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
gguf=[s['rfilename'] for s in d.get('siblings',[]) if s['rfilename'].endswith('.gguf')]
q4=[f for f in gguf if 'Q4_K_M' in f or 'q4_k_m' in f]
print(q4[0] if q4 else (gguf[0] if gguf else ''))
" 2>/dev/null)
    [[ -n "$files" ]] && file_filter="$files"
  fi
  if [[ -n "$file_filter" ]]; then
    local url="https://huggingface.co/${repo}/resolve/main/${file_filter}"
    local dest="$MODELS_DIR/$(basename "$file_filter")"
    info "Downloading $file_filter from $repo..."
    if ! curl -L --progress-bar "$url" ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} -o "$dest"; then
      err ERR306 "Download failed: $url"
      rm -f "$dest" 2>/dev/null || true
      return 1
    fi
    # Verify file actually downloaded (not a 404/HTML error page)
    local fsize; fsize=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if (( fsize < 1024 )); then
      err ERR306 "Downloaded file is too small (${fsize} bytes) — likely a 404 error"
      rm -f "$dest" 2>/dev/null || true
      return 1
    fi
    ok "Downloaded: $dest ($(du -sh "$dest" | cut -f1))"
    ACTIVE_MODEL="$dest"; ACTIVE_BACKEND="gguf"; save_config
    ok "Active model set to: $dest"
  else
    info "Downloading full repo $repo (PyTorch)..."
    HF_REPO="$repo" HF_DEST="$MODELS_DIR/$repo" HF_TOKEN_VAL="${HF_TOKEN:-}" "$PYTHON" - <<'PYEOF'
import os,sys
try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("huggingface_hub not installed"); sys.exit(1)
os.makedirs(os.environ['HF_DEST'], exist_ok=True)
snapshot_download(repo_id=os.environ['HF_REPO'], local_dir=os.environ['HF_DEST'],
                  token=os.environ.get('HF_TOKEN_VAL') or None)
print(f"Downloaded: {os.environ['HF_DEST']}")
PYEOF
    ACTIVE_MODEL="$MODELS_DIR/$repo"; ACTIVE_BACKEND="pytorch"; save_config
  fi
}

cmd_recommended() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    download)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Number required"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err ERR204 "No model #$n"; return 1; }
      cmd_download "$(echo "$entry" | cut -d'|' -f1)" ;;
    use)
      local n="${1:-}"; [[ -z "$n" ]] && { err "Number required"; return 1; }
      local entry="${RECOMMENDED_MODELS[$n]:-}"; [[ -z "$entry" ]] && { err ERR204 "No model #$n"; return 1; }
      ACTIVE_MODEL="$(echo "$entry"|cut -d'|' -f1)"; ACTIVE_BACKEND="$(echo "$entry"|cut -d'|' -f2)"
      save_config; ok "Model: $ACTIVE_MODEL" ;;
    *)
      hdr "Recommended Models (${#RECOMMENDED_MODELS[@]} total)"
      echo ""

      # Helper: check if a gguf/hf model is already downloaded
      _is_downloaded() {
        local repo="$1" btype="$2"
        case "$btype" in
          gguf)
            # Check if any .gguf file from this repo exists in MODELS_DIR
            local repo_name; repo_name=$(basename "$repo")
            find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | \
              grep -qi "$repo_name" && return 0
            # Also check if ACTIVE_MODEL basename contains the repo name
            [[ -n "${ACTIVE_MODEL:-}" ]] && \
              echo "$(basename "${ACTIVE_MODEL}")" | grep -qi "$repo_name" && return 0
            return 1 ;;
          hf|pytorch)
            local dir="$MODELS_DIR/$repo"
            [[ -d "$dir" ]] && return 0
            return 1 ;;
          openai|claude|gemini)
            # Cloud API — "downloaded" if key is set
            case "$btype" in
              openai)  [[ -n "${OPENAI_API_KEY:-}"    ]] && return 0 ;;
              claude)  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0 ;;
              gemini)  [[ -n "${GEMINI_API_KEY:-}"    ]] && return 0 ;;
            esac
            return 1 ;;
          *) return 1 ;;
        esac
      }

      # Group headers
      local last_group=""
      local groups=(
        "1:8:TINY / CPU-FRIENDLY LLMs"
        "9:16:GENERAL-PURPOSE LLMs (7–70B)"
        "17:26:CODING & REASONING LLMs"
        "27:31:VISION / MULTIMODAL LLMs"
        "32:37:IMAGE GENERATION"
        "38:42:AUDIO / SPEECH"
        "43:46:EMBEDDING / RAG"
        "47:56:CLOUD API MODELS"
      )

      for grp in "${groups[@]}"; do
        local gstart="${grp%%:*}"; local rest="${grp#*:}"; local gend="${rest%%:*}"; local glabel="${rest#*:}"
        echo -e "  ${B}${BCYAN}── ${glabel} ──${R}"
        for key in $(seq "$gstart" "$gend"); do
          local entry="${RECOMMENDED_MODELS[$key]:-}"; [[ -z "$entry" ]] && continue
          local repo; repo=$(echo "$entry"|cut -d'|' -f1)
          local btype; btype=$(echo "$entry"|cut -d'|' -f2)
          local sz; sz=$(echo "$entry"|cut -d'|' -f3)
          local desc; desc=$(echo "$entry"|cut -d'|' -f4)
          local mark="  "
          _is_downloaded "$repo" "$btype" 2>/dev/null && mark="${BGREEN}✓${R}"
          [[ "$ACTIVE_MODEL" == "$repo" || "$ACTIVE_MODEL" == *"$(basename "$repo")"* ]] && mark="${BGREEN}▶${R}"
          printf "  %b ${B}%2d.${R} %-8s ${DIM}%-44s${R} %s\n" \
            "$mark" "$key" "$sz" "$repo" "$desc"
        done
        echo ""
      done

      echo -e "  ${BGREEN}✓${R} = downloaded   ${BGREEN}▶${R} = active   ${DIM}(cloud = key configured)${R}"
      echo ""
      echo -e "  Download: ${B}ai recommended download <N>${R}"
      echo -e "  Use:      ${B}ai recommended use <N>${R}"
      ;;
  esac
}

cmd_search_models() {
  local query="$*"; [[ -z "$query" ]] && { read -rp "Search: " query; }
  info "Searching: $query"
  curl -sS --max-time 30 "https://huggingface.co/api/models?search=${query// /+}&limit=15&sort=downloads" 2>/dev/null | \
    python3 -c "
import json,sys
for i,m in enumerate(json.load(sys.stdin),1):
    print(f'  {i:2}. {m.get(\"modelId\",\"?\")}')
    print(f'      ↓{m.get(\"downloads\",0):,}  ♥{m.get(\"likes\",0)}  [{', '.join(m.get(\"tags\",[])[:3])}]')
" 2>/dev/null
}

cmd_upload() {
  local path="${1:-}"; local repo="${2:-}"; local msg="${3:-upload via ai-cli}"
  [[ -z "$path" || -z "$repo" ]] && { err "Usage: ai upload <path> <user/repo>"; return 1; }
  [[ ! -e "$path" ]] && { err "Not found: $path"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }
  HF_TOKEN_VAL="$hf_key" P="$path" REPO="$repo" MSG="$msg" "$PYTHON" - <<'PYEOF'
import os,sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed"); sys.exit(1)
api=HfApi(token=os.environ['HF_TOKEN_VAL'])
repo=os.environ['REPO']; p=os.environ['P']; msg=os.environ['MSG']
try: api.create_repo(repo_id=repo,exist_ok=True,private=False)
except: pass
if os.path.isdir(p): api.upload_folder(folder_path=p,repo_id=repo,commit_message=msg)
else: api.upload_file(path_or_fileobj=p,path_in_repo=os.path.basename(p),repo_id=repo,commit_message=msg)
print(f"Uploaded: https://huggingface.co/{repo}")
PYEOF
}

cmd_model_info() {
  local m="${1:-$ACTIVE_MODEL}"; [[ -z "$m" ]] && { err "No model"; return 1; }
  hdr "Model: $m"
  if [[ -f "$m" ]]; then
    echo "  File: $m  ($(du -sh "$m"|cut -f1))"
  elif [[ -d "$m" && -f "$m/config.json" ]]; then
    python3 -c "import json; [print(f'  {k}: {v}') for k,v in list(json.load(open('$m/config.json')).items())[:15]]" 2>/dev/null
  else
    curl -sS --max-time 30 "https://huggingface.co/api/models/$m" 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(f'  ID: {d.get(\"modelId\",\"?\")}')
print(f'  Downloads: {d.get(\"downloads\",0):,}')
print(f'  Tags: {', '.join(d.get(\"tags\",[])[:5])}')
" 2>/dev/null
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  INSTALL / UNINSTALL
