# icube-debug MCP

A FastMCP server that drives a running iCube (Provenance's Dolphin fork)
build over its on-device debug API: settings, save states, frame stepping,
screenshots, logs, live events, and comparison against upstream Dolphin.

Full HTTP/WebSocket route reference: `docs/dev/debug-api.md` in the repo
root. This package (`icube_debug`) is a thin MCP wrapper around that API —
read the route doc for exact request/response shapes, status codes, and the
`/ws/events` message schema.

## Setup

The debug API is loopback-only on the device (port 8723), so reaching it
from a Mac needs a USB port-forward:

```bash
brew install libimobiledevice   # provides `iproxy`
iproxy 8723 8723                # leave running in its own terminal
```

Install this package's dependencies with [uv](https://docs.astral.sh/uv/):

```bash
cd Tools/mcp
uv sync
```

(Equivalently, from `Source/iOS/App`: `make mcp-install`.)

## Registering with Claude Code

```bash
claude mcp add icube -- uv --directory /ABS/PATH/TO/Tools/mcp run icube-debug-mcp
```

Use an absolute path to `Tools/mcp` (Claude Code launches the server from
its own working directory, not this one). It speaks MCP over stdio and
blocks waiting for a client, so don't run it directly in a terminal you
plan to keep using.

`pyproject.toml` declares a console-script entry point
(`icube-debug-mcp = "icube_debug.server:main"`) and `[tool.uv] package =
true`, so `uv sync` installs it and `uv run icube-debug-mcp` works directly
(verified locally: prints the FastMCP startup banner then blocks on stdio).
The equivalent `uv run python -m icube_debug.server` form still works too
if you prefer it.

## Device settings keys vs. oracle keys — do not mix these up

The tools in this server read/write two entirely different key namespaces,
and neither is auto-translated into the other:

- **Device keys** — used by `settings_get`, `settings_set`, `settings_all`,
  `settings_reset`, and the `settings_overrides` dict on `run_scenario` /
  `compare_with_upstream`. These are the **camelCase** names from
  `GET /api/settings` (backed by `DOLSettingsKeyBridge` on-device), e.g.
  `gfxHackFastMath`, `gfxEfbScale`.
- **Oracle keys** — used internally when `compare_with_upstream` launches
  the upstream `/Applications/Dolphin.app` oracle for comparison. These are
  Dolphin's own `-C` INI-style keys: `<System>.<Section>.<Key>`, e.g.
  `Graphics.Settings.InternalResolution`, `Dolphin.Core.CPUCore`. A scenario
  only reaches the oracle with non-default settings if it sets an explicit
  `oracle_overrides` dict (not currently exposed as an MCP tool parameter —
  device-side `settings_overrides` alone never affects the oracle run).

If a comparison looks wrong because "the setting didn't apply on the
upstream side," this is almost always why: the override was a device key,
and the oracle doesn't know about device keys at all.

## `config.toml`

On first run, `~/.icube-debug/config.toml` is created with defaults:

```toml
[oracle]
dolphin_app = "/Applications/Dolphin.app"
cpu_core = 5   # CachedInterpreter, matches the phone

[games]
# SMNE01 = "/path/to/New Super Mario Bros. Wii.rvz"
```

Add an entry under `[games]` for every `game_id` you want to run
`compare_with_upstream` or `bisect_settings` against — the key is the
game's ID (as reported by `health`) and the value is the absolute path to a
local ISO/RVZ the upstream oracle can boot headless. `dolphin_app` and
`cpu_core` control how that oracle run is launched; leave `cpu_core` at `5`
(CachedInterpreter) unless you have a specific reason to diverge from the
on-device core.

## First session

A five-step loop for investigating a rendering difference:

1. `health` — confirm the device is reachable and see what game/build is
   currently running.
2. `render_state` — see what's *actually* active at runtime (backend,
   internal resolution, vertex loader, active hacks, whether VI-skip is
   currently in effect), alongside the *configured* CPU core, dual-core, and
   clock settings (`*_configured` fields — not verified against the running
   core; there's no cheap way to read which CPU core is actually in use).
3. `snapshot_save(name="before")` — capture every setting's current state.
4. `settings_set(key=..., value=...)` — make the change you want to test.
5. `snapshot_diff(a="before", b="after")` after a second snapshot, or
   `compare_with_upstream(game_id=..., frames=...)` to see whether the
   change moved the device's rendered frame closer to or further from
   upstream Dolphin.

`run_scenario`, `compare_with_upstream`, and `bisect_settings` all require
the game to already be **booted and paused at frame 0** on the device —
there is no MCP route to boot a game yet (`POST /api/debug/boot` is a
follow-up; see the spec's recorded follow-ups). Boot and pause manually
first.

**`compare_with_upstream`'s determinism guard will usually say
"indeterminate" until `/api/debug/boot` exists.** It runs the scenario on
the device twice and compares the two screenshots before trusting a
device-vs-upstream comparison; without a boot route, the second run can't
restart from the same frame-0 origin as the first (it starts from wherever
the first run left the core), so the two device runs frequently disagree
and the guard reports `indeterminate` rather than `pass`/`fail`. This is
expected today, not a bug — re-boot and re-pause the game by hand between
investigations if you need a clean comparison.

## Manual smoke test (needs a real device)

Not run by CI or by any automated task — this requires a physical device on
`iproxy 8723 8723` with a debug-enabled build already booted into a game:

```bash
cd Tools/mcp
uv run python -m icube_debug.smoke
```

or, from `Source/iOS/App`:

```bash
make mcp-smoke
```

Expected output: a `health` JSON blob, a snapshot list containing `smoke`,
10 frames advanced, and a non-zero screenshot byte count.

## Running the test suite

```bash
cd Tools/mcp
uv run pytest -q
```

or `make mcp-test` from `Source/iOS/App`.
