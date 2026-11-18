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

Click a button on the dashboard to run one. The first four let the supervisor
**freely recruit** a 3–5 agent team; the last two are **scripted multi-round
builds** with a fixed sequence.

| Task | Type | What happens |
|------|------|--------------|
| **Analyze & Report** | free recruit | Supervisor assembles a small team to inspect the system's resource usage and write a short health report. Typically recruits Analyst + Coder + Writer. |
| **Build a Small Tool** | free recruit | Design, build, and test a small Python utility that summarizes a directory. Typically Architect + Coder + Tester. |
| **Research Brief** | free recruit | Research the tradeoffs of a topic and produce a concise written brief. Typically Researcher + Analyst + Writer — spans both Sparks. |
| **Review & Harden** | free recruit | Review a code approach for correctness/risks and propose tests. Typically Reviewer + Tester + Coder. |
| **Ship a Mini Feature** | scripted, multi-round | Full mini-SDLC on a word-frequency utility reading `/tmp/sample.txt`. Sequence: **Architect → Coder → Tester → Reviewer → Coder (fix) → Writer**. The Coder runs twice — implement, then fix after the Reviewer's feedback. Real code executes each round. |
| **Build a Data Pipeline** | scripted, multi-round | The **full-swarm showcase** — uses all 8 specialists. Builds a Python pipeline that reads `/tmp/sample.txt` and computes word stats (total/unique/top-10/avg length), validates, analyzes, designs the presentation, and documents. Sequence: **Researcher → Architect → Coder → Tester → Reviewer → Coder (fix) → Analyst → Designer → Writer**. Every specialist is recruited; the whole bench empties across both Sparks. |

After a scripted build finishes, the report panel offers **⬇ Download code** (the
assembled Python the team wrote) and **▶ Re-test in sandbox** (re-runs it against
the seeded sample and shows the real result).

---

## Quick start

```bash
# On node 1 (the backend host), from the repo root:
./install.sh              # prompts for node 1 + node 2 hostnames, SSH user, and
                          # Mode 1 (Clustered 200GbE 120B TP=2) vs Mode 2 (Standard 1GbE 30B).
                          # Configures CX7 networking (Mode 1), pulls vllm-node,
                          # downloads models, starts all servers, provisions sandbox,
                          # and writes .swarm.env.

# then launch the dashboard (also on node 1):
./run.sh
# open http://<node1-host>:4456
```

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
