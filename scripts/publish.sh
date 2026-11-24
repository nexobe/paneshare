#!/bin/bash
# Publishes a release that scripts/release.sh built: creates the GitHub Release vX.Y.Z on the source repo with
# the DMG, its release notes, its delta updates and the signed appcast as assets (docs/RELEASING.md §2 and §3).
# Installed copies read the feed at https://github.com/<repo>/releases/latest/download/appcast.xml, so the
# newest release is always the live feed.
#
# Nothing is signed here and no key is read. It only uploads files release.sh already signed, after
# checking them again. It asks before it publishes anything.
#
# Usage: scripts/publish.sh <version>          e.g. scripts/publish.sh 0.2.0
# Optional environment:
#   PANESHARE_REPO            GitHub repo to publish to (default nexobe/paneshare)
#   PANESHARE_UPDATES_DIR     release.sh's output folder (default build/updates)
#   PANESHARE_TEAM_ID         team every signature must carry (default TV289JZ58M)
#   PANESHARE_YES=1           don't ask for confirmation
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "publish: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

VERSION="${1:-${PANESHARE_VERSION:-}}"
[ -n "$VERSION" ] || fail "usage: scripts/publish.sh <version>"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "version must look like 1.2 or 1.2.3"
REPO="${PANESHARE_REPO:-nexobe/paneshare}"
UPDATES="${PANESHARE_UPDATES_DIR:-$ROOT/build/updates}"
TEAM="${PANESHARE_TEAM_ID:-TV289JZ58M}"
TAG="v$VERSION"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
DMG_NAME="paneshare-$VERSION.dmg"
DMG="$UPDATES/$DMG_NAME"
FEED="$UPDATES/appcast.xml"
NOTES="$UPDATES/paneshare-$VERSION.md"

[ "$(uname -s)" = "Darwin" ] || fail "run this on a Mac"
command -v gh >/dev/null || fail "gh CLI not found"
gh auth status >/dev/null 2>&1 || fail "gh isn't signed in (gh auth login)"

step "Checking the release files"
[ -f "$DMG" ] || fail "$DMG not found; run scripts/release.sh first"
[ -f "$FEED" ] || fail "$FEED not found; run scripts/release.sh first"
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG_NAME has no stapled notarization ticket"
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rejects $DMG_NAME"
# Read codesign's output first: grep -q exits early, and pipefail would count codesign's SIGPIPE as a failure.
SIGNING="$(codesign -dv --verbose=2 "$DMG" 2>&1)" || fail "can't read the signature of $DMG_NAME"
grep -qx "TeamIdentifier=$TEAM" <<<"$SIGNING" || fail "$DMG_NAME isn't signed by team $TEAM"
grep -q "sparkle:edSignature" "$FEED" || fail "appcast has no EdDSA signatures"
grep -qF "$PREFIX$DMG_NAME\"" "$FEED" \
  || fail "appcast doesn't point at $PREFIX$DMG_NAME; build with scripts/ship.sh, which sets the download prefix"

# Upload exactly the files the appcast points at (DMG, notes, deltas), plus the appcast itself.
ASSETS=()
while IFS= read -r url; do
  case "$url" in
    "$PREFIX"*) name="${url#"$PREFIX"}" ;;
    *) fail "appcast points outside this release: $url" ;;
  esac
  [ -f "$UPDATES/$name" ] || fail "appcast lists $name, but $UPDATES/$name is missing"
  ASSETS+=("$UPDATES/$name")
done < <(grep -oE 'https://[^"<> ]+' "$FEED" | sort -u)
ASSETS+=("$FEED")
SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
echo "$DMG_NAME  $(du -h "$DMG" | cut -f 1)  sha256 $SHA"
printf '  %s\n' "${ASSETS[@]##*/}"

step "Checking $REPO"
gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null | grep -qx PUBLIC \
  || fail "$REPO doesn't exist or isn't public"
! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || fail "release $TAG already exists in $REPO"
COMMIT="$(git rev-parse HEAD)"
git fetch --quiet origin
git merge-base --is-ancestor "$COMMIT" "origin/$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)" \
  || fail "HEAD ($COMMIT) isn't pushed; push it first so the tag points at published code"

echo
echo "This will publish paneshare $VERSION:"
echo "  - create the GitHub Release $TAG in $REPO at commit ${COMMIT:0:7}, marked latest"
echo "  - attach the DMG, notes, deltas and appcast.xml (the live update feed)"
echo "Installed copies that check for updates will be offered $VERSION."
if [ "${PANESHARE_YES:-0}" != "1" ]; then
  read -r -p "Type 'publish $VERSION' to go on: " answer
  [ "$answer" = "publish $VERSION" ] || fail "stopped; nothing was published"
fi

step "Creating the GitHub Release $TAG"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
{
  # Drop Sparkle's signing comment and the title; the release has its own title.
  if [ -f "$NOTES" ]; then sed '/^<!-- sparkle-sign-warning:/,/^-->/d' "$NOTES" | sed '1{/^# /d;}'; echo; fi
  echo "## Verify this download"
  echo
  echo "SHA-256 of \`$DMG_NAME\`:"
  echo
  echo "\`\`\`"
  echo "$SHA"
  echo "\`\`\`"
  echo
  echo "\`\`\`bash"
  echo "shasum -a 256 $DMG_NAME"
  echo "spctl -a -vv -t open --context context:primary-signature $DMG_NAME   # source=Notarized Developer ID"
  echo "\`\`\`"
  echo
  echo "Signed with Developer ID by NEXOBE INC (team \`$TEAM\`) and notarized by Apple."
} >"$BODY"
gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --target "$COMMIT" --latest \
  --title "paneshare $VERSION" --notes-file "$BODY"

step "Done"
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "Feed:    https://github.com/$REPO/releases/latest/download/appcast.xml"
echo "SHA-256: $SHA"
