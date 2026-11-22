"""Lorebound's art (Media/), saved as RLE TGA.

Rings (tinted by the addon; alpha is the shape, grey levels a soft bevel):
- Ring1/2/3.tga (256x256): a band of 11%, 15% and 23% of the diameter. The journal's three nested
  rings are drawn 204, 150 and 96 pixels wide, so each band comes out about 22 pixels thick. Drawn dim
  as the track.
- RingHalf1/2/3.tga: the band's right half only. The fill is two of them, each masked to one half of
  the ring and rotated (clockwise, from twelve o'clock) by exactly the share to show.
- RingHead1/2/3.tga: a quarter of the band ending at twelve o'clock, fading in towards that end: the
  fill's lighter leading end (added on, rotated to where the fill ends).
- Every ring also comes at 64x64 ("s" after the name: Ring2s, RingHalf2s) for rings drawn 64 pixels
  or less (lists, toast, badges), which would shimmer sampling the big ones.
- MaskLeft/MaskRight.tga (64x64): masks for the ring's two halves; the left one reaches a texel past
  the middle so no seam shows.
- Halo.tga (128x128): a soft light fading from the middle, behind the badge inspector's badge.
- Glow.tga (64x64): a soft halo just outside a ring drawn at 74% of its width (the texture is 1.35x
  the ring), gone before the texture's edge so it never shows a straight cut.
- Dot.tga (64x64): a disc, for the legend's dots and the quest giver's pin on the journal's map.
- Spark.tga (64x64): a four-pointed sparkle: the glowing head of a ring's fill, and the sparks that fly
  out of a closing ring.

Badges (gold, coloured here; the addon only greys out ones not earned yet):
- Badge<Shape>.tga (128x128): a gold frame with an open window, one shape per kind: Medal (zones),
  Shield (dungeons, battlegrounds), Crest (raids, continents, the Lorebound Seal), Hex (class and
  profession quests).
- Badge<Shape>Mask.tga: the window's shape, a mask for the zone's map art (or an icon) shown in it.
- Shine.tga (64x64): a soft diagonal band of light that sweeps across a badge being inspected.
- Pin.tga (32x32): a map pin, for pinned zones (and the zone ring's start cap).
- Book.tga (32x32): an open book, on the Lorebound ring's start cap (the continent's has the Spark).

    python make_lore_art.py
"""
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Media")
SOFT = 1.2  # texels of smoothing at each edge
SHADES = 16  # grey levels in a ring's bevel


def grid(n):
    centre = (n - 1) / 2
    y, x = np.mgrid[0:n, 0:n]
    return x - centre, y - centre


def edge(distance, radius, soft=SOFT):
    """1 inside the circle of that radius, 0 outside, smoothed over `soft` texels."""
    return np.clip((radius - distance) / soft + 0.5, 0, 1)


def shrink(values, n):
    """A 0..1 array drawn at 4x, scaled down to n x n (smooth edges without smoothing each shape by hand)."""
    image = Image.fromarray((np.clip(values, 0, 1) * 255).astype(np.uint8))
    return np.array(image.resize((n, n), Image.LANCZOS)).astype(float) / 255


def save(alpha, name, rgb=None):
    n = alpha.shape[0]
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    if rgb is None:
        rgba[..., :3] = 255
    else:
        rgba[..., :3] = (np.clip(rgb, 0, 1) * 255).round().astype(np.uint8)
    rgba[..., 3] = (np.clip(alpha, 0, 1) * 255).round().astype(np.uint8)
    Image.fromarray(rgba, "RGBA").save(os.path.join(OUT, name), compression="tga_rle")


def ring(band, n=256, half=False, head=False):
    """The band's alpha and its grey shading (a soft bevel). half: the right half only; head: the
    quarter ending at twelve o'clock, fading in towards it."""
    x, y = grid(n)
    distance = np.hypot(x, y)
    outer = n / 2 - n / 256  # the same share of the width at either size
    inner = outer - band * (2 * outer)
    alpha = edge(distance, outer) * (1 - edge(distance, inner))
    across = np.clip((distance - inner) / (outer - inner), 0, 1)
    shade = 0.80 + 0.20 * np.sin(np.pi * across) ** 0.8
    shade = np.round(shade * SHADES) / SHADES  # a few grey levels: long runs, so small RLE files
    if half:
        alpha = alpha * np.clip(x / 0.75 + 0.5, 0, 1)  # the cut down the middle, smoothed
    if head:
        turn = (np.arctan2(x, -y) / (2 * np.pi)) % 1  # 0 at twelve o'clock, clockwise
        into = np.clip((turn - 0.75) / 0.25, 0, 1)    # the quarter before twelve
        alpha = alpha * into ** 1.6
        shade = np.ones_like(shade)
    return alpha, np.repeat(shade[..., None], 3, axis=2)


def half_mask(right, n=64):
    x, _ = grid(n)
    # The right mask is exactly half; the left one reaches a texel past the middle, so no seam shows at
    # six o'clock (the right half turning round from twelve would show through a shared strip).
    keep = (x >= 0) if right else (x <= 1.0)
    return keep.astype(float)


def book(n=32):
    big = n * 4
    x, y = grid(big)
    x, y = x / (big / 2), y / (big / 2)
    page_l = (x > -0.86) & (x < -0.06) & (y > -0.55 - 0.12 * x) & (y < 0.62 - 0.1 * x)
    page_r = (x < 0.86) & (x > 0.06) & (y > -0.55 + 0.12 * x) & (y < 0.62 + 0.1 * x)
    return shrink((page_l | page_r).astype(float), n)


def glow():
    n = 64  # blurry anyway; smooth gradients don't pack well as RLE
    x, y = grid(n)
    distance = np.hypot(x, y) / (n / 2)
    halo = np.exp(-((distance - 0.74) / 0.1) ** 2) * 0.9
    return halo * np.clip((1 - distance) / 0.08, 0, 1)  # nothing left at the edge


def halo():
    """A soft light behind the inspector's badge: brightest in the middle (under the badge), fading smoothly to
    nothing at the edge, in full 8-bit steps so it doesn't band when stretched."""
    n = 128
    x, y = grid(n)
    distance = np.hypot(x, y) / (n / 2)
    return np.exp(-(distance / 0.5) ** 2) * np.clip((1 - distance) / 0.25, 0, 1)


def spark():
    n = 64
    x, y = grid(n)
    x, y = np.abs(x) / (n / 2), np.abs(y) / (n / 2)
    # Two thin diamonds crossed, plus a soft core.
    arms = np.clip(1 - (x / 0.12 + y), 0, 1) + np.clip(1 - (y / 0.12 + x), 0, 1)
    core = np.exp(-(x ** 2 + y ** 2) / 0.04)
    return np.clip(arms * 1.4 + core, 0, 1)


# ---------------------------------------------------------------- badges

def shape_inside(kind, x, y, scale):
    """1 inside the shape grown or shrunk by `scale` (x, y in -1..1, y down), smoothed; as floats."""
    soft = 0.012
    if kind == "Shield":
        # A heater shield: straight sides, then curving in to a point at the bottom.
        top, half = -0.86 * scale, 0.80 * scale
        knee = 0.05 * scale
        bottom = 0.95 * scale
        below = np.clip((y - knee) / (bottom - knee), 0, 1)
        width = np.where(y < knee, half, half * np.sqrt(np.clip(1 - below ** 1.6, 0, 1)))
        inside_x = np.clip((width - np.abs(x)) / soft + 0.5, 0, 1)
        inside_y = np.clip((y - top) / soft + 0.5, 0, 1) * np.clip((bottom - y) / soft + 0.5, 0, 1)
        return inside_x * inside_y
    distance = np.hypot(x, y)
    theta = np.arctan2(x, -y)
    if kind == "Medal":
        radius = 0.92 * (1 + 0.035 * np.cos(18 * theta))  # a scalloped rim
    elif kind == "Crest":
        radius = 0.66 + 0.30 * ((np.cos(8 * theta) + 1) / 2) ** 2.2  # an eight-pointed star
    else:  # Hex
        step = np.pi / 3
        radius = 0.92 * np.cos(np.pi / 6) / np.cos(((theta + np.pi / 6) % step) - np.pi / 6)
    return np.clip((radius * scale - distance) / soft + 0.5, 0, 1)


WINDOW = {"Medal": 0.74, "Shield": 0.76, "Crest": 0.62, "Hex": 0.76}


def badge(kind, n=128):
    """The gold frame (rgb, alpha) and the window's mask, drawn at 4x and scaled down."""
    big = n * 4
    x, y = grid(big)
    x, y = x / (big / 2), y / (big / 2)
    outer = shape_inside(kind, x, y, 1.0)
    window = shape_inside(kind, x, y, WINDOW[kind])
    lip = shape_inside(kind, x, y, WINDOW[kind] + 0.06)
    frame = np.clip(outer - window, 0, 1)
    # Gold, lit from the top left: bright on the outer rim, a dark groove at the window's lip.
    light = np.clip(0.62 - 0.38 * (x + y) / 1.4, 0.2, 1)
    rim = np.clip(outer - shape_inside(kind, x, y, 0.95), 0, 1)
    groove = np.clip(lip - window, 0, 1)
    gold = np.stack([0.98 * light, 0.76 * light, 0.32 * light], axis=2)
    gold = gold + rim[..., None] * np.array([0.25, 0.22, 0.12]) - groove[..., None] * np.array([0.35, 0.3, 0.15])
    rgb = np.stack([shrink(gold[..., i] * frame, n) for i in range(3)], axis=2)
    alpha = shrink(frame, n)
    rgb = rgb / np.maximum(alpha[..., None], 1e-3)  # un-premultiplied
    return rgb, alpha, shrink(lip, n)


def shine(n=64):
    x, y = grid(n)
    x, y = x / (n / 2), y / (n / 2)
    band = np.exp(-((x + y * 0.45) / 0.16) ** 2) + 0.5 * np.exp(-((x + y * 0.45 - 0.42) / 0.06) ** 2)
    return np.clip(band, 0, 1) * 0.85


def pin(n=32):
    big = n * 4
    x, y = grid(big)
    x, y = x / (big / 2), y / (big / 2)
    head = np.clip((0.48 - np.hypot(x, y + 0.28)) / 0.02 + 0.5, 0, 1)
    # The point: a triangle from the head down to the bottom.
    along = np.clip((y + 0.1) / 1.0, 0, 1)
    point = np.clip(((0.40 * (1 - along)) - np.abs(x)) / 0.02 + 0.5, 0, 1) * (y > -0.2) * (y < 0.92)
    hole = np.clip((0.16 - np.hypot(x, y + 0.28)) / 0.02 + 0.5, 0, 1)
    return shrink(np.maximum(head, point) - hole, n)


def main():
    os.makedirs(OUT, exist_ok=True)
    for number, band in ((1, 0.11), (2, 0.149), (3, 0.229)):
        for size, suffix in ((256, ""), (64, "s")):
            for kind, extra in (("Ring", {}), ("RingHalf", {"half": True}), ("RingHead", {"head": True})):
                alpha, shade = ring(band, size, **extra)
                save(alpha, "%s%d%s.tga" % (kind, number, suffix), shade)
    save(half_mask(True), "MaskRight.tga")
    save(half_mask(False), "MaskLeft.tga")
    save(book(), "Book.tga")
    x, y = grid(64)
    save(edge(np.hypot(x, y), 31), "Dot.tga")
    save(glow(), "Glow.tga")
    save(halo(), "Halo.tga")
    save(spark(), "Spark.tga")
    for kind in ("Medal", "Shield", "Crest", "Hex"):
        rgb, alpha, mask = badge(kind)
        save(alpha, "Badge%s.tga" % kind, rgb)
        save(mask, "Badge%sMask.tga" % kind)
    save(pin(), "Pin.tga")
    save(shine(), "Shine.tga")
    print("made the rings, masks, Dot, Glow, Halo, Spark, the badges, Shine, Pin and Book in", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
