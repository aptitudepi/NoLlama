#!/usr/bin/env bash
# download-model.sh — Download or convert any HuggingFace model for NoLlama (Linux)
#
# Usage:
#   ./download-model.sh OpenVINO/Qwen3-8B-int4-cw-ov          # pre-exported, just download
#   ./download-model.sh Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int8
#   ./download-model.sh Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int4 --trust
#   ./download-model.sh some-org/gated-model --hf-token hf_xxx  # auth for gated/private models
#
# Downloads to ~/models/<repo-name>/ by default.
# Use --output to override the target directory.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_ROOT="${HOME}/models"
HF_TOKEN=""
CONVERT=false
WEIGHT="int4"
TRUST=false
OUTPUT=""

usage() { sed -n '2,10p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --convert) CONVERT=true; shift ;;
        --weight) WEIGHT="$2"; shift 2 ;;
        --trust) TRUST=true; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --hf-token) HF_TOKEN="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) [[ -z "${HF_ID:-}" ]] && HF_ID="$1" || usage; shift ;;
    esac
done

if [[ -z "${HF_ID:-}" ]]; then
    echo "Usage: $0 <hf-id> [--convert] [--weight int4|int8|fp16] [--trust] [--output <dir>] [--hf-token <token>]"
    exit 1
fi

if [[ -n "$HF_TOKEN" ]]; then
    export HF_TOKEN="$HF_TOKEN"
    echo -e "\e[2m[+] HF token set for this session (gated/private model auth)\e[0m"
fi

# Activate venv
if [[ -f "$SELF_DIR/venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$SELF_DIR/venv/bin/activate"
else
    echo -e "\e[33mWARNING: No venv found. Using system Python.\e[0m" >&2
fi

REPO_NAME="${HF_ID##*/}"
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$MODELS_ROOT/$REPO_NAME"
fi

echo ""
echo -e "\e[36m=== NoLlama Model Download ===\e[0m"
echo ""
echo "  Model:  $HF_ID"
echo "  Target: $OUTPUT"
if $CONVERT; then
    echo "  Mode:   Convert (optimum-cli, $WEIGHT)"
else
    echo "  Mode:   Download (pre-exported)"
fi
echo ""

if [[ -d "$OUTPUT" ]]; then
    echo -e "\e[33mTarget directory already exists: $OUTPUT\e[0m" >&2
    read -r -p "Overwrite? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    if [[ -L "$OUTPUT" ]]; then
        rm -f "$OUTPUT"
    else
        rm -rf "$OUTPUT"
    fi
fi

if $CONVERT; then
    echo -e "\e[36mConverting $HF_ID to OpenVINO ($WEIGHT)...\e[0m"
    echo "  This may take 5-30 minutes depending on model size."
    echo ""
    ARGS=(export openvino --model "$HF_ID" --weight-format "$WEIGHT")
    if $TRUST; then
        ARGS+=(--trust-remote-code)
    fi
    ARGS+=("$OUTPUT")
    echo -e "\e[2mRunning: optimum-cli ${ARGS[*]}\e[0m"
    echo ""
    optimum-cli "${ARGS[@]}"
    RC=$?
    if [[ $RC -ne 0 ]]; then
        echo ""
        echo -e "\e[31mERROR: Conversion failed.\e[0m" >&2
        echo -e "\e[33m  Common fixes:\e[0m" >&2
        echo -e "\e[33m    - Add --trust if the model needs trust-remote-code\e[0m" >&2
        echo -e "\e[33m    - Check that optimum-intel is installed: pip install optimum[openvino]\e[0m" >&2
        echo -e "\e[33m    - Some architectures aren't supported yet by optimum-intel\e[0m" >&2
        exit 1
    fi
else
    echo -e "\e[36mDownloading $HF_ID...\e[0m"
    echo ""
    export PYTHONIOENCODING=utf-8
    hf download "$HF_ID" --local-dir "$OUTPUT"
    RC=$?
    if [[ $RC -ne 0 ]]; then
        echo ""
        echo -e "\e[31mERROR: Download failed.\e[0m" >&2
        echo -e "\e[33m  If 401/403: pass --hf-token hf_xxx (or run 'hf auth login' first)\e[0m" >&2
        exit 1
    fi
fi

echo ""
echo -e "\e[32m[OK] Model ready at: $OUTPUT\e[0m"
echo ""
echo "To use with NoLlama:"
echo "  ./start.sh --model-dir \"$OUTPUT\" --device GPU"
echo "  # or as secondary:"
echo "  ./start.sh --model-dir model --gpu-model-dir \"$OUTPUT\""
echo ""
