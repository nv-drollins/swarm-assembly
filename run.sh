#!/usr/bin/env bash
# Swarm Assembly launcher. Honours SWARM_NODE1 / SWARM_NODE2 from the env.
set -euo pipefail
cd "$(dirname "$0")"
VENV="$(pwd)/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r backend/requirements.txt
fi
export SWARM_VLLM_BASE="${SWARM_VLLM_BASE:-http://${SWARM_NODE1:-localhost}:8001/v1}"
export SWARM_MODEL="${SWARM_MODEL:-nemotron-lightning}"
cd backend
exec "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port 4456 "$@"
