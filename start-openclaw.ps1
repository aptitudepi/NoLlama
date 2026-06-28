#requires -Version 7.0
# start-openclaw.ps1 — launch the agent stack in one command:
# NoLlama (serving a coder model, with prefix caching + startup pre-warm) +
# OpenCLAW (the coding agent that talks to it). The NoLlama equivalent of
# `ollama launch openclaw`.
#
# First-time OpenCLAW install (once):
#   npm install -g openclaw@latest
#   openclaw onboard --install-daemon
# Then point OpenCLAW at NoLlama with this script's -Setup switch (once):
#   ./start-openclaw.ps1 -Setup
#
# Tools need a GPU/iGPU or CPU slot (not the NPU). On a weak desktop iGPU, CPU is
# often faster; on a laptop ARC 140V, GPU is the better pick.

param(
    [string]$ModelDir = (Join-Path $env:USERPROFILE "models\Qwen2.5-Coder-7B-Instruct-int4-ov"),
    [ValidateSet("Auto", "CPU", "GPU")]
    [string]$Device   = "Auto",   # Auto: prefer a real Intel GPU, else CPU
    [int]$Port        = 8000,
    [string]$Prewarm  = "prewarm.json",   # prefix-cache pre-warm file (auto-captured on first big prompt)
    [string]$Openclaw = "chat",           # openclaw subcommand to run once NoLlama is ready
    [switch]$Setup,                        # (re)write OpenCLAW's NoLlama config (provider + coding profile), then continue
    [switch]$Warmup,                       # fire one throwaway turn first to build prewarm.json + warm the cache
    [switch]$Force                         # if a running NoLlama is unsuitable, stop+restart it without prompting
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvBin   = if ($IsWindows) { "Scripts" } else { "bin" }
$NoLlama   = Join-Path $ScriptDir "nollama.py"
$PyExe     = Join-Path $ScriptDir "venv" $VenvBin ($(if ($IsWindows) { "python.exe" } else { "python" }))
if (-not [System.IO.Path]::IsPathRooted($Prewarm)) { $Prewarm = Join-Path $ScriptDir $Prewarm }

$ApiBase   = "http://localhost:$Port"

# NoLlama's model_display_name(): strip the OpenVINO suffixes to get the served id.
$ModelName = Split-Path $ModelDir -Leaf
foreach ($sfx in '-ov', '-openvino', '-int8', '-int4') {
    if ($ModelName.EndsWith($sfx)) { $ModelName = $ModelName.Substring(0, $ModelName.Length - $sfx.Length) }
}

function Get-Health {
    try { return Invoke-RestMethod -Uri "$ApiBase/health" -TimeoutSec 3 } catch { return $null }
}

# Resolve "Auto": prefer a real Intel GPU, else CPU (tools run on GPU/CPU, never
# the NPU). Uses OpenVINO's own device list — the same source NoLlama uses.
function Resolve-Device {
    param([string]$Requested)
    if ($Requested -ne "Auto") { return $Requested }
    if (Test-Path $PyExe) {
        try {
            $d = (& $PyExe -c "import openvino as ov; print('GPU' if 'GPU' in ov.Core().available_devices else 'CPU')" 2>$null | Select-Object -Last 1)
            if ("$d".Trim() -eq "GPU") { return "GPU" }
        } catch {}
    }
    return "CPU"
}

# A running NoLlama is usable for OpenCLAW only if prefix caching is on AND there's
# a tool-capable GPU/CPU LLM slot. Returns the list of problems ([] = good).
function Get-Problems($h) {
    $problems = @()
    if (-not $h.prompt_cache) { $problems += "prefix caching is OFF (started with --no-prompt-cache, or an old build)" }
    $hasTool = $false
    if ($h.devices) {
        foreach ($p in $h.devices.PSObject.Properties) {
            $d = $p.Value
            if ($d.type -eq 'llm' -and $d.tools -and $d.status -in @('ready', 'idle_unloaded')) { $hasTool = $true }
        }
    }
    if (-not $hasTool) { $problems += "no tool-capable GPU/CPU LLM slot loaded (NPU/VLM can't drive agents)" }
    return $problems
}

function Stop-NoLlamaOnPort {
    if ($IsWindows) {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        $procIds = @($conns.OwningProcess | Sort-Object -Unique)
        foreach ($procId in $procIds) {
            Write-Host "  stopping process $procId on :$Port" -ForegroundColor DarkGray
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
        return $procIds.Count -gt 0
    }
    Write-Host "  Can't auto-stop on this OS — stop NoLlama yourself (Ctrl+C) and re-run." -ForegroundColor Yellow
    return $false
}

function Start-NoLlama {
    $LogFile = Join-Path $ScriptDir "nollama-openclaw.log"
    $ErrFile = "$LogFile.err"
    if (-not (Test-Path $PyExe)) {
        Write-Host "venv python not found at $PyExe - run install.ps1 first." -ForegroundColor Red
        exit 1
    }
    $pyArgs = @($NoLlama, "--model-dir", $ModelDir, "--device", $Device,
                "--port", "$Port", "--idle-timeout", "0", "--prewarm", $Prewarm)
    Write-Host "Starting NoLlama ($Device, $ModelName) on :$Port" -ForegroundColor Cyan
    Write-Host "  logs -> $LogFile" -ForegroundColor DarkGray
    # Start-Process (not Start-Job): a job spins a child PowerShell runspace, which
    # fails on locked-down machines (ConstrainedLanguage / AppLocker / WDAC) with a
    # language-mode mismatch. A plain process launch of the venv python avoids that.
    $proc = Start-Process -FilePath $PyExe -ArgumentList $pyArgs -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError $ErrFile

    Write-Host -NoNewline "  waiting for ready"
    foreach ($i in 1..150) {            # up to ~5 min (cold load + pre-warm on a slow box)
        Start-Sleep -Seconds 2
        if (Get-Health) { Write-Host ""; Write-Host "NoLlama ready." -ForegroundColor Green; return $proc }
        if ($proc.HasExited) { break }
        Write-Host -NoNewline "."
    }
    Write-Host ""
    Write-Host "NoLlama did not come up - last log lines:" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 -ErrorAction SilentlyContinue }
    if (Test-Path $ErrFile) { Get-Content $ErrFile -Tail 10 -ErrorAction SilentlyContinue }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

function Invoke-Setup {
    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
        Write-Host "openclaw not found. Install it first:" -ForegroundColor Red
        Write-Host "  npm install -g openclaw@latest" -ForegroundColor Yellow
        Write-Host "  openclaw onboard --install-daemon" -ForegroundColor Yellow
        exit 1
    }
    # Self-healing config: provider + default model + a coding-agent-friendly tool
    # set. Re-runnable any time (idempotent) to restore our settings — npm package
    # updates don't touch ~/.openclaw/openclaw.json, but re-onboarding might, so
    # this is the recovery path.
    Write-Host "Configuring OpenCLAW for NoLlama ($ApiBase/v1, $ModelName, coding profile)" -ForegroundColor Cyan
    $patch = @"
{
  models: { providers: { nollama: {
    baseUrl: "$ApiBase/v1",
    apiKey: "local-no-auth",
    api: "openai-completions",
    timeoutSeconds: 600,
    models: [ { id: "$ModelName", name: "NoLlama $ModelName ($Device)", contextWindow: 32768, maxTokens: 8192 } ],
  }}},
  agents: { defaults: {
    model: { primary: "nollama/$ModelName" },
    memorySearch: { enabled: false },
    startupContext: { enabled: false },
  }},
  tools: {
    profile: "coding",
    web: { search: { enabled: false }, x_search: { enabled: false } },
  },
}
"@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "nollama-provider.patch.json5"
    Set-Content -Path $tmp -Value $patch -Encoding utf8
    & openclaw config patch --file $tmp --replace-path "models.providers.nollama.models"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

function Test-NollamaProvider {
    # Is OpenCLAW's `nollama` provider configured on this machine?
    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) { return $true }  # can't check; assume ok
    $v = (& openclaw config get models.providers.nollama.baseUrl 2>$null)
    return -not [string]::IsNullOrWhiteSpace("$v")
}

# --- main ---------------------------------------------------------------------
$Device = Resolve-Device $Device
Write-Host "Device: $Device" -ForegroundColor DarkGray

if ($Setup) {
    Invoke-Setup
} elseif (-not (Test-NollamaProvider)) {
    Write-Host "OpenCLAW has no 'nollama' provider on this machine - running setup automatically." -ForegroundColor Yellow
    Invoke-Setup
}

$ownServer = $false
$server = $null
$health = Get-Health

if ($health) {
    $problems = Get-Problems $health
    if ($problems.Count -eq 0) {
        Write-Host "NoLlama already running on :$Port and looks good (caching on, tool-capable slot) — reusing it." -ForegroundColor Green
    } else {
        Write-Host "A NoLlama is running on :$Port but it's not set up for agents:" -ForegroundColor Yellow
        $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "A correct start would be:" -ForegroundColor DarkGray
        Write-Host "  python nollama.py --model-dir `"$ModelDir`" --device $Device --idle-timeout 0 --prewarm `"$Prewarm`"" -ForegroundColor DarkGray
        $restart = $Force
        if (-not $Force) {
            $ans = Read-Host "Stop that NoLlama and start a correctly-configured one? [y/N]"
            $restart = ($ans -match '^[Yy]')
        }
        if (-not $restart) {
            Write-Host "Leaving it as-is. Stop it and re-run, or fix its flags." -ForegroundColor Yellow
            exit 1
        }
        if (-not (Stop-NoLlamaOnPort)) { exit 1 }
        $server = Start-NoLlama; $ownServer = $true
    }
} else {
    $server = Start-NoLlama; $ownServer = $true
}

try {
    # When prewarm.json already exists, NoLlama prefilled it at startup (--prewarm),
    # so the cache is already warm — a -Warmup throwaway turn would be redundant.
    # -Warmup only does work when the file is MISSING: one throwaway turn builds it
    # (and warms the live cache) so even the first real turn is fast.
    if (Test-Path $Prewarm) {
        Write-Host "prewarm.json present - NoLlama pre-warmed the cache at startup; first turn is already fast." -ForegroundColor DarkGray
    } elseif ($Warmup) {
        Write-Host "No prewarm.json yet - warming up (one throwaway turn builds it + warms the cache)..." -ForegroundColor Cyan
        & openclaw agent --local --session-id _warmup --message "Reply with exactly: ok" --timeout 600 2>&1 |
            Select-Object -Last 2
        Write-Host "Warmup done." -ForegroundColor Green
    }
    Write-Host "Launching OpenCLAW ($Openclaw)..." -ForegroundColor Green
    & openclaw $Openclaw
}
finally {
    if ($ownServer -and $server) {
        Write-Host "Stopping NoLlama..." -ForegroundColor Cyan
        if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    } elseif ($health) {
        Write-Host "Left the existing NoLlama running." -ForegroundColor DarkGray
    }
}
