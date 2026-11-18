"""Per-Spark telemetry for the swarm dashboard.

Polls each node's GPU (nvidia-smi), memory (free), and 200GbE ConnectX-7 RoCEv2
counters over SSH, lightly cached so the frontend can poll ~1Hz without
hammering SSH. GB10 unified memory returns [N/A] for GPU mem via nvidia-smi, so
we use `free` for the memory bar (both `used` and `total - available` so OS buffer
cache is distinguished from locked model memory).
"""
import asyncio
import os
import time

# Hosts come from the environment (run.sh exports them) so the repo carries no
# site-specific addresses -- at a venue you change SWARM_NODE1/2, nothing else.
NODES = {
    1: {"host": os.environ.get("SWARM_NODE1", "localhost"), "label": "Spark 1"},
    2: {"host": os.environ.get("SWARM_NODE2", "localhost"), "label": "Spark 2"},
}
SSH_USER = os.environ.get("SWARM_SSH_USER", "nvidia")

# nvidia-smi (gpu util %, temp C, power W) + free (total, used, available MB)
# + ConnectX-7 RoCEv2 port_{rcv,xmit}_data counters (in 4-byte dwords).
_REMOTE = (
    "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw "
    "--format=csv,noheader,nounits | head -1; "
    "free -m | awk '/^Mem:/{print $2, $3, $7}'; "
    "awk '{s+=$1} END{printf \"ROCE %d\\n\", s+0}' "
    "/sys/class/infiniband/roce*/ports/1/counters/port_rcv_data "
    "/sys/class/infiniband/roce*/ports/1/counters/port_xmit_data 2>/dev/null || echo 'ROCE 0'"
)

_cache: dict[int, dict] = {}
_cache_ts = 0.0
_prev_roce: dict[int, tuple[float, int]] = {}  # node -> (timestamp, bytes)
_TTL = 1.0  # seconds


async def _probe(node: int, host: str) -> dict:
    try:
        proc = await asyncio.create_subprocess_exec(
            "ssh", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=no",
            f"{SSH_USER}@{host}", _REMOTE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
        now = time.time()
        lines = [l.strip() for l in out.decode().splitlines() if l.strip()]
        gpu = temp = power = 0.0
        mem_total = mem_used = mem_avail = 0
        roce_dwords = 0
        for l in lines:
            if l.startswith("ROCE "):
                try:
                    roce_dwords = int(l.split()[1])
                except (IndexError, ValueError):
                    roce_dwords = 0
            elif "," in l:  # nvidia-smi line
                parts = [p.strip() for p in l.split(",")]
                gpu = _num(parts[0])
                temp = _num(parts[1]) if len(parts) > 1 else 0
                power = _num(parts[2]) if len(parts) > 2 else 0
            elif len(l.split()) in (2, 3):  # free line: total used [available]
                parts = l.split()
                mem_total, mem_used = int(parts[0]), int(parts[1])
                mem_avail = int(parts[2]) if len(parts) > 2 else max(0, mem_total - mem_used)
        if not mem_total:
            return {"node": node, "ok": False}
        # Infiniband port_rcv_data / port_xmit_data counters are in 32-bit words (4 bytes each).
        roce_bytes = roce_dwords * 4
        roce_mbps = 0.0
        if node in _prev_roce and roce_bytes >= _prev_roce[node][1]:
            dt = max(now - _prev_roce[node][0], 0.2)
            roce_mbps = round((roce_bytes - _prev_roce[node][1]) / dt / 1e6, 1)  # MB/s
        _prev_roce[node] = (now, roce_bytes)

        return {
            "node": node,
            "ok": True,
            "gpu": gpu,
            "temp": temp,
            "power": round(power, 1),
            "mem_used_gb": round(mem_used / 1024, 1),
            "mem_avail_gb": round(mem_avail / 1024, 1),
            "mem_total_gb": round(mem_total / 1024, 1),
            "mem_pct": round(100 * mem_used / mem_total) if mem_total else 0,
            "roce_mb_s": roce_mbps,
            "roce_total_gb": round(roce_bytes / 1e9, 2),
        }
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
