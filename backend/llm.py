"""OpenAI-compatible LLM client for the swarm's distributed models.

Each specialist can be served on its own endpoint (across 2 Sparks), so the
client takes a per-call base/model rather than a fixed one.
"""
import os
import httpx

DEFAULT_BASE = os.environ.get("SWARM_VLLM_BASE", "http://localhost:8001/v1")
DEFAULT_MODEL = os.environ.get("SWARM_MODEL", "nemotron-lightning")


class LLMClient:
    def __init__(self, base: str = DEFAULT_BASE, model: str = DEFAULT_MODEL):
        self.base = base.rstrip("/")
        self.model = model

    async def chat(self, messages: list[dict], max_tokens: int = 3000,
                   temperature: float = 0.4, timeout: float = 120.0,
                   base: str | None = None, model: str | None = None) -> dict:
        """Chat completion. `base`/`model` override the defaults per call so a
        specialist can hit its own model endpoint on either Spark."""
        url = (base or self.base).rstrip("/")
        payload = {"model": model or self.model, "messages": messages,
                   "max_tokens": max_tokens, "temperature": temperature}
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(f"{url}/chat/completions", json=payload)
            r.raise_for_status()
            d = r.json()
        choice = d["choices"][0]
        msg = choice["message"]
        return {
            "content": (msg.get("content") or "").strip(),
            "reasoning": (msg.get("reasoning_content") or "").strip(),
            "finish": choice.get("finish_reason"),
        }

    async def health(self, base: str | None = None) -> bool:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(f"{(base or self.base).rstrip('/')}/models")
                return r.status_code == 200
        except Exception:
            return False
