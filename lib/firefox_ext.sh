#!/usr/bin/env bash
# AI CLI v3.1.0 — Firefox Extension v2
# AI sidebar for Firefox that connects to the local API server

FIREFOX_EXT_DIR="$CONFIG_DIR/firefox_extension_v2"

cmd_install_firefox_ext_v2() {
  hdr "Firefox AI Sidebar Extension v2"
  mkdir -p "$FIREFOX_EXT_DIR"

  info "Building extension..."

  # manifest.json
  cat > "$FIREFOX_EXT_DIR/manifest.json" <<'MFJSON'
{
  "manifest_version": 2,
  "name": "AI CLI Sidebar",
  "version": "2.0.0",
  "description": "Chat with your local AI CLI from Firefox",
  "permissions": ["activeTab", "contextMenus", "storage"],
  "sidebar_action": {
    "default_title": "AI CLI",
    "default_panel": "sidebar.html",
    "default_icon": "icon.png"
  },
  "background": {
    "scripts": ["background.js"]
  },
  "icons": { "48": "icon.png", "96": "icon.png" }
}
MFJSON

  # sidebar.html
  cat > "$FIREFOX_EXT_DIR/sidebar.html" <<'SHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>AI CLI</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #1e1e2e; color: #cdd6f4; height: 100vh; display: flex; flex-direction: column; }
#header { background: #181825; padding: 8px 12px; border-bottom: 1px solid #313244; display: flex; align-items: center; gap: 8px; }
#header h3 { font-size: 13px; color: #89b4fa; flex: 1; }
#header input { background: #313244; border: none; color: #cdd6f4; padding: 4px 8px; border-radius: 4px; font-size: 11px; width: 120px; }
#header button { background: #313244; border: none; color: #cdd6f4; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 11px; }
#header button:hover { background: #45475a; }
#chat { flex: 1; overflow-y: auto; padding: 8px; }
.msg { margin: 6px 0; padding: 8px 10px; border-radius: 8px; font-size: 13px; line-height: 1.4; white-space: pre-wrap; word-break: break-word; }
.user { background: #313244; margin-left: 20px; }
.ai { background: #181825; border: 1px solid #313244; margin-right: 20px; }
.system { background: #1e1e2e; color: #6c7086; font-size: 11px; text-align: center; }
#input-area { background: #181825; padding: 8px; border-top: 1px solid #313244; display: flex; gap: 6px; }
#prompt { flex: 1; background: #313244; border: 1px solid #45475a; color: #cdd6f4; padding: 8px; border-radius: 6px; font-size: 13px; resize: none; min-height: 36px; max-height: 120px; font-family: inherit; }
#prompt:focus { outline: none; border-color: #89b4fa; }
#send { background: #89b4fa; color: #1e1e2e; border: none; padding: 8px 14px; border-radius: 6px; cursor: pointer; font-weight: 600; font-size: 13px; }
#send:hover { background: #74c7ec; }
#send:disabled { opacity: 0.5; cursor: not-allowed; }
.toolbar { display: flex; gap: 4px; padding: 4px 8px; background: #181825; }
.toolbar label { font-size: 11px; color: #6c7086; display: flex; align-items: center; gap: 3px; cursor: pointer; }
.toolbar input[type=checkbox] { accent-color: #89b4fa; }
</style>
</head>
<body>
<div id="header">
  <h3>AI CLI</h3>
  <input id="api-url" type="text" placeholder="http://localhost:8080" />
  <button id="settings-btn" title="Settings">⚙</button>
</div>
<div class="toolbar">
  <label><input type="checkbox" id="web-cb"> Web</label>
  <label><input type="checkbox" id="page-cb"> Page context</label>
</div>
<div id="chat">
  <div class="msg system">AI CLI Sidebar v2 — Connected to local API</div>
</div>
<div id="input-area">
  <textarea id="prompt" rows="1" placeholder="Ask anything..."></textarea>
  <button id="send">Send</button>
</div>
<script src="sidebar.js"></script>
</body>
</html>
SHTML

  # sidebar.js
  cat > "$FIREFOX_EXT_DIR/sidebar.js" <<'SJS'
const chat = document.getElementById('chat');
const prompt = document.getElementById('prompt');
const send = document.getElementById('send');
const apiUrl = document.getElementById('api-url');
const webCb = document.getElementById('web-cb');
const pageCb = document.getElementById('page-cb');

// Load settings
browser.storage.local.get(['apiUrl']).then(r => {
  apiUrl.value = r.apiUrl || 'http://localhost:8080';
});
apiUrl.addEventListener('change', () => {
  browser.storage.local.set({ apiUrl: apiUrl.value });
});

function addMsg(role, text) {
  const div = document.createElement('div');
  div.className = `msg ${role}`;
  div.textContent = text;
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
}

async function sendMessage() {
  let text = prompt.value.trim();
  if (!text) return;
  prompt.value = '';
  send.disabled = true;

  // Get page context if checked
  if (pageCb.checked) {
    try {
      const tabs = await browser.tabs.query({ active: true, currentWindow: true });
      const results = await browser.tabs.executeScript(tabs[0].id, {
        code: 'document.body.innerText.substring(0, 2000)'
      });
      if (results[0]) text = `Page context:\n${results[0]}\n\nQuestion: ${text}`;
    } catch (e) { console.log('Could not get page context:', e); }
  }

  if (webCb.checked) text = `[Search the web first] ${text}`;

  addMsg('user', text.length > 200 ? text.substring(0, 200) + '...' : text);

  try {
    const url = apiUrl.value || 'http://localhost:8080';
    const resp = await fetch(`${url}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: text }] })
    });
    const data = await resp.json();
    if (data.error) { addMsg('system', `Error: ${data.error.message || data.error}`); }
    else { addMsg('ai', data.choices[0].message.content); }
  } catch (e) {
    addMsg('system', `Connection error: ${e.message}\nMake sure AI CLI API is running: ai api start`);
  }
  send.disabled = false;
}

send.addEventListener('click', sendMessage);
prompt.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});
// Auto-resize textarea
prompt.addEventListener('input', () => {
  prompt.style.height = 'auto';
  prompt.style.height = Math.min(prompt.scrollHeight, 120) + 'px';
});
SJS

  # background.js — context menu
  cat > "$FIREFOX_EXT_DIR/background.js" <<'BGS'
browser.contextMenus.create({
  id: "ask-ai",
  title: "Ask AI: %s",
  contexts: ["selection"]
});
browser.contextMenus.create({
  id: "summarize-ai",
  title: "Summarize with AI",
  contexts: ["selection"]
});
browser.contextMenus.create({
  id: "explain-ai",
  title: "Explain with AI",
  contexts: ["selection"]
});

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  const text = info.selectionText;
  if (!text) return;
  let prompt = text;
  if (info.menuItemId === "summarize-ai") prompt = `Summarize: ${text}`;
  if (info.menuItemId === "explain-ai") prompt = `Explain: ${text}`;

  const settings = await browser.storage.local.get(['apiUrl']);
  const url = settings.apiUrl || 'http://localhost:8080';

  try {
    const resp = await fetch(`${url}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: prompt }] })
    });
    const data = await resp.json();
    const answer = data.choices?.[0]?.message?.content || 'No response';
    // Copy to clipboard and notify
    await navigator.clipboard.writeText(answer).catch(() => {});
    browser.notifications.create({ type: 'basic', title: 'AI CLI', message: answer.substring(0, 200) });
  } catch (e) {
    browser.notifications.create({ type: 'basic', title: 'AI CLI Error', message: 'API not running. Run: ai api start' });
  }
});
BGS

  # Simple icon (1x1 blue pixel PNG as placeholder)
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x000\x00\x00\x000\x08\x02\x00\x00\x00\xd8`\xa4\xe4' > "$FIREFOX_EXT_DIR/icon.png" 2>/dev/null || true

  ok "Firefox extension built: $FIREFOX_EXT_DIR"
  echo ""
  echo "  To install in Firefox:"
  echo "    1. Open Firefox → about:debugging"
  echo "    2. Click 'This Firefox' → 'Load Temporary Add-on'"
  echo "    3. Select: $FIREFOX_EXT_DIR/manifest.json"
  echo ""
  echo "  Features:"
  echo "    • Sidebar chat panel (View → Sidebar → AI CLI)"
  echo "    • Right-click context menu: Ask AI, Summarize, Explain"
  echo "    • Page context checkbox: include current page text"
  echo "    • Web search checkbox: search before answering"
  echo ""
  echo "  Requires: ai api start (run the local API server first)"
}
