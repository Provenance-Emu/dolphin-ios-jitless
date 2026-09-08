import json
from pathlib import Path

import pytest

from icube_debug.scenario import Scenario, run_on_device, compare_with_upstream, bisect_settings
from icube_debug.config import Config
from icube_debug.device import DeviceError
from icube_debug.oracle import OracleError

class FakeDevice:
    def __init__(self, png, settings=None):
        self.png, self.calls = png, []
        self.settings = settings if settings is not None else {}

    def post(self, path, body=None):
        self.calls.append((path, body))
        return {"frames_advanced": (body or {}).get("n", 0)}

    def get(self, path, **p):
        if path == "/api/settings":
            return self.settings
        return {}

    def get_bytes(self, path): return self.png

def solid(color):
    from io import BytesIO; from PIL import Image
    b = BytesIO(); Image.new("RGB", (64, 48), color).save(b, "PNG"); return b.getvalue()

def test_run_on_device_pauses_advances_and_captures():
    d = FakeDevice(solid("red"))
    png = run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None)
    assert png == d.png
    # The screenshot route itself presents the last frame (a paused core never
    # presents), so a 30-frame scenario advances 29 and captures frame 30.
    assert ("/api/debug/pause", None) in d.calls and ("/api/debug/frame-advance", {"n": 29}) in d.calls

def test_run_on_device_single_frame_needs_no_advance():
    d = FakeDevice(solid("red"))
    run_on_device(d, Scenario("SMNE01", 1), boot=lambda g: None)
    assert not [b for path, b in d.calls if path == "/api/debug/frame-advance"]
    assert ("/api/debug/pause", None) in d.calls

def test_run_on_device_chunks_frame_advance_over_600():
    # POST /api/debug/frame-advance caps n at 600 per call (DebugAPIRoutes.swift).
    # A scenario asking for more frames than that must be split into multiple
    # posts of at most 600 frames each.
    d = FakeDevice(solid("red"))
    run_on_device(d, Scenario("SMNE01", 900), boot=lambda g: None)
    advance_calls = [body for path, body in d.calls if path == "/api/debug/frame-advance"]
    assert advance_calls == [{"n": 600}, {"n": 299}]

def test_run_on_device_pins_and_restores_resolution():
    # Controller ruling (Task 13 review): run_on_device must pin the device's
    # internal resolution (gfxEfbScale, a DEVICE key -- not an oracle -C key)
    # to 1x for the duration of the scenario and restore whatever value it
    # had beforehand, bracketing the pause/frame-advance sequence.
    d = FakeDevice(solid("red"), settings={"gfxEfbScale": {"value": 3}})
    run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None)
    set_idx = d.calls.index(("/api/settings/gfxEfbScale", {"value": 1}))
    advance_idx = d.calls.index(("/api/debug/frame-advance", {"n": 29}))
    restore_idx = d.calls.index(("/api/settings/gfxEfbScale", {"value": 3}))
    assert set_idx < advance_idx < restore_idx

def test_run_on_device_skips_resolution_pin_when_key_absent():
    # When the device doesn't report gfxEfbScale at all, skip the pin/restore
    # posts entirely and record a warning instead of failing.
    d = FakeDevice(solid("red"))
    warnings: list[str] = []
    run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None, warnings=warnings)
    assert not any(path == "/api/settings/gfxEfbScale" for path, _ in d.calls)
    assert warnings and "gfxEfbScale" in warnings[0]

def test_run_on_device_restores_on_exception():
    # Controller ruling (Task 13 fix round 1): run_on_device must not leave
    # the device with the resolution pin applied nor the core paused if
    # anything in the middle raises -- both the gfxEfbScale restore and the
    # resume POST must still happen, and the original exception must
    # propagate unchanged.
    class RaisingDevice(FakeDevice):
        def post(self, path, body=None):
            if path == "/api/debug/frame-advance":
                raise DeviceError("boom")
            return super().post(path, body)

    d = RaisingDevice(solid("red"), settings={"gfxEfbScale": {"value": 3}})
    with pytest.raises(DeviceError):
        run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None)
    assert ("/api/settings/gfxEfbScale", {"value": 3}) in d.calls
    assert ("/api/debug/resume", None) in d.calls

def test_run_on_device_resumes_even_if_restore_fails():
    # Controller ruling (Task 13 fix round 2): cleanup steps are independent
    # best-effort operations. If the restore POST raises, the resume POST is
    # still attempted, and the exception is caught + recorded as a warning.
    # Both cleanup steps run even if one fails; the original exception from
    # the scenario (if any) still propagates.
    class PartialFailureDevice(FakeDevice):
        def post(self, path, body=None):
            # Restore POST (value != 1) raises, but other POSTs succeed
            if path == "/api/settings/gfxEfbScale" and body and body.get("value") != 1:
                raise DeviceError("restore failed")
            return super().post(path, body)

    d = PartialFailureDevice(solid("red"), settings={"gfxEfbScale": {"value": 3}})
    warnings: list[str] = []
    png = run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None, warnings=warnings)

    # Function returns screenshot normally (exception was caught, not propagated)
    assert png == d.png

    # Resume was still called even though restore failed
    assert ("/api/debug/resume", None) in d.calls

    # Failure was recorded as a warning
    assert warnings and "restore" in warnings[0].lower()

def test_compare_pass_and_fail(tmp_path, monkeypatch):
    cfg = Config(dolphin_app=Path("/x"), cpu_core=5, games={"SMNE01": Path("/x.rvz")}, home=tmp_path)
    monkeypatch.setattr("icube_debug.scenario.dump_frames", lambda *a, **k: _write(tmp_path / "up.png", solid("red")))
    r = compare_with_upstream(FakeDevice(solid("red")), cfg, Scenario("SMNE01", 30), boot=lambda g: None)
    assert r["verdict"] == "pass" and r["score"] >= 0.97
    r = compare_with_upstream(FakeDevice(solid("blue")), cfg, Scenario("SMNE01", 30), boot=lambda g: None)
    assert r["verdict"] == "fail"
    assert (tmp_path / "runs.jsonl").read_text().count("\n") == 2

def test_compare_with_upstream_oracle_overrides_not_translated(tmp_path, monkeypatch):
    # Controller ruling (Task 13 review): Scenario.settings_overrides are
    # DEVICE keys and must never be auto-translated into oracle -C keys.
    # dump_frames gets overrides=None unless the scenario has an explicit
    # oracle_overrides dict.
    cfg = Config(dolphin_app=Path("/x"), cpu_core=5, games={"SMNE01": Path("/x.rvz")}, home=tmp_path)
    captured = {}
    def fake_dump_frames(cfg_, game_id, frames, overrides=None, timeout=300):
        captured["overrides"] = overrides
        return _write(tmp_path / "up.png", solid("red"))
    monkeypatch.setattr("icube_debug.scenario.dump_frames", fake_dump_frames)

    sc_no_oracle_overrides = Scenario("SMNE01", 30, settings_overrides={"gfxHackFastMath": True})
    compare_with_upstream(FakeDevice(solid("red")), cfg, sc_no_oracle_overrides, boot=lambda g: None)
    assert captured["overrides"] is None

    sc_with_oracle_overrides = Scenario(
        "SMNE01", 30,
        settings_overrides={"gfxHackFastMath": True},
        oracle_overrides={"Dolphin.Core.CPUCore": "1"},
    )
    compare_with_upstream(FakeDevice(solid("red")), cfg, sc_with_oracle_overrides, boot=lambda g: None)
    assert captured["overrides"] == {"Dolphin.Core.CPUCore": "1"}

def test_compare_with_upstream_records_oracle_error(tmp_path, monkeypatch):
    # Controller ruling (Task 13 fix round 1): if dump_frames raises
    # OracleError, compare_with_upstream must still record a run (verdict
    # "error", the device screenshot it already captured, score None) before
    # re-raising the original exception.
    cfg = Config(dolphin_app=Path("/x"), cpu_core=5, games={"SMNE01": Path("/x.rvz")}, home=tmp_path)

    def raising_dump_frames(*a, **k):
        raise OracleError("boom")

    monkeypatch.setattr("icube_debug.scenario.dump_frames", raising_dump_frames)
    with pytest.raises(OracleError):
        compare_with_upstream(FakeDevice(solid("red")), cfg, Scenario("SMNE01", 30), boot=lambda g: None)
    lines = (tmp_path / "runs.jsonl").read_text().strip().splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["verdict"] == "error"
    assert rec["error"] == "boom"
    assert rec["score"] is None
    assert Path(rec["device_png"]).exists()

def test_bisect_settings_flips_booleans_and_restores():
    d = FakeDevice(solid("red"), settings={"gfxHackFastMath": {"value": True}, "other": {"value": 5}})
    results = bisect_settings(
        d, Scenario("SMNE01", 10), ["gfxHackFastMath", "other"],
        boot=lambda g: None, upstream_png=solid("red"),
    )
    fast_math = next(r for r in results if r["key"] == "gfxHackFastMath")
    assert fast_math["from"] is True and fast_math["to"] is False and fast_math["score"] >= 0.99
    other = next(r for r in results if r["key"] == "other")
    assert other["note"] == "non-boolean, skipped"
    assert ("/api/settings/gfxHackFastMath", {"value": True}) in d.calls

def test_bisect_settings_reports_unknown_key():
    # A key absent from GET /api/settings is a distinct case from a
    # non-boolean value -- it must be flagged "unknown key", not silently
    # skipped as if it were a boolean that happened not to flip.
    d = FakeDevice(solid("red"), settings={"gfxHackFastMath": {"value": True}})
    results = bisect_settings(
        d, Scenario("SMNE01", 10), ["gfxHackFastMath", "doesNotExist"],
        boot=lambda g: None, upstream_png=solid("red"),
    )
    missing = next(r for r in results if r["key"] == "doesNotExist")
    assert missing == {"key": "doesNotExist", "note": "unknown key", "score": None}

def test_bisect_settings_records_restore_failure_as_warning():
    # Mirrors run_on_device's cleanup style: if the restore POST after a
    # flip fails, that must show up as a warning on the key's result rather
    # than raising and abandoning the rest of the sweep.
    class RestoreFailsDevice(FakeDevice):
        def post(self, path, body=None):
            if path == "/api/settings/gfxHackFastMath" and body == {"value": True}:
                raise DeviceError("restore boom")
            return super().post(path, body)

    d = RestoreFailsDevice(solid("red"), settings={"gfxHackFastMath": {"value": True}})
    results = bisect_settings(
        d, Scenario("SMNE01", 10), ["gfxHackFastMath"],
        boot=lambda g: None, upstream_png=solid("red"),
    )
    fast_math = results[0]
    assert fast_math["key"] == "gfxHackFastMath"
    assert any("restore" in w.lower() for w in fast_math["warnings"])

def _write(p, b): p.write_bytes(b); return p
