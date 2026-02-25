#!/usr/bin/env bash
# Config-Mac-M1Pro.sh — M1 Pro / 32GB unified memory
#
# Installs Homebrew, Ollama, pulls Qwen3 models, writes Modelfiles with
# Qwen3 recommended sampling params, and wires up shell env vars.
#
# Memory note: macOS typically reserves 8-10GB for OS + apps, leaving
# ~22-24GB available. Qwen3-Coder-30B-A3B (~18GB) fits cleanly.
# Qwen3-32B (~19.8GB) is tight — use Activity Monitor > Memory Pressure
# and watch for swapping. A conservative 32K ctx is set to reduce
# KV-cache overhead. Increase to 65536 only if memory pressure stays green.
#
# Usage:
#   chmod +x Config-Mac-M1Pro.sh && ./Config-Mac-M1Pro.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REQUIRED_CHIP="M1 Pro"
REQUIRED_RAM_GB=32

OLLAMA_MODELS_DIR="$HOME/.ollama/models"
ZSHRC="$HOME/.zshrc"

MODELS=(
    "qwen3-coder:30b-a3b-q4_K_M"   # ~18GB — primary driver, safe fit
    "qwen3:32b-q4_K_M"              # ~19.8GB — tight on 32GB, see note above
)

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

    [[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS only."
    [[ "$(uname -m)" == "arm64" ]] || fail "Expected Apple Silicon (arm64). Got: $(uname -m)"

    local chip
    chip=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2}' | xargs)
    step "Chip: $chip"
    if [[ "$chip" != *"$REQUIRED_CHIP"* ]]; then
        warn "Expected '$REQUIRED_CHIP', got '$chip'. Memory thresholds were tuned for this chip — continuing."
    else
        ok "$REQUIRED_CHIP confirmed"
    fi

    local ram_bytes ram_gb
    ram_bytes=$(sysctl -n hw.memsize)
    ram_gb=$(( ram_bytes / 1024 / 1024 / 1024 ))
    step "Unified memory: ${ram_gb} GB"
    if (( ram_gb < REQUIRED_RAM_GB )); then
        fail "Insufficient memory: need ${REQUIRED_RAM_GB} GB, found ${ram_gb} GB."
    fi
    ok "${ram_gb} GB unified memory"

    # Warn about the tight-fit nature of 32B on this machine
    warn "32GB budget: OS reserves ~8-10GB. Qwen3-32B (~19.8GB) leaves little slack."
    warn "Monitor Activity Monitor > Memory Pressure when running the 32B model."
    step "M1 Pro memory bandwidth: ~200 GB/s (Metal GPU acceleration active)"
}

# ---------------------------------------------------------------------------
# 2. Homebrew + packages
# ---------------------------------------------------------------------------
install_prerequisites() {
    header "Prerequisites"

    if ! command_exists brew; then
        step "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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

    if ! pgrep -x ollama &>/dev/null; then
        step "Starting Ollama server..."
        ollama serve &>/tmp/ollama-serve.log &
        sleep 3
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

    # ctx sizing rationale:
    #   - 30B coder: ~18GB model weight + 32K ctx KV cache (~1-2GB) = safe
    #   - 32B dense:  ~19.8GB model weight + 32K ctx KV cache (~1-2GB)
    #     Total ~21-22GB — leaves ~2-4GB buffer on 32GB with OS overhead
    #     Increase num_ctx to 65536 only if memory pressure stays green in testing
    declare -A variants=(
        ["qwen3-coder-30b-tuned"]="qwen3-coder:30b-a3b-q4_K_M"
        ["qwen3-32b-tuned"]="qwen3:32b-q4_K_M"
    )
    declare -A ctx_sizes=(
        ["qwen3-coder-30b-tuned"]=65536   # 30B is comfortable — full 64K
        ["qwen3-32b-tuned"]=32768         # 32B is tight — conservative 32K ctx
    )

    for tag in "${!variants[@]}"; do
        local base="${variants[$tag]}"
        local ctx="${ctx_sizes[$tag]}"
        local mf_path="$mf_dir/${tag}.Modelfile"

        cat > "$mf_path" <<MODELFILE
FROM $base

# Qwen3 recommended sampling (Qwen team, 2025)
PARAMETER temperature ${QWEN3_PARAMS[temperature]}
PARAMETER top_p ${QWEN3_PARAMS[top_p]}
PARAMETER top_k ${QWEN3_PARAMS[top_k]}
PARAMETER repeat_penalty ${QWEN3_PARAMS[repeat_penalty]}

# M1 Pro 32GB: ctx sized to stay clear of memory pressure (see script notes)
PARAMETER num_ctx $ctx

SYSTEM """
You are a highly capable assistant. For coding tasks you produce clean,
idiomatic code with brief explanations. For log analysis you identify root
causes concisely. Toggle thinking mode at runtime with /think or /no_think
at the start of your message.
"""
MODELFILE

        step "Creating '$tag' from '$base' (num_ctx=$ctx)..."
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

    local marker="# --- Config-Mac-M1Pro ---"

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
export OLLAMA_GPU_OVERHEAD="0"
# M1 Pro: cap at 20GB GPU allocation to avoid spilling into swap under the 32B model
export OLLAMA_MAX_VRAM="21474836480"   # 20 GB in bytes
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

  MODELS (M1 Pro 32GB unified memory)
  ------------------------------------
  qwen3-coder-30b-tuned   Primary coding driver — comfortable fit
                           ~18 GB | 64K ctx configured
                           MoE ~3B active params/tok — fast on M1 Pro

  qwen3-32b-tuned          Reasoning / log analysis — tight fit on 32GB
                           ~19.8 GB | 32K ctx (conservative to avoid swap)
                           Use Activity Monitor > Memory Pressure as a guide:
                             Green  → fine, can bump num_ctx to 65536
                             Yellow → acceptable for short sessions
                             Red    → close other apps or drop back to 30B

  Memory bandwidth ~200 GB/s (vs ~410 GB/s on M4 Max) — inference is still
  fast due to Metal, but noticeably slower than M4 Max on the 32B model.

  THINKING MODE
  -------------
  Start prompt with /think    — chain-of-thought (slow, thorough)
  Start prompt with /no_think — off (fast, default)

  On the M1 Pro, keep thinking mode off unless you specifically need deep
  reasoning — it generates more tokens and increases memory pressure duration.

  QWEN3 SAMPLING PRESETS (written to Modelfiles)
  -----------------------------------------------
  temperature=0.7  top_p=0.8  top_k=20  repeat_penalty=1.05
  Differs from Qwen2.5 defaults — update LM Studio presets manually.

  TO INCREASE CONTEXT (if 32B memory pressure stays green in testing)
  --------------------------------------------------------------------
  Edit ~/.ollama/modelfiles/qwen3-32b-tuned.Modelfile
  Change: PARAMETER num_ctx 32768  →  PARAMETER num_ctx 65536
  Then:   ollama create qwen3-32b-tuned -f ~/.ollama/modelfiles/qwen3-32b-tuned.Modelfile

  LM STUDIO
  ---------
  GPU Offload: 100% initially. If you see memory warnings, back off to 95%.
  Set the Qwen3 sampling params in preset (see above).

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
header "Config-Mac-M1Pro.sh — M1 Pro / 32GB unified memory"

assert_hardware
install_prerequisites
set_env_vars
pull_models
set_modelfiles
show_notes

echo
ok "Setup complete. Run: source ~/.zshrc"
echo
