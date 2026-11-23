#!/bin/bash
# One command for a release on the release Mac: build, sign, notarize and staple (release.sh), then
# publish to the feed repo and GitHub Releases (publish.sh). The keys never leave this Mac.
#
# Usage: scripts/ship.sh <version> [release-notes.md]
#   scripts/ship.sh 0.2.0                      uses docs/release-notes/0.2.0.md if it exists
# Every variable release.sh and publish.sh read can still be set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/ship.sh <version> [release-notes.md]}"
NOTES="${2:-$ROOT/docs/release-notes/$VERSION.md}"

export PANESHARE_VERSION="$VERSION"
export PANESHARE_FEED_URL="${PANESHARE_FEED_URL:-https://nexobe.github.io/paneshare-releases/appcast.xml}"
[ -f "$NOTES" ] && export PANESHARE_RELEASE_NOTES="$NOTES"

"$ROOT/scripts/release.sh"
"$ROOT/scripts/publish.sh" "$VERSION"
