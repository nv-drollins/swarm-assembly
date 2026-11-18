# 🐝 Swarm Assembly

A live, booth-ready **multi-agent swarm demo** for a **cluster of two NVIDIA DGX
Sparks** (GB10). A supervisor agent reasons about a task, **dynamically recruits
a team of specialists**, and assembles them into a shared NVIDIA Nemoclaw sandbox
where they collaborate — each specialist running on **its specialized model,
spread across both Sparks**. When the task is done, the team disbands back to the
bench.

Everything is real: real models, a real two-node cluster, real code execution,
real GPU telemetry. Nothing is simulated.

---

## What it shows

- **Two selectable cluster modes at install time:**
  - **Mode 1 — Clustered 200GbE Mode (default):** The Supervisor runs **`nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4`**, sharded `TP=2` across Spark 1 and Spark 2 over the **2× 200GbE ConnectX-7 RoCEv2** direct link using Ray + RDMA.
  - **Mode 2 — Standard 1GbE Mode:** The Supervisor runs **`nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4`** on Spark 1 with no 200GbE cable required.
- **Consolidated 24B–30B US/FR specialist servers** — instead of 8 tiny 4B containers, specialists share 3 high-capacity 24B–30B vLLM servers across the two Sparks (Mistral `Devstral-Small-2-24B` in FP8, NVIDIA `Nemotron-3-Nano-30B` in NVFP4, and Google/NVIDIA `Gemma-4-26B-A4B` in NVFP4).
- **Dynamic team assembly** — the supervisor reads the task and recruits only the specialists it needs from a bench of 8.
- **Real collaboration** — recruited agents relay in a shared sandbox, each building on prior teammates' output; the Coder and Tester run **real Python**.
- **Multi-round builds** — a specialist can be recruited more than once (e.g. the Coder implements, then fixes after the Reviewer's feedback).
- **Live per-Spark telemetry** — GPU %, memory, temperature, power for each node, updating ~1 Hz.
- **Inspect any agent** — click an active agent node to filter the log to just what it is doing/thinking (with full, uncapped `💭` reasoning traces). Log lines are colored by Spark (green = Spark 1, purple = Spark 2, teal = Supervisor).
- **Download & re-test** — grab the code the swarm wrote, and re-run it in the sandbox from the UI.

---

## Architecture

```
                          Browser dashboard (canvas + WebSocket)
                                        │
                          FastAPI backend  :4456   (Spark 1 / node1)
                          orchestrator · approval · telemetry · WS
                                        │
         ┌──────────────────────────────┴──────────────────────────────┐
         │                 2× 200GbE ConnectX-7 (RoCEv2)               │
   SPARK 1 (node1) ◄══════════════════ TP=2 ══════════════════► SPARK 2 (node2)
   ├─ :8001  Supervisor  Nemotron-3-Super-120B-NVFP4 (TP=2 shard 0)  ├─ (TP=2 shard 1 of Supervisor)
   │         (or Nemotron-3.5-Lightning-30B-NVFP4 in Standard Mode)  ├─ :8011  Nemotron-3-Nano-30B-NVFP4
   ├─ :8013  Devstral-Small-2-24B-Instruct-2512 (FP8)                │         (Researcher, Analyst, Reviewer, Designer)
   │         (Coder, Tester)                                         └─ :8012  Gemma-4-26B-A4B-NVFP4
   └─ Nemoclaw/OpenShell sandbox  (shared "swarm-team")                        (Architect, Writer)
```

- All models run on the DGX Spark-optimized **`eugr/spark-vllm:latest`** (`vllm-node`) container with `instanttensor` / `fastsafetensors` weight loading and FlashInfer/CUTLASS Blackwell (`sm_121a`) kernels.
- Recruited specialists share **one** Nemoclaw sandbox (`swarm-team`) — the "team in one workspace" model. Code execution happens there; a sample input file (`/tmp/sample.txt`) is seeded so file-based utilities have real data.
- Node IPs are **not hardcoded** — the backend reads `SWARM_NODE1` / `SWARM_NODE2`.

### The bench — 8 specialists across 4 shared model servers

| Agent(s) | Role | Model | Origin | Served On | Port |
|----------|------|-------|--------|:---------:|:----:|
| **Supervisor** | Task decomposition & team assembly | **Nemotron-3-Super-120B-A12B** (NVFP4, `TP=2`) *(or Nemotron-3.5-Lightning-30B in Standard mode)* | NVIDIA (US) | Spark 1 + 2 (`TP=2`) | 8001 |
| **Coder**, **Tester** | Write, run & validate Python in sandbox | **Devstral-Small-2-24B-Instruct-2512** (FP8) | Mistral (FR) | Spark 1 | 8013 |
| **Researcher**, **Analyst**, **Reviewer**, **Designer** | Research, data analysis, code review, UX | **Nemotron-3-Nano-30B-A3B** (NVFP4) | NVIDIA (US) | Spark 2 | 8011 |
| **Architect**, **Writer** | System design, documentation & prose | **Gemma-4-26B-A4B** (NVFP4) | Google / NVIDIA (US) | Spark 2 | 8012 |

---

## Demo tasks

Click a button on the dashboard to run one. The first six let the supervisor
**freely recruit** a 3–5 agent team; the last four are **scripted multi-round
builds** with a fixed sequence.

| Task | Type | What happens |
|------|------|--------------|
| **Analyze & Report** | free recruit | Supervisor assembles a team to inspect the system's resource usage, design a status layout for operators, and write a concise health report. Typically recruits Analyst + Designer + Coder + Writer. |
| **Build a Small Tool** | free recruit | Design, build, and test a small Python utility that summarizes a directory. Typically Architect + Coder + Tester. |
| **Design Interactive CLI** | free recruit | Research what operators need from a live DGX Spark cluster status card, design an ergonomic ASCII/ANSI terminal dashboard layout, implement a Python generator in the sandbox, and document the UX guidelines. Typically Researcher + Designer + Coder + Writer. |
| **API & UX Spec** | free recruit | Architect a REST + WebSocket API for a local AI inference monitor, design the user-facing dashboard layout and interaction states, review for usability, and write a developer handoff brief. Typically Architect + Designer + Reviewer + Writer. |
| **Incident Triage & RCA** | free recruit | Triage a latency and memory spike on an inference cluster: write a Python log/metric anomaly detector against `/tmp/sample.txt`, analyze root cause patterns, and write an executive RCA. Typically Analyst + Coder + Researcher + Writer. |
| **Review & Harden** | free recruit | Review a code approach for correctness/risks and propose and run tests. Typically Reviewer + Tester + Coder. |
| **Security Audit & Patch** | scripted, multi-round | Audits a Python token/config parser for security vulnerabilities, implements a hardened stdlib-only version over `/tmp/sample.txt`, validates it with an exploit test suite, re-reviews the patch, and writes a security advisory. Sequence: **Reviewer → Coder → Tester → Reviewer → Writer**. |
| **Benchmark & Optimize** | scripted, multi-round | Writes a baseline Python text-indexing script over `/tmp/sample.txt` and measures execution time, analyzes bottlenecks, implements an optimized version and compares before/after timings in the sandbox, verifies output parity, designs a benchmark comparison table, and summarizes the speedup. Sequence: **Coder → Analyst → Coder (optimize) → Tester → Designer → Writer**. |
| **Ship a Mini Feature** | scripted, multi-round | Full mini-SDLC on a word-frequency utility reading `/tmp/sample.txt`. Sequence: **Architect → Designer → Coder → Tester → Reviewer → Coder (fix) → Writer**. The Coder runs twice — implement, then fix after the Reviewer's feedback. Real code executes each round. |
| **Build a Data Pipeline** | scripted, multi-round | The **full-swarm showcase** — uses all 8 specialists. Builds a Python pipeline that reads `/tmp/sample.txt` and computes word stats (total/unique/top-10/avg length), validates, analyzes, designs the presentation, and documents. Sequence: **Researcher → Architect → Coder → Tester → Reviewer → Coder (fix) → Analyst → Designer → Writer**. Every specialist is recruited; the whole bench empties across both Sparks. |

After a scripted build finishes, the report panel offers **⬇ Download code** (the
assembled Python the team wrote) and **▶ Re-test in sandbox** (re-runs it against
the seeded sample and shows the real result).

---

## Hardware Cabling (200GbE ConnectX-7 Direct Link — Mode 1)

When using **Mode 1 (Clustered 200GbE Mode)**, connect the QSFP cable directly between the two DGX Sparks using the standard port pairing required by `setup-cluster.sh`:

- **Node 1 (Spark 1) QSFP Port 0**  ──►  **Node 2 (Spark 2) QSFP Port 1**
  - **QSFP Port 0** is the QSFP port physically **next to the RJ45 Ethernet jack** (`enp1s0f0np0` / `enP2p1s0f0np0`).
  - **QSFP Port 1** is the outer QSFP port (`enp1s0f1np1` / `enP2p1s0f1np1`).
- Each QSFP port exposes two PCIe/RoCEv2 paths (`10.20.0.11/24 ↔ 10.20.0.12/24` and `10.20.1.11/24 ↔ 10.20.1.12/24`, `MTU 9000`).
- **Expected 200GbE RDMA bandwidth on the dashboard:**
  - During `TP=2` token generation (`Nemotron-3-Super-120B-A12B-NVFP4`), each token requires small, ultra-low-latency tensor-parallel `AllReduce` synchronization across all 88 layers (~300–500 MB per response). On the dashboard's 1.2s telemetry poll, this shows up as **~50–250 MB/s (0.4–2.0 Gbps)** bursts during Supervisor thinking/synthesis (whereas a raw `nccl-tests` large-buffer `all_reduce_perf` benchmark saturates the dual paths at **~22–24 GB/s / ~180–195 Gbps**).
- In **Mode 2 (Standard 1GbE Mode)**, the `⚡ 2× 200GbE CX7 RoCEv2 (TP=2)` bridge and `[120B TP=2 Shard]` tags are automatically hidden on the dashboard.

---

## Quick start (Fresh Install on Two DGX Sparks)

Run all steps below **on Node 1 (Spark 1)** logged in as `nvidia`. You can use either `.local` hostnames (e.g. `spark-6b64.local` / `spark-ae2c.local`, recommended for venue DHCP resilience) or static/LAN IP addresses (e.g. `192.168.1.159` / `192.168.1.188`).

### 1. Generate & Authorize SSH Keys (on Node 1)

`install.sh` and the live telemetry poller SSH into both Node 1 (itself) and Node 2. Generate an Ed25519 key on Node 1 and copy it to **both** nodes:

```bash
# On Node 1:
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Authorize on Node 1 itself:
ssh-copy-id -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519.pub nvidia@<node1-host-or-ip>

# Authorize on Node 2:
ssh-copy-id -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519.pub nvidia@<node2-host-or-ip>
```

### 2. Optional: Export a Hugging Face Token (on Node 1)

All models in the roster are **ungated**, so no token is strictly required. However, exporting a read token prevents Hugging Face Hub rate-limiting during the initial ~135 GB model download:

```bash
export HF_TOKEN=hf_...
```
*(Or add `export HF_TOKEN=hf_...` to `~/.bashrc` on Node 1 — `install.sh` detects it automatically.)*

### 3. Clone & Run `./install.sh` (on Node 1)

```bash
git clone https://github.com/nv-drollins/swarm-assembly.git
cd swarm-assembly
./install.sh
```

What `./install.sh` prompts for and automates:
1. **Node 1 host, Node 2 host, and SSH user** (defaults to `nvidia`).
2. **Mode selection:**
   - **`1` — Clustered 200GbE Mode (default):** Configures the 200GbE ConnectX-7 RoCEv2 link via `spark-vllm-docker/setup-cluster.sh` and serves `NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` sharded `TP=2` across Spark 1 + Spark 2.
   - **`2` — Standard 1GbE Mode:** Uses plain 1GbE LAN and serves `NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` on Spark 1.
3. **One-time sudo password prompt (on freshly imaged Sparks):** If `sudo` requires a password, `install.sh` prompts once in memory and configures passwordless sudo (`/etc/sudoers.d/90-nvidia-nopasswd`) on both nodes so all Docker/runtime/netplan steps run unattended.
4. **Host prerequisites & containers:** Installs `python3-venv` and `nvidia-container-toolkit` (if missing), registers the NVIDIA Docker runtime, adds `nvidia` to the `docker` group, pulls `eugr/spark-vllm:latest` (`vllm-node`), downloads models (syncing the 75 GB 120B checkpoint from Node 1 to Node 2 over the 200GbE link in Mode 1), starts all 4 model servers in largest-first memory order, provisions the `swarm-team` NemoClaw sandbox, saves `.swarm.env`, and **starts the dashboard in the background on `:4456`**.

Open **`http://<node1-host-or-ip>:4456`** in your browser.

---

## Bringing Everything Back Online After a Reboot (`./run.sh`)

If you power down or reboot both DGX Sparks, **you only need to run one command on Node 1** once they boot back up:

```bash
cd ~/swarm-assembly
./run.sh
```

### What happens under the hood after a reboot?
- In **Clustered 200GbE Mode**, the `TP=2` Supervisor (`vllm_super` on `:8001`) spans both nodes via Ray (`--rm`), so it does not auto-start across nodes on boot — whereas the solo specialist containers (`--restart unless-stopped`) *do* auto-start on boot.
- Because GB10 uses 121 GB of unified memory, starting the smaller specialist containers before the 120B `TP=2` Supervisor would leave too little contiguous memory for the 120B shard.
- **`./run.sh` handles this automatically:**
  1. It reads `.swarm.env` (saved by `install.sh`) and checks if `:8001` (the Supervisor) is responding.
  2. If `:8001` is offline (e.g. after a reboot), `./run.sh` automatically stops any auto-started `spec-*` containers on both Sparks and runs **`./install.sh --resume`** (non-interactive, zero prompts, using your saved `.swarm.env` settings).
  3. `./install.sh --resume` verifies the 200GbE CX7 link, starts the 120B `TP=2` Supervisor (`:8001`) first while GPU memory is uncontended, starts the 3 specialist servers (`:8013, :8012, :8011`), verifies the `swarm-team` sandbox, and launches the `:4456` web dashboard in the background.
- If all model servers are already up and you just want to restart/stop the web dashboard:
  - `./run.sh` — restarts the web dashboard in the background (logs to `/tmp/swarm-web.log`).
  - `./run.sh --stop` — stops the background web dashboard.
  - `./run.sh --fg` — runs the web dashboard in the foreground.

### Environment variables

| Var | Default | Purpose |
|-----|---------|---------|
| `SWARM_NODE1` | *(from `.swarm.env` or required)* | host of Spark 1 (supervisor head, Devstral-24B coder/tester, backend, sandbox) |
| `SWARM_NODE2` | *(from `.swarm.env` or required)* | host of Spark 2 (supervisor worker shard, Nano-30B, Gemma-4-26B) |
| `SWARM_CLUSTER_MODE` | `clustered` | `clustered` (`Nemotron-3-Super-120B` `TP=2` over 200GbE) or `standard` (`Nemotron-3.5-Lightning-30B`) |
| `SWARM_SSH_USER` | `nvidia` | SSH user used for telemetry polling |
| `SWARM_VLLM_BASE` | `http://$SWARM_NODE1:8001/v1` | supervisor model endpoint |
| `SWARM_MODEL` | `nemotron-super` (or `nemotron-lightning`) | supervisor served-model name |

---

## Project layout

```
backend/
  main.py          FastAPI app, tasks, WebSocket hub, code + telemetry endpoints
  orchestrator.py  recruit → assemble → relay → synthesize → disband engine
  roster.py        the 8 specialists + supervisor: models, endpoints, node placement
  sandbox.py       Nemoclaw/OpenShell shared-sandbox lifecycle + exec
  telemetry.py     per-Spark GPU/mem/temp/power over SSH
  llm.py           OpenAI-compatible client (per-call endpoint/model)
frontend/
  index.html       dashboard shell
  swarm.js         canvas: two Spark zones, assembly animation, telemetry, log
install.sh         prereq checks + CX7 cluster setup + model/endpoint/sandbox provisioning
run.sh             venv + launch backend on :4456
```

## License

MIT
