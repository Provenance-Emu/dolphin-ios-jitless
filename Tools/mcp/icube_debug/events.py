from __future__ import annotations
import asyncio
import json
import websockets


async def collect_events(base: str, kinds: list[str] | None, seconds: float) -> list[dict]:
    url = f"ws://{base}/ws/events"
    out: list[dict] = []
    loop = asyncio.get_running_loop()
    deadline = loop.time() + seconds
    async with websockets.connect(url, open_timeout=5) as ws:
        while (remaining := deadline - loop.time()) > 0:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if kinds is None or ev.get("kind") in kinds:
                out.append(ev)
    return out
