#!/usr/bin/env bash
# start-template.sh — NoLlama launcher template (Linux)
# Activates the venv and runs nollama.py. All arguments are passed through.
# Called by the auto-generated start.sh (or directly).
#
# Usage:
#   ./start-template.sh                    # run with default args (auto-detect)
#   ./start-template.sh --device NPU       # force NPU
#   ./start-template.sh --port 9000        # different port
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="$SELF_DIR/venv/bin/python"

if [ -x "$VENV_PYTHON" ]; then
    exec "$VENV_PYTHON" "$SELF_DIR/nollama.py" "$@"
fi

exec python3 "$SELF_DIR/nollama.py" "$@"
