from pathlib import Path
from icube_debug.scenario import Scenario, run_on_device, compare_with_upstream, bisect_settings
from icube_debug.config import Config

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
    assert ("/api/debug/pause", None) in d.calls and ("/api/debug/frame-advance", {"n": 30}) in d.calls

def test_run_on_device_pins_and_restores_resolution():
    # Controller ruling (Task 13 review): run_on_device must pin the device's
    # internal resolution (gfxEfbScale, a DEVICE key -- not an oracle -C key)
    # to 1x for the duration of the scenario and restore whatever value it
    # had beforehand, bracketing the pause/frame-advance sequence.
    d = FakeDevice(solid("red"), settings={"gfxEfbScale": {"value": 3}})
    run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None)
    set_idx = d.calls.index(("/api/settings/gfxEfbScale", {"value": 1}))
    advance_idx = d.calls.index(("/api/debug/frame-advance", {"n": 30}))
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

def test_bisect_settings_flips_booleans_and_restores():
    d = FakeDevice(solid("red"), settings={"gfxHackFastMath": {"value": True}, "other": {"value": 5}})
    results = bisect_settings(
        d, None, Scenario("SMNE01", 10), ["gfxHackFastMath", "other"],
        boot=lambda g: None, upstream_png=solid("red"),
    )
    fast_math = next(r for r in results if r["key"] == "gfxHackFastMath")
    assert fast_math["from"] is True and fast_math["to"] is False and fast_math["score"] >= 0.99
    other = next(r for r in results if r["key"] == "other")
    assert other["note"] == "non-boolean, skipped"
    assert ("/api/settings/gfxHackFastMath", {"value": True}) in d.calls

def _write(p, b): p.write_bytes(b); return p
