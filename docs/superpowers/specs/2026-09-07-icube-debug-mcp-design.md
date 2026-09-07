# iCube Debug MCP — design

Date: 2026-09-07. Status: approved in brainstorm, awaiting implementation plan.

## Why

Two rendering regressions (NSMBW skinning, Rogue Squadron textures; iCube #5,
#6) survived a day of on-device A/B testing because every experiment needed a
human to change a setting, relaunch, look, and report. The one decisive
experiment of the day — upstream Dolphin 2509 on a Mac with the same CPU
engine renders correctly — was decisive precisely because a tool could drive
it and look at the result. This design gives a Claude Code session the same
reach into the phone: read and write settings, snapshot and diff them, step
frames, screenshot, stream events, and compare a scenario's frame against
upstream Dolphin on the Mac.

Decisions taken during the brainstorm, in order:

1. Primary consumer is Claude Code through MCP, not a dashboard or CLI.
2. The MCP server runs on the Mac; the phone speaks REST + WebSocket.
3. iFly and iCube share the API *contract* (paths, JSON shapes, event schema),
   not Swift code. One MCP server works against either app.
4. Bug detection is golden comparison first, an in-core geometry detector
   second.
5. Architecture A: thin MCP over the device API, no daemon. Designed so a
   daemon (multi-device, event history) can wrap it later.

## Topology

```
Claude Code ──stdio──▶ Tools/mcp/icube_debug (Python, FastMCP)
                              │ HTTP + WebSocket, 127.0.0.1:8723
                              │ (iproxy 8723 8723 over USB)
                              ▼
                 iCube NativeWebServer (Swift, on device)
                              │
                              ▼
                 Dolphin core (Config, Core, State, screenshots)

Tools/mcp/icube_debug ──subprocess──▶ /Applications/Dolphin.app (oracle)
```

- Device server: the existing `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift`
  on port 8723. DEBUG builds: always on. Release: only behind the existing
  opt-in toggle. Loopback-only remains; no auth in v1.
- Mac: `Tools/mcp/icube_debug/` in this repo. Python 3.12, `fastmcp`, `httpx`,
  `websockets`, `pillow`, `scikit-image` (SSIM). Registered in Claude Code as
  server name `icube`. Stdio transport. No background process: each tool call
  is a request; streaming tools open the WebSocket for a bounded window.
- State on the Mac: `~/.icube-debug/` — `config.toml`, `shots/`, `snapshots/`,
  `goldens/`, `diffs/`, `runs.jsonl`.

## Device API

All responses use the iFly envelope: `{"ok": true, "data": ...}` or
`{"ok": false, "error": "..."}` with an HTTP 4xx/5xx status on failure. Paths
and shapes follow iFly's `docs/dev/debug-api.md` where a route exists there;
new routes are added to both apps' docs with the same shape.

Existing in iCube (unchanged): `GET /api/settings`, `POST /api/settings/{key}`,
`GET /api/perf/live`, `/api/bench/*`, `/api/savestates`.

Added:

| Route | Behaviour |
|---|---|
| `GET /api/health` | `{build_sha, config, game_id, core_state, fps, vps}` |
| `GET /api/settings/all` | every key, every layer, with the resolved value and the layer it came from |
| `GET /api/settings/pergame` | the per-game layer only |
| `POST /api/settings/reset` | `{"keys":[...]}` or empty for all; deletes from Base+CurrentRun |
| `GET /api/settings/snapshots` | list `{name, taken_at, game_id}` |
| `POST /api/settings/snapshots` | `{"name"}` → capture `settings/all` to `Documents/DebugSnapshots/<name>.json` |
| `GET /api/settings/snapshots/{a}/diff/{b}` | keys whose resolved value differs, with both values |
| `POST /api/debug/pause`, `/resume` | `Core::SetState` |
| `POST /api/debug/frame-advance` | `{"n": N}`; runs `Core::DoFrameStep` N times, waiting for `Core::State::Paused` after each; returns `{frames_advanced, frame_count}` |
| `GET /api/debug/frame-count` | emulated frame counter |
| `POST /api/debug/savestate`, `/loadstate` | `{"slot": n}` or `{"path": ...}`; loadstate returns after the state is applied |
| `GET /api/debug/screenshot` | `Core::SaveScreenShot` → `image/png` bytes (not a path) |
| `GET /api/debug/build-info` | sha, branch, xcframework build stamp, Xcode, flags file hash |
| `GET /api/logs?tail=N` | last N lines of the Dolphin log ring |
| `GET /api/debug/render-state` | **runtime** truth: backend, internal resolution, active hacks, vertex loader type actually selected, CPU core actually running, dual core, VI skip decision, adaptive clock state |

`render-state` exists because this session found several places where the
configured value and the runtime value differ (vertex loader override, CPU core
fallback, VI skip resolver). Tools must be able to read what is *running*.

### Frame stepping

`frame-advance` is the foundation of every scenario and must be deterministic:
- Refuse (`409`) unless the core is Paused.
- Step with `Core::DoFrameStep`; wait on the `Core::State` callback, not a
  sleep; time out at 5 s per frame with `504`.
- Return the emulated frame counter so callers can verify N.

## WebSocket

`GET /ws/events` on port 8723, RFC 6455 upgrade implemented in
`NativeWebServer` (text frames, no extensions, no compression, ping/pong).
One JSON object per message:

```
{"t": <unix ms>, "kind": "settings.changed", "key": "...", "old": ..., "new": ..., "layer": "Base"}
{"t": ..., "kind": "perf.sample", "fps": 59.9, "vps": 60.0, "frame_ms": 16.4}   // 1 Hz
{"t": ..., "kind": "log.line", "level": "WARN", "msg": "..."}                    // WARN and above
{"t": ..., "kind": "core.state", "state": "running" | "paused" | "stopped"}
{"t": ..., "kind": "detect.geometry", ...}                                        // phase 2
```

A single `DebugEventBus` (Swift, actor) fans out to connected sockets. Producers:
the Config change callback, `PerformanceMetrics`, the log listener, and the
core state callback. No history on the device; a client that wants history
records it (the future daemon).

## MCP tools

Every tool takes optional `device: str = "127.0.0.1:8723"`.

Mirror tools (one route each): `health`, `settings_get(key)`, `settings_set(key, value)`,
`settings_all`, `settings_reset(keys)`, `snapshot_save(name)`, `snapshot_list`,
`snapshot_diff(a, b)`, `pause`, `resume`, `frame_advance(n)`, `savestate(slot|path)`,
`loadstate(slot|path)`, `screenshot` (returns the image to the session and
writes `~/.icube-debug/shots/<ts>.png`), `render_state`, `logs(tail)`, `build_info`.

Streaming: `watch_events(kinds: list[str], seconds: int ≤ 120)` — opens the
WebSocket, collects matching events for the window, closes, returns them.

Composite:
- `run_scenario(scenario) -> {device_png, frame_count, render_state}`:
  pause → start (`boot` = stop + boot the game; `state` = loadstate) → advance
  N → screenshot.
- `compare_with_upstream(scenario) -> {score, diff_png, device_png, upstream_png, verdict}`:
  runs the scenario on the device, then on `/Applications/Dolphin.app`
  (`-b -e <iso> -C Dolphin.Core.CPUCore=<core> -C Dolphin.Core.CPUThread=False
  -C Dolphin.Movie.DumpFrames=True -C Dolphin.Movie.DumpFramesSilent=True`,
  frame dump to a temp dir, take frame N, kill), then diffs: SSIM on the
  common resolution plus a per-tile heatmap. `verdict` is `pass` if
  `score ≥ threshold` (default 0.97), `fail` otherwise, `indeterminate` if the
  determinism guard failed.
- `bisect_settings(scenario, keys: list[str]) -> [{key, from, to, score}]`:
  for each key, flip it (bool) or step it (enum), re-run the device scenario,
  score against the cached upstream frame, restore.

Oracle configuration in `~/.icube-debug/config.toml`:

```toml
[oracle]
dolphin_app = "/Applications/Dolphin.app"
cpu_core = 5            # CachedInterpreter, to match the phone
[games]
SMNE01 = "/path/New Super Mario Bros. Wii (USA).rvz"
GSWE64 = "/path/Star Wars - Rogue Squadron II.ciso"
```

## Golden pipeline

Scenario:

```json
{"game_id": "SMNE01", "start": "boot", "frames": 900,
 "settings_overrides": {"GFX.Hacks.FastMath": false}}
```

- `start: "boot"` — power-on with no input; deterministic on both sides.
  This is v1.
- `start: {"state": path}` — needs a load-compat shim: iCube's `STATE_VERSION`
  is 176 (VISkip state added to `VideoInterface::DoState`) while upstream 2509
  is 175, so upstream states are rejected today. The shim accepts 175 and
  reads the VISkip field only when the loaded version is ≥ 176. Follow-up,
  not v1.
- Determinism guard: `compare_with_upstream` runs the device scenario twice
  and refuses to score (`indeterminate`) if the two device frames differ by
  more than the noise threshold (SSIM < 0.995).
- Every run appends `{ts, build_sha, scenario, score, verdict, paths}` to
  `runs.jsonl` so a regression across builds is one `grep`.

Known limitation: the oracle is upstream 2509 with the macOS Metal backend.
A failing verdict means "differs from upstream on Apple Silicon", which is the
question we have; it cannot distinguish an iCube code bug from an iOS
GPU-family difference. That split is the next experiment (a macOS DolphinQt
built from the iCube tree), out of scope here.

## Detector (phase 2)

Behind `GFX_DEBUG_GEOMETRY_SENTINEL` (default off; the MCP enables it via
`settings_set`). In `VertexManagerBase::Flush`, after vertex upload: sample
≤ 64 vertices of the draw, compute post-transform positions with the current
XF matrices on the CPU, flag NaN/inf or any vertex farther than `K` (default
8) × the draw's median radius from its centroid, or a draw whose radius grew
> 4× versus the previous frame's draw with the same vertex-format+texture key.
On flag: emit `detect.geometry {draw_index, vertex_format, posmtx_indices,
tex_hashes, radius, median_radius}` on the bus and request a screenshot. Rate
limited to one event per draw key per second. Texture-side detection is
deferred until golden compare shows what the Rogue Squadron failure looks
like numerically.

## Errors

- Device routes: `{"ok": false, "error"}` + status. `409` when the core is in
  the wrong state (e.g. frame-advance while running), `404` unknown key/route,
  `504` step timeout.
- MCP tools surface the device error text verbatim and never retry
  state-changing calls.
- `compare_with_upstream` fails fast with a clear message when the ISO is not
  mapped, Dolphin.app is missing, or the frame dump produced fewer than N
  frames.

## Testing

- Swift `XCTest`: WebSocket handshake + framing (masking, fragmentation,
  ping/pong), snapshot diff, `frame-advance` state machine with a fake core.
- Python `pytest`: every tool against a recorded-response fake device
  (`respx`); image diff against fixture pairs (identical, shifted, corrupted).
- `make mcp-smoke`: live test needing a device on `iproxy` — health,
  snapshot round-trip, 10-frame advance, screenshot.
- CI: the Swift tests run in the existing `build.yml`; the Python tests run in
  a small `ubuntu-latest` job. `build.yml` gets `paths-ignore` for `docs/**`
  and `Tools/mcp/**` so doc and tool changes stop triggering 90-minute core
  builds.

## Out of scope

Dashboard UI, multi-device daemon, auth, Wi-Fi access, MCP served from the
device, the `STATE_VERSION` compat shim, texture detector, iFly changes
(iFly already has most of this surface; it only needs the new routes and the
event schema, tracked separately).

## Files

- `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift` — WebSocket upgrade.
- `Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift` — new routes.
- `Source/iOS/App/Common/Swift/Debug/DebugEventBus.swift` — new.
- `Source/iOS/App/Common/Swift/Debug/SettingsSnapshots.swift` — new.
- `Source/iOS/App/Common/Bridging/DOLDebugBridge.mm|h` — new: frame step,
  screenshot bytes, render-state, log tail.
- `Tools/mcp/icube_debug/{server.py, device.py, oracle.py, imagediff.py, config.py}`,
  `Tools/mcp/pyproject.toml`, `Tools/mcp/README.md`.
- `docs/dev/debug-api.md` — new, mirrors iFly's.
- `.github/workflows/build.yml` — `paths-ignore`.
