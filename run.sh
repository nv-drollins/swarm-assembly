#!/usr/bin/env bash
# Swarm Assembly launcher. Run this ON node 1 (the backend host).
#
#   ./run.sh            # brings up any offline model servers (after a reboot)
#                       # and starts the dashboard in the background on :4456
#   ./run.sh --stop     # stops the background dashboard
#   ./run.sh --fg       # runs the dashboard in the foreground (Ctrl+C to stop)
#
# If install.sh wrote .swarm.env, its defaults (nodes, mode, supervisor model)
# are loaded automatically and can still be overridden by the environment.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--stop" ] || [ "${1:-}" = "stop" ]; then
  pkill -f "uvicorn main:app.*--port 4456" 2>/dev/null && echo "Stopped Swarm Assembly (:4456)." || echo "Swarm Assembly was not running."
  exit 0
fi

FG=0
DASHBOARD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fg|--foreground) FG=1; shift ;;
    --dashboard-only)  DASHBOARD_ONLY=1; shift ;;
    *) break ;;
  esac
done

if [ -f .swarm.env ]; then
  # shellcheck disable=SC1091
  set -a; source .swarm.env; set +a
fi

: "${SWARM_NODE1:?set SWARM_NODE1 to this node's hostname/IP (as other hosts see it)}"
: "${SWARM_NODE2:?set SWARM_NODE2 to Spark 2's hostname/IP}"

export SWARM_NODE1 SWARM_NODE2
export SWARM_SSH_USER="${SWARM_SSH_USER:-nvidia}"
export SWARM_CLUSTER_MODE="${SWARM_CLUSTER_MODE:-clustered}"
export SWARM_VLLM_BASE="${SWARM_VLLM_BASE:-http://${SWARM_NODE1}:8001/v1}"
if [ -z "${SWARM_MODEL:-}" ]; then
  if [ "$SWARM_CLUSTER_MODE" = "clustered" ]; then
    export SWARM_MODEL="nemotron-super"
  else
    export SWARM_MODEL="nemotron-lightning"
  fi
fi

# After a reboot of the Sparks, the multi-node TP=2 Ray container (`vllm_super`
# on :8001) will not be running — and if the solo specialist containers on Spark 2
# auto-started first, they must be stopped before `vllm_super` (largest, 0.44)
# starts so GPU memory is allocated largest-first.
if [ "$DASHBOARD_ONLY" -eq 0 ]; then
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${SWARM_NODE1}:8001/v1/models" 2>/dev/null)" != "200" ]; then
    echo "Supervisor (:8001) is offline (e.g. after a reboot) — bringing model servers online in largest-first order..."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SWARM_SSH_USER}@${SWARM_NODE1}" \
      "sudo -n docker ps -aq --filter 'name=spec-' | xargs -r sudo -n docker rm -f >/dev/null 2>&1 || true"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SWARM_SSH_USER}@${SWARM_NODE2}" \
      "sudo -n docker ps -aq --filter 'name=spec-' | xargs -r sudo -n docker rm -f >/dev/null 2>&1 || true"
    ./install.sh --resume
    exit 0
  fi
fi

VENV="$(pwd)/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV" || {
    echo "python3 -m venv failed — install it with: sudo apt-get install -y python3-venv" >&2
    exit 1
  }
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r backend/requirements.txt
fi

echo "Swarm Assembly  →  http://${SWARM_NODE1}:4456"
echo "  Mode: ${SWARM_CLUSTER_MODE}   Spark 1: ${SWARM_NODE1}   Spark 2: ${SWARM_NODE2}   supervisor: ${SWARM_MODEL} (${SWARM_VLLM_BASE})"

pkill -f "uvicorn main:app.*--port 4456" 2>/dev/null || true
sleep 1

cd backend
if [ "$FG" -eq 1 ]; then
  exec "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port 4456 --no-access-log "$@"
else
  nohup "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port 4456 --no-access-log "$@" > /tmp/swarm-web.log 2>&1 < /dev/null &
  for _ in $(seq 1 15); do
    curl -s http://localhost:4456/api/health >/dev/null 2>&1 && break
    sleep 1
  done
  echo "  ✓ Running in background (PID $!, log: /tmp/swarm-web.log, stop with: ./run.sh --stop)"
fi
