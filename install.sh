#!/usr/bin/env bash
# ============================================================================
# Swarm Assembly — installer / provisioner for a 2x DGX Spark cluster.
#
# Takes two freshly-imaged DGX Sparks to a running demo:
#   0. inputs            node hostnames/IPs + SSH user + cluster mode
#   1. connectivity      SSH both ways, cross-node reachability, 200GbE CX7 setup
#   2. host prereqs      python3-venv, docker group, NVIDIA container runtime
#   3. vLLM image        pull eugr/spark-vllm:latest (tagged vllm-node) on both nodes
#   4. models            download the consolidated US/FR model checkpoints
#   5. serve             4 shared model servers (supervisor + 8 specialists)
#   6. sandbox           install nemoclaw/openshell + provision the shared sandbox
#
# Supports two deployment modes selectable at install time:
#   Mode 1 (clustered):  2x 200GbE ConnectX-7 RoCEv2 link — Supervisor runs
#                        nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 sharded
#                        TP=2 across Spark 1 + Spark 2 via Ray + RDMA (:8001).
#   Mode 2 (standard):   1GbE LAN only — Supervisor runs
#                        nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 on
#                        Spark 1 (:8001).
#
# Consolidated Specialist Roster (both modes — zero 4B models, zero Chinese models):
#   - Spark 1 :8013  mistralai/Devstral-Small-2-24B-Instruct-2512 (Coder, Tester)
#   - Spark 2 :8011  nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4  (Researcher, Analyst, Reviewer, Designer)
#   - Spark 2 :8012  nvidia/Gemma-4-26B-A4B-NVFP4                 (Architect, Writer)
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

VLLM_IMAGE="${VLLM_IMAGE:-eugr/spark-vllm:latest}"
VLLM_TAG="vllm-node"
HF_CACHE="${HF_CACHE:-/home/nvidia/hf-cache}"
SUPERVISOR_PORT=8001

# ---- 0. inputs -------------------------------------------------------------
c_b "🐝 Swarm Assembly installer"
hr
if [[ "${1:-}" == "--resume" ]] && [[ -f .swarm.env ]]; then
  # shellcheck disable=SC1091
  set -a; source .swarm.env; set +a
  NODE1="$SWARM_NODE1"
  NODE2="$SWARM_NODE2"
  SSHUSER="${SWARM_SSH_USER:-nvidia}"
  CLUSTER_MODE="${SWARM_CLUSTER_MODE:-clustered}"
  if [[ "$CLUSTER_MODE" == "standard" ]]; then
    SUPERVISOR_REPO="nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"
    SUPERVISOR_NAME="nemotron-lightning"
  else
    SUPERVISOR_REPO="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"
    SUPERVISOR_NAME="nemotron-super"
  fi
  c_g "  → Resuming from .swarm.env: node1=$NODE1  node2=$NODE2  mode=$CLUSTER_MODE"
else
  c_y "This provisions model endpoints across two DGX Sparks."
  c_y "Use hostnames where you can — they survive a venue's DHCP; IPs do not."
  read -rp "Node 1 host (backend + supervisor + coder + sandbox): " NODE1
  [[ -n "$NODE1" ]] || die "node 1 host is required"
  read -rp "Node 2 host (specialist farm): " NODE2
  [[ -n "$NODE2" ]] || die "node 2 host is required"
  read -rp "SSH user for both nodes (default nvidia): " SSHUSER
  SSHUSER="${SSHUSER:-nvidia}"

  echo ""
  c_b "Select Supervisor / Interconnect Mode:"
  echo "  1) Clustered 200GbE Mode (default) — Nemotron-3-Super-120B-A12B-NVFP4 sharded TP=2"
  echo "     across Spark 1 + Spark 2 over the 200GbE ConnectX-7 direct QSFP cable"
  echo "  2) Standard 1GbE Mode              — Nemotron-3.5-Lightning-30B-A3B-NVFP4 on Spark 1"
  read -rp "Mode [1/2, default 1]: " MODE_CHOICE
  if [[ "${MODE_CHOICE:-1}" == "2" ]]; then
    CLUSTER_MODE="standard"
    SUPERVISOR_REPO="nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"
    SUPERVISOR_NAME="nemotron-lightning"
  else
    CLUSTER_MODE="clustered"
    SUPERVISOR_REPO="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"
    SUPERVISOR_NAME="nemotron-super"
  fi
  c_g "  → Selected mode: $CLUSTER_MODE (Supervisor: $SUPERVISOR_REPO)"
fi

DEVSTRAL_REPO="mistralai/Devstral-Small-2-24B-Instruct-2512"
NANO30B_REPO="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4"
GEMMA26B_REPO="nvidia/Gemma-4-26B-A4B-NVFP4"

SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
SSH1(){ ssh "${SSH_OPTS[@]}" "$SSHUSER@$NODE1" "$@"; }
SSH2(){ ssh "${SSH_OPTS[@]}" "$SSHUSER@$NODE2" "$@"; }
SUDO_PASS=""
SUDO1(){
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | SSH1 "sudo -S -p '' $*" 2>/dev/null
  else
    SSH1 "sudo -n $*" 2>/dev/null
  fi
}
SUDO2(){
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | SSH2 "sudo -S -p '' $*" 2>/dev/null
  else
    SSH2 "sudo -n $*" 2>/dev/null
  fi
}

# ---- 1. connectivity -------------------------------------------------------
hr; c_b "1) Connectivity"
SSH1 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node1 ($NODE1)" \
  || die "cannot SSH to $SSHUSER@$NODE1 — install your key: ssh-copy-id $SSHUSER@$NODE1"
SSH2 'echo ok' >/dev/null 2>&1 && c_g "  ✓ SSH to node2 ($NODE2)" \
  || die "cannot SSH to $SSHUSER@$NODE2 — install your key: ssh-copy-id $SSHUSER@$NODE2"
SSH1 "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 $SSHUSER@$NODE2 echo ok" >/dev/null 2>&1 \
  && c_g "  ✓ node1 → node2 SSH (telemetry path)" \
  || c_y "  ! node1 cannot SSH to node2 — Spark 2 telemetry will read as offline.
      Fix on node1:  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 && ssh-copy-id $SSHUSER@$NODE2"

# Check if sudo requires a password on either node; if so, prompt once in memory
# and configure passwordless sudo so setup-cluster.sh and docker commands work non-interactively.
if ! SSH1 "sudo -n true" 2>/dev/null || ! SSH2 "sudo -n true" 2>/dev/null; then
  c_y "  … sudo on a fresh image requires a password; enter $SSHUSER's sudo password once (kept in memory only):"
  read -rsp "    [sudo] password for $SSHUSER: " SUDO_PASS; echo ""
  for pair in "node1 ($NODE1):SUDO1:SSH1" "node2 ($NODE2):SUDO2:SSH2"; do
    IFS=: read -r lbl sfn rfn <<< "$pair"
    if ! $rfn "sudo -n true" 2>/dev/null; then
      $sfn "bash -c 'echo \"$SSHUSER ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/90-$SSHUSER-nopasswd && chmod 0440 /etc/sudoers.d/90-$SSHUSER-nopasswd'" \
        && c_g "  ✓ configured passwordless sudo on $lbl" \
        || die "sudo authentication failed on $lbl — check your password"
    fi
  done
  SUDO_PASS=""
fi

# ---- 2. host prerequisites on both nodes -----------------------------------
prep_node(){ # $1=label  $2=ssh-fn  $3=sudo-fn
  local label="$1" ssh="$2" sudo_fn="$3"
  c_b "   [$label]"

  $ssh 'command -v nvidia-smi >/dev/null' \
    && c_g "     ✓ nvidia-smi" || { c_r "     ✗ no nvidia-smi — is this a DGX Spark?"; return 1; }
  $ssh 'command -v docker >/dev/null' \
    && c_g "     ✓ docker" || { c_r "     ✗ docker missing"; return 1; }

  if $ssh 'python3 -c "import venv" >/dev/null 2>&1'; then
    c_g "     ✓ python3 + venv"
  else
    c_y "     … installing python3-venv"
    $sudo_fn "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
              DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip" >/dev/null 2>&1 \
      && c_g "     ✓ python3-venv installed" \
      || c_y "     ! run yourself: sudo apt-get install -y python3-venv python3-pip"
  fi

  if $ssh 'docker info 2>/dev/null | grep -qi "Runtimes:.*nvidia"' \
     || $ssh 'sudo -n docker info 2>/dev/null | grep -qi "Runtimes:.*nvidia"'; then
    c_g "     ✓ nvidia docker runtime"
  else
    if ! $ssh 'command -v nvidia-ctk >/dev/null 2>&1'; then
      c_y "     … installing nvidia-container-toolkit"
      $sudo_fn "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit" >/dev/null 2>&1 || true
    fi
    c_y "     … registering the NVIDIA container runtime with docker"
    $sudo_fn "nvidia-ctk runtime configure --runtime=docker --set-as-default" >/dev/null 2>&1 \
      && $sudo_fn "systemctl restart docker" >/dev/null 2>&1 \
      && c_g "     ✓ nvidia runtime configured" \
      || c_y "     ! run yourself: sudo nvidia-ctk runtime configure --runtime=docker --set-as-default && sudo systemctl restart docker"
  fi

  if $ssh 'id -nG | grep -qw docker'; then
    c_g "     ✓ $SSHUSER in docker group"
  else
    $sudo_fn "usermod -aG docker $SSHUSER" >/dev/null 2>&1 \
      && c_y "     ✓ added $SSHUSER to docker group" \
      || c_y "     ! run yourself: sudo usermod -aG docker $SSHUSER"
  fi

  # Ensure ~/.cache/huggingface points at $HF_CACHE so spark-vllm-docker and standalone containers share one cache.
  $ssh "mkdir -p ~/.cache $HF_CACHE && sudo -n chown -R $SSHUSER:$SSHUSER $HF_CACHE 2>/dev/null || true; \
        if [ ! -L ~/.cache/huggingface ]; then rm -rf ~/.cache/huggingface && ln -s $HF_CACHE ~/.cache/huggingface; fi"
  return 0
}
hr; c_b "2) Host prerequisites"
prep_node "node1 $NODE1" SSH1 SUDO1 || die "node1 prerequisites failed"
prep_node "node2 $NODE2" SSH2 SUDO2 || die "node2 prerequisites failed"

# If clustered mode is selected, ensure spark-vllm-docker + 200GbE ConnectX-7 link are configured.
if [[ "$CLUSTER_MODE" == "clustered" ]]; then
  hr; c_b "2b) 200GbE ConnectX-7 Cluster Setup (spark-vllm-docker)"
  N1_IP=$(SSH1 "getent ahostsv4 $NODE1 | awk 'NR==1{print \$1}'" 2>/dev/null)
  N2_IP=$(SSH1 "getent ahostsv4 $NODE2 | awk 'NR==1{print \$1}'" 2>/dev/null)
  N1_IP="${N1_IP:-$NODE1}"
  N2_IP="${N2_IP:-$NODE2}"
  # Pre-populate ~/.ssh/known_hosts on both nodes with both hostnames and resolved IPs
  # so setup-cluster.sh's strict host-key check never fails when you used hostnames in Step 1.
  SSH1 "mkdir -p ~/.ssh && ssh-keygen -f ~/.ssh/known_hosts -R $N1_IP -R $N2_IP >/dev/null 2>&1 || true; \
        ssh-keyscan -t ed25519 $NODE1 $NODE2 $N1_IP $N2_IP >> ~/.ssh/known_hosts 2>/dev/null"
  SSH2 "mkdir -p ~/.ssh && ssh-keygen -f ~/.ssh/known_hosts -R $N1_IP -R $N2_IP >/dev/null 2>&1 || true; \
        ssh-keyscan -t ed25519 $NODE1 $NODE2 $N1_IP $N2_IP >> ~/.ssh/known_hosts 2>/dev/null"
  SSH1 "test -d ~/spark-vllm-docker || git clone -q https://github.com/eugr/spark-vllm-docker.git ~/spark-vllm-docker"
  if SSH1 "cd ~/spark-vllm-docker && ./setup-cluster.sh --doctor --dry-run >/dev/null 2>&1"; then
    c_g "  ✓ 200GbE ConnectX-7 cluster & RoCEv2 links verified ($NODE1 ↔ $NODE2)"
  else
    c_y "  … configuring 200GbE ConnectX-7 direct link ($NODE1 [$N1_IP] ↔ $NODE2 [$N2_IP], MTU 9000)"
    SSH1 "cd ~/spark-vllm-docker && ./setup-cluster.sh $N1_IP $N2_IP --topology direct --mtu 9000 --yes" \
      && c_g "  ✓ 200GbE ConnectX-7 cluster configured ($NODE1 ↔ $NODE2)" \
      || die "setup-cluster.sh failed — check output above"
  fi
  # Ensure Node 1's default ~/.ssh/id_ed25519 is trusted over the 10.20.0.12 RoCE IP as well
  SSH1 "ssh-keyscan -t ed25519 10.20.0.12 >> ~/.ssh/known_hosts 2>/dev/null"
fi

# ---- 3. pull vLLM image on both nodes -------------------------------------
hr; c_b "3) vLLM image ($VLLM_IMAGE → $VLLM_TAG)"
for pair in "node1:SSH1" "node2:SSH2"; do
  n="${pair%%:*}"; RUN="${pair##*:}"
  if $RUN "sudo -n docker image inspect $VLLM_TAG >/dev/null 2>&1"; then
    c_g "  ✓ $n already has $VLLM_TAG"
  elif $RUN "sudo -n docker image inspect $VLLM_IMAGE >/dev/null 2>&1"; then
    $RUN "sudo -n docker tag $VLLM_IMAGE $VLLM_TAG"
    c_g "  ✓ $n tagged $VLLM_IMAGE as $VLLM_TAG"
  else
    c_y "  … pulling $VLLM_IMAGE on $n (~12GB compressed, several minutes)"
    $RUN "sudo -n docker pull $VLLM_IMAGE && sudo -n docker tag $VLLM_IMAGE $VLLM_TAG" >/dev/null 2>&1 \
      && c_g "  ✓ $n image pulled and tagged as $VLLM_TAG" || die "image pull failed on $n"
  fi
done

# ---- 4. download models ----------------------------------------------------
# Pick up HF_TOKEN from the environment or ~/.bashrc if present (speeds up HF Hub downloads).
if [[ -z "${HF_TOKEN:-}" ]]; then
  HF_TOKEN=$(grep -E "^(export )?HF_TOKEN=" ~/.bashrc 2>/dev/null | tail -1 | sed -E "s/^(export )?HF_TOKEN=//; s/^[\"'\\'']//; s/[\"'\\'']$//" || true)
fi
if [[ -z "${HF_TOKEN:-}" ]]; then
  HF_TOKEN=$(SSH1 'grep -E "^(export )?HF_TOKEN=" ~/.bashrc 2>/dev/null | tail -1 | sed -E "s/^(export )?HF_TOKEN=//; s/^[\"'\''\"]//; s/[\"'\''\"]$//"' 2>/dev/null || true)
fi

dl_model(){ local run="$1" node="$2" repo="$3" exclude_glob="${4:-}"
  local dir="models--${repo//\//--}"
  # Verify both that snapshots/ is non-empty AND that no symlinks inside snapshots/ are broken.
  if $run "test -d $HF_CACHE/hub/$dir/snapshots && [ -n \"\$(ls -A $HF_CACHE/hub/$dir/snapshots 2>/dev/null)\" ] && [ -z \"\$(find -L $HF_CACHE/hub/$dir/snapshots -type l 2>/dev/null)\" ]" 2>/dev/null; then
    c_g "     ✓ $node: $repo (cached)"
    return 0
  fi
  c_y "     … downloading $repo on $node"
  $run "mkdir -p $HF_CACHE && sudo -n docker run --rm --entrypoint bash ${HF_TOKEN:+-e HF_TOKEN='$HF_TOKEN'} \
    -v $HF_CACHE:/root/.cache/huggingface $VLLM_TAG \
    -lc \"hf download $repo ${exclude_glob:+--exclude '$exclude_glob'} && chown -R 1000:1000 /root/.cache/huggingface\"" \
    && c_g "     ✓ $node: $repo" || die "failed to download $repo on $node"
}
hr; c_b "4) Models (US/FR consolidated lineup)"
dl_model SSH1 "node1" "$DEVSTRAL_REPO" "consolidated*"
dl_model SSH1 "node1" "$SUPERVISOR_REPO"
if [[ "$CLUSTER_MODE" == "clustered" ]]; then
  local_sup_dir="models--${SUPERVISOR_REPO//\//--}"
  if SSH2 "test -d $HF_CACHE/hub/$local_sup_dir/snapshots && [ -n \"\$(ls -A $HF_CACHE/hub/$local_sup_dir/snapshots 2>/dev/null)\" ] && [ -z \"\$(find -L $HF_CACHE/hub/$local_sup_dir/snapshots -type l 2>/dev/null)\" ]" 2>/dev/null; then
    c_g "     ✓ node2: $SUPERVISOR_REPO (cached)"
  else
    c_y "     … syncing $SUPERVISOR_REPO from node1 → node2 over 200GbE CX7 (10.20.0.12)"
    # Use tar -chf (dereference symlinks) because HF Hub 1.x stores large xet tensors in ../../blobs/ outside the model dir.
    if SSH1 "tar -C $HF_CACHE/hub -chf - $local_sup_dir | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $SSHUSER@10.20.0.12 'mkdir -p $HF_CACHE/hub && rm -rf $HF_CACHE/hub/$local_sup_dir && tar -C $HF_CACHE/hub -xf -'" 2>/dev/null; then
      c_g "     ✓ node2: $SUPERVISOR_REPO (synced over 200GbE CX7)"
    else
      dl_model SSH2 "node2" "$SUPERVISOR_REPO"
    fi
  fi
fi
dl_model SSH2 "node2" "$NANO30B_REPO"
dl_model SSH2 "node2" "$GEMMA26B_REPO"
SSH2 "test -f $HF_CACHE/nano_v3_reasoning_parser.py || wget -q -O $HF_CACHE/nano_v3_reasoning_parser.py https://huggingface.co/$NANO30B_REPO/raw/main/nano_v3_reasoning_parser.py"

# ---- 5. serve the models ---------------------------------------------------
# GPU memory budget on 121GB unified GB10 memory:
#   Clustered Mode:
#     Spark 1: 0.44 (Nemotron-3-Super-120B TP=2 shard) + 0.28 (Devstral-24B) = 0.72
#     Spark 2: 0.44 (Nemotron-3-Super-120B TP=2 shard) + 0.20 (Gemma-4-26B) + 0.18 (Nano-30B) = 0.82
#   Standard Mode:
#     Spark 1: 0.28 (Devstral-24B) + 0.25 (Nemotron-3.5-Lightning-30B) = 0.53
#     Spark 2: 0.25 (Gemma-4-26B) + 0.25 (Nano-30B) = 0.50
# Always pass --enforce-eager on GB10 so PyTorch Inductor autotuning does not
# wedge the GPU GSP during multi-container startup.
wait_ready(){ local run="$1" name="$2" port="$3" cname="$4"
  for _ in $(seq 1 60); do
    [ "$($run "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:$port/v1/models" 2>/dev/null)" = "200" ] \
      && { c_g "     ✓ $name ready on :$port"; return 0; }
    $run "sudo -n docker ps --filter name=$cname --format '{{.Names}}'" 2>/dev/null | grep -q "$cname" \
      || { c_r "     ✗ $name ($cname) exited — check: docker logs $cname"; return 1; }
    sleep 10
  done
  c_r "     ✗ $name did not become ready on :$port (docker logs $cname)"; return 1
}

serve_solo(){ local run="$1" name="$2" repo="$3" port="$4" util="$5" extra="${6:-}"
  if [ "$($run "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:$port/v1/models" 2>/dev/null)" = "200" ]; then
    c_g "     ✓ $name already serving on :$port"; return 0
  fi
  $run "sudo -n docker rm -f spec-$name >/dev/null 2>&1 || true; sudo -n docker run -d --name spec-$name \
    --gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 --restart unless-stopped \
    -p $port:$port -e HF_HUB_OFFLINE=1 \
    -v $HF_CACHE:/root/.cache/huggingface \
    -v /home/$SSHUSER/.cache/vllm:/root/.cache/vllm \
    -v /home/$SSHUSER/.cache/flashinfer:/root/.cache/flashinfer \
    -v /home/$SSHUSER/.triton:/root/.triton \
    $VLLM_TAG \
    vllm serve $repo --host 0.0.0.0 --port $port --served-model-name $name \
    --gpu-memory-utilization $util --max-model-len 8192 --max-num-seqs 8 \
    --kv-cache-dtype fp8 --trust-remote-code --enforce-eager $extra >/dev/null" 2>/dev/null || return 1
  wait_ready "$run" "$name" "$port" "spec-$name"
}

hr; c_b "5) Serve models (sequential — largest first)"
if [[ "$CLUSTER_MODE" == "clustered" ]]; then
  c_b "   cluster (node1 + node2 over 200GbE CX7) — Supervisor ($SUPERVISOR_NAME, TP=2):"
  if [ "$(SSH1 "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:$SUPERVISOR_PORT/v1/models" 2>/dev/null)" = "200" ]; then
    c_g "     ✓ $SUPERVISOR_NAME already serving on :$SUPERVISOR_PORT"
  else
    SSH1 "sudo -n docker rm -f spec-nemotron-lightning >/dev/null 2>&1 || true"
    SSH1 "cd ~/spark-vllm-docker && ./launch-cluster.sh --name vllm_super stop >/dev/null 2>&1 || true; \
      ./launch-cluster.sh --name vllm_super --ray -d \
        -e VLLM_FLASHINFER_ALLREDUCE_BACKEND=trtllm \
        -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
        -e HF_HUB_OFFLINE=1 \
        exec vllm serve $SUPERVISOR_REPO \
          --served-model-name $SUPERVISOR_NAME \
          --kv-cache-dtype fp8 \
          --moe-backend cutlass \
          --trust-remote-code \
          --gpu-memory-utilization 0.44 \
          --max-model-len 16384 \
          --max-num-seqs 8 \
          --enable-prefix-caching \
          --host 0.0.0.0 \
          --port $SUPERVISOR_PORT \
          --enable-auto-tool-choice \
          --load-format instanttensor \
          --tool-call-parser qwen3_coder \
          --reasoning-parser nemotron_v3 \
          --mamba_ssm_cache_dtype float32 \
          --tensor-parallel-size 2 \
          --attention-backend TRITON_ATTN \
          --distributed-executor-backend ray \
          --enforce-eager >/dev/null"
    wait_ready SSH1 "$SUPERVISOR_NAME" "$SUPERVISOR_PORT" "vllm_super"
  fi
  GEMMA_UTIL="0.20"
  NANO_UTIL="0.18"
else
  SSH1 "cd ~/spark-vllm-docker 2>/dev/null && ./launch-cluster.sh --name vllm_super stop >/dev/null 2>&1 || true"
  c_b "   node1 — Supervisor ($SUPERVISOR_NAME, single-node):"
  serve_solo SSH1 "$SUPERVISOR_NAME" "$SUPERVISOR_REPO" "$SUPERVISOR_PORT" 0.25 "--load-format instanttensor --reasoning-parser nemotron_v3"
  GEMMA_UTIL="0.25"
  NANO_UTIL="0.25"
fi

c_b "   node1 — Coder & Tester ($DEVSTRAL_REPO on :8013):"
serve_solo SSH1 "devstral-24b" "$DEVSTRAL_REPO" 8013 0.28 "--load-format instanttensor"

c_b "   node2 — Architect & Writer ($GEMMA26B_REPO on :8012):"
serve_solo SSH2 "gemma4-26b" "$GEMMA26B_REPO" 8012 "$GEMMA_UTIL" \
  "--load-format instanttensor --reasoning-parser gemma4"

c_b "   node2 — Researcher, Analyst, Reviewer & Designer ($NANO30B_REPO on :8011):"
serve_solo SSH2 "nemotron-nano-30b" "$NANO30B_REPO" 8011 "$NANO_UTIL" \
  "--moe-backend cutlass --load-format fastsafetensors --reasoning-parser-plugin /root/.cache/huggingface/nano_v3_reasoning_parser.py --reasoning-parser nano_v3"

SSH2 "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://$NODE1:$SUPERVISOR_PORT/v1/models" 2>/dev/null | grep -q 200 \
  && c_g "  ✓ node2 can reach the supervisor on node1:$SUPERVISOR_PORT" \
  || c_y "  ! node2 cannot reach node1:$SUPERVISOR_PORT (check the firewall / --host binding)"

# ---- 6. shared Nemoclaw sandbox on node1 ----------------------------------
hr; c_b "6) Shared sandbox (node1)"
NEMOCLAW_ENV="export NEMOCLAW_PROVIDER=custom NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:$SUPERVISOR_PORT/v1 NEMOCLAW_MODEL=$SUPERVISOR_NAME COMPATIBLE_API_KEY=dummy NEMOCLAW_YES=1 NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PREFERRED_API=openai-completions NEMOCLAW_SANDBOX_NAME=swarm-team;"
if ! SSH1 'bash -lc "command -v nemoclaw"' >/dev/null 2>&1; then
  c_y "  … installing nemoclaw/openshell on node1 (a few minutes)"
  SSH1 'test -d ~/.nvm && chmod -R g-w,o-w ~/.nvm' >/dev/null 2>&1
  # Start a background watcher on node1 that kills any bundled nemoclaw-hf-download container
  # as soon as nemoclaw.sh spawns it, so bootstrap finishes in ~45s instead of downloading a 35B model.
  SSH1 'nohup bash -c "for _ in \$(seq 1 120); do sudo -n docker ps --format \"{{.Names}}\" 2>/dev/null | grep \"^nemoclaw-hf-download\" | xargs -r sudo -n docker rm -f >/dev/null 2>&1; sleep 2; done" >/dev/null 2>&1 < /dev/null &'
  SSH1 "bash -lc '$NEMOCLAW_ENV curl -fsSL -o /tmp/nemoclaw.sh https://www.nvidia.com/nemoclaw.sh && bash /tmp/nemoclaw.sh --non-interactive --yes-i-accept-third-party-software'" >/dev/null 2>&1
  if ! SSH1 'bash -lc "command -v nemoclaw"' >/dev/null 2>&1; then
    SSH1 'test -d ~/.nvm && chmod -R g-w,o-w ~/.nvm' >/dev/null 2>&1
    SSH1 "bash -lc '$NEMOCLAW_ENV bash /tmp/nemoclaw.sh --non-interactive --yes-i-accept-third-party-software'" >/dev/null 2>&1
  fi
  SSH1 'bash -lc "command -v nemoclaw"' >/dev/null 2>&1 \
    && c_g "  ✓ nemoclaw installed" \
    || c_y "  ! nemoclaw install failed — run on node1:
      chmod -R g-w,o-w ~/.nvm 2>/dev/null
      curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash"
  SSH1 'sudo -n docker ps --format "{{.Names}}" 2>/dev/null | grep "^nemoclaw-hf-download" \
        | xargs -r sudo -n docker rm -f' >/dev/null 2>&1
fi
if SSH1 'bash -lc "command -v nemoclaw"' >/dev/null 2>&1; then
  if SSH1 'bash -lc "openshell sandbox list 2>/dev/null | grep -q \"swarm-team.*Ready\""'; then
    c_g "  ✓ swarm-team sandbox ready"
  else
    SSH1 "bash -lc '$NEMOCLAW_ENV nemoclaw onboard --fresh --non-interactive --yes --yes-i-accept-third-party-software --name swarm-team --no-gpu --no-sandbox-gpu >/dev/null 2>&1'"
    SSH1 'bash -lc "openshell sandbox list 2>/dev/null | grep -q \"swarm-team.*Ready\""' \
      && c_g "  ✓ swarm-team sandbox ready" \
      || c_y "  ! sandbox provisioning needs attention (check nemoclaw on node1)"
  fi
else
  c_y "  ! no nemoclaw on node1 — Coder/Tester will describe code instead of running it."
fi

# Save .swarm.env on node1 and locally so ./run.sh picks up the selected mode automatically.
ENV_BLOCK="SWARM_NODE1=$NODE1
SWARM_NODE2=$NODE2
SWARM_SSH_USER=$SSHUSER
SWARM_CLUSTER_MODE=$CLUSTER_MODE
SWARM_MODEL=$SUPERVISOR_NAME
"
printf '%s' "$ENV_BLOCK" > .swarm.env
SSH1 "mkdir -p ~/swarm-assembly && cat > ~/swarm-assembly/.swarm.env <<'EOF'
$ENV_BLOCK
EOF" 2>/dev/null || true

# ---- 7. start dashboard on node1 (:4456) -----------------------------------
hr; c_b "7) Dashboard (:4456 on node1)"
if SSH1 "test -f ~/swarm-assembly/run.sh" 2>/dev/null; then
  SSH1 "cd ~/swarm-assembly && chmod +x run.sh && ./run.sh --dashboard-only"
elif [ -f ./run.sh ]; then
  chmod +x ./run.sh && ./run.sh --dashboard-only
fi

# ---- done ------------------------------------------------------------------
hr; c_g "Provisioning complete ($CLUSTER_MODE mode)."
c_b "Dashboard is live at:"
echo "  http://$NODE1:4456"
echo "  (restart anytime with: ./run.sh   |   stop with: ./run.sh --stop)"
