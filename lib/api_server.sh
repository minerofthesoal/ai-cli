#!/usr/bin/env bash
# AI CLI v3.1.0 — API Server v3
# OpenAI-compatible REST API server with key management

API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8080}"
API_PID_FILE="$CONFIG_DIR/api.pid"
API_KEYS_FILE="$CONFIG_DIR/api_keys.json"

cmd_api_v3() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    start)
      local port="${1:-$API_PORT}"
      local host="${2:-$API_HOST}"
      [[ -z "$PYTHON" ]] && { err "Python required for API server"; return 1; }

      # Check if already running
      if [[ -f "$API_PID_FILE" ]] && kill -0 "$(cat "$API_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        warn "API server already running (PID $(cat "$API_PID_FILE"))"
        return 0
      fi

      info "Starting API server v3 on ${host}:${port}..."
      API_HOST="$host" API_PORT="$port" \
      AI_CLI_BIN="$(command -v ai 2>/dev/null || echo "$0")" \
      AI_MODEL="${ACTIVE_MODEL:-}" AI_BACKEND="${ACTIVE_BACKEND:-}" \
      "$PYTHON" -c '
import http.server, json, os, subprocess, sys, threading, time, hashlib, secrets

HOST = os.environ.get("API_HOST", "0.0.0.0")
PORT = int(os.environ.get("API_PORT", "8080"))
CLI = os.environ.get("AI_CLI_BIN", "ai")
MODEL = os.environ.get("AI_MODEL", "auto")
BACKEND = os.environ.get("AI_BACKEND", "auto")
KEYS_FILE = os.environ.get("API_KEYS_FILE", os.path.expanduser("~/.config/ai-cli/api_keys.json"))

# Load API keys
def load_keys():
    try: return json.load(open(KEYS_FILE))
    except: return {"keys": []}

def save_keys(data):
    json.dump(data, open(KEYS_FILE, "w"), indent=2)

def check_key(key):
    if not key: return True  # No auth if no keys configured
    data = load_keys()
    if not data.get("keys"): return True
    return any(k["key"] == key and k.get("active", True) for k in data["keys"])

def ai_ask(prompt):
    try:
        r = subprocess.run([CLI, "ask", prompt], capture_output=True, text=True, timeout=120)
        return r.stdout.strip() or r.stderr.strip() or "No response"
    except Exception as e:
        return f"Error: {e}"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_OPTIONS(self):
        self._send(200, {})

    def _send_html(self, code, html):
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())

    def do_GET(self):
        if self.path == "/health": self._send(200, {"status": "ok"})
        elif self.path == "/v1/models": self._send(200, {"data": [{"id": MODEL, "object": "model"}]})
        elif self.path == "/chat":
            self._send_html(200, """<!DOCTYPE html><html><head><title>AI CLI Chat</title>
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:sans-serif;background:#1e1e2e;color:#cdd6f4;height:100vh;display:flex;flex-direction:column}
#msgs{flex:1;overflow-y:auto;padding:16px}.u{background:#313244;margin:8px 0 8px 40px;padding:10px;border-radius:8px}
.a{background:#181825;border:1px solid #313244;margin:8px 40px 8px 0;padding:10px;border-radius:8px;white-space:pre-wrap}
#bar{background:#181825;padding:10px;display:flex;gap:8px;border-top:1px solid #313244}
#p{flex:1;background:#313244;border:1px solid #45475a;color:#cdd6f4;padding:10px;border-radius:6px;font-size:14px;resize:none}
#p:focus{outline:none;border-color:#89b4fa}button{background:#89b4fa;color:#1e1e2e;border:none;padding:10px 18px;border-radius:6px;cursor:pointer;font-weight:600}
button:hover{background:#74c7ec}h3{padding:10px 16px;background:#181825;border-bottom:1px solid #313244;color:#89b4fa}</style></head>
<body><h3>AI CLI Chat</h3><div id="msgs"></div><div id="bar"><textarea id="p" rows="1" placeholder="Type a message..."></textarea><button onclick="send()">Send</button></div>
<script>const m=document.getElementById("msgs"),p=document.getElementById("p");
function add(r,t){const d=document.createElement("div");d.className=r;d.textContent=t;m.appendChild(d);m.scrollTop=m.scrollHeight}
async function send(){const t=p.value.trim();if(!t)return;p.value="";add("u",t);
try{const r=await fetch("/v1/chat/completions",{method:"POST",headers:{"Content-Type":"application/json"},
body:JSON.stringify({messages:[{role:"user",content:t}]})});const d=await r.json();
add("a",d.choices?.[0]?.message?.content||"No response")}catch(e){add("a","Error: "+e.message)}}
p.addEventListener("keydown",e=>{if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();send()}})</script></body></html>""")
        else: self._send(404, {"error": "not found"})

    def do_POST(self):
        auth = self.headers.get("Authorization", "").replace("Bearer ", "")
        if not check_key(auth):
            self._send(401, {"error": {"message": "Invalid API key"}}); return

        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path in ("/v1/chat/completions", "/v1/completions"):
            messages = body.get("messages", [])
            prompt = messages[-1]["content"] if messages else body.get("prompt", "")
            response = ai_ask(prompt)
            self._send(200, {
                "id": f"chatcmpl-{secrets.token_hex(12)}",
                "object": "chat.completion",
                "model": body.get("model", MODEL),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": response}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": len(prompt.split()), "completion_tokens": len(response.split()), "total_tokens": len(prompt.split()) + len(response.split())}
            })
        else:
            self._send(404, {"error": {"message": f"Unknown endpoint: {self.path}"}})

print(f"AI CLI API Server v3 — http://{HOST}:{PORT}")
print(f"Model: {MODEL} | Backend: {BACKEND}")
print(f"Endpoints: POST /v1/chat/completions, GET /v1/models, GET /health, GET /chat")
print("Press Ctrl+C to stop")
server = http.server.HTTPServer((HOST, PORT), Handler)
try: server.serve_forever()
except KeyboardInterrupt: print("\nStopped")
' &
      local pid=$!
      echo "$pid" > "$API_PID_FILE"
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        ok "API server v3 running on http://${host}:${port}"
        info "Chat UI:  http://localhost:${port}/chat"
        info "API test: curl http://localhost:${port}/health"
        info "Send:     curl -X POST http://localhost:${port}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
      else
        err "Server failed to start"
        rm -f "$API_PID_FILE"
      fi
      ;;
    stop)
      if [[ -f "$API_PID_FILE" ]]; then
        local pid; pid=$(cat "$API_PID_FILE")
        kill "$pid" 2>/dev/null && ok "Stopped (PID $pid)" || warn "Process not running"
        rm -f "$API_PID_FILE"
      else
        info "Not running"
      fi
      ;;
    status)
      if [[ -f "$API_PID_FILE" ]] && kill -0 "$(cat "$API_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        ok "Running (PID $(cat "$API_PID_FILE")) on ${API_HOST}:${API_PORT}"
      else
        info "Not running"
      fi
      ;;
    key-gen)
      local label="${1:-default}"
      local key="aicli-$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
      local data; data=$(cat "$API_KEYS_FILE" 2>/dev/null || echo '{"keys":[]}')
      echo "$data" | "$PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
d['keys'].append({'key':'$key','label':'$label','active':True,'created':'$(date -Iseconds)'})
json.dump(d,open('$API_KEYS_FILE','w'),indent=2)
" 2>/dev/null
      ok "API key generated"
      echo "  Key:   $key"
      echo "  Label: $label"
      echo "  Use:   curl -H 'Authorization: Bearer $key' ..."
      ;;
    keys)
      hdr "API Keys"
      [[ ! -f "$API_KEYS_FILE" ]] && { info "No keys. Generate: ai api key-gen"; return; }
      "$PYTHON" -c "
import json
d=json.load(open('$API_KEYS_FILE'))
for k in d.get('keys',[]):
    status='active' if k.get('active',True) else 'revoked'
    print(f\"  {k['key'][:8]}...  {k.get('label','?'):15s}  {status}  {k.get('created','?')}\")
" 2>/dev/null
      ;;
    test)
      local port="${1:-$API_PORT}"
      info "Testing API on port $port..."
      local resp; resp=$(curl -sS "http://localhost:${port}/health" 2>/dev/null)
      [[ "$resp" == *"ok"* ]] && ok "Server healthy" || err "Server not responding"
      ;;
    *)
      echo "Usage: ai api <start|stop|status|key-gen|keys|test>"
      echo ""
      echo "  start [port]    Start OpenAI-compatible API server"
      echo "  stop            Stop the server"
      echo "  status          Check if running"
      echo "  key-gen [label] Generate an API key"
      echo "  keys            List API keys"
      echo "  test [port]     Test the server"
      ;;
  esac
}
