# ============================================================================
# MODULE: 07-rlhf.sh
# RLHF pipeline + HuggingFace preference datasets
# Source lines 1120-2235 of main-v2.7.3
# ============================================================================

#  TTM / MTM / Mtm FINE-TUNING  (v2.4)
#  Fine-tune any trained model on a custom dataset using LoRA/QLoRA
#  ai ttm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
#  ai mtm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
#  ai Mtm finetune <dataset-name-or-path> [epochs=3] [lr=2e-4]
# ════════════════════════════════════════════════════════════════════════════════
_tm_finetune() {
  local id="$1"; local dataset="${2:-}"; local epochs="${3:-3}"; local lr="${4:-2e-4}"
  _tm_vars "$id"; _tm_init "$id"
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Resolve dataset path
  local ds_path=""
  if [[ -z "$dataset" ]]; then
    err "Usage: ai $id finetune <dataset-name-or-path> [epochs] [lr]"
    echo "  Available datasets: $(ls "$DATASETS_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  if [[ -f "$DATASETS_DIR/$dataset/data.jsonl" ]]; then
    ds_path="$DATASETS_DIR/$dataset/data.jsonl"
  elif [[ -f "$dataset" ]]; then
    ds_path="$dataset"
  else
    err "Dataset '$dataset' not found"
    echo "  Create one: ai dataset create $dataset"
    echo "  Or provide a path to a JSONL file"
    return 1
  fi

  local n_pairs; n_pairs=$(wc -l < "$ds_path" 2>/dev/null || echo 0)
  if (( n_pairs < 10 )); then
    err "Dataset too small: $n_pairs pairs (need at least 10)"
    echo "  Add more pairs: ai dataset add $dataset \"<prompt>\" \"<response>\""
    return 1
  fi

  local base_model_dir="$TM_DIR/pretrained"
  if [[ ! -d "$base_model_dir" ]]; then
    warn "No pretrained model found at $base_model_dir"
    warn "Run 'ai $id pretrain' first, or fine-tuning from config..."
    base_model_dir="$TM_DIR"
  fi

  local ft_out="$TM_DIR/finetuned_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$ft_out"

  hdr "$TM_LABEL Fine-tuning"
  echo "  Dataset:  $ds_path ($n_pairs pairs)"
  echo "  Base:     $base_model_dir"
  echo "  Output:   $ft_out"
  echo "  Epochs:   $epochs | LR: $lr | Dtype: $TM_DTYPE"
  echo ""

  TM_DIR_VAL="$TM_DIR" TM_DTYPE_VAL="$TM_DTYPE" TM_LABEL_VAL="$TM_LABEL" \
  DS_PATH="$ds_path" EPOCHS="$epochs" LR="$lr" FT_OUT="$ft_out" \
  BASE_MODEL="$base_model_dir" \
  "$PYTHON" - <<'PYEOF'
import os, sys, json

TM_DIR   = os.environ['TM_DIR_VAL']
TM_DTYPE = os.environ.get('TM_DTYPE_VAL', 'float32')
TM_LABEL = os.environ.get('TM_LABEL_VAL', 'Model')
DS_PATH  = os.environ['DS_PATH']
EPOCHS   = int(os.environ.get('EPOCHS', '3'))
LR       = float(os.environ.get('LR', '2e-4'))
FT_OUT   = os.environ['FT_OUT']
BASE     = os.environ['BASE_MODEL']

try:
    import torch
    from transformers import (AutoTokenizer, AutoModelForCausalLM,
                               TrainingArguments, LlamaForCausalLM, LlamaConfig)
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
except ImportError as e:
    print(f"Missing: {e}\nRun: ai install-deps"); sys.exit(1)

# CPU-only mode: use float32 and minimal batch
device = "cpu"
dtype = torch.float32
if torch.cuda.is_available():
    device = "cuda"
    dtype = torch.float16 if TM_DTYPE == 'float16' else torch.bfloat16
    if TM_DTYPE == 'bfloat16' and not torch.cuda.is_bf16_supported():
        dtype = torch.float16
        print("  Note: BF16 not supported, falling back to FP16")

print(f"  Device: {device} | Dtype: {dtype}")

# Load tokenizer — try from base dir, fallback to TinyLlama tokenizer
try:
    tokenizer = AutoTokenizer.from_pretrained(BASE)
except Exception:
    tokenizer = AutoTokenizer.from_pretrained("TinyLlama/TinyLlama-1.1B-Chat-v1.0")
tokenizer.pad_token = tokenizer.eos_token

# Load model — try from pretrained dir, else from config
try:
    if TM_DTYPE == 'bfloat16' and device == 'cuda':
        model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=dtype).to(device)
    else:
        model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.float32).to(device)
    print(f"  Loaded pretrained model from {BASE}")
except Exception as e:
    print(f"  Loading from config (no pretrained weights): {e}")
    cfg_path = f"{TM_DIR}/config.json"
    with open(cfg_path) as f:
        raw = json.load(f)
    cfg = LlamaConfig(**{k: v for k, v in raw.items() if not k.startswith('_') and k != 'architectures'})
    model = LlamaForCausalLM(cfg).to(device)

total_params = sum(p.numel() for p in model.parameters())
print(f"  Parameters: {total_params:,} ({total_params/1e6:.2f}M)")

# Apply LoRA for efficient fine-tuning (CPU-friendly: small rank)
cpu_mode = (device == "cpu")
lora_r = 4 if cpu_mode else 8
lora_alpha = 8 if cpu_mode else 16

lora_cfg = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=lora_r,
    lora_alpha=lora_alpha,
    lora_dropout=0.05,
    bias="none",
    target_modules=["q_proj", "v_proj"]
)
model = get_peft_model(model, lora_cfg)
trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
print(f"  LoRA rank={lora_r} | Trainable params: {trainable:,} ({trainable/total_params*100:.2f}%)")

# Load dataset
records = []
with open(DS_PATH) as f:
    for line in f:
        try:
            r = json.loads(line)
            prompt = r.get('prompt', r.get('instruction', ''))
            response = r.get('response', r.get('output', r.get('answer', '')))
            if prompt and response:
                records.append({"text": f"User: {prompt}\nAssistant: {response}{tokenizer.eos_token}"})
        except: pass
print(f"  Dataset: {len(records)} training pairs")

if not records:
    print("ERROR: No valid pairs found in dataset"); sys.exit(1)

MAX_LEN = 256 if cpu_mode else 512

def tokenize(batch):
    out = tokenizer(batch['text'], truncation=True, padding='max_length',
                    max_length=MAX_LEN, return_tensors=None)
    out['labels'] = out['input_ids'].copy()
    return out

ds = Dataset.from_list(records).map(tokenize, batched=True, remove_columns=['text'])

# Training arguments — CPU-optimized when no GPU
batch_size = 1 if cpu_mode else 4
grad_accum = 8 if cpu_mode else 4

args = TrainingArguments(
    output_dir=FT_OUT,
    num_train_epochs=EPOCHS,
    per_device_train_batch_size=batch_size,
    gradient_accumulation_steps=grad_accum,
    learning_rate=LR,
    warmup_ratio=0.05,
    lr_scheduler_type="cosine",
    logging_steps=10,
    save_strategy="epoch",
    fp16=(dtype == torch.float16 and device == 'cuda'),
    bf16=(dtype == torch.bfloat16 and device == 'cuda'),
    dataloader_num_workers=0,
    no_cuda=(device == 'cpu'),
    report_to="none",
    save_total_limit=2,
    load_best_model_at_end=False,
    optim="adamw_torch",
)

from transformers import Trainer, DataCollatorForLanguageModeling
collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
trainer = Trainer(model=model, args=args, train_dataset=ds, data_collator=collator)

print(f"\n  Starting fine-tuning ({EPOCHS} epochs)...")
trainer.train()

# Save merged model
try:
    merged = model.merge_and_unload()
    merged.save_pretrained(FT_OUT)
    print(f"  Merged model saved: {FT_OUT}")
except Exception as e:
    # Save LoRA adapter only
    model.save_pretrained(FT_OUT)
    print(f"  LoRA adapter saved: {FT_OUT}")

tokenizer.save_pretrained(FT_OUT)
print(f"\n  Fine-tuning complete → {FT_OUT}")
print(f"  Load: ai {TM_LABEL.split()[0].lower()} load")
PYEOF

  if [[ $? -eq 0 ]]; then
    ok "Fine-tuning complete: $ft_out"
    echo "  Load model: ai $(echo "$id" | tr '[:upper:]' '[:lower:]') load"
    echo "  Upload:     ai $(echo "$id" | tr '[:upper:]' '[:lower:]') upload"
  else
    err "Fine-tuning failed. Check logs above."
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  RLHF — Reinforcement Learning from Human Feedback
#  Auto-RLHF: judge model rates responses → DPO training
#  Manual RLHF: thumbs up/down + star ratings → stored preferences
# ════════════════════════════════════════════════════════════════════════════════

# Judge model configs
declare -A RLHF_JUDGES
RLHF_JUDGES=(
  [nix26]="mradermacher/Nix2.6-GGUF|Nix2.6-Q4_K_M.gguf|Single judge — Nix 2.6 (general alignment)"
  [qwen3+luth]="Qwen/Qwen3-1.7B-GGUF|qwen3-1.7b-q4_k_m.gguf+kurakurai/Luth-LFM2-350M-GGUF|Luth-LFM2-350M.Q4_K_M.gguf|Dual judge — Qwen3-1.7B + Luth 350M (fast+quality)"
  [qwen3+llama32]="Qwen/Qwen3-1.7B-GGUF|qwen3-1.7b-q4_k_m.gguf+bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|Dual judge — Qwen3-1.7B + Llama 3.2-3B (balanced)"
)

RLHF_PREF_FILE="$CONFIG_DIR/rlhf_preferences.jsonl"
RLHF_PAIRS_FILE="$CONFIG_DIR/rlhf_pairs.jsonl"
RLHF_RATINGS_FILE="$CONFIG_DIR/rlhf_ratings.jsonl"
# Ensure RLHF data files exist
touch "$RLHF_PAIRS_FILE" "$RLHF_RATINGS_FILE" 2>/dev/null || true

# Active HF RLHF dataset for training (set via 'ai rlhf use-dataset')
RLHF_ACTIVE_HF_DATASET="${RLHF_ACTIVE_HF_DATASET:-}"

# ── Download judge models ─────────────────────────────────────────────────────
_rlhf_download_judge() {
  local judge="${RLHF_JUDGE:-nix26}"
  local entry="${RLHF_JUDGES[$judge]:-${RLHF_JUDGES[nix26]}}"
  local judge_dir="$MODELS_DIR/rlhf_judges"
  mkdir -p "$judge_dir"

  info "Downloading RLHF judge(s): $judge"

  # Parse single or dual judge
  IFS='+' read -ra parts <<< "$entry"
  local i=0
  for part in "${parts[@]}"; do
    IFS='|' read -r repo filename desc <<< "$part"
    [[ -z "$repo" ]] && continue
    local dest="$judge_dir/${filename}"
    if [[ ! -f "$dest" ]]; then
      info "  Downloading $filename from $repo..."
      curl -L --progress-bar \
        --retry 5 --retry-delay 2 \
        ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/${repo}/resolve/main/${filename}" \
        -o "$dest" 2>/dev/null || \
      curl -L --progress-bar \
        --retry 5 --retry-delay 2 \
        ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/${repo}/resolve/main/$(echo "$filename" | tr '[:upper:]' '[:lower:]')" \
        -o "$dest" 2>/dev/null || { warn "  Could not download $filename"; continue; }
      ok "  Downloaded: $dest"
    else
      ok "  Already present: $filename"
    fi
    (( i++ ))
  done
}

# ── Score a response using judge model(s) ────────────────────────────────────
_rlhf_score_response() {
  local prompt="$1" response="$2" judge="${RLHF_JUDGE:-nix26}"
  local entry="${RLHF_JUDGES[$judge]:-${RLHF_JUDGES[nix26]}}"
  local judge_dir="$MODELS_DIR/rlhf_judges"
  [[ -z "$LLAMA_BIN" && -z "$PYTHON" ]] && { echo "0.5"; return; }

  # Build judge prompt
  local judge_prompt="[INST] Rate this AI response on a scale of 0.0-1.0.
Consider: factual accuracy, helpfulness, coherence, no hallucinations.
Respond with ONLY a decimal number between 0.0 and 1.0.

User prompt: ${prompt:0:200}
AI response: ${response:0:400}
[/INST] Score:"

  local score="0.5"

  # Try with llama.cpp
  if [[ -n "$LLAMA_BIN" && "$LLAMA_BIN" != "llama_cpp_python" ]]; then
    IFS='+' read -ra parts <<< "$entry"
    local scores=()
    for part in "${parts[@]}"; do
      IFS='|' read -r repo filename _ <<< "$part"
      local model="$judge_dir/$filename"
      [[ ! -f "$model" ]] && continue
      local s
      s=$("$LLAMA_BIN" -m "$model" -p "$judge_prompt" \
          -n 8 --temp 0 --top-k 1 --repeat-penalty 1.0 \
          --no-display-prompt 2>/dev/null | \
          grep -oP '[0-9]\.[0-9]+' | head -1)
      [[ -n "$s" ]] && scores+=("$s")
    done
    if [[ ${#scores[@]} -gt 0 ]]; then
      # Average scores from dual judges
      score=$(python3 -c "scores=[${scores[*]}]; print(round(sum(scores)/len(scores),3))" 2>/dev/null || echo "0.5")
    fi
  elif [[ -n "$PYTHON" ]]; then
    # Use transformers for scoring
    IFS='+' read -ra parts <<< "$entry"
    local part="${parts[0]}"
    IFS='|' read -r repo filename _ <<< "$part"
    local model="$judge_dir/$filename"
    [[ -f "$model" ]] && score=$(JUDGE_MODEL="$model" JUDGE_PROMPT="$judge_prompt" \
      "$PYTHON" - <<'PYEOF' 2>/dev/null
import os,sys
try:
    from llama_cpp import Llama
    llm=Llama(model_path=os.environ['JUDGE_MODEL'],n_ctx=512,verbose=False)
    out=llm(os.environ['JUDGE_PROMPT'],max_tokens=8,temperature=0,stop=['\n'])
    txt=out['choices'][0]['text'].strip()
    import re; m=re.search(r'[0-9]\.[0-9]+',txt)
    print(m.group(0) if m else '0.5')
except: print('0.5')
PYEOF
    )
  fi
  echo "$score"
}

# ── Auto-RLHF: collect (prompt, response, score) pairs → DPO training ────────
_rlhf_auto_collect() {
  local prompt="$1" response="$2"
  [[ "$RLHF_AUTO" != "1" ]] && return
  [[ -z "$prompt" || -z "$response" ]] && return

  local score
  score=$(_rlhf_score_response "$prompt" "$response")
  local ts; ts=$(date -Iseconds)

  # Store pair
  printf '{"ts":"%s","prompt":%s,"response":%s,"score":%s,"judge":"%s"}\n' \
    "$ts" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null || echo "\"$prompt\"")" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$response" 2>/dev/null || echo "\"$response\"")" \
    "$score" "$RLHF_JUDGE" \
    >> "$RLHF_PAIRS_FILE"

  # Trigger DPO if enough pairs accumulated and score is low
  local count; count=$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)
  if (( count > 0 && count % 20 == 0 )); then
    _rlhf_dpo_train &
  fi
}

# ── DPO training on collected pairs ──────────────────────────────────────────
_rlhf_dpo_train() {
  local model_dir="${1:-$ACTIVE_MODEL}"
  # Resolve TTM/MTM/Mtm shortcuts
  case "$model_dir" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|mmtm|MMTM) model_dir="$MMTM_DIR" ;;
  esac
  if [[ -z "$model_dir" || ! -d "$model_dir" ]]; then
    warn "RLHF: model directory not found: ${model_dir:-<not set>}"
    warn "  Run 'ai ttm pretrain' first, or specify model: ai rlhf train TTM"
    return 1
  fi
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Merge any active HF dataset pairs in first
  local pairs_source="$RLHF_PAIRS_FILE"
  if [[ -n "$RLHF_ACTIVE_HF_DATASET" && -f "$RLHF_ACTIVE_HF_DATASET" ]]; then
    local merged="/tmp/ai_rlhf_merged_$$.jsonl"
    cat "$RLHF_PAIRS_FILE" "$RLHF_ACTIVE_HF_DATASET" > "$merged" 2>/dev/null || true
    pairs_source="$merged"
  fi

  [[ ! -f "$pairs_source" ]] && { warn "No RLHF pairs collected yet."; return 1; }
  local count; count=$(wc -l < "$pairs_source" 2>/dev/null || echo 0)
  if (( count < 10 )); then
    warn "RLHF: Need at least 10 pairs (have $count). Rate more responses or add HF dataset."
    return 1
  fi

  info "RLHF: Running DPO training on $count pairs → $model_dir ..."
  PAIRS_FILE="$pairs_source" MODEL_DIR="$model_dir" \
  THRESHOLD="${RLHF_REWARD_THRESHOLD:-0.6}" CPU_ONLY="${CPU_ONLY_MODE:-0}" \
  "$PYTHON" - <<'PYEOF' &
import os, json, sys, random, pathlib, shutil
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType
except ImportError as e:
    print(f"RLHF: Missing dependency: {e}")
    print("  Install: pip install trl peft transformers datasets torch")
    sys.exit(1)

pairs_file = os.environ['PAIRS_FILE']
model_dir  = os.environ['MODEL_DIR']
threshold  = float(os.environ.get('THRESHOLD', '0.6'))
cpu_only   = os.environ.get('CPU_ONLY', '0') == '1'
out_dir    = model_dir + "_dpo"

# ── Load & deduplicate pairs ─────────────────────────────────────────────────
pairs = []; seen = set()
with open(pairs_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            p = json.loads(line)
            # Normalise score field — could be 'score', 'rating', 'reward'
            if 'rating' in p and 'score' not in p:
                p['score'] = float(p['rating']) / 5.0  # 1-5 stars → 0-1
            key = str(p.get('prompt', ''))[:120]
            if key in seen: continue
            seen.add(key); pairs.append(p)
        except: pass

if not pairs:
    print("RLHF: No valid pairs found in pairs file"); sys.exit(1)

# ── Build DPO format ─────────────────────────────────────────────────────────
dpo_data = []
if all('chosen' in p and 'rejected' in p for p in pairs):
    dpo_data = [{'prompt': p.get('prompt', ''),
                 'chosen': str(p['chosen']),
                 'rejected': str(p['rejected'])}
                for p in pairs if p.get('prompt') and p.get('chosen') and p.get('rejected')]
else:
    chosen   = [p for p in pairs if float(p.get('score', 0)) >= threshold]
    rejected = [p for p in pairs if float(p.get('score', 1)) <  threshold]
    if len(chosen) < 2 or len(rejected) < 2:
        print(f"RLHF: Not enough contrast pairs (chosen={len(chosen)}, rejected={len(rejected)})")
        print(f"  threshold={threshold}. Try: ai rlhf threshold 0.4")
        print("  Or import pairs: ai rlhf add-dataset hh-rlhf")
        sys.exit(1)
    random.shuffle(chosen); random.shuffle(rejected)
    for c, r in zip(chosen, rejected):
        dpo_data.append({
            'prompt':   str(c.get('prompt', '')),
            'chosen':   str(c.get('response', c.get('chosen', ''))),
            'rejected': str(r.get('response', r.get('rejected', ''))),
        })

dpo_data = [d for d in dpo_data if d['prompt'] and d['chosen'] and d['rejected']]
if not dpo_data:
    print("RLHF: No usable DPO pairs after filtering"); sys.exit(1)

print(f"RLHF: {len(dpo_data)} DPO pairs — training on {'CPU' if cpu_only else 'GPU/CPU'}...")

# ── Model setup ──────────────────────────────────────────────────────────────
try:
    from trl import DPOTrainer, DPOConfig
    import inspect

    device   = 'cpu' if cpu_only else ('cuda' if torch.cuda.is_available() else 'cpu')
    use_cuda = device == 'cuda'
    dtype    = torch.float32 if (cpu_only or not use_cuda) else \
               (torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16)

    load_kw = {'torch_dtype': dtype, 'low_cpu_mem_usage': True}
    if use_cuda:
        load_kw['device_map'] = 'auto'

    tokenizer = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model     = AutoModelForCausalLM.from_pretrained(model_dir, **load_kw)
    ref_model = AutoModelForCausalLM.from_pretrained(model_dir, **load_kw)

    lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=8, lora_alpha=16,
                      lora_dropout=0.05,
                      target_modules=["q_proj", "v_proj", "k_proj", "o_proj"],
                      bias="none")
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()

    if not use_cuda:
        model = model.to(device)
        ref_model = ref_model.to(device)

    ds = Dataset.from_list(dpo_data)

    # ── DPOConfig — compatible with trl 0.7 through 0.12+ ────────────────────
    dpo_cfg_params = inspect.signature(DPOConfig.__init__).parameters
    cfg_kwargs = dict(
        output_dir=out_dir,
        num_train_epochs=1,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        max_steps=min(len(dpo_data), 200),
        learning_rate=5e-6,
        lr_scheduler_type="cosine",
        warmup_ratio=0.05,
        logging_steps=10,
        save_steps=500,
        report_to='none',
        remove_unused_columns=False,
        bf16=(use_cuda and dtype == torch.bfloat16),
        fp16=(use_cuda and dtype == torch.float16),
    )
    # max_length / max_prompt_length removed in trl ≥ 0.9
    if 'max_length' in dpo_cfg_params:
        cfg_kwargs['max_length'] = 512
    if 'max_prompt_length' in dpo_cfg_params:
        cfg_kwargs['max_prompt_length'] = 256

    cfg = DPOConfig(**cfg_kwargs)

    # ── DPOTrainer — 'tokenizer' renamed to 'processing_class' in trl ≥ 0.12 ─
    trainer_params = inspect.signature(DPOTrainer.__init__).parameters
    trainer_kwargs = dict(model=model, ref_model=ref_model, args=cfg, train_dataset=ds)
    if 'processing_class' in trainer_params:
        trainer_kwargs['processing_class'] = tokenizer
    else:
        trainer_kwargs['tokenizer'] = tokenizer

    trainer = DPOTrainer(**trainer_kwargs)
    trainer.train()

    # Merge LoRA weights back into base model and save
    merged = model.merge_and_unload()
    merged.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)

    # Copy config.json if missing from output
    src_cfg = pathlib.Path(model_dir) / 'config.json'
    dst_cfg = pathlib.Path(out_dir) / 'config.json'
    if src_cfg.exists() and not dst_cfg.exists():
        shutil.copy(src_cfg, dst_cfg)

    print(f"RLHF DPO complete → {out_dir}")
    print(f"  Load with: ai model {out_dir}")

except ImportError as ie:
    print(f"RLHF: Missing dependency: {ie}")
    print("  Install: pip install 'trl>=0.7' peft transformers datasets")
    sys.exit(1)
except Exception as e:
    import traceback
    print(f"RLHF DPO error: {e}")
    traceback.print_exc()
    sys.exit(1)
PYEOF
  # Clean up temp merged file if we created one
  [[ -f "/tmp/ai_rlhf_merged_$$.jsonl" ]] && rm -f "/tmp/ai_rlhf_merged_$$.jsonl" 2>/dev/null || true
}

# ── Mandatory realignment (anti-hallucination) using Qwen3 ───────────────────
_tm_align() {
  local id="$1"; _tm_vars "$id"
  local base_model="$TM_DIR/pretrained"
  local latest_ft; latest_ft=$(ls -td "$TM_DIR"/ft_v*/ 2>/dev/null | head -1 || echo "")
  [[ -n "$latest_ft" ]] && base_model="$latest_ft"
  [[ ! -d "$base_model" ]] && { warn "No model to align"; return 1; }
  [[ -z "$PYTHON" ]] && { warn "Python not found for alignment"; return 1; }

  # Download Qwen3-1.7B if not present
  local qwen_dir="$MODELS_DIR/rlhf_judges"
  local qwen_gguf="$qwen_dir/qwen3-1.7b-q4_k_m.gguf"
  mkdir -p "$qwen_dir"
  if [[ ! -f "$qwen_gguf" ]]; then
    info "Downloading Qwen3-1.7B for alignment..."
    curl -L --retry 5 --progress-bar \
      ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
      "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/qwen3-1.7b-q4_k_m.gguf" \
      -o "$qwen_gguf" 2>/dev/null || { warn "Could not download Qwen3; skipping alignment"; return 1; }
  fi

  local out_dir="$TM_DIR/aligned_v$(_tm_get_var "$TM_VERSION_VAR")"
  mkdir -p "$out_dir"
  info "Alignment: generating anti-hallucination training pairs with Qwen3..."

  BASE_MODEL="$base_model" QWEN_GGUF="$qwen_gguf" OUT_DIR="$out_dir" \
  LLAMA_BIN_VAL="${LLAMA_BIN:-}" "$PYTHON" - <<'PYEOF'
import os, json, subprocess, sys, random
base_model = os.environ['BASE_MODEL']
qwen_gguf  = os.environ['QWEN_GGUF']
out_dir    = os.environ['OUT_DIR']
llama_bin  = os.environ.get('LLAMA_BIN_VAL','')

# Generate factual Q&A pairs using Qwen3 as teacher
alignment_prompts = [
    "What is 2+2? Answer only with the number.",
    "Name the capital of France. Answer in one word.",
    "Is the Earth round or flat? Answer in one sentence.",
    "What is Python? Answer in 1-2 sentences without fabricating details.",
    "What does CPU stand for? Answer in one sentence.",
    "Name three primary colors. List only the colors.",
    "What year did World War 2 end? Answer with just the year.",
    "What language is used to style web pages? One word answer.",
    "Is the sun a star? Yes or no, then one sentence explanation.",
    "What is machine learning? Define it in 1-2 sentences without making things up.",
    "Who wrote Hamlet? One sentence answer.",
    "What does HTTP stand for? Full expansion only.",
    "Name the planet closest to the Sun. One word.",
    "What is the boiling point of water at sea level? Number and unit.",
    "How many continents are there? Number only.",
    "What is photosynthesis? One factual sentence.",
    "What programming language is named after a snake? One word.",
    "What is RAM used for? One sentence.",
    "Name the largest ocean. One word.",
    "What does AI stand for? Two words.",
]

pairs = []
if llama_bin and llama_bin != 'llama_cpp_python':
    for prompt in alignment_prompts:
        try:
            result = subprocess.run(
                [llama_bin, '-m', qwen_gguf, '-p',
                 f'<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n',
                 '-n', '64', '--temp', '0.1', '--top-k', '10',
                 '--no-display-prompt', '--repeat-penalty', '1.1'],
                capture_output=True, text=True, timeout=30
            )
            response = result.stdout.strip()
            if response and len(response) > 2:
                pairs.append({'instruction': prompt, 'response': response,
                              'source': 'qwen3_alignment'})
        except Exception as e:
            pass

if not pairs:
    # Fallback: static high-quality alignment pairs
    pairs = [
        {"instruction": "What is 2+2?", "response": "4"},
        {"instruction": "Name the capital of France.", "response": "Paris"},
        {"instruction": "Is the Earth round or flat?", "response": "The Earth is round (an oblate spheroid)."},
        {"instruction": "What does CPU stand for?", "response": "Central Processing Unit."},
        {"instruction": "What year did World War 2 end?", "response": "1945"},
        {"instruction": "What is Python?", "response": "Python is a high-level, interpreted programming language known for its readable syntax."},
        {"instruction": "What does HTTP stand for?", "response": "HyperText Transfer Protocol."},
        {"instruction": "What is machine learning?", "response": "Machine learning is a subset of AI where systems learn patterns from data to make predictions."},
        {"instruction": "Name the planet closest to the Sun.", "response": "Mercury."},
        {"instruction": "What is the boiling point of water at sea level?", "response": "100°C (212°F)."},
        {"instruction": "How many continents are there?", "response": "7"},
        {"instruction": "What does RAM stand for?", "response": "Random Access Memory."},
        {"instruction": "Who wrote Hamlet?", "response": "William Shakespeare."},
        {"instruction": "Name the largest ocean.", "response": "The Pacific Ocean."},
        {"instruction": "What does AI stand for?", "response": "Artificial Intelligence."},
        {"instruction": "What language styles web pages?", "response": "CSS (Cascading Style Sheets)."},
        {"instruction": "What programming language is named after a snake?", "response": "Python."},
        {"instruction": "Name three primary colors.", "response": "Red, blue, and yellow."},
        {"instruction": "Is the sun a star?", "response": "Yes. The Sun is a G-type main-sequence star at the center of our solar system."},
        {"instruction": "What is photosynthesis?", "response": "Photosynthesis is the process by which plants use sunlight, water, and CO2 to produce glucose and oxygen."},
    ]

# Save alignment dataset
align_file = f"{out_dir}/alignment_data.jsonl"
with open(align_file, 'w') as f:
    for p in pairs: f.write(json.dumps(p) + '\n')
print(f"Generated {len(pairs)} alignment pairs → {align_file}")

# Fine-tune the model on alignment data
try:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, \
        TrainingArguments, Trainer, DataCollatorForLanguageModeling
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model, TaskType

    tokenizer = AutoTokenizer.from_pretrained(base_model)
    tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(base_model)
    lora = LoraConfig(task_type=TaskType.CAUSAL_LM, r=8, lora_alpha=16,
                      lora_dropout=0.05, target_modules=["q_proj","v_proj","k_proj","o_proj"])
    model = get_peft_model(model, lora)

    texts = [f"### Instruction:\n{p['instruction']}\n\n### Response:\n{p['response']}" for p in pairs]
    ds = Dataset.from_list([{'text': t} for t in texts])
    def tok(ex):
        return tokenizer(ex['text'], truncation=True, max_length=256, padding='max_length')
    ds = ds.map(tok, batched=True, remove_columns=['text'])

    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    model = model.to(device)

    args = TrainingArguments(
        output_dir=out_dir, num_train_epochs=3,
        per_device_train_batch_size=1, gradient_accumulation_steps=4,
        learning_rate=2e-4, logging_steps=5, save_steps=100,
        report_to='none', warmup_ratio=0.1,
        fp16=(device=='cuda'), dataloader_num_workers=0,
    )
    Trainer(model=model, args=args, train_dataset=ds,
            data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False)).train()
    merged = model.merge_and_unload()
    merged.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)
    print(f"Alignment fine-tune saved → {out_dir}")
except Exception as e:
    print(f"Alignment training error (data saved): {e}")
PYEOF

  if [[ -d "$out_dir" ]]; then
    ok "Alignment complete: $out_dir"
    # Set as latest model
    local ver; ver=$(_tm_get_var "$TM_VERSION_VAR")
    local aligned_link="$TM_DIR/ft_v${ver}_aligned"
    [[ -L "$aligned_link" ]] && rm -f "$aligned_link"
    ln -sfn "$out_dir" "$aligned_link" 2>/dev/null || true
  else
    warn "Alignment output not found"
  fi
}

# ── Manual RLHF: rating system ────────────────────────────────────────────────
_rlhf_rate() {
  local prompt="$1" response="$2" rating="${3:-}"

  if [[ -z "$rating" ]]; then
    echo -e "\n${B}Rate this response:${R}"
    echo -e "  ${BGREEN}5${R} ★★★★★ Excellent"
    echo -e "  ${BBLUE}4${R} ★★★★☆ Good"
    echo -e "  ${BYELLOW}3${R} ★★★☆☆ OK"
    echo -e "  ${BRED}2${R} ★★☆☆☆ Poor"
    echo -e "  ${RED}1${R} ★☆☆☆☆ Wrong/Harmful"
    echo -e "  ${DIM}s${R} Skip"
    read -rp "Rating [1-5/s]: " rating
    [[ "$rating" == "s" || -z "$rating" ]] && return
  fi

  local ts; ts=$(date -Iseconds)
  local score
  case "$rating" in
    5) score="1.0" ;;  4) score="0.8" ;;  3) score="0.6" ;;
    2) score="0.3" ;;  1) score="0.0" ;;  *) return ;;
  esac

  printf '{"ts":"%s","prompt":%s,"response":%s,"rating":%s,"score":%s,"source":"manual"}\n' \
    "$ts" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt" 2>/dev/null || echo "\"$prompt\"")" \
    "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$response" 2>/dev/null || echo "\"$response\"")" \
    "$rating" "$score" \
    >> "$RLHF_RATINGS_FILE"

  case "$rating" in
    5) echo -e "${BGREEN}✓ Saved — Excellent${R}" ;;
    4) echo -e "${BBLUE}✓ Saved — Good${R}" ;;
    3) echo -e "${BYELLOW}✓ Saved${R}" ;;
    2|1) echo -e "${BRED}✓ Saved — Will use for improvement${R}" ;;
  esac
  ok "Rating saved. Total: $(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null)  |  ai rlhf train-on-ratings"
}

cmd_rlhf() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    status)
      hdr "RLHF Status"
      printf "  %-25s %s\n" "Auto-RLHF:" "$RLHF_AUTO"
      printf "  %-25s %s\n" "Judge model:" "$RLHF_JUDGE"
      printf "  %-25s %s\n" "Reward threshold:" "$RLHF_REWARD_THRESHOLD"
      printf "  %-25s %s\n" "Manual ratings:" "$(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null || echo 0)"
      printf "  %-25s %s\n" "Auto pairs collected:" "$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)"
      ;;
    enable)
      RLHF_AUTO="1"; save_config
      ok "Auto-RLHF enabled (judge: $RLHF_JUDGE)"
      warn "Run 'ai rlhf download-judges' to get judge models"
      ;;
    disable) RLHF_AUTO="0"; save_config; ok "Auto-RLHF disabled" ;;
    judge)
      local j="${1:-}"; [[ -z "$j" ]] && {
        hdr "Available RLHF Judges"
        for k in "${!RLHF_JUDGES[@]}"; do
          IFS='|' read -r _ _ desc <<< "${RLHF_JUDGES[$k]}"
          printf "  ${B}%-18s${R} %s\n" "$k" "$desc"
        done
        echo ""; read -rp "Choose judge [nix26/qwen3+luth/qwen3+llama32]: " j
      }
      [[ -z "${RLHF_JUDGES[$j]:-}" ]] && { err "Unknown judge: $j"; return 1; }
      RLHF_JUDGE="$j"; save_config; ok "Judge: $j"
      ;;
    download-judges) _rlhf_download_judge ;;
    train)
      local model="${1:-$ACTIVE_MODEL}"
      [[ -z "$model" ]] && { err "No model specified"; return 1; }
      info "Running DPO training on auto-collected pairs..."
      _rlhf_dpo_train "$model"
      ;;
    train-on-ratings)
      local count; count=$(wc -l < "$RLHF_RATINGS_FILE" 2>/dev/null || echo 0)
      (( count < 5 )) && { warn "Need at least 5 ratings (have $count)"; return 1; }
      # Merge ratings into pairs file then train
      cat "$RLHF_RATINGS_FILE" >> "$RLHF_PAIRS_FILE"
      _rlhf_dpo_train "$ACTIVE_MODEL"
      ;;
    rate)
      local prompt="${1:-}"; local response="${2:-}"; local rating="${3:-}"
      if [[ -z "$prompt" ]]; then
        read -rp "Prompt: " prompt; read -rp "Response: " response
      fi
      _rlhf_rate "$prompt" "$response" "$rating"
      ;;
    align)
      local id="${1:-TTM}"
      _tm_vars "$id" 2>/dev/null && _tm_align "$id"
      ;;
    clear-pairs)
      read -rp "Clear all collected RLHF pairs? [y/N]: " c
      [[ "$c" =~ ^[Yy]$ ]] && { > "$RLHF_PAIRS_FILE"; > "$RLHF_RATINGS_FILE"; ok "Cleared"; }
      ;;
    threshold)
      RLHF_REWARD_THRESHOLD="${1:-0.6}"; save_config
      ok "Reward threshold: $RLHF_REWARD_THRESHOLD"
      ;;

    # ── v2.4.5: HuggingFace RLHF datasets ─────────────────────────────────────
    datasets|list-datasets)
      _rlhf_hf_list_presets
      ;;
    add-dataset)
      local ds="${1:?Usage: ai rlhf add-dataset <hf-id-or-preset-name>}"
      local split="${2:-train[:3000]}"
      _rlhf_hf_import "$ds" "$split"
      ;;
    use-dataset)
      local ds="${1:?Usage: ai rlhf use-dataset <hf-id-or-preset-name>}"
      _rlhf_hf_set_active "$ds"
      ;;
    my-datasets)
      _rlhf_hf_list_imported
      ;;

    # v2.5: RLHF v2 — reward model, PPO, GRPO
    reward-model|train-reward)
      _rlhf_train_reward_model "${1:-TTM}" ;;
    ppo|train-ppo)
      _rlhf_train_ppo "${1:-TTM}" ;;
    grpo|train-grpo)
      _rlhf_train_grpo "${1:-TTM}" ;;

    *)
      hdr "RLHF v2 — Reinforcement Learning from Human Feedback"
      echo ""
      echo "  ${B}Auto-RLHF${R}  (judge models score responses, DPO trains on pairs)"
      echo "  ai rlhf enable / disable"
      echo "  ai rlhf judge [nix26|qwen3+luth|qwen3+llama32]"
      echo "  ai rlhf download-judges      — Download selected judge model(s)"
      echo "  ai rlhf train [model-path]   — Run DPO on collected pairs"
      echo "  ai rlhf threshold <0.0-1.0>  — Set reward cutoff (default 0.6)"
      echo ""
      echo "  ${B}v2.5: RLHF v2 additions${R}"
      echo "  ai rlhf reward-model [model] — Train reward model on pairs"
      echo "  ai rlhf ppo [model]          — PPO fine-tuning with reward model"
      echo "  ai rlhf grpo [model]         — GRPO training (DeepSeek-R1 style)"
      echo ""
      echo "  ${B}Manual RLHF${R}  (rate responses 1-5 stars)"
      echo "  ai rlhf rate                 — Rate a response interactively"
      echo "  ai rlhf train-on-ratings     — Fine-tune on your ratings"
      echo ""
      echo "  ${B}HF RLHF Datasets (v2.4.5)${R}  — curated preference datasets"
      echo "  ai rlhf datasets             — List available HF preset datasets"
      echo "  ai rlhf add-dataset <id>     — Import a HF dataset into RLHF pairs"
      echo "  ai rlhf use-dataset <id>     — Set as active RLHF training source"
      echo "  ai rlhf my-datasets          — Show imported datasets + counts"
      echo ""
      echo "  ${B}Alignment${R}  (Qwen3-powered anti-hallucination pass)"
      echo "  ai rlhf align TTM|MTM|Mtm    — Run alignment on trained model"
      echo ""
      echo "  ai rlhf status               — Show RLHF stats"
      echo "  ai rlhf clear-pairs          — Clear collected data"
      echo ""
      echo -e "  ${DIM}Judge options:${R}"
      for k in "${!RLHF_JUDGES[@]}"; do
        IFS='|' read -r _ _ desc <<< "${RLHF_JUDGES[$k]}"
        printf "    ${B}%-18s${R} %s\n" "$k" "$desc"
      done
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  RLHF HF DATASETS  (v2.4.5)
#  Curated list of HuggingFace preference/RLHF datasets
#  Import → convert to {prompt, chosen, rejected} format → merge into RLHF pairs
# ════════════════════════════════════════════════════════════════════════════════

# Curated RLHF / preference datasets on HuggingFace
# Format: "hf-id|field-map|description"
declare -A RLHF_HF_PRESETS
RLHF_HF_PRESETS=(
  [hh-rlhf]="Anthropic/hh-rlhf|chosen+rejected|Anthropic HH-RLHF (human pref, 160k pairs)"
  [summarize]="openai/summarize_from_feedback|info.post+summary|OpenAI Summary Feedback (93k)"
  [pku-safe]="PKU-Alignment/PKU-SafeRLHF|prompt+response_0+response_1+better_response_id|PKU-SafeRLHF (330k safety pairs)"
  [ultrafeedback]="HuggingFaceH4/ultrafeedback_binarized|prompt+chosen+rejected|UltraFeedback binarized (61k)"
  [helpsteer2]="nvidia/HelpSteer2|prompt+response+helpfulness|NVIDIA HelpSteer2 (21k rated)"
  [orca-dpo]="Intel/orca_dpo_pairs|system+question+chosen+rejected|Orca DPO pairs (12.9k)"
  [capybara]="argilla/distilabel-capybara-dpo-7k-binarized|instruction+chosen+rejected|Capybara DPO 7k"
  [math-pref]="argilla/distilabel-math-preference-dpo|instruction+chosen+rejected|Math preference DPO"
  [openhermes-pref]="argilla/openhermes2.5-dpo-binarized-alpha|prompt+chosen+rejected|OpenHermes 2.5 DPO"
  [skywork-reward]="Skywork/Skywork-Reward-Preference-80K-v0.2|prompt+chosen+rejected|Skywork Reward 80k"
)

_rlhf_hf_list_presets() {
  hdr "HuggingFace RLHF Datasets (v2.4.5)"
  echo ""
  printf "  %-18s  %-45s  %s\n" "PRESET NAME" "HF REPO" "DESCRIPTION"
  printf "  %s\n" "$(printf '%0.s-' {1..90})"
  for key in "${!RLHF_HF_PRESETS[@]}"; do
    IFS='|' read -r hf_id _ desc <<< "${RLHF_HF_PRESETS[$key]}"
    printf "  %-18s  %-45s  %s\n" "$key" "$hf_id" "$desc"
  done | sort
  echo ""
  echo "  Add any preset: ai rlhf add-dataset <name>"
  echo "  Or any HF id:   ai rlhf add-dataset Anthropic/hh-rlhf"
  echo "  Limit sample:   ai rlhf add-dataset hh-rlhf 'train[:2000]'"
}

_rlhf_hf_list_imported() {
  [[ ! -f "$RLHF_HF_DATASETS_FILE" ]] && { info "No HF datasets imported yet"; return; }
  hdr "Imported RLHF Datasets"
  python3 -c "
import json, sys
try:
    ds = json.load(open('$RLHF_HF_DATASETS_FILE'))
except:
    ds = []
if not ds:
    print('  None.')
    sys.exit()
for d in ds:
    active = ' [active]' if d.get('active') else ''
    print(f\"  {d.get('name','?'):20}  {d.get('source','?'):40}  {d.get('pairs',0):>6} pairs{active}\")
"
}

_rlhf_hf_set_active() {
  local name="$1"
  [[ ! -f "$RLHF_HF_DATASETS_FILE" ]] && { err "No HF datasets. Import one first."; return 1; }
  python3 - <<PYEOF
import json
dss = json.load(open('$RLHF_HF_DATASETS_FILE'))
found = False
for d in dss:
    if d.get('name') == '$name' or d.get('source', '').endswith('$name'):
        d['active'] = True; found = True
    else:
        d['active'] = False
json.dump(dss, open('$RLHF_HF_DATASETS_FILE', 'w'), indent=2)
# Print the jsonl file path for the active dataset so bash can capture it
active = next((d for d in dss if d.get('active')), None)
if active:
    import pathlib
    # Derive the per-dataset jsonl path from pairs file convention
    ds_name = active.get('name', '')
    print(f'ACTIVE_PATH:$CONFIG_DIR/rlhf_hf_{ds_name}.jsonl')
print('Active RLHF dataset set to: $name' if found else 'Dataset not found: $name')
PYEOF
  local out; out=$?
  if [[ $out -eq 0 ]]; then
    # Extract and save the active file path if printed
    local active_path
    active_path=$(python3 -c "
import json,sys
dss=json.load(open('$RLHF_HF_DATASETS_FILE'))
a=next((d for d in dss if d.get('active')),None)
print('$CONFIG_DIR/rlhf_hf_'+a['name']+'.jsonl' if a else '') " 2>/dev/null || true)
    [[ -n "$active_path" ]] && RLHF_ACTIVE_HF_DATASET="$active_path"
    save_config
    ok "Active RLHF dataset: $name"
  fi
}

_rlhf_hf_import() {
  local input="$1"; local split="${2:-train[:3000]}"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }

  # Resolve preset name to HF id + field map
  local hf_id="$input" field_map=""
  if [[ -n "${RLHF_HF_PRESETS[$input]:-}" ]]; then
    IFS='|' read -r hf_id field_map _ <<< "${RLHF_HF_PRESETS[$input]}"
  fi

  local ds_name; ds_name=$(echo "$hf_id" | tr '/' '_' | tr -d '.')
  info "Importing RLHF dataset: $hf_id (split: $split)"
  info "Output: $RLHF_PAIRS_FILE"

  HF_ID="$hf_id" SPLIT="$split" FIELD_MAP="$field_map" \
  PAIRS_FILE="$RLHF_PAIRS_FILE" DS_NAME="$ds_name" \
  HF_DATASETS_FILE="$RLHF_HF_DATASETS_FILE" \
  HF_TOKEN_VAL="${HF_TOKEN:-}" \
  "$PYTHON" - <<'PYEOF'
import os, sys, json
hf_id      = os.environ['HF_ID']
split      = os.environ.get('SPLIT', 'train[:3000]')
field_map  = os.environ.get('FIELD_MAP', '')
pairs_file = os.environ['PAIRS_FILE']
ds_name    = os.environ['DS_NAME']
hf_ds_file = os.environ['HF_DATASETS_FILE']
hf_token   = os.environ.get('HF_TOKEN_VAL', '') or None

try:
    from datasets import load_dataset
except ImportError:
    print("Missing: datasets\nRun: pip install datasets"); sys.exit(1)

print(f"  Loading {hf_id} [{split}] ...")
try:
    ds = load_dataset(hf_id, split=split, token=hf_token, trust_remote_code=True)
except Exception as e:
    # Try without split parameter
    try:
        ds = load_dataset(hf_id, token=hf_token, trust_remote_code=True)
        # Get first available split
        if hasattr(ds, 'keys'):
            first_split = list(ds.keys())[0]
            ds = ds[first_split]
            if '[' in split:
                n = int(split.split('[')[1].rstrip(']').replace(':', ''))
                ds = ds.select(range(min(n, len(ds))))
    except Exception as e2:
        print(f"  Failed to load: {e2}"); sys.exit(1)

print(f"  Loaded {len(ds)} examples. Columns: {ds.column_names}")

# Smart field detection
cols = ds.column_names
pairs = []
for row in ds:
    chosen = None; rejected = None; prompt = None
    # Try explicit field_map first
    if field_map:
        fields = field_map.split('+')
        if len(fields) >= 2:
            if 'chosen' in fields and 'rejected' in fields:
                chosen   = str(row.get('chosen', '') or '')
                rejected = str(row.get('rejected', '') or '')
                prompt   = str(row.get('prompt', row.get('instruction', row.get('system', ''))) or '')
            elif 'response_0' in fields:
                # PKU-SafeRLHF style
                bid = int(row.get('better_response_id', 0))
                r0 = str(row.get('response_0', '') or '')
                r1 = str(row.get('response_1', '') or '')
                prompt = str(row.get('prompt', '') or '')
                chosen   = r0 if bid == 0 else r1
                rejected = r1 if bid == 0 else r0
            else:
                # Generic: treat first as prompt, second as chosen
                vals = [str(row.get(f, '') or '') for f in fields if f in row]
                if len(vals) >= 2:
                    prompt = vals[0]; chosen = vals[1]
    # Auto-detect if still not set
    if chosen is None:
        if 'chosen' in cols and 'rejected' in cols:
            chosen   = str(row.get('chosen', '') or '')
            rejected = str(row.get('rejected', '') or '')
            prompt   = str(row.get('prompt', row.get('instruction', '')) or '')
        elif 'response' in cols and 'helpfulness' in cols:
            # HelpSteer2 style — score > 3 = chosen
            score = float(row.get('helpfulness', 3))
            if score >= 3.5:
                chosen = str(row.get('response', '') or '')
                prompt = str(row.get('prompt', '') or '')
        elif 'output' in cols:
            prompt = str(row.get('input', row.get('instruction', '')) or '')
            chosen = str(row.get('output', '') or '')
    if not chosen or not prompt:
        continue
    entry = {'prompt': prompt[:512], 'chosen': chosen[:1024]}
    if rejected:
        entry['rejected'] = rejected[:1024]
    entry['source'] = hf_id
    pairs.append(entry)

print(f"  Extracted {len(pairs)} preference pairs")
if not pairs:
    print("  No pairs could be extracted — check column names above"); sys.exit(1)

# Append to RLHF pairs file
with open(pairs_file, 'a') as f:
    for p in pairs:
        f.write(json.dumps(p) + '\n')
print(f"  Appended to: {pairs_file}")

# Track in HF datasets registry
try:
    reg = json.load(open(hf_ds_file)) if os.path.exists(hf_ds_file) else []
except:
    reg = []
# Update or add entry
found = False
for d in reg:
    if d.get('source') == hf_id:
        d['pairs'] += len(pairs); found = True
if not found:
    reg.append({'name': ds_name, 'source': hf_id, 'pairs': len(pairs),
                'split': split, 'active': True})
json.dump(reg, open(hf_ds_file, 'w'), indent=2)
print(f"  Registered as: {ds_name}")
print(f"  Total RLHF pairs now: {sum(1 for _ in open(pairs_file))}")
PYEOF

  if [[ $? -eq 0 ]]; then
    ok "HF RLHF dataset imported: $hf_id"
    local total; total=$(wc -l < "$RLHF_PAIRS_FILE" 2>/dev/null || echo 0)
    echo "  Total RLHF pairs: $total"
    echo "  Train now: ai rlhf train"
  else
    err "Import failed"
    return 1
  fi
}


# ════════════════════════════════════════════════════════════════════════════════
