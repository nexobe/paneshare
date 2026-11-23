#!/bin/bash
# Publishes a release that scripts/release.sh built: pushes the DMG, release notes and signed appcast to
# the GitHub Pages repo that serves the update feed, and creates a GitHub Release there with the DMG and
# its SHA-256 (docs/RELEASING.md §2 and §3, option A).
#
# Nothing is signed here and no key is read. It only uploads files release.sh already signed, after
# checking them again. It asks before it publishes anything.
#
# Usage: scripts/publish.sh <version>          e.g. scripts/publish.sh 0.2.0
# Optional environment:
#   PANESHARE_RELEASES_REPO   GitHub repo that serves the feed (default nexobe/paneshare-releases)
#   PANESHARE_UPDATES_DIR     release.sh's output folder (default build/updates)
#   PANESHARE_RELEASES_CLONE  local clone of the releases repo (default build/paneshare-releases)
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
REPO="${PANESHARE_RELEASES_REPO:-nexobe/paneshare-releases}"
UPDATES="${PANESHARE_UPDATES_DIR:-$ROOT/build/updates}"
CLONE="${PANESHARE_RELEASES_CLONE:-$ROOT/build/paneshare-releases}"
TEAM="${PANESHARE_TEAM_ID:-TV289JZ58M}"
TAG="v$VERSION"
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
grep -qF "/$DMG_NAME\"" "$FEED" || fail "appcast doesn't list $DMG_NAME"
SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
SIZE="$(du -h "$DMG" | cut -f 1)"
echo "$DMG_NAME  $SIZE  sha256 $SHA"

step "Checking $REPO"
gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null | grep -qx PUBLIC \
  || fail "$REPO doesn't exist or isn't public. Create it once:
  gh repo create $REPO --public --description 'paneshare releases and update feed'
then turn on Pages: Settings > Pages > deploy from branch main, folder / (docs/RELEASING.md §3)."
! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || fail "release $TAG already exists in $REPO"

echo
echo "This will publish paneshare $VERSION:"
echo "  - push $DMG_NAME, appcast.xml and its notes to $REPO (the live update feed)"
echo "  - create the GitHub Release $TAG in $REPO with the DMG attached"
echo "Installed copies that checked for updates will be offered $VERSION."
if [ "${PANESHARE_YES:-0}" != "1" ]; then
  read -r -p "Type 'publish $VERSION' to go on: " answer
  [ "$answer" = "publish $VERSION" ] || fail "stopped; nothing was published"
fi

step "Updating the feed repo"
if [ -d "$CLONE/.git" ]; then
  git -C "$CLONE" pull --ff-only --quiet
else
  rm -rf "$CLONE"
  gh repo clone "$REPO" "$CLONE" -- --quiet
fi
# Every DMG, notes file and the appcast, so the feed's older entries and deltas keep resolving.
rsync -a --include='*.dmg' --include='*.delta' --include='*.md' --include='*.html' --include='appcast.xml' \
  --exclude='*' "$UPDATES/" "$CLONE/"
touch "$CLONE/.nojekyll"
git -C "$CLONE" add -A
if git -C "$CLONE" diff --cached --quiet; then
  echo "feed repo already up to date"
else
  git -C "$CLONE" commit --quiet -m "paneshare $VERSION"
  git -C "$CLONE" push --quiet
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
gh release create "$TAG" "$DMG" -R "$REPO" --title "paneshare $VERSION" --notes-file "$BODY"

step "Done"
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "Feed:    https://${REPO%%/*}.github.io/${REPO#*/}/appcast.xml (Pages can take a minute to update)"
echo "SHA-256: $SHA"
