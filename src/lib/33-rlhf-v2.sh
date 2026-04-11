# ============================================================================
# MODULE: 33-rlhf-v2.sh
# RLHF v2: reward model, PPO, GRPO
# Source lines 11833-12044 of main-v2.7.3
# ============================================================================

_rlhf_train_reward_model() {
  local model_id="${1:-TTM}" out_dir="$CONFIG_DIR/rlhf_reward_model"
  local pairs_file="$RLHF_PAIRS_FILE"
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  [[ ! -s "$pairs_file" ]] && { err "No RLHF pairs. Run: ai rlhf collect"; return 1; }
  info "Training RLHF Reward Model from ${model_id}..."
  mkdir -p "$out_dir"
  "$PYTHON" - "$pairs_file" "$out_dir" <<'PYEOF'
import sys, os, json, torch, traceback
pairs_file, out_dir = sys.argv[1], sys.argv[2]
try:
    from transformers import AutoTokenizer, AutoModelForSequenceClassification, TrainingArguments, Trainer
    from datasets import Dataset
    import numpy as np

    # Load pairs
    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    if len(pairs) < 10:
        print(f"Need at least 10 pairs (have {len(pairs)})")
        sys.exit(1)

    print(f"Training reward model on {len(pairs)} pairs...")

    # Use a small base model for reward modeling
    base = "distilbert-base-uncased"
    tokenizer = AutoTokenizer.from_pretrained(base)
    model = AutoModelForSequenceClassification.from_pretrained(base, num_labels=1)

    # Build dataset: chosen gets label 1, rejected gets label 0
    records = []
    for p in pairs:
        chosen = p.get('chosen', p.get('response_a', ''))
        rejected = p.get('rejected', p.get('response_b', ''))
        prompt = p.get('prompt', p.get('instruction', ''))
        if chosen: records.append({'text': f"{prompt}\n{chosen}", 'label': 1.0})
        if rejected: records.append({'text': f"{prompt}\n{rejected}", 'label': 0.0})

    def tokenize(batch):
        return tokenizer(batch['text'], truncation=True, max_length=512, padding='max_length')

    ds = Dataset.from_list(records).map(tokenize, batched=True)
    ds = ds.rename_column('label', 'labels')
    ds = ds.remove_columns(['text'])
    ds.set_format('torch')

    args = TrainingArguments(
        output_dir=out_dir, num_train_epochs=3,
        per_device_train_batch_size=4, logging_steps=20,
        save_strategy='epoch', evaluation_strategy='no',
        bf16=torch.cuda.is_available(), fp16=False,
        remove_unused_columns=False
    )
    trainer = Trainer(model=model, args=args, train_dataset=ds)
    trainer.train()
    model.save_pretrained(out_dir)
    tokenizer.save_pretrained(out_dir)
    print(f"Reward model saved: {out_dir}")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install transformers datasets torch")
except Exception:
    traceback.print_exc()
PYEOF
}

_rlhf_train_ppo() {
  local model_id="${1:-TTM}"
  local model_dir
  case "$model_id" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|MMTM|mmtm) model_dir="$MMTM_DIR" ;;
    *) model_dir="$model_id" ;;
  esac
  [[ ! -d "$model_dir" ]] && { err "Model dir not found: $model_dir. Run: ai ${model_id,,} pretrain"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  local reward_model_dir="$CONFIG_DIR/rlhf_reward_model"
  [[ ! -d "$reward_model_dir" ]] && { err "Train reward model first: ai rlhf reward-model $model_id"; return 1; }
  info "RLHF PPO training: $model_id → $model_dir"
  "$PYTHON" - "$model_dir" "$reward_model_dir" "$RLHF_PAIRS_FILE" <<'PYEOF'
import sys, os, json, torch, traceback
model_dir, reward_dir, pairs_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    from trl import PPOTrainer, PPOConfig, AutoModelForCausalLMWithValueHead
    from transformers import AutoTokenizer, AutoModelForSequenceClassification
    import numpy as np

    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForCausalLMWithValueHead.from_pretrained(model_dir, torch_dtype=dtype)
    reward_tokenizer = AutoTokenizer.from_pretrained(reward_dir)
    reward_model = AutoModelForSequenceClassification.from_pretrained(reward_dir)

    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    model = model.to(device)
    reward_model = reward_model.to(device)

    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    if not pairs:
        print("No RLHF pairs found")
        sys.exit(1)

    cfg = PPOConfig(model_name=model_dir, learning_rate=1.5e-5,
        batch_size=min(4, len(pairs)), mini_batch_size=1,
        gradient_accumulation_steps=4)
    ppo_trainer = PPOTrainer(cfg, model, ref_model=None, tokenizer=tokenizer)

    print(f"PPO training on {len(pairs)} pairs...")
    for i, pair in enumerate(pairs[:100]):  # limit for first run
        prompt = pair.get('prompt', pair.get('instruction', ''))
        if not prompt: continue
        try:
            enc = tokenizer(prompt, return_tensors='pt', truncation=True, max_length=256).to(device)
            with torch.no_grad():
                gen = model.generate(**enc, max_new_tokens=64, do_sample=True, temperature=0.7)
            response_text = tokenizer.decode(gen[0][enc['input_ids'].shape[1]:], skip_special_tokens=True)

            # Score with reward model
            r_enc = reward_tokenizer(prompt + '\n' + response_text,
                return_tensors='pt', truncation=True, max_length=512).to(device)
            with torch.no_grad():
                reward = reward_model(**r_enc).logits.squeeze().item()

            reward_tensor = torch.tensor([reward])
            ppo_trainer.step([enc['input_ids'][0]], [gen[0][enc['input_ids'].shape[1]:]], [reward_tensor])
            if (i+1) % 10 == 0:
                print(f"  Step {i+1}/{min(100,len(pairs))}, reward={reward:.3f}")
        except Exception as step_err:
            continue

    model.save_pretrained(model_dir + '_ppo')
    tokenizer.save_pretrained(model_dir + '_ppo')
    print(f"PPO model saved: {model_dir}_ppo")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install trl transformers torch")
except Exception:
    traceback.print_exc()
PYEOF
}

_rlhf_train_grpo() {
  local model_id="${1:-TTM}"
  local model_dir
  case "$model_id" in
    TTM|ttm) model_dir="$TTM_DIR" ;;
    MTM|mtm) model_dir="$MTM_DIR" ;;
    Mtm|MMTM|mmtm) model_dir="$MMTM_DIR" ;;
    *) model_dir="$model_id" ;;
  esac
  [[ ! -d "$model_dir" ]] && { err "Model not found: $model_dir"; return 1; }
  [[ -z "$PYTHON" ]] && { err "Python required"; return 1; }
  info "RLHF GRPO training: $model_id (Group Relative Policy Optimization)"
  "$PYTHON" - "$model_dir" "$RLHF_PAIRS_FILE" <<'PYEOF'
import sys, os, json, torch, traceback
model_dir, pairs_file = sys.argv[1], sys.argv[2]
try:
    from trl import GRPOTrainer, GRPOConfig
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from datasets import Dataset

    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    pairs = []
    with open(pairs_file) as f:
        for line in f:
            try: pairs.append(json.loads(line.strip()))
            except: pass

    prompts = [p.get('prompt', p.get('instruction','')) for p in pairs if p.get('prompt') or p.get('instruction')]
    if not prompts:
        print("No prompts in RLHF pairs"); sys.exit(1)

    def reward_fn(samples, prompts=None, **kwargs):
        # Simple length-based reward (replace with real reward model)
        return [min(len(s.split()) / 50.0, 1.0) for s in samples]

    cfg = GRPOConfig(output_dir=model_dir+'_grpo',
        num_train_epochs=1, per_device_train_batch_size=1,
        gradient_accumulation_steps=8, logging_steps=5,
        bf16=torch.cuda.is_available())
    ds = Dataset.from_dict({'prompt': prompts[:200]})
    model = AutoModelForCausalLM.from_pretrained(model_dir, torch_dtype=dtype)
    trainer = GRPOTrainer(model=model, reward_funcs=reward_fn,
        args=cfg, train_dataset=ds, tokenizer=tokenizer)
    trainer.train()
    trainer.save_model(model_dir + '_grpo')
    print(f"GRPO model saved: {model_dir}_grpo")
except ImportError as e:
    print(f"Missing: {e}")
    print("Install: pip install 'trl>=0.8' transformers torch datasets")
except Exception:
    traceback.print_exc()
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: CANVAS v2 — Multi-file workspace, split-pane, live preview, git
# ════════════════════════════════════════════════════════════════════════════════
