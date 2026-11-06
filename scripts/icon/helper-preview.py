#!/usr/bin/env python3
"""Preview of a Dock helper icon (the remote app's icon inside the source-Mac ring, with the
paneshare badge from 64 px), using the same geometry as HelperIconLayout.swift. For review only;
the shipped helpers are drawn by DockHelperFactory at runtime.

usage: helper-preview.py OUT_DIR [ring-hex ...]   (needs rsvg-convert)
"""
import base64, math, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
N = 4.6
BODY = 824 / 1024

# A neutral stand-in for "some remote app": not any real product's icon.
SAMPLE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#FFD25A"/><stop offset="1" stop-color="#F08A1C"/></linearGradient></defs>
<path d="{body}" fill="url(#g)"/>
<rect x="300" y="300" width="424" height="424" rx="70" fill="#fff" opacity="0.95"/>
<rect x="370" y="390" width="284" height="44" rx="22" fill="#F08A1C"/>
<rect x="370" y="490" width="220" height="44" rx="22" fill="#F5B04A"/>
<rect x="370" y="590" width="250" height="44" rx="22" fill="#F5B04A"/>
</svg>"""


def squircle(cx, cy, half, count=192):
    pts = []
    for i in range(count):
        t = 2 * math.pi * i / count
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / N), c), cy + half * math.copysign(abs(s) ** (2 / N), s)))
    return "M" + " L".join(f"{x:.3f} {y:.3f}" for x, y in pts) + " Z"


def layout(p):
    side = p * BODY
    origin = (p - side) / 2
    ring = max(1.5, p * (0.09 if p <= 32 else 0.055))
    gap = max(0.5, p * 0.012)
    image = (side - 2 * (ring + gap)) / BODY
    badge = None
    if p >= 64:
        d = p * 0.36
        # HelperIconLayout is y-up; SVG is y-down.
        badge = (origin + side - d * 0.82, p - (origin - d * 0.18) - d, d)
    return side, origin, ring, image, badge


def data_uri(svg_bytes, pixels):
    png = subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels)], input=svg_bytes,
                         capture_output=True, check=True).stdout
    return "data:image/png;base64," + base64.b64encode(png).decode()


def helper_svg(p, ring_hex):
    side, origin, ring, image, badge = layout(p)
    half = side / 2
    c = p / 2
    sample = SAMPLE.replace("{body}", squircle(512, 512, 412)).encode()
    remote = data_uri(sample, max(16, round(image * 2)))
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
             f'width="{p}" height="{p}" viewBox="0 0 {p} {p}">',
             f'<defs><filter id="s" x="-10%" y="-10%" width="120%" height="120%">'
             f'<feDropShadow dx="0" dy="{max(0.5, p * 0.006):.3f}" stdDeviation="{max(0.5, p * 0.012):.3f}" '
             f'flood-color="#000" flood-opacity="0.3"/></filter></defs>',
             f'<path fill-rule="evenodd" fill="{ring_hex}" filter="url(#s)" '
             f'd="{squircle(c, c, half)} {squircle(c, c, half - ring)}"/>',
             f'<image x="{(p - image) / 2:.3f}" y="{(p - image) / 2:.3f}" width="{image:.3f}" height="{image:.3f}" '
             f'xlink:href="{remote}"/>']
    if badge:
        x, y, d = badge
        with open(os.path.join(ROOT, "Resources/Icon/paneshare.svg"), "rb") as f:
            icon = data_uri(f.read(), max(64, round(d * 2)))
        parts.append(f'<image x="{x:.3f}" y="{y:.3f}" width="{d:.3f}" height="{d:.3f}" xlink:href="{icon}"/>')
    parts.append("</svg>")
    return "\n".join(parts).encode()


def main():
    out = sys.argv[1]
    rings = sys.argv[2:] or ["#007AFF", "#FF9500"]
    os.makedirs(out, exist_ok=True)
    for i, ring in enumerate(rings):
        for p in (1024, 128, 32, 16):
            png = subprocess.run(["rsvg-convert"], input=helper_svg(p, ring), capture_output=True, check=True).stdout
            with open(os.path.join(out, f"dock-helper-{chr(ord('a') + i)}-{p}.png"), "wb") as f:
                f.write(png)
    print(f"wrote {len(rings) * 4} previews to {out}")


if __name__ == "__main__":
    main()
