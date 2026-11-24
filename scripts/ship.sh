#!/bin/bash
# One command for a release on the release Mac: build, sign, notarize and staple (release.sh), then
# publish a GitHub Release with the DMG and the update feed (publish.sh). The keys never leave this Mac.
#
# Usage: scripts/ship.sh <version> [release-notes.md]
#   scripts/ship.sh 0.2.0                      uses docs/release-notes/0.2.0.md if it exists
# Every variable release.sh and publish.sh read can still be set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/ship.sh <version> [release-notes.md]}"
NOTES="${2:-$ROOT/docs/release-notes/$VERSION.md}"

export PANESHARE_VERSION="$VERSION"
# The feed and every download are assets of the GitHub Release vX.Y.Z on the source repo. "latest/download"
# always resolves to the newest release, so the feed URL never changes. Each release's appcast lists only that
# release (plus deltas to it), because every file in it shares the one download prefix.
export PANESHARE_FEED_URL="${PANESHARE_FEED_URL:-https://github.com/nexobe/paneshare/releases/latest/download/appcast.xml}"
export PANESHARE_DOWNLOAD_URL_PREFIX="${PANESHARE_DOWNLOAD_URL_PREFIX:-https://github.com/nexobe/paneshare/releases/download/v$VERSION/}"
export PANESHARE_FEED_MAX_VERSIONS="${PANESHARE_FEED_MAX_VERSIONS:-1}"
[ -f "$NOTES" ] && export PANESHARE_RELEASE_NOTES="$NOTES"

"$ROOT/scripts/release.sh"
"$ROOT/scripts/publish.sh" "$VERSION"
