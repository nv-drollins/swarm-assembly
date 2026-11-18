"""Swarm Assembly -- the bench of specialist agents (2-Spark cluster).

Eight known specialists sit idle on the bench. They do NOT run until the
supervisor recruits them; when recruited, a team assembles into a shared
Nemoclaw sandbox, collaborates via relay on their specialized models
(spread across two DGX Sparks), then disbands back to the bench.

Consolidated US/FR model lineup (zero 4B models, zero Chinese models):
  - Supervisor (:8001):
      * Clustered 200GbE mode: NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 (TP=2 across Spark 1 + 2)
      * Standard 1GbE mode:    NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 (Spark 1)
  - Coder & Tester (:8013 on Spark 1):
      * mistralai/Devstral-Small-2-24B-Instruct-2512 (FP8, shared instance)
  - Researcher, Analyst, Reviewer & Designer (:8011 on Spark 2):
      * nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4 (shared instance)
  - Architect & Writer (:8012 on Spark 2):
      * nvidia/Gemma-4-26B-A4B-NVFP4 (shared instance)
"""
import os

NODE1 = os.environ.get("SWARM_NODE1", "localhost")  # supervisor + coder + sandbox
NODE2 = os.environ.get("SWARM_NODE2", "")           # specialist farm (REQUIRED)
if not NODE2:
    raise SystemExit("SWARM_NODE2 must be set (hostname or IP of Spark 2). "
                     "Run via ./run.sh, which exports it.")

CLUSTER_MODE = os.environ.get("SWARM_CLUSTER_MODE", "clustered")  # "clustered" (120B TP=2) or "standard" (30B TP=1)
SUPERVISOR_MODEL = os.environ.get("SWARM_MODEL", "nemotron-super" if CLUSTER_MODE == "clustered" else "nemotron-lightning")

# Supervisor: reasons about the task and assembles the team.
# In clustered mode, Nemotron-3-Super-120B-A12B-NVFP4 is sharded TP=2 across
# Spark 1 + Spark 2 over 200GbE CX7 and served from node1:8001.
SUPERVISOR = {
    "id": "supervisor", "name": "Supervisor", "emoji": "\U0001F9E0",
    "specialty": "Task decomposition and team assembly",
    "model": SUPERVISOR_MODEL, "endpoint": f"http://{NODE1}:8001/v1", "node": 1,
    "clustered": CLUSTER_MODE == "clustered",
}

# Default model (supervisor's Nemotron) for specialists without a dedicated one.
_DEFAULT = {"model": SUPERVISOR_MODEL, "endpoint": f"http://{NODE1}:8001/v1", "node": 1}

# The bench: 8 specialists. `skills` guides recruitment; `system` is the persona.
# Multiple specialists share a high-capacity 24B-30B vLLM server on their Spark.
BENCH = [
    {"id": "researcher", "name": "Researcher", "emoji": "\U0001F50D",
     "skills": "web/API lookups, gathering facts and documentation",
     "system": "You are the Researcher. Gather relevant facts and context. Be concise.",
     "model": "nemotron-nano-30b", "endpoint": f"http://{NODE2}:8011/v1", "node": 1},  # Nemotron-3-Nano-30B (benched Spark 1, served Spark 2 :8011)
    {"id": "coder", "name": "Coder", "emoji": "\U0001F4BB",
     "skills": "writing and running code, scripts, automation",
     "system": "You are the Coder in a minimal non-root sandbox (no sudo, no pip "
               "installs). Write ONE small, self-contained Python script using ONLY "
               "the standard library that terminates in under 10s. You MUST include "
               "exactly one ```python code block that prints a result. Example:\n"
               "```python\nimport json, platform, os\nprint(json.dumps({'os': "
               "platform.platform(), 'cpus': os.cpu_count()}))\n```\n"
               "Then one line explaining it.",
     "model": "devstral-24b", "endpoint": f"http://{NODE1}:8013/v1", "node": 1},  # Devstral-Small-2-24B-FP8 on Spark 1 :8013
    {"id": "analyst", "name": "Analyst", "emoji": "\U0001F4CA",
     "skills": "data analysis, metrics, spotting patterns and anomalies",
     "system": "You are the Analyst. Interpret data and surface key insights as tight bullets.",
     "model": "nemotron-nano-30b", "endpoint": f"http://{NODE2}:8011/v1", "node": 2},  # Nemotron-3-Nano-30B on Spark 2 :8011
    {"id": "architect", "name": "Architect", "emoji": "\U0001F4D0",
     "skills": "system design, structure, planning technical approaches",
     "system": "You are the Architect. Propose a clear, pragmatic design or structure.",
     "model": "gemma4-26b", "endpoint": f"http://{NODE2}:8012/v1", "node": 2},  # Gemma-4-26B-A4B-NVFP4 on Spark 2 :8012
    {"id": "writer", "name": "Writer", "emoji": "\u270D\uFE0F",
     "skills": "clear writing, summaries, documentation, reports",
     "system": "You are the Writer. Produce clear, concise prose for the audience.",
     "model": "gemma4-26b", "endpoint": f"http://{NODE2}:8012/v1", "node": 2},  # Gemma-4-26B-A4B-NVFP4 on Spark 2 :8012
    {"id": "reviewer", "name": "Reviewer", "emoji": "\U0001F50E",
     "skills": "code review, quality checks, finding bugs and risks",
     "system": "You are the Reviewer. Critically assess for correctness, risks, and gaps. "
               "Give 2-4 specific, actionable findings.",
     "model": "nemotron-nano-30b", "endpoint": f"http://{NODE2}:8011/v1", "node": 2},  # Nemotron-3-Nano-30B on Spark 2 :8011
    {"id": "tester", "name": "Tester", "emoji": "\U0001F9EA",
     "skills": "test design, validation, edge cases, verification",
     "system": "You are the Tester in a minimal non-root sandbox. Validate the work "
               "with ONE small stdlib-only Python check in a ```python block that "
               "prints PASS/FAIL, then one line of commentary.",
     "model": "devstral-24b", "endpoint": f"http://{NODE1}:8013/v1", "node": 2},  # Devstral-Small-2-24B-FP8 (benched Spark 2, shared :8013)
    {"id": "designer", "name": "Designer", "emoji": "\U0001F3A8",
     "skills": "UX, visual/interaction design, user-facing polish",
     "system": "You are the Designer. Focus on user experience and presentation.",
     "model": "nemotron-nano-30b", "endpoint": f"http://{NODE2}:8011/v1", "node": 1},  # Nemotron-3-Nano-30B (benched Spark 1, shared :8011)
]

BENCH_BY_ID = {a["id"]: a for a in BENCH}
ALL_BY_ID = {SUPERVISOR["id"]: SUPERVISOR, **BENCH_BY_ID}


def roster_for_prompt() -> str:
    """One line per specialist for the supervisor's recruitment prompt."""
    return "\n".join(f"- {a['id']}: {a['name']} -- {a['skills']}" for a in BENCH)
