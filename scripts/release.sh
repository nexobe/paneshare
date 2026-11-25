#!/bin/bash
# A signed, notarized paneshare release plus its Sparkle appcast, built on the release Mac
# (docs/RELEASING.md). Nothing is uploaded or published: the result is a folder to upload yourself.
#
# No secrets are read from the repository or the environment. The Developer ID identity lives in
# the login keychain, the notary credentials in the keychain (the `asc` CLI's App Store Connect API
# key profile, or a `notarytool store-credentials` profile), and Sparkle's EdDSA private key in the
# login keychain, where generate_appcast reads it.
#
# Required environment:
#   PANESHARE_FEED_URL        https URL of the appcast as users will fetch it, e.g.
#                            https://github.com/nexobe/paneshare/releases/latest/download/appcast.xml
#   PANESHARE_VERSION         marketing version, e.g. 0.2.0
# Signing and notarization (defaults are NEXOBE INC's release Mac):
#   PANESHARE_SIGN_IDENTITY   default "Developer ID Application: NEXOBE INC (TV289JZ58M)"
#   PANESHARE_TEAM_ID         default TV289JZ58M; every signature must carry it
#   PANESHARE_NOTARY_TOOL     asc (default): `asc notarization submit`, using asc's own keychain profile
#                            notarytool: `xcrun notarytool --keychain-profile "$PANESHARE_NOTARY_PROFILE"`
#   PANESHARE_NOTARY_PROFILE  notarytool keychain profile name (needed only with notarytool)
#   PANESHARE_NOTARY_TIMEOUT  how long to wait per submission (default 30m)
#   PANESHARE_ASC             path of the asc CLI (default: asc on PATH)
# Optional:
#   PANESHARE_BUILD_NUMBER        CFBundleVersion (default: commit count of HEAD); must grow every release
#   PANESHARE_DOWNLOAD_URL_PREFIX where the DMGs will be downloadable (default: the feed URL's folder)
#   PANESHARE_FEED_MAX_VERSIONS   keep only this many versions in the appcast (generate_appcast
#                                --maximum-versions); scripts/ship.sh sets 1
#   PANESHARE_UPDATES_DIR         local folder that keeps every released DMG and the appcast
#                                (default: build/updates); keep it between releases
#   PANESHARE_RELEASE_NOTES       Markdown file with this version's release notes
#   PANESHARE_ED_PUBLIC_KEY       skip reading the public key with `generate_keys -p`
#   PANESHARE_ALLOW_DIRTY=1       allow uncommitted changes
#   SPARKLE_BIN                  Sparkle's bin/ folder (default: the SwiftPM artifact)
#   PANESHARE_SKIP_DOCK_SELFTEST=1  skip launching a Dock helper from a quarantined copy of the DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/app.noindex/paneshare.app"
cd "$ROOT"
# shellcheck source=scripts/lib/launchservices.sh
. "$ROOT/scripts/lib/launchservices.sh"

fail() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || fail "run this on a Mac"
PANESHARE_TEAM_ID="${PANESHARE_TEAM_ID:-TV289JZ58M}"
PANESHARE_SIGN_IDENTITY="${PANESHARE_SIGN_IDENTITY:-Developer ID Application: NEXOBE INC ($PANESHARE_TEAM_ID)}"
NOTARY_TOOL="${PANESHARE_NOTARY_TOOL:-asc}"
NOTARY_TIMEOUT="${PANESHARE_NOTARY_TIMEOUT:-30m}"
ASC="${PANESHARE_ASC:-asc}"
: "${PANESHARE_FEED_URL:?set PANESHARE_FEED_URL (https URL of appcast.xml)}"
: "${PANESHARE_VERSION:?set PANESHARE_VERSION (e.g. 0.2.0)}"

[[ "$PANESHARE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "PANESHARE_TEAM_ID must be a 10-character Apple Team ID"
case "$PANESHARE_SIGN_IDENTITY" in
  "Developer ID Application:"*"($PANESHARE_TEAM_ID)") ;;
  *) fail "PANESHARE_SIGN_IDENTITY must be a Developer ID Application identity of team $PANESHARE_TEAM_ID" ;;
esac
case "$NOTARY_TOOL" in
  asc) ;;
  notarytool) : "${PANESHARE_NOTARY_PROFILE:?set PANESHARE_NOTARY_PROFILE (notarytool keychain profile name)}" ;;
  *) fail "PANESHARE_NOTARY_TOOL must be asc or notarytool" ;;
esac
[[ "$NOTARY_TIMEOUT" =~ ^[0-9]+[smh]?$ ]] || fail "PANESHARE_NOTARY_TIMEOUT must look like 30m, 1h or 900"
case "$PANESHARE_FEED_URL" in
  https://*/*.xml) ;;
  *) fail "PANESHARE_FEED_URL must be an https:// URL ending in .xml" ;;
esac
[[ "$PANESHARE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "PANESHARE_VERSION must look like 1.2 or 1.2.3"
BUILD_NUMBER="${PANESHARE_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "PANESHARE_BUILD_NUMBER must be an integer"
if [ -n "$(git status --porcelain)" ] && [ "${PANESHARE_ALLOW_DIRTY:-0}" != "1" ]; then
  fail "uncommitted changes; commit them or set PANESHARE_ALLOW_DIRTY=1"
fi
[ "$(uname -m)" = "arm64" ] || echo "release: warning: building on $(uname -m); the release is for this architecture only" >&2

FEED_NAME="$(basename "$PANESHARE_FEED_URL")"
DOWNLOAD_PREFIX="${PANESHARE_DOWNLOAD_URL_PREFIX:-${PANESHARE_FEED_URL%/*}/}"
case "$DOWNLOAD_PREFIX" in
  https://*/) ;;
  *) fail "PANESHARE_DOWNLOAD_URL_PREFIX must be an https:// URL ending in /" ;;
esac
UPDATES="${PANESHARE_UPDATES_DIR:-$ROOT/build/updates}"
DMG_NAME="paneshare-$PANESHARE_VERSION.dmg"
[ ! -e "$UPDATES/$DMG_NAME" ] || fail "$UPDATES/$DMG_NAME already exists; bump PANESHARE_VERSION"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/paneshare-release.XXXXXX")"
# Every app bundle this script stages lives under here, so none shows up in Spotlight or Launchpad.
APPS="$WORK/apps.noindex"
SELFTEST_APP=""
cleanup() {
  unregister_apps "$WORK" "$SELFTEST_APP" "$APP"
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Checking tools and identity"
security find-identity -v -p codesigning | grep -qF "\"$PANESHARE_SIGN_IDENTITY\"" \
  || fail "identity not found in the keychain: $PANESHARE_SIGN_IDENTITY"
if [ "$NOTARY_TOOL" = "asc" ]; then
  command -v "$ASC" >/dev/null || fail "asc CLI not found (set PANESHARE_ASC, or PANESHARE_NOTARY_TOOL=notarytool)"
else
  xcrun --find notarytool >/dev/null || fail "notarytool missing (install Xcode 14+)"
fi
echo "notarizing with $NOTARY_TOOL"
xcrun --find stapler >/dev/null || fail "stapler missing (install Xcode)"
swift package resolve
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
[ -x "$SPARKLE_BIN/generate_appcast" ] || fail "generate_appcast not found in $SPARKLE_BIN"
PUBLIC_KEY="${PANESHARE_ED_PUBLIC_KEY:-$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)}"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "no Sparkle EdDSA key in the Keychain (run generate_keys once; see docs/RELEASING.md)"

step "Release build $PANESHARE_VERSION ($BUILD_NUMBER), signed with the hardened runtime"
PANESHARE_SIGN_IDENTITY="$PANESHARE_SIGN_IDENTITY" PANESHARE_FEED_URL="$PANESHARE_FEED_URL" \
  PANESHARE_ED_PUBLIC_KEY="$PUBLIC_KEY" PANESHARE_VERSION="$PANESHARE_VERSION" PANESHARE_BUILD_NUMBER="$BUILD_NUMBER" \
  "$ROOT/scripts/make-app.sh" release

step "Checking signatures"
FW="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$APP" "$APP/Contents/Helpers/paneshare-dock-helper" "$FW" "$FW/Versions/B/Autoupdate" \
            "$FW/Versions/B/Updater.app" "$FW/Versions/B/XPCServices/Installer.xpc" \
            "$FW/Versions/B/XPCServices/Downloader.xpc"; do
  details="$(codesign -d --verbose=2 "$code" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$details" || fail "not Developer ID signed: $code"
  grep -qx "TeamIdentifier=$PANESHARE_TEAM_ID" <<<"$details" || fail "not signed by team $PANESHARE_TEAM_ID: $code"
  grep -q "Timestamp=" <<<"$details" || fail "no secure timestamp: $code"
  grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" <<<"$details" || fail "hardened runtime not enabled: $code"
done
codesign --verify --deep --strict --verbose=2 "$APP"

# The first of these JSON paths that exists: top level (notarytool, asc) or the Notary API's shape.
json_field() {
  local file="$1" path
  shift
  for path in "$@"; do
    plutil -extract "$path" raw -o - "$file" 2>/dev/null && return 0
  done
  return 1
}

notarize() {
  local file="$1" out status id
  out="$WORK/notary-$(basename "$file").json"
  if [ "$NOTARY_TOOL" = "asc" ]; then
    "$ASC" notarization submit --file "$file" --wait --timeout "$NOTARY_TIMEOUT" --output json >"$out" || true
  else
    xcrun notarytool submit "$file" --keychain-profile "$PANESHARE_NOTARY_PROFILE" --wait --timeout "$NOTARY_TIMEOUT" \
      --output-format json >"$out" || true
  fi
  status="$(json_field "$out" status data.attributes.status ||
            sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$out" | head -n 1)"
  id="$(json_field "$out" id data.id || true)"
  if [ "$status" != "Accepted" ]; then
    echo "release: notarization of $(basename "$file") with $NOTARY_TOOL returned: ${status:-no status}" >&2
    cat "$out" >&2 || true
    if [ -n "$id" ] && [ "$NOTARY_TOOL" = "notarytool" ]; then
      xcrun notarytool log "$id" --keychain-profile "$PANESHARE_NOTARY_PROFILE" >&2 || true
    elif [ -n "$id" ]; then
      echo "release: submission $id; Apple's log for it explains each rejected file" >&2
    fi
    exit 1
  fi
  echo "notarized $(basename "$file") with $NOTARY_TOOL (submission ${id:-?})"
}

step "Notarizing and stapling the app"
ditto -c -k --keepParent "$APP" "$WORK/paneshare.zip"
notarize "$WORK/paneshare.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

step "Building, signing, notarizing and stapling the disk image"
DMG="$WORK/$DMG_NAME"
# Styled window (background, arrow, icon positions) and the app icon as the volume icon.
# Finder lays the window out, so the first run asks to let this terminal control Finder.
"$ROOT/scripts/dmg/make-dmg.sh" "$APP" "$DMG" "paneshare $PANESHARE_VERSION"
codesign --force --sign "$PANESHARE_SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

if [ "${PANESHARE_SKIP_DOCK_SELFTEST:-0}" != "1" ]; then
  step "Dock helper self-test from a quarantined install (what a downloaded copy on another Mac does)"
  ! pgrep -x paneshare >/dev/null || fail "quit paneshare first (or set PANESHARE_SKIP_DOCK_SELFTEST=1)"
  QUARANTINE="0081;$(printf '%x' "$(date +%s)");paneshare-release;$(uuidgen)"
  mkdir -p "$WORK/download" "$WORK/mnt" "$APPS/install"
  cp "$DMG" "$WORK/download/$DMG_NAME"
  xattr -w com.apple.quarantine "$QUARANTINE" "$WORK/download/$DMG_NAME"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$WORK/mnt" "$WORK/download/$DMG_NAME" >/dev/null
  ditto "$WORK/mnt/paneshare.app" "$APPS/install/paneshare.app"
  unregister_apps "$WORK/mnt/paneshare.app"
  hdiutil detach "$WORK/mnt" -quiet
  # A browser and Finder mark every file of a downloaded app; do the same so nothing depends on
  # how this Mac propagates the flag.
  xattr -r -w com.apple.quarantine "$QUARANTINE" "$APPS/install/paneshare.app"
  spctl -a -vv -t exec "$APPS/install/paneshare.app"
  echo "If macOS asks whether to open paneshare (downloaded from the Internet), click Open."
  RESULT="$WORK/dock-selftest.txt"
  open -W -n "$APPS/install/paneshare.app" --args --dock-helper-selftest "$RESULT" || true
  cat "$RESULT" 2>/dev/null || true
  # The copy runs translocated (quarantined, not moved by Finder); that path gets registered too.
  SELFTEST_APP="$(sed -n 's/^app: //p' "$RESULT" 2>/dev/null | head -n 1)"
  grep -q "^dock-helper-selftest: PASS" "$RESULT" 2>/dev/null \
    || fail "a Dock helper didn't launch from the quarantined install (docs/RELEASING.md §5); nothing was published"
fi

step "Updating the appcast"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/$DMG_NAME"
if [ -n "${PANESHARE_RELEASE_NOTES:-}" ]; then
  [ -f "$PANESHARE_RELEASE_NOTES" ] || fail "release notes not found: $PANESHARE_RELEASE_NOTES"
  cp "$PANESHARE_RELEASE_NOTES" "$UPDATES/paneshare-$PANESHARE_VERSION.md"
fi
# Signs each archive and, because the app sets SURequireSignedFeed, the feed and release notes too,
# with the EdDSA key from the Keychain (macOS may ask to allow Keychain access).
APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_PREFIX")
[ -n "${PANESHARE_FEED_MAX_VERSIONS:-}" ] && APPCAST_ARGS+=(--maximum-versions "$PANESHARE_FEED_MAX_VERSIONS")
"$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}" -o "$UPDATES/$FEED_NAME" "$UPDATES"
grep -q "sparkle:edSignature" "$UPDATES/$FEED_NAME" || fail "appcast has no EdDSA signatures"
grep -qF "$DOWNLOAD_PREFIX$DMG_NAME" "$UPDATES/$FEED_NAME" || fail "appcast doesn't list $DMG_NAME"

step "Done"
echo "App:      $APP (stapled)"
echo "DMG:      $UPDATES/$DMG_NAME (signed, notarized, stapled)"
echo "SHA-256:  $(shasum -a 256 "$UPDATES/$DMG_NAME" | cut -d ' ' -f 1)  (publish.sh puts it in the GitHub Release body)"
echo "Appcast:  $UPDATES/$FEED_NAME"
echo
echo "Nothing was uploaded. Upload the new and changed files in $UPDATES so that"
echo "  $PANESHARE_FEED_URL"
echo "  ${DOWNLOAD_PREFIX}$DMG_NAME"
echo "resolve (docs/RELEASING.md, \"Hosting the feed\"). Keep $UPDATES for the next release."
