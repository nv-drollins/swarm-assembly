"""Swarm Assembly orchestration engine.

Lifecycle for one task:
  1. RECRUIT  -- supervisor (Nemotron reasoning) picks which specialists the
                 task needs from the bench.
  2. ASSEMBLE -- the recruited team spins up into ONE shared Nemoclaw sandbox;
                 idle agents animate from the bench to the work zone.
  3. RELAY    -- each teammate works in turn, seeing prior teammates' output,
                 so the team builds on its own work (real collaboration).
  4. DISBAND  -- the shared sandbox is destroyed and agents return to the bench.

Events emitted over WebSocket (via async `emit`):
  agent_state {agent, state}    idle|recruited|assembling|working|done
  recruit     {team:[ids], reasoning}   supervisor's team choice + why
  phase       {phase}           recruit|assemble|relay|disband|done
  team_sandbox{name, state}     up|down    the shared sandbox lifecycle
  stream      {agent, text}     live activity line
  reasoning   {agent, text}     model <think> trace
  exec        {agent, command, stdout, code}   real sandbox execution
  final       {report}          synthesized result
"""
import asyncio
from typing import Awaitable, Callable

from roster import SUPERVISOR, BENCH, BENCH_BY_ID, roster_for_prompt
from llm import LLMClient
from sandbox import SwarmSandbox

Emit = Callable[[str, dict], Awaitable[None]]

# Holds the most recent run's generated code + exec results, so the UI can
# download the code the team wrote and re-test it in the shared sandbox.
LAST_RUN: dict = {"task": "", "code": {}, "exec": {}}

# A sample input file so file-reading utilities (word counter, etc.) have real
# data to work on when their code runs in the sandbox.
SAMPLE_TEXT = ("the quick brown fox jumps over the lazy dog the dog barks the "
               "fox runs the quick fox wins the race again and again the end")


async def seed_sample(sandbox, sbx: str):
    """Write /tmp/sample.txt into the sandbox for file-based utilities to read."""
    py = f"open('/tmp/sample.txt','w').write({SAMPLE_TEXT!r}); print('seeded')"
    await sandbox.exec(sbx, py, lang="python", timeout=12)


class Orchestrator:
    def __init__(self, emit: Emit):
        self.emit = emit
        self.llm = LLMClient()
        self.sandbox = SwarmSandbox()

    async def _state(self, agent_id: str, state: str):
        await self.emit("agent_state", {"agent": agent_id, "state": state})

    async def _line(self, agent_id: str, text: str):
        await self.emit("stream", {"agent": agent_id, "text": text})

    async def run_task(self, task: str, team_size: tuple[int, int] = (3, 5),
                       sequence: list[str] | None = None):
        # reset bench
        for a in BENCH:
            await self._state(a["id"], "idle")
        await self._state("supervisor", "idle")
        LAST_RUN.update(task=task, code={}, exec={}, good={})  # fresh capture per run

        # 1) RECRUIT (or use a fixed multi-round sequence for feature builds)
        await self.emit("phase", {"phase": "recruit"})
        await self._state("supervisor", "working")
        await self._line("supervisor", f"New task: {task}")
        if sequence:
            # Ordered multi-round build (e.g. architect->coder->tester->reviewer->coder->writer).
            team = list(dict.fromkeys(sequence))  # unique agents for assembly/placement
            reasoning = "multi-round feature build"
            await self._line("supervisor", "planning a multi-round build: " + " \u2192 ".join(
                BENCH_BY_ID[t]["name"] for t in sequence))
        else:
            team, reasoning = await self._recruit(task, team_size)
        # Include node placement so the UI can show which Spark each agent lands on.
        placement = {tid: BENCH_BY_ID[tid]["node"] for tid in team}
        await self.emit("recruit", {"team": team, "reasoning": reasoning, "placement": placement})
        for tid in team:
            await self._state(tid, "recruited")
            await self._line("supervisor", f"\u2192 recruiting {BENCH_BY_ID[tid]['name']} (Spark {BENCH_BY_ID[tid]['node']})")
        await self._state("supervisor", "idle")

        # 2) ASSEMBLE -- one shared sandbox for the whole team
        await self.emit("phase", {"phase": "assemble"})
        # One reusable shared sandbox (pre-provisioned = instant assemble). The
        # create/destroy *lifecycle* is shown in the UI each task; the real
        # Nemoclaw sandbox is reused across tasks for booth snappiness.
        sbx = "swarm-team"
        for tid in team:
            await self._state(tid, "assembling")
        await self._line("supervisor", f"\U0001F4E6 assembling {len(team)} agents into shared sandbox\u2026")
        ready = await self.sandbox.spin_up(sbx)
        if ready:
            await seed_sample(self.sandbox, sbx)  # give file-based code real input
        await self.emit("team_sandbox", {"name": sbx, "state": "up", "team": team, "real": ready})

        # 3) RELAY -- teammates build on each other's work in the shared sandbox.
        # For a feature build, iterate the ordered sequence (agents can repeat,
        # e.g. Coder implements then fixes after the Reviewer's feedback).
        await self.emit("phase", {"phase": "relay"})
        prior = []
        results = {}
        run_order = sequence if sequence else team
        for step, tid in enumerate(run_order, 1):
            if sequence and run_order.count(tid) > 1:
                # mark the round for agents that appear more than once
                nth = run_order[:step].count(tid)
                await self._line(tid, f"\u2014 round {nth} \u2014")
            out = await self._run_member(tid, task, prior, sbx, ready)
            results[tid] = out  # last contribution wins for the digest
            if out.strip():
                prior.append({"name": BENCH_BY_ID[tid]["name"], "output": out})

        # 4) synthesize final report (supervisor)
        await self.emit("phase", {"phase": "synthesize"})
        report = await self._synthesize(task, team, results)

        # 5) DISBAND -- clear the shared workspace, agents return to the bench.
        # (The sandbox is kept warm/reused so re-assembly is instant next task.)
        await self.emit("phase", {"phase": "disband"})
        if ready:
            await self._line("supervisor", f"\U0001F9F9 clearing shared sandbox, releasing team\u2026")
            await self.sandbox.clear(sbx)
        await self.emit("team_sandbox", {"name": sbx, "state": "down", "team": team})
        for tid in team:
            await self._state(tid, "idle")  # back to general population

        await self.emit("phase", {"phase": "done"})
        await self.emit("final", {"report": report})
        return report

    async def _recruit(self, task: str, team_size: tuple[int, int]) -> tuple[list[str], str]:
        lo, hi = team_size
        prompt = (
            f"Task: {task}\n\n"
            f"Available specialists (id: name -- skills):\n{roster_for_prompt()}\n\n"
            f"Pick the {lo}-{hi} specialists best suited to this task. Answer with "
            f"ONLY a comma-separated list of their ids on the first line (e.g. "
            f"'researcher, coder, writer'), then one short sentence explaining the choice."
        )
        out = await self.llm.chat(
            [{"role": "system", "content": SUPERVISOR["specialty"] +
              ". You assemble the smallest effective team. Be decisive."},
             {"role": "user", "content": prompt}],
            max_tokens=2000, temperature=0.3,
        )
        if out["reasoning"]:
            await self.emit("reasoning", {"agent": "supervisor", "text": out["reasoning"][:500]})
        # parse first line of ids
        lines = [l.strip() for l in out["content"].splitlines() if l.strip()]
        ids, reasoning = [], ""
        if lines:
            first = lines[0].replace(".", "")
            ids = [t.strip().lower() for t in first.split(",") if t.strip().lower() in BENCH_BY_ID]
            reasoning = " ".join(lines[1:])[:200] if len(lines) > 1 else ""
        # fallback: sensible default team if parsing yielded too few
        if len(ids) < lo:
            ids = ["researcher", "coder", "writer"]
            reasoning = reasoning or "Default balanced team."
        return ids[:hi], reasoning

    async def _run_member(self, tid: str, task: str, prior: list, sbx: str, ready: bool) -> str:
        agent = BENCH_BY_ID[tid]
        await self._state(tid, "working")
        # Announce which specialized model + Spark this agent runs on.
        model_short = {"nemotron-lightning": "Nemotron-30B", "coder": "Qwen-Coder-7B",
                       "writer": "Qwen3-4B", "analyst": "Nemotron-Nano-4B",
                       "architect": "Qwen3-4B", "reviewer": "Nemotron-Nano-4B",
                       "tester": "Qwen-Coder-7B", "researcher": "Nemotron-Nano-4B",
                       "designer": "Nemotron-Nano-4B"}.get(agent["model"], agent["model"])
        await self._line(tid, f"running on {model_short} (Spark {agent['node']})\u2026")
        context = ""
        if prior:
            context = "\n\nYour teammates have already produced:\n" + "\n".join(
                f"[{p['name']}] {p['output'][:300]}" for p in prior)
        out = await self.llm.chat(
            [{"role": "system", "content": agent["system"]},
             {"role": "user", "content": f"Team task: {task}{context}\n\n"
              f"Contribute your part as {agent['name']}. Be concise."}],
            max_tokens=2500, temperature=0.4,
            base=agent["endpoint"], model=agent["model"],  # each specialist on its OWN model
        )
        if out["reasoning"]:
            await self.emit("reasoning", {"agent": tid, "text": out["reasoning"][:300]})
        text = out["content"]
        # Coder/Tester run real code in the shared sandbox (execution roles).
        if ready and tid in ("coder", "tester"):
            code = _extract_python(text)
            if not code:
                # Retry once, demanding ONLY a runnable python block (LLMs sometimes
                # answer in prose first). Keeps exec reliable in the feature build.
                retry = await self.llm.chat(
                    [{"role": "system", "content": "Output ONLY one ```python code block that "
                      "runs with the stdlib and prints a result. No prose."},
                     {"role": "user", "content": f"Task: {task}\n\nWrite the runnable Python now."}],
                    max_tokens=1200, temperature=0.2,
                    base=agent["endpoint"], model=agent["model"],
                )
                code = _extract_python(retry["content"])
                if code:
                    text += "\n\n" + retry["content"]
            if code:
                LAST_RUN["code"][tid] = code            # capture for download/re-test
                res = await self.sandbox.exec(sbx, code, lang="python")
                LAST_RUN["exec"][tid] = {"rc": res["code"], "stdout": res["stdout"][:1500]}
                if res["code"] == 0:
                    LAST_RUN.setdefault("good", {})[tid] = code   # known-passing version
                await self.emit("exec", {"agent": tid, "command": code[:200],
                                         "stdout": res["stdout"][:800], "code": res["code"]})
                text += f"\n\n[ran in {sbx} rc={res['code']}]\n{res['stdout'][:400]}"
        await self._line(tid, "done \u2713")
        await self._state(tid, "recruited")  # stays in the team box until disband
        return text

    async def _synthesize(self, task: str, team: list, results: dict) -> str:
        await self._state("supervisor", "working")
        digest = "\n\n".join(f"[{BENCH_BY_ID[t]['name']}]\n{results.get(t,'')[:400]}" for t in team)
        out = await self.llm.chat(
            [{"role": "system", "content": "You are the Supervisor. Synthesize the team's work "
              "into a clear, concise final result for the user."},
             {"role": "user", "content": f"Task: {task}\n\nTeam contributions:\n{digest}\n\n"
              "Write the final result (3-5 sentences)."}],
            max_tokens=2500, temperature=0.4,
        )
        await self._state("supervisor", "idle")
        await self._line("supervisor", "final result ready \u2728")
        return out["content"]


import re

_PY_RE = re.compile(r"```(?:python)?\s*\n(.*?)```", re.DOTALL)


def _extract_python(text: str) -> str | None:
    m = _PY_RE.search(text or "")
    return m.group(1).strip() if m else None
