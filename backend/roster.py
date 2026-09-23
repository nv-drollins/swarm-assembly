"""Swarm Assembly -- the bench of specialist agents (2-Spark cluster).

Eight known specialists sit idle on the bench. They do NOT run until the
supervisor recruits them; when recruited, a team assembles into a shared
Nemoclaw sandbox, collaborates via relay on their OWN specialized models
(spread across two DGX Sparks), then disbands back to the bench.

Each specialist can pin to its own model endpoint (model + node). Specialists
without a dedicated model fall back to the supervisor's Nemotron on node1.
"""
import os

NODE1 = os.environ.get("SWARM_NODE1", "192.168.1.124")  # supervisor + coder
NODE2 = os.environ.get("SWARM_NODE2", "192.168.1.188")  # writer + analyst farm

# Supervisor: reasons about the task and assembles the team. Runs on the big
# Nemotron-30B on node1.
SUPERVISOR = {
    "id": "supervisor", "name": "Supervisor", "emoji": "\U0001F9E0",
    "specialty": "Task decomposition and team assembly",
    "model": "nemotron-lightning", "endpoint": f"http://{NODE1}:8001/v1", "node": 1,
}

# Default model (supervisor's Nemotron) for specialists without a dedicated one.
_DEFAULT = {"model": "nemotron-lightning", "endpoint": f"http://{NODE1}:8001/v1", "node": 1}

# The bench: 8 specialists. `skills` guides recruitment; `system` is the persona.
# `model`/`endpoint`/`node` pin the specialist to its own specialized model.
BENCH = [
    {"id": "researcher", "name": "Researcher", "emoji": "\U0001F50D",
     "skills": "web/API lookups, gathering facts and documentation",
     "system": "You are the Researcher. Gather relevant facts and context. Be concise.",
     "model": "researcher", "endpoint": f"http://{NODE1}:8017/v1", "node": 1},  # Nemotron-Nano-4B on Spark 1
    {"id": "coder", "name": "Coder", "emoji": "\U0001F4BB",
     "skills": "writing and running code, scripts, automation",
     "system": "You are the Coder in a minimal non-root sandbox (no sudo, no pip "
               "installs). Write ONE small, self-contained Python script using ONLY "
               "the standard library that terminates in under 10s. You MUST include "
               "exactly one ```python code block that prints a result. Example:\n"
               "```python\nimport json, platform, os\nprint(json.dumps({'os': "
               "platform.platform(), 'cpus': os.cpu_count()}))\n```\n"
               "Then one line explaining it.",
     "model": "coder", "endpoint": f"http://{NODE1}:8013/v1", "node": 1},  # Qwen2.5-Coder-7B on Spark 1
    {"id": "analyst", "name": "Analyst", "emoji": "\U0001F4CA",
     "skills": "data analysis, metrics, spotting patterns and anomalies",
     "system": "You are the Analyst. Interpret data and surface key insights as tight bullets.",
     "model": "analyst", "endpoint": f"http://{NODE2}:8011/v1", "node": 2},  # Nemotron-Nano-4B on Spark 2
    {"id": "architect", "name": "Architect", "emoji": "\U0001F4D0",
     "skills": "system design, structure, planning technical approaches",
     "system": "You are the Architect. Propose a clear, pragmatic design or structure.",
     "model": "architect", "endpoint": f"http://{NODE2}:8014/v1", "node": 2},  # Qwen3-4B on Spark 2
    {"id": "writer", "name": "Writer", "emoji": "\u270D\uFE0F",
     "skills": "clear writing, summaries, documentation, reports",
     "system": "You are the Writer. Produce clear, concise prose for the audience.",
     "model": "writer", "endpoint": f"http://{NODE2}:8012/v1", "node": 2},  # Qwen3-4B on Spark 2
    {"id": "reviewer", "name": "Reviewer", "emoji": "\U0001F50E",
     "skills": "code review, quality checks, finding bugs and risks",
     "system": "You are the Reviewer. Critically assess for correctness, risks, and gaps. "
               "Give 2-4 specific, actionable findings.",
     "model": "reviewer", "endpoint": f"http://{NODE2}:8016/v1", "node": 2},  # Nemotron-Nano-4B on Spark 2
    {"id": "tester", "name": "Tester", "emoji": "\U0001F9EA",
     "skills": "test design, validation, edge cases, verification",
     "system": "You are the Tester in a minimal non-root sandbox. Validate the work "
               "with ONE small stdlib-only Python check in a ```python block that "
               "prints PASS/FAIL, then one line of commentary.",
     "model": "tester", "endpoint": f"http://{NODE2}:8015/v1", "node": 2},  # Qwen2.5-Coder-7B on Spark 2
    {"id": "designer", "name": "Designer", "emoji": "\U0001F3A8",
     "skills": "UX, visual/interaction design, user-facing polish",
     "system": "You are the Designer. Focus on user experience and presentation.",
     "model": "designer", "endpoint": f"http://{NODE1}:8018/v1", "node": 1},  # Nemotron-Nano-4B on Spark 1
]

BENCH_BY_ID = {a["id"]: a for a in BENCH}
ALL_BY_ID = {SUPERVISOR["id"]: SUPERVISOR, **BENCH_BY_ID}


def roster_for_prompt() -> str:
    """One line per specialist for the supervisor's recruitment prompt."""
    return "\n".join(f"- {a['id']}: {a['name']} -- {a['skills']}" for a in BENCH)
