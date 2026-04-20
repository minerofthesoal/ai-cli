#!/usr/bin/env bash
# Return if sourced before config is loaded
[[ -z "${VERSION:-}" ]] && return 0 2>/dev/null || true
# AI CLI v3.1.0 — API Server v3
# OpenAI-compatible REST API server with key management

API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8080}"
API_PID_FILE="${CONFIG_DIR:-$HOME/.config/ai-cli}/api.pid"
API_KEYS_FILE="${CONFIG_DIR:-$HOME/.config/ai-cli}/api_keys.json"

cmd_api_v3() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    start)
      local port="${1:-$API_PORT}"
      local host="${2:-$API_HOST}"
      local use_tailscale=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port) port="$2"; shift 2 ;;
          --host) host="$2"; shift 2 ;;
          --tailscale|--ts) use_tailscale=1; shift ;;
          --public) host="0.0.0.0"; shift ;;
          *) shift ;;
        esac
      done
      [[ -z "$PYTHON" ]] && { err "Python required for API server"; return 1; }
      # Tailscale: get tailscale IP if available
      if [[ $use_tailscale -eq 1 ]]; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
        if [[ -n "$ts_ip" ]]; then
          host="$ts_ip"
          info "Tailscale IP: $ts_ip"
        else
          warn "Tailscale not found or not connected. Using $host"
        fi
      fi

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

def run_cmd(cmd):
    try:
        r = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True, timeout=120,
                          env={**os.environ, "NO_COLOR": "1"})
        import re
        out = re.sub(r'\x1b\[[0-9;]*m', '', (r.stdout + r.stderr).strip())
        return out or "Done"
    except Exception as e:
        return f"Error: {e}"

def ai_ask(prompt):
    try:
        r = subprocess.run([CLI, "ask", prompt], capture_output=True, text=True, timeout=120)
        return r.stdout.strip() or r.stderr.strip() or "No response"
    except Exception as e:
        return f"Error: {e}"

SITE_HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AI CLI Dashboard</title>
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh}
nav{background:#181825;padding:12px 20px;display:flex;gap:12px;border-bottom:1px solid #313244;align-items:center;flex-wrap:wrap}
nav h2{color:#89b4fa;margin-right:auto}nav button{background:#313244;color:#cdd6f4;border:none;padding:8px 16px;border-radius:6px;cursor:pointer;font-size:13px}
nav button:hover{background:#45475a}nav button.active{background:#89b4fa;color:#1e1e2e}
.panel{display:none;padding:20px;max-width:900px;margin:0 auto}.panel.active{display:block}
textarea,input[type=text]{background:#313244;border:1px solid #45475a;color:#cdd6f4;padding:10px;border-radius:6px;font-family:monospace;font-size:14px;width:100%}
textarea:focus,input:focus{outline:none;border-color:#89b4fa}
.btn{background:#89b4fa;color:#1e1e2e;border:none;padding:10px 20px;border-radius:6px;cursor:pointer;font-weight:600;margin:4px}
.btn:hover{background:#74c7ec}.btn-sm{padding:6px 12px;font-size:12px}.btn-red{background:#f38ba8}.btn-green{background:#a6e3a1}
.card{background:#181825;border:1px solid #313244;border-radius:8px;padding:16px;margin:10px 0}
.output{background:#181825;border:1px solid #313244;border-radius:8px;padding:16px;margin:10px 0;white-space:pre-wrap;max-height:400px;overflow-y:auto;font-family:monospace;font-size:13px}
h3{color:#89b4fa;margin-bottom:10px}label{color:#a6adc8;font-size:13px;display:block;margin:8px 0 4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px}
.stat{background:#313244;padding:12px;border-radius:6px;text-align:center}.stat h4{color:#89b4fa;font-size:12px}.stat p{font-size:20px;font-weight:600}
.chat-msg{margin:8px 0;padding:10px;border-radius:8px}.chat-user{background:#313244;margin-left:40px}.chat-ai{background:#181825;border:1px solid #313244;margin-right:40px}
</style></head><body>
<nav><h2>AI CLI Dashboard</h2>
<button class="active" onclick="show('chat')">Chat</button>
<button onclick="show('models')">Models</button>
<button onclick="show('settings')">Settings</button>
<button onclick="show('keys')">API Keys</button>
<button onclick="show('tools')">Tools</button>
</nav>
<div id="chat" class="panel active">
<h3>Chat</h3>
<div id="msgs" class="output" style="min-height:200px"></div>
<div style="display:flex;gap:8px;margin-top:8px"><textarea id="prompt" rows="2" placeholder="Type a message..."></textarea><button class="btn" onclick="sendChat()">Send</button></div>
</div>
<div id="models" class="panel">
<h3>Models</h3><button class="btn btn-sm" onclick="runCmd('models')">Refresh</button> <button class="btn btn-sm" onclick="runCmd('recommended')">Browse All</button>
<div id="models-out" class="output">Loading...</div>
</div>
<div id="settings" class="panel">
<h3>Settings</h3><button class="btn btn-sm" onclick="runCmd('status')">Status</button> <button class="btn btn-sm" onclick="runCmd('health')">Health</button> <button class="btn btn-sm" onclick="runCmd('sysinfo')">System Info</button>
<div id="settings-out" class="output">Click a button above</div>
</div>
<div id="keys" class="panel">
<h3>API Key Management</h3>
<div class="card"><label>Create new API key</label><input type="text" id="key-label" placeholder="Key label"><button class="btn btn-sm" onclick="genKey()" style="margin-top:8px">Generate Key</button></div>
<button class="btn btn-sm" onclick="listKeys()">List Keys</button>
<div id="keys-out" class="output"></div>
</div>
<div id="tools" class="panel">
<h3>Quick Tools</h3>
<div class="grid">
<button class="btn btn-sm" onclick="runCmd('test -S')">Speed Test</button>
<button class="btn btn-sm" onclick="runCmd('test -N')">Network Test</button>
<button class="btn btn-sm" onclick="runCmd('analytics')">Analytics</button>
<button class="btn btn-sm" onclick="runCmd('security')">Security</button>
<button class="btn btn-sm" onclick="runCmd('cleanup --dry-run')">Cleanup</button>
<button class="btn btn-sm" onclick="runCmd('memory list')">Memory</button>
<button class="btn btn-sm" onclick="runCmd('snap list')">Snapshots</button>
<button class="btn btn-sm" onclick="runCmd('plugin list')">Plugins</button>
</div>
<div id="tools-out" class="output" style="margin-top:12px"></div>
</div>
<script>
const API=location.origin;
function show(id){document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));document.getElementById(id).classList.add('active');document.querySelectorAll('nav button').forEach(b=>b.classList.remove('active'));event.target.classList.add('active')}
function addMsg(r,t){const d=document.createElement('div');d.className='chat-msg chat-'+r;d.textContent=t;document.getElementById('msgs').appendChild(d);document.getElementById('msgs').scrollTop=9e9}
async function sendChat(){const p=document.getElementById('prompt');const t=p.value.trim();if(!t)return;p.value='';addMsg('user',t);try{const r=await fetch(API+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:[{role:'user',content:t}]})});const d=await r.json();addMsg('ai',d.choices?.[0]?.message?.content||'No response')}catch(e){addMsg('ai','Error: '+e.message)}}
async function runCmd(c){const out=document.querySelector('.panel.active .output')||document.getElementById('tools-out');out.textContent='Running...';try{const r=await fetch(API+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:[{role:'user',content:'/cmd '+c}]})});const d=await r.json();out.textContent=d.choices?.[0]?.message?.content||'No output'}catch(e){out.textContent='Error: '+e.message}}
async function genKey(){const l=document.getElementById('key-label').value||'default';const r=await fetch(API+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:[{role:'user',content:'/cmd api key-gen '+l}]})});const d=await r.json();document.getElementById('keys-out').textContent=d.choices?.[0]?.message?.content||'Error'}
async function listKeys(){const r=await fetch(API+'/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:[{role:'user',content:'/cmd api keys'}]})});const d=await r.json();document.getElementById('keys-out').textContent=d.choices?.[0]?.message?.content||'No keys'}
document.getElementById('prompt').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendChat()}});
</script></body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _serve_site(self):
        self._send_html(200, SITE_HTML)

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
        if self.path == "/health": self._send(200, {"status": "ok", "version": "3.1"})
        elif self.path == "/v1/models": self._send(200, {"data": [{"id": MODEL, "object": "model"}]})
        elif self.path == "/v3/site": self._serve_site()
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
            if prompt.startswith("/cmd "):
                cmd = prompt[5:]
                response = run_cmd(cmd)
            else:
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
        info "Dashboard: http://${host}:${port}/v3/site"
        info "Chat UI:   http://${host}:${port}/chat"
        info "Health:    http://${host}:${port}/health"
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
      echo "  start [--port N] [--tailscale] [--public]"
      echo "                  Start API server with dashboard"
      echo "  Endpoints:"
      echo "    /v3/site      Full web dashboard"
      echo "    /chat         Simple chat UI"
      echo "    /v1/chat/completions   OpenAI-compatible API"
      echo "    /health       Health check"
      echo ""
      echo "  start           Start on localhost:8080"
      echo "  stop            Stop the server"
      echo "  status          Check if running"
      echo "  key-gen [label] Generate an API key"
      echo "  keys            List API keys"
      echo "  test [port]     Test the server"
      ;;
  esac
}
