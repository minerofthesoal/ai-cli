# ============================================================================
# MODULE: 06-trained-models.sh
# Generalized trained-model engine (TTM / MTM / Mtm)
# Source lines 601-1120 of main-v2.7.3
# ============================================================================

#  Handles TTM (tiny/179M), MTM (mini/0.61B), Mtm (medium/1.075B)
# ════════════════════════════════════════════════════════════════════════════════

# _tm_vars MODEL_ID  →  sets TM_DIR TM_HF_REPO TM_CONFIG_JSON TM_LABEL
#                        TM_AUTO_TRAIN_VAR TM_VERSION_VAR TM_PRETRAINED_VAR
_tm_vars() {
  local id="$1"
  case "$id" in
    TTM|ttm)
      TM_DIR="$TTM_DIR"
      TM_HF_REPO="ray0rf1re/tiny"
      TM_CONFIG_JSON="$TTM_CONFIG_JSON"
      TM_LABEL="TTM (Tiny ~179M)"
      TM_AUTO_TRAIN_VAR="TTM_AUTO_TRAIN"
      TM_VERSION_VAR="TTM_VERSION"
      TM_PRETRAINED_VAR="TTM_PRETRAINED"
      TM_DTYPE="bfloat16"
      TM_GPU_OPT="any"
      ;;
    MTM|mtm)
      TM_DIR="$MTM_DIR"
      TM_HF_REPO="ray0rf1re/mini"
      TM_CONFIG_JSON="$MTM_CONFIG_JSON"
      TM_LABEL="MTM (Mini ~0.61B, GTX 1080)"
      TM_AUTO_TRAIN_VAR="MTM_AUTO_TRAIN"
      TM_VERSION_VAR="MTM_VERSION"
      TM_PRETRAINED_VAR="MTM_PRETRAINED"
      TM_DTYPE="float16"
      TM_GPU_OPT="GTX 1080 / Pascal+"
      ;;
    Mtm|mmtm|MMTM)
      TM_DIR="$MMTM_DIR"
      TM_HF_REPO="ray0rf1re/medium"
      TM_CONFIG_JSON="$MMTM_CONFIG_JSON"
      TM_LABEL="Mtm (Medium ~1.075B, RTX 2080+)"
      TM_AUTO_TRAIN_VAR="MMTM_AUTO_TRAIN"
      TM_VERSION_VAR="MMTM_VERSION"
      TM_PRETRAINED_VAR="MMTM_PRETRAINED"
      TM_DTYPE="bfloat16"
      TM_GPU_OPT="RTX 2080+ / Turing+"
      ;;
    *) err "Unknown model ID: $id (use TTM, MTM, or Mtm)"; return 1 ;;
  esac
}

_tm_get_var()  { eval "echo \"\${${1}:-0}\""; }
_tm_set_var()  { eval "${1}=\"${2}\""; }

_tm_init() {
  local id="$1"; _tm_vars "$id"
  mkdir -p "$TM_DIR"
  local cfg="$TM_DIR/config.json"
  if [[ ! -f "$cfg" ]]; then
    echo "$TM_CONFIG_JSON" > "$cfg"
    ok "$TM_LABEL config created: $cfg"
  fi
}

_tm_create_repo() {
  local id="$1"; _tm_vars "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }
  info "Creating HuggingFace repo: $TM_HF_REPO ..."
  HF_TOKEN_VAL="$hf_key" REPO_ID="$TM_HF_REPO" MODEL_LABEL="$TM_LABEL" \
  MODEL_CFG="$TM_CONFIG_JSON" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed. Run: ai install-deps"); sys.exit(1)
api = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo = os.environ['REPO_ID']
label = os.environ['MODEL_LABEL']
cfg   = os.environ['MODEL_CFG']
try:
    api.create_repo(repo_id=repo, exist_ok=True, private=False, repo_type='model')
    readme = f"# {label}\n\nAuto-trained model by AI CLI v2.3.\n\n```json\n{cfg}\n```\n"
    api.upload_file(
        path_or_fileobj=readme.encode(),
        path_in_repo="README.md",
        repo_id=repo,
        commit_message="init: create repo",
    )
    print(f"Created: https://huggingface.co/{repo}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

_tm_pretrain() {
  local id="$1"; shift
  local custom1="${1:-$PRETRAIN_CUSTOM_1}"; local custom2="${2:-$PRETRAIN_CUSTOM_2}"
  _tm_vars "$id"; _tm_init "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  info "$TM_LABEL — Starting pretraining"
  info "Using 6 standard datasets + ${custom1:+custom1: $custom1 }${custom2:+custom2: $custom2}"
  echo ""

  TM_DIR_VAL="$TM_DIR" TM_DTYPE_VAL="$TM_DTYPE" \
  CUSTOM1="${custom1:-}" CUSTOM2="${custom2:-}" \
  "$PYTHON" - <<'PYEOF'
import os, json, sys
TM_DIR   = os.environ['TM_DIR_VAL']
TM_DTYPE = os.environ.get('TM_DTYPE_VAL','float32')
CUSTOM1  = os.environ.get('CUSTOM1','')
CUSTOM2  = os.environ.get('CUSTOM2','')

try:
    import torch
    from transformers import (AutoTokenizer, LlamaConfig, LlamaForCausalLM,
                               TrainingArguments, Trainer, DataCollatorForLanguageModeling)
    from datasets import load_dataset, Dataset
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)

cfg_path = f"{TM_DIR}/config.json"
out_dir  = f"{TM_DIR}/pretrained"
os.makedirs(out_dir, exist_ok=True)

with open(cfg_path) as f:
    raw = json.load(f)
cfg = LlamaConfig(**{k:v for k,v in raw.items() if not k.startswith('_') and k!='architectures'})
model = LlamaForCausalLM(cfg)
total = sum(p.numel() for p in model.parameters())
print(f"Parameters: {total:,} ({total/1e6:.2f}M)")

tokenizer = AutoTokenizer.from_pretrained("TinyLlama/TinyLlama-1.1B-Chat-v1.0")
tokenizer.pad_token = tokenizer.eos_token
MAX_LEN = min(cfg.max_position_embeddings, 256)

records = []

# ── Dataset 1: TinyStories ────────────────────────────────────────────────────
print("Dataset 1/8: roneneldan/TinyStories")
try:
    ds = load_dataset("roneneldan/TinyStories", split="train[:6000]")
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 2: CodeAlpaca ─────────────────────────────────────────────────────
print("Dataset 2/8: sahil2801/CodeAlpaca-20k")
try:
    ds = load_dataset("sahil2801/CodeAlpaca-20k", split="train[:4000]")
    for ex in ds:
        t = (ex.get('instruction','') + '\n' + ex.get('output',''))[:MAX_LEN*4]
        records.append(t)
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 3: OpenOrca ───────────────────────────────────────────────────────
print("Dataset 3/8: Open-Orca/OpenOrca")
try:
    ds = load_dataset("Open-Orca/OpenOrca", split="train[:3000]")
    for ex in ds:
        t = (ex.get('system_prompt','') + ' ' + ex.get('question','') + '\n' + ex.get('response',''))[:MAX_LEN*4]
        records.append(t)
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 4: The Stack Smol ─────────────────────────────────────────────────
print("Dataset 4/8: bigcode/the-stack-smol")
try:
    ds = load_dataset("bigcode/the-stack-smol", data_dir="data/python", split="train[:3000]")
    for ex in ds: records.append(ex.get('content','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 5: FineWeb-Edu ────────────────────────────────────────────────────
print("Dataset 5/8: HuggingFaceFW/fineweb-edu")
try:
    ds = load_dataset("HuggingFaceFW/fineweb-edu", name="sample-10BT", split="train[:4000]",
                      streaming=False)
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Dataset 6: Wikipedia ──────────────────────────────────────────────────────
print("Dataset 6/8: wikimedia/wikipedia (en)")
try:
    ds = load_dataset("wikimedia/wikipedia", "20231101.en", split="train[:4000]")
    for ex in ds: records.append(ex.get('text','')[:MAX_LEN*4])
    print(f"  +{len(ds)} records (total {len(records)})")
except Exception as e: print(f"  skipped: {e}")

# ── Custom dataset 1 ──────────────────────────────────────────────────────────
if CUSTOM1:
    print(f"Dataset 7/8: {CUSTOM1} (custom)")
    try:
        if CUSTOM1.startswith('/') or CUSTOM1.endswith('.jsonl') or CUSTOM1.endswith('.txt'):
            with open(CUSTOM1) as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        obj = json.loads(line)
                        t = obj.get('text','') or obj.get('content','') or str(obj)
                    except:
                        t = line
                    records.append(t[:MAX_LEN*4])
        else:
            ds_id = CUSTOM1.replace('hf:','')
            ds = load_dataset(ds_id, split="train[:2000]")
            tcols = [c for c in ds.column_names if c in ['text','content','input','instruction']]
            col = tcols[0] if tcols else ds.column_names[0]
            for ex in ds: records.append(str(ex.get(col,''))[:MAX_LEN*4])
        print(f"  added custom1 (total {len(records)})")
    except Exception as e: print(f"  skipped: {e}")

# ── Custom dataset 2 ──────────────────────────────────────────────────────────
if CUSTOM2:
    print(f"Dataset 8/8: {CUSTOM2} (custom)")
    try:
        if CUSTOM2.startswith('/') or CUSTOM2.endswith('.jsonl') or CUSTOM2.endswith('.txt'):
            with open(CUSTOM2) as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        obj = json.loads(line)
                        t = obj.get('text','') or obj.get('content','') or str(obj)
                    except:
                        t = line
                    records.append(t[:MAX_LEN*4])
        else:
            ds_id = CUSTOM2.replace('hf:','')
            ds = load_dataset(ds_id, split="train[:2000]")
            tcols = [c for c in ds.column_names if c in ['text','content','input','instruction']]
            col = tcols[0] if tcols else ds.column_names[0]
            for ex in ds: records.append(str(ex.get(col,''))[:MAX_LEN*4])
        print(f"  added custom2 (total {len(records)})")
    except Exception as e: print(f"  skipped: {e}")

# ── Filter and tokenize ───────────────────────────────────────────────────────
records = [r for r in records if r and len(r.strip()) > 20]
print(f"\nTotal records: {len(records)}")
if not records:
    print("No data loaded"); sys.exit(1)

ds_all = Dataset.from_list([{'text': r} for r in records])
def tokenize(ex):
    return tokenizer(ex['text'], truncation=True, max_length=MAX_LEN, padding='max_length')
ds_all = ds_all.map(tokenize, batched=True, remove_columns=['text'])

device = 'cuda' if torch.cuda.is_available() else 'cpu'
dtype_map = {'float16': torch.float16, 'bfloat16': torch.bfloat16, 'float32': torch.float32}
torch_dtype = dtype_map.get(TM_DTYPE, torch.float32)
model = model.to(device)
if device == 'cuda':
    model = model.to(torch_dtype)

print(f"Training on: {device} | dtype: {TM_DTYPE} | records: {len(ds_all)}")

args = TrainingArguments(
    output_dir=out_dir,
    num_train_epochs=1.075,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,
    learning_rate=5e-4,
    lr_scheduler_type='cosine',
    warmup_ratio=0.05,
    fp16=(device=='cuda' and TM_DTYPE=='float16'),
    bf16=(device=='cuda' and TM_DTYPE=='bfloat16'),
    logging_steps=50,
    save_steps=500,
    save_total_limit=1,
    report_to='none',
    dataloader_num_workers=0,
)
trainer = Trainer(
    model=model,
    args=args,
    train_dataset=ds_all,
    data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"\nPretrained model saved: {out_dir}")
PYEOF

  if [[ -d "$TM_DIR/pretrained" ]]; then
    _tm_set_var "$TM_PRETRAINED_VAR" "1"
    save_config
    ok "$TM_LABEL pretraining complete"
  fi
}

_tm_train_batch() {
  local id="$1"; _tm_vars "$id"
  local auto_var; auto_var=$(_tm_get_var "$TM_AUTO_TRAIN_VAR")
  [[ "$auto_var" != "1" ]] && return 0
  [[ -z "$PYTHON" ]] && return 0

  # Build batch data from chat logs + history
  local batch_file; batch_file=$(mktemp /tmp/tm_batch_XXXX.jsonl)
  find "$CHAT_LOGS_DIR" -name "*.jsonl" -newer "$TM_DIR/.last_train" 2>/dev/null | head -5 | while read -r f; do
    cat "$f"
  done > "$batch_file" 2>/dev/null || true
  if [[ -f "$LOG_FILE" ]]; then
    tail -20 "$LOG_FILE" | while IFS= read -r line; do
      local msg; msg=$(echo "$line" | sed 's/^[0-9T:+-]* \[[a-z]*\] //')
      [[ -n "$msg" ]] && echo "{\"text\":\"$msg\"}" >> "$batch_file"
    done
  fi

  local count; count=$(wc -l < "$batch_file" 2>/dev/null || echo 0)
  if (( count < 3 )); then rm -f "$batch_file"; return 0; fi

  local base_model="$TM_DIR/pretrained"
  local latest_ft; latest_ft=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest_ft" ]] && base_model="$latest_ft"
  [[ ! -d "$base_model" ]] && { rm -f "$batch_file"; return 0; }

  local cur_ver; cur_ver=$(_tm_get_var "$TM_VERSION_VAR")
  local new_ver=$(( cur_ver + 1 ))
  local out_dir="$TM_DIR/ft_v${new_ver}"
  mkdir -p "$out_dir"

  BATCH_FILE="$batch_file" BASE_MODEL="$base_model" OUT_DIR="$out_dir" \
  TM_DTYPE_VAL="$TM_DTYPE" "$PYTHON" - <<'PYEOF' &>/dev/null &
import os, json, sys
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, \
        TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType
except ImportError: sys.exit(0)

batch_file = os.environ['BATCH_FILE']
base_model = os.environ['BASE_MODEL']
out_dir    = os.environ['OUT_DIR']
TM_DTYPE   = os.environ.get('TM_DTYPE_VAL','float32')

records = []
with open(batch_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            txt = obj.get('text','') or obj.get('output','') + ' ' + obj.get('instruction','')
            if txt.strip(): records.append({'text': txt[:256]})
        except: pass
if len(records) < 3: sys.exit(0)

tokenizer = AutoTokenizer.from_pretrained(base_model)
tokenizer.pad_token = tokenizer.eos_token
model = AutoModelForCausalLM.from_pretrained(base_model)
lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=4, lora_alpha=8,
                  lora_dropout=0.05, target_modules=["q_proj","v_proj"])
model = get_peft_model(model, lora)
ds = Dataset.from_list(records)
def tok(ex): return tokenizer(ex['text'], truncation=True, max_length=128, padding='max_length')
ds = ds.map(tok, batched=True, remove_columns=['text'])
device = 'cuda' if torch.cuda.is_available() else 'cpu'
model = model.to(device)
dtype_map = {'float16': torch.float16, 'bfloat16': torch.bfloat16}
if device == 'cuda' and TM_DTYPE in dtype_map:
    model = model.to(dtype_map[TM_DTYPE])
args = TrainingArguments(
    output_dir=out_dir, num_train_epochs=1, per_device_train_batch_size=1,
    gradient_accumulation_steps=1, max_steps=1, learning_rate=2e-4,
    fp16=(device=='cuda' and TM_DTYPE=='float16'),
    bf16=(device=='cuda' and TM_DTYPE=='bfloat16'),
    logging_steps=1, save_steps=1, report_to='none',
)
Trainer(model=model, args=args, train_dataset=ds,
        data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False)).train()
merged = model.merge_and_unload()
merged.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
PYEOF

  rm -f "$batch_file"
  touch "$TM_DIR/.last_train"
  _tm_set_var "$TM_VERSION_VAR" "$new_ver"
  save_config
}

_tm_upload() {
  local id="$1"; local version="${2:-latest}"; _tm_vars "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  local hf_key="${HF_TOKEN:-}"; [[ -z "$hf_key" ]] && { err "HF_TOKEN not set"; return 1; }

  local model_dir
  if [[ "$version" == "latest" ]]; then
    model_dir=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "$TM_DIR/pretrained")
  else
    model_dir="$TM_DIR/ft_v${version}"
  fi
  [[ ! -d "$model_dir" ]] && { err "No $id model at $model_dir. Run: ai $id pretrain"; return 1; }

  local folder_name; folder_name=$(basename "$model_dir")
  info "Uploading $id $folder_name → $TM_HF_REPO/$folder_name"

  HF_TOKEN_VAL="$hf_key" MODEL_DIR="$model_dir" FOLDER_NAME="$folder_name" \
  TM_HF_REPO="$TM_HF_REPO" "$PYTHON" - <<'PYEOF'
import os, sys
try:
    from huggingface_hub import HfApi
except ImportError:
    print("huggingface_hub not installed. Run: ai install-deps"); sys.exit(1)
api   = HfApi(token=os.environ['HF_TOKEN_VAL'])
repo  = os.environ['TM_HF_REPO']
mdir  = os.environ['MODEL_DIR']
fname = os.environ['FOLDER_NAME']
try:
    api.create_repo(repo_id=repo, exist_ok=True, private=False)
except: pass
api.upload_folder(
    folder_path=mdir, repo_id=repo, path_in_repo=fname,
    commit_message=f"auto-upload: {fname}",
)
print(f"Uploaded: https://huggingface.co/{repo}/tree/main/{fname}")
PYEOF
}

_tm_load() {
  local id="$1"; local version="${2:-latest}"; _tm_vars "$id"
  local mdir
  if [[ "$version" == "latest" ]]; then
    mdir=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "$TM_DIR/pretrained")
  else
    mdir="$TM_DIR/ft_v${version}"
  fi
  [[ ! -d "$mdir" ]] && { err "$id not trained yet. Run: ai $id pretrain"; return 1; }
  ACTIVE_MODEL="$mdir"; ACTIVE_BACKEND="pytorch"; save_config
  ok "Loaded $TM_LABEL from $mdir"
}

_tm_status() {
  local id="$1"; _tm_vars "$id"
  local auto_var;    auto_var=$(_tm_get_var "$TM_AUTO_TRAIN_VAR")
  local pretrain_var; pretrain_var=$(_tm_get_var "$TM_PRETRAINED_VAR")
  local ver_var;     ver_var=$(_tm_get_var "$TM_VERSION_VAR")

  hdr "$TM_LABEL Status"
  echo "  HF Repo:    $TM_HF_REPO"
  echo "  GPU target: $TM_GPU_OPT"
  echo "  Data type:  $TM_DTYPE"
  echo "  Config:     $TM_DIR/config.json"
  echo "  Auto-train: $auto_var"
  echo "  Pretrained: $pretrain_var"
  echo "  Version:    $ver_var"
  echo ""
  [[ -d "$TM_DIR/pretrained" ]] && ok "Pretrained model present" || warn "Not pretrained yet"
  local latest; latest=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest" ]] && ok "Latest finetune: $(basename "$latest")"
  [[ -n "$PRETRAIN_CUSTOM_1" ]] && echo "  Custom DS 1: $PRETRAIN_CUSTOM_1"
  [[ -n "$PRETRAIN_CUSTOM_2" ]] && echo "  Custom DS 2: $PRETRAIN_CUSTOM_2"
}

# ── Generic cmd dispatcher for TTM/MTM/Mtm ────────────────────────────────────
_tm_cmd() {
  local id="$1"; shift
  local sub="${1:-help}"; shift || true
  _tm_init "$id"
  case "$sub" in
    pretrain)
      local c1="${1:-$PRETRAIN_CUSTOM_1}"; local c2="${2:-$PRETRAIN_CUSTOM_2}"
      _tm_pretrain "$id" "$c1" "$c2"
      ;;
    status)    _tm_status "$id" ;;
    load)      _tm_load "$id" "${1:-latest}" ;;
    train-now) _tm_train_batch "$id" ;;
    upload)    _tm_upload "$id" "${1:-latest}" ;;
    create-repo) _tm_create_repo "$id" ;;
    enable)
      _tm_vars "$id"
      _tm_set_var "$TM_AUTO_TRAIN_VAR" "1"; save_config
      ok "$TM_LABEL auto-training enabled"
      ;;
    disable)
      _tm_vars "$id"
      _tm_set_var "$TM_AUTO_TRAIN_VAR" "0"; save_config
      ok "$TM_LABEL auto-training disabled"
      ;;
    set-custom1)
      PRETRAIN_CUSTOM_1="${1:-}"; save_config
      ok "Custom dataset 1: $PRETRAIN_CUSTOM_1"
      ;;
    set-custom2)
      PRETRAIN_CUSTOM_2="${1:-}"; save_config
      ok "Custom dataset 2: $PRETRAIN_CUSTOM_2"
      ;;
    finetune|fine-tune|ft)
      local dataset="${1:-}"; local epochs="${2:-3}"; local lr="${3:-2e-4}"
      _tm_finetune "$id" "$dataset" "$epochs" "$lr"
      ;;
    *)
      _tm_vars "$id"
      echo -e "${B}${BCYAN}$TM_LABEL${R}"
      echo "  GPU target: $TM_GPU_OPT | Dtype: $TM_DTYPE | Repo: $TM_HF_REPO"
      echo ""
      echo "  ${B}ai $id pretrain [custom1] [custom2]${R} — Pretrain (6 standard + 2 optional)"
      echo "  ${B}ai $id finetune <dataset> [epochs] [lr]${R} — Fine-tune on custom dataset (v2.4)"
      echo "  ${B}ai $id enable / disable${R}              — Toggle auto-training"
      echo "  ${B}ai $id train-now${R}                     — Force one batch"
      echo "  ${B}ai $id upload [version]${R}              — Upload to $TM_HF_REPO"
      echo "  ${B}ai $id create-repo${R}                   — Create HF repo"
      echo "  ${B}ai $id status${R}                        — Show status"
      echo "  ${B}ai $id load [version]${R}                — Set as active model"
      echo "  ${B}ai $id set-custom1 <hf-id-or-path>${R}   — Set custom dataset 1"
      echo "  ${B}ai $id set-custom2 <hf-id-or-path>${R}   — Set custom dataset 2"
      echo ""
      echo "  ${B}ai -TTM${R} / ${B}ai -MTM${R} / ${B}ai -Mtm${R}            — Load respective model"
      ;;
  esac
}

cmd_ttm() { _tm_cmd "TTM" "$@"; }
cmd_mtm() { _tm_cmd "MTM" "$@"; }
cmd_Mtm() { _tm_cmd "Mtm" "$@"; }

# ════════════════════════════════════════════════════════════════════════════════
#  TTM / MTM / Mtm FINE-TUNING  (v2.4)
