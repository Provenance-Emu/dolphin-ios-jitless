from __future__ import annotations
import re
import shutil
import subprocess, tempfile, time
from pathlib import Path
from .config import Config

class OracleError(Exception):
    pass

_FRAME_RE = re.compile(r"framedump_(\d+)\.png$")

# The forced flag that makes the oracle rasterize at the same resolution as the
# device (controller ruling, Task 11 review). Callers are not allowed to
# override this -- see build_command.
_FORCED_INTERNAL_RESOLUTION_KEY = "Graphics.Settings.InternalResolution"

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
    overrides = overrides or {}
    if _FORCED_INTERNAL_RESOLUTION_KEY in overrides:
        raise OracleError(
            f"override of {_FORCED_INTERNAL_RESOLUTION_KEY} is not allowed: "
            "frames must match the device at 1x"
        )

    cmd = [str(app / "Contents/MacOS/Dolphin"), "-b", "-e", str(iso), "-u", str(user_dir)]

    # Caller overrides are emitted FIRST. Dolphin's -C parsing is last-value-wins,
    # so the forced flags below (esp. the 1x resolution pin) always win even if an
    # override happens to target the same key -- except InternalResolution, which
    # is rejected outright above rather than silently overridden.
    for k, v in overrides.items():
        cmd += ["-C", f"{k}={v}"]

    cmd += ["-C", "Dolphin.Movie.DumpFrames=True",
            "-C", "Graphics.Settings.DumpFramesAsImages=True",
            "-C", "Dolphin.Movie.DumpFramesSilent=True",
            # Controller ruling (Task 11 review): comparisons must be rasterized at
            # the same resolution on both sides. Force 1x native internal
            # resolution so the upstream oracle frame matches the device's native
            # EFB scale. Emitted last so no override can shadow it.
            "-C", f"{_FORCED_INTERNAL_RESOLUTION_KEY}=1",
            "-C", f"Dolphin.Core.CPUCore={cpu_core}",
            "-C", "Dolphin.Core.CPUThread=False",
            "-C", "Dolphin.Core.EnableCheats=False"]
    return cmd

def pick_frame(user_dir: Path, frame: int) -> Path:
    # Dolphin 2509 with Graphics.Settings.DumpFramesAsImages=True writes unpadded
    # names (framedump_0.png, framedump_1.png, ... framedump_10.png, ...), so a
    # lexical sort misorders anything past frame 9. Sort numerically instead, and
    # skip (rather than crash on) any filename that doesn't match the expected
    # pattern -- a stray leftover file shouldn't take down the whole poll loop.
    candidates: list[tuple[int, Path]] = []
    for p in (user_dir / "Dump" / "Frames").glob("framedump_*.png"):
        m = _FRAME_RE.search(p.name)
        if m is None:
            continue
        candidates.append((int(m.group(1)), p))
    frames = [p for _, p in sorted(candidates, key=lambda t: t[0])]
    if len(frames) <= frame:
        raise OracleError(f"oracle produced only {len(frames)} frames, needed {frame + 1}")
    return frames[frame]

def _tail(path: Path, n: int) -> str:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    tail_lines = lines[-n:]
    if not tail_lines:
        return ""
    return "\n--- last Dolphin stderr lines ---\n" + "\n".join(tail_lines)

def _wait_for_frame(proc: subprocess.Popen, user_dir: Path, frame: int, stderr_path: Path, timeout: float) -> Path:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return pick_frame(user_dir, frame)
        except OracleError:
            if proc.poll() is not None:
                raise OracleError(
                    "Dolphin exited before producing enough frames" + _tail(stderr_path, 10)
                )
            time.sleep(0.5)
    raise OracleError(f"oracle timed out after {timeout}s")

def dump_frames(cfg: Config, game_id: str, frames: int, overrides: dict[str, str] | None = None, timeout: float = 300) -> Path:
    """Run Dolphin headless in a throwaway user dir, wait for `frames` PNGs to
    exist, then copy the selected frame into cfg.home/oracle-frames and return
    that path. The throwaway Dolphin user dir (and its captured stderr log) are
    always cleaned up afterwards, whether this succeeds, times out, or Dolphin
    crashes.
    """
    iso = cfg.games.get(game_id)
    if iso is None:
        raise OracleError(f"no ISO mapped for {game_id} in {cfg.home / 'config.toml'}")
    if not (cfg.dolphin_app / "Contents/MacOS/Dolphin").exists():
        raise OracleError(f"Dolphin not found at {cfg.dolphin_app}")

    user_dir = Path(tempfile.mkdtemp(prefix="icube-oracle-"))
    stderr_path = Path(tempfile.mkstemp(prefix="icube-oracle-stderr-", suffix=".log")[1])
    proc: subprocess.Popen | None = None
    try:
        with open(stderr_path, "wb") as stderr_file:
            proc = subprocess.Popen(
                build_command(cfg.dolphin_app, iso, user_dir, cfg.cpu_core, overrides),
                stdout=subprocess.DEVNULL, stderr=stderr_file,
            )
            frame_path = _wait_for_frame(proc, user_dir, frames, stderr_path, timeout)

        dest_dir = cfg.home / "oracle-frames"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / f"{game_id}-{frames}-{int(time.time() * 1000)}.png"
        shutil.copyfile(frame_path, dest)
        return dest
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        stderr_path.unlink(missing_ok=True)
        shutil.rmtree(user_dir, ignore_errors=True)
