from io import BytesIO
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


def test_size_mismatch_is_handled():
    r = compare(png(scene), png(scene, size=(512, 384)))
    assert r.size == (256, 192) and r.score > 0.7
