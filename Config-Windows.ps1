#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LLM environment setup for Ryzen 9 5950X / 64GB RAM / RTX 3090 FE (24GB VRAM)

.DESCRIPTION
    Installs and configures Ollama + LM Studio for local LLM inference.
    Primary models: Qwen3-Coder-30B-A3B (coding), Qwen3-32B (reasoning/logs)
    Validates GPU has 24GB VRAM before pulling large models.

.NOTES
    Run from an elevated PowerShell session:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\Config-Windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$REQUIRED_VRAM_GB    = 24
$REQUIRED_RAM_GB     = 64
$REQUIRED_GPU_NAME   = '3090'          # substring match — adjust if needed

$OLLAMA_MODELS = @(
    # Primary coding driver — MoE, activates ~3B params/token, 128K ctx
    'qwen3-coder:30b-a3b-q4_K_M'
    # Dense flagship — swap in for deep reasoning / log analysis with thinking mode
    'qwen3:32b-q4_K_M'
)

# Qwen3 tuning per Qwen team recommendations (applies to both models above)
# Set these in LM Studio presets or pass via Ollama Modelfile overrides
$QWEN3_PARAMS = @{
    temperature        = 0.7
    top_p              = 0.8
    top_k              = 20
    repetition_penalty = 1.05
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Header([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host "[*] $Text" -ForegroundColor Yellow
}

function Write-OK([string]$Text) {
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Write-Host "[WARN] $Text" -ForegroundColor Magenta
}

function Write-Fail([string]$Text) {
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Test-CommandExists([string]$Cmd) {
    [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# 1. Hardware validation
# ---------------------------------------------------------------------------
function Assert-Hardware {
    Write-Header 'Hardware Validation'

    # --- CPU ---
    $cpu = (Get-CimInstance Win32_Processor).Name
    Write-Step "CPU: $cpu"
    if ($cpu -notmatch '5950X') {
        Write-Warn "Expected 5950X — got '$cpu'. Continuing, but VRAM/RAM thresholds were tuned for this rig."
    } else {
        Write-OK '5950X confirmed'
    }

    # --- RAM ---
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    Write-Step "RAM: ${ramGB} GB detected"
    if ($ramGB -lt $REQUIRED_RAM_GB) {
        throw "Insufficient RAM: need ${REQUIRED_RAM_GB} GB, found ${ramGB} GB."
    }
    Write-OK "${ramGB} GB RAM OK"

    # --- GPU / VRAM ---
    $gpus = Get-CimInstance Win32_VideoController
    $targetGpu = $gpus | Where-Object { $_.Name -match $REQUIRED_GPU_NAME } | Select-Object -First 1

    if (-not $targetGpu) {
        throw "No GPU matching '$REQUIRED_GPU_NAME' found. GPUs present: $($gpus.Name -join ', ')"
    }

    Write-Step "GPU: $($targetGpu.Name)"

    # AdapterRAM from WMI is often wrong for high-VRAM cards — use nvidia-smi if available
    $vramGB = $null
    if (Test-CommandExists 'nvidia-smi') {
        $raw = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null |
               Select-Object -First 1
        if ($raw -match '^\d+$') {
            $vramGB = [math]::Round([int]$raw / 1024)
        }
    }

    if ($null -eq $vramGB) {
        # Fallback: WMI (unreliable above 4GB on some drivers, but worth trying)
        $vramGB = [math]::Round($targetGpu.AdapterRAM / 1GB)
    }

    Write-Step "VRAM: ${vramGB} GB detected"
    if ($vramGB -lt $REQUIRED_VRAM_GB) {
        throw "Insufficient VRAM: need ${REQUIRED_VRAM_GB} GB, found ${vramGB} GB. " +
              "Cannot safely fit Qwen3-Coder-30B-A3B Q4_K_M (~18 GB) or Qwen3-32B Q4_K_M (~19.8 GB)."
    }
    Write-OK "${vramGB} GB VRAM OK — fits primary models with context headroom"
}

# ---------------------------------------------------------------------------
# 2. Install Winget packages
# ---------------------------------------------------------------------------
function Install-Prerequisites {
    Write-Header 'Prerequisites'

    $packages = @(
        @{ Id = 'Git.Git';              Name = 'Git'         }
        @{ Id = 'Ollama.Ollama';        Name = 'Ollama'      }
        @{ Id = 'GitHub.GitLFS';        Name = 'Git LFS'     }
    )

    foreach ($pkg in $packages) {
        Write-Step "Checking $($pkg.Name)..."
        $installed = winget list --id $pkg.Id --exact 2>$null | Select-String $pkg.Id
        if ($installed) {
            Write-OK "$($pkg.Name) already installed"
        } else {
            Write-Step "Installing $($pkg.Name) via winget..."
            winget install --id $pkg.Id --exact --silent --accept-package-agreements --accept-source-agreements
            Write-OK "$($pkg.Name) installed"
        }
    }

    # LM Studio — winget ID varies by release; fall back to advisory note
    $lmsInstalled = winget list --id 'LMStudio.LMStudio' --exact 2>$null | Select-String 'LMStudio'
    if ($lmsInstalled) {
        Write-OK 'LM Studio already installed'
    } else {
        Write-Step 'Attempting LM Studio install via winget...'
        try {
            winget install --id 'LMStudio.LMStudio' --exact --silent --accept-package-agreements --accept-source-agreements
            Write-OK 'LM Studio installed'
        } catch {
            Write-Warn 'LM Studio not found in winget — download manually from https://lmstudio.ai'
        }
    }

    # Refresh PATH so ollama is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

# ---------------------------------------------------------------------------
# 3. Ollama: pull models
# ---------------------------------------------------------------------------
function Install-OllamaModels {
    Write-Header 'Ollama — Pulling Models'

    if (-not (Test-CommandExists 'ollama')) {
        Write-Warn 'ollama not found in PATH — skipping model pull. Re-run after installation.'
        return
    }

    # Ensure Ollama service is running
    $svc = Get-Service -Name 'ollama' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Step 'Starting Ollama service...'
        Start-Service -Name 'ollama'
    }

    foreach ($model in $OLLAMA_MODELS) {
        Write-Step "Pulling $model (this may take a while on first run)..."
        ollama pull $model
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Pull failed for $model — check Ollama logs. Continuing."
        } else {
            Write-OK "$model ready"
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Ollama: write Modelfiles with Qwen3 tuning
# ---------------------------------------------------------------------------
function Set-OllamaModelfiles {
    Write-Header 'Ollama — Applying Qwen3 Parameter Presets'

    if (-not (Test-CommandExists 'ollama')) {
        Write-Warn 'ollama not in PATH — skipping Modelfile creation.'
        return
    }

    $modelfileDir = Join-Path $env:USERPROFILE '.ollama\modelfiles'
    New-Item -ItemType Directory -Force -Path $modelfileDir | Out-Null

    # Map: friendly tag -> base model tag
    $variants = @{
        'qwen3-coder-30b-a3b-tuned' = 'qwen3-coder:30b-a3b-q4_K_M'
        'qwen3-32b-tuned'           = 'qwen3:32b-q4_K_M'
    }

    foreach ($tag in $variants.Keys) {
        $base = $variants[$tag]
        $mfPath = Join-Path $modelfileDir "$tag.Modelfile"

        # Thinking mode: leave /think and /no_think toggles to the user at runtime.
        # These are injected in the prompt, not the Modelfile.
        $content = @"
FROM $base

# Qwen3 recommended sampling parameters (Qwen team, 2025)
PARAMETER temperature $($QWEN3_PARAMS.temperature)
PARAMETER top_p $($QWEN3_PARAMS.top_p)
PARAMETER top_k $($QWEN3_PARAMS.top_k)
PARAMETER repeat_penalty $($QWEN3_PARAMS.repetition_penalty)

# 3090 FE has 24GB VRAM — keep context generous but leave ~4GB headroom
PARAMETER num_ctx 65536

SYSTEM """
You are a highly capable assistant. For coding tasks you produce clean,
idiomatic code with brief explanations. For log analysis you identify root
causes concisely. Toggle thinking mode at runtime with /think or /no_think
at the start of your message.
"""
"@
        Set-Content -Path $mfPath -Value $content -Encoding UTF8
        Write-Step "Creating tuned variant '$tag' from '$base'..."
        ollama create $tag -f $mfPath
        if ($LASTEXITCODE -eq 0) {
            Write-OK "'$tag' created"
        } else {
            Write-Warn "Failed to create '$tag' — base model may not be pulled yet."
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Environment variables
# ---------------------------------------------------------------------------
function Set-EnvVars {
    Write-Header 'Environment Variables'

    $vars = @{
        # Keep models on a drive with space — change path if needed
        OLLAMA_MODELS = 'C:\LLM\models\ollama'
        # Full GPU offload — 3090 fits these models entirely in VRAM
        OLLAMA_GPU_OVERHEAD = '0'
        # Expose Ollama on localhost only (default); change to 0.0.0.0 for LAN
        OLLAMA_HOST = '127.0.0.1:11434'
    }

    foreach ($key in $vars.Keys) {
        [System.Environment]::SetEnvironmentVariable($key, $vars[$key], 'Machine')
        $env:($key) = $vars[$key]
        Write-OK "Set $key = $($vars[$key])"
    }

    # Create model storage dir if it doesn't exist
    $modelDir = $vars['OLLAMA_MODELS']
    if (-not (Test-Path $modelDir)) {
        New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
        Write-OK "Created $modelDir"
    }
}

# ---------------------------------------------------------------------------
# 6. Print usage notes
# ---------------------------------------------------------------------------
function Show-UsageNotes {
    Write-Header 'Usage Notes'

    Write-Host @"

  MODELS INSTALLED
  ----------------
  qwen3-coder-30b-a3b-tuned   Primary coding driver (Ruby, Chef, omnibus, etc.)
                               ~18 GB VRAM | 128K ctx | MoE ~3B active params/tok
                               Fast interactive use + Cline/Continue tool-calling

  qwen3-32b-tuned              Dense flagship for deep reasoning & log analysis
                               ~19.8 GB VRAM | 128K ctx | thinking mode available

  THINKING MODE (Qwen3)
  ---------------------
  Prefix your prompt with /think   — enables chain-of-thought (slow, thorough)
  Prefix your prompt with /no_think — disables it (fast, interactive default)

  Recommended: /no_think for coding sessions, /think for mysterious build failures.

  QWEN3 SAMPLING PRESETS (applied via Modelfile)
  -----------------------------------------------
  temperature=0.7  top_p=0.8  top_k=20  repeat_penalty=1.05
  Note: these differ from Qwen2.5 defaults — update any LM Studio presets manually.

  LARGE MODEL (EXPERIMENTAL)
  --------------------------
  Qwen3-Coder-480B-A35B Q2_K_XL (~200 GB) can run with CPU offload via llama.cpp:
    llama-server -m qwen3-coder-480b-a35b-q2_k_xl.gguf \
      -ot ".ffn_.*_exps.=CPU" --n-gpu-layers 999 \
      --ctx-size 32768 --port 8080
  Expect ~3-5 tok/s (DDR4 ~50 GB/s vs GDDR6X ~936 GB/s bottleneck).
  Good for long offline analysis; not interactive. Pull model separately.

  OLLAMA QUICK REFERENCE
  ----------------------
  ollama list                          # see installed models
  ollama run qwen3-coder-30b-a3b-tuned # interactive chat
  ollama ps                            # check what's loaded in VRAM
  ollama stop <model>                  # unload from VRAM

  LM STUDIO
  ---------
  Load model -> Edit Preset -> set temperature/top_p/top_k/repeat_penalty
  as shown above. Enable GPU offload = 100% (all layers to 3090).

"@ -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-Header 'Config-Windows.ps1 — 5950X / 64GB / RTX 3090 FE'

    Assert-Hardware
    Install-Prerequisites
    Set-EnvVars
    Install-OllamaModels
    Set-OllamaModelfiles
    Show-UsageNotes

    Write-Host ''
    Write-OK 'Setup complete. Open a new terminal to pick up environment variable changes.'
    Write-Host ''
} catch {
    Write-Fail "Setup failed: $_"
    exit 1
}
