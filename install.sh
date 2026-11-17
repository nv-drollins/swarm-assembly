#!/usr/bin/env bash
# ============================================================================
# Swarm Assembly — installer / provisioner for a 2x DGX Spark cluster.
#
# Takes two freshly-imaged DGX Sparks to a running demo:
#   0. inputs            node hostnames/IPs + SSH user
#   1. connectivity      SSH both ways, cross-node reachability
#   2. host prereqs      python3-venv, docker group, NVIDIA container runtime
#   3. vLLM image        pull the NGC vLLM container on both nodes
#   4. models            download the 3 model checkpoints into a shared HF cache
#   5. serve             9 endpoints (supervisor + 8 specialists) across the pair
#   6. sandbox           install nemoclaw/openshell + provision the shared sandbox
#
# Does NOT assume: specific IPs, passwordless sudo, an existing supervisor.
# Anything privileged is attempted with `sudo -n` first; if that fails you are
# told the exact command to run yourself.
#
# Re-running is safe: every step detects work already done and skips it.
# ============================================================================
set -uo pipefail

# ---- pretty output ---------------------------------------------------------
c_g(){ printf '\033[0;32m%s\033[0m\n' "$*"; }   # green
c_y(){ printf '\033[0;33m%s\033[0m\n' "$*"; }   # yellow
c_r(){ printf '\033[0;31m%s\033[0m\n' "$*"; }   # red
c_b(){ printf '\033[1;36m%s\033[0m\n' "$*"; }   # bold cyan
hr(){ printf '%s\n' "----------------------------------------------------------------"; }
die(){ c_r "ERROR: $*"; exit 1; }

# NGC vLLM container. 26.05.post1-py3 (CUDA 13.2 / driver 595.58.03) is the
# latest NGC release within R580 kernel driver (580.178.04) CUDA Forward
# Compatibility (26.06+ require driver 610/620+ where compatibility mode is
# unavailable on R580).
VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.05.post1-py3}"
HF_CACHE="${HF_CACHE:-/home/nvidia/hf-cache}"

# ---- the roster ------------------------------------------------------------
# Supervisor: Nemotron 3.5 Lightning 30B (NVFP4) — the reasoning model that
# recruits the team. ~21.6GB on disk, served on node1:8001.
SUPERVISOR_REPO="nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"
SUPERVISOR_PORT=8001
SUPERVISOR_NAME="nemotron-lightning"

# Specialists. All ungated — no HuggingFace token required.
#   Nemotron-3-Nano-4B-FP8      (5.3GB)  general specialists
#   Qwen3-Coder-30B-A3B-FP8     (31GB)   code roles; MoE, only 3B active = fast
MODELS=(
  "$SUPERVISOR_REPO"
  "nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8"
  "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
)
# Models each node actually needs (saves a 31GB download on node1 vs node2 etc).
NODE1_MODELS=("$SUPERVISOR_REPO" "nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8" "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8")
NODE2_MODELS=("nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8" "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8")

# ---- GPU memory budget (READ THIS BEFORE CHANGING A `util` NUMBER) --------
# GB10 has 121GB of UNIFIED memory, and vLLM's --gpu-memory-utilization is a
# fraction of that FULL 121GB -- not of what is still free. Every server you
# start permanently consumes its share, so the fractions on a node must sum to
# well under 1.0 or a later (larger) model fails at startup with:
#   "Free memory on device cuda:0 (19.76/121.69 GiB) on startup is less than
#    desired GPU memory utilization (0.35, 42.59 GiB)"
# Two rules follow:
#   1. Start the LARGEST model on a node first, while memory is uncontended.
#   2. Keep each node's fractions summing to <= ~0.60, leaving headroom for the
#      host, the sandbox, and vLLM's own activation workspace.
# Node 1: 0.30 coder + 0.25 supervisor + 0.09 + 0.09  = 0.73 of 121GB
# Node 2: 0.30 tester + 0.09 x 4                      = 0.66 of 121GB
# Order within each array matters: largest first.

# node1 specialists: served_name repo port util
NODE1_SERVE=(
  "coder Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 8013 0.30"
  "researcher nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8017 0.09"
  "designer nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8018 0.09"
)
# node2 specialists
NODE2_SERVE=(
  "tester Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 8015 0.30"
  "analyst nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8011 0.09"
  "writer nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8012 0.09"
  "architect nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8014 0.09"
  "reviewer nvidia/NVIDIA-Nemotron-3-Nano-4B-FP8 8016 0.09"
)

# ---- 0. inputs -------------------------------------------------------------
c_b "🐝 Swarm Assembly installer"
hr
c_y "This provisions model endpoints across two DGX Sparks."
c_y "Use hostnames where you can — they survive a venue's DHCP; IPs do not."
read -rp "Node 1 host (backend + supervisor + sandbox): " NODE1
[[ -n "$NODE1" ]] || die "node 1 host is required"
read -rp "Node 2 host (specialist farm): " NODE2
[[ -n "$NODE2" ]] || die "node 2 host is required"
read -rp "SSH user for both nodes (default nvidia): " SSHUSER
SSHUSER="${SSHUSER:-nvidia}"

SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
SSH1(){ ssh "${SSH_OPTS[@]}" "$SSHUSER@$NODE1" "$@"; }
SSH2(){ ssh "${SSH_OPTS[@]}" "$SSHUSER@$NODE2" "$@"; }

# Run a command with sudo on a node, preferring passwordless. Returns non-zero
# and prints the command for you if sudo needs a password.
SUDO1(){ SSH1 "sudo -n $*" 2>/dev/null; }
SUDO2(){ SSH2 "sudo -n $*" 2>/dev/null; }

# ---- 1. connectivity -------------------------------------------------------
hr; c_b "1) Connectivity"
SSH1 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node1 ($NODE1)" \
  || die "cannot SSH to $SSHUSER@$NODE1 — install your key: ssh-copy-id $SSHUSER@$NODE1"
SSH2 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node2 ($NODE2)" \
  || die "cannot SSH to $SSHUSER@$NODE2 — install your key: ssh-copy-id $SSHUSER@$NODE2"
# The backend polls telemetry over SSH from node1 to node2, so node1 needs a key
# on node2 as well. Check that specifically — it is a classic silent failure.
SSH1 "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 $SSHUSER@$NODE2 echo ok" >/dev/null 2>&1 \
  && c_g "  ✓ node1 → node2 SSH (telemetry path)" \
  || c_y "  ! node1 cannot SSH to node2 — Spark 2 telemetry will read as offline.
      Fix on node1:  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 && ssh-copy-id $SSHUSER@$NODE2"

# ---- 2. host prerequisites on both nodes -----------------------------------
# A fresh DGX OS image has docker + the NVIDIA toolkit installed but NOT wired
# together: the user isn't in the docker group and docker has no nvidia runtime.
prep_node(){ # $1=label  $2=ssh-fn  $3=sudo-fn
  local label="$1" ssh="$2" sudo_fn="$3"
  c_b "   [$label]"

  $ssh 'command -v nvidia-smi >/dev/null' \
    && c_g "     ✓ nvidia-smi" || { c_r "     ✗ no nvidia-smi — is this a DGX Spark?"; return 1; }
  $ssh 'command -v docker >/dev/null' \
    && c_g "     ✓ docker" || { c_r "     ✗ docker missing"; return 1; }

  # python3 + venv: the backend host needs it for run.sh; harmless elsewhere.
  if $ssh 'python3 -c "import venv" >/dev/null 2>&1'; then
    c_g "     ✓ python3 + venv"
  else
    c_y "     … installing python3-venv"
    $sudo_fn "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
              DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip" >/dev/null 2>&1 \
      && c_g "     ✓ python3-venv installed" \
      || c_y "     ! run yourself: sudo apt-get install -y python3-venv python3-pip"
  fi

  # NVIDIA container runtime registered with docker?
  if $ssh 'docker info 2>/dev/null | grep -qi "Runtimes:.*nvidia"' \
     || $ssh 'sudo -n docker info 2>/dev/null | grep -qi "Runtimes:.*nvidia"'; then
    c_g "     ✓ nvidia docker runtime"
  else
    c_y "     … registering the NVIDIA container runtime with docker"
    $sudo_fn "nvidia-ctk runtime configure --runtime=docker --set-as-default" >/dev/null 2>&1 \
      && $sudo_fn "systemctl restart docker" >/dev/null 2>&1 \
      && c_g "     ✓ nvidia runtime configured" \
      || c_y "     ! run yourself: sudo nvidia-ctk runtime configure --runtime=docker --set-as-default && sudo systemctl restart docker"
  fi

  # docker group membership (so later steps don't all need sudo)
  if $ssh 'id -nG | grep -qw docker'; then
    c_g "     ✓ $SSHUSER in docker group"
  else
    $sudo_fn "usermod -aG docker $SSHUSER" >/dev/null 2>&1 \
      && c_y "     ✓ added $SSHUSER to docker group (takes effect on next login; sudo is used meanwhile)" \
      || c_y "     ! run yourself: sudo usermod -aG docker $SSHUSER"
  fi

  # Prove GPU-in-container actually works — the single most useful check here.
  if $ssh "sudo -n docker run --rm --gpus all $VLLM_IMAGE nvidia-smi -L" 2>/dev/null | grep -q GPU \
     || $ssh 'sudo -n docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L' 2>/dev/null | grep -q GPU; then
    c_g "     ✓ GPU visible inside containers"
  else
    c_y "     ! could not verify GPU passthrough into a container (checked after the image pull)"
  fi
  return 0
}
hr; c_b "2) Host prerequisites"
prep_node "node1 $NODE1" SSH1 SUDO1 || die "node1 prerequisites failed"
prep_node "node2 $NODE2" SSH2 SUDO2 || die "node2 prerequisites failed"

# ---- 3. pull vLLM image on both nodes -------------------------------------
hr; c_b "3) vLLM image ($VLLM_IMAGE)"
for pair in "node1:SSH1" "node2:SSH2"; do
  n="${pair%%:*}"; RUN="${pair##*:}"
  if $RUN "sudo -n docker image inspect $VLLM_IMAGE >/dev/null 2>&1"; then
    c_g "  ✓ $n already has the image"
  else
    c_y "  … pulling on $n (~39GB, one-time, several minutes)"
    $RUN "sudo -n docker pull $VLLM_IMAGE" >/dev/null 2>&1 \
      && c_g "  ✓ $n image pulled" || die "image pull failed on $n"
  fi
done

# ---- 4. download models ----------------------------------------------------
# All three checkpoints are ungated, so no HF token is needed. Downloads run
# inside the vLLM container (which ships the `hf` CLI) into a host-side cache.
dl_models(){ local run="$1" node="$2"; shift 2
  c_b "   $node:"
  for m in "$@"; do
    if $run "test -d $HF_CACHE/hub/models--$(echo "$m" | tr '/' '-' | sed 's/^/models--/;s/models--models--/models--/')" 2>/dev/null; then :; fi
    c_y "     … $m"
    $run "mkdir -p $HF_CACHE && sudo -n docker run --rm ${HF_TOKEN:+-e HF_TOKEN='$HF_TOKEN'} \
      -v $HF_CACHE:/root/.cache/huggingface $VLLM_IMAGE \
      bash -lc 'hf download $m >/dev/null 2>&1 && echo ok'" 2>/dev/null | grep -q ok \
      && c_g "     ✓ $m" || c_r "     ✗ $m (download failed)"
  done
}
hr; c_b "4) Models (ungated — no HF token required)"
dl_models SSH1 "node1" "${NODE1_MODELS[@]}"
dl_models SSH2 "node2" "${NODE2_MODELS[@]}"

# ---- 5. serve the models ---------------------------------------------------
# Sequential: each vLLM profiles the GPU as it loads, so starting them in
# parallel makes them fight over memory and some fail to come up.
serve_one(){ local run="$1" name="$2" repo="$3" port="$4" util="$5" extra="${6:-}"
  if [ "$($run "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:$port/v1/models" 2>/dev/null)" = "200" ]; then
    c_g "     ✓ $name already serving on :$port"; return 0
  fi
  # Nemotron models need --reasoning-parser nemotron_v3, or their <think> trace
  # is emitted as part of the answer and shows up verbatim in the dashboard.
  case "$repo" in *Nemotron*) extra="$extra --reasoning-parser nemotron_v3";; esac
  $run "sudo -n docker rm -f spec-$name >/dev/null 2>&1; sudo -n docker run -d --name spec-$name \
    --gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 --restart unless-stopped \
    -p $port:$port -e HF_HUB_OFFLINE=1 -v $HF_CACHE:/root/.cache/huggingface $VLLM_IMAGE \
    vllm serve $repo --host 0.0.0.0 --port $port --served-model-name $name \
    --gpu-memory-utilization $util --max-model-len 8192 --max-num-seqs 16 \
    --trust-remote-code --enforce-eager $extra >/dev/null" 2>/dev/null || return 1
  # Wait for readiness — a 30B MoE can take a few minutes on first load.
  for _ in $(seq 1 60); do
    [ "$($run "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:$port/v1/models" 2>/dev/null)" = "200" ] \
      && { c_g "     ✓ $name ready on :$port"; return 0; }
    $run "sudo -n docker ps --filter name=spec-$name --format '{{.Names}}'" 2>/dev/null | grep -q "spec-$name" \
      || { c_r "     ✗ $name container exited — logs: docker logs spec-$name"; return 1; }
    sleep 10
  done
  c_r "     ✗ $name did not become ready on :$port (docker logs spec-$name)"; return 1
}
hr; c_b "5) Serve models (sequential — parallel loads fight over GPU memory)"
# Largest-first on each node (see the memory budget note above). On node 1 that
# means the 30B coder, then the 30B supervisor, then the 4B specialists.
c_b "   node1 — coder (largest, goes first):"
serve_one SSH1 ${NODE1_SERVE[0]}
c_b "   node1 — supervisor:"
serve_one SSH1 "$SUPERVISOR_NAME" "$SUPERVISOR_REPO" "$SUPERVISOR_PORT" 0.25
c_b "   node1 — remaining specialists:"
for spec in "${NODE1_SERVE[@]:1}"; do serve_one SSH1 $spec; done
c_b "   node2 — specialists (largest first):"
for spec in "${NODE2_SERVE[@]}"; do serve_one SSH2 $spec; done

# cross-node reachability now that the supervisor is actually up
SSH2 "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$NODE1:$SUPERVISOR_PORT/v1/models" 2>/dev/null | grep -q 200 \
  && c_g "  ✓ node2 can reach the supervisor on node1:$SUPERVISOR_PORT" \
  || c_y "  ! node2 cannot reach node1:$SUPERVISOR_PORT (check the firewall / --host binding)"

# ---- 6. shared Nemoclaw sandbox on node1 ----------------------------------
# The Coder and Tester execute real Python here. Without it the demo still
# runs, but those two roles only talk about code instead of running it.
hr; c_b "6) Shared sandbox (node1)"
if ! SSH1 'bash -lc "command -v nemoclaw" >/dev/null 2>&1'; then
  c_y "  … installing nemoclaw/openshell on node1 (a few minutes)"
  # npm refuses to run from a group-writable directory, and DGX OS ships with
  # umask 002, so a fresh ~/.nvm trips the installer's safety check with
  # "Unsafe npm executable directory". Pre-clean it if it exists.
  SSH1 'test -d ~/.nvm && chmod -R g-w,o-w ~/.nvm' >/dev/null 2>&1
  SSH1 "bash -lc 'curl -fsSL -o /tmp/nemoclaw.sh https://www.nvidia.com/nemoclaw.sh && \
        NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash /tmp/nemoclaw.sh'" >/dev/null 2>&1
  # Retry once after the permission fix — ~/.nvm is created by the first run.
  if ! SSH1 'bash -lc "command -v nemoclaw" >/dev/null 2>&1'; then
    SSH1 'test -d ~/.nvm && chmod -R g-w,o-w ~/.nvm' >/dev/null 2>&1
    SSH1 "bash -lc 'NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash /tmp/nemoclaw.sh'" >/dev/null 2>&1
  fi
  SSH1 'bash -lc "command -v nemoclaw" >/dev/null 2>&1' \
    && c_g "  ✓ nemoclaw installed" \
    || c_y "  ! nemoclaw install failed — run on node1:
      chmod -R g-w,o-w ~/.nvm 2>/dev/null
      curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash"
  # The nemoclaw bootstrap also pulls its OWN vLLM image and a ~35B default
  # model for a stack we don't use (we point the sandbox at our supervisor).
  # Once the CLI is on disk that download is pure waste — stop it.
  SSH1 'sudo -n docker ps --format "{{.Names}}" 2>/dev/null | grep "^nemoclaw-hf-download" \
        | xargs -r sudo -n docker rm -f' >/dev/null 2>&1 \
    && c_y "  … stopped nemoclaw's unused bundled-model download"
fi
if SSH1 'bash -lc "command -v nemoclaw"' >/dev/null 2>&1; then
  if SSH1 'bash -lc "openshell sandbox list 2>/dev/null | grep -q \"swarm-team.*Ready\""'; then
    c_g "  ✓ swarm-team sandbox ready"
  else
    SSH1 "bash -lc '
      export NEMOCLAW_PROVIDER=custom NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:$SUPERVISOR_PORT/v1 \
             NEMOCLAW_MODEL=$SUPERVISOR_NAME COMPATIBLE_API_KEY=dummy NEMOCLAW_YES=1 \
             NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PREFERRED_API=openai-completions
      nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software --name swarm-team --no-gpu --no-sandbox-gpu >/dev/null 2>&1'"
    SSH1 'bash -lc "openshell sandbox list 2>/dev/null | grep -q \"swarm-team.*Ready\""' \
      && c_g "  ✓ swarm-team sandbox ready" \
      || c_y "  ! sandbox provisioning needs attention (check nemoclaw on node1)"
  fi
else
  c_y "  ! no nemoclaw on node1 — Coder/Tester will describe code instead of running it."
fi

# ---- done ------------------------------------------------------------------
hr; c_g "Provisioning complete."
c_b "Next: launch the dashboard ON node1:"
echo "  SWARM_NODE1=$NODE1 SWARM_NODE2=$NODE2 ./run.sh"
echo "  open http://$NODE1:4456"
