#!/bin/bash
# Renders the app icon from its SVG sources into Resources/AppIcon.icns (every size macOS asks for)
# and, optionally, PNG previews. Development only: make-app.sh uses the committed .icns, so a normal
# build needs none of these tools.
#
#   scripts/icon/build-icon.sh [PREVIEW_DIR]
#
# Needs rsvg-convert (macOS: `brew install librsvg`; Debian/Ubuntu: `apt install librsvg2-bin`).
# 16 and 32 px come from paneshare-small.svg (simplified artwork); 64 px and up from paneshare.svg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Resources/Icon"
OUT="$ROOT/Resources/AppIcon.icns"
PREVIEWS="${1:-}"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

render() { # svg pixels file
  rsvg-convert --width "$2" --height "$2" --keep-aspect-ratio "$SRC/$1" --output "$SET/$3"
}
render paneshare-small.svg 16 icon_16x16.png
render paneshare-small.svg 32 icon_16x16@2x.png
render paneshare-small.svg 32 icon_32x32.png
render paneshare.svg 64 icon_32x32@2x.png
render paneshare.svg 128 icon_128x128.png
render paneshare.svg 256 icon_128x128@2x.png
render paneshare.svg 256 icon_256x256.png
render paneshare.svg 512 icon_256x256@2x.png
render paneshare.svg 512 icon_512x512.png
render paneshare.svg 1024 icon_512x512@2x.png

if command -v iconutil >/dev/null; then
  iconutil --convert icns --output "$OUT" "$SET"
else
  python3 "$ROOT/scripts/icon/icns.py" "$SET" "$OUT"
fi
echo "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

if [ -n "$PREVIEWS" ]; then
  mkdir -p "$PREVIEWS"
  cp "$SET/icon_512x512@2x.png" "$PREVIEWS/paneshare-icon-1024.png"
  cp "$SET/icon_128x128.png" "$PREVIEWS/paneshare-icon-128.png"
  cp "$SET/icon_32x32.png" "$PREVIEWS/paneshare-icon-32.png"
  cp "$SET/icon_16x16.png" "$PREVIEWS/paneshare-icon-16.png"
  echo "Previews in $PREVIEWS"
fi
