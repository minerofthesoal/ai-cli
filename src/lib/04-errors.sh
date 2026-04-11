# ============================================================================
# MODULE: 04-errors.sh
# Error code registry + output helpers (err/ok/info/warn/hdr/dim)
# Source lines 396-469 of main-v2.7.3
# ============================================================================


# ════════════════════════════════════════════════════════════════════════════════
#  RECOMMENDED MODELS
# ════════════════════════════════════════════════════════════════════════════════
declare -A RECOMMENDED_MODELS
RECOMMENDED_MODELS=(
  # ── Tiny / CPU-friendly LLMs ──────────────────────────────────────────────
  [1]="Amu/supertiny-llama3-0.25B-v0.1|gguf|0.25B|Supertiny Llama3 — runs on ANY CPU"
  [2]="bartowski/Phi-3.1-mini-128k-instruct-GGUF|gguf|3.8B|Phi-3 Mini 128k context"
  [3]="bartowski/SmolLM2-1.7B-Instruct-GGUF|gguf|1.7B|SmolLM2 — ultra-fast on CPU"
  [4]="bartowski/Qwen2.5-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 1.5B — multilingual tiny"
  [5]="Qwen/Qwen2.5-0.5B-Instruct-GGUF|gguf|0.5B|Qwen2.5 0.5B — smallest usable"
  [6]="bartowski/Llama-3.2-1B-Instruct-GGUF|gguf|1B|Llama 3.2 1B — Meta tiny"
  [7]="bartowski/Llama-3.2-3B-Instruct-GGUF|gguf|3B|Llama 3.2 3B — Meta small"
  [8]="bartowski/gemma-2-2b-it-GGUF|gguf|2B|Gemma 2 2B — Google lightweight"
  # ── General-purpose LLMs (7–9B) ───────────────────────────────────────────
  [9]="TheBloke/Mistral-7B-Instruct-v0.2-GGUF|gguf|7B|Mistral 7B — top general-purpose"
  [10]="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|gguf|8B|Llama 3.1 8B — strong reasoning"
  [11]="Qwen/Qwen2-7B-Instruct-GGUF|gguf|7B|Qwen2 7B — multilingual + coding"
  [12]="bartowski/gemma-2-9b-it-GGUF|gguf|9B|Gemma 2 9B — Google model"
  [13]="bartowski/Qwen2.5-7B-Instruct-GGUF|gguf|7B|Qwen2.5 7B — best 7B 2025"
  [14]="bartowski/Mistral-Nemo-Instruct-2407-GGUF|gguf|12B|Mistral Nemo 12B — long context"
  [15]="bartowski/Phi-3.5-mini-instruct-GGUF|gguf|3.8B|Phi-3.5 Mini — fast instruction"
  [16]="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF|gguf|70B|Llama 3.1 70B — flagship open"
  # ── Coding LLMs ───────────────────────────────────────────────────────────
  [17]="bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|gguf|16B|DeepSeek Coder V2 — code"
  [18]="bartowski/Codestral-22B-v0.1-GGUF|gguf|22B|Codestral 22B — Mistral code model"
  [19]="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF|gguf|7B|Qwen2.5 Coder 7B — top coder"
  [20]="bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF|gguf|1.5B|Qwen2.5 Coder 1.5B — tiny coder"
  [21]="bartowski/starcoder2-7b-GGUF|gguf|7B|StarCoder2 7B — multi-language code"
  [22]="bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|gguf|7B|DeepSeek-R1 7B — reasoning"
  [23]="bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF|gguf|8B|DeepSeek-R1 Llama 8B — reasoning"
  # ── Math / Reasoning LLMs ─────────────────────────────────────────────────
  [24]="bartowski/Qwen2.5-Math-7B-Instruct-GGUF|gguf|7B|Qwen2.5 Math 7B — best open math"
  [25]="bartowski/internlm2_5-7b-chat-GGUF|gguf|7B|InternLM2.5 7B — strong all-rounder"
  [26]="bartowski/Hermes-3-Llama-3.1-8B-GGUF|gguf|8B|Hermes 3 8B — advanced instruction"
  # ── Vision / Multimodal LLMs ──────────────────────────────────────────────
  [27]="Qwen/Qwen2-VL-7B-Instruct|hf|7B|Qwen2-VL 7B — best open vision-language"
  [28]="microsoft/Phi-3.5-vision-instruct|hf|4.2B|Phi-3.5 Vision — small + capable"
  [29]="llava-hf/llava-1.5-7b-hf|hf|7B|LLaVA 1.5 7B — classic vision model"
  [30]="Qwen/Qwen2-VL-2B-Instruct|hf|2B|Qwen2-VL 2B — tiny vision model"
  [31]="llava-hf/llava-v1.6-mistral-7b-hf|hf|7B|LLaVA 1.6 Mistral 7B — better vision"
  # ── Image Generation ──────────────────────────────────────────────────────
  [32]="stabilityai/stable-diffusion-xl-base-1.0|diffusers|SDXL|SDXL 1.0 — high quality"
  [33]="black-forest-labs/FLUX.1-schnell|diffusers|FLUX|FLUX Schnell — fast 4-step"
  [34]="black-forest-labs/FLUX.1-dev|diffusers|FLUX|FLUX Dev — best quality"
  [35]="stabilityai/stable-diffusion-2-1|diffusers|SD2|SD 2.1 — lightweight option"
  [36]="stabilityai/stable-diffusion-3-medium-diffusers|diffusers|SD3|SD 3 Medium — latest SD"
  [37]="stabilityai/sdxl-turbo|diffusers|SDXL-T|SDXL Turbo — real-time image gen"
  # ── Audio / Speech ────────────────────────────────────────────────────────
  [38]="openai/whisper-base|hf|74M|Whisper base — fast speech-to-text"
  [39]="openai/whisper-large-v3|hf|1.5B|Whisper Large v3 — best transcription"
  [40]="suno/bark|hf|TTS|Bark — realistic multi-lingual TTS"
  [41]="openai/whisper-medium|hf|307M|Whisper medium — balanced transcription"
  [42]="facebook/musicgen-small|hf|300M|MusicGen small — AI music generation"
  # ── Embedding / RAG Models ────────────────────────────────────────────────
  [43]="BAAI/bge-small-en-v1.5|hf|33M|BGE small — fast embeddings"
  [44]="BAAI/bge-large-en-v1.5|hf|335M|BGE large — best embeddings"
  [45]="sentence-transformers/all-MiniLM-L6-v2|hf|22M|MiniLM L6 — sentence embeddings"
  [46]="nomic-ai/nomic-embed-text-v1.5|hf|137M|Nomic Embed — long context embeddings"
  # ── Cloud API Models ──────────────────────────────────────────────────────
  [47]="gpt-4o|openai|API|GPT-4o with vision"
  [48]="gpt-4o-mini|openai|API|GPT-4o mini — fast and affordable"
  [49]="gpt-4.5-preview|openai|API|GPT-4.5 Preview — latest OpenAI"
  [50]="claude-sonnet-4-5|claude|API|Claude Sonnet 4.5 — top reasoning"
  [51]="claude-haiku-4-5-20251001|claude|API|Claude Haiku 4.5 — ultra-fast"
  [52]="claude-opus-4-6|claude|API|Claude Opus 4.6 — most capable Claude"
  [53]="gemini-2.0-flash|gemini|API|Gemini 2.0 Flash — Google best"
  [54]="gemini-2.0-flash-lite|gemini|API|Gemini 2.0 Flash Lite — cheapest Gemini"
  [55]="gemini-1.5-pro|gemini|API|Gemini 1.5 Pro — long context 2M"
  [56]="o1-mini|openai|API|OpenAI o1-mini — fast reasoning model"
)

# ════════════════════════════════════════════════════════════════════════════════
