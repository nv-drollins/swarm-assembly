#!/usr/bin/env bash
# ============================================================================
# Swarm Assembly — installer / provisioner for a 2x DGX Spark cluster.
#
# Checks prerequisites on BOTH nodes, then serves the 9 model endpoints
# (supervisor + 8 specialists) across the two Sparks and provisions the shared
# Nemoclaw sandbox on node 1.
#
# Does NOT assume: specific IPs, passwordless sudo. It prompts for what it needs
# and asks you to run any privileged step yourself if sudo isn't passwordless.
# ============================================================================
set -uo pipefail

# ---- pretty output ---------------------------------------------------------
c_g(){ printf '\033[0;32m%s\033[0m\n' "$*"; }   # green
c_y(){ printf '\033[0;33m%s\033[0m\n' "$*"; }   # yellow
c_r(){ printf '\033[0;31m%s\033[0m\n' "$*"; }   # red
c_b(){ printf '\033[1;36m%s\033[0m\n' "$*"; }   # bold cyan
hr(){ printf '%s\n' "----------------------------------------------------------------"; }
die(){ c_r "ERROR: $*"; exit 1; }

VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm@sha256:9204569b17ee4c0eff75194b8e6e458479c8aee18953b5ab9cf359fcdac659e2}"
HF_CACHE="/home/nvidia/hf-cache"

# Models to download (repo) and how each is served (name:port:util).
MODELS=(
  "nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8"
  "Qwen/Qwen3-4B-Instruct-2507"
  "RedHatAI/Qwen2.5-Coder-7B-Instruct-FP8-dynamic"
)

# node1 specialists: served_name repo port util
NODE1_SERVE=(
  "coder RedHatAI/Qwen2.5-Coder-7B-Instruct-FP8-dynamic 8013 0.12"
  "researcher nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8017 0.10"
  "designer nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8018 0.10"
)
# node2 specialists
NODE2_SERVE=(
  "analyst nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8011 0.12"
  "writer Qwen/Qwen3-4B-Instruct-2507 8012 0.12"
  "architect Qwen/Qwen3-4B-Instruct-2507 8014 0.10"
  "tester RedHatAI/Qwen2.5-Coder-7B-Instruct-FP8-dynamic 8015 0.10"
  "reviewer nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8016 0.12"
)

# ---- 0. inputs -------------------------------------------------------------
c_b "🐝 Swarm Assembly installer"
hr
c_y "This will provision model endpoints across two DGX Sparks."
read -rp "Node 1 IP/host (backend + supervisor, default 192.168.1.124): " NODE1
NODE1="${NODE1:-192.168.1.124}"
read -rp "Node 2 IP/host (specialist farm,   default 192.168.1.188): " NODE2
NODE2="${NODE2:-192.168.1.188}"
read -rp "SSH user for both nodes (default nvidia): " SSHUSER
SSHUSER="${SSHUSER:-nvidia}"
read -rp "Assume supervisor Nemotron 30B is already served on node1:8001? [y/N]: " HAVE_SUP

if [[ -z "${HF_TOKEN:-}" ]]; then
  read -rsp "HuggingFace token (for model downloads): " HF_TOKEN; echo
fi
[[ -n "$HF_TOKEN" ]] || die "HF_TOKEN is required to download models."

SSH1(){ ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$SSHUSER@$NODE1" "$@"; }
SSH2(){ ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$SSHUSER@$NODE2" "$@"; }

# ---- 1. connectivity -------------------------------------------------------
hr; c_b "1) Connectivity"
SSH1 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node1 ($NODE1)" || die "cannot SSH to $SSHUSER@$NODE1"
SSH2 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node2 ($NODE2)" || die "cannot SSH to $SSHUSER@$NODE2"
SSH2 "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$NODE1:8001/v1/models" 2>/dev/null | grep -q 200 \
  && c_g "  ✓ node2 can reach node1:8001 (cross-node network ok)" \
  || c_y "  ! node2 could not reach node1:8001 yet (fine if supervisor isn't up)"

# ---- 2. prerequisites on both nodes ---------------------------------------
check_node(){ # $1=label  $2=ssh-fn
  local label="$1" ssh="$2" miss=0
  c_b "   [$label]"
  $ssh 'command -v docker >/dev/null'         && c_g "     ✓ docker"            || { c_r "     ✗ docker missing"; miss=1; }
  $ssh 'docker info 2>/dev/null | grep -qi nvidia' && c_g "     ✓ nvidia runtime" || c_y "     ! nvidia docker runtime not detected"
  $ssh 'command -v nvidia-smi >/dev/null'     && c_g "     ✓ nvidia-smi"        || c_y "     ! nvidia-smi not found"
  $ssh "docker image inspect $VLLM_IMAGE >/dev/null 2>&1" && c_g "     ✓ vLLM image present" || c_y "     ! vLLM image will be pulled"
  return $miss
}
hr; c_b "2) Prerequisites"
check_node "node1 $NODE1" SSH1 || die "install docker + NVIDIA Container Toolkit on node1, then re-run."
check_node "node2 $NODE2" SSH2 || die "install docker + NVIDIA Container Toolkit on node2, then re-run."
# node1 backend host also needs python3.11+
SSH1 'python3 -c "import sys; assert sys.version_info>=(3,11)"' 2>/dev/null \
  && c_g "  ✓ node1 python 3.11+" || c_y "  ! node1 needs python 3.11+ for the backend"
# node2 needs nemoclaw/openshell for the sandbox (only if you run sandboxes on node2)
SSH2 'bash -lc "command -v openshell" >/dev/null 2>&1' \
  && c_g "  ✓ node2 nemoclaw/openshell present" \
  || c_y "  ! node2 has no nemoclaw/openshell (install: curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash)"

# ---- 3. pull vLLM image on both nodes -------------------------------------
hr; c_b "3) vLLM image"
for pair in "node1:SSH1" "node2:SSH2"; do
  n="${pair%%:*}"; RUN="${pair##*:}"
  if $RUN "docker image inspect $VLLM_IMAGE >/dev/null 2>&1"; then
    c_g "  ✓ $n already has the image"
  else
    c_y "  … pulling vLLM image on $n (~30GB, one-time)"; $RUN "docker pull $VLLM_IMAGE" || die "image pull failed on $n"
  fi
done

# ---- 4. download models on both nodes -------------------------------------
dl_models(){ local run="$1" node="$2"
  c_b "   downloading models on $node …"
  for m in "${MODELS[@]}"; do
    $run "mkdir -p $HF_CACHE && docker run --rm -e HF_TOKEN='$HF_TOKEN' -v $HF_CACHE:/root/.cache/huggingface $VLLM_IMAGE bash -lc 'hf download $m >/dev/null 2>&1 && echo ok'" \
      | grep -q ok && c_g "     ✓ $m" || c_r "     ✗ $m (check HF token / repo access)"
  done
}
hr; c_b "4) Models"
dl_models SSH1 "node1"
dl_models SSH2 "node2"

# ---- 5. serve specialist models (sequential = avoids vLLM profiling clash) --
serve_one(){ local run="$1" name="$2" repo="$3" port="$4" util="$5"
  $run "docker rm -f spec-$name >/dev/null 2>&1; docker run -d --name spec-$name --gpus all --ipc=host \
    --ulimit memlock=-1 --ulimit stack=67108864 --restart unless-stopped -p $port:$port -e HF_HUB_OFFLINE=1 \
    -v $HF_CACHE:/root/.cache/huggingface $VLLM_IMAGE vllm serve $repo --port $port --served-model-name $name \
    --gpu-memory-utilization $util --max-model-len 8192 --trust-remote-code --enforce-eager >/dev/null" || return 1
  # wait for ready (each model loads solo before the next starts)
  for _ in $(seq 1 24); do
    [ "$($run "curl -s -o /dev/null -w '%{http_code}' http://localhost:$port/v1/models" 2>/dev/null)" = "200" ] \
      && { c_g "     ✓ $name ready on :$port"; return 0; }
    sleep 8
  done
  c_r "     ✗ $name did not become ready on :$port"; return 1
}
hr; c_b "5) Serve specialist models (sequential)"
c_b "   node1:"; for spec in "${NODE1_SERVE[@]}"; do serve_one SSH1 $spec; done
c_b "   node2:"; for spec in "${NODE2_SERVE[@]}"; do serve_one SSH2 $spec; done

# ---- 6. provision shared Nemoclaw sandbox on node1 ------------------------
hr; c_b "6) Shared sandbox (node1)"
if [[ "${HAVE_SUP,,}" != "y" ]]; then
  c_y "  ! Supervisor Nemotron-30B on node1:8001 not confirmed — the sandbox and"
  c_y "    the swarm need it. Serve it first (see docs), then re-run this step."
fi
if SSH1 'bash -lc "command -v nemoclaw" >/dev/null 2>&1'; then
  SSH1 "bash -lc '
    export NEMOCLAW_PROVIDER=custom NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:8001/v1 \
           NEMOCLAW_MODEL=nemotron-lightning COMPATIBLE_API_KEY=dummy NEMOCLAW_YES=1 \
           NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PREFERRED_API=openai-completions
    openshell sandbox list 2>/dev/null | grep -q \"swarm-team.*Ready\" && { echo already; exit 0; }
    nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software --name swarm-team --no-gpu --no-sandbox-gpu >/dev/null 2>&1
    openshell sandbox list 2>/dev/null | grep swarm-team'" \
    && c_g "  ✓ swarm-team sandbox ready" \
    || c_y "  ! sandbox provisioning needs attention (check nemoclaw on node1)"
else
  c_y "  ! node1 has no nemoclaw. Code-exec features need it. Install:"
  c_y "    curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash"
fi

# ---- done ------------------------------------------------------------------
hr; c_g "Provisioning complete."
c_b "Next: launch the dashboard on node1:"
echo "  SWARM_NODE1=$NODE1 SWARM_NODE2=$NODE2 ./run.sh"
echo "  open http://$NODE1:4456"
