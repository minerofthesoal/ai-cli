# ============================================================================
# MODULE: 19-dispatch.sh
# Final dispatch_ask + session + canvas + fine-tuning
# Source lines 7009-7778 of main-v2.7.3
# ============================================================================

#  FINE-TUNING PIPELINE
# ════════════════════════════════════════════════════════════════════════════════
_save_session_turn() {
  local user_msg="$1"; local ai_msg="$2"
  local session="${ACTIVE_SESSION:-default}"
  local sess_file="$SESSIONS_DIR/${session}.json"
  [[ ! -f "$sess_file" ]] && echo "[]" > "$sess_file"
  python3 -c "
import json,sys
f='$sess_file'
hist=json.load(open(f))
hist.append({'role':'user','content':$(echo "$user_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')})
hist.append({'role':'assistant','content':$(echo "$ai_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')})
# Keep last 20 turns
if len(hist)>40: hist=hist[-40:]
json.dump(hist,open(f,'w'),indent=2)
" 2>/dev/null || true
  # v2.6: Also append to project history (persistent multi-chat memory)
  if [[ -n "${ACTIVE_PROJECT:-}" && -d "$PROJECTS_DIR/$ACTIVE_PROJECT" ]]; then
    local proj_hist="$PROJECTS_DIR/$ACTIVE_PROJECT/history.jsonl"
    local ts; ts=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    printf '%s\n%s\n' \
      "{\"role\":\"user\",\"content\":$(echo "$user_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""'),\"ts\":\"$ts\"}" \
      "{\"role\":\"assistant\",\"content\":$(echo "$ai_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""'),\"ts\":\"$ts\"}" \
      >> "$proj_hist" 2>/dev/null || true
  fi
}

ask_gguf() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  if [[ -z "$model" ]]; then
    err ERR201 "No model set. Run: ai download 1  OR  ai recommended"
    return 1
  fi
  # v2.7.3: GGUF model resolution — search MODELS_DIR if direct path fails
  if [[ ! -f "$model" ]]; then
    # Try exact basename match in MODELS_DIR
    local candidate; candidate=$(find "$MODELS_DIR" -maxdepth 1 -name "$(basename "$model")" 2>/dev/null | head -1)
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      model="$candidate"
      ACTIVE_MODEL="$model"; save_config 2>/dev/null || true
    else
      # Try partial name match (case-insensitive)
      candidate=$(find "$MODELS_DIR" -maxdepth 1 -iname "*$(basename "$model" .gguf)*" -name "*.gguf" 2>/dev/null | head -1)
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        model="$candidate"
        ACTIVE_MODEL="$model"; save_config 2>/dev/null || true
      else
        err ERR202 "GGUF model not found: $model"
        echo "  Hint: Run 'ai models' to list downloaded models."
        echo "  Hint: Run 'ai recommended download <N>' to download a model."
        return 1
      fi
    fi
  fi

  if [[ "${LLAMA_BIN:-}" == "llama_cpp_python" ]]; then
    [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
    local sys_prompt; sys_prompt=$(_get_effective_system)
    LLAMA_PROMPT="$prompt" LLAMA_MODEL="$model" LLAMA_MAX="${MAX_TOKENS:-512}" \
    LLAMA_TEMP="${TEMPERATURE:-0.7}" LLAMA_CTX="${CONTEXT_SIZE:-4096}" \
    LLAMA_GPU="${GPU_LAYERS:-0}" LLAMA_SYS="$sys_prompt" \
    "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from llama_cpp import Llama
except ImportError:
    print("llama-cpp-python not installed. Run: ai install-deps", file=sys.stderr); sys.exit(1)
try:
    sys_prompt = os.environ.get('LLAMA_SYS', '').strip()
    user_prompt = os.environ['LLAMA_PROMPT']
    llm = Llama(model_path=os.environ['LLAMA_MODEL'],
                n_ctx=int(os.environ['LLAMA_CTX']),
                n_gpu_layers=int(os.environ['LLAMA_GPU']),
                verbose=False)
    # Use chat_completion if system prompt set, else plain completion
    if sys_prompt:
        out = llm.create_chat_completion(
            messages=[{"role": "system", "content": sys_prompt},
                      {"role": "user",   "content": user_prompt}],
            max_tokens=int(os.environ['LLAMA_MAX']),
            temperature=float(os.environ['LLAMA_TEMP']))
        print(out['choices'][0]['message']['content'], end='', flush=True)
    else:
        out = llm(user_prompt,
                  max_tokens=int(os.environ['LLAMA_MAX']),
                  temperature=float(os.environ['LLAMA_TEMP']),
                  stream=False)
        print(out['choices'][0]['text'], end='', flush=True)
except Exception as e:
    print(f"GGUF inference error: {e}", file=sys.stderr); sys.exit(1)
PYEOF
  elif [[ -n "${LLAMA_BIN:-}" ]]; then
    # Use llama.cpp binary — show stderr so user sees errors
    local _sys; _sys=$(_get_effective_system)
    local _prompt_arg="$prompt"
    # Prepend system as prefix when not empty
    [[ -n "$_sys" ]] && _prompt_arg="System: ${_sys}

User: ${prompt}"
    "$LLAMA_BIN" -m "$model" -p "$_prompt_arg" \
      -n "${MAX_TOKENS:-512}" --temp "${TEMPERATURE:-0.7}" \
      -c "${CONTEXT_SIZE:-4096}" \
      --n-gpu-layers "${GPU_LAYERS:-0}" \
      --threads "${THREADS:-4}" -s 0 --no-display-prompt 2>&1 | \
      grep -v "^llama\|^ggml\|^system\|^model\|^\[" || true
  else
    err "llama.cpp not found. Run: ai install-deps"
    info "Or install manually: pip install llama-cpp-python"
    return 1
  fi
}

ask_pytorch() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  if [[ -z "$model" ]]; then err "No model set. Run: ai model <path>  OR  ai ttm load"; return 1; fi
  if [[ -z "$PYTHON" ]]; then err "Python not found. Run: ai install-deps"; return 1; fi
  if [[ ! -d "$model" ]]; then err "Model directory not found: $model"; return 1; fi

  local sys_prompt; sys_prompt=$(_get_effective_system)
  MODEL_PATH="$model" PROMPT="$prompt" MAX_TOKENS="${MAX_TOKENS:-512}" \
  TEMPERATURE="${TEMPERATURE:-0.7}" SYS_PROMPT="$sys_prompt" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
except ImportError as e:
    print(f"Missing dependency: {e}\nRun: ai install-deps", file=sys.stderr); sys.exit(1)

mp         = os.environ['MODEL_PATH']
prompt     = os.environ['PROMPT']
sys_prompt = os.environ.get('SYS_PROMPT', '').strip()
maxt   = int(os.environ.get('MAX_TOKENS', 512))
temp   = float(os.environ.get('TEMPERATURE', 0.7))
device = 'cuda' if torch.cuda.is_available() else 'cpu'
dtype  = torch.float16 if device == 'cuda' else torch.float32

try:
    tok = AutoTokenizer.from_pretrained(mp, trust_remote_code=True)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    # v2.6 fix: patch config.json if model_type key is missing (causes unrecognized model error)
    import json as _json, pathlib as _pl
    _cfg_path = _pl.Path(mp) / 'config.json'
    if _cfg_path.exists():
        try:
            _cfg = _json.loads(_cfg_path.read_text())
            if 'model_type' not in _cfg:
                _cfg['model_type'] = 'llama'   # safe default; transformers will handle it
                _cfg_path.write_text(_json.dumps(_cfg, indent=2))
        except Exception:
            pass

    mdl = AutoModelForCausalLM.from_pretrained(mp, torch_dtype=dtype,
            low_cpu_mem_usage=True, trust_remote_code=True)
    mdl = mdl.to(device).eval()

    # Apply chat template if available, else use raw prompt
    # Inject system prompt (custom or persona) when the template supports it
    if hasattr(tok, 'apply_chat_template') and tok.chat_template:
        messages = []
        if sys_prompt:
            messages.append({"role": "system", "content": sys_prompt})
        messages.append({"role": "user", "content": prompt})
        input_ids = tok.apply_chat_template(messages, return_tensors='pt',
                                            add_generation_prompt=True).to(device)
    else:
        # Prepend system prompt as plain text when no chat template is available
        full_prompt = f"[SYSTEM]: {sys_prompt}\n\n[USER]: {prompt}" if sys_prompt else prompt
        input_ids = tok(full_prompt, return_tensors='pt').input_ids.to(device)

    gen_kwargs = dict(
        max_new_tokens=maxt,
        do_sample=(temp > 0),
        pad_token_id=tok.eos_token_id,
        eos_token_id=tok.eos_token_id,
    )
    if temp > 0:
        gen_kwargs['temperature'] = temp
        gen_kwargs['top_p'] = 0.9

    with torch.no_grad():
        out = mdl.generate(input_ids, **gen_kwargs)

    new_tokens = out[0][input_ids.shape[1]:]
    text = tok.decode(new_tokens, skip_special_tokens=True).strip()
    print(text, flush=True)
except FileNotFoundError:
    print(f"Model not found: {mp}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    import traceback
    print(f"PyTorch inference error: {e}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
}

ask_openai() {
  local prompt="$1"
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "OPENAI_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-gpt-4o}"
  local sys_prompt; sys_prompt=$(_get_effective_system)

  local messages_json
  messages_json=$(python3 -c "
import json,sys
sys_p=$(echo "$sys_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
user_p=$(echo "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
msgs=[{'role':'system','content':sys_p},{'role':'user','content':user_p}]
print(json.dumps(msgs))
" 2>/dev/null)

  local body; body=$(python3 -c "
import json
body={'model':'${model}','messages':${messages_json},'max_tokens':${MAX_TOKENS},'temperature':${TEMPERATURE},'stream':False}
print(json.dumps(body))
" 2>/dev/null)

  curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['choices'][0]['message']['content'],end='',flush=True)
" 2>/dev/null
}

ask_claude() {
  local prompt="$1"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "ANTHROPIC_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-claude-sonnet-4-5}"
  local sys_prompt; sys_prompt=$(_get_effective_system)

  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)
  local sys_content; sys_content=$(echo "$sys_prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)

  curl -sS https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":$MAX_TOKENS,\"system\":$sys_content,\"messages\":[{\"role\":\"user\",\"content\":$user_content}]}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['content'][0]['text'],end='',flush=True)
" 2>/dev/null
}

ask_gemini() {
  local prompt="$1"
  [[ -z "${GEMINI_API_KEY:-}" ]] && { err "GEMINI_API_KEY not set"; return 1; }
  local model="${ACTIVE_MODEL:-gemini-2.0-flash}"
  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)

  curl -sS "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"contents\":[{\"parts\":[{\"text\":$user_content}]}]}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(f\"Error: {d['error']['message']}\",file=sys.stderr)
else: print(d['candidates'][0]['content']['parts'][0]['text'],end='',flush=True)
" 2>/dev/null
}

ask_hf() {
  local prompt="$1"
  local model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && { err "No model set"; return 1; }
  local hf_key="${HF_TOKEN:-}"
  local auth_header=""
  [[ -n "$hf_key" ]] && auth_header="-H \"Authorization: Bearer $hf_key\""
  local user_content; user_content=$(echo "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null)
  curl -sS "https://api-inference.huggingface.co/models/${model}" \
    ${hf_key:+-H "Authorization: Bearer $hf_key"} \
    -H "Content-Type: application/json" \
    -d "{\"inputs\":$user_content,\"parameters\":{\"max_new_tokens\":$MAX_TOKENS,\"temperature\":$TEMPERATURE}}" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
if isinstance(d,list): print(d[0].get('generated_text',''),end='')
elif isinstance(d,dict): print(d.get('generated_text',str(d)),end='')
" 2>/dev/null
}

_auto_detect_backend() {
  local model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && {
    [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo "claude"; return; }
    [[ -n "${GEMINI_API_KEY:-}" ]] && { echo "gemini"; return; }
    echo ""; return
  }
  [[ "$model" == gpt-* || "$model" == o1* || "$model" == o3* ]] && { echo "openai"; return; }
  [[ "$model" == claude-* ]] && { echo "claude"; return; }
  [[ "$model" == gemini-* ]] && { echo "gemini"; return; }
  # gguf detection — all conditions in a single bracket to avoid || short-circuit bug
  if [[ "$model" == *.gguf || "$model" == *Q4_K* || "$model" == *Q5_K* || \
        "$model" == *Q8_0* || "$model" == *Q4_0* || "$model" == *IQ4* ]]; then
    echo "gguf"; return
  fi
  [[ -f "$model" ]] && { echo "gguf"; return; }          # any local file → gguf
  [[ -d "$model" && -f "$model/config.json" ]] && { echo "pytorch"; return; }
  # HuggingFace repo id (org/name format, no local path)
  if [[ "$model" == */* && ! -d "$model" ]]; then
    echo "hf"; return
  fi
  # Fallback: if API key available use it
  [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo "claude"; return; }
  [[ -n "${GEMINI_API_KEY:-}" ]] && { echo "gemini"; return; }
  echo "gguf"
}

_maybe_inject_search() {
  local prompt="$1"
  [[ "$WEB_SEARCH_ENABLED" != "1" ]] && { echo "$prompt"; return; }
  local backend; backend=$(_auto_detect_backend)
  # OpenAI tool calling handles its own search
  [[ "$backend" == "openai" ]] && { echo "$prompt"; return; }
  # Detect search-worthy keywords
  if echo "$prompt" | grep -qiE 'latest|current|today|2024|2025|2026|news|price|who is|what is the status|recent|now|trending'; then
    local search_terms; search_terms=$(echo "$prompt" | sed 's/[?!.,]//g' | tr '[:upper:]' '[:lower:]' | \
      sed 's/what is//g;s/who is//g;s/tell me about//g;s/the latest//g' | \
      awk '{for(i=1;i<=NF&&i<=6;i++) printf $i" "; print ""}' | xargs)
    local results; results=$(web_search "$search_terms" 3 2>/dev/null)
    if [[ -n "$results" ]]; then
      echo "[Web search results for context:]
$results

[User question:] $prompt"
      return
    fi
  fi
  echo "$prompt"
}

dispatch_ask() {
  local prompt="$1"
  local backend="${ACTIVE_BACKEND:-}"
  [[ -z "$backend" ]] && backend=$(_auto_detect_backend)

  # No backend at all — give clear diagnostic
  if [[ -z "$backend" ]]; then
    err "No model or API key configured."
    echo ""
    echo -e "${BCYAN}Quick setup:${R}"
    echo "  ai keys set OPENAI_API_KEY sk-...        (OpenAI GPT-4)"
    echo "  ai keys set ANTHROPIC_API_KEY sk-ant-... (Claude)"
    echo "  ai keys set GEMINI_API_KEY AIza...       (Gemini)"
    echo "  ai download 1                             (tiny local model, any CPU)"
    echo "  ai recommended                            (browse 28 curated models)"
    return 1
  fi

  # Auto-inject web search if needed
  local enriched_prompt; enriched_prompt=$(_maybe_inject_search "$prompt")

  local response="" rc=0
  case "$backend" in
    gguf)      response=$(ask_gguf "$enriched_prompt");   rc=$? ;;
    pytorch)   response=$(ask_pytorch "$enriched_prompt"); rc=$? ;;
    openai)    response=$(ask_openai "$enriched_prompt");  rc=$? ;;
    claude)    response=$(ask_claude "$enriched_prompt");  rc=$? ;;
    gemini)    response=$(ask_gemini "$enriched_prompt");  rc=$? ;;
    hf)        response=$(ask_hf "$enriched_prompt");      rc=$? ;;
    diffusers)
      cmd_imagine "$enriched_prompt"
      response="[Image generated]"
      ;;
    *)
      if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="openai"; response=$(ask_openai "$enriched_prompt"); rc=$?
      elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="claude"; response=$(ask_claude "$enriched_prompt"); rc=$?
      elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
        ACTIVE_BACKEND="gemini"; response=$(ask_gemini "$enriched_prompt"); rc=$?
      else
        err "Unknown backend '$backend'. Run: ai status"
        return 1
      fi
      ;;
  esac

  if [[ $rc -ne 0 || -z "$response" ]]; then
    err "No response from backend '$backend'."
    [[ -z "${ACTIVE_MODEL:-}" ]] && echo "  Hint: no model set. Run: ai recommended"
    [[ "$backend" == "pytorch" && ! -d "${ACTIVE_MODEL:-x}" ]] && \
      echo "  Hint: model dir not found (${ACTIVE_MODEL:-not set}). Run: ai ttm pretrain"
    [[ "$backend" == "gguf" && ! -f "${ACTIVE_MODEL:-x}" ]] && \
      echo "  Hint: model file not found (${ACTIVE_MODEL:-not set}). Run: ai download 1"
    return 1
  fi

  echo "$response"
  log_history "user" "$prompt"
  log_history "assistant" "$response"
  _save_session_turn "$prompt" "$response"
  [[ -n "${CURRENT_CHAT_FILE:-}" ]] && _chat_append "assistant" "$response"

  # Background TTM batch train if enabled
  [[ "${TTM_AUTO_TRAIN:-0}" == "1" ]] && { _ttm_train_batch &>/dev/null & disown; } 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════════
#  CANVAS — Code workspace with AI assistance
# ════════════════════════════════════════════════════════════════════════════════
cmd_canvas() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    new)
      local name="${1:-canvas_$(date +%H%M%S)}"; local lang="${2:-python}"
      local file="$CANVAS_DIR/${name}.${lang}"
      touch "$file"; CANVAS_ACTIVE="$file"; save_config
      ok "Canvas: $file"
      ;;
    open)
      local f="${1:-}"; [[ -z "$f" ]] && { err "File required"; return 1; }
      [[ ! -f "$f" ]] && { err "Not found: $f"; return 1; }
      CANVAS_ACTIVE="$f"; save_config; ok "Canvas: $f"
      ;;
    edit)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      "${EDITOR:-nano}" "$CANVAS_ACTIVE"
      ;;
    show)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      hdr "Canvas: $CANVAS_ACTIVE"
      cat -n "$CANVAS_ACTIVE"
      ;;
    run)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local ext="${CANVAS_ACTIVE##*.}"
      case "$ext" in
        py|python) python3 "$CANVAS_ACTIVE" ;;
        sh|bash)   bash "$CANVAS_ACTIVE" ;;
        js|ts)     node "$CANVAS_ACTIVE" 2>/dev/null || npx ts-node "$CANVAS_ACTIVE" ;;
        c)         gcc "$CANVAS_ACTIVE" -o /tmp/canvas_out && /tmp/canvas_out ;;
        cpp)       g++ "$CANVAS_ACTIVE" -o /tmp/canvas_out && /tmp/canvas_out ;;
        *)         err "Unknown extension: $ext" ;;
      esac
      ;;
    ask)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local task="$*"
      [[ -z "$task" ]] && { read -rp "Task: " task; }
      local current_code=""
      [[ -s "$CANVAS_ACTIVE" ]] && current_code=$(cat "$CANVAS_ACTIVE")
      local prompt
      if [[ -z "$current_code" ]]; then
        prompt="Write code for this task. Return ONLY the code, no explanation, no markdown fences.

Task: $task"
      else
        prompt="Here is the current code:
\`\`\`
$current_code
\`\`\`

Modify it for this task. Return ONLY the complete updated code, no explanation, no markdown fences.

Task: $task"
      fi
      info "Generating code..."
      local result; result=$(dispatch_ask "$prompt" 2>/dev/null)
      # Strip markdown fences
      result=$(echo "$result" | sed 's/^```[a-z]*$//' | sed 's/^```$//')
      echo "$result" > "$CANVAS_ACTIVE"
      ok "Canvas updated. Lines: $(wc -l < "$CANVAS_ACTIVE")"
      cat -n "$CANVAS_ACTIVE"
      ;;
    diff)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      git diff "$CANVAS_ACTIVE" 2>/dev/null || diff /dev/null "$CANVAS_ACTIVE"
      ;;
    save)
      [[ -z "$CANVAS_ACTIVE" ]] && { err "No active canvas"; return 1; }
      local dest="${1:-$AI_OUTPUT_DIR/$(basename "$CANVAS_ACTIVE")}"
      cp "$CANVAS_ACTIVE" "$dest"; ok "Saved: $dest"
      ;;
    list)
      hdr "Canvas files"
      for f in "$CANVAS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local lines; lines=$(wc -l < "$f")
        local active=""
        [[ "$f" == "$CANVAS_ACTIVE" ]] && active=" ${BGREEN}◀ active${R}"
        printf "  %-40s %4d lines%b\n" "$(basename "$f")" "$lines" "$active"
      done
      ;;
    close) CANVAS_ACTIVE=""; save_config; ok "Canvas closed" ;;
    status)
      [[ -n "$CANVAS_ACTIVE" ]] && ok "Active: $CANVAS_ACTIVE ($(wc -l < "$CANVAS_ACTIVE" 2>/dev/null || echo 0) lines)" || info "No active canvas"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  FINE-TUNING PIPELINE
# ════════════════════════════════════════════════════════════════════════════════
cmd_finetune() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    prepare)
      local data="${1:-}"; [[ -z "$data" ]] && { err "Data file required"; return 1; }
      [[ ! -f "$data" ]] && { err "Not found: $data"; return 1; }
      local out="$FINETUNE_DIR/dataset.jsonl"
      info "Preparing dataset from $data..."
      "$PYTHON" - <<PYEOF
import json, re
data_file = "$data"
out_file = "$out"
records = []
with open(data_file) as f:
    content = f.read()
# Try JSONL
try:
    for line in content.splitlines():
        line = line.strip()
        if not line: continue
        obj = json.loads(line)
        if isinstance(obj, dict):
            txt = obj.get('text') or (obj.get('instruction','') + '\n' + obj.get('output',''))
            records.append({'text': txt})
    print(f"Loaded {len(records)} JSONL records")
except:
    # Try Q&A format
    pairs = re.split(r'### Human:', content)
    for p in pairs:
        if '### Assistant:' in p:
            parts = p.split('### Assistant:', 1)
            q = parts[0].strip(); a = parts[1].strip()
            if q and a:
                records.append({'text': f'### Human: {q}\n### Assistant: {a}'})
    if not records:
        # Plain text: split into chunks
        chunks = [content[i:i+512] for i in range(0,len(content),512)]
        records = [{'text': c} for c in chunks if c.strip()]
    print(f"Prepared {len(records)} records from plain text/QA")

with open(out_file, 'w') as f:
    for r in records:
        f.write(json.dumps(r) + '\n')
print(f"Saved: {out_file}")
PYEOF
      ;;
    start)
      local base="${1:-}"; local data="${2:-$FINETUNE_DIR/dataset.jsonl}"; local out="${3:-$FINETUNE_DIR/finetuned_$(date +%Y%m%d_%H%M%S)}"
      [[ -z "$base" ]] && { err "Base model required"; return 1; }
      [[ ! -f "$data" ]] && { err "Dataset not found: $data. Run: ai finetune prepare <data>"; return 1; }
      info "Starting LoRA fine-tune: $base → $out"
      mkdir -p "$out"
      BASE_MODEL="$base" DATA_FILE="$data" OUT_DIR="$out" "$PYTHON" - <<'PYEOF'
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
    from trl import SFTTrainer
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)
base = os.environ['BASE_MODEL']
data_file = os.environ['DATA_FILE']
out_dir   = os.environ['OUT_DIR']
tokenizer = AutoTokenizer.from_pretrained(base)
tokenizer.pad_token = tokenizer.eos_token
model = AutoModelForCausalLM.from_pretrained(base, torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32)
lora = LoraConfig(task_type=TaskType.CAUSAL_LM,r=16,lora_alpha=32,lora_dropout=0.05,target_modules=["q_proj","k_proj","v_proj","o_proj"])
model = get_peft_model(model, lora)
records=[]
with open(data_file) as f:
    for line in f:
        obj=json.loads(line); txt=obj.get('text','')
        if txt: records.append({'text':txt})
ds = Dataset.from_list(records)
device='cuda' if torch.cuda.is_available() else 'cpu'
model=model.to(device)
args=TrainingArguments(output_dir=out_dir,num_train_epochs=3,per_device_train_batch_size=1,gradient_accumulation_steps=4,learning_rate=2e-4,fp16=(device=='cuda'),logging_steps=20,save_steps=200,save_total_limit=2,report_to='none')
trainer=SFTTrainer(model=model,args=args,train_dataset=ds,tokenizer=tokenizer,dataset_text_field='text',max_seq_length=512)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved: {out_dir}")
PYEOF
      ;;
    merge)
      local adapter="${1:-}"; local base="${2:-}"; local out="${3:-${1}_merged}"
      [[ -z "$adapter" || -z "$base" ]] && { err "Usage: ai finetune merge <adapter> <base> [out]"; return 1; }
      info "Merging adapter into base model..."
      ADAPTER="$adapter" BASE="$base" OUT="$out" "$PYTHON" - <<'PYEOF'
import os,torch
from transformers import AutoTokenizer
from peft import PeftModel, AutoPeftModelForCausalLM
base=os.environ['BASE']; adapter=os.environ['ADAPTER']; out=os.environ['OUT']
model=AutoPeftModelForCausalLM.from_pretrained(adapter,torch_dtype=torch.float16)
merged=model.merge_and_unload()
merged.save_pretrained(out)
tok=AutoTokenizer.from_pretrained(base)
tok.save_pretrained(out)
print(f"Merged: {out}")
PYEOF
      ;;
    quantize)
      local model="${1:-}"; local quant="${2:-Q4_K_M}"
      [[ -z "$model" ]] && { err "Model path required"; return 1; }
      local script="$HOME/llama.cpp/convert_hf_to_gguf.py"
      [[ ! -f "$script" ]] && { err "llama.cpp not found at $HOME/llama.cpp"; return 1; }
      local out="${model}_${quant}.gguf"
      info "Quantizing to $quant..."
      "$PYTHON" "$script" "$model" --outfile "$out" --outtype "${quant,,}" && ok "GGUF: $out"
      ;;
    any|universal|lora-any)
      # Fine-tune ANY HuggingFace model with LoRA
      local any_model="${1:-}"; shift || true
      [[ -z "$any_model" ]] && { err "Usage: ai finetune any <model> [--data <file>] [--epochs N] [--merge] [--quantize]"; return 1; }
      local any_data="$FINETUNE_DIR/dataset.jsonl"
      local any_epochs=3
      local any_merge=0
      local any_quantize=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data)     any_data="$2";     shift 2 ;;
          --epochs)   any_epochs="$2";   shift 2 ;;
          --merge)    any_merge=1;       shift   ;;
          --quantize) any_quantize="${2:-Q4_K_M}"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ ! -f "$any_data" ]] && { err "Dataset not found: $any_data\nRun: ai finetune prepare <data>  or  ai dataset generate <name> <topic>"; return 1; }
      local any_out="$FINETUNE_DIR/finetuned_any_$(date +%Y%m%d_%H%M%S)"
      info "Fine-tuning $any_model → $any_out (LoRA, epochs=$any_epochs)"
      mkdir -p "$any_out"
      ANY_MODEL="$any_model" ANY_DATA="$any_data" ANY_OUT="$any_out" ANY_EPOCHS="$any_epochs" "$PYTHON" - <<'PYEOF'
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, AutoModelForSeq2SeqLM, TrainingArguments
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
    from trl import SFTTrainer
except ImportError as e:
    print(f"Missing dependency: {e}\nRun: pip install transformers peft trl datasets"); sys.exit(1)

model_id  = os.environ['ANY_MODEL']
data_file = os.environ['ANY_DATA']
out_dir   = os.environ['ANY_OUT']
epochs    = int(os.environ.get('ANY_EPOCHS', '3'))

# Device selection
if torch.cuda.is_available():
    device = 'cuda'
elif hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
    device = 'mps'
else:
    device = 'cpu'
dtype = torch.float16 if device in ('cuda', 'mps') else torch.float32

print(f"Device: {device} | Model: {model_id}")
tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

# Try CausalLM first, fall back to Seq2Seq
try:
    model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=dtype, trust_remote_code=True)
    task = TaskType.CAUSAL_LM
except Exception:
    model = AutoModelForSeq2SeqLM.from_pretrained(model_id, torch_dtype=dtype, trust_remote_code=True)
    task = TaskType.SEQ_2_SEQ_LM

# Auto-select LoRA target modules based on model architecture
model_type = getattr(model.config, 'model_type', '').lower()
target_map = {
    'llama':   ['q_proj','k_proj','v_proj','o_proj'],
    'mistral': ['q_proj','k_proj','v_proj','o_proj'],
    'mixtral': ['q_proj','k_proj','v_proj','o_proj'],
    'qwen2':   ['q_proj','k_proj','v_proj','o_proj'],
    'phi':     ['q_proj','v_proj'],
    'falcon':  ['query_key_value'],
    'mpt':     ['Wqkv'],
    'gpt2':    ['c_attn','c_proj'],
    'gpt_neox':['query_key_value'],
    't5':      ['q','v'],
    'bart':    ['q_proj','v_proj'],
}
targets = target_map.get(model_type, ['q_proj','v_proj'])
print(f"Model type: {model_type or 'unknown'} | LoRA targets: {targets}")

lora_cfg = LoraConfig(task_type=task, r=16, lora_alpha=32, lora_dropout=0.05, target_modules=targets)
model = get_peft_model(model, lora_cfg)
model.print_trainable_parameters()

records = []
with open(data_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        obj = json.loads(line)
        txt = obj.get('text','')
        if txt: records.append({'text': txt})
ds = Dataset.from_list(records)
print(f"Training records: {len(records)}")

model = model.to(device)
args = TrainingArguments(
    output_dir=out_dir, num_train_epochs=epochs,
    per_device_train_batch_size=1, gradient_accumulation_steps=4,
    learning_rate=2e-4, fp16=(device=='cuda'), bf16=False,
    logging_steps=20, save_steps=200, save_total_limit=2, report_to='none'
)
trainer = SFTTrainer(model=model, args=args, train_dataset=ds,
                     tokenizer=tokenizer, dataset_text_field='text', max_seq_length=512)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved adapter: {out_dir}")
PYEOF
      ok "Fine-tune complete: $any_out"
      # Optional merge
      if [[ "$any_merge" == "1" ]]; then
        info "Merging adapter into base model..."
        local merged_out="${any_out}_merged"
        ADAPTER="$any_out" BASE="$any_model" OUT="$merged_out" "$PYTHON" - <<'PYEOF'
import os, torch
from transformers import AutoTokenizer
from peft import AutoPeftModelForCausalLM
adapter=os.environ['ADAPTER']; base=os.environ['BASE']; out=os.environ['OUT']
model=AutoPeftModelForCausalLM.from_pretrained(adapter, torch_dtype=torch.float16)
merged=model.merge_and_unload()
merged.save_pretrained(out)
tok=AutoTokenizer.from_pretrained(base)
tok.save_pretrained(out)
print(f"Merged: {out}")
PYEOF
        ok "Merged model: $merged_out"
        any_out="$merged_out"
      fi
      # Optional quantize
      if [[ -n "$any_quantize" ]]; then
        local script="$HOME/llama.cpp/convert_hf_to_gguf.py"
        if [[ -f "$script" ]]; then
          local gguf_out="${any_out}_${any_quantize}.gguf"
          info "Quantizing to $any_quantize..."
          "$PYTHON" "$script" "$any_out" --outfile "$gguf_out" --outtype "${any_quantize,,}" && ok "GGUF: $gguf_out"
        else
          warn "llama.cpp not found; skipping quantize. Clone to $HOME/llama.cpp to enable."
        fi
      fi
      ;;
    status)
      hdr "Fine-tune Status"
      [[ -f "$FINETUNE_DIR/dataset.jsonl" ]] && echo "  Dataset: $(wc -l < "$FINETUNE_DIR/dataset.jsonl") records" || echo "  Dataset: none"
      ls -td "$FINETUNE_DIR"/finetuned_*/ 2>/dev/null | head -5 | while read -r d; do
        echo "  Model: $(basename "$d") ($(du -sh "$d" 2>/dev/null | cut -f1))"
      done
      ;;
    *) echo "Usage: ai finetune prepare|start|merge|quantize|any|status" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  IMAGE GENERATION
