#!/usr/bin/env python3
"""Draws the DMG window background: Resources/DMG/background.png (660x400) and background@2x.png.

Needs Pillow. Run it only when the design changes; make-dmg.sh uses the committed PNGs.
Layout matches make-dmg.sh: paneshare.app at (170, 190), Applications at (490, 190), icons 128 pt.
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Resources", "DMG")
W, H = 660, 400
FONT = "/System/Library/Fonts/SFNS.ttf"


def draw(scale):
    s = lambda v: int(round(v * scale))
    im = Image.new("RGB", (s(W), s(H)), (30, 30, 32))
    d = ImageDraw.Draw(im)
    # Soft top glow so the window isn't flat.
    for y in range(s(H)):
        t = y / s(H)
        c = int(38 - 10 * t)
        d.line([(0, y), (s(W), y)], fill=(c, c, c + 2))
    # Arrow from the app to Applications.
    y = s(190)
    x0, x1 = s(262), s(398)
    col = (120, 120, 128)
    d.line([(x0, y), (x1 - s(10), y)], fill=col, width=s(4))
    d.polygon([(x1, y), (x1 - s(16), y - s(10)), (x1 - s(16), y + s(10))], fill=col)
    # Caption.
    f = ImageFont.truetype(FONT, s(14))
    text = "Drag paneshare to Applications"
    tw = d.textlength(text, font=f)
    d.text(((s(W) - tw) / 2, s(318)), text, font=f, fill=(150, 150, 156))
    return im


os.makedirs(OUT, exist_ok=True)
draw(1).save(os.path.join(OUT, "background.png"), optimize=True)
draw(2).save(os.path.join(OUT, "background@2x.png"), optimize=True)
print("wrote", OUT)
