#!/usr/bin/env bash
# Config-Mac-M4Max.sh — M4 Max / 36GB unified memory
#
# Installs Homebrew, Ollama, pulls Qwen3 models, writes Modelfiles with
# Qwen3 recommended sampling params, and wires up shell env vars.
#
# Usage:
#   chmod +x Config-Mac-M4Max.sh && ./Config-Mac-M4Max.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REQUIRED_CHIP="M4 Max"
REQUIRED_RAM_GB=36

OLLAMA_MODELS_DIR="$HOME/.ollama/models"
ZSHRC="$HOME/.zshrc"

# Primary models for this rig
MODELS=(
    "qwen3-coder:30b-a3b-q4_K_M"   # ~18GB — coding driver, MoE, 128K ctx
    "qwen3:32b-q4_K_M"              # ~19.8GB — dense flagship, reasoning/logs
)

# Qwen3 recommended sampling (applies to both)
declare -A QWEN3_PARAMS=(
    [temperature]=0.7
    [top_p]=0.8
    [top_k]=20
    [repeat_penalty]=1.05
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
header()  { echo; printf '%s\n' "$(printf '=%.0s' {1..60})"; echo "  $*"; printf '%s\n' "$(printf '=%.0s' {1..60})"; }
step()    { echo "[*] $*"; }
ok()      { echo -e "\033[32m[OK]\033[0m $*"; }
warn()    { echo -e "\033[35m[WARN]\033[0m $*"; }
fail()    { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Hardware validation
# ---------------------------------------------------------------------------
assert_hardware() {
    header "Hardware Validation"

    # macOS only
    [[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS only."

    # Apple Silicon
    [[ "$(uname -m)" == "arm64" ]] || fail "Expected Apple Silicon (arm64). Got: $(uname -m)"

    # Chip name
    local chip
    chip=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2}' | xargs)
    step "Chip: $chip"
    if [[ "$chip" != *"$REQUIRED_CHIP"* ]]; then
        warn "Expected '$REQUIRED_CHIP', got '$chip'. Thresholds were tuned for this chip — continuing."
    else
        ok "$REQUIRED_CHIP confirmed"
    fi

    # Unified memory
    local ram_bytes ram_gb
    ram_bytes=$(sysctl -n hw.memsize)
    ram_gb=$(( ram_bytes / 1024 / 1024 / 1024 ))
    step "Unified memory: ${ram_gb} GB"
    if (( ram_gb < REQUIRED_RAM_GB )); then
        fail "Insufficient memory: need ${REQUIRED_RAM_GB} GB, found ${ram_gb} GB."
    fi
    ok "${ram_gb} GB unified memory — fits both models with context headroom"

    # Memory bandwidth note (informational)
    step "M4 Max memory bandwidth: ~410 GB/s (GDDR6X-class throughput via Metal)"
}

# ---------------------------------------------------------------------------
# 2. Homebrew + packages
# ---------------------------------------------------------------------------
install_prerequisites() {
    header "Prerequisites"

    if ! command_exists brew; then
        step "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Add brew to PATH for the rest of this session
        eval "$(/opt/homebrew/bin/brew shellenv)"
        ok "Homebrew installed"
    else
        ok "Homebrew already installed ($(brew --version | head -1))"
    fi

    local formulae=("git" "ollama" "git-lfs")
    for pkg in "${formulae[@]}"; do
        if brew list "$pkg" &>/dev/null; then
            ok "$pkg already installed"
        else
            step "Installing $pkg..."
            brew install "$pkg"
            ok "$pkg installed"
        fi
    done

    git lfs install --skip-repo 2>/dev/null || true

    # LM Studio — cask
    if brew list --cask lm-studio &>/dev/null; then
        ok "LM Studio already installed"
    else
        step "Installing LM Studio..."
        brew install --cask lm-studio && ok "LM Studio installed" \
            || warn "LM Studio cask install failed — download from https://lmstudio.ai"
    fi
}

# ---------------------------------------------------------------------------
# 3. Ollama: pull models
# ---------------------------------------------------------------------------
pull_models() {
    header "Ollama — Pulling Models"

    # Start Ollama server in background if not already running
    if ! pgrep -x ollama &>/dev/null; then
        step "Starting Ollama server..."
        ollama serve &>/tmp/ollama-serve.log &
        sleep 3   # give it a moment to bind
    fi

    for model in "${MODELS[@]}"; do
        step "Pulling $model..."
        if ollama pull "$model"; then
            ok "$model ready"
        else
            warn "Pull failed for $model — check 'cat /tmp/ollama-serve.log'. Continuing."
        fi
    done
}

# ---------------------------------------------------------------------------
# 4. Ollama: Modelfiles with Qwen3 tuning
# ---------------------------------------------------------------------------
set_modelfiles() {
    header "Ollama — Applying Qwen3 Parameter Presets"

    local mf_dir="$HOME/.ollama/modelfiles"
    mkdir -p "$mf_dir"

    declare -A variants=(
        ["qwen3-coder-30b-tuned"]="qwen3-coder:30b-a3b-q4_K_M"
        ["qwen3-32b-tuned"]="qwen3:32b-q4_K_M"
    )

    for tag in "${!variants[@]}"; do
        local base="${variants[$tag]}"
        local mf_path="$mf_dir/${tag}.Modelfile"

        cat > "$mf_path" <<MODELFILE
FROM $base

# Qwen3 recommended sampling (Qwen team, 2025)
PARAMETER temperature ${QWEN3_PARAMS[temperature]}
PARAMETER top_p ${QWEN3_PARAMS[top_p]}
PARAMETER top_k ${QWEN3_PARAMS[top_k]}
PARAMETER repeat_penalty ${QWEN3_PARAMS[repeat_penalty]}

# M4 Max 36GB: 19.8GB peak (32B) + 65K ctx tokens leaves comfortable headroom
PARAMETER num_ctx 65536

SYSTEM """
You are a highly capable assistant. For coding tasks you produce clean,
idiomatic code with brief explanations. For log analysis you identify root
causes concisely. Toggle thinking mode at runtime with /think or /no_think
at the start of your message.
"""
MODELFILE

        step "Creating '$tag' from '$base'..."
        if ollama create "$tag" -f "$mf_path"; then
            ok "'$tag' created"
        else
            warn "Failed to create '$tag' — base model may not be pulled yet."
        fi
    done
}

# ---------------------------------------------------------------------------
# 5. Shell environment variables (~/.zshrc)
# ---------------------------------------------------------------------------
set_env_vars() {
    header "Shell Environment (~/.zshrc)"

    local marker="# --- Config-Mac-M4Max ---"

    # Remove any previous block from this script
    if grep -q "$marker" "$ZSHRC" 2>/dev/null; then
        step "Updating existing env block in $ZSHRC..."
        local tmp
        tmp=$(mktemp)
        awk "/$marker/{found=1} found && /# --- end ---/{found=0; next} !found" "$ZSHRC" > "$tmp"
        mv "$tmp" "$ZSHRC"
    fi

    cat >> "$ZSHRC" <<ENVBLOCK

$marker
export OLLAMA_MODELS="$OLLAMA_MODELS_DIR"
export OLLAMA_HOST="127.0.0.1:11434"
# Full Metal GPU offload — M4 Max handles both models entirely in unified memory
export OLLAMA_GPU_OVERHEAD="0"
# --- end ---
ENVBLOCK

    ok "Env vars written to $ZSHRC"
    step "Run 'source $ZSHRC' or open a new terminal to apply."

    mkdir -p "$OLLAMA_MODELS_DIR"
}

# ---------------------------------------------------------------------------
# 6. Usage notes
# ---------------------------------------------------------------------------
show_notes() {
    header "Usage Notes"

    cat <<'NOTES'

  MODELS (M4 Max 36GB unified memory)
  ------------------------------------
  qwen3-coder-30b-tuned   Primary coding driver (Ruby, Chef, omnibus, etc.)
                           ~18 GB | 128K ctx | MoE ~3B active params/tok
                           Fast + excellent Cline/Continue tool-calling

  qwen3-32b-tuned          Dense flagship for deep reasoning & log analysis
                           ~19.8 GB | 128K ctx | 65K ctx configured here

  Both models fit comfortably in 36GB with room for context and OS overhead.
  M4 Max memory bandwidth (~410 GB/s) gives strong inference throughput.

  THINKING MODE
  -------------
  Start prompt with /think    — chain-of-thought (slow, thorough)
  Start prompt with /no_think — off (fast, default for interactive use)

  Tip: /no_think for coding sessions; /think for mysterious build failures.

  QWEN3 SAMPLING PRESETS (written to Modelfiles)
  -----------------------------------------------
  temperature=0.7  top_p=0.8  top_k=20  repeat_penalty=1.05
  Differs from Qwen2.5 defaults — update LM Studio presets manually.

  LM STUDIO
  ---------
  My Models -> Edit Preset -> set params above.
  GPU Offload: 100% (full Metal acceleration, no CPU spill needed).

  OLLAMA QUICK REFERENCE
  ----------------------
  ollama list                        # installed models
  ollama run qwen3-coder-30b-tuned   # interactive chat
  ollama ps                          # check what's loaded
  ollama stop <model>                # unload from memory

NOTES
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
header "Config-Mac-M4Max.sh — M4 Max / 36GB unified memory"

assert_hardware
install_prerequisites
set_env_vars
pull_models
set_modelfiles
show_notes

echo
ok "Setup complete. Run: source ~/.zshrc"
echo
