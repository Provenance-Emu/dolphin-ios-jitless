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


async def fake_server_closes(ws):
    """Send 2 events then close the connection."""
    await ws.send(json.dumps({"kind": "perf.sample", "data": 1}))
    await ws.send(json.dumps({"kind": "perf.sample", "data": 2}))
    # Connection closes here; no more sends


async def test_handles_server_close_mid_collection():
    """collect_events returns already-collected events when server closes."""
    async with websockets.serve(fake_server_closes, "127.0.0.1", 0) as srv:
        port = srv.sockets[0].getsockname()[1]
        events = await collect_events(f"127.0.0.1:{port}", ["perf.sample"], seconds=5.0)
    assert len(events) == 2
    assert [e["kind"] for e in events] == ["perf.sample", "perf.sample"]


async def fake_non_dict_json(ws):
    """Send non-dict JSON, then valid events."""
    await ws.send(json.dumps([1, 2]))  # List, not dict
    await ws.send(json.dumps(42))  # Number, not dict
    await ws.send(json.dumps("not json string"))  # String
    await ws.send(json.dumps({"kind": "perf.sample", "data": 1}))
    await ws.send(json.dumps("invalid"))  # Another string after valid
    await ws.send(json.dumps({"kind": "core.state", "data": 2}))
    await asyncio.sleep(5)


async def test_skips_non_dict_json_frames():
    """collect_events skips JSON that doesn't decode to a dict."""
    async with websockets.serve(fake_non_dict_json, "127.0.0.1", 0) as srv:
        port = srv.sockets[0].getsockname()[1]
        events = await collect_events(f"127.0.0.1:{port}", None, seconds=0.5)
    # Should only get the 2 dict events, not the arrays/numbers/strings
    assert len(events) == 2
    assert [e["kind"] for e in events] == ["perf.sample", "core.state"]
