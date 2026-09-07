from __future__ import annotations
import re
import subprocess, tempfile, time
from pathlib import Path
from .config import Config

class OracleError(Exception):
    pass

_FRAME_RE = re.compile(r"framedump_(\d+)\.png$")

def build_command(app: Path, iso: Path, user_dir: Path, cpu_core: int, overrides: dict[str, str] | None = None) -> list[str]:
    # NOTE on -C key names: Dolphin's -C parser is <System>.<Section>.<Key>=<Value>,
    # where the System token is looked up by name (UICommon/CommandLineParse.cpp).
    # System::Main is registered under the name "Dolphin" (Core/Config/MainSettings.*),
    # but System::GFX is registered under the name "Graphics", NOT "GFX" and NOT
    # "Dolphin.Graphics" (Common/Config/Config.cpp system_to_name) -- an unrecognized
    # system name is silently dropped, no error. Verified against the Dolphin source in
    # Cores/Dolphin/dolphin-ios/Source/Core/{Common,Core}/Config/*.{h,cpp} and confirmed
    # empirically: Graphics.Settings.InternalResolution=1 -> 836x456,
    # =4 -> 3336x1824 (scales); the same values under a "GFX." or "Dolphin.Graphics."
    # prefix produced no change in dumped frame size at all.
    cmd = [str(app / "Contents/MacOS/Dolphin"), "-b", "-e", str(iso), "-u", str(user_dir),
           "-C", f"Dolphin.Core.CPUCore={cpu_core}", "-C", "Dolphin.Core.CPUThread=False",
           "-C", "Dolphin.Movie.DumpFrames=True", "-C", "Graphics.Settings.DumpFramesAsImages=True",
           "-C", "Dolphin.Movie.DumpFramesSilent=True", "-C", "Dolphin.Core.EnableCheats=False",
           # Controller ruling (Task 11 review): comparisons must be rasterized at the
           # same resolution on both sides. Force 1x native internal resolution so the
           # upstream oracle frame matches the device's native EFB scale.
           "-C", "Graphics.Settings.InternalResolution=1"]
    for k, v in (overrides or {}).items():
        cmd += ["-C", f"{k}={v}"]
    return cmd

def pick_frame(user_dir: Path, frame: int) -> Path:
    # Dolphin 2509 with Movie.DumpFramesAsImages=True writes unpadded names
    # (framedump_0.png, framedump_1.png, ... framedump_10.png, ...), so a
    # lexical sort misorders anything past frame 9. Sort numerically instead.
    frames = sorted((user_dir / "Dump" / "Frames").glob("framedump_*.png"),
                     key=lambda p: int(_FRAME_RE.search(p.name).group(1)))
    if len(frames) <= frame:
        raise OracleError(f"oracle produced only {len(frames)} frames, needed {frame + 1}")
    return frames[frame]

def dump_frames(cfg: Config, game_id: str, frames: int, overrides: dict[str, str] | None = None, timeout: float = 300) -> Path:
    iso = cfg.games.get(game_id)
    if iso is None:
        raise OracleError(f"no ISO mapped for {game_id} in {cfg.home / 'config.toml'}")
    if not (cfg.dolphin_app / "Contents/MacOS/Dolphin").exists():
        raise OracleError(f"Dolphin not found at {cfg.dolphin_app}")
    user_dir = Path(tempfile.mkdtemp(prefix="icube-oracle-"))
    proc = subprocess.Popen(build_command(cfg.dolphin_app, iso, user_dir, cfg.cpu_core, overrides),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            try:
                return pick_frame(user_dir, frames)
            except OracleError:
                if proc.poll() is not None:
                    raise OracleError("Dolphin exited before producing enough frames")
                time.sleep(0.5)
        raise OracleError(f"oracle timed out after {timeout}s")
    finally:
        proc.terminate()
        try: proc.wait(5)
        except subprocess.TimeoutExpired: proc.kill()
