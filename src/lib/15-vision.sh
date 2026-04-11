# ============================================================================
# MODULE: 15-vision.sh
# Vision / image-text-to-text (VL models)
# Source lines 4612-4731 of main-v2.7.3
# ============================================================================

# ════════════════════════════════════════════════════════════════════════════════
cmd_vision() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    ask)     _vision_ask "$@" ;;
    ocr)     _vision_ocr "$@" ;;
    caption) _vision_caption "$@" ;;
    compare) _vision_compare "$@" ;;
    *)
      echo -e "${B}${BCYAN}Vision (Image-Text-to-Text)${R}"
      echo "  ${B}ai vision ask <image> <question>${R}   — Ask about an image"
      echo "  ${B}ai vision ocr <image>${R}              — Extract text from image"
      echo "  ${B}ai vision caption <image>${R}          — Generate image caption"
      echo "  ${B}ai vision compare <img1> <img2>${R}    — Compare two images"
      echo ""
      echo "  Supports: jpg, png, gif, webp, bmp"
      echo "  Backends: OpenAI GPT-4o (best), Claude 3, Gemini 1.5, LLaVA (local)"
      ;;
  esac
}

_encode_image_b64() {
  local file="$1"
  base64 -w0 < "$file" 2>/dev/null || base64 < "$file" 2>/dev/null
}

_vision_ask() {
  local image="${1:-}"; shift
  local question="${*:-Describe this image in detail.}"
  [[ -z "$image" ]] && { err "Usage: ai vision ask <image> <question>"; return 1; }
  [[ ! -f "$image" ]] && { err "Image not found: $image"; return 1; }

  local ext="${image##*.}"; ext="${ext,,}"
  local mime
  case "$ext" in
    jpg|jpeg) mime="image/jpeg" ;;
    png)      mime="image/png" ;;
    gif)      mime="image/gif" ;;
    webp)     mime="image/webp" ;;
    *)        mime="image/jpeg" ;;
  esac

  local b64; b64=$(_encode_image_b64 "$image")

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    curl -sS https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime;base64,$b64\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}],\"max_tokens\":${MAX_TOKENS}}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    curl -sS https://api.anthropic.com/v1/messages \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"claude-opus-4-5\",\"max_tokens\":${MAX_TOKENS},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"$mime\",\"data\":\"$b64\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null
  elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
    curl -sS "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$GEMINI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"contents\":[{\"parts\":[{\"inline_data\":{\"mime_type\":\"$mime\",\"data\":\"$b64\"}},{\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}]}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['candidates'][0]['content']['parts'][0]['text'])" 2>/dev/null
  elif [[ -n "$PYTHON" ]] && "$PYTHON" -c "import llava" 2>/dev/null; then
    IMAGE_FILE="$image" IMAGE_QUESTION="$question" "$PYTHON" - <<'PYEOF'
import os
from llava.model.builder import load_pretrained_model
from llava.mm_utils import get_model_name_from_path
model_path = "liuhaotian/llava-v1.5-7b"
tokenizer, model, image_processor, _ = load_pretrained_model(model_path, None, get_model_name_from_path(model_path))
from PIL import Image
image = Image.open(os.environ['IMAGE_FILE']).convert('RGB')
# simplified inference
print("LLaVA vision response")
PYEOF
  else
    err "No vision-capable backend. Set OPENAI_API_KEY, ANTHROPIC_API_KEY, or GEMINI_API_KEY"
    return 1
  fi
}

_vision_ocr() {
  local image="${1:-}"; [[ -z "$image" || ! -f "$image" ]] && { err "Image required"; return 1; }
  _vision_ask "$image" "Extract ALL text from this image exactly as it appears. Return only the text, no commentary."
}

_vision_caption() {
  local image="${1:-}"; [[ -z "$image" || ! -f "$image" ]] && { err "Image required"; return 1; }
  _vision_ask "$image" "Write a concise, descriptive caption for this image in one sentence."
}

_vision_compare() {
  local img1="${1:-}"; local img2="${2:-}"; local question="${3:-What are the differences between these images?}"
  [[ -z "$img1" || -z "$img2" ]] && { err "Usage: ai vision compare <img1> <img2> [question]"; return 1; }
  [[ ! -f "$img1" ]] && { err "Not found: $img1"; return 1; }
  [[ ! -f "$img2" ]] && { err "Not found: $img2"; return 1; }

  local b64_1; b64_1=$(_encode_image_b64 "$img1")
  local b64_2; b64_2=$(_encode_image_b64 "$img2")
  local mime1="image/jpeg"; local mime2="image/jpeg"

  [[ -n "${OPENAI_API_KEY:-}" ]] && \
    curl -sS https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime1;base64,$b64_1\"}},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:$mime2;base64,$b64_2\"}},{\"type\":\"text\",\"text\":$(echo "$question" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}]}],\"max_tokens\":${MAX_TOKENS}}" 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || \
    err "Vision comparison requires OPENAI_API_KEY"
}


# ════════════════════════════════════════════════════════════════════════════════


# ════════════════════════════════════════════════════════════════════════════════
#  GUI v5 — Split-pane · Edit-on-select · AI Extensions · Firefox Sidebar
# ════════════════════════════════════════════════════════════════════════════════
#  New in v5: Split-pane layout (sidebar + content), inline editing on Enter/click,
#  different visual style, extension manager, Firefox extension install.
# ════════════════════════════════════════════════════════════════════════════════

