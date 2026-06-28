#requires -Version 7.0
# start-openclaw.ps1 — launch the agent stack in one command:
# NoLlama (serving a coder model, with prefix caching + startup pre-warm) +
# OpenCLAW (the coding agent that talks to it). NoLlama's own --prewarm does the
# cache pre-fill; this script just wires the two together with the right flags.
#
# Prereqs (one-time): the model is downloaded, and OpenCLAW's openclaw.json has a
# `nollama` provider pointing at http://localhost:<port>/v1 with the matching
# model id. See OPENCLAW-PLAN.md.
#
# Tools need a GPU/iGPU or CPU slot (not the NPU). On a weak desktop iGPU, CPU is
# often faster; on a laptop ARC 140V, GPU is the better pick.

param(
    [string]$ModelDir = (Join-Path $env:USERPROFILE "models\Qwen2.5-Coder-7B-Instruct-int4-ov"),
    [ValidateSet("CPU", "GPU")]
    [string]$Device   = "CPU",
    [int]$Port        = 8000,
    [string]$Prewarm  = "prewarm.json",   # prefix-cache pre-warm file (auto-captured on first big prompt)
    [string]$Openclaw = "chat"            # openclaw subcommand to run once NoLlama is ready
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvBin   = if ($IsWindows) { "Scripts" } else { "bin" }
$Activate  = Join-Path $ScriptDir "venv" $VenvBin "Activate.ps1"
$NoLlama   = Join-Path $ScriptDir "nollama.py"
if (-not [System.IO.Path]::IsPathRooted($Prewarm)) { $Prewarm = Join-Path $ScriptDir $Prewarm }

$ApiUrl = "http://localhost:$Port/v1/models"

function Test-NoLlamaUp {
    try { Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

# If NoLlama is already serving on this port, reuse it (don't start/stop a second).
$ownServer = $false
$server = $null

if (Test-NoLlamaUp) {
    Write-Host "NoLlama already running on :$Port — reusing it." -ForegroundColor Green
} else {
    $LogFile = Join-Path $ScriptDir "nollama-openclaw.log"
    Write-Host "Starting NoLlama ($Device, $(Split-Path $ModelDir -Leaf)) on :$Port" -ForegroundColor Cyan
    Write-Host "  logs -> $LogFile" -ForegroundColor DarkGray
    $ownServer = $true
    $server = Start-Job -ScriptBlock {
        param($act, $py, $md, $dev, $port, $pw, $log)
        & $act
        & python $py --model-dir $md --device $dev --port $port --idle-timeout 0 --prewarm $pw *>&1 |
            Tee-Object -FilePath $log
    } -ArgumentList $Activate, $NoLlama, $ModelDir, $Device, $Port, $Prewarm, $LogFile

    Write-Host -NoNewline "  waiting for ready"
    $ready = $false
    foreach ($i in 1..150) {            # up to ~5 min (cold load + pre-warm on a slow box)
        Start-Sleep -Seconds 2
        if (Test-NoLlamaUp) { $ready = $true; break }
        if ($server.State -in @("Failed", "Completed")) { break }
        Write-Host -NoNewline "."
    }
    Write-Host ""
    if (-not $ready) {
        Write-Host "NoLlama did not come up — last log lines:" -ForegroundColor Red
        Receive-Job $server -ErrorAction SilentlyContinue | Select-Object -Last 25
        Stop-Job $server -ErrorAction SilentlyContinue
        Remove-Job $server -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "NoLlama ready." -ForegroundColor Green
}

try {
    Write-Host "Launching OpenCLAW ($Openclaw)..." -ForegroundColor Green
    & openclaw $Openclaw
}
finally {
    if ($ownServer -and $server) {
        Write-Host "Stopping NoLlama..." -ForegroundColor Cyan
        Stop-Job $server -ErrorAction SilentlyContinue
        Remove-Job $server -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Left the existing NoLlama running." -ForegroundColor DarkGray
    }
}
