# ============================================================================
# MODULE: 10-agent.sh
# Multi-step agent mode + agentic web search
# Source lines 3558-3818 of main-v2.7.3
# ============================================================================

#  AGENT MODE — multi-step agentic task execution with web search
# ════════════════════════════════════════════════════════════════════════════════

declare -A AGENT_TOOLS_REGISTRY
AGENT_TOOLS_REGISTRY=(
  [web_search]="Search the web for current information. Args: {query: string}"
  [read_url]="Read the content of a URL. Args: {url: string}"
  [write_file]="Write content to a file. Args: {path: string, content: string}"
  [read_file]="Read a file's content. Args: {path: string}"
  [run_code]="Execute Python code. Args: {code: string}"
  [run_bash]="Execute a bash command. Args: {command: string}"
  [ask_user]="Ask the user a clarifying question. Args: {question: string}"
  [calculate]="Evaluate a math expression. Args: {expression: string}"
)

_agent_web_search() {
  local query="$1"
  # Try multiple search backends (no rate limiting)
  local results=""

  # DDG
  if [[ "${AGENT_SEARCH_ENGINE:-ddg}" == "ddg" ]] || true; then
    results=$(curl -sS --max-time 10 --retry 3 \
      -H "User-Agent: Mozilla/5.0 (compatible; ai-cli)" \
      "https://api.duckduckgo.com/?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "${query// /+}")&format=json&no_redirect=1" \
      2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    items=[]
    if d.get('AbstractText'): items.append({'title':'Summary','snippet':d['AbstractText'],'url':d.get('AbstractURL','')})
    for r in d.get('RelatedTopics',[])[:6]:
        if isinstance(r,dict) and r.get('Text'):
            items.append({'title':r.get('Text','')[:60],'snippet':r.get('Text',''),'url':r.get('FirstURL','')})
    print(json.dumps(items[:5]))
except: print('[]')
" 2>/dev/null)
  fi

  # Brave Search API if key available
  if [[ -n "${BRAVE_API_KEY:-}" ]] && [[ -z "$results" || "$results" == "[]" ]]; then
    results=$(curl -sS --max-time 10 --retry 3 \
      -H "Accept: application/json" \
      -H "Accept-Encoding: gzip" \
      -H "X-Subscription-Token: $BRAVE_API_KEY" \
      "https://api.search.brave.com/res/v1/web/search?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")" \
      2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    items=[{'title':r.get('title',''),'snippet':r.get('description',''),'url':r.get('url','')}
           for r in d.get('web',{}).get('results',[])]
    print(json.dumps(items[:6]))
except: print('[]')
" 2>/dev/null)
  fi

  echo "${results:-[]}"
}

_agent_read_url() {
  local url="$1"
  curl -sS --max-time 15 --retry 2 \
    -H "User-Agent: Mozilla/5.0" \
    -L "$url" 2>/dev/null | python3 -c "
import sys,re
html=sys.stdin.read()
# Strip HTML tags
text=re.sub(r'<script[^>]*>.*?</script>','',html,flags=re.DOTALL|re.IGNORECASE)
text=re.sub(r'<style[^>]*>.*?</style>','',text,flags=re.DOTALL|re.IGNORECASE)
text=re.sub(r'<[^>]+>','',text)
text=re.sub(r'\s+',' ',text).strip()
print(text[:3000])
" 2>/dev/null
}

_agent_run_code() {
  local code="$1"
  echo "$code" | python3 2>&1 | head -50
}

_agent_execute_step() {
  local tool="$1" args="$2"
  case "$tool" in
    web_search)
      local q; q=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('query',''))" 2>/dev/null)
      _agent_web_search "$q"
      ;;
    read_url)
      local url; url=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
      _agent_read_url "$url"
      ;;
    write_file)
      local path content
      path=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
      content=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))" 2>/dev/null)
      echo "$content" > "$path" && echo "Written: $path"
      ;;
    read_file)
      local p; p=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
      cat "$p" 2>/dev/null || echo "File not found: $p"
      ;;
    run_code)
      local code; code=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
      _agent_run_code "$code"
      ;;
    run_bash)
      local cmd; cmd=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command',''))" 2>/dev/null)
      eval "$cmd" 2>&1 | head -50
      ;;
    ask_user)
      local q; q=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('question',''))" 2>/dev/null)
      read -rp "$q: " ans; echo "$ans"
      ;;
    calculate)
      local expr; expr=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin).get('expression',''))" 2>/dev/null)
      python3 -c "print(eval('$expr'))" 2>/dev/null
      ;;
    *)
      echo "Unknown tool: $tool"
      ;;
  esac
}

cmd_agent() {
  local task="$*"
  [[ -z "$task" ]] && { read -rp "Task: " task; }
  [[ -z "$task" ]] && return

  AGENT_MODE=1
  local max_steps="${AGENT_MAX_STEPS:-10}"
  local step=0
  local history=()
  local done=0

  hdr "🤖 Agent Mode — Task: $task"
  echo ""

  # Build tools list for the model
  local tools_desc
  tools_desc=$(for t in "${!AGENT_TOOLS_REGISTRY[@]}"; do
    echo "  - $t: ${AGENT_TOOLS_REGISTRY[$t]}"; done)

  local system_prompt="You are an autonomous AI agent. Break complex tasks into steps using available tools.
Available tools:
$tools_desc

Respond in this exact JSON format when using a tool:
{\"thought\": \"reasoning\", \"tool\": \"tool_name\", \"args\": {\"key\": \"value\"}}

Or when done:
{\"thought\": \"reasoning\", \"done\": true, \"answer\": \"final answer\"}

Be systematic. Use web_search for current information. Never make up facts."

  local context="Task: $task"

  while (( step < max_steps && done == 0 )); do
    (( step++ ))
    printf "\n${B}${BCYAN}Step %d/%d${R}\n" "$step" "$max_steps"

    # Get next action from AI
    local response
    response=$(AI_SYSTEM_OVERRIDE="$system_prompt" dispatch_ask "$context" 2>/dev/null)
    echo -e "${DIM}$response${R}"

    # Parse JSON response
    local thought tool args final_answer is_done
    thought=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('thought',''))" 2>/dev/null)
    tool=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('tool',''))" 2>/dev/null)
    args=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(json.dumps(d.get('args',{})))" 2>/dev/null || echo "{}")
    is_done=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('done','false'))" 2>/dev/null)
    final_answer=$(echo "$response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read().strip()); print(d.get('answer',''))" 2>/dev/null)

    [[ -n "$thought" ]] && echo -e "${DIM}  💭 $thought${R}"

    if [[ "$is_done" == "True" || "$is_done" == "true" || -n "$final_answer" ]]; then
      done=1
      echo ""
      hdr "✅ Agent Complete"
      echo -e "${BWHITE}$final_answer${R}"
      break
    fi

    if [[ -n "$tool" && "$tool" != "None" && "$tool" != "null" ]]; then
      echo -e "  ${BBLUE}🔧 Tool: $tool${R}"
      local tool_result
      tool_result=$(_agent_execute_step "$tool" "$args")
      echo -e "  ${DIM}Result: ${tool_result:0:500}${R}"
      context="${context}\n\nStep $step — Used: $tool\nResult: ${tool_result:0:1000}"
    else
      # Model gave a plain response, not JSON — treat as final answer
      done=1
      hdr "✅ Agent Response"
      echo "$response"
    fi
  done

  if (( done == 0 )); then
    warn "Max steps ($max_steps) reached. Use 'ai config agent_max_steps N' to increase."
  fi
  AGENT_MODE=0
}

# ════════════════════════════════════════════════════════════════════════════════
#  ENHANCED WEB SEARCH (no rate limiting, multiple backends)
# ════════════════════════════════════════════════════════════════════════════════
cmd_websearch() {
  local query="$*"; local backend="${SEARCH_ENGINE:-ddg}"
  [[ -z "$query" ]] && { read -rp "Search: " query; }
  [[ -z "$query" ]] && return

  hdr "🌐 Web Search: $query"
  echo ""

  local results_json
  results_json=$(_agent_web_search "$query")

  # Display results
  echo "$results_json" | python3 - "$query" <<'PYEOF'
import json, sys
try:
    results = json.loads(sys.stdin.read())
    if not results:
        print("  No results found")
        sys.exit(0)
    for i, r in enumerate(results, 1):
        print(f"  {i}. {r.get('title','')[:70]}")
        snippet = r.get('snippet','')
        if snippet and snippet != r.get('title',''):
            print(f"     {snippet[:120]}")
        url = r.get('url','')
        if url: print(f"     {url[:80]}")
        print()
except Exception as e:
    print(f"Parse error: {e}")
PYEOF

  echo ""
  # Use AI to summarize if model available
  if [[ -n "$ACTIVE_MODEL" || -n "${OPENAI_API_KEY:-}" || -n "${ANTHROPIC_API_KEY:-}" || -n "${GEMINI_API_KEY:-}" ]]; then
    local context
    context=$(echo "$results_json" | python3 -c "
import json,sys
results=json.load(sys.stdin)
lines=[]
for r in results:
    lines.append(f\"Title: {r.get('title','')}\nSnippet: {r.get('snippet','')}\nURL: {r.get('url','')}\")
print('\n'.join(lines))")
    hdr "AI Summary"
    dispatch_ask "Based on these search results, answer: $query

$context

Be factual, cite the sources." 2>/dev/null
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  MODEL LOADING PERSISTENCE (save/restore between install/update)
# ════════════════════════════════════════════════════════════════════════════════
