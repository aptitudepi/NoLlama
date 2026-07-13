#!/usr/bin/env bash
# install.sh — NoLlama Linux setup: venv, dependencies, model selection
#
# Usage:
#     ./install.sh                       # interactive setup
#     ./install.sh --skip-model            # venv + deps only
#     ./install.sh --hf-token hf_xxx       # auth for gated/private models
#
# Detects available devices (NPU, GPU, CPU), then asks what you want to DO
# (chat / coding agent / vision / combos) and places each model on the best
# device. Coding-agent models (OpenClaw / Copilot, tool-calling) and CPU are
# first-class choices, not buried.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_ROOT="${HOME}/models"
SKIP_MODEL=false
HF_TOKEN=""

usage() { sed -n '2,9p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-model) SKIP_MODEL=true; shift ;;
        --hf-token) HF_TOKEN="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
R="\e[31m" G="\e[32m" Y="\e[33m" C="\e[36m" GR="\e[90m" BOLD="\e[1m" NC="\e[0m"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo -e "${R}ERROR: $*${NC}" >&2; exit 1; }

run_py() {
    # Run a short Python snippet, capturing stdout.
    # Automatically picks up the venv python if available.
    python3 -c "$1"
}

json_val() {
    # Extract a value from JSON via Python: json_val <json-str> <key>
    python3 -c "import json,sys; d=json.loads('$1'); print(d.get('$2',''))"
}

json_has() {
    python3 -c "import json,sys; d=json.loads('$1'); print('yes' if '$2' in d else '')"
}

if [[ -n "$HF_TOKEN" ]]; then
    export HF_TOKEN="$HF_TOKEN"
    echo -e "${GR}[+] HF token set for this session (gated/private model auth)${NC}"
fi

echo ""
echo -e "${C}=== NoLlama Install ===${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Create / validate venv
# ---------------------------------------------------------------------------
VENV_DIR="$SELF_DIR/venv"

venv_ok() {
    local pip="$VENV_DIR/bin/pip"
    [[ -f "$pip" ]] && "$pip" --version &>/dev/null
}

if [[ -d "$VENV_DIR" ]]; then
    if venv_ok; then
        echo -e "${G}[OK]${NC} venv already exists"
    else
        echo -e "${Y}[!]${NC} venv at $VENV_DIR is broken. Recreating..."
        rm -rf "$VENV_DIR"
    fi
fi

if [[ ! -d "$VENV_DIR" ]]; then
    SYS_PY=""
    for c in python3 python; do
        if command -v "$c" &>/dev/null; then SYS_PY="$c"; break; fi
    done
    [[ -z "$SYS_PY" ]] && die "Neither 'python3' nor 'python' found in PATH."
    echo "Creating Python venv (using $SYS_PY)..."
    "$SYS_PY" -m venv "$VENV_DIR"
    echo -e "${G}[OK]${NC} venv created"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "Installing dependencies..."
pip install --upgrade pip wheel setuptools &>/dev/null || true
pip install -r "$SELF_DIR/requirements.txt"
echo -e "${G}[OK]${NC} Dependencies installed"
echo ""

# ---------------------------------------------------------------------------
# 2. Detect devices
# ---------------------------------------------------------------------------
echo -e "${C}Detecting devices...${NC}"

DEVICE_JSON=$(python3 -c "
import openvino as ov, json
core = ov.Core()
out = {}
for dev in core.get_available_devices():
    try: full = core.get_property(dev, 'FULL_DEVICE_NAME')
    except: full = dev
    if dev.startswith('GPU'):
        if 'intel' not in full.lower(): continue
        if 'GPU' not in out: out['GPU'] = {'id': dev, 'name': full}
    elif dev in ('NPU', 'CPU'):
        out[dev] = {'id': dev, 'name': full}
print(json.dumps(out))
")

HAS_NPU=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'NPU' in d else '')")
HAS_GPU=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'GPU' in d else '')")
NPU_NAME=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('NPU',{}).get('name','') or '')")
GPU_NAME=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('GPU',{}).get('name','') or '')")
GPU_ID=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('GPU',{}).get('id','') or '')")
CPU_NAME=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('CPU',{}).get('name','') or '')")

echo ""
if [[ -n "$HAS_NPU" ]]; then echo -e "  ${G}[+] NPU:${NC} $NPU_NAME"
else                           echo -e "  ${GR}[-] NPU: not found${NC}"; fi
if [[ -n "$HAS_GPU" ]]; then
    gpu_sfx=""; [[ "$GPU_ID" != "GPU" ]] && gpu_sfx=" [$GPU_ID]"
    echo -e "  ${G}[+] GPU${gpu_sfx}:${NC} $GPU_NAME"
else
    echo -e "  ${GR}[-] GPU: not found (non-Intel GPUs are filtered)${NC}"
fi
echo -e "  ${GR}[+] CPU:${NC} $CPU_NAME"
echo ""

# ---------------------------------------------------------------------------
# 3. Scan existing local models in ~/models/
# ---------------------------------------------------------------------------
declare -a LOCAL_MODELS=()   # JSON strings per model: {name,path,size_gb,type,npu_ok}

if [[ -d "$MODELS_ROOT" ]]; then
    while IFS= read -r -d '' dir; do
        dir_name="$(basename "$dir")"
        vlm_bin="$dir/openvino_language_model.bin"
        llm_bin="$dir/openvino_model.bin"
        bin_path=""
        if [[ -f "$vlm_bin" ]]; then bin_path="$vlm_bin"; else bin_path="$llm_bin"; fi
        [[ -z "$bin_path" || ! -f "$bin_path" ]] && continue

        size_bytes=$(stat -c%s "$bin_path" 2>/dev/null || echo 0)
        size_gb=$(awk "BEGIN { printf \"%.1f\", $size_bytes / 1073741824 }")

        mtype="llm"
        if [[ -f "$dir/openvino_vision_embeddings_model.xml" ]]; then
            mtype="vlm"
        elif [[ -f "$dir/config.json" ]]; then
            cfg=$(python3 -c "
import json; d=json.load(open('$dir/config.json'))
arch = (d.get('architectures') or [''])[0].lower() if d.get('architectures') else ''
mt = (d.get('model_type') or '').lower()
print('vlm' if any(x in arch for x in ['vl','vision','llava','qwen2vl','internvl','minicpm']) or any(x in mt for x in ['vl','vision']) else 'llm')
")
            mtype="$cfg"
        fi

        npu_ok="no"
        if [[ "$dir_name" == *int4* ]] && awk "BEGIN { exit !($size_gb < 10) }"; then
            npu_ok="yes"
        fi

        entry=$(python3 -c "
import json; print(json.dumps({'name':'$dir_name','path':'$dir','size_gb':$size_gb,'type':'$mtype','npu_ok':'$npu_ok'}))
")
        LOCAL_MODELS+=("$entry")
    done < <(find "$MODELS_ROOT" -maxdepth 1 -type d -print0)
fi

if [[ ${#LOCAL_MODELS[@]} -gt 0 ]]; then
    echo -e "  ${GR}Local models ($MODELS_ROOT):${NC}"
    for entry in "${LOCAL_MODELS[@]}"; do
        nm=$(json_val "$entry" "name")
        sz=$(json_val "$entry" "size_gb")
        tp=$(json_val "$entry" "type")
        echo -e "    ${GR}$nm  (${sz} GB, ${tp^^})${NC}"
    done
    echo ""
fi

if $SKIP_MODEL; then
    echo "Skipping model selection (--skip-model)"
    echo ""
    echo -e "${Y}=== Install complete (no model) ===${NC}"
    deactivate 2>/dev/null || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Model registry
# ---------------------------------------------------------------------------
REGISTRY=$(cat "$SELF_DIR/models.json")

# Helper to pick items from registry by category
registry_get() { # category
    python3 -c "
import json, sys
reg = json.load(open('$SELF_DIR/models.json'))
print(json.dumps(reg.get('$1', [])))
"
}

# Check whether a cache path has a valid model (>100 MB weight file)
cache_valid() { # path
    local p="$1"
    [[ ! -d "$p" ]] && return 1
    for bin in "openvino_language_model.bin" "openvino_model.bin"; do
        local f="$p/$bin"
        if [[ -f "$f" ]]; then
            local sz
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            if [[ $sz -gt 104857600 ]]; then return 0; fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Model menu
# ---------------------------------------------------------------------------
# Returns a JSON object with the selected model, or empty string if skipped.
show_model_menu() {
    local title="$1"
    local reg_json="$2"
    shift 2
    local -a local_list=("${@}")
    local allow_skip=false
    # Check last arg for --allow-skip
    if [[ $# -gt 0 && "${@: -1}" == "--allow-skip" ]]; then
        allow_skip=true
        local_list=("${@:1:$#-1}")
    fi

    echo ""
    echo -e "${C}=== $title ===${NC}"
    echo ""

    declare -a items=()  # Each item is JSON: {action, name, path?, hf_id?, source?, weight?, trust?, size_gb, notes?}

    # On-disk models from local scan
    for entry in "${local_list[@]}"; do
        nm=$(json_val "$entry" "name")
        p=$(json_val "$entry" "path")
        sz=$(json_val "$entry" "size_gb")
        items+=("$(python3 -c "import json; print(json.dumps({'action':'local','name':'$nm','path':'$p','hf_id':None,'source':None,'weight':None,'trust':False,'size_gb':$sz,'notes':'Already on disk'}))")")
    done

    # Registry models: check if already cached, else offer download
    local local_names=""
    for entry in "${local_list[@]}"; do
        local_names+=" $(json_val "$entry" "name" | tr '[:upper:]' '[:lower:]')"
    done

    while IFS= read -r dm_raw; do
        [[ -z "$dm_raw" ]] && continue
        hf_id=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hf_id',''))")
        dm_name=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
        source=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))")
        weight=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('weight_format',''))")
        trust=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('trust_remote_code',False)))")
        est_sz=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('est_size_gb',0))")
        notes=$(echo "$dm_raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('notes',''))")

        repo_name="${hf_id##*/}"
        lc_repo=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]')
        # Skip if already in local scan
        if echo "$local_names" | grep -qw "$lc_repo"; then continue; fi

        cache_name="$repo_name"
        [[ "$source" == "convert" ]] && cache_name="${repo_name}-${weight}"
        cache_path="$MODELS_ROOT/$cache_name"

        if cache_valid "$cache_path"; then
            items+=("$(python3 -c "
import json; print(json.dumps({'action':'local','name':'${dm_name}','path':'${cache_path}','hf_id':'${hf_id}','source':'${source}','weight':'${weight}','trust':${trust},'size_gb':${est_sz},'notes':'Already on disk'}))
")")
        else
            items+=("$(python3 -c "
import json; print(json.dumps({'action':'${source}','name':'${dm_name}','path':None,'hf_id':'${hf_id}','source':'${source}','weight':'${weight}','trust':${trust},'size_gb':${est_sz},'notes':'${notes}'}))
")")
        fi
    done < <(echo "$reg_json" | python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(sys.stdin)]")

    if [[ ${#items[@]} -eq 0 ]]; then
        echo "  No models available."
        return 1
    fi

    # Display menu
    local has_disk=false
    for item in "${items[@]}"; do
        local act
        act=$(json_val "$item" "action")
        if [[ "$act" == "local" ]]; then has_disk=true; break; fi
    done

    local idx=1
    if $has_disk; then
        echo -e "  ${Y}Already on disk (instant):${NC}"
        for item in "${items[@]}"; do
            local act nm sz
            act=$(json_val "$item" "action")
            [[ "$act" != "local" ]] && continue
            nm=$(json_val "$item" "name")
            sz=$(json_val "$item" "size_gb")
            echo -e "    $idx. $nm  ${GR}($sz GB)  Already on disk${NC}"
            idx=$((idx + 1))
        done
        echo ""
    fi

    local has_dl=false
    for item in "${items[@]}"; do
        local act
        act=$(json_val "$item" "action")
        [[ "$act" != "local" ]] && has_dl=true
    done

    if $has_dl; then
        echo -e "  ${Y}Download from HuggingFace:${NC}"
        for item in "${items[@]}"; do
            local act nm est_sz dl_tag notes
            act=$(json_val "$item" "action")
            [[ "$act" == "local" ]] && continue
            nm=$(json_val "$item" "name")
            est_sz=$(json_val "$item" "size_gb")
            [[ "$act" == "pre-exported" ]] && dl_tag="download" || dl_tag="convert"
            notes=$(json_val "$item" "notes")
            echo -e "    $idx. $nm  ${GR}(~${est_sz} GB, ${dl_tag})${NC}  ${GR}$notes${NC}"
            idx=$((idx + 1))
        done
    fi

    echo ""

    local prompt="Pick a model [1-$((idx - 1))]"
    $allow_skip && prompt="$prompt or press Enter to skip"

    while true; do
        read -r -p "$prompt: " choice
        if $allow_skip && [[ -z "$choice" ]]; then
            echo ""
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $((idx - 1)) ]]; then
            local selected="${items[$((choice - 1))]}"
            echo "$selected"
            return 0
        fi
        echo -e "${R}Enter a number between 1 and $((idx - 1))${NC}" >&2
    done
}

# ---------------------------------------------------------------------------
# Model symlink (Linux: symlink; keeps the PS1 junction pattern for parity)
# ---------------------------------------------------------------------------
link_model() { # target_dir cache_path
    local target="$1" cache="$2"
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -L "$target" ]]; then
            rm -f "$target"
        else
            rm -rf "$target"
        fi
    fi
    ln -s "$cache" "$target"
}

# ---------------------------------------------------------------------------
# Install a model
# ---------------------------------------------------------------------------
install_model() {
    local selected="$1" target_dir="$2"
    local action nm path hf_id source weight trust

    action=$(json_val "$selected" "action")
    nm=$(json_val "$selected" "name")
    path=$(json_val "$selected" "path")
    hf_id=$(json_val "$selected" "hf_id")
    source=$(json_val "$selected" "source")
    weight=$(json_val "$selected" "weight")
    trust=$(json_val "$selected" "trust")

    if [[ "$action" == "local" ]]; then
        echo -e "${G}Linking to:${NC} $path"
        link_model "$target_dir" "$path"
        echo -e "${G}[OK]${NC} $nm"
        return 0
    fi

    if [[ "$action" == "pre-exported" ]]; then
        local cache_name="${hf_id##*/}"
        local cache_path="$MODELS_ROOT/$cache_name"

        if cache_valid "$cache_path"; then
            echo -e "${G}Using cached${NC} $nm at $cache_path"
        else
            if [[ -d "$cache_path" ]]; then
                echo -e "${GR}  Found incomplete cache at $cache_path, removing.${NC}"
                rm -rf "$cache_path"
            fi
            mkdir -p "$MODELS_ROOT"
            echo -e "${C}Downloading $nm...${NC}"
            echo "  From: $hf_id"
            echo "  To:   $cache_path"
            echo ""
            export PYTHONIOENCODING=utf-8
            hf download "$hf_id" --local-dir "$cache_path"
            if [[ $? -ne 0 ]]; then
                echo -e "${R}ERROR: Download failed.${NC}" >&2
                echo -e "${Y}  If 401/403 (gated/private model): re-run with a token --${NC}" >&2
                echo -e "${Y}    ./install.sh --hf-token hf_xxx${NC}" >&2
                return 1
            fi
        fi

        link_model "$target_dir" "$cache_path"
        echo -e "${G}[OK]${NC} $nm"
        return 0
    fi

    if [[ "$action" == "convert" ]]; then
        local cache_name="${hf_id##*/}-${weight}"
        local cache_path="$MODELS_ROOT/$cache_name"

        if cache_valid "$cache_path"; then
            echo -e "${G}Using cached${NC} $nm at $cache_path"
        else
            if [[ -d "$cache_path" ]]; then
                echo -e "${GR}  Found incomplete cache at $cache_path, removing.${NC}"
                rm -rf "$cache_path"
            fi
            mkdir -p "$MODELS_ROOT"
            echo -e "${C}Converting $nm...${NC}"
            echo "  From: $hf_id"
            echo "  To:   $cache_path"
            echo "  This may take 5-20 minutes."
            echo ""
            local -a args=(export openvino --model "$hf_id" --weight-format "$weight")
            [[ "$trust" == "True" ]] && args+=(--trust-remote-code)
            args+=("$cache_path")
            echo -e "${GR}Running: optimum-cli ${args[*]}${NC}"
            optimum-cli "${args[@]}"
            if [[ $? -ne 0 ]]; then
                echo -e "${R}ERROR: Conversion failed.${NC}" >&2
                echo -e "${Y}  If unsupported architecture: needs newer optimum-intel${NC}" >&2
                return 1
            fi
        fi

        link_model "$target_dir" "$cache_path"
        echo -e "${G}[OK]${NC} $nm"
        return 0
    fi

    echo -e "${R}ERROR: Unknown action '$action'${NC}" >&2
    return 1
}

# ---------------------------------------------------------------------------
# 4. Model selection — use-case first
# ---------------------------------------------------------------------------
MODEL_DIR="$SELF_DIR/model"
GPU_MODEL_DIR="$SELF_DIR/gpu-model"
START_ARGS=()

select_device() {
    local purpose="$1" note="$2"
    shift 2
    local -a choices=("$@")
    if [[ ${#choices[@]} -eq 1 ]]; then echo "${choices[0]}"; return; fi
    echo ""
    echo -e "  ${C}Run $purpose on which device?${NC}"
    [[ -n "$note" ]] && echo -e "    ${GR}$note${NC}"
    for i in "${!choices[@]}"; do echo "    $((i+1)). ${choices[$i]}"; done
    while true; do
        read -r -p "  [1-${#choices[@]}]: " c
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ $c -ge 1 ]] && [[ $c -le ${#choices[@]} ]]; then
            echo "${choices[$((c-1))]}"
            return
        fi
        echo -e "  ${R}Enter 1-${#choices[@]}${NC}" >&2
    done
}

chat_registry() {
    local dev="$1"
    if [[ "$dev" == "NPU" ]]; then registry_get "npu"
    else
        python3 -c "
import json
reg = json.load(open('$SELF_DIR/models.json'))
all_models = reg.get('npu', []) + reg.get('gpu_llm', [])
print(json.dumps(all_models))
"
    fi
}

chat_local() {
    local dev="$1" exclude="${2:-}"
    for entry in "${LOCAL_MODELS[@]}"; do
        local tp nm npu_ok
        tp=$(json_val "$entry" "type")
        nm=$(json_val "$entry" "name")
        npu_ok=$(json_val "$entry" "npu_ok")
        # Skip excluded
        [[ "$nm" == "$exclude" ]] && continue
        [[ "$tp" != "llm" ]] && continue
        if [[ "$dev" == "NPU" && "$npu_ok" != "yes" ]]; then continue; fi
        echo "$entry"
    done
}

install_primary() {
    local sel="$1" dev="$2"
    if ! install_model "$sel" "$MODEL_DIR"; then
        echo -e "${Y}Model installation failed. Re-run install.sh to retry.${NC}" >&2
        deactivate 2>/dev/null || true
        exit 1
    fi
    START_ARGS+=(--device "$dev")
}

# --- Use-case menu ---
echo ""
echo -e "${C}=== What will you use NoLlama for? ===${NC}"
echo ""

declare -a CASES=()
CASES+=("chat|Chat|text assistant")
CASES+=("agent|Coding agent|OpenClaw / VS Code Copilot (tool-calling)")
if [[ -n "$HAS_GPU" ]]; then
    CASES+=("vision|Vision|image understanding (GPU)")
    CASES+=("chat+agent|Chat + Coding agent|chat model + a GPU coder, together")
    CASES+=("chat+vision|Chat + Vision|chat model + GPU vision (classic)")
fi

for i in "${!CASES[@]}"; do
    IFS='|' read -r key label desc <<< "${CASES[$i]}"
    echo -e "  $((i+1)). $label  ${GR}$desc${NC}"
done
echo ""

use_key=""
while [[ -z "$use_key" ]]; do
    read -r -p "Pick [1-${#CASES[@]}]: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [[ $c -ge 1 ]] && [[ $c -le ${#CASES[@]} ]]; then
        IFS='|' read -r use_key _ _ <<< "${CASES[$((c-1))]}"
    else
        echo -e "${R}Enter 1-${#CASES[@]}${NC}" >&2
    fi
done

CHAT_DEVICES=()
[[ -n "$HAS_NPU" ]] && CHAT_DEVICES+=("NPU")
[[ -n "$HAS_GPU" ]] && CHAT_DEVICES+=("GPU")
CHAT_DEVICES+=("CPU")

AGENT_DEVICES=()
[[ -n "$HAS_GPU" ]] && AGENT_DEVICES+=("GPU")
AGENT_DEVICES+=("CPU")

coders_json=$(registry_get "gpu_llm" | python3 -c "
import json,sys; 
models = json.load(sys.stdin)
print(json.dumps([m for m in models if m.get('agent')]))
")

IS_AGENT=false

case "$use_key" in
    "chat")
        dev=$(select_device "chat" "" "${CHAT_DEVICES[@]}")
        # Build local list for chat on this device
        declare -a chat_loc=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && chat_loc+=("$entry")
        done < <(chat_local "$dev")
        reg=$(chat_registry "$dev")
        sel=$(show_model_menu "Chat model ($dev)" "$reg" "${chat_loc[@]}") || true
        if [[ -n "$sel" ]]; then install_primary "$sel" "$dev"; fi
        ;;
    "agent")
        dev=$(select_device "the coding agent" "GPU is usually faster; CPU often wins on strong desktops / weak iGPUs." "${AGENT_DEVICES[@]}")
        declare -a agent_loc=()
        for entry in "${LOCAL_MODELS[@]}"; do
            tp=$(json_val "$entry" "type")
            [[ "$tp" == "llm" ]] && agent_loc+=("$entry")
        done
        sel=$(show_model_menu "Coding agent model ($dev) - OpenClaw / Copilot ready" "$coders_json" "${agent_loc[@]}") || true
        if [[ -n "$sel" ]]; then
            install_primary "$sel" "$dev"
            START_ARGS+=(--prewarm "prewarm.json" --vscode-compat)
            IS_AGENT=true
        fi
        ;;
    "vision")
        declare -a vis_loc=()
        for entry in "${LOCAL_MODELS[@]}"; do
            tp=$(json_val "$entry" "type")
            [[ "$tp" == "vlm" ]] && vis_loc+=("$entry")
        done
        sel=$(show_model_menu "Vision model (GPU)" "$(registry_get 'gpu_vlm')" "${vis_loc[@]}") || true
        if [[ -n "$sel" ]]; then install_primary "$sel" "GPU"; fi
        ;;
    "chat+agent")
        chat_dev="CPU"; [[ -n "$HAS_NPU" ]] && chat_dev="NPU"
        declare -a chat_loc_a=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && chat_loc_a+=("$entry")
        done < <(chat_local "$chat_dev")
        chat_sel=$(show_model_menu "Chat model ($chat_dev)" "$(chat_registry $chat_dev)" "${chat_loc_a[@]}") || true
        if [[ -n "$chat_sel" ]]; then
            chat_name=$(json_val "$chat_sel" "name")
            install_primary "$chat_sel" "$chat_dev"
            declare -a coder_loc=()
            for entry in "${LOCAL_MODELS[@]}"; do
                tp=$(json_val "$entry" "type"); nm=$(json_val "$entry" "name")
                [[ "$tp" == "llm" && "$nm" != "$chat_name" ]] && coder_loc+=("$entry")
            done
            # Allow skip for secondary
            coder_sel=$(show_model_menu "Coding agent model (GPU) - OpenClaw / Copilot ready" "$coders_json" "${coder_loc[@]}" --allow-skip) || true
            if [[ -n "$coder_sel" ]]; then
                if install_model "$coder_sel" "$GPU_MODEL_DIR"; then
                    START_ARGS+=(--gpu-model-dir "gpu-model" --prewarm "prewarm.json" --vscode-compat)
                    IS_AGENT=true
                fi
            fi
        fi
        ;;
    "chat+vision")
        chat_dev="CPU"; [[ -n "$HAS_NPU" ]] && chat_dev="NPU"
        declare -a chat_loc_v=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && chat_loc_v+=("$entry")
        done < <(chat_local "$chat_dev")
        chat_sel=$(show_model_menu "Chat model ($chat_dev)" "$(chat_registry $chat_dev)" "${chat_loc_v[@]}") || true
        if [[ -n "$chat_sel" ]]; then
            chat_name=$(json_val "$chat_sel" "name")
            install_primary "$chat_sel" "$chat_dev"
            declare -a vis_loc2=()
            for entry in "${LOCAL_MODELS[@]}"; do
                tp=$(json_val "$entry" "type"); nm=$(json_val "$entry" "name")
                [[ "$tp" == "vlm" && "$nm" != "$chat_name" ]] && vis_loc2+=("$entry")
            done
            vis_sel=$(show_model_menu "Vision model (GPU)" "$(registry_get 'gpu_vlm')" "${vis_loc2[@]}" --allow-skip) || true
            if [[ -n "$vis_sel" ]]; then
                install_model "$vis_sel" "$GPU_MODEL_DIR" || true
                START_ARGS+=(--gpu-model-dir "gpu-model")
            fi
        fi
        ;;
esac

if $IS_AGENT; then
    echo ""
    echo -e "${G}Coding agent ready. To drive it with OpenClaw:${NC}"
    echo -e "  ${GR}npm install -g openclaw@latest      # once${NC}"
    echo -e "  ${GR}openclaw onboard --install-daemon   # once${NC}"
    echo -e "  ${Y}./start-openclaw.sh -Setup -Warmup # configures + launches the agent${NC}"
fi

# ---------------------------------------------------------------------------
# 5. Generate start.sh
# ---------------------------------------------------------------------------
START_SCRIPT="$SELF_DIR/start.sh"
ARGS_STR="${START_ARGS[*]}"

cat > "$START_SCRIPT" << GENEOF
#!/usr/bin/env bash
# Auto-generated by install.sh
set -euo pipefail
exec bash "${SELF_DIR}/start-template.sh" ${ARGS_STR}
GENEOF
chmod +x "$START_SCRIPT"
echo -e "${G}[OK]${NC} Generated start.sh"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${G}=== NoLlama install complete ===${NC}"
echo ""
echo "To start the server:"
echo "  ./start.sh"
echo ""

deactivate 2>/dev/null || true
