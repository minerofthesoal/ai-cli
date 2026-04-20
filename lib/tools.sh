#!/usr/bin/env bash
# Return if sourced before config is loaded
[[ -z "${VERSION:-}" ]] && return 0 2>/dev/null || true
# AI CLI v3.1.0 — Tools module
# test, health, perf, cost, tokens, analytics, cleanup, security

cmd_test() {
  local mode="${1:--A}"
  case "$mode" in
    -S|speed)
      hdr "Speed Test"
      [[ -z "$ACTIVE_MODEL" && -z "$ACTIVE_BACKEND" ]] && { err "No model set"; return 1; }
      local start=$(date +%s%3N) out=$(_silent_generate "Count from 1 to 50" 64 2>/dev/null) end=$(date +%s%3N)
      local ms=$(( end - start )) words=$(echo "$out" | wc -w)
      (( ms > 0 && words > 0 )) && printf "  ${GREEN}%.1f tok/s${R} (%d ms)\n" "$(awk "BEGIN{print $words/($ms/1000.0)}")" "$ms" || err "No output" ;;
    -N|network)
      hdr "Network Test"
      local ping_ms; ping_ms=$(ping -c 3 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "?")
      printf "  Latency:  %s ms\n" "$ping_ms"
      local s=$(date +%s%N); curl -fsSL "https://speed.cloudflare.com/__down?bytes=5000000" -o /dev/null 2>/dev/null; local e=$(date +%s%N)
      local ms=$(( (e - s) / 1000000 )); (( ms > 0 )) && printf "  Download: %.1f Mbps\n" "$(awk "BEGIN{print 5*8/($ms/1000.0)}")" ;;
    -A|all) cmd_test -S; echo ""; cmd_test -N ;;
    *) echo "Usage: ai test <-S|-N|-A>" ;;
  esac
}

cmd_health() {
  hdr "Health Check"
  local issues=0
  (( BASH_VERSINFO[0] >= 4 )) && printf "  ${GREEN}[OK]${R}  Bash %s\n" "$BASH_VERSION" || { printf "  ${RED}[!!]${R}  Bash %s (need 4+)\n" "$BASH_VERSION"; (( issues++ )); }
  [[ -n "$PYTHON" ]] && printf "  ${GREEN}[OK]${R}  %s\n" "$($PYTHON --version 2>&1)" || { printf "  ${RED}[!!]${R}  Python not found\n"; (( issues++ )); }
  command -v curl &>/dev/null && printf "  ${GREEN}[OK]${R}  curl\n" || { printf "  ${RED}[!!]${R}  curl missing\n"; (( issues++ )); }
  command -v git &>/dev/null && printf "  ${GREEN}[OK]${R}  git\n" || printf "  ${YELLOW}[--]${R}  git missing\n"
  echo ""
  [[ "$CUDA_ARCH" == "metal" ]] && printf "  ${GREEN}[OK]${R}  Metal GPU\n"
  [[ "$CUDA_ARCH" != "0" && "$CUDA_ARCH" != "metal" && -n "$CUDA_ARCH" ]] && printf "  ${GREEN}[OK]${R}  CUDA sm_%s\n" "$CUDA_ARCH"
  [[ "$CUDA_ARCH" == "0" || -z "$CUDA_ARCH" ]] && printf "  ${YELLOW}[--]${R}  CPU-only\n"
  [[ -n "$LLAMA_BIN" ]] && printf "  ${GREEN}[OK]${R}  llama.cpp\n" || printf "  ${YELLOW}[--]${R}  llama.cpp missing\n"
  echo ""
  for k in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GROQ_API_KEY MISTRAL_API_KEY TOGETHER_API_KEY; do
    local v; v=$(eval "echo \"\${$k:-}\"")
    [[ -n "$v" ]] && printf "  ${GREEN}[OK]${R}  %s\n" "$k" || printf "  ${DIM}[--]${R}  %s\n" "$k"
  done
  echo ""; (( issues > 0 )) && warn "$issues issue(s)" || ok "All checks passed"
}

cmd_count_tokens() {
  local input="${*:-}"
  [[ -z "$input" && -f "${1:-}" ]] && input=$(cat "$1")
  [[ -z "$input" && ! -t 0 ]] && input=$(cat)
  [[ -z "$input" ]] && { echo "Usage: ai tokens \"text\" | ai tokens <file>"; return 1; }
  local chars=${#input} words=$(echo "$input" | wc -w)
  local est=$(( chars * 100 / 400 ))
  printf "  Chars: %s | Words: %s | ~%s tokens\n" "$chars" "$words" "$est"
  (( est > CONTEXT_SIZE )) && warn "Exceeds context ($CONTEXT_SIZE)" || ok "Fits ($est/$CONTEXT_SIZE)"
}

cmd_cost() {
  local in_tok="${1:-1000}" out_tok="${2:-$MAX_TOKENS}"
  hdr "Cost Estimate (${in_tok} in + ${out_tok} out tokens)"
  printf "  %-20s %10s\n" "Model" "Cost"
  for m in "gpt-4o:2.5:10" "gpt-4o-mini:0.15:0.6" "claude-sonnet:3:15" "claude-opus:15:75" "gemini-flash:0.075:0.3" "groq-llama:0.59:0.79" "mistral-large:4:12"; do
    IFS=: read -r name inp outp <<< "$m"
    local cost=$(awk "BEGIN{printf \"%.6f\", ($in_tok*$inp + $out_tok*$outp)/1000000}")
    printf "  %-20s \$%s\n" "$name" "$cost"
  done
  echo ""; info "Local GGUF: \$0.00"
}

cmd_analytics() {
  local sub="${1:-summary}"
  case "$sub" in
    summary)
      hdr "Usage Analytics"
      [[ ! -s "$ANALYTICS_FILE" ]] && { info "No data yet"; return; }
      local total=$(wc -l < "$ANALYTICS_FILE")
      printf "  Total requests: %s\n" "$total" ;;
    clear) > "$ANALYTICS_FILE"; ok "Cleared" ;;
    *) echo "Usage: ai analytics <summary|clear>" ;;
  esac
}

cmd_cleanup() {
  hdr "Cleanup"
  local dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
  local tmp_count=$(find /tmp -name "ai-cli-*" -o -name "ai_gui_*" 2>/dev/null | wc -l)
  (( tmp_count > 0 )) && { printf "  Temp files: %d\n" "$tmp_count"; (( dry == 0 )) && rm -rf /tmp/ai-cli-* /tmp/ai_gui_* 2>/dev/null; }
  local old_batch=$(find "$BATCH_DIR" -name "*.out" -mtime +7 2>/dev/null | wc -l)
  (( old_batch > 0 )) && { printf "  Old batch: %d\n" "$old_batch"; (( dry == 0 )) && find "$BATCH_DIR" -name "*.out" -mtime +7 -delete 2>/dev/null; }
  (( dry == 1 )) && info "[dry-run]" || ok "Done"
}

cmd_security() {
  hdr "Security Audit"
  local issues=0
  if [[ -f "$KEYS_FILE" ]]; then
    local perms; perms=$(stat -c%a "$KEYS_FILE" 2>/dev/null || stat -f%Lp "$KEYS_FILE" 2>/dev/null || echo "?")
    [[ "$perms" == "600" ]] && printf "  ${GREEN}[OK]${R}  keys.env: %s\n" "$perms" || { printf "  ${RED}[!!]${R}  keys.env: %s (should be 600)\n" "$perms"; (( issues++ )); }
  fi
  local hist="${HISTFILE:-$HOME/.bash_history}"
  if [[ -f "$hist" ]]; then
    local exposed=$(grep -ciE 'sk-[a-zA-Z0-9]{20,}' "$hist" 2>/dev/null || echo 0)
    (( exposed > 0 )) && { printf "  ${RED}[!!]${R}  %d key(s) in shell history\n" "$exposed"; (( issues++ )); } || printf "  ${GREEN}[OK]${R}  No keys in history\n"
  fi
  (( issues > 0 )) && warn "$issues issue(s)" || ok "All clear"
}
