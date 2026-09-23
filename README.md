# 🐝 Swarm Assembly

A live, booth-ready **multi-agent swarm demo** for a **cluster of two NVIDIA DGX
Sparks** (GB10). A supervisor agent reasons about a task, **dynamically recruits
a team of specialists**, and assembles them into a shared NVIDIA Nemoclaw sandbox
where they collaborate — each specialist running on **its own specialized model,
spread across both Sparks**. When the task is done, the team disbands back to the
bench.

Everything is real: real models, a real two-node cluster, real code execution,
real GPU telemetry. Nothing is simulated.

---

## What it shows

- **Dynamic team assembly** — the supervisor (Nemotron 3.5 Lightning 30B) reads
  the task and recruits only the specialists it needs from a bench of 8.
- **A model per specialist, across two Sparks** — 9 distinct model servers run
  concurrently (supervisor + 8 specialists), split across the cluster. You can
  *see* the compute load move between the two nodes.
- **Real collaboration** — recruited agents relay in a shared sandbox, each
  building on prior teammates' output; the Coder and Tester run **real Python**.
- **Multi-round builds** — a specialist can be recruited more than once (e.g. the
  Coder implements, then fixes after the Reviewer's feedback).
- **Live per-Spark telemetry** — GPU %, memory, temperature, power for each node,
  updating ~1 Hz. The working Spark visibly lights up.
- **Inspect any agent** — click an active agent to filter the log to just what it
  is doing/thinking. Log lines are colored by Spark (green = Spark 1, purple =
  Spark 2, teal = Supervisor).
- **Download & re-test** — grab the code the swarm wrote, and re-run it in the
  sandbox from the UI.

---

## Architecture

```
                          Browser dashboard (canvas + WebSocket)
                                        │
                          FastAPI backend  :4456   (Spark 1 / node1)
                          orchestrator · approval · telemetry · WS
                                        │
         ┌──────────────────────────────┴──────────────────────────────┐
         │                                                              │
   SPARK 1 (node1)                                              SPARK 2 (node2)
   ├─ :8001  Supervisor  Nemotron 3.5 Lightning 30B            ├─ :8011 Analyst    Nemotron-Nano-4B
   ├─ :8013  Coder       Qwen2.5-Coder-7B-FP8                  ├─ :8012 Writer     Qwen3-4B
   ├─ :8017  Researcher  Nemotron-Nano-4B-FP8                  ├─ :8014 Architect  Qwen3-4B
   ├─ :8018  Designer    Nemotron-Nano-4B-FP8                  ├─ :8015 Tester     Qwen2.5-Coder-7B-FP8
   └─ Nemoclaw/OpenShell sandbox  (shared "swarm-team")        └─ :8016 Reviewer   Nemotron-Nano-4B-FP8
```

- Each model is served by its own **vLLM** container (NVIDIA vLLM image), pinned to
  a tight `--gpu-memory-utilization` so many coexist on a single GB10's unified memory.
- Recruited specialists share **one** Nemoclaw sandbox (`swarm-team`) — the "team in
  one workspace" model. Code execution happens there; a sample input file
  (`/tmp/sample.txt`) is seeded so file-based utilities have real data.
- Node IPs are **not hardcoded** — the backend reads `SWARM_NODE1` / `SWARM_NODE2`.

### The bench — 8 specialists, one model each

| Agent | Role | Model | Spark | Port |
|-------|------|-------|:-----:|:----:|
| **Supervisor** | Task decomposition & team assembly | Nemotron 3.5 Lightning **30B** | 1 | 8001 |
| **Researcher** | Gather facts & context | Nemotron-Nano-**4B** | 1 | 8017 |
| **Coder** | Write & run code | **Qwen2.5-Coder-7B** | 1 | 8013 |
| **Designer** | UX / presentation of output | Nemotron-Nano-**4B** | 1 | 8018 |
| **Analyst** | Data analysis & insights | Nemotron-Nano-**4B** | 2 | 8011 |
| **Architect** | System design & structure | **Qwen3-4B** | 2 | 8014 |
| **Writer** | Documentation & prose | **Qwen3-4B** | 2 | 8012 |
| **Reviewer** | Code review & risk | Nemotron-Nano-**4B** | 2 | 8016 |
| **Tester** | Test design & validation | **Qwen2.5-Coder-7B** | 2 | 8015 |

*Model choices: NVIDIA Nemotron for reasoning/analysis roles, Qwen2.5-Coder for
code roles, Qwen3 for design/writing. All FP8 where available (native on Blackwell).*

### Lifecycle of a task

1. **Recruit** — supervisor picks the team (either by reasoning, or a fixed
   sequence for the scripted builds).
2. **Assemble** — the recruited team spins up into the shared sandbox; idle agents
   animate from the bench into their Spark's work zone.
3. **Relay** — each teammate works in turn on its own model, seeing prior
   teammates' output; Coder/Tester execute real Python in the sandbox.
4. **Synthesize** — the supervisor stitches the team's work into a final result.
5. **Disband** — the workspace is cleared and agents return to the bench.

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

## Prerequisites

- **Two DGX Sparks (GB10)** clustered on the same network, reachable via SSH.
- On **both** nodes: Docker + NVIDIA Container Toolkit, and the NVIDIA vLLM image
  (the installer pulls it). Node 2 also needs Nemoclaw/OpenShell for its sandbox
  (the installer can set this up).
- A **HuggingFace token** with access to the model repos (for the one-time
  download). Nemotron models may require accepting terms on HF.
- Python 3.11+ on node 1 (for the FastAPI backend).

See **`install.sh`** — it checks each prerequisite and guides you through anything
missing. It does **not** assume specific IPs or passwordless sudo.

---

## Quick start

```bash
# On node 1 (the backend host), from the repo root:
./install.sh              # prompts for the two node IPs + HF token, checks prereqs,
                          # pulls the vLLM image, downloads models, serves all 9
                          # model endpoints across both Sparks, provisions the sandbox

# then launch the dashboard:
SWARM_NODE1=<node1-ip> SWARM_NODE2=<node2-ip> ./run.sh
# open http://<node1-ip>:4456
```

`run.sh` creates a venv, installs Python deps, and serves the dashboard on `:4456`.

### Environment variables

| Var | Default | Purpose |
|-----|---------|---------|
| `SWARM_NODE1` | `192.168.1.124` | IP/host of Spark 1 (supervisor, coder, researcher, designer + backend + sandbox) |
| `SWARM_NODE2` | `192.168.1.188` | IP/host of Spark 2 (analyst, writer, architect, tester, reviewer) |
| `SWARM_VLLM_BASE` | `http://localhost:8001/v1` | supervisor model endpoint |
| `SWARM_MODEL` | `nemotron-lightning` | supervisor served-model name |

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
install.sh         prereq checks + model/endpoint/sandbox provisioning
run.sh             venv + launch backend on :4456
```

## License

MIT
