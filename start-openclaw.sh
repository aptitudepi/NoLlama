#!/usr/bin/env bash
# start-openclaw.sh — launch the agent stack in one command (Linux):
# NoLlama (serving a coder model, with prefix caching + startup pre-warm) +
# OpenClaw (the coding agent that talks to it).
#
# First-time OpenClaw install (once):
#   npm install -g openclaw@latest
#   openclaw onboard --install-daemon
# Then point OpenClaw at NoLlama with this script's -Setup switch (once):
#   ./start-openclaw.sh -Setup
#
# Tools need a GPU/iGPU or CPU slot (not the NPU). On a weak desktop iGPU, CPU is
# often faster; on a laptop ARC 140V, GPU is the better pick.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="$SELF_DIR/venv/bin/python"
NOLLAMA="$SELF_DIR/nollama.py"
API_BASE="http://localhost:8000"

MODEL_DIR="${MODEL_DIR:-${HOME}/models/Qwen2.5-Coder-7B-Instruct-int4-ov}"
DEVICE="${DEVICE:-Auto}"
PORT="${PORT:-8000}"
PREWARM="${PREWARM:-prewarm.json}"
OPENCLAW_CMD="${OPENCLAW_CMD:-chat}"
SETUP=false
WARMUP=false
FORCE=false

usage() {
    echo "Usage: $0 [-Setup] [-Warmup] [-Force] [-Device Auto|CPU|GPU] [-Port 8000] [-Prewarm prewarm.json]"
    echo "       [-ModelDir <path>] [-Openclaw chat]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -Setup) SETUP=true; shift ;;
        -Warmup) WARMUP=true; shift ;;
        -Force) FORCE=true; shift ;;
        -Device) DEVICE="$2"; shift 2 ;;
        -Port) PORT="$2"; shift 2 ;;
        -Prewarm) PREWARM="$2"; shift 2 ;;
        -ModelDir) MODEL_DIR="$2"; shift 2 ;;
        -Openclaw) OPENCLAW_CMD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

R="\e[31m" G="\e[32m" Y="\e[33m" C="\e[36m" GR="\e[90m" NC="\e[0m"

# Resolve PREWARM to absolute path
if [[ "$PREWARM" != /* ]]; then
    PREWARM="$SELF_DIR/$PREWARM"
fi

# Model display name: strip OpenVINO suffixes
model_name="$(basename "$MODEL_DIR")"
for sfx in '-ov' '-openvino' '-int8' '-int4'; do
    if [[ "$model_name" == *"$sfx" ]]; then
        model_name="${model_name%$sfx}"
    fi
done

# Resolve "Auto": prefer GPU, else CPU
if [[ "$DEVICE" == "Auto" ]]; then
    if [[ -x "$VENV_PYTHON" ]]; then
        detected=$("$VENV_PYTHON" -c "import openvino as ov; print('GPU' if 'GPU' in ov.Core().available_devices else 'CPU')" 2>/dev/null || echo "CPU")
    else
        detected="CPU"
    fi
    DEVICE="$detected"
fi

echo -e "${GR}Device: $DEVICE${NC}"

# --- OpenClaw config setup ---
invoke_setup() {
    if ! command -v openclaw &>/dev/null; then
        echo -e "${R}openclaw not found. Install it first:${NC}" >&2
        echo -e "${Y}  npm install -g openclaw@latest${NC}" >&2
        echo -e "${Y}  openclaw onboard --install-daemon${NC}" >&2
        exit 1
    fi

    echo -e "${C}Configuring OpenClaw for NoLlama ($API_BASE/v1, $model_name, coding profile)${NC}"
    patch_file=$(mktemp /tmp/nollama-provider.patch.XXXXXX.json5)
    cat > "$patch_file" << PATCHEOF
{
  models: { providers: { nollama: {
    baseUrl: "$API_BASE/v1",
    apiKey: "local-no-auth",
    api: "openai-completions",
    timeoutSeconds: 600,
    models: [ { id: "$model_name", name: "NoLlama $model_name ($DEVICE)", contextWindow: 32768, maxTokens: 8192 } ],
  }}},
  agents: { defaults: {
    model: { primary: "nollama/$model_name" },
    memorySearch: { enabled: false },
    startupContext: { enabled: false },
  }},
  tools: {
    profile: "coding",
    web: { search: { enabled: false }, x_search: { enabled: false } },
  },
}
PATCHEOF
    openclaw config patch --file "$patch_file" --replace-path "models.providers.nollama.models"
    rm -f "$patch_file"
}

# --- Health check ---
get_health() {
    curl -sf "$API_BASE/health" 2>/dev/null || true
}

# --- Check NoLlama is agent-ready ---
get_problems() {
    local h="$1"
    local problems=()
    if [[ -z "$h" ]]; then echo "no-health"; return; fi
    if ! echo "$h" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('prompt_cache') else 1)" 2>/dev/null; then
        problems+=("prefix caching is OFF")
    fi
    if ! echo "$h" | python3 -c "
import json,sys
d=json.load(sys.stdin)
devices = d.get('devices',{})
has_tool = any(
    v.get('type')=='llm' and v.get('tools') and v.get('status') in ('ready','idle_unloaded')
    for v in devices.values()
)
exit(0 if has_tool else 1)
" 2>/dev/null; then
        problems+=("no tool-capable GPU/CPU LLM slot loaded")
    fi
    printf '%s\n' "${problems[@]}"
}

# --- Port killing ---
stop_nollama_on_port() {
    local pids
    pids=$(fuser "$PORT/tcp" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo -e "${GR}  stopping process(es) on :$PORT${NC}"
        fuser -k "$PORT/tcp" 2>/dev/null || true
        sleep 2
        return 0
    fi
    return 1
}

# --- Start NoLlama ---
NOLLAMA_PID=""
cleanup() {
    if [[ -n "$NOLLAMA_PID" ]] && kill -0 "$NOLLAMA_PID" 2>/dev/null; then
        echo -e "${C}Stopping NoLlama...${NC}"
        kill "$NOLLAMA_PID" 2>/dev/null || true
        wait "$NOLLAMA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

start_nollama() {
    local log_file="$SELF_DIR/nollama-openclaw.log"
    if [[ ! -x "$VENV_PYTHON" ]]; then
        echo -e "${R}venv python not found at $VENV_PYTHON - run install.sh first.${NC}" >&2
        exit 1
    fi

    echo -e "${C}Starting NoLlama ($DEVICE, $model_name) on :$PORT${NC}"
    echo -e "${GR}  logs -> $log_file${NC}"

    nohup "$VENV_PYTHON" "$NOLLAMA" \
        --model-dir "$MODEL_DIR" --device "$DEVICE" \
        --port "$PORT" --idle-timeout 0 --prewarm "$PREWARM" \
        > "$log_file" 2>&1 &
    NOLLAMA_PID=$!

    echo -n "  waiting for ready"
    for i in $(seq 1 150); do
        sleep 2
        if get_health >/dev/null; then
            echo ""
            echo -e "${G}NoLlama ready.${NC}"
            return 0
        fi
        if ! kill -0 "$NOLLAMA_PID" 2>/dev/null; then
            break
        fi
        echo -n "."
    done
    echo ""
    echo -e "${R}NoLlama did not come up - last log lines:${NC}" >&2
    tail -20 "$log_file" 2>/dev/null || true
    kill "$NOLLAMA_PID" 2>/dev/null || true
    exit 1
}

# --- Check if OpenClaw has a nollama provider ---
test_nollama_provider() {
    if ! command -v openclaw &>/dev/null; then return 0; fi
    local val
    val=$(openclaw config get models.providers.nollama.baseUrl 2>/dev/null || true)
    [[ -n "$val" ]]
}

# --- Main ---
if $SETUP; then
    invoke_setup
elif ! test_nollama_provider; then
    echo -e "${Y}OpenClaw has no 'nollama' provider - running setup automatically.${NC}"
    invoke_setup
fi

OWN_SERVER=false
SERVER_PID=""
HEALTH=$(get_health)

if [[ -n "$HEALTH" ]]; then
    problems=$(get_problems "$HEALTH")
    if [[ -z "$problems" ]]; then
        echo -e "${G}NoLlama already running on :$PORT and looks good (caching on, tool-capable slot) — reusing it.${NC}"
    else
        echo -e "${Y}A NoLlama is running on :$PORT but it's not set up for agents:${NC}" >&2
        while IFS= read -r prob; do
            [[ -n "$prob" ]] && echo -e "  ${Y}- $prob${NC}" >&2
        done <<< "$problems"
        echo -e "${GR}A correct start would be:${NC}" >&2
        echo -e "${GR}  python nollama.py --model-dir \"$MODEL_DIR\" --device $DEVICE --idle-timeout 0 --prewarm \"$PREWARM\"${NC}" >&2
        RESTART=$FORCE
        if ! $FORCE; then
            read -r -p "Stop that NoLlama and start a correctly-configured one? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] && RESTART=true
        fi
        if ! $RESTART; then
            echo -e "${Y}Leaving it as-is. Stop it and re-run, or fix its flags.${NC}" >&2
            exit 1
        fi
        stop_nollama_on_port
        start_nollama
        OWN_SERVER=true
    fi
else
    start_nollama
    OWN_SERVER=true
fi

# Warmup logic
if [[ -f "$PREWARM" ]]; then
    echo -e "${GR}prewarm.json present - NoLlama pre-warmed the cache at startup; first turn is already fast.${NC}"
elif $WARMUP; then
    echo -e "${C}No prewarm.json yet - warming up (one throwaway turn builds it + warms the cache)...${NC}"
    openclaw agent --local --session-id _warmup --message "Reply with exactly: ok" --timeout 600 2>&1 | tail -2
    echo -e "${G}Warmup done.${NC}"
fi

echo -e "${G}Launching OpenClaw ($OPENCLAW_CMD)...${NC}"
openclaw "$OPENCLAW_CMD"
