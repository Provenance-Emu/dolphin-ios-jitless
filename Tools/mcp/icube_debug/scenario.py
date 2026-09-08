"""Scenario definitions, device/upstream comparison, and settings bisection.

A `Scenario` describes what to do on the device (which game, how many frames
to advance, and any device-side settings overrides to apply first) in order
to capture a screenshot that can be compared against an upstream Dolphin
oracle frame (see `oracle.dump_frames`).

Controller ruling (Task 13 review): comparisons must be rasterized at the
same resolution on both sides. The oracle already forces 1x internal
resolution (see oracle.py); `run_on_device` mirrors that by pinning the
device's `gfxEfbScale` setting to 1 for the duration of the scenario and
restoring whatever value it had beforehand. `gfxEfbScale` is a DEVICE
settings key (from DOLSettingsKeyBridge), not a Dolphin -C/INI path -- it is
unrelated to the oracle's `Graphics.Settings.InternalResolution` key.
"""
from __future__ import annotations
import json, time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable
from .config import Config
from .imagediff import compare
from .oracle import dump_frames, OracleError

# Device settings key (DOLSettingsKeyBridge camelCase name) used to pin/restore
# the device's internal rendering resolution around a scenario run. This is a
# different namespace than the oracle's `Graphics.Settings.*` -C keys.
_EFB_SCALE_KEY = "gfxEfbScale"

# POST /api/debug/frame-advance caps `n` at 600 per call (DebugAPIRoutes.swift:
# `guard let n = asJSONInt(dict["n"]), (1...600).contains(n)`). run_on_device
# splits any larger request into multiple posts of at most this many frames.
_MAX_FRAME_ADVANCE_PER_CALL = 600


@dataclass
class Scenario:
    game_id: str
    # Presented frames after the pause point; must be >= 1 because the capture
    # itself presents the last frame (see run_on_device).
    frames: int
    start: str = "boot"
    # Device settings keys (e.g. "gfxHackFastMath"), applied via
    # POST /api/settings/<key> before the scenario runs. Never translated.
    settings_overrides: dict = field(default_factory=dict)
    # Oracle -C overrides (e.g. "Graphics.Settings.*" / "Dolphin.Core.*"),
    # passed through to oracle.dump_frames verbatim. Controller ruling (Task
    # 13 review): device settings keys are NOT auto-translated into these --
    # a scenario that wants a non-default oracle run must say so explicitly.
    oracle_overrides: dict = field(default_factory=dict)


def _pin_resolution(dev, warnings: list[str] | None) -> tuple[bool, object]:
    """Read the device's current gfxEfbScale and pin it to 1x.

    Returns (had_key, previous_value). If the key is absent from
    GET /api/settings, no post is made and a warning is recorded (if a
    warnings list was supplied) instead of failing the scenario.
    """
    settings = dev.get("/api/settings")
    if _EFB_SCALE_KEY not in settings:
        if warnings is not None:
            warnings.append(
                f"{_EFB_SCALE_KEY} not present in device settings; "
                "skipping resolution pin/restore"
            )
        return False, None
    prev = settings[_EFB_SCALE_KEY]["value"]
    dev.post(f"/api/settings/{_EFB_SCALE_KEY}", {"value": 1})
    return True, prev


def _restore_resolution(dev, had_key: bool, prev_value: object) -> None:
    if had_key:
        dev.post(f"/api/settings/{_EFB_SCALE_KEY}", {"value": prev_value})


def run_on_device(
    dev,
    sc: Scenario,
    boot: Callable[[str], None],
    warnings: list[str] | None = None,
) -> bytes:
    had_key, prev_value = _pin_resolution(dev, warnings)
    try:
        for k, v in sc.settings_overrides.items():
            dev.post(f"/api/settings/{k}", {"value": v})
        if sc.start == "boot":
            boot(sc.game_id)
        else:
            raise NotImplementedError("state-based scenarios need the STATE_VERSION shim (spec follow-up)")
        dev.post("/api/debug/pause")
        # A paused core never presents, so GET /api/debug/screenshot itself
        # steps one presented frame to land the capture (DOLDebugBridge.mm).
        # Advance frames-1 and let the screenshot present frame `frames`.
        remaining = sc.frames - 1
        while remaining > 0:
            n = min(_MAX_FRAME_ADVANCE_PER_CALL, remaining)
            dev.post("/api/debug/frame-advance", {"n": n})
            remaining -= n
        return dev.get_bytes("/api/debug/screenshot")
    finally:
        # Controller ruling (Task 13 fix round 2): cleanup steps are
        # independent best-effort operations. If the restore POST fails, the
        # resume POST is still attempted (safe even if the scenario failed
        # before pause -- the route returns 409 → DeviceError → swallowed).
        try:
            _restore_resolution(dev, had_key, prev_value)
        except Exception as e:
            if warnings is not None:
                warnings.append(f"restore gfxEfbScale failed: {e}")
        try:
            dev.post("/api/debug/resume")
        except Exception as e:
            if warnings is not None:
                warnings.append(f"resume failed: {e}")


def append_run(cfg: Config, record: dict) -> None:
    cfg.home.mkdir(parents=True, exist_ok=True)
    with (cfg.home / "runs.jsonl").open("a") as f:
        f.write(json.dumps(record, allow_nan=False) + "\n")


def compare_with_upstream(dev, cfg: Config, sc: Scenario, boot, threshold=0.97, guard=0.995) -> dict:
    ts = time.strftime("%Y%m%d-%H%M%S")
    shots = cfg.home / "shots"; diffs = cfg.home / "diffs"; goldens = cfg.home / "goldens"
    for d in (shots, diffs, goldens): d.mkdir(parents=True, exist_ok=True)
    warnings: list[str] = []
    a = run_on_device(dev, sc, boot, warnings=warnings)
    b = run_on_device(dev, sc, boot, warnings=warnings)
    if compare(a, b).score < guard:
        rec = {"ts": ts, "scenario": asdict(sc), "verdict": "indeterminate", "score": None, "warnings": warnings}
        append_run(cfg, rec); return rec
    device_png = shots / f"{ts}-{sc.game_id}-device.png"; device_png.write_bytes(a)
    # Controller ruling (Task 13 review): device settings_overrides are NOT
    # translated into oracle -C keys. Only an explicit oracle_overrides dict
    # on the scenario is forwarded to the oracle; otherwise pass None.
    oracle_overrides = sc.oracle_overrides or None
    try:
        upstream_path = dump_frames(cfg, sc.game_id, sc.frames, overrides=oracle_overrides)
    except OracleError as e:
        # Controller ruling (Task 13 fix round 1): a failed oracle dump must
        # still leave a run record behind (the device screenshot was already
        # captured successfully) before the exception propagates.
        rec = {"ts": ts, "scenario": asdict(sc), "verdict": "error", "error": str(e),
               "device_png": str(device_png), "score": None, "warnings": warnings}
        append_run(cfg, rec)
        raise
    upstream_png = goldens / f"{ts}-{sc.game_id}-upstream.png"; upstream_png.write_bytes(Path(upstream_path).read_bytes())
    r = compare(a, upstream_png.read_bytes())
    diff_png = diffs / f"{ts}-{sc.game_id}-diff.png"; diff_png.write_bytes(r.diff_png)
    rec = {"ts": ts, "scenario": asdict(sc), "score": r.score, "tile_scores": r.tile_scores,
           "verdict": "pass" if r.score >= threshold else "fail",
           "device_png": str(device_png), "upstream_png": str(upstream_png), "diff_png": str(diff_png),
           "warnings": warnings}
    append_run(cfg, rec)
    return rec


def bisect_settings(dev, sc: Scenario, keys: list[str], boot, upstream_png: bytes) -> list[dict]:
    # Note (Task 13 fix round 1): the brief's original signature carried an
    # unused `cfg: Config` parameter. Nothing in this package or the rest of
    # the tree references it (Task 14's server.py does not exist yet), so it
    # was dropped here -- follow up in Task 14 to pass `dev, sc, keys, boot,
    # upstream_png` (no `cfg`) when wiring this into server.py.
    all_settings = dev.get("/api/settings")
    baseline = {k: v["value"] for k, v in all_settings.items() if k in keys}
    results = []
    for key in keys:
        if key not in baseline:
            results.append({"key": key, "note": "unknown key", "score": None})
            continue
        cur = baseline[key]
        flipped = (not cur) if isinstance(cur, bool) else cur
        if flipped == cur:
            results.append({"key": key, "from": cur, "to": cur, "score": None, "note": "non-boolean, skipped", "warnings": []}); continue
        dev.post(f"/api/settings/{key}", {"value": flipped})
        warnings: list[str] = []
        try:
            png = run_on_device(dev, sc, boot, warnings=warnings)
            results.append({"key": key, "from": cur, "to": flipped, "score": compare(png, upstream_png).score, "warnings": warnings})
        finally:
            # Mirror run_on_device's cleanup style: the restore POST is
            # best-effort -- if it fails, record a warning on this key's
            # result rather than letting the restore failure mask whatever
            # happened above (or propagate and skip remaining keys).
            try:
                dev.post(f"/api/settings/{key}", {"value": cur})
            except Exception as e:
                warnings.append(f"restore {key} failed: {e}")
    return results
