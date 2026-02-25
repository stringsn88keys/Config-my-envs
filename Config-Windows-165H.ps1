#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LLM environment setup for Intel Core Ultra 165H / 32GB LPDDR5x (shared iGPU memory)

.DESCRIPTION
    Installs Ollama and configures models appropriate for 32GB unified memory.
    Primary: Qwen3-14B Q4_K_M (~9GB, fast, comfortable fit)
    Secondary: Qwen3-Coder-30B-A3B Q4_K_M (~18GB, slower, capable)
    Qwen3-32B is omitted — too tight on 32GB shared memory.

    GPU ACCELERATION NOTE
    ---------------------
    Standard Ollama on Windows has partial Intel Arc iGPU support via Vulkan.
    For full, correct Intel GPU acceleration install IPEX-LLM instead:
      https://github.com/intel/ipex-llm/blob/main/docs/mddocs/Quickstart/ollama_quickstart.md
    This script installs standard Ollama as a reliable CPU baseline and sets
    the environment variables needed by both standard Ollama and IPEX-LLM.
    Swap the Ollama binary for the IPEX-LLM build at any time — everything
    else (models, Modelfiles, env vars) is compatible.

    BIOS PREREQUISITE
    -----------------
    Ensure BIOS reserves at least 2-4 GB of system RAM for the Arc iGPU
    (Intel Dynamic Video Memory Technology / DVMT setting).
    Ollama will refuse to use the iGPU if it sees less than 512 MB reserved.

.NOTES
    Run from an elevated PowerShell session:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\Config-Windows-165H.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$REQUIRED_CPU_PATTERN = '165H'
$REQUIRED_RAM_GB      = 32
$REQUIRED_GPU_NAME    = 'Intel'      # substring match against Arc iGPU

# Models sized for 32GB shared memory (OS ~8GB + model + context headroom)
$OLLAMA_MODELS = @(
    'qwen3:14b-q4_K_M'                   # ~9GB — daily driver, comfortable fit
    'qwen3-coder:30b-a3b-q4_K_M'         # ~18GB — coding secondary, slower on iGPU
)

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

function Write-Step([string]$Text)  { Write-Host "[*] $Text" -ForegroundColor Yellow }
function Write-OK([string]$Text)    { Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text)  { Write-Host "[WARN] $Text" -ForegroundColor Magenta }
function Write-Fail([string]$Text)  { Write-Host "[FAIL] $Text" -ForegroundColor Red }

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
    if ($cpu -notmatch $REQUIRED_CPU_PATTERN) {
        Write-Warn "Expected $REQUIRED_CPU_PATTERN — got '$cpu'. Memory thresholds tuned for 165H. Continuing."
    } else {
        Write-OK "Core Ultra $REQUIRED_CPU_PATTERN confirmed"
    }

    # --- RAM ---
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    Write-Step "RAM: ${ramGB} GB detected"
    if ($ramGB -lt $REQUIRED_RAM_GB) {
        throw "Insufficient RAM: need ${REQUIRED_RAM_GB} GB, found ${ramGB} GB."
    }
    Write-OK "${ramGB} GB RAM OK"
    Write-Warn "Shared memory: OS reserves ~8 GB, iGPU DVMT carves out 2-4 GB. ~20-22 GB available for models."

    # --- iGPU ---
    $gpus = Get-CimInstance Win32_VideoController
    $igpu = $gpus | Where-Object { $_.Name -match $REQUIRED_GPU_NAME } | Select-Object -First 1

    if (-not $igpu) {
        Write-Warn "No Intel GPU found via WMI. GPUs present: $($gpus.Name -join ', ')"
        Write-Warn "Ollama will run CPU-only. Install Intel GPU drivers if Arc iGPU is present."
    } else {
        Write-Step "iGPU: $($igpu.Name)"
        Write-OK "Intel Arc iGPU detected"
        Write-Warn "Standard Ollama uses Vulkan for Arc (may have correctness issues)."
        Write-Warn "For full GPU acceleration: install IPEX-LLM (see script header and usage notes)."
    }

    # Bandwidth note
    Write-Step "Memory bandwidth: ~120 GB/s LPDDR5x (AVX2/AVX-512 on P-cores for CPU inference)"
    Write-Warn "No AMX on Meteor Lake consumer chips — CPU inference uses AVX2/AVX-512 only."
}

# ---------------------------------------------------------------------------
# 2. Winget packages
# ---------------------------------------------------------------------------
function Install-Prerequisites {
    Write-Header 'Prerequisites'

    $packages = @(
        @{ Id = 'Git.Git';       Name = 'Git'     }
        @{ Id = 'Ollama.Ollama'; Name = 'Ollama'  }
        @{ Id = 'GitHub.GitLFS'; Name = 'Git LFS' }
    )

    foreach ($pkg in $packages) {
        Write-Step "Checking $($pkg.Name)..."
        $installed = winget list --id $pkg.Id --exact 2>$null | Select-String $pkg.Id
        if ($installed) {
            Write-OK "$($pkg.Name) already installed"
        } else {
            Write-Step "Installing $($pkg.Name)..."
            winget install --id $pkg.Id --exact --silent --accept-package-agreements --accept-source-agreements
            Write-OK "$($pkg.Name) installed"
        }
    }

    $lmsInstalled = winget list --id 'LMStudio.LMStudio' --exact 2>$null | Select-String 'LMStudio'
    if ($lmsInstalled) {
        Write-OK 'LM Studio already installed'
    } else {
        Write-Step 'Attempting LM Studio install...'
        try {
            winget install --id 'LMStudio.LMStudio' --exact --silent --accept-package-agreements --accept-source-agreements
            Write-OK 'LM Studio installed'
        } catch {
            Write-Warn 'LM Studio not in winget — download from https://lmstudio.ai'
        }
    }

    # Refresh PATH for this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

# ---------------------------------------------------------------------------
# 3. Ollama: pull models
# ---------------------------------------------------------------------------
function Install-OllamaModels {
    Write-Header 'Ollama — Pulling Models'

    if (-not (Test-CommandExists 'ollama')) {
        Write-Warn 'ollama not in PATH — skipping model pull. Re-run after install.'
        return
    }

    $svc = Get-Service -Name 'ollama' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Step 'Starting Ollama service...'
        Start-Service -Name 'ollama'
    }

    foreach ($model in $OLLAMA_MODELS) {
        Write-Step "Pulling $model..."
        ollama pull $model
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Pull failed for $model — check Ollama logs. Continuing."
        } else {
            Write-OK "$model ready"
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Ollama: Modelfiles with Qwen3 tuning
# ---------------------------------------------------------------------------
function Set-OllamaModelfiles {
    Write-Header 'Ollama — Applying Qwen3 Parameter Presets'

    if (-not (Test-CommandExists 'ollama')) {
        Write-Warn 'ollama not in PATH — skipping Modelfile creation.'
        return
    }

    $modelfileDir = Join-Path $env:USERPROFILE '.ollama\modelfiles'
    New-Item -ItemType Directory -Force -Path $modelfileDir | Out-Null

    # Context sizing rationale for 32GB shared memory:
    #   14B:   ~9GB weights  + 32K ctx KV (~1.5GB) = ~11GB  → very safe
    #   30B-A3B: ~18GB weights + 16K ctx KV (~1.5GB) = ~20GB → fits, little headroom
    #   (Increase 30B ctx to 32768 only if memory pressure is comfortable in practice)
    $variants = @{
        'qwen3-14b-tuned'           = @{ Base = 'qwen3:14b-q4_K_M';              Ctx = 32768 }
        'qwen3-coder-30b-a3b-tuned' = @{ Base = 'qwen3-coder:30b-a3b-q4_K_M';   Ctx = 16384 }
    }

    foreach ($tag in $variants.Keys) {
        $v = $variants[$tag]
        $mfPath = Join-Path $modelfileDir "$tag.Modelfile"

        $content = @"
FROM $($v.Base)

# Qwen3 recommended sampling (Qwen team, 2025)
PARAMETER temperature $($QWEN3_PARAMS.temperature)
PARAMETER top_p $($QWEN3_PARAMS.top_p)
PARAMETER top_k $($QWEN3_PARAMS.top_k)
PARAMETER repeat_penalty $($QWEN3_PARAMS.repetition_penalty)

# 165H 32GB shared: ctx sized conservatively to avoid memory pressure
# Bump qwen3-coder-30b ctx to 32768 if Task Manager shows < 80% memory use
PARAMETER num_ctx $($v.Ctx)

SYSTEM """
You are a highly capable assistant. For coding tasks you produce clean,
idiomatic code with brief explanations. For log analysis you identify root
causes concisely. Toggle thinking mode at runtime with /think or /no_think
at the start of your message.
"""
"@
        Set-Content -Path $mfPath -Value $content -Encoding UTF8

        Write-Step "Creating '$tag' (num_ctx=$($v.Ctx))..."
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
        OLLAMA_MODELS = 'C:\LLM\models\ollama'
        OLLAMA_HOST   = '127.0.0.1:11434'

        # Leave GPU memory management to Ollama — iGPU uses shared RAM
        # Override to a bytes value if Ollama tries to load too much
        OLLAMA_GPU_OVERHEAD = '536870912'   # 512 MB reserved for OS/driver overhead

        # Required by IPEX-LLM and useful for Intel GPU debugging in standard Ollama
        ZES_ENABLE_SYSMAN = '1'

        # Helps Intel Level Zero driver prioritize inference workloads
        SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS = '1'

        # Persistent SYCL kernel cache — avoids recompilation on every Ollama start
        SYCL_CACHE_PERSISTENT = '1'
    }

    foreach ($key in $vars.Keys) {
        [System.Environment]::SetEnvironmentVariable($key, $vars[$key], 'Machine')
        Set-Item -Path "Env:$key" -Value $vars[$key]
        Write-OK "Set $key = $($vars[$key])"
    }

    $modelDir = $vars['OLLAMA_MODELS']
    if (-not (Test-Path $modelDir)) {
        New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
        Write-OK "Created $modelDir"
    }
}

# ---------------------------------------------------------------------------
# 6. Usage notes
# ---------------------------------------------------------------------------
function Show-UsageNotes {
    Write-Header 'Usage Notes'

    Write-Host @"

  MODELS (165H / 32GB shared memory)
  ------------------------------------
  qwen3-14b-tuned            Daily driver — fast, comfortable fit
                              ~9 GB | 32K ctx | good for interactive coding & chat
                              Expect ~15-25 tok/s (iGPU Vulkan) or ~10-18 tok/s (CPU)

  qwen3-coder-30b-a3b-tuned  Capable coding secondary — slower on iGPU
                              ~18 GB | 16K ctx (conservative)
                              Expect ~20-35 tok/s on iGPU, ~12-25 tok/s CPU-only
                              Use for complex reasoning when speed isn't critical

  qwen3-32B is NOT installed — too tight on 32GB shared memory with OS overhead.

  GPU ACCELERATION (CRITICAL READ)
  ---------------------------------
  Standard Ollama uses Vulkan for Intel Arc (experimental — may produce
  incorrect outputs on some builds). For production use, replace Ollama
  with Intel's IPEX-LLM build:

    1. Install Intel oneAPI Base Toolkit (runtime only, ~2GB):
         winget install Intel.oneAPI.base
    2. Download IPEX-LLM Ollama for Windows from:
         https://github.com/intel/ipex-llm/releases
       Look for: ipex-llm-ollama-windows-x64.zip
    3. Replace C:\Users\<you>\AppData\Local\Programs\Ollama\ollama.exe
       with the IPEX-LLM build (or install to a separate directory and
       update your PATH).
    4. All models, Modelfiles, and env vars set by this script remain valid.
    Expected gain: ~2x throughput vs Vulkan Ollama; correct outputs.

  BIOS PREREQUISITE
  -----------------
  Set DVMT Pre-Allocated to 2048 MB (or higher) in BIOS.
  Path typically: Advanced → Video → DVMT Pre-Allocated
  Ollama refuses Arc iGPU if it sees < 512 MB reserved VRAM.

  CONTEXT TUNING
  --------------
  If Task Manager shows < 80% memory use while running qwen3-coder-30b-a3b-tuned,
  increase its context to 32768:
    Edit: %USERPROFILE%\.ollama\modelfiles\qwen3-coder-30b-a3b-tuned.Modelfile
    Change PARAMETER num_ctx to 32768
    Then: ollama create qwen3-coder-30b-a3b-tuned -f <path>

  THINKING MODE
  -------------
  Start prompt with /think    — chain-of-thought (slow, thorough)
  Start prompt with /no_think — fast interactive (default)
  On this hardware, keep /no_think for day-to-day use — fewer tokens
  = less memory pressure duration.

  QWEN3 SAMPLING PRESETS (written to Modelfiles)
  -----------------------------------------------
  temperature=0.7  top_p=0.8  top_k=20  repeat_penalty=1.05
  Differs from Qwen2.5 defaults — update LM Studio presets manually.

  LM STUDIO
  ---------
  GPU Offload: set to 100%, then reduce if you see out-of-memory errors.
  For Intel Arc, LM Studio uses llama.cpp's Vulkan backend — same caveats
  as Ollama apply. IPEX-LLM has no LM Studio integration (Ollama API only).

  OLLAMA QUICK REFERENCE
  ----------------------
  ollama list                          # installed models
  ollama run qwen3-14b-tuned           # interactive chat
  ollama ps                            # check what's loaded
  ollama stop <model>                  # unload from memory

"@ -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-Header 'Config-Windows-165H.ps1 — Core Ultra 165H / 32GB shared memory'

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
