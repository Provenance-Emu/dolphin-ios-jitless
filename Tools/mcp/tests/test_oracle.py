from pathlib import Path
import pytest
from icube_debug.config import Config, load_config
from icube_debug.oracle import build_command, pick_frame, dump_frames, OracleError

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

def test_build_command_forced_flags_win_over_overrides(tmp_path):
    # Caller overrides must be emitted first, forced flags last, so Dolphin's
    # last-`-C`-wins parsing lets the forced flags (esp. 1x resolution) win.
    cmd = build_command(
        Path("/Applications/Dolphin.app"), Path("/r/x.rvz"), tmp_path, cpu_core=5,
        overrides={"GFX.Hacks.FastMath": "False"},
    )
    override_idx = cmd.index("GFX.Hacks.FastMath=False")
    for forced in (
        "Dolphin.Movie.DumpFrames=True",
        "Graphics.Settings.DumpFramesAsImages=True",
        "Dolphin.Movie.DumpFramesSilent=True",
        "Graphics.Settings.InternalResolution=1",
        "Dolphin.Core.CPUCore=5",
        "Dolphin.Core.CPUThread=False",
        "Dolphin.Core.EnableCheats=False",
    ):
        assert cmd.index(forced) > override_idx

def test_build_command_disallows_internal_resolution_override(tmp_path):
    with pytest.raises(OracleError, match="InternalResolution"):
        build_command(
            Path("/Applications/Dolphin.app"), Path("/r/x.rvz"), tmp_path, cpu_core=5,
            overrides={"Graphics.Settings.InternalResolution": "4"},
        )

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

def test_pick_frame_skips_non_matching_names(tmp_path):
    d = tmp_path / "Dump" / "Frames"; d.mkdir(parents=True)
    for i in range(3): (d / f"framedump_{i}.png").write_bytes(b"x")
    (d / "framedump_final.png").write_bytes(b"x")  # no numeric suffix -- must be skipped
    (d / "not_a_frame.png").write_bytes(b"x")
    assert pick_frame(tmp_path, 2).name == "framedump_2.png"
    with pytest.raises(OracleError, match="only 3"):
        pick_frame(tmp_path, 5)

def _fake_dolphin_app(tmp_path: Path) -> Path:
    app = tmp_path / "Dolphin.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / "Dolphin").write_bytes(b"")
    return app

def test_dump_frames_orchestration_success(tmp_path, monkeypatch):
    calls = []

    class FakePopen:
        def __init__(self, cmd, stdout=None, stderr=None):
            self.cmd = cmd
            self._returncode = None
            self.terminated = False
            self.killed = False
            user_dir = Path(cmd[cmd.index("-u") + 1])
            frames_dir = user_dir / "Dump" / "Frames"
            frames_dir.mkdir(parents=True, exist_ok=True)
            for i in range(5):
                (frames_dir / f"framedump_{i}.png").write_bytes(b"fake-png-data")
            calls.append(self)

        def poll(self):
            return self._returncode

        def terminate(self):
            self.terminated = True

        def wait(self, timeout=None):
            return 0

        def kill(self):
            self.killed = True

    monkeypatch.setattr("icube_debug.oracle.subprocess.Popen", FakePopen)

    cfg = Config(
        dolphin_app=_fake_dolphin_app(tmp_path),
        cpu_core=5,
        games={"TEST": tmp_path / "game.rvz"},
        home=tmp_path / "home",
    )

    result = dump_frames(cfg, "TEST", 2)

    assert result.exists()
    assert result.parent == cfg.home / "oracle-frames"
    assert len(calls) == 1
    assert calls[0].terminated
    user_dir = Path(calls[0].cmd[calls[0].cmd.index("-u") + 1])
    assert not user_dir.exists()

def test_dump_frames_raises_when_dolphin_exits_without_frames(tmp_path, monkeypatch):
    class FakePopen:
        def __init__(self, cmd, stdout=None, stderr=None):
            self.cmd = cmd
            self._returncode = 1
            if stderr is not None:
                stderr.write(b"Dolphin: fatal error loading ISO\n")
                stderr.flush()

        def poll(self):
            return self._returncode

        def terminate(self):
            pass

        def wait(self, timeout=None):
            return self._returncode

        def kill(self):
            pass

    monkeypatch.setattr("icube_debug.oracle.subprocess.Popen", FakePopen)

    cfg = Config(
        dolphin_app=_fake_dolphin_app(tmp_path),
        cpu_core=5,
        games={"TEST": tmp_path / "game.rvz"},
        home=tmp_path / "home",
    )

    with pytest.raises(OracleError, match="exited"):
        dump_frames(cfg, "TEST", 0)

def test_dump_frames_does_not_leak_fds(tmp_path, monkeypatch):
    import os
    calls = []

    class FakePopen:
        def __init__(self, cmd, stdout=None, stderr=None):
            self.cmd = cmd
            self._returncode = None
            self.terminated = False
            self.killed = False
            user_dir = Path(cmd[cmd.index("-u") + 1])
            frames_dir = user_dir / "Dump" / "Frames"
            frames_dir.mkdir(parents=True, exist_ok=True)
            for i in range(5):
                (frames_dir / f"framedump_{i}.png").write_bytes(b"fake-png-data")
            calls.append(self)

        def poll(self):
            return self._returncode

        def terminate(self):
            self.terminated = True

        def wait(self, timeout=None):
            return 0

        def kill(self):
            self.killed = True

    monkeypatch.setattr("icube_debug.oracle.subprocess.Popen", FakePopen)

    cfg = Config(
        dolphin_app=_fake_dolphin_app(tmp_path),
        cpu_core=5,
        games={"TEST": tmp_path / "game.rvz"},
        home=tmp_path / "home",
    )

    # Count open fds before and after 5 calls
    fd_count_before = len(os.listdir("/dev/fd"))
    for _ in range(5):
        dump_frames(cfg, "TEST", 2)
    fd_count_after = len(os.listdir("/dev/fd"))

    # The fd count should be the same (no leaks)
    assert fd_count_before == fd_count_after, f"fd leak detected: {fd_count_before} before, {fd_count_after} after"
