"""Manual smoke check against a real device over the debug API.

Not run in CI and not run by this task's automation -- there is no device
attached in this environment. Requires `iproxy 8723 8723` (see README) and a
build with the debug server enabled, already booted into a game. Run with:

    uv run python -m icube_debug.smoke
"""
from .device import Device


def main():
    d = Device()
    print("health", d.get("/api/health"))
    d.post("/api/settings/snapshots", {"name": "smoke"})
    print("snapshots", d.get("/api/settings/snapshots"))
    d.post("/api/debug/pause")
    print("advance", d.post("/api/debug/frame-advance", {"n": 10}))
    print("screenshot bytes", len(d.get_bytes("/api/debug/screenshot")))
    d.post("/api/debug/resume")


if __name__ == "__main__":
    main()
