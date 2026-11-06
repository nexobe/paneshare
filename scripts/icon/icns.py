#!/usr/bin/env python3
"""Packs an .iconset directory into an .icns file (the same container `ICNSWriter` in PaneshareCore
writes: "icns", big-endian length, then type/length/PNG entries). Used where `iconutil` isn't
available (Linux); on a Mac build-icon.sh uses `iconutil -c icns`. Usage: icns.py ICONSET OUT.icns
"""
import os
import struct
import sys

# iconset file name -> icns entry type (PNG payloads)
TYPES = [
    ("icon_16x16.png", b"icp4"),
    ("icon_16x16@2x.png", b"ic11"),
    ("icon_32x32.png", b"icp5"),
    ("icon_32x32@2x.png", b"ic12"),
    ("icon_128x128.png", b"ic07"),
    ("icon_128x128@2x.png", b"ic13"),
    ("icon_256x256.png", b"ic08"),
    ("icon_256x256@2x.png", b"ic14"),
    ("icon_512x512.png", b"ic09"),
    ("icon_512x512@2x.png", b"ic10"),
]

iconset, out = sys.argv[1], sys.argv[2]
body = b""
for name, kind in TYPES:
    with open(os.path.join(iconset, name), "rb") as f:
        png = f.read()
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{name} is not a PNG")
    body += kind + struct.pack(">I", 8 + len(png)) + png
with open(out, "wb") as f:
    f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
