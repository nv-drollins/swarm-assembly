"""Per-Spark telemetry for the swarm dashboard.

Polls each node's GPU (nvidia-smi) and memory (free) over SSH, lightly cached
so the frontend can poll ~1Hz without hammering SSH. GB10 unified memory
returns [N/A] for GPU mem via nvidia-smi, so we use `free` for the memory bar.
"""
import asyncio
import time

import os

# Hosts come from the environment (run.sh exports them) so the repo carries no
# site-specific addresses -- at a venue you change SWARM_NODE1/2, nothing else.
NODES = {
    1: {"host": os.environ.get("SWARM_NODE1", "localhost"), "label": "Spark 1"},
    2: {"host": os.environ.get("SWARM_NODE2", "localhost"), "label": "Spark 2"},
}
SSH_USER = os.environ.get("SWARM_SSH_USER", "nvidia")

# nvidia-smi (gpu util %, temp C, power W) + free (mem used/total MB), one hop.
_REMOTE = (
    "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw "
    "--format=csv,noheader,nounits | head -1; "
    "free -m | awk '/^Mem:/{print $2, $3}'"
)

_cache: dict[int, dict] = {}
_cache_ts = 0.0
_TTL = 1.0  # seconds


async def _probe(node: int, host: str) -> dict:
    try:
        proc = await asyncio.create_subprocess_exec(
            "ssh", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=no",
            f"{SSH_USER}@{host}", _REMOTE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
        lines = [l.strip() for l in out.decode().splitlines() if l.strip()]
        gpu = temp = power = 0.0
        mem_total = mem_used = 0
        for l in lines:
            if "," in l:  # nvidia-smi line
                parts = [p.strip() for p in l.split(",")]
                gpu = _num(parts[0]); temp = _num(parts[1]) if len(parts) > 1 else 0
                power = _num(parts[2]) if len(parts) > 2 else 0
            elif len(l.split()) == 2:  # free line: total used
                mt, mu = l.split()
                mem_total, mem_used = int(mt), int(mu)
        return {"node": node, "ok": True, "gpu": gpu, "temp": temp, "power": power,
                "mem_used_gb": round(mem_used / 1024, 1), "mem_total_gb": round(mem_total / 1024, 1),
                "mem_pct": round(100 * mem_used / mem_total) if mem_total else 0}
    except Exception:  # noqa: BLE001
        return {"node": node, "ok": False}


def _num(s: str) -> float:
    try:
        return float(s.replace("%", "").replace("W", "").strip())
    except ValueError:
        return 0.0


async def snapshot() -> dict:
    """Return {node: telemetry} for both Sparks, cached for _TTL seconds."""
    global _cache, _cache_ts
    now = time.time()
    if _cache and now - _cache_ts < _TTL:
        return _cache
    results = await asyncio.gather(*(_probe(n, v["host"]) for n, v in NODES.items()))
    _cache = {r["node"]: r for r in results}
    _cache_ts = now
    return _cache
