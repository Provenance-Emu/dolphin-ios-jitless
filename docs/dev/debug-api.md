# iCube Debug API

A loopback-only HTTP + WebSocket API for driving and inspecting a running
iCube build: settings, save states, frame stepping, screenshots, perf, and a
live event stream. Backing implementation:

- `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift` — HTTP/WebSocket server
- `Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift` — route registration
- `Source/iOS/App/Common/Swift/Debug/DebugEventBus.swift` — `/ws/events` fan-out
- `Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift` — lifecycle/gating
- `Source/iOS/App/Common/Swift/Debug/SettingsSnapshots.swift` — named settings snapshots
- `Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.h` — string-keyed settings facade
- `Source/iOS/App/Common/Bridging/DOLDebugBridge.h` — core state / frame-step / screenshot bridge
- `Source/iOS/App/Common/Bridging/DOLPerfBridge.h` — perf counters bridge

## Server facts

- **Port:** `8723`, bound to `127.0.0.1` only (loopback-only by design — this
  is the App Store review-safety property; it must never change).
- **Reaching it from a Mac:** `brew install libimobiledevice`, then
  `iproxy 8723 8723` forwards the device's loopback port 8723 to the Mac's
  own port 8723 over USB.
- **Availability:** DEBUG builds always start the server. Release builds
  start it only when the user has opted in via the `ICubeBenchServerEnabled`
  `UserDefaults` key (the "Perf Test Bench (HTTP)" toggle in Settings), which
  defaults to **off**. With the toggle off — the default for every shipping
  install — nothing binds.
- No authentication in v1; safety comes entirely from loopback-only + the
  opt-in gate.

## Envelope and errors

Every JSON route responds with one of:

```json
{"ok": true, "data": ...}
{"ok": false, "error": "..."}
```

(`GET /api/debug/screenshot` is the one exception — it returns raw
`image/png` bytes, not the envelope, on success.)

An `ok: false` response carries an HTTP status code:

| Status | Meaning | Example |
|---|---|---|
| `400` | Bad request — missing/non-JSON-object body, wrong field type, value out of range, or (implicit default, see below) any other `ok:false` route that does not set a status | frame-advance body isn't `{"n": <1...600>}` |
| `404` | Unknown key, unknown route, or unknown snapshot name | `POST /api/settings/reset` with an unknown key in `"keys"`; `GET /api/settings/snapshots/{a}/diff/{b}` when `a` or `b` doesn't exist |
| `409` | Core is in the wrong state for the request | `pause`/`resume`/`savestate`/`loadstate` when the core isn't running; `frame-advance` when the core isn't paused |
| `500` | Handler error — the route's handler returned invalid JSON | snapshot write failure |
| `504` | The operation didn't complete before its timeout | `frame-advance` didn't reach `n` frames within 5s/frame; `screenshot` wasn't produced within 3s |

Routes that return `["ok": false, "error": ...]` **without** an explicit
status (e.g. `POST /api/settings/<key>` for an unknown key, `POST
/api/bench/sweep` for a missing `key`/`values`) fall back to the server's
default of **400**.

**Note:** An unmatched HTTP route returns plain-text `404 Not Found` (Content-Type: `text/plain`),
not the JSON envelope. Only routes that exist (i.e. match the path) return the JSON `{"ok": false, "error": ...}` 
envelope with the status codes above.

## Settings routes

| Method | Path | Body | Response `data` |
|---|---|---|---|
| `GET` | `/api/settings` | — | every known key → its resolved value + metadata (`value`, `type`, `hotSwappable`) |
| `GET` | `/api/settings/all` | — | every known key → `{value, layer, layers: {Base, GlobalGame, PerGame, CurrentRun}}` (see below) |
| `GET` | `/api/settings/pergame` | — | only keys that have an explicit **PerGame** (Local GameINI) override: key → that layer's raw value |
| `POST` | `/api/settings/<key>` | `{"value": ...}` | `{key, value, hotSwappable, note}`; `note` says whether the change applied live or needs a reboot/state reload; `value` is echoed as a string regardless of the request type |
| `POST` | `/api/settings/reset` | `{"keys": [...]}`, optional (empty/missing resets **all** known keys) | `{reset: [...] \| "all"}` |
| `GET` | `/api/settings/snapshots` | — | `[{name, taken_at, game_id}, ...]` |
| `POST` | `/api/settings/snapshots` | `{"name": "..."}` | `{name}` — captures every known key's current per-layer state under `name` |
| `GET` | `/api/settings/snapshots/<a>/diff/<b>` | — | `[{key, a, b}, ...]` — keys whose resolved value differs between the two named snapshots |

### `/api/settings/all` per-key shape

Each entry is:

```json
{
  "value": ...,
  "layer": "Base" | "GlobalGame" | "PerGame" | "CurrentRun" | "Default",
  "layers": {
    "Base": ...,
    "GlobalGame": ...,
    "PerGame": ...,
    "CurrentRun": ...
  }
}
```

`value`/`layer` are the resolved (winning) value and the layer it came from,
by precedence `CurrentRun > PerGame > GlobalGame > Base`. `layer` is
`"Default"` when none of the four tracked layers has an explicit entry (the
resolved value came from the key's compiled-in default, or from an untracked
layer such as Netplay/Movie/CommandLine). `layers` holds each layer's own raw
value; a layer is omitted entirely when it has no explicit entry for that
key. `"PerGame"` is the user-editable Local GameSettings INI layer;
`"GlobalGame"` is the bundled read-only `Sys/GameSettings/<id>.ini` layer.

## Save states

| Method | Path | Body | Response `data` |
|---|---|---|---|
| `GET` | `/api/savestates` | — | `[{name, size, modified, slot?}, ...]` — entries in the StateSaves directory (slot files `*.sNN` plus `lastState.sav`) |
| `POST` | `/api/debug/savestate` | `{"slot": N}`, optional (defaults to `1`) | `{slot}`; `409` if the core isn't running |
| `POST` | `/api/debug/loadstate` | `{"slot": N}` or `{"path": "..."}`, at least one required; `path` takes priority when both are present | `{state}` (the resulting core state); `409` if the core isn't running or the state is missing |

## Debug control

| Method | Path | Body | Response `data` |
|---|---|---|---|
| `POST` | `/api/debug/pause` | — | `{state}`; `409` if the core isn't running |
| `POST` | `/api/debug/resume` | — | `{state}`; `409` if the core isn't running |
| `POST` | `/api/debug/frame-advance` | `{"n": N}`, required, integer `1...600` | `{frames_advanced, frame_count}`; `409` unless the core is already paused; `504` if fewer than `n` frames land within 5s/frame |
| `GET` | `/api/debug/frame-count` | — | `{frame_count}` — the emulated frame counter |
| `GET` | `/api/debug/screenshot` | — | **raw `image/png` bytes**, not the JSON envelope; `504` if no screenshot lands within 3s |
| `GET` | `/api/debug/build-info` | — | SCM revision/branch, app version/build, configuration |
| `GET` | `/api/debug/render-state` | — | mix of runtime and configured state, distinguished by field name. Runtime (actually observed): backend, internal resolution, active hacks, and `vi_skip_active` (from `Core::System::GetInstance().GetCoreTiming().GetVISkip()`). Configured (from `Config`, NOT verified against the running core — suffixed `_configured`): `cpu_core_configured`, `dual_core_configured`, `vi_skip_mode_configured`, `overclock_enable_configured`, `overclock_configured`, `vi_overclock_configured` |
| `GET` | `/api/health` | — | `{build_sha, config, game_id, core_state, fps, vps}` |
| `GET` | `/api/logs?tail=N` | — | `{lines: [...]}` — last `N` log lines (`N` defaults to `200`; must be a non-negative integer if given) |

## Perf and benchmark routes

| Method | Path | Body | Response `data` |
|---|---|---|---|
| `GET` | `/api/perf/live` | — | current `fps`, `vps`, `speed`, `maxSpeed`, `frameTimeMs`, `rawFrameTimeMs` |
| `POST` | `/api/bench/start` | `{"slot": N=1, "seconds": S=15}` | `{started, slot, seconds}` — kicks off an async benchmark run |
| `GET` | `/api/bench/result` | — | `{status: "running"}` \| `{status: "no-result"}` \| `{status: "done", result: {...}}` |
| `POST` | `/api/bench/sweep` | `{"key": K, "values": [...], "slot": N=1, "seconds": S=15}` | `{started, key, values, slot, seconds}` — runs a benchmark once per value |

## WebSocket: `/ws/events`

`GET /ws/events` upgrades to a WebSocket (RFC 6455, text frames only, no
extensions/compression). On attach, the socket immediately receives a
`core.state` snapshot (not broadcast to other sockets). Thereafter it
receives every event published to `DebugEventBus`. Every message is one JSON
object with `t` (unix ms) and `kind`:

```json
{"t": 1732999999000, "kind": "settings.changed", "key": "...", "old": ..., "new": ...}
{"t": 1732999999000, "kind": "perf.sample", "fps": 59.9, "vps": 60.0, "frame_ms": 16.4}
{"t": 1732999999000, "kind": "log.line", "level": "WARN", "msg": "..."}
{"t": 1732999999000, "kind": "core.state", "state": "uninitialized" | "starting" | "running" | "paused" | "stopping"}
```

- `settings.changed` — fired on every resolved-value change detected after a
  `Config` change callback; `old`/`new` are `null` when the key was
  previously/newly unset.
- `perf.sample` — emitted once per second while the core state is
  `"running"`.
- `log.line` — forwarded log lines (WARN and above).
- `core.state` — fired whenever the core's `Core::State` changes.

## Setup

```bash
brew install libimobiledevice
iproxy 8723 8723
curl http://127.0.0.1:8723/api/health
```
