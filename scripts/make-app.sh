#!/bin/bash
# Builds paneshare.app from the SwiftPM products. A stable bundle (same path, same bundle ID) keeps
# the Screen Recording and Accessibility grants across rebuilds better than the bare binary.
#
#   scripts/make-app.sh            # release build into build/app.noindex/paneshare.app, ad hoc signed
#   scripts/make-app.sh debug      # debug build
#   scripts/make-app.sh unregister # only drop build copies from LaunchServices (after `open`ing one)
#
# Build copies stay out of Spotlight, Launchpad and "Open With" (scripts/lib/launchservices.sh):
# the bundle lives in a *.noindex folder and is unregistered from LaunchServices when done.
# Opening it registers it again until the next build or `unregister`.
#
# Build settings, all optional (scripts/release.sh sets them; see docs/RELEASING.md):
#   PANESHARE_SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
#                            Default "-" (ad hoc). A real identity signs everything with the
#                            hardened runtime and a secure timestamp.
#   PANESHARE_FEED_URL        Sparkle appcast URL, written as SUFeedURL. Without it the app never
#                            checks for updates.
#   PANESHARE_ED_PUBLIC_KEY   Sparkle EdDSA public key (SUPublicEDKey). Public by design; the
#                            private key never leaves the release Mac's Keychain.
#   PANESHARE_VERSION         CFBundleShortVersionString, e.g. 0.2.0
#   PANESHARE_BUILD_NUMBER    CFBundleVersion; Sparkle needs it to grow with every release.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/app.noindex/paneshare.app"
IDENTITY="${PANESHARE_SIGN_IDENTITY:--}"
# shellcheck source=scripts/lib/launchservices.sh
. "$ROOT/scripts/lib/launchservices.sh"

hide_from_spotlight "$ROOT/build"
# Every earlier build copy, including hand-made ones such as build/release/paneshare.app.
unregister_apps "$ROOT/build"
if [ "$CONFIG" = "unregister" ]; then
  echo "Unregistered the app bundles under $ROOT/build from LaunchServices"
  exit 0
fi
# Where this script used to put the bundle (indexed); it's rebuilt below.
rm -rf "$ROOT/build/paneshare.app"

cd "$ROOT"
swift build -c "$CONFIG" --product paneshare
swift build -c "$CONFIG" --product paneshare-dock-helper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN_DIR/paneshare" "$APP/Contents/MacOS/paneshare"

PLIST="$APP/Contents/Info.plist"
cp "$ROOT/Sources/PaneshareApp/Info.plist" "$PLIST"
if [ -n "${PANESHARE_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$PANESHARE_VERSION" "$PLIST"
fi
if [ -n "${PANESHARE_BUILD_NUMBER:-}" ]; then
  plutil -replace CFBundleVersion -string "$PANESHARE_BUILD_NUMBER" "$PLIST"
fi
if [ -n "${PANESHARE_FEED_URL:-}" ]; then
  case "$PANESHARE_FEED_URL" in
    https://*) ;;
    *) echo "PANESHARE_FEED_URL must be an https:// URL" >&2; exit 1 ;;
  esac
  if [ -z "${PANESHARE_ED_PUBLIC_KEY:-}" ]; then
    echo "PANESHARE_FEED_URL needs PANESHARE_ED_PUBLIC_KEY (bin/generate_keys -p)" >&2
    exit 1
  fi
  plutil -replace SUFeedURL -string "$PANESHARE_FEED_URL" "$PLIST"
  plutil -replace SUPublicEDKey -string "$PANESHARE_ED_PUBLIC_KEY" "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null

# Rendered from Resources/Icon/*.svg by scripts/icon/build-icon.sh; Info.plist names it (CFBundleIconFile).
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The template for per-app Dock helpers. The app copies it into each generated helper bundle and
# re-signs that copy itself, in process; this signature only covers the template inside the app.
HELPER="$APP/Contents/Helpers/paneshare-dock-helper"
cp "$BIN_DIR/paneshare-dock-helper" "$HELPER"
# AdHocSigner handles one architecture per file; a universal template would disable Dock helpers.
if ! lipo -info "$HELPER" | grep -q "Non-fat"; then
  echo "paneshare-dock-helper must be a single-architecture binary (got: $(lipo -archs "$HELPER"))" >&2
  exit 1
fi
# ditto keeps the framework's symlinks and permissions, which Sparkle and codesign rely on.
if [ ! -d "$BIN_DIR/Sparkle.framework" ]; then
  echo "Sparkle.framework not found in $BIN_DIR (run swift package resolve)" >&2
  exit 1
fi
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's MIT license and its bundled bsdiff, sais-lite and ed25519 notices must travel with the binary.
SPARKLE_LICENSE="$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE"
if [ ! -f "$SPARKLE_LICENSE" ]; then
  echo "Sparkle LICENSE not found at $SPARKLE_LICENSE (run swift package resolve)" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"
# The six files adapted from Sill stay under Apache-2.0 (THIRD_PARTY.md), and Apache-2.0 4(a) requires its
# text to ship with the binary. Sill ships no NOTICE file, so there is none to copy.
cp "$ROOT/LICENSES/Apache-2.0.txt" "$APP/Contents/Resources/Licenses/Apache-2.0.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/paneshare-MIT.txt"

if [ "$IDENTITY" = "-" ]; then
  # Ad hoc: no Apple account needed, and Gatekeeper doesn't assess a bundle built locally. Sparkle
  # keeps its upstream ad hoc signatures. No hardened runtime: its library validation would refuse
  # an ad hoc framework.
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
  # Inside out, as Sparkle documents for signing outside Xcode; never --deep.
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
  "${SIGN[@]}" "$FW/Versions/B/Updater.app"
  "${SIGN[@]}" "$FW"
fi
"${SIGN[@]}" --identifier dev.paneshare.dock-helper "$HELPER"
"${SIGN[@]}" --entitlements "$ROOT/Sources/PaneshareApp/paneshare.entitlements" --identifier dev.paneshare.app "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
unregister_apps "$APP"

echo "Built $APP"
echo "Run it with: open \"$APP\""
