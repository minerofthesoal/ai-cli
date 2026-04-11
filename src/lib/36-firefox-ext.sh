# ============================================================================
# MODULE: 36-firefox-ext.sh
# Firefox LLM sidebar extension builder
# Source lines 13015-13459 of main-v2.7.3
# ============================================================================

cmd_install_firefox_ext() {
  local out_dir="$FIREFOX_EXT_DIR"
  local api_url="${1:-http://localhost:8080}"
  mkdir -p "$out_dir"

  info "Building Firefox LLM Sidebar Extension..."
  info "API endpoint: $api_url"

  # ── manifest.json (WebExtension Manifest V2 — Firefox) ────────────────────
  cat > "$out_dir/manifest.json" <<JSON
{
  "manifest_version": 2,
  "name": "AI CLI — Local LLM Sidebar",
  "version": "1.1.0",
  "description": "Use your locally-installed LLMs from the AI CLI directly in the Firefox sidebar. v2.7.1: fixed AI output, non-streaming API.",
  "author": "AI CLI v${VERSION}",
  "sidebar_action": {
    "default_title": "AI CLI LLM",
    "default_panel": "sidebar.html",
    "default_icon": "icon.svg"
  },
  "permissions": [
    "storage",
    "https://*/*",
    "http://localhost/*",
    "http://127.0.0.1/*"
  ],
  "background": {
    "scripts": ["background.js"],
    "persistent": false
  },
  "browser_action": {
    "default_icon": "icon.svg",
    "default_title": "Toggle AI CLI Sidebar",
    "browser_style": false
  },
  "icons": {
    "48": "icon.svg",
    "96": "icon.svg"
  },
  "browser_specific_settings": {
    "gecko": {
      "id": "ai-cli-llm-sidebar@local",
      "strict_min_version": "109.0"
    }
  }
}
JSON

  # ── sidebar.html ──────────────────────────────────────────────────────────
  cat > "$out_dir/sidebar.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI CLI — LLM Sidebar</title>
  <style>
    :root {
      --bg: #1a1b26;
      --bg2: #16161e;
      --fg: #c0caf5;
      --accent: #7aa2f7;
      --accent2: #9ece6a;
      --warn: #e0af68;
      --err: #f7768e;
      --dim: #565f89;
      --border: #292e42;
      --sel: #283457;
      --user-bg: #1f3054;
      --ai-bg:   #1c2e1c;
      --radius:  8px;
      --font: 'Segoe UI', system-ui, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg); color: var(--fg);
      font-family: var(--font); font-size: 13px;
      display: flex; flex-direction: column; height: 100vh;
      overflow: hidden;
    }
    /* ── Header ── */
    #header {
      background: var(--bg2); border-bottom: 1px solid var(--border);
      padding: 8px 10px; display: flex; align-items: center; gap: 8px;
      flex-shrink: 0;
    }
    #header h1 { font-size: 14px; font-weight: 700; color: var(--accent); flex: 1; }
    #status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim); }
    #status-dot.ok  { background: var(--accent2); }
    #status-dot.err { background: var(--err); }
    /* ── Settings panel ── */
    #settings {
      background: var(--bg2); border-bottom: 1px solid var(--border);
      padding: 6px 10px; display: none; gap: 6px; flex-direction: column;
    }
    #settings.visible { display: flex; }
    #settings label { font-size: 11px; color: var(--dim); margin-bottom: 2px; }
    #settings input, #settings select {
      background: var(--bg); border: 1px solid var(--border); color: var(--fg);
      border-radius: 4px; padding: 4px 6px; font-size: 12px; width: 100%;
    }
    /* ── Messages ── */
    #messages {
      flex: 1; overflow-y: auto; padding: 10px; display: flex;
      flex-direction: column; gap: 8px;
    }
    .msg {
      border-radius: var(--radius); padding: 8px 10px; max-width: 95%;
      word-break: break-word; line-height: 1.5;
    }
    .msg.user { background: var(--user-bg); align-self: flex-end; border: 1px solid var(--accent); }
    .msg.ai   { background: var(--ai-bg);   align-self: flex-start; border: 1px solid var(--accent2); }
    .msg.sys  { background: transparent; color: var(--dim); font-style: italic; font-size: 11px; align-self: center; }
    .msg .role { font-size: 10px; font-weight: 700; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
    .msg.user .role { color: var(--accent); }
    .msg.ai   .role { color: var(--accent2); }
    /* ── Thinking dots ── */
    .thinking-dots span { animation: blink 1.2s infinite; }
    .thinking-dots span:nth-child(2) { animation-delay: 0.2s; }
    .thinking-dots span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes blink { 0%,80%,100%{opacity:0} 40%{opacity:1} }
    /* ── Input area ── */
    #input-area {
      flex-shrink: 0; border-top: 1px solid var(--border);
      padding: 8px 10px; display: flex; flex-direction: column; gap: 6px;
      background: var(--bg2);
    }
    #input {
      background: var(--bg); border: 1px solid var(--border); color: var(--fg);
      border-radius: var(--radius); padding: 8px 10px; font-size: 13px;
      font-family: var(--font); resize: none; min-height: 56px; max-height: 120px;
      outline: none; transition: border-color 0.15s;
    }
    #input:focus { border-color: var(--accent); }
    .btn-row { display: flex; gap: 6px; }
    button {
      border: none; border-radius: 5px; padding: 5px 12px; cursor: pointer;
      font-size: 12px; font-weight: 600; transition: opacity 0.15s;
    }
    button:hover { opacity: 0.85; }
    #send-btn  { background: var(--accent);  color: #1a1b26; flex: 1; }
    #clear-btn { background: var(--border);  color: var(--fg); }
    #cfg-btn   { background: var(--border);  color: var(--fg); }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    /* ── Scrollbar ── */
    ::-webkit-scrollbar { width: 4px; }
    ::-webkit-scrollbar-track { background: var(--bg2); }
    ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
    /* ── Code blocks ── */
    pre, code {
      background: #0d0d15; border: 1px solid var(--border);
      border-radius: 4px; font-family: monospace; font-size: 11px;
      padding: 2px 4px;
    }
    pre { padding: 8px; overflow-x: auto; white-space: pre-wrap; margin: 4px 0; }
    pre code { background: none; border: none; padding: 0; }
  </style>
</head>
<body>
  <div id="header">
    <div id="status-dot" title="API status"></div>
    <h1>AI CLI — LLM</h1>
    <button id="cfg-btn" style="padding:3px 8px;font-size:11px;">⚙</button>
  </div>

  <div id="settings">
    <div>
      <label>API URL</label>
      <input id="api-url" type="text" placeholder="http://localhost:8080">
    </div>
    <div>
      <label>Model (leave blank for default)</label>
      <input id="model-input" type="text" placeholder="">
    </div>
    <div>
      <label>Max tokens</label>
      <input id="max-tokens" type="number" value="1024" min="64" max="8192" step="64">
    </div>
    <div>
      <label>Temperature</label>
      <input id="temperature" type="number" value="0.7" min="0" max="2" step="0.05">
    </div>
    <button id="save-cfg" style="background:var(--accent);color:#1a1b26;">Save</button>
  </div>

  <div id="messages">
    <div class="msg sys">AI CLI LLM Sidebar v1.1 — Type a message to begin. Make sure "ai api start" is running.</div>
  </div>

  <div id="input-area">
    <textarea id="input" placeholder="Ask anything… (Enter=send, Shift+Enter=newline)" rows="2"></textarea>
    <div class="btn-row">
      <button id="clear-btn">Clear</button>
      <button id="send-btn">Send ⏎</button>
    </div>
  </div>

  <script src="sidebar.js"></script>
</body>
</html>
HTML

  # ── sidebar.js ────────────────────────────────────────────────────────────
  cat > "$out_dir/sidebar.js" <<JSEOF
'use strict';

// ── Config ─────────────────────────────────────────────────────────────────
const DEFAULT_API = '${api_url}';
const STORAGE_KEY = 'aiCLI_cfg';

let cfg = {
  apiUrl:      DEFAULT_API,
  model:       '',
  maxTokens:   1024,
  temperature: 0.7,
};

function loadCfg() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) Object.assign(cfg, JSON.parse(raw));
  } catch {}
  document.getElementById('api-url').value    = cfg.apiUrl;
  document.getElementById('model-input').value = cfg.model;
  document.getElementById('max-tokens').value  = cfg.maxTokens;
  document.getElementById('temperature').value = cfg.temperature;
}

function saveCfg() {
  cfg.apiUrl      = document.getElementById('api-url').value.trim() || DEFAULT_API;
  cfg.model       = document.getElementById('model-input').value.trim();
  cfg.maxTokens   = parseInt(document.getElementById('max-tokens').value) || 1024;
  cfg.temperature = parseFloat(document.getElementById('temperature').value) || 0.7;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
  toggleSettings();
  checkHealth();
}

// ── UI helpers ─────────────────────────────────────────────────────────────
const messagesEl  = document.getElementById('messages');
const inputEl     = document.getElementById('input');
const sendBtn     = document.getElementById('send-btn');
const clearBtn    = document.getElementById('clear-btn');
const cfgBtn      = document.getElementById('cfg-btn');
const settingsEl  = document.getElementById('settings');
const statusDot   = document.getElementById('status-dot');

let history = [];   // [{role, content}]

function toggleSettings() {
  settingsEl.classList.toggle('visible');
}

function appendMsg(role, text) {
  const div = document.createElement('div');
  div.className = 'msg ' + role;
  const roleLabel = document.createElement('div');
  roleLabel.className = 'role';
  roleLabel.textContent = role === 'user' ? 'You' : role === 'ai' ? 'AI' : 'System';
  div.appendChild(roleLabel);
  const content = document.createElement('div');
  content.innerHTML = formatMarkdown(text);
  div.appendChild(content);
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return content;
}

function thinkingMsg() {
  const div = document.createElement('div');
  div.className = 'msg ai';
  const roleLabel = document.createElement('div');
  roleLabel.className = 'role';
  roleLabel.textContent = 'AI';
  div.appendChild(roleLabel);
  const dots = document.createElement('div');
  dots.className = 'thinking-dots';
  dots.innerHTML = '<span>●</span><span>●</span><span>●</span>';
  div.appendChild(dots);
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return div;
}

function formatMarkdown(text) {
  // Very light markdown: code blocks, inline code, bold, italic, newlines
  return text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\`\`\`([\s\S]*?)\`\`\`/g, '<pre><code>\$1</code></pre>')
    .replace(/\`([^\`]+)\`/g, '<code>\$1</code>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>\$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>\$1</em>')
    .replace(/\n/g, '<br>');
}

// ── API health check ────────────────────────────────────────────────────────
async function checkHealth() {
  try {
    const r = await fetch(cfg.apiUrl + '/health', { signal: AbortSignal.timeout(3000) });
    statusDot.className = r.ok ? 'ok' : 'err';
    statusDot.title = r.ok ? 'API connected' : 'API error ' + r.status;
  } catch {
    statusDot.className = 'err';
    statusDot.title = 'API not reachable — run: ai api start';
  }
}

// ── Send message ────────────────────────────────────────────────────────────
async function sendMessage() {
  const text = inputEl.value.trim();
  if (!text) return;
  inputEl.value = '';
  sendBtn.disabled = true;

  history.push({ role: 'user', content: text });
  appendMsg('user', text);

  const thinking = thinkingMsg();

  // Build request body — non-streaming (server returns plain JSON)
  // v2.7.1 fix: do NOT send stream:true — the AI CLI API server does not
  // support SSE streaming and returns standard JSON. Sending stream:true
  // caused the client to look for "data:" SSE lines and find none, resulting
  // in empty AI output even when the server responded correctly.
  const body = {
    model:       cfg.model || undefined,
    messages:    history,
    max_tokens:  cfg.maxTokens,
    temperature: cfg.temperature,
  };

  try {
    const res = await fetch(cfg.apiUrl + '/v1/chat/completions', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error('HTTP ' + res.status + ': ' + errText.slice(0, 200));
    }

    // ── Non-streaming JSON response (standard OpenAI format) ─────────────
    const data = await res.json();

    // Extract response text from choices[0].message.content
    const aiText = data?.choices?.[0]?.message?.content
                || data?.choices?.[0]?.text
                || '';

    thinking.remove();

    if (!aiText && aiText !== 0) {
      // Response received but no content — show raw for debugging
      appendMsg('sys', 'Warning: empty response. Raw: ' + JSON.stringify(data).slice(0, 300));
    } else {
      appendMsg('ai', String(aiText));
      history.push({ role: 'assistant', content: String(aiText) });
    }

    // Update status dot to green on success
    statusDot.className = 'ok';
    statusDot.title = 'API connected — last call OK';

  } catch (err) {
    thinking.remove();
    appendMsg('sys', 'Error: ' + err.message + '\n\nMake sure "ai api start" is running:\n  ai api start\n  ai api status');
    statusDot.className = 'err';
  } finally {
    sendBtn.disabled = false;
    inputEl.focus();
  }
}

// ── Event listeners ─────────────────────────────────────────────────────────
sendBtn.addEventListener('click', sendMessage);
clearBtn.addEventListener('click', () => {
  history = [];
  messagesEl.innerHTML = '<div class="msg sys">Cleared. Start a new conversation.</div>';
});
cfgBtn.addEventListener('click', toggleSettings);
document.getElementById('save-cfg').addEventListener('click', saveCfg);

inputEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

// ── Init ────────────────────────────────────────────────────────────────────
loadCfg();
checkHealth();
setInterval(checkHealth, 30000);
JSEOF

  # ── background.js ─────────────────────────────────────────────────────────
  cat > "$out_dir/background.js" <<'BGJS'
'use strict';
// Toggle sidebar via browser action click
browser.browserAction.onClicked.addListener(() => {
  browser.sidebarAction.toggle();
});
BGJS

  # ── icon.svg ──────────────────────────────────────────────────────────────
  cat > "$out_dir/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <rect width="48" height="48" rx="10" fill="#1a1b26"/>
  <text x="24" y="34" text-anchor="middle" font-size="28" font-family="monospace" font-weight="bold" fill="#7aa2f7">AI</text>
</svg>
SVG

  echo ""
  ok "Firefox LLM Sidebar Extension built at: $out_dir"
  echo ""
  echo -e "  ${B}Files:${R}"
  ls -1 "$out_dir" | sed 's/^/    /'
  echo ""
  echo -e "  ${B}How to install in Firefox:${R}"
  echo -e "    1. Open Firefox and go to ${CYAN}about:debugging#/runtime/this-firefox${R}"
  echo -e "    2. Click ${B}\"Load Temporary Add-on…\"${R}"
  echo -e "    3. Navigate to: ${CYAN}${out_dir}/manifest.json${R}"
  echo -e "    4. The AI CLI sidebar will appear in Firefox"
  echo -e "    5. Before using: run ${B}ai api start${R} to start the local LLM API"
  echo ""
  echo -e "  ${B}Permanent install (for nightly / developer edition):${R}"
  echo -e "    Set ${CYAN}xpinstall.signatures.required${R} to ${B}false${R} in about:config"
  echo -e "    Then use the Web Extension package method."
  echo ""
  echo -e "  ${B}Package as .xpi:${R}"
  echo -e "    cd ${out_dir} && zip -r ../ai-cli-firefox.xpi . && echo Done"
  echo ""
  echo -e "  ${DIM}The sidebar connects to: ${api_url}${R}"
  echo -e "  ${DIM}Change URL in the ⚙ settings inside the sidebar.${R}"
  echo ""

  # Offer to package as .xpi
  if command -v zip &>/dev/null; then
    local xpi_out="$BUILD_DIR/ai-cli-firefox.xpi"
    cd "$out_dir" && zip -rq "$xpi_out" . 2>/dev/null && cd - >/dev/null
    ok "Also packaged as: $xpi_out"
    echo -e "  ${DIM}To install .xpi: drag it onto Firefox or use about:addons → gear → Install from file${R}"
  fi
}

