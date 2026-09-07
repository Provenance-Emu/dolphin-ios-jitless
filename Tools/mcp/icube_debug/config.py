from __future__ import annotations
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT = '''[oracle]
dolphin_app = "/Applications/Dolphin.app"
cpu_core = 5   # CachedInterpreter, matches the phone

[games]
# SMNE01 = "/path/to/New Super Mario Bros. Wii.rvz"
'''

@dataclass
class Config:
    dolphin_app: Path
    cpu_core: int
    games: dict[str, Path] = field(default_factory=dict)
    home: Path = Path.home() / ".icube-debug"

def load_config(path: Path | None = None) -> Config:
    path = path or Path.home() / ".icube-debug" / "config.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(DEFAULT)
    doc = tomllib.loads(path.read_text())
    oracle = doc.get("oracle", {})
    return Config(dolphin_app=Path(oracle.get("dolphin_app", "/Applications/Dolphin.app")),
                  cpu_core=int(oracle.get("cpu_core", 5)),
                  games={k: Path(v) for k, v in doc.get("games", {}).items()},
                  home=path.parent)
