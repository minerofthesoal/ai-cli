# ============================================================================
# MODULE: 26-datasets.sh
# Custom dataset creation from text/URL/file/paper
# Source lines 8841-9358 of main-v2.7.3
# ============================================================================

#  CUSTOM DATASET CREATION  (v2.4)
#  ai dataset create <name>               — Create a new dataset
#  ai dataset add <name> <prompt> <resp>  — Add a prompt/response pair
#  ai dataset add-file <name> <jsonl>     — Import from JSONL file
#  ai dataset import-csv <name> <csv>     — Import from CSV (prompt,response)
#  ai dataset list                        — List all datasets
#  ai dataset show <name> [N]             — Show last N entries
#  ai dataset delete <name>              — Delete dataset
#  ai dataset export <name> [path]        — Export to JSONL file
#  ai dataset push <name> <hf-repo>       — Push to HuggingFace
#  ai dataset from-chat [session]         — Convert chat session to dataset
#  ai dataset from-rlhf                   — Convert RLHF ratings to dataset
# ════════════════════════════════════════════════════════════════════════════════
cmd_dataset() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    create)
      local name="${1:?Usage: ai dataset create <name>}"
      local ds_dir="$DATASETS_DIR/$name"
      if [[ -d "$ds_dir" ]]; then warn "Dataset '$name' already exists"; return 1; fi
      mkdir -p "$ds_dir"
      echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      touch "$ds_dir/data.jsonl"
      ok "Dataset '$name' created at $ds_dir"
      echo "  Add pairs:  ai dataset add $name \"<prompt>\" \"<response>\""
      echo "  Import:     ai dataset add-file $name <file.jsonl>"
      ;;
    add)
      local name="${1:?Usage: ai dataset add <name> <prompt> <response>}"
      local prompt="${2:?Provide a prompt}"; local response="${3:?Provide a response}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found. Create it first: ai dataset create $name"; return 1; }
      echo '{"prompt":'"$(echo "$prompt" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"',"response":'"$(echo "$response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"'}' >> "$ds_dir/data.jsonl"
      local cnt; cnt=$(wc -l < "$ds_dir/data.jsonl")
      # Update meta count
      python3 -c "
import json,sys
m=json.load(open('$ds_dir/meta.json'))
m['count']=$cnt; m['updated']='$(date -Iseconds)'
json.dump(m,open('$ds_dir/meta.json','w'))
" 2>/dev/null || true
      ok "Added pair #$cnt to '$name'"
      ;;
    add-file)
      local name="${1:?Usage: ai dataset add-file <name> <file.jsonl>}"
      local src="${2:?Provide source JSONL file}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found"; return 1; }
      [[ ! -f "$src" ]] && { err "File not found: $src"; return 1; }
      local before; before=$(wc -l < "$ds_dir/data.jsonl" 2>/dev/null || echo 0)
      cat "$src" >> "$ds_dir/data.jsonl"
      local after; after=$(wc -l < "$ds_dir/data.jsonl")
      local added=$(( after - before ))
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$after; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Imported $added entries from $src into '$name' (total: $after)"
      ;;
    import-csv)
      local name="${1:?Usage: ai dataset import-csv <name> <file.csv>}"
      local src="${2:?Provide source CSV file}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { mkdir -p "$ds_dir"; echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"; touch "$ds_dir/data.jsonl"; }
      [[ ! -f "$src" ]] && { err "File not found: $src"; return 1; }
      local added
      added=$(python3 - <<PYEOF
import csv, json, sys
count = 0
with open('$src', newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    with open('$ds_dir/data.jsonl', 'a', encoding='utf-8') as out:
        for row in reader:
            prompt = row.get('prompt', row.get('instruction', row.get('input', '')))
            response = row.get('response', row.get('output', row.get('answer', '')))
            if prompt and response:
                out.write(json.dumps({'prompt': prompt, 'response': response}) + '\n')
                count += 1
print(count)
PYEOF
)
      local total; total=$(wc -l < "$ds_dir/data.jsonl")
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Imported $added entries from CSV into '$name' (total: $total)"
      ;;
    list)
      hdr "Custom Datasets"
      local found=0
      for d in "$DATASETS_DIR"/*/; do
        [[ -f "$d/meta.json" ]] || continue
        found=1
        local meta; meta=$(cat "$d/meta.json")
        local n; n=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('name','?'))" 2>/dev/null || basename "$d")
        local cnt; cnt=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('count',0))" 2>/dev/null || wc -l < "$d/data.jsonl")
        local up; up=$(echo "$meta" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m.get('updated',m.get('created','?'))[:10])" 2>/dev/null || echo "?")
        printf "  %-20s  %5s pairs  updated %s\n" "$n" "$cnt" "$up"
      done
      [[ $found -eq 0 ]] && info "No datasets yet. Create one: ai dataset create <name>"
      ;;
    show)
      local name="${1:?Usage: ai dataset show <name> [N]}"; local n="${2:-10}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      hdr "Dataset '$name' (last $n entries)"
      tail -n "$n" "$ds_dir/data.jsonl" | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        e=json.loads(line)
        print(f'\033[1mPrompt:\033[0m {e.get(\"prompt\",\"\")[:120]}')
        print(f'\033[2mResponse:\033[0m {e.get(\"response\",\"\")[:200]}')
        print()
    except: pass
"
      ;;
    delete)
      local name="${1:?Usage: ai dataset delete <name>}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { err "Dataset '$name' not found"; return 1; }
      read -rp "Delete dataset '$name'? [y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled"; return; }
      rm -rf "$ds_dir"; ok "Dataset '$name' deleted"
      ;;
    export)
      local name="${1:?Usage: ai dataset export <name> [output-path]}"
      local ds_dir="$DATASETS_DIR/$name"
      local out="${2:-$HOME/${name}.jsonl}"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      cp "$ds_dir/data.jsonl" "$out"
      ok "Exported '$name' to $out ($(wc -l < "$out") entries)"
      ;;
    push)
      local name="${1:?Usage: ai dataset push <name> <hf-repo>}"
      local repo="${2:?Provide HuggingFace repo (user/dataset-name)}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -f "$ds_dir/data.jsonl" ]] && { err "Dataset '$name' not found"; return 1; }
      [[ -z "${HF_TOKEN:-}" ]] && { err "HF_TOKEN not set. Run: ai keys set HF_TOKEN <token>"; return 1; }
      info "Pushing '$name' to HuggingFace hub: $repo"
      HF_TOKEN_VAL="$HF_TOKEN" DS_DIR="$ds_dir" DS_REPO="$repo" DS_NAME="$name" \
      "$PYTHON" - <<'PYEOF'
import os, json
from huggingface_hub import HfApi, create_repo
api = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo = os.environ['DS_REPO']
ds_dir = os.environ['DS_DIR']
name = os.environ['DS_NAME']
try:
    create_repo(repo, repo_type="dataset", exist_ok=True, token=os.environ['HF_TOKEN_VAL'])
except Exception as e:
    pass
api.upload_file(path_or_fileobj=f"{ds_dir}/data.jsonl",
                path_in_repo="data.jsonl",
                repo_id=repo, repo_type="dataset",
                token=os.environ['HF_TOKEN_VAL'])
print(f"Pushed to https://huggingface.co/datasets/{repo}")
PYEOF
      ;;
    from-chat)
      local session="${1:-$ACTIVE_SESSION}"
      local sess_file="$SESSIONS_DIR/${session}.json"
      [[ ! -f "$sess_file" ]] && { err "Session '$session' not found"; return 1; }
      local ds_name="chat_${session}_$(date +%Y%m%d)"
      local ds_dir="$DATASETS_DIR/$ds_name"
      mkdir -p "$ds_dir"
      echo '{"name":"'"$ds_name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      touch "$ds_dir/data.jsonl"
      local cnt
      cnt=$(python3 - <<PYEOF
import json, sys
with open('$sess_file') as f:
    data = json.load(f)
pairs = []
for i in range(len(data)):
    if data[i]['role'] == 'user' and i+1 < len(data) and data[i+1]['role'] == 'assistant':
        pairs.append({'prompt': data[i]['content'], 'response': data[i+1]['content']})
with open('$ds_dir/data.jsonl', 'w') as out:
    for p in pairs:
        out.write(json.dumps(p) + '\n')
print(len(pairs))
PYEOF
)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$cnt; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Created dataset '$ds_name' from session '$session' ($cnt pairs)"
      echo "  Fine-tune: ai ttm finetune $ds_name"
      ;;
    from-rlhf)
      local min_score="${1:-4}"
      local ds_name="rlhf_preferred_$(date +%Y%m%d)"
      local ds_dir="$DATASETS_DIR/$ds_name"
      mkdir -p "$ds_dir"; touch "$ds_dir/data.jsonl"
      echo '{"name":"'"$ds_name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      local cnt
      cnt=$(python3 - <<PYEOF
import json
count = 0
for f in ['$RLHF_RATINGS_FILE', '$RLHF_PAIRS_FILE']:
    try:
        with open(f) as inp:
            with open('$ds_dir/data.jsonl', 'a') as out:
                for line in inp:
                    try:
                        r = json.loads(line)
                        score = float(r.get('score', r.get('rating', 0)))
                        if score >= $min_score:
                            pair = {'prompt': r.get('prompt',''), 'response': r.get('response', r.get('chosen',''))}
                            if pair['prompt'] and pair['response']:
                                out.write(json.dumps(pair) + '\n')
                                count += 1
                    except: pass
    except: pass
print(count)
PYEOF
)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$cnt; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Created dataset '$ds_name' from RLHF ratings >= $min_score ($cnt pairs)"
      echo "  Fine-tune: ai ttm finetune $ds_name"
      ;;
    generate)
      # Use AI to generate synthetic training data
      local name="${1:?Usage: ai dataset generate <name> <topic> [N]}"
      local topic="${2:?Provide a topic}"
      local n="${3:-50}"
      local ds_dir="$DATASETS_DIR/$name"
      [[ ! -d "$ds_dir" ]] && { mkdir -p "$ds_dir"; echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"; touch "$ds_dir/data.jsonl"; }
      info "Generating $n synthetic pairs on topic: $topic"
      local generated=0
      for (( i=1; i<=n; i++ )); do
        local prompt_q="Generate a realistic question or instruction about: $topic. Output ONLY the question/instruction, nothing else."
        local q; q=$(dispatch_ask "$prompt_q" 2>/dev/null | head -3)
        [[ -z "$q" ]] && continue
        local a; a=$(dispatch_ask "$q" 2>/dev/null)
        [[ -z "$a" ]] && continue
        echo '{"prompt":'"$(echo "$q" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"',"response":'"$(echo "$a" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))")"'}' >> "$ds_dir/data.jsonl"
        generated=$(( generated + 1 ))
        printf "\r  Generated: %d/%d" "$generated" "$n"
      done
      echo ""
      local total; total=$(wc -l < "$ds_dir/data.jsonl")
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Generated $generated pairs → '$name' (total: $total)"
      ;;
    # v2.5: text/url/file/paper → dataset
    from-text)
      _dataset_from_text "$@"
      ;;
    from-url)
      _dataset_from_url "$@"
      ;;
    from-file)
      _dataset_from_file "$@"
      ;;
    # v2.5.5: AI-generated synthetic dataset on any topic
    generate|gen|ai-gen)
      local name="${1:?Usage: ai dataset generate <name> <topic> [--count N] [--style qa|chat|instruct] [--model <model>]}"
      shift
      local topic="" count=50 style="qa" gen_model=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --count|-n) count="${2:-50}"; shift 2 ;;
          --style|-s)  style="${2:-qa}"; shift 2 ;;
          --model|-m)  gen_model="${2:-}"; shift 2 ;;
          *) topic="${topic:+$topic }$1"; shift ;;
        esac
      done
      [[ -z "$topic" ]] && { read -rp "Topic for dataset: " topic; }
      [[ -z "$topic" ]] && { err "Topic required"; return 1; }

      local ds_dir="$DATASETS_DIR/$name"
      mkdir -p "$ds_dir"
      [[ ! -f "$ds_dir/meta.json" ]] && \
        echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
      [[ ! -f "$ds_dir/data.jsonl" ]] && touch "$ds_dir/data.jsonl"

      info "Generating $count synthetic '$style' pairs about: $topic"
      info "Model: ${gen_model:-active (${ACTIVE_MODEL:-API})}"

      # Override model temporarily if --model given
      local prev_model="$ACTIVE_MODEL" prev_backend="$ACTIVE_BACKEND"
      [[ -n "$gen_model" ]] && ACTIVE_MODEL="$gen_model" && ACTIVE_BACKEND=""

      local generated=0 batch=5
      while (( generated < count )); do
        local remaining=$(( count - generated ))
        local this_batch=$(( remaining < batch ? remaining : batch ))

        local style_instruction
        case "$style" in
          chat)    style_instruction="conversational multi-turn dialogue excerpts" ;;
          instruct) style_instruction="instruction-following pairs where a user gives a specific task and the assistant completes it" ;;
          *)       style_instruction="diverse question-and-answer pairs" ;;
        esac

        local gen_prompt="Generate exactly ${this_batch} unique ${style_instruction} about the topic: '${topic}'.
Return ONLY a JSON array, no other text. Each element must have keys 'prompt' and 'response'.
Make each pair distinct, informative, and varying in complexity.
Example: [{\"prompt\":\"...\",\"response\":\"...\"}]"

        local raw_response
        raw_response=$(dispatch_ask "$gen_prompt" 2>/dev/null)

        if [[ -z "$raw_response" ]]; then
          warn "No response from AI — check model/API key setup"; break
        fi

        # Extract JSON array from response
        local added=0
        added=$("$PYTHON" - "$ds_dir/data.jsonl" <<PYEOF
import sys, json, re

raw = """${raw_response}"""
out_file = sys.argv[1]
count = 0

# Find JSON array in response
match = re.search(r'\[[\s\S]*\]', raw)
if not match:
    sys.exit(0)
try:
    pairs = json.loads(match.group(0))
    if not isinstance(pairs, list):
        sys.exit(0)
    with open(out_file, 'a', encoding='utf-8') as f:
        for p in pairs:
            if isinstance(p, dict) and ('prompt' in p or 'question' in p) and ('response' in p or 'answer' in p):
                prompt = p.get('prompt', p.get('question', ''))
                response = p.get('response', p.get('answer', ''))
                if prompt and response:
                    f.write(json.dumps({'prompt': prompt, 'response': response}) + '\n')
                    count += 1
except Exception:
    pass
print(count)
PYEOF
)
        generated=$(( generated + ${added:-0} ))
        printf "  Generated %d/%d pairs...\r" "$generated" "$count"
      done
      echo ""

      # Restore model
      ACTIVE_MODEL="$prev_model"; ACTIVE_BACKEND="$prev_backend"

      local total; total=$(wc -l < "$ds_dir/data.jsonl" 2>/dev/null || echo 0)
      python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$total; m['topic']='$topic'; m['style']='$style'; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
      ok "Dataset '$name' — $total pairs generated about: $topic"
      info "Fine-tune: ai finetune any <model> $name"
      info "   or:     ai ttm finetune $name"
      ;;

    from-paper)
      _dataset_from_paper "$@"
      ;;
    *)
      hdr "Dataset Commands (v2.4+2.5)"
      echo "  ai dataset create <name>               — Create new dataset"
      echo "  ai dataset add <name> <prompt> <resp>  — Add a prompt/response pair"
      echo "  ai dataset add-file <name> <file.jsonl> — Import from JSONL"
      echo "  ai dataset import-csv <name> <file.csv> — Import from CSV"
      echo "  ai dataset list                        — List all datasets"
      echo "  ai dataset show <name> [N]             — Show last N entries"
      echo "  ai dataset delete <name>               — Delete dataset"
      echo "  ai dataset export <name> [path]        — Export to JSONL"
      echo "  ai dataset push <name> <hf-repo>       — Upload to HuggingFace"
      echo "  ai dataset from-chat [session]         — Convert chat to dataset"
      echo "  ai dataset from-rlhf [min-score]       — Convert RLHF ratings"
      echo "  ai dataset generate <name> <topic> [N] — AI-generated synthetic data"
      echo ""
      echo "  v2.5 additions:"
      echo "  ai dataset from-text <name> <text>     — Text blob → Q&A dataset"
      echo "  ai dataset from-paper <name> <arxiv-id>— arXiv paper → dataset"
      echo "  ai dataset from-url <name> <url>       — Webpage text → dataset"
      echo "  ai dataset from-file <name> <file>     — Any text file → dataset"
      echo ""
      echo "  Dataset path: $DATASETS_DIR/"
      echo ""
      echo "  Then fine-tune:  ai ttm finetune <name>"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: Dataset creation helpers — from-text, from-paper, from-url, from-file
# ════════════════════════════════════════════════════════════════════════════════
_dataset_from_text_python() {
  local name="$1" text="$2" ds_dir="$3"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  "$PYTHON" - "$name" "$text" "$ds_dir" <<'PYEOF'
import sys, os, json, re

name, text, ds_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(ds_dir, exist_ok=True)
data_file = os.path.join(ds_dir, 'data.jsonl')

# Split text into sentences / paragraphs
sentences = [s.strip() for s in re.split(r'(?<=[.!?])\s+', text) if len(s.strip()) > 20]
paragraphs = [p.strip() for p in text.split('\n\n') if len(p.strip()) > 30]

pairs = []
# Sentence-based Q&A
for i in range(0, len(sentences)-1, 2):
    q = f"Explain: {sentences[i][:200]}"
    a = sentences[i+1][:500] if i+1 < len(sentences) else sentences[i]
    pairs.append({'prompt': q, 'response': a})

# Paragraph-based summary
for para in paragraphs:
    pairs.append({'prompt': f"Summarize: {para[:300]}", 'response': para[:500]})
    pairs.append({'prompt': f"What does this mean: {para[:200]}", 'response': para[:500]})

with open(data_file, 'a') as f:
    for p in pairs:
        f.write(json.dumps(p) + '\n')

meta_file = os.path.join(ds_dir, 'meta.json')
if os.path.exists(meta_file):
    m = json.load(open(meta_file))
else:
    m = {'name': name, 'created': __import__('datetime').datetime.now().isoformat(), 'count': 0}
m['count'] = sum(1 for _ in open(data_file))
m['updated'] = __import__('datetime').datetime.now().isoformat()
json.dump(m, open(meta_file, 'w'), indent=2)
print(f"Generated {len(pairs)} pairs from text → {data_file}")
PYEOF
}

# Patch cmd_dataset to handle from-text, from-paper, from-url, from-file
_dataset_from_text() {
  local name="${1:?Usage: ai dataset from-text <name> <text>}"
  local text="${2:?Provide text content}"
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_url() {
  local name="${1:?Usage: ai dataset from-url <name> <url>}"
  local url="${2:?Provide URL}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Fetching: $url"
  local text
  text=$("$PYTHON" -c "
import urllib.request, html.parser, re, sys
url = '$url'
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.text = []; self.skip = False
    def handle_starttag(self,t,a):
        if t in ('script','style','nav','footer'): self.skip = True
    def handle_endtag(self,t):
        if t in ('script','style','nav','footer'): self.skip = False
    def handle_data(self,d):
        if not self.skip and d.strip(): self.text.append(d.strip())
try:
    req = urllib.request.Request(url, headers={'User-Agent':'AI-CLI/2.5'})
    with urllib.request.urlopen(req, timeout=15) as r:
        html_content = r.read().decode('utf-8','replace')
    p = P(); p.feed(html_content)
    print(' '.join(p.text)[:10000])
except Exception as e:
    print('ERROR:'+str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { err "Failed to fetch: $url"; return 1; }
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_file() {
  local name="${1:?Usage: ai dataset from-file <name> <file>}"
  local file="${2:?Provide file path}"
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Reading: $file"
  local text; text=$(< "$file")
  _dataset_from_text_python "$name" "$text" "$ds_dir"
}

_dataset_from_paper() {
  local name="${1:?Usage: ai dataset from-paper <name> <arxiv-id>}"
  local paper_id="${2:?Provide arXiv ID (e.g. 2301.12345)}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local ds_dir="$DATASETS_DIR/$name"
  mkdir -p "$ds_dir"
  [[ ! -f "$ds_dir/meta.json" ]] && echo '{"name":"'"$name"'","created":"'"$(date -Iseconds)"'","count":0}' > "$ds_dir/meta.json"
  touch "$ds_dir/data.jsonl"
  info "Fetching arXiv paper: $paper_id"
  local abstract
  abstract=$("$PYTHON" -c "
import urllib.request, xml.etree.ElementTree as ET, sys
arxiv_id = '$paper_id'
url = f'https://export.arxiv.org/api/query?id_list={arxiv_id}'
req = urllib.request.Request(url, headers={'User-Agent':'AI-CLI/2.5'})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read()
    ns = {'a': 'http://www.w3.org/2005/Atom'}
    root = ET.fromstring(data)
    entry = root.find('a:entry', ns)
    if entry is None: print(''); sys.exit(0)
    title = (entry.find('a:title', ns).text or '').strip()
    abstract = (entry.find('a:summary', ns).text or '').strip()
    authors = [a.find('a:name', ns).text for a in entry.findall('a:author', ns)[:5]]
    print(f'Title: {title}\nAuthors: {\", \".join(authors)}\n\nAbstract: {abstract}')
except Exception as e:
    print('ERROR:'+str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || { err "Failed to fetch paper: $paper_id"; return 1; }
  [[ -z "$abstract" ]] && { err "Paper not found: $paper_id"; return 1; }
  _dataset_from_text_python "$name" "$abstract" "$ds_dir"
  ok "Dataset from arXiv $paper_id created"
}

# ════════════════════════════════════════════════════════════════════════════════
#  UNIVERSAL LLM API SERVER  (v2.4)
