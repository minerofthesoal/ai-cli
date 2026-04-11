# ============================================================================
# MODULE: 29-multiai.sh
# Multi-AI chat arena + cmd_serve
# Source lines 10753-11086 of main-v2.7.3
# ============================================================================

#  MULTI-AI CHAT ARENA  (v2.4.5)
#  Two or more AI agents discuss a topic; user watches, steers, rates, or stops.
#  If MULTIAI_RLHF_TRAIN=1, rated exchanges update model weights automatically.
#  Conversation is saved as a custom dataset (for later fine-tuning).
#
#  ai multiai "<topic>" [opts]
#  ai multiai debate  "<topic>"    — adversarial: agents take opposing sides
#  ai multiai collab  "<task>"     — collaborative: agents build on each other
#  ai multiai brainstorm "<topic>" — free-form: each agent adds new ideas
#
#  Options:
#    --agents N          Number of agents (2-4, default 2)
#    --rounds N          Conversation rounds (default 6)
#    --model1 <id>       Agent 1 backend/model (default: active model/backend)
#    --model2 <id>       Agent 2 backend/model
#    --no-save           Don't save as dataset
#    --no-train          Don't trigger RLHF training even if enabled
#    --quiet             Minimal output (no banners/prompts)
#
#  During conversation (interactive controls):
#    Enter              — let agents continue
#    s <guidance>       — steer: inject your guidance into next prompt
#    r <1-5>            — rate last exchange (feeds RLHF if enabled)
#    p                  — pause / resume
#    q / Ctrl+C         — stop and save
# ════════════════════════════════════════════════════════════════════════════════
cmd_multiai() {
  local sub="${1:-help}"
  # Detect mode vs topic
  local mode="discuss"
  case "$sub" in
    debate|collab|brainstorm|discuss) mode="$sub"; shift ;;
    help|-h|--help) _multiai_help; return ;;
    *) : ;; # treat first arg as the topic directly
  esac

  # Parse options
  local topic="" n_agents=2 rounds="$MULTIAI_ROUNDS" quiet=0
  local model1="" model2="" model3="" model4=""
  local do_save="$MULTIAI_SAVE_DATASET" do_train="$MULTIAI_RLHF_TRAIN"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents)   n_agents="$2"; shift 2 ;;
      --rounds)   rounds="$2"; shift 2 ;;
      --model1)   model1="$2"; shift 2 ;;
      --model2)   model2="$2"; shift 2 ;;
      --model3)   model3="$2"; shift 2 ;;
      --model4)   model4="$2"; shift 2 ;;
      --no-save)  do_save=0; shift ;;
      --no-train) do_train=0; shift ;;
      --quiet)    quiet=1; shift ;;
      --) shift; topic="$*"; break ;;
      -*) shift ;;
      *) topic="${topic:+$topic }$1"; shift ;;
    esac
  done

  [[ -z "$topic" ]] && { _multiai_help; return 1; }
  (( n_agents < 2 )) && n_agents=2
  (( n_agents > 4 )) && n_agents=4

  # Build agent configs (backend|model|persona)
  local -a AGENT_BACKENDS AGENT_MODELS AGENT_LABELS AGENT_COLORS AGENT_PERSONAS
  local _ab="${ACTIVE_BACKEND:-}" _am="${ACTIVE_MODEL:-}"
  AGENT_BACKENDS=("$_ab" "$_ab" "$_ab" "$_ab")
  AGENT_MODELS=("$_am" "$_am" "$_am" "$_am")
  [[ -n "$model1" ]] && AGENT_MODELS[0]="$model1"
  [[ -n "$model2" ]] && AGENT_MODELS[1]="$model2"
  [[ -n "$model3" ]] && AGENT_MODELS[2]="$model3"
  [[ -n "$model4" ]] && AGENT_MODELS[3]="$model4"
  AGENT_LABELS=("Agent-Alpha" "Agent-Beta" "Agent-Gamma" "Agent-Delta")
  AGENT_COLORS=("$BCYAN" "$BYELLOW" "$BMAGENTA" "$BGREEN")

  # Build system prompts based on mode
  local topic_clean="${topic//\"/\'}"
  case "$mode" in
    debate)
      AGENT_PERSONAS=(
        "You are Agent-Alpha in a debate about: ${topic_clean}. Argue STRONGLY in FAVOR. Be direct, use evidence, challenge opposing points. Keep responses under 120 words."
        "You are Agent-Beta in a debate about: ${topic_clean}. Argue STRONGLY AGAINST. Be direct, use evidence, challenge opposing points. Keep responses under 120 words."
        "You are Agent-Gamma, a critical analyst in the debate about: ${topic_clean}. Find flaws in BOTH sides. Keep responses under 120 words."
        "You are Agent-Delta, a moderator. Summarize points made and ask a probing question. Keep responses under 80 words."
      )
      ;;
    collab)
      AGENT_PERSONAS=(
        "You are Agent-Alpha collaborating on: ${topic_clean}. Build directly on what others say. Add concrete ideas. Keep responses under 120 words."
        "You are Agent-Beta collaborating on: ${topic_clean}. Extend and improve ideas from others. Be specific and practical. Keep responses under 120 words."
        "You are Agent-Gamma collaborating on: ${topic_clean}. Identify gaps and suggest solutions. Keep responses under 120 words."
        "You are Agent-Delta collaborating on: ${topic_clean}. Synthesize ideas and propose next steps. Keep responses under 100 words."
      )
      ;;
    brainstorm)
      AGENT_PERSONAS=(
        "You are Agent-Alpha brainstorming: ${topic_clean}. Generate wild, creative ideas. Each turn add 2-3 NEW ideas not yet mentioned. Under 100 words."
        "You are Agent-Beta brainstorming: ${topic_clean}. Build on Alpha's ideas and add your own twists. Under 100 words."
        "You are Agent-Gamma brainstorming: ${topic_clean}. Challenge assumptions, suggest unexpected angles. Under 100 words."
        "You are Agent-Delta brainstorming: ${topic_clean}. Pick the most promising ideas and push them further. Under 100 words."
      )
      ;;
    *)
      AGENT_PERSONAS=(
        "You are Agent-Alpha discussing: ${topic_clean}. Share your perspective thoughtfully. Engage with what others say. Under 120 words."
        "You are Agent-Beta discussing: ${topic_clean}. Offer a different angle or nuance. Respond to previous points. Under 120 words."
        "You are Agent-Gamma discussing: ${topic_clean}. Ask probing questions and add depth. Under 100 words."
        "You are Agent-Delta discussing: ${topic_clean}. Synthesize and find common ground. Under 100 words."
      )
      ;;
  esac

  # Header
  if [[ $quiet -eq 0 ]]; then
    echo ""
    echo -e "${B}${BWHITE}╔══════════════════════════════════════════════════════════╗${R}"
    printf "${B}${BWHITE}║  Multi-AI Arena  %-42s║${R}\n" "v2.4.5"
    echo -e "${B}${BWHITE}╚══════════════════════════════════════════════════════════╝${R}"
    echo ""
    printf "  ${B}Topic:${R}   %s\n" "$topic"
    printf "  ${B}Mode:${R}    %s\n" "$mode"
    printf "  ${B}Agents:${R}  %d  |  ${B}Rounds:${R} %d\n" "$n_agents" "$rounds"
    for (( i=0; i<n_agents; i++ )); do
      printf "  ${B}${AGENT_COLORS[$i]}%s${R}: %s\n" \
        "${AGENT_LABELS[$i]}" "${AGENT_PERSONAS[$i]:0:80}..."
    done
    echo ""
    echo -e "  ${DIM}Controls: [Enter]=continue  [s <text>]=steer  [r <1-5>]=rate  [p]=pause  [q]=quit${R}"
    echo ""
  fi

  # Conversation state
  local -a HISTORY       # full conversation as text
  local -a EXCHANGE_LOG  # for RLHF + dataset: {round, agent, prompt, response}
  local last_exchange_prompt="" last_exchange_response="" last_agent=""
  local steer_msg="" paused=0 round=0 total_rated=0

  # Opening prompt for round 1
  local opening="The topic is: $topic. Please give your opening statement or perspective."

  _multiai_ask() {
    local agent_idx=$1 user_prompt="$2"
    local backend="${AGENT_BACKENDS[$agent_idx]}"
    local model="${AGENT_MODELS[$agent_idx]}"
    local persona="${AGENT_PERSONAS[$agent_idx]}"
    local label="${AGENT_LABELS[$agent_idx]}"

    # Build context: system prompt + recent history (last 6 turns)
    local context_lines="${#HISTORY[@]}"
    local start_idx=$(( context_lines > 6 ? context_lines - 6 : 0 ))
    local context=""
    for (( ci=start_idx; ci<context_lines; ci++ )); do
      context="${context}${HISTORY[$ci]}"$'\n'
    done

    local full_prompt="${context}${label}: "
    if [[ -n "$steer_msg" ]]; then
      full_prompt="[User guidance: ${steer_msg}] ${full_prompt}"
    fi
    full_prompt="${full_prompt}${user_prompt}"

    # Use dispatch_ask with system override
    local response
    response=$(AI_SYSTEM_OVERRIDE="$persona" dispatch_ask "$full_prompt" 2>/dev/null)
    echo "$response"
  }

  # Main conversation loop
  while (( round < rounds )); do
    (( round++ ))

    for (( agent=0; agent<n_agents; agent++ )); do
      [[ $paused -eq 1 ]] && { read -rp "  [paused — press Enter to resume, q to quit] " _r; [[ "$_r" == "q" ]] && break 2; paused=0; }

      local label="${AGENT_LABELS[$agent]}"
      local color="${AGENT_COLORS[$agent]}"

      # Build prompt from context
      local turn_prompt
      if (( round == 1 && agent == 0 )); then
        turn_prompt="$opening"
      elif (( ${#HISTORY[@]} > 0 )); then
        # Reply to previous agent's last message
        local prev_idx=$(( agent == 0 ? n_agents - 1 : agent - 1 ))
        turn_prompt="Respond to ${AGENT_LABELS[$prev_idx]}'s last point and continue the discussion."
      else
        turn_prompt="$opening"
      fi

      # Apply steering if set
      if [[ -n "$steer_msg" ]]; then
        turn_prompt="[User steers: $steer_msg] $turn_prompt"
      fi

      printf "\r  ${B}${color}%s${R} [round %d/%d] thinking..." "$label" "$round" "$rounds"

      local response
      response=$(_multiai_ask "$agent" "$turn_prompt" 2>/dev/null)
      steer_msg=""  # consume steering after first use

      # Display response
      printf "\r  ${B}${color}%s${R} [%d/%d]:${R}\n" "$label" "$round" "$rounds"
      echo "$response" | fold -sw 78 | sed 's/^/    /'
      echo ""

      # Record
      local hist_entry="${label}: ${response}"
      HISTORY+=("$hist_entry")
      EXCHANGE_LOG+=("$(printf '{"round":%d,"agent":"%s","response":%s}' \
        "$round" "$label" "$(echo "$response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '"..."')")")
      last_exchange_prompt="$turn_prompt"
      last_exchange_response="$response"
      last_agent="$label"

      # User control prompt (non-blocking with timeout)
      if [[ $quiet -eq 0 ]]; then
        local user_input=""
        IFS= read -r -t 0.1 user_input 2>/dev/null || true
        if [[ -z "$user_input" ]] && (( agent == n_agents - 1 )); then
          # End of round: give user a chance to act
          printf "  ${DIM}[Enter]=continue  [s text]=steer  [r 1-5]=rate  [p]=pause  [q]=quit:${R} "
          IFS= read -r user_input 2>/dev/null || true
        fi
        if [[ -n "$user_input" ]]; then
          case "${user_input:0:1}" in
            q|Q) echo ""; info "Stopping."; break 2 ;;
            p|P) paused=1 ;;
            s|S) steer_msg="${user_input:2}"; ok "Steering: $steer_msg" ;;
            r|R)
              local rating="${user_input:2}"; rating="${rating// /}"
              if [[ "$rating" =~ ^[1-5]$ ]]; then
                # Save for RLHF
                echo "{\"prompt\":$(echo "$last_exchange_prompt" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"response\":$(echo "$last_exchange_response" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"rating\":$rating,\"agent\":\"$last_agent\"}" \
                  >> "$RLHF_RATINGS_FILE"
                (( total_rated++ ))
                ok "Rated $rating/5 (total rated: $total_rated)"
                # Trigger RLHF training if enabled and enough pairs
                if [[ "$do_train" == "1" ]] && (( total_rated > 0 && total_rated % 5 == 0 )); then
                  info "Auto-training on $total_rated rated exchanges..."
                  _rlhf_dpo_train "${ACTIVE_MODEL:-}" &>/dev/null &
                fi
              else
                warn "Rating must be 1-5"
              fi
              ;;
          esac
        fi
      fi
    done
  done

  echo ""
  info "Conversation complete ($round rounds, $n_agents agents)"

  # Save as dataset
  if [[ "$do_save" == "1" && ${#EXCHANGE_LOG[@]} -gt 0 ]]; then
    local ds_name="multiai_${mode}_$(date +%Y%m%d_%H%M%S)"
    local ds_dir="$DATASETS_DIR/$ds_name"
    mkdir -p "$ds_dir"
    echo "{\"name\":\"$ds_name\",\"created\":\"$(date -Iseconds)\",\"count\":0}" > "$ds_dir/meta.json"
    touch "$ds_dir/data.jsonl"

    # Build adjacent-turn pairs as training data
    local pair_count=0
    for (( i=0; i+1 < ${#HISTORY[@]}; i+=2 )); do
      local q="${HISTORY[$i]}" a="${HISTORY[$((i+1))]}"
      echo "{\"prompt\":$(echo "$q" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),\"response\":$(echo "$a" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')}" \
        >> "$ds_dir/data.jsonl"
      (( pair_count++ ))
    done

    python3 -c "import json; m=json.load(open('$ds_dir/meta.json')); m['count']=$pair_count; json.dump(m,open('$ds_dir/meta.json','w'))" 2>/dev/null || true
    ok "Saved as dataset: $ds_name ($pair_count pairs)"
    echo "  Fine-tune: ai ttm finetune $ds_name"
  fi

  # Final RLHF training if ratings were collected
  if [[ "$do_train" == "1" && $total_rated -ge 5 ]]; then
    info "Running final RLHF training on $total_rated rated exchanges..."
    _rlhf_dpo_train "${ACTIVE_MODEL:-}" 2>/dev/null || true
    ok "RLHF training triggered"
  fi
}

_multiai_help() {
  hdr "Multi-AI Chat Arena (v2.4.5)"
  echo ""
  echo "  ${B}ai multiai \"<topic>\"${R}              — Two AIs discuss a topic"
  echo "  ${B}ai multiai debate \"<topic>\"${R}        — Adversarial: AIs take opposite sides"
  echo "  ${B}ai multiai collab \"<task>\"${R}         — Collaborative: AIs build together"
  echo "  ${B}ai multiai brainstorm \"<topic>\"${R}    — Free-form: each AI adds ideas"
  echo ""
  echo "  Options:"
  echo "    --agents N       Number of agents (2-4, default 2)"
  echo "    --rounds N       Conversation rounds (default $MULTIAI_ROUNDS)"
  echo "    --model1 <id>    Agent 1 model/backend"
  echo "    --model2 <id>    Agent 2 model/backend"
  echo "    --no-save        Don't save as training dataset"
  echo "    --no-train       Don't trigger RLHF even if enabled"
  echo ""
  echo "  During conversation:"
  echo "    Enter            Continue"
  echo "    s <text>         Steer: inject guidance into next agent's prompt"
  echo "    r <1-5>          Rate last exchange (feeds RLHF training)"
  echo "    p                Pause / resume"
  echo "    q                Stop and save"
  echo ""
  echo "  Settings:"
  echo "    ai config multiai_rounds N        — Default rounds"
  echo "    ai config multiai_save_dataset 1  — Auto-save conversations as datasets"
  echo "    ai config multiai_rlhf_train 1    — Auto-train on rated exchanges"
  echo ""
  echo "  Examples:"
  echo "    ai multiai debate \"Is AGI beneficial?\""
  echo "    ai multiai collab \"Design a REST API for a todo app\" --agents 3"
  echo "    ai multiai brainstorm \"New uses for LLMs\" --rounds 4"
  echo "    ai multiai \"What is consciousness?\" --agents 2 --rounds 8"
}

cmd_serve() {
  local port=8080 host="127.0.0.1"
  while [[ $# -gt 0 ]]; do
    case "$1" in --port) port="$2"; shift 2 ;; --host) host="$2"; shift 2 ;; *) shift ;; esac
  done
  local model="${ACTIVE_MODEL:-}"; [[ -z "$model" ]] && { err "No model set"; return 1; }
  if [[ -n "$LLAMA_BIN" && "$LLAMA_BIN" != "llama_cpp_python" ]]; then
    local srv; srv=$(dirname "$LLAMA_BIN")/llama-server
    [[ -x "$srv" ]] && { info "Starting llama.cpp server on $host:$port"; "$srv" -m "$model" --host "$host" --port "$port" -c "$CONTEXT_SIZE" -ngl "$GPU_LAYERS"; return; }
  fi
  [[ -n "$PYTHON" ]] && "$PYTHON" -m llama_cpp.server --model "$model" --host "$host" --port "$port"
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: GITHUB INTEGRATION — commit / push / pr / issue / clone / status
# ════════════════════════════════════════════════════════════════════════════════
