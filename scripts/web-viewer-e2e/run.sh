#!/bin/bash
# Development check of the share-link browser viewer (docs/TESTING.md §1.1). Runs on Linux, not part of
# the app: the Core test writes the exact HTTP responses, decoder config and video messages the host would
# send; server.py replays them over TLS with a WebCertificate; drive.py runs headless Chrome through the
# DevTools protocol and checks the page decodes video and follows the guest protocol.
# Needs: swift, ffmpeg (x264), Google Chrome, python3 with `websockets`.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR="${PANESHARE_E2E_DIR:-/tmp/paneshare-web-e2e}"
CHROME="${CHROME:-$(command -v google-chrome || command -v chrome || echo /usr/local/bin/chrome)}"
mkdir -p "$DIR"
rm -rf "$DIR/prof" "$DIR/inbound.log" "$DIR/cmd"
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x400:rate=30 -t 4 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -bf 0 -g 30 -x264-params slices=1:repeat-headers=1 -bsf:v h264_mp4toannexb -f h264 "$DIR/in.h264"
PANESHARE_E2E_DIR="$DIR" swift test --filter WebViewerFixtureTests
python3 scripts/web-viewer-e2e/server.py "$DIR" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1
python3 scripts/web-viewer-e2e/drive.py "$DIR" "$CHROME"
