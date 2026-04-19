#!/usr/bin/env bash
# AI CLI v3.1.0 — Backend module
# All LLM API backends: OpenAI, Claude, Gemini, Groq, Mistral, Together, HF, GGUF, PyTorch

# ── Personas ──────────────────────────────────────────────────────────────────
declare -A BUILTIN_PERSONAS=(
  [default]="You are a helpful, friendly AI assistant."
  [dev]="You are an expert software engineer. Write clean, secure, well-documented code."
  [researcher]="You are a rigorous researcher. Cite reasoning. Acknowledge uncertainty."
  [writer]="You are a skilled writer. Prioritize clarity, flow, and engagement."
  [teacher]="You are a patient teacher. Use analogies and examples."
  [sysadmin]="You are a Linux/DevOps expert. Give precise commands."
  [creative]="You are a bold, original creative. Push boundaries."
  [concise]="Be maximally concise. Fewest words without losing accuracy."
)

_get_persona_prompt() {
  local name="${ACTIVE_PERSONA:-default}"
  if [[ -f "$PERSONAS_DIR/$name" ]]; then cat "$PERSONAS_DIR/$name"
  elif [[ -n "${BUILTIN_PERSONAS[$name]:-}" ]]; then echo "${BUILTIN_PERSONAS[$name]}"
  else echo "${BUILTIN_PERSONAS[default]}"
  fi
}

_get_effective_system() {
  if [[ -n "${CUSTOM_SYSTEM_PROMPT:-}" ]]; then echo "$CUSTOM_SYSTEM_PROMPT"; return; fi
  _get_persona_prompt
}

# ── Generic OpenAI-compatible API caller ──────────────────────────────────────
_call_openai_compatible() {
  local url="$1" key="$2" model="$3" prompt="$4" max_tok="${5:-$MAX_TOKENS}" temp="${6:-$TEMPERATURE}"
  local sys_prompt; sys_prompt=$(_get_effective_system)
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  ASKAPI_URL="$url" ASKAPI_KEY="$key" ASKAPI_MODEL="$model" \
  ASKAPI_PROMPT="$prompt" ASKAPI_SYS="$sys_prompt" \
  ASKAPI_MAX="$max_tok" ASKAPI_TEMP="$temp" "$PYTHON" -c '
import os,json,urllib.request,sys
body=json.dumps({"model":os.environ["ASKAPI_MODEL"],
  "max_tokens":int(os.environ["ASKAPI_MAX"]),
  "temperature":float(os.environ["ASKAPI_TEMP"]),
  "messages":[{"role":"system","content":os.environ["ASKAPI_SYS"]},
              {"role":"user","content":os.environ["ASKAPI_PROMPT"]}]})
req=urllib.request.Request(os.environ["ASKAPI_URL"],data=body.encode(),
  headers={"Authorization":"Bearer "+os.environ["ASKAPI_KEY"],
           "Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=120) as r:
    d=json.loads(r.read())
  if "error" in d: print(d["error"].get("message",str(d["error"])),file=sys.stderr)
  else: print(d["choices"][0]["message"]["content"],end="",flush=True)
except urllib.error.HTTPError as e:
  print(f"API error {e.code}: {e.read().decode()[:200]}",file=sys.stderr)
except Exception as e:
  print(f"Error: {e}",file=sys.stderr)
' 2>/dev/null
}

# ── Individual Backends ───────────────────────────────────────────────────────
ask_openai() {
  [[ -z "${OPENAI_API_KEY:-}" ]] && { err "OPENAI_API_KEY not set"; return 1; }
  _call_openai_compatible "https://api.openai.com/v1/chat/completions" \
    "$OPENAI_API_KEY" "${ACTIVE_MODEL:-gpt-4o}" "$1"
}

ask_claude() {
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "ANTHROPIC_API_KEY not set"; return 1; }
  local prompt="$1"
  local sys_prompt; sys_prompt=$(_get_effective_system)
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  ASKAPI_PROMPT="$prompt" ASKAPI_SYS="$sys_prompt" \
  ASKAPI_MODEL="${ACTIVE_MODEL:-claude-sonnet-4-6}" \
  ASKAPI_MAX="$MAX_TOKENS" ASKAPI_KEY="$ANTHROPIC_API_KEY" "$PYTHON" -c '
import os,json,urllib.request,sys
body=json.dumps({"model":os.environ["ASKAPI_MODEL"],
  "max_tokens":int(os.environ["ASKAPI_MAX"]),
  "system":os.environ["ASKAPI_SYS"],
  "messages":[{"role":"user","content":os.environ["ASKAPI_PROMPT"]}]})
req=urllib.request.Request("https://api.anthropic.com/v1/messages",data=body.encode(),
  headers={"x-api-key":os.environ["ASKAPI_KEY"],"anthropic-version":"2023-06-01",
           "Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=120) as r:
    d=json.loads(r.read())
  if "error" in d: print(d["error"].get("message",str(d["error"])),file=sys.stderr)
  else: print(d["content"][0]["text"],end="",flush=True)
except Exception as e:
  print(f"Claude error: {e}",file=sys.stderr)
' 2>/dev/null
}

ask_gemini() {
  [[ -z "${GEMINI_API_KEY:-}" ]] && { err "GEMINI_API_KEY not set"; return 1; }
  local prompt="$1" model="${ACTIVE_MODEL:-gemini-2.0-flash}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  ASKAPI_PROMPT="$prompt" ASKAPI_MODEL="$model" ASKAPI_KEY="$GEMINI_API_KEY" "$PYTHON" -c '
import os,json,urllib.request,sys
body=json.dumps({"contents":[{"parts":[{"text":os.environ["ASKAPI_PROMPT"]}]}]})
url=f"https://generativelanguage.googleapis.com/v1beta/models/{os.environ[\"ASKAPI_MODEL\"]}:generateContent?key={os.environ[\"ASKAPI_KEY\"]}"
req=urllib.request.Request(url,data=body.encode(),headers={"Content-Type":"application/json"})
try:
  with urllib.request.urlopen(req,timeout=120) as r:
    d=json.loads(r.read())
  if "error" in d: print(d["error"]["message"],file=sys.stderr)
  else: print(d["candidates"][0]["content"]["parts"][0]["text"],end="",flush=True)
except Exception as e:
  print(f"Gemini error: {e}",file=sys.stderr)
' 2>/dev/null
}

ask_groq() {
  [[ -z "${GROQ_API_KEY:-}" ]] && { err "GROQ_API_KEY not set"; return 1; }
  _call_openai_compatible "https://api.groq.com/openai/v1/chat/completions" \
    "$GROQ_API_KEY" "${ACTIVE_MODEL:-llama-3.3-70b-versatile}" "$1"
}

ask_mistral() {
  [[ -z "${MISTRAL_API_KEY:-}" ]] && { err "MISTRAL_API_KEY not set"; return 1; }
  _call_openai_compatible "https://api.mistral.ai/v1/chat/completions" \
    "$MISTRAL_API_KEY" "${ACTIVE_MODEL:-mistral-small-latest}" "$1"
}

ask_together() {
  [[ -z "${TOGETHER_API_KEY:-}" ]] && { err "TOGETHER_API_KEY not set"; return 1; }
  _call_openai_compatible "https://api.together.xyz/v1/chat/completions" \
    "$TOGETHER_API_KEY" "${ACTIVE_MODEL:-meta-llama/Llama-3.3-70B-Instruct-Turbo}" "$1"
}

ask_hf() {
  local prompt="$1" model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && { err "No model set"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  ASKAPI_PROMPT="$prompt" ASKAPI_MODEL="$model" ASKAPI_KEY="${HF_TOKEN:-}" "$PYTHON" -c '
import os,json,urllib.request,sys
body=json.dumps({"inputs":os.environ["ASKAPI_PROMPT"],"parameters":{"max_new_tokens":2048}})
headers={"Content-Type":"application/json"}
key=os.environ.get("ASKAPI_KEY","")
if key: headers["Authorization"]=f"Bearer {key}"
req=urllib.request.Request(f"https://api-inference.huggingface.co/models/{os.environ[\"ASKAPI_MODEL\"]}",
  data=body.encode(),headers=headers)
try:
  with urllib.request.urlopen(req,timeout=120) as r:
    d=json.loads(r.read())
  if isinstance(d,list): print(d[0].get("generated_text",""),end="")
  elif isinstance(d,dict): print(d.get("generated_text",str(d)),end="")
except Exception as e:
  print(f"HF error: {e}",file=sys.stderr)
' 2>/dev/null
}

ask_gguf() {
  local prompt="$1" model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && { err "No model set. Run: ai recommended download 1"; return 1; }
  # Resolve model path
  if [[ ! -f "$model" ]]; then
    local candidate
    candidate=$(find "$MODELS_DIR" -maxdepth 1 -iname "*$(basename "$model" .gguf)*" -name "*.gguf" 2>/dev/null | head -1)
    [[ -n "$candidate" ]] && model="$candidate" || { err "Model not found: $model"; return 1; }
  fi
  local sys_prompt; sys_prompt=$(_get_effective_system)

  if [[ "${LLAMA_BIN:-}" == "llama_cpp_python" ]]; then
    LLAMA_PROMPT="$prompt" LLAMA_MODEL="$model" LLAMA_MAX="${MAX_TOKENS:-512}" \
    LLAMA_TEMP="${TEMPERATURE:-0.7}" LLAMA_CTX="${CONTEXT_SIZE:-4096}" \
    LLAMA_GPU="${GPU_LAYERS:--1}" LLAMA_SYS="$sys_prompt" "$PYTHON" -c '
import os,sys,logging; logging.disable(logging.WARNING); os.environ["LLAMA_LOG_LEVEL"]="0"
from llama_cpp import Llama
llm=Llama(model_path=os.environ["LLAMA_MODEL"],n_ctx=int(os.environ["LLAMA_CTX"]),
  n_gpu_layers=int(os.environ["LLAMA_GPU"]),verbose=False)
sp=os.environ.get("LLAMA_SYS","").strip()
if sp:
  out=llm.create_chat_completion(messages=[{"role":"system","content":sp},
    {"role":"user","content":os.environ["LLAMA_PROMPT"]}],
    max_tokens=int(os.environ["LLAMA_MAX"]),temperature=float(os.environ["LLAMA_TEMP"]))
  print(out["choices"][0]["message"]["content"],end="",flush=True)
else:
  out=llm(os.environ["LLAMA_PROMPT"],max_tokens=int(os.environ["LLAMA_MAX"]),
    temperature=float(os.environ["LLAMA_TEMP"]),stream=False)
  print(out["choices"][0]["text"],end="",flush=True)
' 2>/dev/null
  elif [[ -n "${LLAMA_BIN:-}" ]]; then
    local _prompt_arg="$prompt"
    [[ -n "$sys_prompt" ]] && _prompt_arg="System: ${sys_prompt}

User: ${prompt}"
    "$LLAMA_BIN" -m "$model" -p "$_prompt_arg" \
      -n "${MAX_TOKENS:-512}" --temp "${TEMPERATURE:-0.7}" \
      -c "${CONTEXT_SIZE:-4096}" --n-gpu-layers "${GPU_LAYERS:--1}" \
      --threads "${THREADS:-4}" -s 0 --no-display-prompt --log-disable 2>/dev/null | \
      grep -v "^llama_\|^ggml_\|^llm_load\|^system_info\|^main:\|^sampling:\|^build info\|warning:" || true
  else
    err "llama.cpp not found. Run: ai install-deps"
    return 1
  fi
}

# ── Backend Auto-Detection ────────────────────────────────────────────────────
_auto_detect_backend() {
  local model="${ACTIVE_MODEL:-}"
  [[ -z "$model" ]] && {
    [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo "claude"; return; }
    [[ -n "${GEMINI_API_KEY:-}" ]] && { echo "gemini"; return; }
    [[ -n "${GROQ_API_KEY:-}" ]] && { echo "groq"; return; }
    echo ""; return
  }
  [[ "$model" == gpt-* || "$model" == o1* || "$model" == o3* || "$model" == chatgpt-* ]] && { echo "openai"; return; }
  [[ "$model" == claude-* ]] && { echo "claude"; return; }
  [[ "$model" == gemini-* ]] && { echo "gemini"; return; }
  [[ "$model" == llama-* || "$model" == mixtral-* ]] && [[ -n "${GROQ_API_KEY:-}" ]] && { echo "groq"; return; }
  [[ "$model" == mistral-* || "$model" == codestral-* ]] && { echo "mistral"; return; }
  [[ "$model" == meta-llama/* ]] && [[ -n "${TOGETHER_API_KEY:-}" ]] && { echo "together"; return; }
  [[ "$model" == *.gguf || "$model" == *Q4_K* || "$model" == *Q5_K* || "$model" == *Q8_0* ]] && { echo "gguf"; return; }
  [[ -f "$model" ]] && { echo "gguf"; return; }
  [[ -d "$model" && -f "$model/config.json" ]] && { echo "pytorch"; return; }
  [[ "$model" == */* && ! -d "$model" ]] && { echo "hf"; return; }
  [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "openai"; return; }
  echo "gguf"
}

# ── Session Management ────────────────────────────────────────────────────────
_save_session_turn() {
  local user_msg="$1" ai_msg="$2"
  local sess_file="$SESSIONS_DIR/${ACTIVE_SESSION:-default}.json"
  [[ ! -f "$sess_file" ]] && echo "[]" > "$sess_file"
  SESSION_FILE="$sess_file" USER_MSG="$user_msg" AI_MSG="$ai_msg" \
    "$PYTHON" -c '
import json,os
f=os.environ["SESSION_FILE"]
try: hist=json.load(open(f))
except: hist=[]
hist.append({"role":"user","content":os.environ["USER_MSG"]})
hist.append({"role":"assistant","content":os.environ["AI_MSG"]})
if len(hist)>40: hist=hist[-40:]
json.dump(hist,open(f,"w"),indent=2)
' 2>/dev/null || true
}

# ── Main Dispatch ─────────────────────────────────────────────────────────────
dispatch_ask() {
  local prompt="$1"
  local backend="${ACTIVE_BACKEND:-}"
  [[ -z "$backend" ]] && backend=$(_auto_detect_backend)

  if [[ -z "$backend" ]]; then
    err "No model or API key configured."
    echo "  ai keys set OPENAI_API_KEY sk-..."
    echo "  ai recommended download 1"
    return 1
  fi

  local response="" rc=0
  case "$backend" in
    gguf)     response=$(ask_gguf "$prompt");     rc=$? ;;
    openai)   response=$(ask_openai "$prompt");   rc=$? ;;
    claude)   response=$(ask_claude "$prompt");   rc=$? ;;
    gemini)   response=$(ask_gemini "$prompt");   rc=$? ;;
    groq)     response=$(ask_groq "$prompt");     rc=$? ;;
    mistral)  response=$(ask_mistral "$prompt");  rc=$? ;;
    together) response=$(ask_together "$prompt"); rc=$? ;;
    hf)       response=$(ask_hf "$prompt");       rc=$? ;;
    *) err "Unknown backend: $backend"; return 1 ;;
  esac

  if [[ $rc -ne 0 || -z "$response" ]]; then
    err "No response from $backend"
    return 1
  fi

  echo "$response"
  log_history "user" "$prompt"
  log_history "assistant" "$response"
  _save_session_turn "$prompt" "$response" 2>/dev/null || true
}

# Silent generation helper
_silent_generate() {
  local old_stream="$STREAM"; STREAM=0
  dispatch_ask "$1" 2>/dev/null
  STREAM="$old_stream"
}
