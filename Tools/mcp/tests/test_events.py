import asyncio
import json
import pytest
import websockets
from icube_debug.events import collect_events


async def fake(ws):
    for i in range(3):
        await ws.send(json.dumps({"t": i, "kind": "perf.sample" if i else "core.state"}))
        await asyncio.sleep(0.05)
    await asyncio.sleep(5)


async def test_collects_filtered_events_within_window():
    async with websockets.serve(fake, "127.0.0.1", 0) as srv:
        port = srv.sockets[0].getsockname()[1]
        events = await collect_events(f"127.0.0.1:{port}", ["perf.sample"], seconds=0.5)
    assert [e["kind"] for e in events] == ["perf.sample", "perf.sample"]
