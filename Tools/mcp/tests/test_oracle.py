from pathlib import Path
import pytest
from icube_debug.config import load_config
from icube_debug.oracle import build_command, pick_frame, OracleError

def test_config_defaults_created(tmp_path):
    cfg = load_config(tmp_path / "config.toml")
    assert cfg.dolphin_app == Path("/Applications/Dolphin.app") and cfg.cpu_core == 5 and cfg.games == {}

def test_build_command_sets_dump_and_core(tmp_path):
    cmd = build_command(Path("/Applications/Dolphin.app"), Path("/r/x.rvz"), tmp_path, cpu_core=5, overrides={"GFX.Hacks.FastMath": "False"})
    s = " ".join(cmd)
    assert "-b" in cmd and "-e /r/x.rvz" in s
    assert "Dolphin.Core.CPUCore=5" in s and "Dolphin.Core.CPUThread=False" in s
    # NOTE: Dolphin's System::GFX is registered under the CLI name "Graphics", not
    # "GFX" or "Dolphin.Graphics" -- confirmed against Core/Config/GraphicsSettings.cpp
    # and Common/Config/Config.cpp (system_to_name) and empirically (an unrecognized
    # system token is silently dropped, no error, so "GFX.*"/"Dolphin.Graphics.*"
    # overrides are dead no-ops that never touch the renderer).
    assert "Graphics.Settings.DumpFramesAsImages=True" in s and f"-u {tmp_path}" in s
    assert "GFX.Hacks.FastMath=False" in s
    # Controller ruling (Task 11 review): comparisons must be rasterized at the
    # same resolution on both sides, so the oracle always forces 1x native IR.
    assert "Graphics.Settings.InternalResolution=1" in s

def test_pick_frame_requires_enough_frames(tmp_path):
    # Empirically, Dolphin 2509 with Movie.DumpFramesAsImages=True writes
    # unpadded names like framedump_0.png, framedump_1.png, ... framedump_10.png
    # (no zero-padding), so a lexical sort misorders anything past frame 9.
    d = tmp_path / "Dump" / "Frames"; d.mkdir(parents=True)
    for i in range(12): (d / f"framedump_{i}.png").write_bytes(b"x")
    assert pick_frame(tmp_path, 2).name == "framedump_2.png"
    assert pick_frame(tmp_path, 10).name == "framedump_10.png"
    with pytest.raises(OracleError, match="only 12"):
        pick_frame(tmp_path, 20)
