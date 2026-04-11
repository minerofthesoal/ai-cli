# ============================================================================
# MODULE: 11-model-mgmt.sh
# Model state save/restore + custom model creation
# Source lines 3818-4113 of main-v2.7.3
# ============================================================================

# ════════════════════════════════════════════════════════════════════════════════
cmd_model_save_restore() {
  local sub="${1:-status}"
  case "$sub" in
    save)
      _model_save_state
      ok "Model state saved: $ACTIVE_MODEL ($ACTIVE_BACKEND)"
      ;;
    restore)
      _model_restore_state
      ;;
    status)
      local state_file="$CONFIG_DIR/.model_state"
      if [[ -f "$state_file" ]]; then
        info "Saved state:"
        cat "$state_file"
      else
        info "No saved state (current: $ACTIVE_MODEL)"
      fi
      ;;
  esac
}

cmd_model_create() {
  local subcmd="${1:-help}"; shift || true
  case "$subcmd" in
    presets) _model_list_presets ;;
    new)     _model_new "$@" ;;
    edit)    _model_edit "$@" ;;
    list)    _model_list_custom ;;
    train)   _model_train_custom "$@" ;;
    info)    _model_info_custom "$@" ;;
    delete)  _model_delete_custom "$@" ;;
    *)
      echo -e "${B}${BCYAN}Custom Model Creator${R}"
      echo ""
      echo "  ${B}ai model-create presets${R}         — List built-in architecture presets"
      echo "  ${B}ai model-create new <name> [preset|custom]${R} — Create new model config"
      echo "  ${B}ai model-create edit <name>${R}     — Edit model config JSON"
      echo "  ${B}ai model-create list${R}            — List custom models"
      echo "  ${B}ai model-create train <name> [data.jsonl]${R} — Train from scratch"
      echo "  ${B}ai model-create info <name>${R}     — Show model info"
      echo "  ${B}ai model-create delete <name>${R}   — Delete custom model"
      echo ""
      echo -e "  ${DIM}Minimum: 0.125B params (nano preset)${R}"
      ;;
  esac
}

_model_list_presets() {
  hdr "Built-in Model Presets"
  echo ""
  for key in nano micro tiny small medium tinyllama; do
    local val="${MODEL_PRESETS[$key]}"
    local params; params=$(echo "$val" | grep -o 'params=[^|]*' | cut -d= -f2)
    printf "  ${B}%-12s${R} %s\n" "$key" "$params"
  done
  echo ""
  echo "  Use: ${B}ai model-create new mymodel nano${R}"
  echo "  Or:  ${B}ai model-create new mymodel custom${R} (opens editor)"
}

_model_new() {
  local name="${1:-}"; local preset="${2:-tiny}"
  [[ -z "$name" ]] && { read -rp "Model name: " name; }
  [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ -d "$mdir" ]] && { err "Model '$name' already exists"; return 1; }
  mkdir -p "$mdir"

  local config
  if [[ "$preset" == "custom" ]]; then
    config="$TTM_CONFIG_JSON"
    echo "$config" > "$mdir/config.json"
    "${EDITOR:-nano}" "$mdir/config.json"
  elif [[ -n "${MODEL_PRESETS[$preset]:-}" ]]; then
    local p="${MODEL_PRESETS[$preset]}"
    local hs; hs=$(echo "$p" | grep -o 'hidden_size=[0-9]*' | cut -d= -f2)
    local nhl; nhl=$(echo "$p" | grep -o 'num_hidden_layers=[0-9]*' | cut -d= -f2)
    local nah; nah=$(echo "$p" | grep -o 'num_attention_heads=[0-9]*' | cut -d= -f2)
    local is; is=$(echo "$p" | grep -o 'intermediate_size=[0-9]*' | cut -d= -f2)
    local mpe; mpe=$(echo "$p" | grep -o 'max_position_embeddings=[0-9]*' | cut -d= -f2)
    local vs; vs=$(echo "$p" | grep -o 'vocab_size=[0-9]*' | cut -d= -f2)
    cat > "$mdir/config.json" <<JSON
{
  "architectures": ["LlamaForCausalLM"],
  "bos_token_id": 1,
  "eos_token_id": 2,
  "hidden_act": "silu",
  "hidden_size": $hs,
  "initializer_range": 0.02,
  "intermediate_size": $is,
  "max_position_embeddings": $mpe,
  "model_type": "llama",
  "num_attention_heads": $nah,
  "num_hidden_layers": $nhl,
  "num_key_value_heads": $nah,
  "rms_norm_eps": 1e-05,
  "rope_scaling": null,
  "tie_word_embeddings": false,
  "torch_dtype": "float32",
  "use_cache": true,
  "vocab_size": $vs
}
JSON
  elif [[ -f "$preset" ]]; then
    cp "$preset" "$mdir/config.json"
  else
    err "Unknown preset: $preset. Use: nano micro tiny small medium tinyllama custom or a path to JSON"
    rm -rf "$mdir"; return 1
  fi

  cat > "$mdir/meta.json" <<META
{
  "name": "$name",
  "preset": "$preset",
  "created": "$(date -Iseconds)",
  "trained": false,
  "train_steps": 0,
  "version": 1
}
META
  ok "Created custom model '$name' in $mdir"
  echo "  Config: $mdir/config.json"
  echo "  Train:  ai model-create train $name <data.jsonl>"
}

_model_edit() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  "${EDITOR:-nano}" "$mdir/config.json"
  ok "Saved '$name' config"
}

_model_list_custom() {
  hdr "Custom Models"
  local found=0
  for d in "$CUSTOM_MODELS_DIR"/*/; do
    [[ -f "$d/meta.json" ]] || continue
    found=1
    local name; name=$(basename "$d")
    local trained; trained=$(python3 -c "import json,sys; d=json.load(open('$d/meta.json')); print('yes' if d.get('trained') else 'no')" 2>/dev/null || echo "?")
    local steps; steps=$(python3 -c "import json,sys; d=json.load(open('$d/meta.json')); print(d.get('train_steps',0))" 2>/dev/null || echo "0")
    printf "  ${B}%-20s${R} trained=%-4s steps=%s\n" "$name" "$trained" "$steps"
  done
  [[ $found -eq 0 ]] && dim "  No custom models. Create one: ai model-create new mymodel tiny"
}

_model_info_custom() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  hdr "Model: $name"
  [[ -f "$mdir/config.json" ]] && { echo ""; echo "Config:"; cat "$mdir/config.json"; }
  [[ -f "$mdir/meta.json"   ]] && { echo ""; echo "Meta:";   cat "$mdir/meta.json";   }
}

_model_delete_custom() {
  local name="${1:-}"; [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found"; return 1; }
  read -rp "Delete '$name'? This cannot be undone. [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Cancelled"; return 0; }
  rm -rf "$mdir"; ok "Deleted '$name'"
}

_model_train_custom() {
  local name="${1:-}"; local data="${2:-}"
  [[ -z "$name" ]] && { err "Name required"; return 1; }
  local mdir="$CUSTOM_MODELS_DIR/$name"
  [[ ! -d "$mdir" ]] && { err "Model '$name' not found. Create it first: ai model-create new $name"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }

  # Use provided dataset or look for default
  if [[ -z "$data" ]]; then
    [[ -f "$FINETUNE_DIR/dataset.jsonl" ]] && data="$FINETUNE_DIR/dataset.jsonl"
    [[ -z "$data" ]] && { err "No dataset. Provide path or run: ai finetune prepare <data>"; return 1; }
  fi
  [[ ! -f "$data" ]] && { err "Dataset not found: $data"; return 1; }

  local out_dir="$mdir/trained_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$out_dir"
  info "Training custom model '$name' from scratch..."
  info "Config: $mdir/config.json"
  info "Data:   $data"
  info "Output: $out_dir"
  echo ""

  "$PYTHON" - <<PYEOF
import json, os, sys
try:
    import torch
    from transformers import (AutoTokenizer, LlamaConfig, LlamaForCausalLM,
                               TrainingArguments, Trainer, DataCollatorForLanguageModeling)
    from datasets import Dataset
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run: ai install-deps")
    sys.exit(1)

config_path = "$mdir/config.json"
data_path   = "$data"
out_dir     = "$out_dir"

with open(config_path) as f:
    cfg_dict = json.load(f)

cfg = LlamaConfig(**{k: v for k, v in cfg_dict.items()
                     if not k.startswith('_') and k != 'architectures'})
model = LlamaForCausalLM(cfg)
total_params = sum(p.numel() for p in model.parameters())
print(f"Model parameters: {total_params:,} ({total_params/1e6:.2f}M)")

if total_params < 0.125e9:
    print(f"WARNING: Model has {total_params/1e6:.2f}M params, minimum is 125M (0.125B)")
    sys.exit(1)

# Tokenizer — use TinyLlama's tokenizer as base
tokenizer_id = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
try:
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_id)
except Exception:
    tokenizer = AutoTokenizer.from_pretrained("huggyllama/llama-7b", use_fast=True)
tokenizer.pad_token = tokenizer.eos_token

# Load dataset
records = []
with open(data_path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
            txt = obj.get('text') or (obj.get('instruction','') + ' ' + obj.get('output',''))
            if txt.strip(): records.append({'text': txt})
        except: pass

if not records:
    print("No valid records in dataset"); sys.exit(1)
print(f"Dataset records: {len(records)}")

ds = Dataset.from_list(records)
def tokenize(ex):
    return tokenizer(ex['text'], truncation=True, max_length=cfg.max_position_embeddings,
                     padding='max_length')
ds = ds.map(tokenize, batched=True, remove_columns=['text'])

device = 'cuda' if torch.cuda.is_available() else 'cpu'
model = model.to(device)
print(f"Training on: {device}")

args = TrainingArguments(
    output_dir=out_dir,
    num_train_epochs=3,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=8,
    learning_rate=3e-4,
    lr_scheduler_type='cosine',
    warmup_ratio=0.05,
    fp16=(device=='cuda'),
    logging_steps=10,
    save_steps=100,
    save_total_limit=2,
    report_to='none',
)
trainer = Trainer(
    model=model,
    args=args,
    train_dataset=ds,
    data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
)
trainer.train()
model.save_pretrained(out_dir)
tokenizer.save_pretrained(out_dir)
print(f"Saved to {out_dir}")
PYEOF

  if [[ $? -eq 0 ]]; then
    # Update meta
    "$PYTHON" -c "
import json
m = json.load(open('$mdir/meta.json'))
m['trained'] = True
m['train_steps'] = m.get('train_steps',0) + 1
m['last_trained'] = '$(date -Iseconds)'
m['last_output'] = '$out_dir'
json.dump(m, open('$mdir/meta.json','w'), indent=2)
"
    ok "Training complete! Model saved to $out_dir"
  else
    err "Training failed"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
