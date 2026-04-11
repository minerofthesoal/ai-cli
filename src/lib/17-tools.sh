# ============================================================================
# MODULE: 17-tools.sh
# Builtin agent tools + web search backends
# Source lines 5979-6176 of main-v2.7.3
# ============================================================================

#  BUILTIN TOOLS
# ════════════════════════════════════════════════════════════════════════════════
BUILTIN_TOOLS=("web_search" "read_file" "write_file" "run_code" "list_dir"
               "get_time" "get_sysinfo" "calc" "download_file" "image_info")

run_tool() {
  local name="$1"; local args_json="${2:-{}}"
  case "$name" in
    web_search)
      local q; q=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('query',''))" 2>/dev/null)
      web_search "$q" 5 ;;
    read_file)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -f "$p" ]] && cat "$p" || echo "File not found: $p" ;;
    write_file)
      local p c
      p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      c=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('content',''))" 2>/dev/null)
      echo "$c" > "$p" && echo "Written: $p" ;;
    run_code)
      local lang code
      lang=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('language','python'))" 2>/dev/null)
      code=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('code',''))" 2>/dev/null)
      case "$lang" in
        python|py) echo "$code" | python3 2>&1 ;;
        bash|sh)   echo "$code" | bash 2>&1 ;;
        js|node)   echo "$code" | node 2>&1 ;;
        *) echo "Unsupported language: $lang" ;;
      esac ;;
    list_dir)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path','.'))" 2>/dev/null)
      ls -la "$p" 2>&1 ;;
    get_time) date ;;
    get_sysinfo)
      echo "OS: $(uname -s -r)"
      echo "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
      echo "RAM: $(free -h 2>/dev/null | awk '/^Mem/{print $2}' || echo '?')"
      [[ -n "$PYTHON" ]] && echo "Python: $($PYTHON --version 2>&1)"
      command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "GPU: none/unknown"
      ;;
    calc)
      local expr; expr=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('expression',''))" 2>/dev/null)
      python3 -c "import math; print(eval('$expr'))" 2>&1 ;;
    download_file)
      local url sp
      url=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('url',''))" 2>/dev/null)
      sp=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('save_path','/tmp/download'))" 2>/dev/null)
      curl -sL "$url" -o "$sp" && echo "Saved: $sp" ;;
    image_info)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "from PIL import Image; im=Image.open('$p'); print(f'Size: {im.size}, Mode: {im.mode}')" 2>/dev/null || file "$p" ;;
    *) echo "Unknown tool: $name" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  WEB SEARCH
# ════════════════════════════════════════════════════════════════════════════════
web_search() {
  local query="$1"; local max="${2:-5}"
  local encoded; encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null || echo "$query")

  if [[ "${SEARCH_ENGINE:-ddg}" == "brave" ]] && [[ -n "${BRAVE_API_KEY:-}" ]]; then
    curl -sS "https://api.search.brave.com/res/v1/web/search?q=${encoded}&count=${max}" \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: $BRAVE_API_KEY" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('web',{}).get('results',[])[:int('$max')]:
    print(f\"Title: {r.get('title','')}\")
    print(f\"URL: {r.get('url','')}\")
    print(f\"Snippet: {r.get('description','')[:200]}\")
    print()
" 2>/dev/null
  else
    curl -sS "https://api.duckduckgo.com/?q=${encoded}&format=json&no_redirect=1&no_html=1" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
results=[]
if d.get('AbstractText'):
    results.append({'title': d.get('Heading',''), 'url': d.get('AbstractURL',''), 'snippet': d.get('AbstractText','')})
for r in d.get('RelatedTopics',[])[:int('$max')]:
    if isinstance(r,dict) and r.get('Text'):
        results.append({'title': r.get('Text','')[:80], 'url': r.get('FirstURL',''), 'snippet': r.get('Text','')[:200]})
for r in results[:int('$max')]:
    print(f\"Title: {r['title']}\")
    print(f\"URL: {r['url']}\")
    print(f\"Snippet: {r['snippet']}\")
    print()
" 2>/dev/null
  fi
}

BUILTIN_TOOLS=("web_search" "read_file" "write_file" "run_code" "list_dir"
               "get_time" "get_sysinfo" "calc" "download_file" "image_info")

run_tool() {
  local name="$1"; local args_json="${2:-{}}"
  case "$name" in
    web_search)
      local q; q=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('query',''))" 2>/dev/null)
      web_search "$q" 5 ;;
    read_file)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -f "$p" ]] && cat "$p" || echo "File not found: $p" ;;
    write_file)
      local p c
      p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      c=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('content',''))" 2>/dev/null)
      echo "$c" > "$p" && echo "Written: $p" ;;
    run_code)
      local lang code
      lang=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('language','python'))" 2>/dev/null)
      code=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('code',''))" 2>/dev/null)
      case "$lang" in
        python|py) echo "$code" | python3 2>&1 ;;
        bash|sh)   echo "$code" | bash 2>&1 ;;
        js|node)   echo "$code" | node 2>&1 ;;
        *) echo "Unsupported language: $lang" ;;
      esac ;;
    list_dir)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path','.'))" 2>/dev/null)
      ls -la "$p" 2>&1 ;;
    get_time) date ;;
    get_sysinfo)
      echo "OS: $(uname -s -r)"
      echo "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
      echo "RAM: $(free -h 2>/dev/null | awk '/^Mem/{print $2}' || echo '?')"
      [[ -n "$PYTHON" ]] && echo "Python: $($PYTHON --version 2>&1)"
      command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "GPU: none/unknown"
      ;;
    calc)
      local expr; expr=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('expression',''))" 2>/dev/null)
      python3 -c "import math; print(eval('$expr'))" 2>&1 ;;
    download_file)
      local url sp
      url=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('url',''))" 2>/dev/null)
      sp=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('save_path','/tmp/download'))" 2>/dev/null)
      curl -sL "$url" -o "$sp" && echo "Saved: $sp" ;;
    image_info)
      local p; p=$(echo "$args_json" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('path',''))" 2>/dev/null)
      [[ -n "$PYTHON" ]] && "$PYTHON" -c "from PIL import Image; im=Image.open('$p'); print(f'Size: {im.size}, Mode: {im.mode}')" 2>/dev/null || file "$p" ;;
    *) echo "Unknown tool: $name" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  WEB SEARCH
# ════════════════════════════════════════════════════════════════════════════════
web_search() {
  local query="$1"; local max="${2:-5}"
  local encoded; encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null || echo "$query")

  if [[ "${SEARCH_ENGINE:-ddg}" == "brave" ]] && [[ -n "${BRAVE_API_KEY:-}" ]]; then
    curl -sS "https://api.search.brave.com/res/v1/web/search?q=${encoded}&count=${max}" \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: $BRAVE_API_KEY" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('web',{}).get('results',[])[:int('$max')]:
    print(f\"Title: {r.get('title','')}\")
    print(f\"URL: {r.get('url','')}\")
    print(f\"Snippet: {r.get('description','')[:200]}\")
    print()
" 2>/dev/null
  else
    curl -sS "https://api.duckduckgo.com/?q=${encoded}&format=json&no_redirect=1&no_html=1" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
results=[]
if d.get('AbstractText'):
    results.append({'title': d.get('Heading',''), 'url': d.get('AbstractURL',''), 'snippet': d.get('AbstractText','')})
for r in d.get('RelatedTopics',[])[:int('$max')]:
    if isinstance(r,dict) and r.get('Text'):
        results.append({'title': r.get('Text','')[:80], 'url': r.get('FirstURL',''), 'snippet': r.get('Text','')[:200]})
for r in results[:int('$max')]:
    print(f\"Title: {r['title']}\")
    print(f\"URL: {r['url']}\")
    print(f\"Snippet: {r['snippet']}\")
    print()
" 2>/dev/null
  fi
}

cmd_websearch() {
  local query="$*"
  [[ -z "$query" ]] && { read -rp "Search: " query; }
  hdr "Search: $query"
  echo ""
  web_search "$query" 10
}

# ════════════════════════════════════════════════════════════════════════════════
#  AI BACKENDS
