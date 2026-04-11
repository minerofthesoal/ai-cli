# ============================================================================
# MODULE: 21-install.sh
# Dependency installer + uninstall
# Source lines 8108-8303 of main-v2.7.3
# ============================================================================

#  INSTALL / UNINSTALL
# ════════════════════════════════════════════════════════════════════════════════
cmd_install_deps() {
  local force=0 cpu_only=0 no_torch=0 windows_help=0
  for a in "$@"; do
    [[ "$a" == "--force"    ]] && force=1
    [[ "$a" == "--cpu-only" ]] && cpu_only=1
    [[ "$a" == "--no-torch" ]] && no_torch=1
    [[ "$a" == "--windows"  ]] && windows_help=1
  done

  # Windows 10 setup instructions
  if [[ $windows_help -eq 1 ]] || [[ $IS_WINDOWS -eq 1 && $force -eq 0 && -z "$PYTHON" ]]; then
    hdr "AI CLI v${VERSION} — Windows 10 Setup"
    echo ""
    echo -e "${BCYAN}Prerequisites (install in order):${R}"
    echo ""
    echo "  1. Python 3.11+ for Windows"
    echo "     https://www.python.org/downloads/windows/"
    echo "     Tick: 'Add Python to PATH' during install"
    echo ""
    echo "  2. Git for Windows (includes Git Bash)"
    echo "     https://git-scm.com/download/win"
    echo ""
    echo "  3. Run in Git Bash:"
    echo "     pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu"
    echo "     pip install transformers tokenizers accelerate safetensors datasets"
    echo "     pip install openai anthropic google-generativeai peft trl huggingface_hub"
    echo "     pip install llama-cpp-python"
    echo ""
    echo -e "${BCYAN}Recommended: Use WSL2 for best compatibility${R}"
    echo "  wsl --install        (in PowerShell as Admin)"
    echo "  Then install Ubuntu, run ai install-deps inside WSL"
    echo ""
    echo -e "${BCYAN}Run in Git Bash / WSL to install (CPU-only):${R}"
    echo "  ai install-deps --cpu-only"
    echo ""
    return 0
  fi

  hdr "Installing AI CLI v${VERSION} dependencies"
  echo "  Platform: $PLATFORM | CPU-only: $([[ $cpu_only -eq 1 || $IS_WINDOWS -eq 1 ]] && echo yes || echo auto)"
  echo ""

  # System package installation
  if [[ $IS_WINDOWS -eq 0 && $IS_WSL -eq 0 ]]; then
    if command -v apt-get &>/dev/null; then
      info "Detected APT (Debian/Ubuntu/Mint)..."
      sudo apt-get update -q 2>/dev/null || true
      sudo apt-get install -y -q python3 python3-pip python3-dev git cmake \
        build-essential ffmpeg curl jq espeak libsndfile1 \
        libssl-dev libffi-dev tk-dev 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
      info "Detected Pacman (Arch/Manjaro/EndeavourOS)..."
      sudo pacman -Sy --noconfirm --needed 2>/dev/null || true
      sudo pacman -S --noconfirm --needed \
        python python-pip git cmake base-devel \
        ffmpeg curl jq espeak libsndfile \
        openssl python-tkinter 2>/dev/null || true
      # AUR helper for yay or paru (optional extras)
      if command -v yay &>/dev/null; then
        yay -S --noconfirm --needed python-soundfile 2>/dev/null || true
      elif command -v paru &>/dev/null; then
        paru -S --noconfirm --needed python-soundfile 2>/dev/null || true
      fi
    elif command -v dnf &>/dev/null; then
      info "Detected DNF (Fedora/RHEL)..."
      sudo dnf install -y python3 python3-pip python3-devel git cmake \
        gcc gcc-c++ ffmpeg curl jq espeak libsndfile-devel \
        openssl-devel python3-tkinter 2>/dev/null || true
    elif command -v zypper &>/dev/null; then
      info "Detected Zypper (openSUSE)..."
      sudo zypper install -y python3 python3-pip python3-devel git cmake \
        gcc ffmpeg curl jq espeak libsndfile-devel \
        libopenssl-devel python3-tk 2>/dev/null || true
    elif command -v brew &>/dev/null; then
      info "Detected Homebrew (macOS)..."
      brew install python3 cmake ffmpeg jq espeak libsndfile 2>/dev/null || true
    else
      warn "No known package manager found. Install python3, git, ffmpeg, cmake manually."
    fi
  elif [[ $IS_WSL -eq 1 ]]; then
    info "Detected WSL — using APT..."
    sudo apt-get update -q 2>/dev/null || true
    sudo apt-get install -y -q python3 python3-pip python3-dev git cmake \
      build-essential ffmpeg curl jq espeak libsndfile1 \
      libssl-dev libffi-dev 2>/dev/null || true
  else
    info "Windows: skipping system package install (install manually if needed)"
  fi

  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required. On Windows run: ai install-deps --windows"; return 1; }

  # Windows / CPU-only always use CPU torch
  local use_cpu=0
  [[ $cpu_only -eq 1 || $IS_WINDOWS -eq 1 ]] && use_cpu=1

  if [[ $no_torch -eq 0 ]]; then
    local ca; ca=$(detect_cuda_arch)
    if [[ $use_cpu -eq 1 ]] || (( ca == 0 )); then
      info "Installing PyTorch CPU (Windows/CPU-only mode)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu -q 2>/dev/null || \
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu --break-system-packages -q 2>/dev/null || true
    elif (( ca >= 80 )); then
      info "Installing PyTorch CUDA 12.1 (compute $ca — Ampere/Ada+)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu121 --break-system-packages -q 2>/dev/null || true
    elif (( ca >= 37 )); then
      # sm_61 = Pascal GTX 1060/1070/1080/Ti, sm_70 = Volta, sm_75 = Turing, etc.
      # CUDA 11.8 supports compute >= 3.7 (sm_37) — covers GTX 1080 (sm_61) perfectly
      info "Installing PyTorch CUDA 11.8 (compute $ca — Pascal/Volta/Turing/Ampere)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu118 --break-system-packages -q 2>/dev/null || true
    else
      info "Installing PyTorch CPU (very old GPU, compute $ca < 3.7)"
      "$PYTHON" -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu --break-system-packages -q 2>/dev/null || true
    fi
  fi

  # Core ML and API packages
  info "Installing core packages..."
  "$PYTHON" -m pip install transformers tokenizers accelerate safetensors datasets \
    optimum "huggingface_hub>=0.20" "peft>=0.7" "trl>=0.7" diffusers Pillow \
    openai anthropic google-generativeai tiktoken \
    soundfile pydub -q 2>/dev/null || \
  "$PYTHON" -m pip install transformers tokenizers accelerate safetensors datasets \
    optimum "huggingface_hub>=0.20" "peft>=0.7" "trl>=0.7" diffusers Pillow \
    openai anthropic google-generativeai tiktoken \
    soundfile pydub --break-system-packages -q 2>/dev/null || true

  # Optional packages (may fail on some platforms)
  "$PYTHON" -m pip install openai-whisper pyttsx3 -q 2>/dev/null || \
  "$PYTHON" -m pip install openai-whisper pyttsx3 --break-system-packages -q 2>/dev/null || true

  # bitsandbytes (skip on Windows — no CUDA, often fails)
  if [[ $IS_WINDOWS -eq 0 ]]; then
    "$PYTHON" -m pip install bitsandbytes -q --break-system-packages 2>/dev/null || true
  fi

  # llama-cpp-python (CPU only on Windows/no GPU)
  info "Installing llama-cpp-python..."
  local ca; ca=$(detect_cuda_arch)
  if [[ $use_cpu -eq 1 ]] || (( ca < 61 )); then
    # CPU-only build
    CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS" \
      "$PYTHON" -m pip install llama-cpp-python -q 2>/dev/null || \
    "$PYTHON" -m pip install llama-cpp-python -q --break-system-packages 2>/dev/null || true
  else
    CMAKE_ARGS="-DLLAMA_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=${ca}" \
      "$PYTHON" -m pip install llama-cpp-python --no-cache-dir --force-reinstall \
      --break-system-packages -q 2>/dev/null || \
    "$PYTHON" -m pip install llama-cpp-python --break-system-packages -q 2>/dev/null || true
  fi

  echo ""
  ok "Installation complete!"
  if [[ $IS_WINDOWS -eq 1 ]]; then
    echo "  Windows 10 CPU-only mode is active"
    echo "  Quick start: ai recommended → ai ask \"Hello\""
  else
    echo "  Quick start: ai recommended → ai recommended download 1 → ai -gui"
  fi
  echo "  Start API server: ai api start"
}

cmd_uninstall() {
  # v2.7.3 fix: suppress first-run check during uninstall
  touch "$FIRST_RUN_FILE" 2>/dev/null || true
  if [[ $EUID -ne 0 ]]; then err "Requires sudo: sudo ai uninstall"; return 1; fi
  echo -e "${BRED}${B}╔══════════════════════════════════════════════╗${R}"
  echo -e "${BRED}${B}║   ⚠  AI CLI UNINSTALL — CANNOT BE UNDONE   ║${R}"
  echo -e "${BRED}${B}╚══════════════════════════════════════════════╝${R}"
  echo ""
  echo "  AI CLI v${VERSION} will be removed from this system."
  echo ""
  echo "  Binary:  /usr/local/bin/ai"
  echo "  Config:  $CONFIG_DIR  (optional)"
  echo "  Models:  $MODELS_DIR  (optional)"
  echo ""
  read -rp "  Type CONFIRM to proceed: " confirm
  [[ "$confirm" != "CONFIRM" ]] && { info "Cancelled."; return 0; }
  read -rp "  Remove config/sessions/chats? [y/N]: " rm_cfg
  read -rp "  Remove downloaded models? [y/N]: " rm_mdl
  # Remove binary from both common paths
  rm -f /usr/local/bin/ai 2>/dev/null && ok "Removed /usr/local/bin/ai"
  rm -f /usr/bin/ai 2>/dev/null || true
  [[ "$rm_cfg" =~ ^[Yy]$ ]] && { rm -rf "$CONFIG_DIR"; ok "Removed $CONFIG_DIR"; }
  [[ "$rm_mdl" =~ ^[Yy]$ ]] && { rm -rf "$MODELS_DIR"; ok "Removed $MODELS_DIR"; }
  ok "AI CLI v${VERSION} uninstalled successfully."
}

# ════════════════════════════════════════════════════════════════════════════════
#  STATUS
