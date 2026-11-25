#!/bin/bash
# Builds the paneshare disk image: the app and an Applications link side by side on a dark background with a
# "drag to Applications" arrow, a fixed window size, and the app icon as the volume icon.
#
# Usage: scripts/dmg/make-dmg.sh <paneshare.app> <out.dmg> <volume name>
#
# Finder writes the window layout (.DS_Store), so the first run asks to let this terminal control Finder
# (System Settings > Privacy & Security > Automation). Without that permission the script still builds a
# working DMG, only without the layout, and says so. The DMG is not signed here; release.sh signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?usage: make-dmg.sh <paneshare.app> <out.dmg> <volume name>}"
OUT="${2:?usage: make-dmg.sh <paneshare.app> <out.dmg> <volume name>}"
VOLNAME="${3:?usage: make-dmg.sh <paneshare.app> <out.dmg> <volume name>}"
[ -d "$APP" ] || { echo "make-dmg: $APP not found" >&2; exit 1; }

WORK="$(mktemp -d)"
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Stage the contents.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/paneshare.app"
ln -s /Applications "$STAGE/Applications"
# One multi-resolution TIFF, so the background is sharp on Retina and normal screens.
tiffutil -cathidpicheck "$ROOT/Resources/DMG/background.png" "$ROOT/Resources/DMG/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# 2. A writable image, mounted where Finder can see it (no -nobrowse: Finder must open the window).
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -d "$MNT" ] || { echo "make-dmg: couldn't mount the writable image" >&2; exit 1; }
DISK="$(basename "$MNT")"

# 3. Window layout. Positions are icon centres, in points, inside a 660 x 400 content area.
if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "paneshare.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  # Give Finder time to write .DS_Store before the image is unmounted.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MNT/.DS_Store" ] && break; sleep 1; done
  [ -f "$MNT/.DS_Store" ] || echo "make-dmg: warning: Finder didn't save the window layout" >&2
else
  echo "make-dmg: warning: couldn't control Finder (Automation permission), so the DMG has no window layout" >&2
fi
# 4. Volume icon, after the layout: Finder's layout pass drops a .VolumeIcon.icns copied in earlier, and
#    hdiutil -srcfolder drops one in the staging folder. Then the Finder flag that says "use it".
cp "$ROOT/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
SetFile -a V "$MNT/.VolumeIcon.icns" "$MNT/.background"
SetFile -a C "$MNT"
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes"
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet
MNT=""

# 5. Compress to the read-only image that ships.
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null
echo "$OUT"
