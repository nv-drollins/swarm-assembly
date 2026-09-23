"""Shared-team Nemoclaw sandbox lifecycle for Swarm Assembly.

A recruited team of specialists shares ONE ephemeral Nemoclaw sandbox:
  spin_up(team_id)   -> onboard a fresh sandbox pointed at our local vLLM
  exec(name, cmd)    -> run a command inside it (bash or python)
  destroy(name)      -> tear it down when the task completes

Verified recipe (from the agentic-hive build / Lobster-Agents reference):
onboard the DEFAULT relay image (NO --from), point at our existing vLLM via
host.openshell.internal:8001, provider=custom. Reuses our Nemotron -- no second
model, no second vLLM. If tooling is unavailable, callers fall back to local
subprocess so the demo still runs.
"""
import asyncio
import os
import shutil

OPENSHELL = shutil.which("openshell") or os.path.expanduser("~/.local/bin/openshell")
NEMOCLAW = shutil.which("nemoclaw") or os.path.expanduser(
    "~/.nvm/versions/node/v22.23.2/bin/nemoclaw")

ENDPOINT_URL = os.environ.get("SWARM_SANDBOX_ENDPOINT", "http://host.openshell.internal:8001/v1")
MODEL = os.environ.get("SWARM_MODEL", "nemotron-lightning")


async def _run(*argv: str, timeout: float = 60.0, env: dict | None = None) -> dict:
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env={**os.environ, **(env or {})},
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return {"stdout": out.decode(errors="replace"),
                "stderr": err.decode(errors="replace"), "code": proc.returncode}
    except asyncio.TimeoutError:
        return {"stdout": "", "stderr": f"timeout {timeout}s", "code": 124}
    except Exception as e:  # noqa: BLE001
        return {"stdout": "", "stderr": repr(e), "code": 1}


class SwarmSandbox:
    def __init__(self):
        self.available = bool(OPENSHELL and NEMOCLAW)

    async def _ready(self, name: str) -> bool:
        r = await _run(OPENSHELL, "sandbox", "list", timeout=20)
        return any(line.split()[:1] == [name] and "Ready" in line
                   for line in r["stdout"].splitlines() if line.split())

    async def spin_up(self, name: str, timeout: float = 300.0) -> bool:
        """Create ONE shared sandbox for a recruited team."""
        if not self.available:
            return False
        if await self._ready(name):
            return True
        env = {
            "NEMOCLAW_PROVIDER": "custom", "NEMOCLAW_ENDPOINT_URL": ENDPOINT_URL,
            "NEMOCLAW_MODEL": MODEL, "COMPATIBLE_API_KEY": "dummy",
            "NEMOCLAW_YES": "1", "NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE": "1",
            "NEMOCLAW_PREFERRED_API": "openai-completions",
        }
        r = await _run(
            NEMOCLAW, "onboard", "--non-interactive", "--yes",
            "--yes-i-accept-third-party-software", "--name", name,
            "--no-gpu", "--no-sandbox-gpu", timeout=timeout, env=env,
        )
        return r["code"] == 0 or await self._ready(name)

    async def exec(self, name: str, command: str, timeout: float = 25.0, lang: str = "bash") -> dict:
        runner = ["python3", "-c", command] if lang == "python" else ["bash", "-lc", command]
        r = await _run(OPENSHELL, "sandbox", "exec", "--name", name, "--no-tty",
                       "--timeout", str(int(timeout)), "--", *runner, timeout=timeout + 8)
        r["engine"] = f"nemoclaw:{name}"
        if r["code"] != 0 and not r["stdout"].strip() and r["stderr"].strip():
            r["stdout"] = f"[stderr] {r['stderr'].strip()[:600]}"
        return r

    async def destroy(self, name: str) -> dict:
        return await _run(NEMOCLAW, name, "destroy", "--yes", timeout=45)

    async def clear(self, name: str) -> dict:
        """Wipe the shared workspace but keep the sandbox warm for reuse."""
        return await self.exec(name, "rm -rf /sandbox/work/* 2>/dev/null; mkdir -p /sandbox/work; echo cleared", timeout=15)
