"""Swarm Assembly -- FastAPI backend.

Serves the dashboard, exposes the bench + preset tasks, and runs a task while
broadcasting the recruit -> assemble -> relay -> disband lifecycle over WS.
"""
import asyncio
import json
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from roster import SUPERVISOR, BENCH
from llm import LLMClient
from orchestrator import Orchestrator

app = FastAPI(title="Swarm Assembly")
FRONTEND = Path(__file__).resolve().parent.parent / "frontend"

# Preset tasks chosen to make the supervisor recruit *different* teams.
TASKS = [
    {"id": "analyze_logs", "title": "Analyze & Report",
     "task": "Analyze this system's resource usage and write a short health report."},
    {"id": "build_tool", "title": "Build a Small Tool",
     "task": "Design, build, and test a small Python utility that summarizes a directory."},
    {"id": "research_brief", "title": "Research Brief",
     "task": "Research the tradeoffs of a topic and produce a concise, well-written brief."},
    {"id": "review_code", "title": "Review & Harden",
     "task": "Review a code approach for correctness and risks, then propose tests."},
    {"id": "ship_feature", "title": "Ship a Mini Feature",
     "task": "Design, build, test, review, fix, and document a small Python utility "
             "that counts word frequencies in the text file at /tmp/sample.txt and prints the top 5.",
     "sequence": ["architect", "coder", "tester", "reviewer", "coder", "writer"]},
    {"id": "data_pipeline", "title": "Build a Data Pipeline",
     "task": "Build a small Python data pipeline that reads /tmp/sample.txt, computes "
             "word-frequency statistics (total words, unique words, top-10, average word "
             "length), validates the output, analyzes the results, designs how the report "
             "should be presented to the user, and documents it. Full lifecycle: gather "
             "requirements, design, build, test, review, fix, analyze, design presentation, document.",
     "sequence": ["researcher", "architect", "coder", "tester", "reviewer",
                  "coder", "analyst", "designer", "writer"]},
]
TASKS_BY_ID = {t["id"]: t for t in TASKS}


class Hub:
    def __init__(self):
        self.clients: set[WebSocket] = set()
        self.lock = asyncio.Lock()
        self.busy = False

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.clients.add(ws)

    def disconnect(self, ws: WebSocket):
        self.clients.discard(ws)

    async def broadcast(self, event: str, data: dict):
        msg = json.dumps({"event": event, "data": data})
        for ws in list(self.clients):
            try:
                await ws.send_text(msg)
            except Exception:
                self.disconnect(ws)


hub = Hub()


async def emit(event: str, data: dict):
    await hub.broadcast(event, data)


@app.get("/api/bench")
async def get_bench():
    return {"supervisor": {k: SUPERVISOR[k] for k in ("id", "name", "emoji", "node")},
            "bench": [{**{k: a[k] for k in ("id", "name", "emoji", "skills", "node")},
                       "model": a["model"]} for a in BENCH]}


@app.get("/api/tasks")
async def get_tasks():
    return [{k: t[k] for k in ("id", "title", "task")} for t in TASKS]


@app.get("/api/health")
async def health():
    return JSONResponse({"llm": await LLMClient().health()})


@app.get("/api/telemetry")
async def get_telemetry():
    from telemetry import snapshot
    return JSONResponse(await snapshot())


def _assemble_code() -> str:
    """Stitch the team's generated code into one downloadable script."""
    from orchestrator import LAST_RUN
    parts = [f"# Swarm Assembly — code produced for task:\n# {LAST_RUN.get('task','')}\n"]
    for tid, code in LAST_RUN.get("code", {}).items():
        parts.append(f"\n# ===== {tid} =====\n{code}\n")
    return "".join(parts) if LAST_RUN.get("code") else "# (no code produced in the last run)\n"


@app.get("/api/code")
async def get_code():
    from fastapi.responses import PlainTextResponse
    return PlainTextResponse(_assemble_code(), headers={
        "Content-Disposition": "attachment; filename=swarm_output.py"})


@app.get("/api/code/info")
async def code_info():
    from orchestrator import LAST_RUN
    return JSONResponse({"task": LAST_RUN.get("task", ""),
                         "agents": list(LAST_RUN.get("code", {}).keys()),
                         "has_code": bool(LAST_RUN.get("code"))})


@app.post("/api/code/run")
async def code_run():
    """Re-run the last team's Coder code in the shared sandbox (a re-test).

    Seeds a sample input file first so file-reading utilities (e.g. the
    word-frequency tool) have real data to work on instead of erroring.
    """
    from orchestrator import LAST_RUN, SAMPLE_TEXT, seed_sample
    from sandbox import SwarmSandbox
    # Prefer a version that passed (rc=0) during the run; else the last attempt.
    good = LAST_RUN.get("good", {})
    code = (good.get("coder") or next(iter(good.values()), None)
            or LAST_RUN.get("code", {}).get("coder")
            or next(iter(LAST_RUN.get("code", {}).values()), None))
    if not code:
        return JSONResponse({"error": "no code from last run"}, status_code=404)
    sb = SwarmSandbox()
    if not sb.available or not await sb.spin_up("swarm-team"):
        return JSONResponse({"error": "sandbox unavailable"}, status_code=503)
    await seed_sample(sb, "swarm-team")
    res = await sb.exec("swarm-team", code, lang="python")
    return JSONResponse({"rc": res["code"], "stdout": res["stdout"][:2000], "engine": res.get("engine"),
                         "sample": "/tmp/sample.txt seeded"})


@app.post("/api/run/{task_id}")
async def run(task_id: str):
    t = TASKS_BY_ID.get(task_id)
    if not t:
        return JSONResponse({"error": "unknown task"}, status_code=404)
    async with hub.lock:
        if hub.busy:
            return JSONResponse({"error": "a task is already running"}, status_code=409)
        hub.busy = True
    asyncio.create_task(_run_and_release(t["task"], t.get("sequence")))
    return {"status": "started", "task": task_id}


async def _run_and_release(task: str, sequence=None):
    try:
        await Orchestrator(emit).run_task(task, sequence=sequence)
    except Exception as e:  # noqa: BLE001
        await emit("error", {"message": repr(e)})
    finally:
        hub.busy = False


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await hub.connect(ws)
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        hub.disconnect(ws)


@app.get("/")
async def index():
    return FileResponse(FRONTEND / "index.html")


if FRONTEND.exists():
    app.mount("/static", StaticFiles(directory=str(FRONTEND)), name="static")
