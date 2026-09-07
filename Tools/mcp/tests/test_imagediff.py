from io import BytesIO
import math
from PIL import Image, ImageDraw
from icube_debug.imagediff import compare


def png(draw_fn, size=(256, 192)):
    im = Image.new("RGB", size, "white")
    draw_fn(ImageDraw.Draw(im))
    b = BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


def scene(d):
    d.rectangle([40, 40, 120, 150], fill="red")
    d.ellipse([150, 60, 230, 140], fill="blue")


def scene_broken(d):
    scene(d)
    d.rectangle([60, 20, 200, 60], fill="red")  # a limb where none should be


def test_identical_scores_one():
    a = png(scene)
    assert compare(a, a).score == 1.0


def test_corruption_lowers_score_and_localises():
    r = compare(png(scene), png(scene_broken))
    assert r.score < 0.97
    top_row = r.tile_scores[0]
    bottom_row = r.tile_scores[-1]
    assert min(top_row) < min(bottom_row)


def test_same_rasterization_resized_scores_high():
    """Same rasterization resized with LANCZOS should score >= 0.97."""
    original = png(scene)
    # Manually upscale using LANCZOS via Pillow
    im = Image.open(BytesIO(original))
    upscaled_im = im.resize((512, 384), Image.LANCZOS)
    upscaled = BytesIO()
    upscaled_im.save(upscaled, "PNG")
    upscaled_bytes = upscaled.getvalue()

    r = compare(original, upscaled_bytes)
    assert r.size == (256, 192)
    assert r.score >= 0.97


def test_independent_rasterizations_at_different_sizes_score_low():
    """Independent renders at different native sizes score low (0.6-0.85)."""
    # This is a documented limitation: frames must be rasterized at the same
    # resolution on both sides for meaningful comparison (Task 13 enforces
    # 1× internal resolution on device and oracle).
    r = compare(png(scene), png(scene, size=(512, 384)))
    assert r.size == (256, 192)
    assert 0.6 <= r.score <= 0.85


def test_small_tiles_do_not_report_perfect():
    """Small tiles should not silently report 1.0; None tiles are excluded."""
    # With 32×32 tiles on a 256×192 image, tiles are 8×6 pixels.
    # After grayscale conversion, smaller tiles should not all score 1.0.
    r = compare(png(scene), png(scene_broken), tiles=32)
    assert r.size == (256, 192)

    # Flatten tile scores and check for at least one non-None score < 0.97
    flat_scores = [s for row in r.tile_scores for s in row if s is not None]
    assert len(flat_scores) > 0, "No valid (non-None) tile scores found"
    assert any(s < 0.97 for s in flat_scores), "Expected at least one tile score < 0.97, but all are >= 0.97"


def test_degenerate_tiles_are_json_null():
    """Degenerate tiles (win < 3) must score None (JSON null), not NaN.

    256×192 with tiles=128 creates 2×1-pixel tiles (win=1 < 3), which should
    all be None. Verify: at least one None, no NaN anywhere, JSON-serializable.
    """
    import json

    r = compare(png(scene), png(scene), tiles=128)
    assert r.size == (256, 192)

    # Flatten scores
    flat_scores = [s for row in r.tile_scores for s in row]

    # At least one None
    assert any(s is None for s in flat_scores), "Expected at least one None tile"

    # No NaN anywhere
    assert not any(isinstance(s, float) and math.isnan(s) for s in flat_scores), "Found NaN in tile scores"

    # Must be JSON-serializable with allow_nan=False
    json_str = json.dumps(r.tile_scores, allow_nan=False)
    assert json_str is not None
