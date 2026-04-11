# ============================================================================
# MODULE: 28-api-keys.sh
# Shareable API key store (v2.4.5)
# Source lines 10380-10753 of main-v2.7.3
# ============================================================================

#  API KEY MANAGEMENT  (v2.4.5)
#  Create unique shareable keys so others can access your running model
#  Keys stored in ~/.config/ai-cli/api_keys.json
#  Each key has: id, key (secret), label, created, active, rate_limit,
#                requests_today, requests_total, last_used
# ════════════════════════════════════════════════════════════════════════════════
_api_key_gen() {
  local label="key_$(date +%Y%m%d_%H%M%S)" rate="${API_SHARE_RATE_LIMIT:-60}"
  while [[ $# -gt 0 ]]; do
    case "$1" in --label) label="$2"; shift 2 ;; --rate) rate="$2"; shift 2 ;; *) shift ;; esac
  done
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local key_id; key_id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
  local secret; secret=$(python3 -c "import secrets; print('ak-' + secrets.token_hex(24))")
  local now; now=$(date -Iseconds 2>/dev/null || python3 -c "from datetime import datetime; print(datetime.utcnow().isoformat())")

  # Load or create key store
  local ks="$API_KEYS_FILE"
  if [[ ! -f "$ks" ]]; then echo "[]" > "$ks"; chmod 600 "$ks"; fi

  python3 - <<PYEOF
import json, sys
ks = '$ks'
try:
    keys = json.load(open(ks))
except: keys = []
keys.append({
    "id": "$key_id", "key": "$secret", "label": "$label",
    "created": "$now", "active": True,
    "rate_limit": $rate,
    "requests_today": 0, "requests_total": 0, "last_used": None
})
json.dump(keys, open(ks,'w'), indent=2)
PYEOF

  ok "API key created"
  printf "  %-14s %s\n" "ID:"     "$key_id"
  printf "  %-14s %s\n" "Label:"  "$label"
  printf "  %-14s %s\n" "Key:"    "$secret"
  printf "  %-14s %s req/min\n" "Rate limit:" "$rate"
  echo ""
  warn "Copy the key now — it cannot be recovered later"
  echo "  Share: ai api share --port ${API_SHARE_PORT}"
  echo "  Usage: curl http://<your-ip>:${API_SHARE_PORT}/v1/chat/completions \\"
  echo "           -H 'Authorization: Bearer $secret' \\"
  echo "           -H 'Content-Type: application/json' \\"
  echo "           -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
}

_api_keys_list() {
  [[ ! -f "$API_KEYS_FILE" ]] && { info "No keys yet. Create one: ai api key-gen"; return; }
  hdr "API Keys (v2.4.5)"
  python3 - <<'PYEOF'
import json, sys
try:
    keys = json.load(open(sys.argv[1]))
except: keys = []
if not keys:
    print("  No keys.")
    sys.exit()
print(f"  {'ID':8}  {'Label':20}  {'Active':6}  {'Rate':8}  {'Total':7}  {'Last used':19}")
print("  " + "-"*80)
for k in keys:
    key_preview = k['key'][:10] + "..."
    active = "yes" if k.get('active', True) else "NO"
    rate = f"{k.get('rate_limit',60)}/min"
    total = str(k.get('requests_total', 0))
    last = (k.get('last_used') or 'never')[:19]
    print(f"  {k['id']:8}  {k['label']:20}  {active:6}  {rate:8}  {total:7}  {last}")
PYEOF
  "$API_KEYS_FILE"
}

_api_keys_revoke() {
  local id="${1:?Usage: ai api keys revoke <id>}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
ks = '$API_KEYS_FILE'
keys = json.load(open(ks))
found = False
for k in keys:
    if k['id'] == '$id':
        k['active'] = False; found = True
json.dump(keys, open(ks,'w'), indent=2)
print('Revoked' if found else 'Key not found: $id')
"
}

_api_keys_show() {
  local id="${1:?Usage: ai api keys show <id>}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
keys = json.load(open('$API_KEYS_FILE'))
for k in keys:
    if k['id'] == '$id':
        print(k['key']); exit()
print('Key not found: $id')
"
}

_api_keys_reset_count() {
  local id="${1:?Usage: ai api keys reset-count <id>}"
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No key store found"; return 1; }
  python3 -c "
import json
ks = '$API_KEYS_FILE'; keys = json.load(open(ks))
for k in keys:
    if k['id'] == '$id':
        k['requests_today'] = 0; k['requests_total'] = 0
json.dump(keys, open(ks,'w'), indent=2)
print('Reset counters for $id')
"
}

_api_share_start() {
  local host="${1:-${API_SHARE_HOST:-0.0.0.0}}"
  local port="${2:-${API_SHARE_PORT:-8080}}"
  local share_pid_file="$CONFIG_DIR/api_share.pid"

  if [[ -f "$share_pid_file" ]]; then
    local p; p=$(cat "$share_pid_file" 2>/dev/null)
    kill -0 "$p" 2>/dev/null && { warn "Share server already running (PID $p)"; return 1; }
    rm -f "$share_pid_file"
  fi
  [[ ! -f "$API_KEYS_FILE" ]] && { err "No API keys. Create one first: ai api key-gen --label <name>"; return 1; }
  # v2.7.1: Pre-check port availability (prevents errno 98)
  if [[ -n "$PYTHON" ]]; then
    if ! "$PYTHON" -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('$host', $port))
    s.close(); sys.exit(0)
except OSError:
    s.close(); sys.exit(1)
" 2>/dev/null; then
      err "Port $port is already in use (OSError errno 98). Free it first or use a different port."
      return 1
    fi
  fi
  info "Starting public AI CLI share server on ${host}:${port}"
  info "Auth: multi-key from $API_KEYS_FILE"
  warn "This exposes your model to key holders — revoke keys with: ai api keys revoke <id>"

  export _SHARE_HOST="$host" _SHARE_PORT="$port" _SHARE_KEYS_FILE="$API_KEYS_FILE"
  export _SHARE_BACKEND="${ACTIVE_BACKEND:-}" _SHARE_MODEL="${ACTIVE_MODEL:-}"
  export _SHARE_CONFIG="$CONFIG_DIR" _SHARE_CORS="${API_CORS:-1}"

  "$PYTHON" - <<'PYEOF' &
import os, sys, json, time, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from collections import defaultdict

HOST       = os.environ.get('_SHARE_HOST', '0.0.0.0')
PORT       = int(os.environ.get('_SHARE_PORT', '8080'))
KEYS_FILE  = os.environ['_SHARE_KEYS_FILE']
BACKEND    = os.environ.get('_SHARE_BACKEND', '')
MODEL      = os.environ.get('_SHARE_MODEL', '')
CONFIG     = os.environ.get('_SHARE_CONFIG', '')
CORS       = os.environ.get('_SHARE_CORS', '1') == '1'

_request_times = defaultdict(list)  # key_id -> [timestamps]
_lock = threading.Lock()

def load_keys():
    try:
        return {k['key']: k for k in json.load(open(KEYS_FILE)) if k.get('active', True)}
    except:
        return {}

def load_config_keys():
    keys = {}
    cf = os.path.join(CONFIG, 'keys.env')
    if os.path.exists(cf):
        for line in open(cf):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                keys[k.strip()] = v.strip().strip('"\'')
    return keys

def check_rate(key_id, rate_limit):
    now = time.time()
    with _lock:
        times = [t for t in _request_times[key_id] if now - t < 60]
        _request_times[key_id] = times
        if len(times) >= rate_limit:
            return False
        _request_times[key_id].append(now)
    return True

def update_key_stats(key_secret):
    try:
        keys = json.load(open(KEYS_FILE))
        for k in keys:
            if k['key'] == key_secret:
                k['requests_total'] = k.get('requests_total', 0) + 1
                k['requests_today'] = k.get('requests_today', 0) + 1
                k['last_used'] = time.strftime('%Y-%m-%dT%H:%M:%S')
        json.dump(keys, open(KEYS_FILE, 'w'), indent=2)
    except:
        pass

def call_llm(messages, max_tokens=2048, temperature=0.7):
    """Minimal inline LLM caller."""
    import urllib.request
    cfg_keys = load_config_keys()
    backend = BACKEND or ('openai' if cfg_keys.get('OPENAI_API_KEY') else
                          'claude' if cfg_keys.get('ANTHROPIC_API_KEY') else
                          'gemini' if cfg_keys.get('GEMINI_API_KEY') else None)
    if backend == 'openai':
        key = cfg_keys.get('OPENAI_API_KEY', '')
        if not key: return None, "OPENAI_API_KEY not set"
        payload = json.dumps({"model": MODEL or "gpt-4o-mini", "messages": messages,
                              "max_tokens": max_tokens, "temperature": temperature}).encode()
        req = urllib.request.Request("https://api.openai.com/v1/chat/completions", data=payload,
                                     headers={"Authorization": f"Bearer {key}",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['choices'][0]['message']['content'], None
    elif backend == 'claude':
        key = cfg_keys.get('ANTHROPIC_API_KEY', '')
        if not key: return None, "ANTHROPIC_API_KEY not set"
        payload = json.dumps({"model": MODEL or "claude-haiku-4-5-20251001",
                              "max_tokens": max_tokens,
                              "messages": [m for m in messages if m.get('role') != 'system']}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=payload,
                                     headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['content'][0]['text'], None
    elif backend == 'gemini':
        key = cfg_keys.get('GEMINI_API_KEY', '')
        if not key: return None, "GEMINI_API_KEY not set"
        mdl = MODEL or 'gemini-2.0-flash'
        parts = [{"text": f"{m['role']}: {m['content']}"} for m in messages]
        payload = json.dumps({"contents": [{"parts": parts}],
                              "generationConfig": {"maxOutputTokens": max_tokens,
                                                   "temperature": temperature}}).encode()
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{mdl}:generateContent?key={key}"
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)['candidates'][0]['content']['parts'][0]['text'], None
    return None, f"No backend available (set OPENAI/ANTHROPIC/GEMINI API key)"

class ShareHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _cors(self):
        if CORS:
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        """Returns (key_record, error_msg). key_record is None on failure."""
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return None, "Missing Authorization: Bearer <key>"
        secret = auth[7:].strip()
        api_keys = load_keys()
        rec = api_keys.get(secret)
        if not rec:
            return None, "Invalid API key"
        if not check_rate(rec['id'], rec.get('rate_limit', 60)):
            return None, f"Rate limit exceeded ({rec.get('rate_limit',60)} req/min)"
        threading.Thread(target=update_key_stats, args=(secret,), daemon=True).start()
        return rec, None

    def do_OPTIONS(self):
        self.send_response(200); self._cors(); self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/health':
            self._json(200, {"status": "ok", "version": "2.4.5", "mode": "share",
                             "backend": BACKEND or "auto", "model": MODEL or "auto"})
        elif path == '/v1/models':
            rec, err = self._auth()
            if not rec: self._json(401, {"error": err}); return
            self._json(200, {"object": "list", "data": [
                {"id": MODEL or "auto", "object": "model", "owned_by": "ai-cli-share"}
            ]})
        else:
            self._json(404, {"error": "Not found"})

    def do_POST(self):
        rec, err = self._auth()
        if not rec: self._json(401, {"error": {"message": err, "type": "auth_error"}}); return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            self._json(400, {"error": str(e)}); return
        path = urlparse(self.path).path
        if path in ('/v1/chat/completions', '/v1/completions'):
            messages = body.get('messages', [{"role":"user","content": body.get('prompt','')}])
            max_tok = int(body.get('max_tokens', 2048))
            temp = float(body.get('temperature', 0.7))
            t0 = time.time()
            try:
                text, err2 = call_llm(messages, max_tok, temp)
            except Exception as ex:
                self._json(500, {"error": str(ex)}); return
            if err2:
                self._json(500, {"error": {"message": err2, "type": "backend_error"}}); return
            elapsed = time.time() - t0
            self._json(200, {
                "id": f"chatcmpl-{int(time.time()*1000)}", "object": "chat.completion",
                "created": int(time.time()), "model": MODEL or "ai-cli",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": sum(len(m.get('content','').split()) for m in messages),
                          "completion_tokens": len((text or '').split()),
                          "total_tokens": 0},
                "_meta": {"key_id": rec['id'], "key_label": rec['label'],
                          "elapsed_s": round(elapsed, 3)}
            })
        else:
            self._json(404, {"error": "Unknown endpoint"})

keys_count = len(load_keys())
print(f"AI CLI Share Server v2.7.1 — {keys_count} active key(s) — http://{HOST}:{PORT}", flush=True)
print(f"  POST http://{HOST}:{PORT}/v1/chat/completions  (OpenAI-compatible)", flush=True)
# v2.7.1: SO_REUSEADDR to prevent errno 98
class _ReuseAddrHTTPServer(HTTPServer):
    allow_reuse_address = True
import errno as _errno
try:
    _srv = _ReuseAddrHTTPServer((HOST, PORT), ShareHandler)
except OSError as _e:
    if _e.errno in (98, 48):
        print(f"ERROR: Port {PORT} is already in use. Run: ai api unshare  or choose a different port.", flush=True)
        sys.exit(98)
    raise
_srv.serve_forever()
PYEOF

  local share_pid=$!
  sleep 0.8
  if kill -0 "$share_pid" 2>/dev/null; then
    echo "$share_pid" > "$CONFIG_DIR/api_share.pid"
    ok "Share server running (PID $share_pid)"
    echo "  Endpoint: http://${host}:${port}/v1/chat/completions"
    echo "  Keys:     $(python3 -c "import json; k=json.load(open('$API_KEYS_FILE')); print(len([x for x in k if x.get('active',True)]), 'active')" 2>/dev/null || echo "?")"
    echo "  Stop:     ai api unshare"
  else
    err "Share server failed to start"
  fi
}

_api_share_stop() {
  local pf="$CONFIG_DIR/api_share.pid"
  [[ ! -f "$pf" ]] && { warn "Share server not running"; return; }
  local pid; pid=$(cat "$pf")
  kill -0 "$pid" 2>/dev/null && kill "$pid" && rm -f "$pf" && ok "Share server stopped" || \
    { warn "Share server not running (stale PID)"; rm -f "$pf"; }
}

# ════════════════════════════════════════════════════════════════════════════════
#  MULTI-AI CHAT ARENA  (v2.4.5)
