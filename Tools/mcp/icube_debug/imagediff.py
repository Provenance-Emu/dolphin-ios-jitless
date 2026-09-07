from __future__ import annotations
from dataclasses import dataclass
from io import BytesIO
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity


@dataclass
class DiffResult:
    score: float
    tile_scores: list[list[float]]
    diff_png: bytes
    size: tuple[int, int]


def _load(b: bytes) -> Image.Image:
    return Image.open(BytesIO(b)).convert("RGB")


def compare(a_png: bytes, b_png: bytes, tiles: int = 8) -> DiffResult:
    a, b = _load(a_png), _load(b_png)
    size = (min(a.width, b.width), min(a.height, b.height))
    a, b = a.resize(size, Image.LANCZOS), b.resize(size, Image.LANCZOS)
    ga, gb = np.asarray(a.convert("L"), dtype=np.float32), np.asarray(b.convert("L"), dtype=np.float32)
    score = float(structural_similarity(ga, gb, data_range=255.0))
    th, tw = size[1] // tiles, size[0] // tiles
    tile_scores = []
    heat = a.copy()
    px = heat.load()
    for ty in range(tiles):
        row = []
        for tx in range(tiles):
            sa, sb = ga[ty*th:(ty+1)*th, tx*tw:(tx+1)*tw], gb[ty*th:(ty+1)*th, tx*tw:(tx+1)*tw]
            s = float(structural_similarity(sa, sb, data_range=255.0, win_size=7)) if min(sa.shape) >= 7 else 1.0
            row.append(round(s, 4))
            red = int(255 * max(0.0, 1.0 - s))
            for y in range(ty*th, (ty+1)*th):
                for x in range(tx*tw, (tx+1)*tw):
                    r, g, bb = px[x, y]
                    px[x, y] = (min(255, r + red), g // 2 if red > 40 else g, bb // 2 if red > 40 else bb)
        tile_scores.append(row)
    out = BytesIO()
    heat.save(out, "PNG")
    return DiffResult(score=round(score, 4), tile_scores=tile_scores, diff_png=out.getvalue(), size=size)
