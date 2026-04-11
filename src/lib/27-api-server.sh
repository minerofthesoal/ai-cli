# ============================================================================
# MODULE: 27-api-server.sh
# Universal LLM API server (OpenAI-compatible v1/v2)
# Source lines 9358-10380 of main-v2.7.3
# ============================================================================

#  UNIVERSAL LLM API SERVER  (v2.4)
#  OpenAI-compatible REST API — works with any LLM client
#  Supports: GGUF, PyTorch, OpenAI, Claude, Gemini, HF backends
#
#  ai api start [--port 8080] [--host 0.0.0.0] [--key <token>]
#  ai api stop
#  ai api status
#  ai api test
#
#  Endpoints (OpenAI-compatible):
#    GET  /v1/models
#    POST /v1/chat/completions
#    POST /v1/completions
#    GET  /health
# ════════════════════════════════════════════════════════════════════════════════
cmd_api() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    start)
      local port="$API_PORT" host="$API_HOST" key="$API_KEY"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)  port="$2"; shift 2 ;;
          --host)  host="$2"; shift 2 ;;
          --key)   key="$2";  shift 2 ;;
          --public) host="0.0.0.0"; shift ;;
          *) shift ;;
        esac
      done
      if [[ -f "$API_PID_FILE" ]]; then
        local old_pid; old_pid=$(cat "$API_PID_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
          warn "API server already running (PID $old_pid) on $host:$port"
          warn "Stop it first: ai api stop"
          return 1
        fi
        rm -f "$API_PID_FILE"
      fi
      [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
      # v2.7.1: Pre-check if port is already in use (fixes OSError errno 98)
      if "$PYTHON" -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('$host', $port))
    s.close()
    sys.exit(0)
except OSError:
    s.close()
    sys.exit(1)
" 2>/dev/null; then
        : # port is free
      else
        err "Port $port is already in use on $host (OSError errno 98)"
        err "  Run: ai api stop   — to stop the existing server"
        err "  Or:  ai api start --port <other_port>   — to use a different port"
        # Try to find the PID using lsof/ss
        local busy_pid=""
        busy_pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || true)
        [[ -z "$busy_pid" ]] && busy_pid=$(lsof -ti :"$port" 2>/dev/null | head -1 || true)
        [[ -n "$busy_pid" ]] && err "  Process holding port $port: PID $busy_pid"
        return 1
      fi
      info "Starting AI CLI LLM API server on http://${host}:${port}"
      info "OpenAI-compatible: POST /v1/chat/completions"
      [[ -n "$key" ]] && info "Auth: Bearer token required"
      [[ -z "$key" ]] && warn "No API key set — open access (localhost only is safer)"
      # Export context for the Python server
      export API_SERVER_HOST="$host"
      export API_SERVER_PORT="$port"
      export API_SERVER_KEY="$key"
      export API_SERVER_BACKEND="${ACTIVE_BACKEND:-}"
      export API_SERVER_MODEL="${ACTIVE_MODEL:-}"
      export API_SERVER_CORS="${API_CORS:-1}"
      export AI_CLI_CONFIG="$CONFIG_DIR"
      export AI_CLI_MODELS="$MODELS_DIR"
      "$PYTHON" - <<'PYEOF' &
# ── AI CLI LLM API v2.0 ───────────────────────────────────────────────────────
# New in v2: ThreadedHTTPServer, real SSE streaming, rate limiting, per-IP auth
# reloading, JSON access log, /v2/ endpoints (stats, backends, config, models,
# tokenize, log), top_p/stop/n params, retry logic, token tracking.
# ─────────────────────────────────────────────────────────────────────────────
import os, sys, json, time, threading, subprocess, shutil, uuid
import socket as _sock
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from socketserver import ThreadingMixIn
from collections import defaultdict, deque
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────
HOST         = os.environ.get('API_SERVER_HOST', '127.0.0.1')
PORT         = int(os.environ.get('API_SERVER_PORT', '8080'))
API_KEY      = os.environ.get('API_SERVER_KEY', '')
BACKEND      = os.environ.get('API_SERVER_BACKEND', '')
MODEL        = os.environ.get('API_SERVER_MODEL', '')
CORS         = os.environ.get('API_SERVER_CORS', '1') == '1'
CORS_ORIGINS = os.environ.get('API_SERVER_CORS_ORIGINS', '*')
CONFIG       = os.environ.get('AI_CLI_CONFIG', os.path.expanduser('~/.config/ai-cli'))
MODELS_DIR   = os.environ.get('AI_CLI_MODELS', os.path.expanduser('~/.ai-cli/models'))
LOG_FILE     = os.environ.get('API_LOG_FILE', os.path.join(CONFIG, 'api_access.log'))
RATE_LIMIT   = int(os.environ.get('API_RATE_LIMIT', '120'))   # req/min per IP, 0=off
MAX_BODY     = int(os.environ.get('API_MAX_BODY', str(4 * 1024 * 1024)))

# ── Server statistics ─────────────────────────────────────────────────────────
_stats = {
    'total_requests':   0,
    'chat_completions': 0,
    'text_completions': 0,
    'streaming_reqs':   0,
    'errors':           0,
    'total_tokens':     0,
    'start_time':       time.time(),
    'backend_counts':   defaultdict(int),
}
_stats_lock = threading.Lock()

def _stat(key, n=1, sub=None):
    with _stats_lock:
        if sub is not None:
            _stats[key][sub] += n
        else:
            _stats[key] = _stats.get(key, 0) + n

# ── Rate limiter (sliding window per IP) ─────────────────────────────────────
_rate_windows = defaultdict(deque)
_rate_lock    = threading.Lock()

def _check_rate(ip):
    if RATE_LIMIT <= 0:
        return True
    now = time.time()
    with _rate_lock:
        dq = _rate_windows[ip]
        while dq and now - dq[0] > 60:
            dq.popleft()
        if len(dq) >= RATE_LIMIT:
            return False
        dq.append(now)
    return True

# ── Auth key store (multi-key, hot-reloadable) ────────────────────────────────
_auth_keys  = set()
_auth_lock  = threading.Lock()

def _reload_auth():
    keys = set()
    if API_KEY:
        keys.add(API_KEY)
    akf = os.path.join(CONFIG, 'api_keys.json')
    if os.path.exists(akf):
        try:
            for r in json.load(open(akf)):
                if r.get('active', True) and r.get('key'):
                    keys.add(r['key'])
        except Exception:
            pass
    with _auth_lock:
        _auth_keys.clear()
        _auth_keys.update(keys)

_reload_auth()

def _auth_ok(header):
    with _auth_lock:
        if not _auth_keys:
            return True
        tok = (header or '').replace('Bearer ', '').strip()
        return tok in _auth_keys

# ── JSON access logger ────────────────────────────────────────────────────────
try:
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    _log_fh = open(LOG_FILE, 'a', buffering=1)
except Exception:
    _log_fh = None

def _log(ip, method, path, status, elapsed_ms, tokens=0, note=''):
    if not _log_fh:
        return
    try:
        _log_fh.write(json.dumps({
            'ts': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            'ip': ip, 'method': method, 'path': path,
            'status': status, 'ms': round(elapsed_ms),
            'tokens': tokens, 'note': note,
        }) + '\n')
    except Exception:
        pass

# ── Load env keys ─────────────────────────────────────────────────────────────
def _load_keys():
    keys = {}
    kf = os.path.join(CONFIG, 'keys.env')
    if os.path.exists(kf):
        for line in open(kf):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                keys[k.strip()] = v.strip().strip('"\'')
    return keys

KEYS = _load_keys()

# ── Token estimator (~4 chars per token) ─────────────────────────────────────
def _tokens(text):
    return max(1, len(str(text)) // 4) if text else 0

def _msgs_tokens(msgs):
    return sum(_tokens(m.get('content', '')) + 4 for m in msgs)

# ── Retry helper ──────────────────────────────────────────────────────────────
def _retry(fn, tries=2):
    for i in range(tries + 1):
        try:
            return fn()
        except Exception as e:
            if i == tries:
                raise
            time.sleep(0.4 * (i + 1))

# ── Model scanner ─────────────────────────────────────────────────────────────
def _scan_models():
    results = []
    if os.path.isdir(MODELS_DIR):
        for root, _dirs, files in os.walk(MODELS_DIR):
            for fname in files:
                ext = os.path.splitext(fname)[1].lower()
                if ext not in ('.gguf', '.bin', '.pt', '.safetensors', '.pth'):
                    continue
                fpath = os.path.join(root, fname)
                try:
                    sz = os.path.getsize(fpath)
                    ctime = int(os.path.getmtime(fpath))
                except OSError:
                    sz = 0; ctime = 0
                mtype = 'gguf' if ext == '.gguf' else 'pytorch'
                results.append({
                    'id':         os.path.relpath(fpath, MODELS_DIR).replace(os.sep, '/'),
                    'object':     'model',
                    'owned_by':   'ai-cli',
                    'type':       mtype,
                    'path':       fpath,
                    'size_bytes': sz,
                    'created':    ctime,
                })
    for backend_id, key_name, dflt, owner in [
        ('openai',  'OPENAI_API_KEY',    'gpt-4o-mini',               'OpenAI'),
        ('claude',  'ANTHROPIC_API_KEY', 'claude-haiku-4-5-20251001', 'Anthropic'),
        ('gemini',  'GEMINI_API_KEY',    'gemini-2.0-flash',          'Google'),
    ]:
        if KEYS.get(key_name):
            mid = MODEL if (MODEL and backend_id in BACKEND.lower()) else dflt
            results.append({'id': str(mid), 'object': 'model', 'owned_by': owner,
                            'type': 'cloud', 'path': None, 'size_bytes': 0, 'created': 0})
    return results

# ── SSE helpers ───────────────────────────────────────────────────────────────
def _sse_chunk(model_id, delta, finish=False):
    return ('data: ' + json.dumps({
        'id': f"chatcmpl-{uuid.uuid4().hex[:10]}",
        'object': 'chat.completion.chunk',
        'created': int(time.time()),
        'model': model_id,
        'choices': [{'index': 0,
                     'delta': {'content': delta} if not finish else {},
                     'finish_reason': 'stop' if finish else None}],
    }) + '\n\n').encode()

def _sse_done():
    return b'data: [DONE]\n\n'

# ── Backend caller ────────────────────────────────────────────────────────────
def call_backend(messages, model_override=None, max_tokens=2048, temperature=0.7,
                 stream=False, top_p=1.0, stop=None, system_prompt=None, n=1):
    backend = BACKEND
    model   = model_override or MODEL

    if system_prompt and not any(m.get('role') == 'system' for m in messages):
        messages = [{'role': 'system', 'content': system_prompt}] + list(messages)

    # ── Auto-detect backend ────────────────────────────────────────────────────
    if not backend:
        if model and os.path.exists(model):
            backend = 'gguf' if model.endswith('.gguf') else 'pytorch'
        elif KEYS.get('OPENAI_API_KEY') and (not model or any(
                x in model.lower() for x in ('gpt', 'o1', 'o3', 'o4', 'text-', 'chatgpt'))):
            backend = 'openai'
        elif KEYS.get('ANTHROPIC_API_KEY') and (not model or 'claude' in model.lower()):
            backend = 'claude'
        elif KEYS.get('GEMINI_API_KEY') and (not model or 'gemini' in model.lower()):
            backend = 'gemini'
        elif KEYS.get('HF_TOKEN') and model and '/' in model:
            backend = 'hf'
        else:
            backend = 'openai'

    _stat('backend_counts', sub=backend)

    sys_msg = next((m['content'] for m in messages if m.get('role') == 'system'), '')
    prompt  = '\n'.join(
        f"{'User' if m['role']=='user' else 'Assistant'}: {m.get('content','')}"
        for m in messages if m.get('role') != 'system'
    ) + '\nAssistant:'

    # ── OpenAI ────────────────────────────────────────────────────────────────
    if backend == 'openai':
        import urllib.request
        key = KEYS.get('OPENAI_API_KEY', '')
        if not key:
            return None, 'OPENAI_API_KEY not set in keys.env'
        mdl  = model or 'gpt-4o-mini'
        body = {'model': mdl, 'messages': messages, 'max_tokens': max_tokens,
                'temperature': temperature, 'top_p': top_p, 'n': n, 'stream': stream}
        if stop:
            body['stop'] = stop
        req = urllib.request.Request(
            'https://api.openai.com/v1/chat/completions',
            data=json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
        if stream:
            def _gen():
                with urllib.request.urlopen(req, timeout=120) as r:
                    for raw in r:
                        line = raw.decode().strip()
                        if not line.startswith('data: '): continue
                        data = line[6:]
                        if data == '[DONE]': return
                        try:
                            delta = json.loads(data)['choices'][0].get('delta', {}).get('content', '')
                            if delta: yield delta
                        except Exception: pass
            return _gen(), None
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            texts = [c['message']['content'] for c in resp.get('choices', [])]
            return ('\n---\n'.join(texts) if len(texts) > 1 else texts[0]) if texts else '', None
        try:
            return _retry(_call)
        except Exception as e:
            return None, f'OpenAI: {e}'

    # ── Claude ────────────────────────────────────────────────────────────────
    elif backend == 'claude':
        import urllib.request
        key = KEYS.get('ANTHROPIC_API_KEY', '')
        if not key:
            return None, 'ANTHROPIC_API_KEY not set in keys.env'
        mdl  = model or 'claude-haiku-4-5-20251001'
        msgs = [m for m in messages if m.get('role') != 'system']
        body = {'model': mdl, 'max_tokens': max_tokens,
                'system': sys_msg or 'You are a helpful assistant.',
                'messages': msgs, 'temperature': temperature, 'top_p': top_p}
        if stop:
            body['stop_sequences'] = stop if isinstance(stop, list) else [stop]
        if stream:
            body['stream'] = True
        req = urllib.request.Request(
            'https://api.anthropic.com/v1/messages',
            data=json.dumps(body).encode(),
            headers={'x-api-key': key, 'anthropic-version': '2023-06-01',
                     'Content-Type': 'application/json'})
        if stream:
            def _gen():
                with urllib.request.urlopen(req, timeout=120) as r:
                    for raw in r:
                        line = raw.decode().strip()
                        if not line.startswith('data: '): continue
                        try:
                            ev = json.loads(line[6:])
                            if ev.get('type') == 'content_block_delta':
                                yield ev.get('delta', {}).get('text', '')
                        except Exception: pass
            return _gen(), None
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            return resp['content'][0]['text'], None
        try:
            return _retry(_call)
        except Exception as e:
            return None, f'Claude: {e}'

    # ── Gemini ────────────────────────────────────────────────────────────────
    elif backend == 'gemini':
        import urllib.request
        key = KEYS.get('GEMINI_API_KEY', '')
        if not key:
            return None, 'GEMINI_API_KEY not set in keys.env'
        mdl   = model or 'gemini-2.0-flash'
        parts = [{'text': f"{m.get('role','user')}: {m.get('content','')}"}
                 for m in messages]
        body  = {'contents': [{'parts': parts}],
                 'generationConfig': {'maxOutputTokens': max_tokens,
                                      'temperature': temperature, 'topP': top_p}}
        url = (f'https://generativelanguage.googleapis.com/v1beta/models/'
               f'{mdl}:generateContent?key={key}')
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json'})
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            return resp['candidates'][0]['content']['parts'][0]['text'], None
        try:
            text, err = _retry(_call)
            if stream and text:
                chunk = 24
                def _sim():
                    for i in range(0, len(text), chunk):
                        yield text[i:i+chunk]; time.sleep(0.008)
                return _sim(), None
            return text, err
        except Exception as e:
            return None, f'Gemini: {e}'

    # ── GGUF / llama.cpp ──────────────────────────────────────────────────────
    elif backend in ('gguf', 'local'):
        ctx     = int(os.environ.get('CONTEXT_SIZE', '4096'))
        n_thr   = int(os.environ.get('THREADS', str(os.cpu_count() or 4)))
        n_gpu   = int(os.environ.get('GPU_LAYERS', '0'))
        try:
            from llama_cpp import Llama
            llm = Llama(model_path=model, n_ctx=ctx, n_threads=n_thr,
                        n_gpu_layers=n_gpu, verbose=False)
            if stream:
                def _gen():
                    for ch in llm.create_chat_completion(
                            messages=messages, max_tokens=max_tokens,
                            temperature=temperature, top_p=top_p,
                            stop=stop or [], stream=True):
                        d = ch['choices'][0].get('delta', {}).get('content', '')
                        if d: yield d
                return _gen(), None
            out = llm.create_chat_completion(messages=messages, max_tokens=max_tokens,
                                             temperature=temperature, top_p=top_p,
                                             stop=stop or [])
            return out['choices'][0]['message']['content'], None
        except ImportError:
            pass
        llama_bin = next((b for b in ('llama-cli', 'llama', 'llama-run')
                          if shutil.which(b)), None)
        if llama_bin and model and os.path.exists(model):
            try:
                r = subprocess.run(
                    [llama_bin, '-m', model, '-p', prompt,
                     '--temp', str(temperature), '-n', str(max_tokens),
                     '--no-display-prompt', '-t', str(n_thr)],
                    capture_output=True, text=True, timeout=300)
                text = r.stdout.strip()
                if stream:
                    chunk = 16
                    def _sim():
                        for i in range(0, len(text), chunk):
                            yield text[i:i+chunk]
                    return _sim(), None
                return text, None
            except Exception as e:
                return None, f'llama.cpp: {e}'
        return None, 'GGUF backend: no model path or llama.cpp not installed (ai install-deps)'

    # ── PyTorch / Transformers ────────────────────────────────────────────────
    elif backend == 'pytorch':
        try:
            import torch
            from transformers import AutoTokenizer, AutoModelForCausalLM, TextIteratorStreamer
            tok   = AutoTokenizer.from_pretrained(model)
            mdl_o = AutoModelForCausalLM.from_pretrained(model, torch_dtype=torch.float32)
            mdl_o.eval()
            inputs = tok(prompt, return_tensors='pt')
            if stream:
                streamer = TextIteratorStreamer(tok, skip_prompt=True, skip_special_tokens=True)
                def _gen_thread():
                    with torch.no_grad():
                        mdl_o.generate(**inputs, max_new_tokens=max_tokens,
                                       temperature=temperature, do_sample=True,
                                       streamer=streamer)
                threading.Thread(target=_gen_thread, daemon=True).start()
                return iter(streamer), None
            with torch.no_grad():
                out = mdl_o.generate(**inputs, max_new_tokens=max_tokens,
                                     temperature=temperature, do_sample=True)
            text = tok.decode(out[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)
            return text.strip(), None
        except ImportError:
            return None, 'torch/transformers not installed — run: ai install-deps'
        except Exception as e:
            return None, f'PyTorch: {e}'

    # ── HuggingFace Inference API ─────────────────────────────────────────────
    elif backend == 'hf':
        import urllib.request
        key = KEYS.get('HF_TOKEN', '')
        if not model:
            return None, 'HF backend: set ACTIVE_MODEL to a HuggingFace model ID'
        hdrs = {'Content-Type': 'application/json'}
        if key: hdrs['Authorization'] = f'Bearer {key}'
        body = {'inputs': prompt,
                'parameters': {'max_new_tokens': max_tokens,
                                'temperature': temperature, 'top_p': top_p}}
        req  = urllib.request.Request(
            f'https://api-inference.huggingface.co/models/{model}',
            data=json.dumps(body).encode(), headers=hdrs)
        def _call():
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = json.load(r)
            if isinstance(resp, list):
                return resp[0].get('generated_text', ''), None
            return str(resp), None
        try:
            text, err = _retry(_call)
            if stream and text:
                chunk = 20
                def _sim():
                    for i in range(0, len(text), chunk):
                        yield text[i:i+chunk]
                return _sim(), None
            return text, err
        except Exception as e:
            return None, f'HuggingFace: {e}'

    return None, f"Unknown backend: {backend!r}  valid: openai|claude|gemini|gguf|pytorch|hf"

# ── HTTP handler ──────────────────────────────────────────────────────────────
class LLMHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _ip(self):
        xff = self.headers.get('X-Forwarded-For', '')
        return xff.split(',')[0].strip() if xff else self.client_address[0]

    def _cors(self):
        if not CORS: return
        orig = self.headers.get('Origin', CORS_ORIGINS)
        self.send_header('Access-Control-Allow-Origin',
                         CORS_ORIGINS if CORS_ORIGINS != '*' else orig or '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers',
                         'Content-Type, Authorization, X-Requested-With')
        self.send_header('Access-Control-Max-Age', '86400')

    def _json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg, etype='api_error'):
        self._json(code, {'error': {'message': msg, 'type': etype, 'code': code}})

    def _body(self):
        try:
            n = int(self.headers.get('Content-Length', 0))
            if n > MAX_BODY:
                return None, f'Body too large ({n} > {MAX_BODY})'
            return json.loads(self.rfile.read(n) if n else b'{}'), None
        except Exception as e:
            return None, f'Bad JSON: {e}'

    # ── OPTIONS ───────────────────────────────────────────────────────────────
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    # ── GET endpoints ─────────────────────────────────────────────────────────
    def do_GET(self):
        t0   = time.time()
        path = urlparse(self.path).path.rstrip('/')
        ip   = self._ip()
        auth = _auth_ok(self.headers.get('Authorization', ''))

        # /health
        if path == '/health':
            with _stats_lock:
                up = round(time.time() - _stats['start_time'])
            self._json(200, {'status': 'ok', 'version': '2.0', 'uptime_s': up,
                             'backend': BACKEND or 'auto', 'model': MODEL or 'auto',
                             'threaded': True, 'rate_limit': RATE_LIMIT})

        # /v1/models — OpenAI-compat list
        elif path == '/v1/models':
            base = [{'id': MODEL or 'ai-cli-default', 'object': 'model',
                     'created': int(time.time()), 'owned_by': 'ai-cli'}]
            for m in _scan_models():
                if not any(x['id'] == m['id'] for x in base):
                    base.append({'id': m['id'], 'object': 'model',
                                 'created': m['created'], 'owned_by': m['owned_by']})
            self._json(200, {'object': 'list', 'data': base})

        # /v2/models — extended with size, path, type
        elif path == '/v2/models':
            if not auth: self._err(401, 'Auth required'); return
            self._json(200, {'object': 'list', 'data': _scan_models()})

        # /v2/backends — backend availability
        elif path == '/v2/backends':
            if not auth: self._err(401, 'Auth required'); return
            have_torch = False
            try: import torch; have_torch = True
            except ImportError: pass
            have_llama = bool(next((b for b in ('llama-cli','llama','llama-run')
                                    if shutil.which(b)), None))
            self._json(200, {'backends': [
                {'id': 'openai',   'type': 'cloud', 'available': bool(KEYS.get('OPENAI_API_KEY')),
                 'default_model': 'gpt-4o-mini'},
                {'id': 'claude',   'type': 'cloud', 'available': bool(KEYS.get('ANTHROPIC_API_KEY')),
                 'default_model': 'claude-haiku-4-5-20251001'},
                {'id': 'gemini',   'type': 'cloud', 'available': bool(KEYS.get('GEMINI_API_KEY')),
                 'default_model': 'gemini-2.0-flash'},
                {'id': 'hf',       'type': 'cloud', 'available': bool(KEYS.get('HF_TOKEN')),
                 'default_model': None},
                {'id': 'gguf',     'type': 'local', 'available': have_llama,
                 'default_model': MODEL if MODEL and MODEL.endswith('.gguf') else None},
                {'id': 'pytorch',  'type': 'local', 'available': have_torch,
                 'default_model': MODEL if MODEL and not MODEL.endswith('.gguf') else None},
            ], 'active': BACKEND or 'auto'})

        # /v2/stats — request statistics
        elif path == '/v2/stats':
            if not auth: self._err(401, 'Auth required'); return
            with _stats_lock:
                s = {k: (dict(v) if isinstance(v, defaultdict) else v)
                     for k, v in _stats.items()}
                s['uptime_s'] = round(time.time() - s.pop('start_time'))
            self._json(200, s)

        # /v2/config — read current server config
        elif path == '/v2/config':
            if not auth: self._err(401, 'Auth required'); return
            cfg_file = os.path.join(CONFIG, 'config.env')
            vals = {}
            if os.path.exists(cfg_file):
                for line in open(cfg_file):
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        k, _, v = line.partition('=')
                        vals[k.strip()] = v.strip().strip('"\'')
            self._json(200, {'host': HOST, 'port': PORT, 'backend': BACKEND or 'auto',
                             'model': MODEL or 'auto', 'cors': CORS,
                             'rate_limit': RATE_LIMIT, 'settings': vals})

        # /v2/log — last 100 access log entries
        elif path == '/v2/log':
            if not auth: self._err(401, 'Auth required'); return
            entries = []
            if os.path.exists(LOG_FILE):
                try:
                    with open(LOG_FILE) as f: lines = f.readlines()
                    for ln in lines[-100:]:
                        try: entries.append(json.loads(ln.strip()))
                        except Exception: pass
                except Exception: pass
            self._json(200, {'entries': entries, 'count': len(entries),
                             'log_file': LOG_FILE})

        # /v2/tokenize?text=...
        elif path == '/v2/tokenize':
            qs   = parse_qs(urlparse(self.path).query)
            text = qs.get('text', [''])[0]
            self._json(200, {'estimated_tokens': _tokens(text),
                             'char_count': len(text),
                             'preview': text[:80] + ('…' if len(text) > 80 else '')})

        else:
            self._err(404, f'Unknown endpoint: {path}')

        _log(ip, 'GET', path, 200, (time.time()-t0)*1000)

    # ── POST endpoints ────────────────────────────────────────────────────────
    def do_POST(self):
        t0   = time.time()
        path = urlparse(self.path).path.rstrip('/')
        ip   = self._ip()
        _stat('total_requests')

        if not _auth_ok(self.headers.get('Authorization', '')):
            self._err(401, 'Invalid or missing API key')
            _log(ip, 'POST', path, 401, (time.time()-t0)*1000, note='auth_fail')
            return
        if not _check_rate(ip):
            self._err(429, f'Rate limit exceeded ({RATE_LIMIT} req/min)')
            _log(ip, 'POST', path, 429, (time.time()-t0)*1000, note='rate_limit')
            return

        body, err = self._body()
        if err:
            self._err(400, err, 'invalid_request_error'); return

        # ── /v1/chat/completions  /v2/chat/completions ────────────────────────
        if path in ('/v1/chat/completions', '/v2/chat/completions'):
            msgs      = body.get('messages', [])
            model_req = body.get('model') or MODEL or 'ai-cli-default'
            max_tok   = min(int(body.get('max_tokens', 2048)), 32768)
            temp      = max(0.0, min(float(body.get('temperature', 0.7)), 2.0))
            top_p_v   = max(0.0, min(float(body.get('top_p', 1.0)), 1.0))
            stop_v    = body.get('stop')
            do_stream = bool(body.get('stream', False))
            sys_p     = body.get('system_prompt')
            n_v       = min(int(body.get('n', 1)), 4)

            if not msgs:
                self._err(400, '"messages" is required', 'invalid_request_error')
                return
            for i, m in enumerate(msgs):
                if 'role' not in m or 'content' not in m:
                    self._err(400, f'messages[{i}] missing role or content'); return
                if m['role'] not in ('system','user','assistant','function','tool'):
                    self._err(400, f'Unknown role: {m["role"]!r}'); return

            ptoks = _msgs_tokens(msgs)
            result, err = call_backend(msgs, model_req, max_tok, temp,
                                       stream=do_stream, top_p=top_p_v, stop=stop_v,
                                       system_prompt=sys_p, n=n_v)
            if err:
                _stat('errors')
                self._err(500, err, 'backend_error')
                _log(ip, 'POST', path, 500, (time.time()-t0)*1000, note=err[:80])
                return

            _stat('chat_completions')
            if do_stream:
                _stat('streaming_reqs')
                rid = f"chatcmpl-{uuid.uuid4().hex[:12]}"
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('X-Accel-Buffering', 'no')
                self._cors()
                self.end_headers()
                acc = []
                try:
                    for chunk in result:
                        if chunk:
                            acc.append(chunk)
                            self.wfile.write(_sse_chunk(model_req, chunk))
                            self.wfile.flush()
                    self.wfile.write(_sse_chunk(model_req, '', finish=True))
                    self.wfile.write(_sse_done())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                ctoks = _tokens(''.join(acc))
                _stat('total_tokens', ptoks + ctoks)
                _log(ip, 'POST', path, 200, (time.time()-t0)*1000,
                     tokens=ptoks+ctoks, note='stream')
            else:
                text    = result or ''
                elapsed = time.time() - t0
                ctoks   = _tokens(text)
                _stat('total_tokens', ptoks + ctoks)
                self._json(200, {
                    'id': f"chatcmpl-{uuid.uuid4().hex[:12]}",
                    'object': 'chat.completion',
                    'created': int(time.time()),
                    'model': model_req,
                    'choices': [{'index': 0,
                                 'message': {'role': 'assistant', 'content': text},
                                 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': ptoks, 'completion_tokens': ctoks,
                              'total_tokens': ptoks + ctoks},
                    '_meta': {'backend': BACKEND or 'auto',
                              'elapsed_s': round(elapsed, 3), 'api_version': 2},
                })
                _log(ip, 'POST', path, 200, (time.time()-t0)*1000,
                     tokens=ptoks+ctoks)

        # ── /v1/completions ───────────────────────────────────────────────────
        elif path == '/v1/completions':
            prompt_text = body.get('prompt', '')
            model_req   = body.get('model') or MODEL or 'ai-cli-default'
            max_tok     = min(int(body.get('max_tokens', 256)), 32768)
            temp        = max(0.0, min(float(body.get('temperature', 0.7)), 2.0))
            msgs        = [{'role': 'user', 'content': prompt_text}]
            text, err   = call_backend(msgs, model_req, max_tok, temp)
            if err:
                _stat('errors'); self._err(500, err, 'backend_error'); return
            _stat('text_completions')
            pt = _tokens(prompt_text); ct = _tokens(text or '')
            _stat('total_tokens', pt + ct)
            self._json(200, {
                'id': f"cmpl-{uuid.uuid4().hex[:12]}", 'object': 'text_completion',
                'created': int(time.time()), 'model': model_req,
                'choices': [{'text': text or '', 'index': 0,
                             'finish_reason': 'stop', 'logprobs': None}],
                'usage': {'prompt_tokens': pt, 'completion_tokens': ct,
                          'total_tokens': pt + ct},
            })
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000, tokens=pt+ct)

        # ── /v1/embeddings ────────────────────────────────────────────────────
        elif path == '/v1/embeddings':
            inp = body.get('input', '')
            if isinstance(inp, list): inp = inp[0] if inp else ''
            try:
                from sentence_transformers import SentenceTransformer as _ST
                emb_mdl = body.get('model', 'all-MiniLM-L6-v2')
                vec = _ST(emb_mdl).encode(inp).tolist()
                t_count = _tokens(inp)
                self._json(200, {
                    'object': 'list', 'model': emb_mdl,
                    'data': [{'object': 'embedding', 'index': 0, 'embedding': vec}],
                    'usage': {'prompt_tokens': t_count, 'total_tokens': t_count},
                })
            except ImportError:
                self._err(501, 'pip install sentence-transformers to enable embeddings')
            except Exception as e:
                self._err(500, str(e))
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        # ── /v2/config — update config file ───────────────────────────────────
        elif path == '/v2/config':
            if not _auth_ok(self.headers.get('Authorization', '')):
                self._err(401, 'Auth required'); return
            cfg_file = os.path.join(CONFIG, 'config.env')
            updates  = {k: v for k, v in body.items()
                        if isinstance(k, str) and isinstance(v, str)}
            if not updates:
                self._err(400, 'No string key-value pairs in body'); return
            try:
                lines = open(cfg_file).readlines() if os.path.exists(cfg_file) else []
                done  = set()
                new_lines = []
                for line in lines:
                    s = line.strip()
                    if '=' in s and not s.startswith('#'):
                        k = s.partition('=')[0].strip().upper()
                        match = next((u for u in updates if u.upper() == k), None)
                        if match:
                            new_lines.append(f'{k}="{updates[match]}"\n')
                            done.add(match); continue
                    new_lines.append(line)
                for k, v in updates.items():
                    if k not in done:
                        new_lines.append(f'{k.upper()}="{v}"\n')
                os.makedirs(os.path.dirname(cfg_file), exist_ok=True)
                open(cfg_file, 'w').writelines(new_lines)
                self._json(200, {'updated': list(updates.keys()), 'file': cfg_file})
            except Exception as e:
                self._err(500, f'Config write error: {e}')
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        # ── /v2/auth/reload — hot-reload API keys ─────────────────────────────
        elif path == '/v2/auth/reload':
            if not _auth_ok(self.headers.get('Authorization', '')):
                self._err(401, 'Auth required'); return
            _reload_auth()
            with _auth_lock:
                n = len(_auth_keys)
            self._json(200, {'reloaded': True, 'keys_count': n})
            _log(ip, 'POST', path, 200, (time.time()-t0)*1000)

        else:
            self._err(404, f'Unknown endpoint: {path}')
            _log(ip, 'POST', path, 404, (time.time()-t0)*1000)

# ── Threaded server ───────────────────────────────────────────────────────────
class _THTTP(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads      = True
    request_queue_size  = 64

# ── Startup ───────────────────────────────────────────────────────────────────
import errno as _errno
print(f"AI CLI LLM API v2.0 on http://{HOST}:{PORT}  [threaded | rate:{RATE_LIMIT}/min | cors:{CORS}]", flush=True)
print(f"  /health  /v1/models  /v1/chat/completions (stream ok)  /v1/completions", flush=True)
print(f"  /v2/chat/completions  /v2/stats  /v2/backends  /v2/config  /v2/log  /v2/tokenize", flush=True)
try:
    server = _THTTP((HOST, PORT), LLMHandler)
except OSError as _e:
    if _e.errno in (98, 48):
        print(f"ERROR: Port {PORT} already in use. Run: ai api stop", flush=True)
        sys.exit(98)
    raise
server.serve_forever()
PYEOF
      local api_pid=$!
      sleep 0.8
      if kill -0 "$api_pid" 2>/dev/null; then
        echo "$api_pid" > "$API_PID_FILE"
        ok "API server running (PID $api_pid)"
        echo "  Endpoint:  http://${host}:${port}/v1/chat/completions"
        echo "  Models:    http://${host}:${port}/v1/models"
        echo "  Health:    http://${host}:${port}/health"
        echo "  Stop with: ai api stop"
      else
        err "API server failed to start. Check Python dependencies: ai install-deps"
      fi
      ;;
    stop)
      if [[ ! -f "$API_PID_FILE" ]]; then
        warn "No API server PID file found"
        return
      fi
      local pid; pid=$(cat "$API_PID_FILE" 2>/dev/null)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && rm -f "$API_PID_FILE"
        ok "API server stopped (PID $pid)"
      else
        warn "API server not running (stale PID $pid)"
        rm -f "$API_PID_FILE"
      fi
      ;;
    status)
      if [[ -f "$API_PID_FILE" ]]; then
        local pid; pid=$(cat "$API_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
          ok "API server running (PID $pid) on $API_HOST:$API_PORT"
          echo "  Endpoint: http://${API_HOST}:${API_PORT}/v1/chat/completions"
        else
          warn "API server not running (stale PID file)"
          rm -f "$API_PID_FILE"
        fi
      else
        info "API server not running"
        echo "  Start with: ai api start [--port 8080] [--public]"
      fi
      ;;
    test)
      local port="${1:-$API_PORT}"; local host="${2:-$API_HOST}"
      info "Testing LLM API at http://${host}:${port}"
      if ! command -v curl &>/dev/null; then err "curl required for test"; return 1; fi
      local health
      health=$(curl -sf "http://${host}:${port}/health" 2>/dev/null)
      if [[ $? -eq 0 ]]; then
        ok "Health check passed: $health"
      else
        err "Server not responding. Start it: ai api start"
        return 1
      fi
      info "Testing /v1/chat/completions..."
      local key_header=""
      [[ -n "$API_KEY" ]] && key_header="-H \"Authorization: Bearer $API_KEY\""
      local result
      result=$(curl -sf -X POST "http://${host}:${port}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
        -d '{"model":"auto","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":20}' 2>/dev/null)
      if [[ $? -eq 0 ]]; then
        local text; text=$(echo "$result" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['choices'][0]['message']['content'])" 2>/dev/null)
        ok "Chat completion: $text"
      else
        err "Chat completion failed"
      fi
      ;;
    config)
      hdr "LLM API Configuration"
      printf "  %-22s %s\n" "Host:" "$API_HOST"
      printf "  %-22s %s\n" "Port:" "$API_PORT"
      printf "  %-22s %s\n" "Key:" "${API_KEY:+(set)}"
      printf "  %-22s %s\n" "CORS:" "$API_CORS"
      printf "  %-22s %s\n" "Share enabled:" "$API_SHARE_ENABLED"
      printf "  %-22s %s\n" "Share host:port:" "${API_SHARE_HOST}:${API_SHARE_PORT}"
      printf "  %-22s %s req/min\n" "Rate limit:" "$API_SHARE_RATE_LIMIT"
      printf "  %-22s %s\n" "Backend:" "${ACTIVE_BACKEND:-auto}"
      printf "  %-22s %s\n" "Model:" "${ACTIVE_MODEL:-auto}"
      echo ""
      echo "  Change: ai config api_host / api_port / api_key"
      echo "          ai config api_share_host / api_share_port / api_share_rate_limit"
      ;;

    # ── v2.4.5: Key management ────────────────────────────────────────────────
    key-gen)
      _api_key_gen "$@"
      ;;
    keys)
      local ksub="${1:-list}"; shift || true
      case "$ksub" in
        list) _api_keys_list ;;
        revoke) _api_keys_revoke "$@" ;;
        show)   _api_keys_show  "$@" ;;
        reset-count) _api_keys_reset_count "$@" ;;
        *) echo "Usage: ai api keys list|revoke <id>|show <id>|reset-count <id>" ;;
      esac
      ;;
    share)
      # Start public-facing API server accepting any valid key from the key store
      local port="${API_SHARE_PORT}" host="${API_SHARE_HOST}"
      while [[ $# -gt 0 ]]; do
        case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; *) shift ;; esac
      done
      _api_share_start "$host" "$port"
      ;;
    unshare) _api_share_stop ;;

    *)
      hdr "LLM API Server (v2.4.5) — OpenAI-compatible"
      echo ""
      echo "  ${B}Server${R}"
      echo "  ai api start [--port 8080] [--host 0.0.0.0] [--key <token>]"
      echo "  ai api stop / status / test / config"
      echo ""
      echo "  ${B}Key Hosting (v2.4.5) — share your model with others${R}"
      echo "  ai api key-gen [--label name] [--rate N/min]"
      echo "    Creates a unique key others can use to call YOUR running model"
      echo "  ai api keys list            — Show all generated keys + usage"
      echo "  ai api keys revoke <id>     — Disable a key"
      echo "  ai api keys show <id>       — Show full key value"
      echo "  ai api share [--port 8080]  — Start public multi-key server"
      echo "  ai api unshare              — Stop shared server"
      echo ""
      echo "  ${B}Endpoints (OpenAI-compatible)${R}"
      echo "    GET  /v1/models"
      echo "    POST /v1/chat/completions"
      echo "    POST /v1/completions"
      echo "    GET  /health"
      echo ""
      echo "  Works with: Open WebUI, LM Studio, SillyTavern, Chatbot UI, curl"
      echo "  Backends:   openai, claude, gemini, gguf, pytorch, hf (auto-detected)"
      echo ""
      echo "  ${B}Example workflow${R}"
      echo "    ai api key-gen --label friend1   # create key"
      echo "    ai api share --port 8080         # share your model"
      echo "    # Give friend1 the key + your IP:port"
      echo "    # They use it like any OpenAI endpoint"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  API KEY MANAGEMENT  (v2.4.5)
