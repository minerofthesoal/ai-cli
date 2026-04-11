# ============================================================================
# MODULE: 14-video.sh
# Video: info, transcribe, caption, frames, trim, analyze
# Source lines 4437-4612 of main-v2.7.3
# ============================================================================

#  VIDEO SUPPORT
# ════════════════════════════════════════════════════════════════════════════════
cmd_video() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    analyze)   _video_analyze "$@" ;;
    transcribe) _video_transcribe "$@" ;;
    caption)   _video_caption "$@" ;;
    convert)   _video_convert "$@" ;;
    extract)   _video_extract_frames "$@" ;;
    ask)       _video_ask "$@" ;;
    trim)      _video_trim "$@" ;;
    info)      _video_info "$@" ;;
    summary)   _video_summary "$@" ;;
    *)
      echo -e "${B}${BCYAN}Video Commands${R}"
      echo "  ${B}ai video analyze <file>${R}          — Analyze video content with AI"
      echo "  ${B}ai video transcribe <file>${R}       — Transcribe video audio"
      echo "  ${B}ai video caption <file>${R}          — Generate captions/subtitles (.srt)"
      echo "  ${B}ai video convert <in> <out>${R}      — Convert video format"
      echo "  ${B}ai video extract <file> [fps]${R}    — Extract frames"
      echo "  ${B}ai video ask <file> <question>${R}   — Ask about video"
      echo "  ${B}ai video trim <in> <start> <end> <out>${R}"
      echo "  ${B}ai video info <file>${R}             — Show video metadata"
      echo "  ${B}ai video summary <file>${R}          — AI summary of video"
      ;;
  esac
}

_video_info() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "File required"; return 1; }
  command -v ffprobe &>/dev/null || { err "ffmpeg/ffprobe required"; return 1; }
  ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null | \
    python3 -c "
import json,sys
d=json.load(sys.stdin)
fmt=d.get('format',{})
print(f\"File:     {fmt.get('filename','?')}\")
dur=float(fmt.get('duration',0))
print(f\"Duration: {int(dur//60)}m {dur%60:.1f}s\")
print(f\"Size:     {int(fmt.get('size',0))//1024//1024} MB\")
print(f\"Bitrate:  {int(fmt.get('bit_rate',0))//1000} kbps\")
for s in d.get('streams',[]):
    if s.get('codec_type')=='video':
        print(f\"Video:    {s.get('codec_name')} {s.get('width')}x{s.get('height')} @ {s.get('r_frame_rate','?')} fps\")
    elif s.get('codec_type')=='audio':
        print(f\"Audio:    {s.get('codec_name')} {s.get('sample_rate','?')}Hz {s.get('channel_layout','?')}\")
" 2>/dev/null
}

_video_transcribe() {
  local file="${1:-}"; shift
  [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  info "Extracting audio..."
  local tmp_audio; tmp_audio=$(mktemp /tmp/vid_audio_XXXX.mp3)
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$file" -q:a 0 -map a "$tmp_audio" -y &>/dev/null
  info "Transcribing..."
  _audio_transcribe "$tmp_audio" "$@"
  rm -f "$tmp_audio"
}

_video_caption() {
  local file="${1:-}"; [[ -z "$file" ]] && { err "Video file required"; return 1; }
  local out_srt="${file%.*}.srt"
  info "Generating captions for: $file"

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local tmp; tmp=$(mktemp /tmp/vid_XXXX.mp3)
    ffmpeg -i "$file" -q:a 0 -map a "$tmp" -y &>/dev/null
    local result
    result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F "file=@$tmp" -F "model=whisper-1" -F "response_format=srt" 2>/dev/null)
    rm -f "$tmp"
    echo "$result" > "$out_srt"
    ok "Captions saved: $out_srt"
  else
    err "OpenAI API key required for caption generation (provides word-level timestamps)"
  fi
}

_video_extract_frames() {
  local file="${1:-}"; local fps="${2:-1}"
  [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  local out_dir="$VIDEO_DIR/frames_$(basename "$file" | sed 's/\.[^.]*$//')_$(date +%H%M%S)"
  mkdir -p "$out_dir"
  ffmpeg -i "$file" -vf "fps=$fps" "$out_dir/frame_%04d.jpg" -y &>/dev/null
  local count; count=$(ls "$out_dir"/*.jpg 2>/dev/null | wc -l)
  ok "Extracted $count frames to $out_dir"
}

_video_trim() {
  local input="${1:-}"; local start="${2:-}"; local end="${3:-}"; local output="${4:-}"
  [[ -z "$input" || -z "$start" || -z "$end" ]] && {
    err "Usage: ai video trim <input> <start> <end> [output]"
    err "Example: ai video trim video.mp4 00:01:00 00:02:30 clip.mp4"
    return 1
  }
  [[ -z "$output" ]] && output="$VIDEO_DIR/trim_$(basename "$input")"
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$input" -ss "$start" -to "$end" -c copy "$output" -y
  ok "Trimmed video: $output"
}

_video_convert() {
  local input="${1:-}"; local output="${2:-}"
  [[ -z "$input" || -z "$output" ]] && { err "Usage: ai video convert <input> <output>"; return 1; }
  command -v ffmpeg &>/dev/null || { err "ffmpeg required"; return 1; }
  ffmpeg -i "$input" "$output" && ok "Converted: $output"
}

_video_analyze() {
  local file="${1:-}"; [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  info "Analyzing video: $file"
  _video_info "$file"
  echo ""
  info "Transcribing audio for analysis..."
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)

  # Extract a few frames and describe them if vision model available
  local frame_desc=""
  if command -v ffmpeg &>/dev/null && [[ -n "${OPENAI_API_KEY:-}" ]]; then
    local tmpdir; tmpdir=$(mktemp -d /tmp/vid_frames_XXXX)
    ffmpeg -i "$file" -vf "fps=0.1" -vframes 3 "$tmpdir/frame_%02d.jpg" -y &>/dev/null
    local first_frame="$tmpdir/frame_01.jpg"
    if [[ -f "$first_frame" ]]; then
      info "Analyzing key frame with vision model..."
      local b64; b64=$(base64 -w0 < "$first_frame" 2>/dev/null || base64 < "$first_frame" 2>/dev/null)
      frame_desc=$(curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$b64\"}},{\"type\":\"text\",\"text\":\"Briefly describe what you see in this video frame.\"}]}],\"max_tokens\":200}" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
    fi
    rm -rf "$tmpdir"
  fi

  local prompt="Analyze this video content comprehensively.

${frame_desc:+Visual description of key frame:
$frame_desc

}${transcript:+Audio transcript:
$transcript

}Provide: 1) Overall summary, 2) Key topics/themes, 3) Sentiment/tone, 4) Notable moments."

  dispatch_ask "$prompt"
}

_video_ask() {
  local file="${1:-}"; shift
  local question="$*"
  [[ -z "$file" || -z "$question" ]] && { err "Usage: ai video ask <file> <question>"; return 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; return 1; }
  info "Processing video for question answering..."
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)
  local prompt="Video content:
${transcript:-[No audio/transcript available]}

Question: $question"
  dispatch_ask "$prompt"
}

_video_summary() {
  local file="${1:-}"; [[ -z "$file" || ! -f "$file" ]] && { err "Video file required"; return 1; }
  local transcript; transcript=$(_video_transcribe "$file" 2>/dev/null)
  dispatch_ask "Summarize this video content in 3-5 sentences:
$transcript"
}

# ════════════════════════════════════════════════════════════════════════════════
#  IMAGE-TEXT-TO-TEXT (Full vision support)
# ════════════════════════════════════════════════════════════════════════════════
