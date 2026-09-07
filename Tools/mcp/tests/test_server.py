import icube_debug.server as srv

TOOL_NAMES = [
    "health", "settings_get", "settings_set", "settings_all", "settings_reset",
    "snapshot_save", "snapshot_list", "snapshot_diff", "pause", "resume",
    "frame_advance", "savestate", "loadstate", "screenshot", "render_state",
    "logs", "build_info", "watch_events", "run_scenario", "compare_with_upstream",
    "bisect_settings",
]


class FakeDevice:
    def get(self, path, **p): return {"path": path, **p}
    def post(self, path, body=None): return {"path": path, "body": body}
    def get_bytes(self, path): return b"\x89PNG"


def test_tools_route_to_device(monkeypatch):
    monkeypatch.setattr(srv, "_device", lambda base: FakeDevice())
    assert srv.health()["path"] == "/api/health"
    assert srv.frame_advance(n=7)["body"] == {"n": 7}
    assert srv.settings_set(key="gfxHackFastMath", value=False)["body"] == {"value": False}
    assert srv.logs(tail=5)["tail"] == 5


async def test_all_tools_registered():
    # Confirms every tool in the brief's list is actually registered on the
    # FastMCP server under its expected name (calling the plain module-level
    # function, as above, bypasses the FastMCP decorator entirely and would
    # not catch a missing/misnamed @mcp.tool()).
    for name in TOOL_NAMES:
        tool = await srv.mcp.get_tool(name)
        assert tool.fn is not None
