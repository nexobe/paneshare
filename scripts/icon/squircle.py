#!/usr/bin/env python3
"""Prints an SVG path for the macOS icon body: a superellipse |x|^n + |y|^n = 1 (n = 5) inscribed in
the 824 pt body square of a 1024 pt canvas (100 pt margins), the shape of the Big Sur and later icon grid.
`Squircle` in PaneshareCore draws the same curve for Dock helper icons. Usage: squircle.py [cx cy half n]
"""
import math
import sys

cx, cy, half, n = (float(a) for a in (sys.argv[1:5] if len(sys.argv) >= 5 else (512, 512, 412, 5)))
steps = 192
points = []
for i in range(steps):
    t = 2 * math.pi * i / steps
    c, s = math.cos(t), math.sin(t)
    x = cx + half * math.copysign(abs(c) ** (2 / n), c)
    y = cy + half * math.copysign(abs(s) ** (2 / n), s)
    points.append(f"{x:.1f} {y:.1f}")
print("M" + " L".join(points) + " Z")
