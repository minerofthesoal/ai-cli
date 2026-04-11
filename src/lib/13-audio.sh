# ============================================================================
# MODULE: 13-audio.sh
# Audio: transcribe, TTS, analyze, convert
# Source lines 4228-4437 of main-v2.7.3
# ============================================================================

#  AUDIO SUPPORT
cmd_audio() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    transcribe) _audio_transcribe "$@" ;;
    tts)        _audio_tts "$@" ;;
    analyze)    _audio_analyze "$@" ;;
    convert)    _audio_convert "$@" ;;
    extract)    _audio_extract_from_video "$@" ;;
    ask)        _audio_ask "$@" ;;
    play)       _audio_play "$@" ;;
    info)       _audio_info "$@" ;;
    *)
      echo -e "${B}${BCYAN}Audio Commands${R}"
      echo "  ${B}ai audio transcribe <file> [--lang en] [--model base]${R}"
      echo "  ${B}ai audio tts <text> [--voice nova] [--out file.mp3]${R}"
      echo "  ${B}ai audio analyze <file>${R}      — Analyze audio with AI"
      echo "  ${B}ai audio convert <in> <out>${R}  — Convert format (ffmpeg)"
      echo "  ${B}ai audio extract <video>${R}     — Extract audio from video"
      echo "  ${B}ai audio ask <file> <question>${R} — Ask about audio content"
      echo "  ${B}ai audio play <file>${R}          — Play audio file"
      echo "  ${B}ai audio info <file>${R}          — Show audio metadata"
      ;;
  esac
}

_audio_transcribe() {
  local file="" lang="en" model_size="base" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)  lang="$2"; shift 2 ;;
      --model) model_size="$2"; shift 2 ;;
      --out)   out="$2"; shift 2 ;;
      *)       file="$1"; shift ;;
    esac
  done
  [[ -z "$file" ]] && { err "Usage: ai audio transcribe <file>"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }

  # Try OpenAI Whisper API first
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    info "Transcribing with OpenAI Whisper API..."
    local result
    result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F "file=@$file" \
      -F "model=whisper-1" \
      -F "language=$lang" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null)
    if [[ -n "$result" ]]; then
      echo "$result"
      if [[ -n "$out" ]]; then
        echo "$result" > "$out"; ok "Saved to $out"
      fi
      return 0
    fi
  fi

  # Fallback: local whisper
  [[ -z "$PYTHON" ]] && { err "Python not found"; return 1; }
  info "Transcribing with local Whisper (model: $model_size)..."
  local result
  result=$(AUDIO_FILE="$file" WHISPER_MODEL="$model_size" WHISPER_LANG="$lang" \
    "$PYTHON" - <<'PYEOF'
import os, sys
try:
    import whisper
except ImportError:
    try:
        import openai_whisper as whisper
    except ImportError:
        print("ERROR: whisper not installed. Run: pip install openai-whisper --break-system-packages")
        sys.exit(1)
f = os.environ['AUDIO_FILE']
m = os.environ.get('WHISPER_MODEL','base')
l = os.environ.get('WHISPER_LANG','en')
model = whisper.load_model(m)
result = model.transcribe(f, language=l)
print(result['text'])
PYEOF
  )
  if [[ -n "$result" ]]; then
    echo "$result"
    [[ -n "$out" ]] && { echo "$result" > "$out"; ok "Saved to $out"; }
  fi
}

_audio_tts() {
  local text="" voice="nova" out="" speed="1.0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --voice) voice="$2"; shift 2 ;;
      --out)   out="$2"; shift 2 ;;
      --speed) speed="$2"; shift 2 ;;
      *)       text="${text}${text:+ }$1"; shift ;;
    esac
  done
  [[ -z "$text" ]] && { read -rp "Text: " text; }
  [[ -z "$text" ]] && { err "No text provided"; return 1; }

  if [[ -z "$out" ]]; then
    out="$AUDIO_DIR/tts_$(date +%Y%m%d_%H%M%S).mp3"
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    info "Generating TTS with OpenAI (voice: $voice)..."
    curl -sS https://api.openai.com/v1/audio/speech \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"tts-1\",\"input\":$(echo "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))'),\"voice\":\"$voice\",\"speed\":$speed}" \
      --output "$out"
    ok "Saved to $out"
    _audio_play "$out"
  else
    # Fallback: pyttsx3 or espeak
    if "$PYTHON" -c "import pyttsx3" 2>/dev/null; then
      SPEAK_TEXT="$text" SPEAK_OUT="$out" "$PYTHON" - <<'PYEOF'
import os, pyttsx3
engine = pyttsx3.init()
engine.save_to_file(os.environ['SPEAK_TEXT'], os.environ['SPEAK_OUT'])
engine.runAndWait()
print(f"Saved to {os.environ['SPEAK_OUT']}")
PYEOF
    elif command -v espeak &>/dev/null; then
      espeak "$text" -w "$out"
      ok "Saved to $out"
    else
      err "No TTS backend. Set OPENAI_API_KEY or install: pip install pyttsx3 --break-system-packages"
      return 1
    fi
  fi
}

_audio_analyze() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "Usage: ai audio analyze <file>"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }

  # First transcribe, then analyze with AI
  info "Transcribing for analysis..."
  local transcript; transcript=$(_audio_transcribe "$file" 2>/dev/null)
  [[ -z "$transcript" ]] && { err "Could not transcribe audio"; return 1; }

  local prompt="Analyze this audio transcript. Provide: 1) Summary, 2) Key topics, 3) Sentiment, 4) Notable quotes.

Transcript:
$transcript"
  dispatch_ask "$prompt"
}

_audio_convert() {
  local input="${1:-}"; local output="${2:-}"
  [[ -z "$input" || -z "$output" ]] && { err "Usage: ai audio convert <input> <output>"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg not installed"; return 1; }
  ffmpeg -i "$input" "$output" && ok "Converted: $output"
}

_audio_extract_from_video() {
  local video="${1:-}"; local out="${2:-}"
  [[ -z "$video" ]] && { err "Usage: ai audio extract <video> [output.mp3]"; return 1; }
  [[ ! -f "$video" ]] && { err "File not found: $video"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  [[ -z "$out" ]] && out="$AUDIO_DIR/$(basename "$video" | sed 's/\.[^.]*$//').mp3"
  ffmpeg -i "$video" -q:a 0 -map a "$out" -y
  ok "Audio extracted to: $out"
}

_audio_ask() {
  local file="${1:-}"; shift
  local question="$*"
  [[ -z "$file" || -z "$question" ]] && { err "Usage: ai audio ask <file> <question>"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  info "Transcribing..."
  local transcript; transcript=$(_audio_transcribe "$file" 2>/dev/null)
  local prompt="Audio transcript:
$transcript

Question: $question"
  dispatch_ask "$prompt"
}

_audio_play() {
  local file="${1:-}"; [[ -z "$file" ]] && return 0
  for player in mpv vlc aplay paplay afplay; do
    command -v "$player" &>/dev/null && { "$player" "$file" &>/dev/null & return 0; }
  done
  warn "No audio player found (install mpv)"
}

_audio_info() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "File required"; return 1; }
  [[ ! -f "$file" ]] && { err "Not found: $file"; return 1; }
  if command -v ffprobe &>/dev/null; then
    ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
fmt=d.get('format',{})
print(f\"File:     {fmt.get('filename','?')}\")
print(f\"Duration: {float(fmt.get('duration',0)):.1f}s\")
print(f\"Size:     {int(fmt.get('size',0))//1024} KB\")
print(f\"Bitrate:  {int(fmt.get('bit_rate',0))//1000} kbps\")
for s in d.get('streams',[]):
    print(f\"Stream:   {s.get('codec_type','?')} / {s.get('codec_name','?')} / {s.get('sample_rate','?')}Hz\")
" 2>/dev/null
  else
    ls -lh "$file"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#  VIDEO SUPPORT
