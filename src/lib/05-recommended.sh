# ============================================================================
# MODULE: 05-recommended.sh
# Recommended model list + builtin personas
# Source lines 469-601 of main-v2.7.3
# ============================================================================

# ════════════════════════════════════════════════════════════════════════════════
#  BUILTIN PERSONAS
# ════════════════════════════════════════════════════════════════════════════════
declare -A BUILTIN_PERSONAS
BUILTIN_PERSONAS=(
  [default]="You are a helpful, friendly AI assistant."
  [dev]="You are an expert software engineer. Write clean, secure, well-documented code. Prefer idiomatic solutions. Flag potential bugs and security issues."
  [researcher]="You are a rigorous researcher. Cite your reasoning. Acknowledge uncertainty. Be precise and thorough."
  [writer]="You are a skilled writer. Prioritize clarity, flow, and engagement. Adapt tone to context."
  [teacher]="You are a patient teacher. Use analogies and examples. Check for understanding. Scaffold complex concepts."
  [sysadmin]="You are a Linux/DevOps expert. Give precise, tested commands. Prefer minimal dependencies."
  [security]="You are a cybersecurity expert. Think offensively to defend. Reference CVEs where relevant."
  [data]="You are a data scientist. Use pandas, numpy, matplotlib. Apply statistical rigor."
  [creative]="You are a bold, original creative. Push boundaries. Experiment with form and voice."
  [concise]="Be maximally concise. Use the fewest words without losing accuracy."
  [audio]="You are an audio engineering and music production expert. Help with DSP, audio files, mixing, analysis."
  [video]="You are a video production and ffmpeg expert. Help with video editing, transcoding, analysis."
)


# ════════════════════════════════════════════════════════════════════════════════
#  CUSTOM MODEL CONFIGS (prebuilt architecture presets)
# ════════════════════════════════════════════════════════════════════════════════
declare -A MODEL_PRESETS
MODEL_PRESETS=(
  [nano]="hidden_size=256|num_hidden_layers=8|num_attention_heads=8|intermediate_size=512|max_position_embeddings=512|vocab_size=32000|params=~0.125B"
  [micro]="hidden_size=512|num_hidden_layers=8|num_attention_heads=8|intermediate_size=1024|max_position_embeddings=1024|vocab_size=32000|params=~0.25B"
  [tiny]="hidden_size=512|num_hidden_layers=10|num_attention_heads=8|intermediate_size=1024|max_position_embeddings=2048|vocab_size=32000|params=~0.35B"
  [small]="hidden_size=768|num_hidden_layers=12|num_attention_heads=12|intermediate_size=2048|max_position_embeddings=2048|vocab_size=32000|params=~0.5B"
  [medium]="hidden_size=1024|num_hidden_layers=16|num_attention_heads=16|intermediate_size=4096|max_position_embeddings=2048|vocab_size=32000|params=~1B"
  [tinyllama]="hidden_size=2048|num_hidden_layers=22|num_attention_heads=32|intermediate_size=5632|max_position_embeddings=2048|vocab_size=32000|params=~1.1B"
)

# ── Model JSON configs ────────────────────────────────────────────────────────

# TTM: 179.35M — TinyLlama-based
TTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":1280,"initializer_range":0.02,
  "intermediate_size":3328,"max_position_embeddings":2048,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":14,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"bfloat16",
  "use_cache":true,"vocab_size":32000,"_comment":"~179.35M params"
}'

# MTM: 0.61B — GTX 1080 optimized (fp16, 8GB VRAM — Pascal arch)
# Uses grouped-query attention (GQA) 4 kv heads, smaller intermediate for VRAM fit
MTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":2048,"initializer_range":0.02,
  "intermediate_size":5120,"max_position_embeddings":2048,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":18,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"float16",
  "use_cache":true,"vocab_size":32000,
  "_comment":"~0.61B params — GTX 1080 (8GB fp16) optimized"
}'

# Mtm: 1.075B — RTX 2080+ optimized (bf16, 8GB+ VRAM — Turing/Ampere)
# More layers, wider intermediate, bf16 for Turing+ tensor cores
MMTM_CONFIG_JSON='{
  "architectures":["LlamaForCausalLM"],"bos_token_id":1,"eos_token_id":2,
  "hidden_act":"silu","hidden_size":2048,"initializer_range":0.02,
  "intermediate_size":5632,"max_position_embeddings":4096,"model_type":"llama",
  "num_attention_heads":16,"num_hidden_layers":28,"num_key_value_heads":4,
  "rms_norm_eps":1e-05,"tie_word_embeddings":false,"torch_dtype":"bfloat16",
  "use_cache":true,"vocab_size":32000,
  "_comment":"~1.075B params — RTX 2080+ (bf16) optimized"
}'

# ════════════════════════════════════════════════════════════════════════════════
#  6 PRETRAINING DATASETS (shared by TTM/MTM/Mtm)
#  +2 optional custom ones set by user
# ════════════════════════════════════════════════════════════════════════════════
PRETRAIN_DATASETS=(
  "roneneldan/TinyStories|text|5000|Tiny children's stories — fluent English"
  "sahil2801/CodeAlpaca-20k|instruction+output|3000|Code generation pairs"
  "Open-Orca/OpenOrca|system_prompt+question+response|2000|Instruction following"
  "bigcode/the-stack-smol|content|2000|Small code snippets across languages"
  "HuggingFaceFW/fineweb-edu|text|3000|High-quality educational web text"
  "wikimedia/wikipedia|text|3000|Wikipedia articles (en, 20231101)"
)
# User-settable custom datasets (HF id or 'hf:user/repo' or local path)
PRETRAIN_CUSTOM_1="${PRETRAIN_CUSTOM_1:-}"
PRETRAIN_CUSTOM_2="${PRETRAIN_CUSTOM_2:-}"

# RLHF settings
RLHF_AUTO="${RLHF_AUTO:-0}"
RLHF_JUDGE="${RLHF_JUDGE:-nix26}"           # nix26 | qwen3+luth | qwen3+llama32
RLHF_MANUAL_ENABLED="${RLHF_MANUAL_ENABLED:-1}"
RLHF_REWARD_THRESHOLD="${RLHF_REWARD_THRESHOLD:-0.6}"

# Right-click context menu
RCLICK_ENABLED="${RCLICK_ENABLED:-0}"
RCLICK_VL_MODEL="${RCLICK_VL_MODEL:-qwen3vl}"  # qwen3vl | lfm25vl | lfm25vl_gguf | custom
RCLICK_CUSTOM_MODEL="${RCLICK_CUSTOM_MODEL:-}"

# Auto-updater
AUP_REPO="${AUP_REPO:-minerofthesoal/ai-cli}"
AUP_CHECK_INTERVAL="${AUP_CHECK_INTERVAL:-3600}"
AUP_LAST_CHECK="${AUP_LAST_CHECK:-0}"

# Agent mode
AGENT_MODE="${AGENT_MODE:-0}"
AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-10}"
AGENT_SEARCH_ENGINE="${AGENT_SEARCH_ENGINE:-ddg}"

# v2.4: LLM API server settings
API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8080}"
API_KEY="${API_KEY:-}"            # optional bearer token for API auth
API_CORS="${API_CORS:-1}"         # enable CORS for browser clients

# v2.4.5: API key hosting (shareable keys for others to access your model)
API_SHARE_ENABLED="${API_SHARE_ENABLED:-0}"
API_SHARE_HOST="${API_SHARE_HOST:-0.0.0.0}"
API_SHARE_PORT="${API_SHARE_PORT:-8080}"
API_SHARE_RATE_LIMIT="${API_SHARE_RATE_LIMIT:-60}"  # requests per minute per key

# v2.4.5: Multi-AI settings
MULTIAI_ROUNDS="${MULTIAI_ROUNDS:-6}"               # default conversation rounds
MULTIAI_SAVE_DATASET="${MULTIAI_SAVE_DATASET:-1}"   # save as training dataset
MULTIAI_RLHF_TRAIN="${MULTIAI_RLHF_TRAIN:-0}"       # auto-train on rated exchanges

# v2.4: CPU-only mode (auto-set on Windows or when no GPU found)
# v2.6: Fixed — sm_61 (Pascal GTX 10xx) and Metal correctly detected as GPU
CPU_ONLY_MODE="${CPU_ONLY_MODE:-0}"
[[ $IS_WINDOWS -eq 1 ]] && CPU_ONLY_MODE=1
# Only force CPU mode if CUDA_ARCH is truly 0 (no GPU whatsoever)
[[ "${CUDA_ARCH:-0}" == "0" ]] && CPU_ONLY_MODE=1

# ════════════════════════════════════════════════════════════════════════════════
#  GENERALIZED TRAINED MODEL ENGINE
#  Handles TTM (tiny/179M), MTM (mini/0.61B), Mtm (medium/1.075B)
