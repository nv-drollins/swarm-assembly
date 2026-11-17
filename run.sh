#!/usr/bin/env bash
# Swarm Assembly launcher. Run this ON node 1 (the backend host).
#
#   SWARM_NODE1=<node1-host> SWARM_NODE2=<node2-host> ./run.sh
#
# SWARM_NODE2 is required — the backend has no built-in address for Spark 2.
set -euo pipefail
cd "$(dirname "$0")"

: "${SWARM_NODE1:?set SWARM_NODE1 to this node's hostname/IP (as other hosts see it)}"
: "${SWARM_NODE2:?set SWARM_NODE2 to Spark 2's hostname/IP}"

VENV="$(pwd)/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV" || {
    echo "python3 -m venv failed — install it with: sudo apt-get install -y python3-venv" >&2
    exit 1
  }
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r backend/requirements.txt
fi

export SWARM_NODE1 SWARM_NODE2
export SWARM_SSH_USER="${SWARM_SSH_USER:-nvidia}"
export SWARM_VLLM_BASE="${SWARM_VLLM_BASE:-http://${SWARM_NODE1}:8001/v1}"
export SWARM_MODEL="${SWARM_MODEL:-nemotron-lightning}"

echo "Swarm Assembly  →  http://${SWARM_NODE1}:4456"
echo "  Spark 1: ${SWARM_NODE1}   Spark 2: ${SWARM_NODE2}   supervisor: ${SWARM_VLLM_BASE}"
cd backend
exec "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port 4456 "$@"
