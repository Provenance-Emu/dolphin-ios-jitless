"""FastMCP server exposing the iCube debug API as MCP tools.

Route reference: `docs/dev/debug-api.md` in the main repo. All routes are
loopback-only (127.0.0.1:8723 on-device); reach them from a Mac via
`iproxy 8723 8723` (see the README).

Key namespaces (do not confuse these -- see `compare_with_upstream` below):
- `settings_get`/`settings_set`/`settings_all`/`settings_reset` and the
  `settings_overrides` dict on `run_scenario`/`compare_with_upstream` take
  DEVICE settings keys: the camelCase names from `GET /api/settings`
  (`DOLSettingsKeyBridge`), e.g. `gfxHackFastMath`, `gfxEfbScale`.
- The oracle (upstream Dolphin.app, used by `compare_with_upstream`) is
  configured with Dolphin's own `-C` INI-style keys instead:
  `Graphics.Settings.*` / `Dolphin.Core.*`, e.g.
  `Graphics.Settings.InternalResolution`, `Dolphin.Core.CPUCore`. These are
  never auto-translated from device keys -- a scenario that wants a
  non-default oracle run must set `oracle_overrides` explicitly.

Booting via the API is a follow-up (`POST /api/debug/boot` -- needs an
`EmulationCoordinator` library lookup). Until then, `run_scenario`,
`compare_with_upstream`, and `bisect_settings` all assume the game is
already booted and paused at frame 0 on the device; they pass a no-op
`boot` callback into the scenario helpers.
"""
from __future__ import annotations
import asyncio, time
from pathlib import Path
from fastmcp import FastMCP
from fastmcp.utilities.types import Image
from .config import load_config
from .device import Device
from .events import collect_events
from .scenario import Scenario, run_on_device, compare_with_upstream as _compare, bisect_settings as _bisect

mcp = FastMCP("icube", instructions=(
    "Drive an iCube device over its debug API (port 8723 via `iproxy 8723 8723`). "
    "Read render_state to learn what is actually running, not just configured. "
    "run_scenario, compare_with_upstream, and bisect_settings all require the "
    "game to already be booted and paused at frame 0 on the device -- there is "
    "no MCP boot route yet."))


def _device(base: str) -> Device:
    return Device(base)


@mcp.tool()
def health(device: str = "127.0.0.1:8723") -> dict:
    """Build, game, core state and fps."""
    return _device(device).get("/api/health")


@mcp.tool()
def settings_get(key: str, device: str = "127.0.0.1:8723") -> dict:
    """One setting with its metadata. `key` is a DEVICE key (camelCase, from GET /api/settings), e.g. gfxHackFastMath."""
    return _device(device).get("/api/settings").get(key, {"error": f"unknown key {key}"})


@mcp.tool()
def settings_set(key: str, value: bool | int | float | str, device: str = "127.0.0.1:8723") -> dict:
    """Set a setting; reply says whether it applied live or needs a reboot. `key` is a DEVICE key (camelCase, from GET /api/settings)."""
    return _device(device).post(f"/api/settings/{key}", {"value": value})


@mcp.tool()
def settings_all(device: str = "127.0.0.1:8723") -> dict:
    """Every key with resolved value and per-layer values."""
    return _device(device).get("/api/settings/all")


@mcp.tool()
def settings_reset(keys: list[str] | None = None, device: str = "127.0.0.1:8723") -> dict:
    """Delete keys (or all) from Base/PerGame/CurrentRun layers."""
    return _device(device).post("/api/settings/reset", {"keys": keys or []})


@mcp.tool()
def snapshot_save(name: str, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/settings/snapshots", {"name": name})


@mcp.tool()
def snapshot_list(device: str = "127.0.0.1:8723") -> list:
    return _device(device).get("/api/settings/snapshots")


@mcp.tool()
def snapshot_diff(a: str, b: str, device: str = "127.0.0.1:8723") -> list:
    return _device(device).get(f"/api/settings/snapshots/{a}/diff/{b}")


@mcp.tool()
def pause(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/pause")


@mcp.tool()
def resume(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/resume")


@mcp.tool()
def frame_advance(n: int = 1, device: str = "127.0.0.1:8723") -> dict:
    """Advance exactly n emulated frames; core must be paused."""
    return _device(device).post("/api/debug/frame-advance", {"n": n})


@mcp.tool()
def savestate(slot: int = 1, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/savestate", {"slot": slot})


@mcp.tool()
def loadstate(slot: int | None = None, path: str | None = None, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/loadstate", {"path": path} if path else {"slot": slot or 1})


@mcp.tool()
def screenshot(device: str = "127.0.0.1:8723") -> Image:
    """Current frame as PNG; also saved under ~/.icube-debug/shots/."""
    png = _device(device).get_bytes("/api/debug/screenshot")
    cfg = load_config(); shots = cfg.home / "shots"; shots.mkdir(parents=True, exist_ok=True)
    (shots / f"{time.strftime('%Y%m%d-%H%M%S')}.png").write_bytes(png)
    return Image(data=png, format="png")


@mcp.tool()
def render_state(device: str = "127.0.0.1:8723") -> dict:
    """Runtime truth: backend, CPU core in use, vertex loader, hacks, clocks."""
    return _device(device).get("/api/debug/render-state")


@mcp.tool()
def logs(tail: int = 200, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).get("/api/logs", tail=tail)


@mcp.tool()
def build_info(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).get("/api/debug/build-info")


@mcp.tool()
def watch_events(kinds: list[str] | None = None, seconds: int = 10, device: str = "127.0.0.1:8723") -> list:
    """Collect WebSocket events (settings.changed, perf.sample, log.line, core.state) for up to 120 s."""
    return asyncio.run(collect_events(device, kinds, min(seconds, 120)))


@mcp.tool()
def run_scenario(game_id: str, frames: int, settings_overrides: dict | None = None, device: str = "127.0.0.1:8723") -> Image:
    """Pause, advance `frames`, screenshot. `settings_overrides` are DEVICE keys
    (camelCase, e.g. gfxHackFastMath). The game must already be booted and
    paused at frame 0 on the device -- there is no MCP boot route yet."""
    png = run_on_device(_device(device), Scenario(game_id, frames, "boot", settings_overrides or {}), lambda g: None)
    return Image(data=png, format="png")


@mcp.tool()
def compare_with_upstream(game_id: str, frames: int, settings_overrides: dict | None = None, threshold: float = 0.97, device: str = "127.0.0.1:8723") -> dict:
    """Run the same scenario on the device and on /Applications/Dolphin.app (the
    upstream oracle); return SSIM score, verdict (pass/fail/indeterminate), and
    image paths. The game must already be booted and paused at frame 0 on the
    device -- there is no MCP boot route yet.

    `settings_overrides` are DEVICE keys (camelCase, from GET /api/settings,
    e.g. gfxHackFastMath) applied on the device before the run. They are
    NEVER translated into oracle settings -- the oracle always runs with its
    defaults (forced to 1x internal resolution to match the device) unless
    the scenario itself carries an explicit `oracle_overrides` dict of
    Dolphin `-C` keys (`Graphics.Settings.*` / `Dolphin.Core.*`), which this
    tool does not currently expose as a parameter."""
    return _compare(_device(device), load_config(), Scenario(game_id, frames, "boot", settings_overrides or {}), lambda g: None, threshold)


@mcp.tool()
def bisect_settings(game_id: str, frames: int, keys: list[str], upstream_png: str, device: str = "127.0.0.1:8723") -> list:
    """Flip each boolean DEVICE settings key (camelCase, e.g. gfxHackFastMath),
    re-run the scenario, and score the result against a saved upstream PNG
    file. The game must already be booted and paused at frame 0 on the
    device -- there is no MCP boot route yet."""
    return _bisect(_device(device), Scenario(game_id, frames), keys, lambda g: None, Path(upstream_png).read_bytes())


def main():
    mcp.run()


if __name__ == "__main__":
    main()
