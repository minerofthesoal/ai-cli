#!/usr/bin/env bash
# AI CLI v3.1.0 — Utilities module
# Shell, git, write, learn, quiz, interview, text, json, sql, regex, docker, cron, math, net, date, diff, find

cmd_shell() {
  case "${1:-}" in
    gen) shift; local r; r=$(_silent_generate "Generate one bash command for: $*. Return ONLY the command."); echo "  $r"; read -rp "Run? [y/N] " c; [[ "$c" == "y" ]] && eval "$r" ;;
    explain) shift; dispatch_ask "Explain this command: $*" ;;
    fix) shift; local r; r=$(_silent_generate "Fix this command: $*. Return ONLY the fixed command."); echo "  Fixed: $r" ;;
    *) echo "Usage: ai shell <gen|explain|fix> \"command\"" ;;
  esac
}

cmd_git_ai() {
  case "${1:-}" in
    commit) shift; local d; d=$(git diff --cached --stat 2>/dev/null); [[ -z "$d" ]] && { info "No staged changes"; return; }; local msg; msg=$(_silent_generate "Write a conventional commit message for:\n$(git diff --cached 2>/dev/null | head -100)"); echo "$msg"; read -rp "Use? [Y/n/e] " c; case "$c" in n) ;; e) local t=$(mktemp); echo "$msg" > "$t"; ${EDITOR:-nano} "$t"; git commit -F "$t"; rm "$t" ;; *) git commit -m "$msg" ;; esac ;;
    pr) local l; l=$(git log --oneline HEAD~10..HEAD 2>/dev/null); _silent_generate "Write PR description for:\n$l" ;;
    blame) local f="${2:?file}" n="${3:?line}"; git blame -L "$n,$n" "$f" 2>/dev/null ;;
    summary) local r="${2:-HEAD~5..HEAD}"; _silent_generate "Summarize:\n$(git log --oneline "$r" 2>/dev/null)" ;;
    *) echo "Usage: ai git <commit|pr|blame|summary>" ;;
  esac
}

cmd_write() {
  local mode="${1:-}"; shift 2>/dev/null || true; local topic="${*:-}"
  case "$mode" in
    blog) _silent_generate "Write a blog post about: ${topic:?topic required}. ~800 words with headers." ;;
    email) _silent_generate "Draft professional email about: ${topic:?}" ;;
    readme) _silent_generate "Generate README.md for project with files: $(ls -1 "${topic:-.}" 2>/dev/null | head -20)" ;;
    docs) [[ -f "${topic:?file}" ]] && _silent_generate "Document this code:\n$(cat "$topic" | head -200)" || err "File not found" ;;
    story) _silent_generate "Write a short story about: ${topic:-a mysterious adventure}. ~500 words." ;;
    poem) _silent_generate "Write a poem about: ${topic:-technology and nature}" ;;
    *) echo "Usage: ai write <blog|email|readme|docs|story|poem> [topic]" ;;
  esac
}

cmd_learn() {
  local topic="${*:?Usage: ai learn \"topic\"}"; hdr "Learn: $topic"
  info "Commands: n=next q=quiz e=example x=explain quit=exit"
  local step=0
  _silent_generate "Give a 3-sentence overview of $topic"
  while true; do
    read -rp "$(echo -e "${BCYAN}[learn]${R}> ")" c
    case "$c" in
      n) (( step++ )); _silent_generate "Teach step $step of $topic. Be concise." ;;
      q) _silent_generate "One quiz question about $topic step $step" ;;
      e) _silent_generate "Practical example for $topic step $step" ;;
      x) read -rp "What? " w; _silent_generate "Explain $w in context of $topic" ;;
      quit|exit) ok "Done ($step steps)"; break ;;
      *) echo "  n q e x quit" ;;
    esac
  done
}

cmd_quiz() {
  local topic="${1:?Usage: ai quiz \"topic\"}" count="${2:-5}"
  _silent_generate "Generate $count multiple choice quiz questions about $topic with answers"
}

cmd_interview() {
  local role="${*:?Usage: ai interview \"role\"}"; hdr "Interview: $role"
  local qn=0
  while true; do
    (( qn++ )); local q; q=$(_silent_generate "Ask interview question #$qn for $role")
    echo "$q"; read -rp "Answer (or quit): " a; [[ "$a" == "quit" ]] && break
    _silent_generate "Rate this answer 1-10 with feedback:\nQ: $q\nA: $a"
  done
}

cmd_text() {
  local sub="${1:-}"; shift 2>/dev/null || true; local input="${*:-}"; [[ -z "$input" && ! -t 0 ]] && input=$(cat)
  case "$sub" in
    upper) echo "$input" | tr '[:lower:]' '[:upper:]' ;;
    lower) echo "$input" | tr '[:upper:]' '[:lower:]' ;;
    reverse) echo "$input" | rev ;;
    count) echo "  Chars: ${#input} | Words: $(echo "$input" | wc -w) | Lines: $(echo "$input" | wc -l)" ;;
    slug) echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' ;;
    uuid) python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null ;;
    password) python3 -c "import secrets;print(secrets.token_urlsafe(${input:-16}))" 2>/dev/null ;;
    hash) echo "  MD5:    $(echo -n "$input" | md5sum 2>/dev/null | awk '{print $1}')"; echo "  SHA256: $(echo -n "$input" | sha256sum 2>/dev/null | awk '{print $1}')" ;;
    b64) echo "$input" | base64 ;;
    b64d) echo "$input" | base64 -d 2>/dev/null ;;
    *) echo "Usage: ai text <upper|lower|reverse|count|slug|uuid|password|hash|b64|b64d>" ;;
  esac
}

cmd_json() {
  case "${1:-}" in
    format|fmt) python3 -m json.tool "${2:--}" 2>/dev/null || err "Invalid JSON" ;;
    validate) python3 -c "import json,sys;json.load(open('${2:--}') if '${2:--}'!='-' else sys.stdin);print('Valid')" 2>/dev/null || err "Invalid" ;;
    generate) shift; _silent_generate "Generate JSON for: $*. Return ONLY valid JSON." ;;
    *) echo "Usage: ai json <format|validate|generate>" ;;
  esac
}

cmd_sql() {
  case "${1:-}" in
    gen) shift; _silent_generate "Generate SQL for: $*. Return ONLY the query." ;;
    explain) shift; _silent_generate "Explain this SQL:\n$*" ;;
    optimize) shift; _silent_generate "Optimize this SQL:\n$*" ;;
    *) echo "Usage: ai sql <gen|explain|optimize>" ;;
  esac
}

cmd_regex() {
  case "${1:-}" in
    build) shift; _silent_generate "Create regex for: $*. Return pattern first, then explain." ;;
    explain) shift; _silent_generate "Explain regex: $*" ;;
    test) echo "$3" | grep -qP "$2" 2>/dev/null && echo "${GREEN}MATCH${R}" || echo "${RED}NO MATCH${R}" ;;
    *) echo "Usage: ai regex <build|explain|test>" ;;
  esac
}

cmd_docker() {
  case "${1:-}" in
    gen) shift; _silent_generate "Generate Dockerfile for: $*" ;;
    compose) shift; _silent_generate "Generate docker-compose.yml for: $*" ;;
    explain) [[ -f "${2:-Dockerfile}" ]] && _silent_generate "Explain:\n$(cat "${2:-Dockerfile}")" || err "File not found" ;;
    *) echo "Usage: ai docker <gen|compose|explain>" ;;
  esac
}

cmd_cron() {
  case "${1:-}" in
    build) shift; _silent_generate "Cron expression for: $*. Return cron on line 1." ;;
    explain) shift; _silent_generate "Explain cron: $*" ;;
    *) echo "Usage: ai cron <build|explain>" ;;
  esac
}

cmd_math() { local e="${*:?expression}"; echo "$e" | bc -l 2>/dev/null || _silent_generate "Solve step by step: $e"; }

cmd_net() {
  case "${1:-}" in
    ip) printf "  Local:  %s\n  Public: %s\n" "$(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')" "$(curl -fsSL ifconfig.me 2>/dev/null || echo '?')" ;;
    dns) local d="${2:?domain}"; dig +short "$d" 2>/dev/null || nslookup "$d" 2>/dev/null || host "$d" 2>/dev/null ;;
    ping) ping -c 3 "${2:-8.8.8.8}" 2>/dev/null ;;
    speed) info "Testing..."; local s=$(date +%s%N); curl -fsSL "https://speed.cloudflare.com/__down?bytes=5000000" -o /dev/null 2>/dev/null; local e=$(date +%s%N); local ms=$(((e-s)/1000000)); (( ms>0 )) && printf "  ~%.1f Mbps\n" "$(awk "BEGIN{print 5*8/($ms/1000.0)}")" ;;
    port) timeout 3 bash -c "echo >/dev/tcp/${2:?host}/${3:?port}" 2>/dev/null && echo "OPEN" || echo "CLOSED" ;;
    *) echo "Usage: ai net <ip|dns|ping|speed|port>" ;;
  esac
}

cmd_date_tools() {
  case "${1:-}" in
    now) date -Iseconds ;; epoch) date +%s ;;
    from-epoch) date -d "@${2:?ts}" -Iseconds 2>/dev/null || date -r "${2}" -Iseconds 2>/dev/null ;;
    diff) local e1=$(date -d "$2" +%s 2>/dev/null || echo 0) e2=$(date -d "${3:-now}" +%s 2>/dev/null || date +%s); echo "  $(( (e2-e1)/86400 )) days" ;;
    *) echo "Usage: ai date <now|epoch|from-epoch|diff>" ;;
  esac
}

cmd_diff() {
  local f1="${1:?file1}" f2="${2:?file2}"; diff --color=auto -u "$f1" "$f2" 2>/dev/null || true
  [[ "${3:-}" == "--explain" ]] && _silent_generate "Explain this diff:\n$(diff -u "$f1" "$f2" 2>/dev/null)"
}

cmd_find_ai() {
  local q="${1:?query}" d="${2:-.}"
  hdr "Search: $q"
  grep -rli "$q" "$d" --include="*.{txt,md,py,js,sh,ts,go,rs,c,cpp,java}" 2>/dev/null | head -15 | while read -r f; do
    printf "  %s\n" "$f"
  done
}

cmd_changelog_gen() {
  git rev-parse --is-inside-work-tree &>/dev/null || { err "Not a git repo"; return 1; }
  _silent_generate "Generate changelog from:\n$(git log --oneline "${1:-HEAD~10}"..HEAD 2>/dev/null)"
}

cmd_translate_v2() {
  local target="English"; local text=""
  while [[ $# -gt 0 ]]; do case "$1" in --to) target="$2"; shift 2 ;; *) text+="$1 "; shift ;; esac; done
  _silent_generate "Translate to $target: ${text% }"
}

cmd_define() { _silent_generate "Define '$*' with: definition, etymology, example, synonyms"; }

cmd_convert_units() { _silent_generate "Convert $1 $2 to ${4:-$3}. Show calculation."; }

cmd_watch() {
  local file="${1:?file}" action="${2:-summarize}" interval="${3:-2}"
  info "Watching: $file (${action}, ${interval}s) — Ctrl+C to stop"
  local last=""
  while true; do
    local h; h=$(md5sum "$file" 2>/dev/null | awk '{print $1}')
    [[ "$h" != "$last" && -n "$h" ]] && { last="$h"; info "Changed — processing..."; dispatch_ask "$action: $(cat "$file" | head -200)" 2>/dev/null; }
    sleep "$interval"
  done
}

cmd_clipboard() {
  case "${1:-get}" in
    get) xclip -selection clipboard -o 2>/dev/null || xsel --clipboard -o 2>/dev/null || wl-paste 2>/dev/null || pbpaste 2>/dev/null ;;
    set) shift; echo "$*" | xclip -selection clipboard 2>/dev/null || echo "$*" | pbcopy 2>/dev/null; ok "Copied" ;;
    ask) local c; c=$(cmd_clipboard get); [[ -n "$c" ]] && dispatch_ask "${2:-Summarize}: $c" || err "Clipboard empty" ;;
    *) echo "Usage: ai clip <get|set|ask>" ;;
  esac
}
