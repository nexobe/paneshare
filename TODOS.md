# TODOS

## Files

### Pace file sends against video

**What:** Decide how file chunks give way to video when the host sends a file to a viewer.

**Why:** File chunks and video share one connection, and frames leave in order. Video is sent with `sendDroppable`, which drops a frame once 2 are queued. Up to 1 MiB of file data (4 × 256 KiB) can sit ahead of each frame. On a slow link this can stall the shared window for the length of a big send.

**Context:** Run TESTING I24 first: send a 1 GB file from host to viewer over a LAN and over Tailscale while moving the shared window, and record the debug overlay latency. If the lag is real, the choices are:
- send the next chunk only while no video frame is queued;
- cap file throughput at a share of the measured bandwidth;
- document the cost.

A smaller pacing window alone only lowers throughput. Code: `TLSMessageChannel.sendDroppable` (`Sources/PaneshareTransport/TLSMessageChannel.swift`), `FileSendPacer` and `FileTransferRules.windowChunks` (`Sources/PaneshareCore/Files/FileTransfer.swift`), `FileSender.pump`.

**Effort:** M
**Priority:** P2
**Depends on:** TESTING I24 results

## Release

### Homebrew cask

**What:** Publish a cask so users can run `brew install --cask paneshare`.

**Why:** Many Mac developers install tools through Homebrew; it also handles updates for people who don't use Sparkle.

**Context:** Deferred from the launch CEO review (E5): it needs a tap repo or a homebrew-cask PR, and that is outside the launch's scope. The notarized DMG URL and its SHA-256 (launch item E2) are the inputs.

**Effort:** M
**Priority:** P3
**Depends on:** Stable public DMG URLs (paneshare-releases)

### Issue and pull request templates

**What:** Add `.github/ISSUE_TEMPLATE/` (bug report with macOS version, both Macs' roles, network type) and a PR template that links CONTRIBUTING's rule on other products' code.

**Why:** Bug reports for a two-Mac app are useless without both sides' details.

**Context:** Deferred from the launch CEO review (E6).

**Effort:** S
**Priority:** P3
**Depends on:** The repo going public

## Completed
