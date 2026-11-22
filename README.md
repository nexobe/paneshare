# paneshare

Share individual macOS windows between Macs as native windows. Clean-room and open source (MIT), by NEXOBE.

Pick a window on one Mac (the **host**). It opens on another Mac (the **viewer**) as a real `NSWindow` with
the source window's title, sharp at the viewer's backing scale. You can click, type, scroll and resize it.
Resizing the viewer window resizes the source window. Each remote app gets its own Dock icon and
Command-Tab entry. Traffic is end-to-end encrypted and mutually authenticated between paired Macs. There's no
server, account or relay. Someone without paneshare can also view one window in a browser through a share link
(same LAN or tailnet), with their own pointer.

## How this started

On November 4, 2026, Asghar Ali (NEXOBE) wanted a way to use a window from one Mac on another, as a
real window instead of a whole-screen share. The question was simple: could we build our own, clean-room, in a day?

paneshare is built clean-room. The spec ([`docs/SPEC.md`](docs/SPEC.md)) was written only from public information:
product pages, docs, pricing and observed behaviour. No other product's
code, binaries or assets were used. The code was written by AI coding agents (Cursor cloud agents on Claude Opus)
driven by gstack, Asghar's virtual product and engineering team, against that spec.

What happened, in order, all on Nov 4, 2026:

1. **Spec and architecture.** A study of public sources and of open-source building blocks,
   then [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components, wire protocol v1, threat model, latency
   budget and test plan.
2. **MVP.** Window picker, per-window capture, HEVC/H.264 encode and decode, native viewer windows, input
   forwarding, resize, Bonjour discovery and mutual-TLS pairing. The first Mac build hit macOS 15 SDK errors
   (CGRect moving into CoreGraphics), which were fixed, and then the **first two-Mac test worked**.
3. **Feedback round.** Text wasn't crisp, and pairing was awkward. Capture now runs at the viewer's backing scale,
   and pairing v2 lets the viewer ask while the host gets a prompt automatically.
4. **Filling the feature gaps.** Per-app audio, a virtual display for headless hosts and oversized windows,
   and browser share links.
5. **Ship-ready.** An app icon, Sparkle 2 auto-update and `scripts/release.sh`. A Developer ID Application
   certificate was issued to NEXOBE INC (TV289JZ58M), and builds are signed, notarized with `asc` and stapled.
   Build copies were kept out of Spotlight, and two macOS 27 SDK clashes were fixed (Network's new `WebSocket`
   type, and `CATapDescription` taking `[AudioObjectID]`).

## Status

**Working MVP, notarized.** As of Nov 4, 2026, commit `3569e42` builds with 0 errors on Xcode 27 (macOS 27 SDK).
It's signed with Developer ID, notarized by Apple (Accepted), stapled and passes Gatekeeper. It's installed on
Asghar's MacBook Pro.

- **Proven on real Macs:** discovery, pairing (v1), and streaming and controlling windows between two Macs.
  Sharp text and pairing v2 were built and installed. They still need a test against a second Mac running this build.
- **Built but not yet tested on two Macs:** app audio, the virtual display, share links, Dock helpers from a
  downloaded copy, and auto-update.
- **Not live yet:** auto-update needs a public host for the update feed (for example GitHub Pages). It isn't set up,
  so installed builds don't check for updates.
- **License:** MIT (see [`LICENSE`](LICENSE)). It isn't for the Mac App
  Store: it uses a private virtual-display API and controls other apps' input, so it ships as a notarized DMG.
- **Unit tests:** the platform-neutral core (`PaneshareCore`) passes 175 tests on Swift 6.0.3 and 6.2.3 on Linux
  and 176 on Xcode 27. GitHub Actions is disabled on the repo, so CI doesn't run. The manual plan is in [`docs/TESTING.md`](docs/TESTING.md).

### Component status

| Area | State |
| --- | --- |
| Window list (ScreenCaptureKit; our own windows, password managers, system password prompts and hidden apps excluded) | Run on two Macs. Policy unit-tested. |
| Per-window capture at the viewer's backing scale × a quality setting | Capture run on two Macs; viewer-scale sharpness not retested. Sizing unit-tested. |
| HEVC / H.264 low-latency encode, with fallback and recovery | Run on two Macs; fallback and recovery not confirmed. |
| Keep the host awake (system and display idle sleep) while any stream is live | Written, not run. Hold counting unit-tested. |
| Clipboard sync: plain text up to 1 MB, off by default, both Macs opt in, only while a remote window is in front, skips items marked private | Written, not run. Rules unit-tested. |
| File drop: single files up to 2 GB from viewer to host, off by default, saved to `Downloads/paneshare` with a digest check and quarantine. It doesn't drop the file into the app itself. | Written, not run. Name safety, digest and pacing unit-tested. |
| Send files from host to viewer: **Send Files…** or a drop on the viewer's row; the viewer must turn on its own setting (off by default) and have one of the host's windows open. Same limits, folder and checks as file drop. If that Mac doesn't answer in 15 s, the send stops. A host you connect to can send you files at any time while one of its windows is open on your Mac, after you turn the setting on. | Written, not run. Offer timeout unit-tested. |
| Whole screen offers, off until ticked; **Open every screen** opens each in its own window, not one combined picture; rejected apps are left out and rechecked every 2 s | Written, not run. IDs and wire field unit-tested. |
| Hardware decode into a native window titled after the source | Run on two Macs |
| Bonjour discovery, plus pairing by address (Tailscale) | Bonjour run on two Macs; pairing by address not confirmed. |
| TLS 1.3, mutual, SPKI-pinned; pairing requested from the viewer and accepted on the host with a 6-digit code and a PAKE | Written. PAKE, gate and request limiter unit-tested; v1 pairing worked on two Macs, v2 not yet run. |
| Key, mouse and scroll forwarding; host injects CGEvents after raising; typing pauses on secure input | Control run on two Macs; secure-input pause not confirmed. Coordinate mapping and input gate unit-tested. |
| Resize from the viewer, applied on the host via Accessibility, stream size frozen during the drag | Written. Sizing unit-tested. |
| Onboarding for Screen Recording and Accessibility | Run on macOS 27.2. macOS doesn't add the app to the Screen Recording list by itself, so the user adds it with +. |
| Dock / Command-Tab: one entry per remote app via a generated, ad hoc signed helper app | Written, not run. Bundle plan, signer, seal, ledger and link unit-tested. |
| Fallback: one paneshare icon that follows the focused remote app | Written, not run |
| Per-app audio: process tap (macOS 14.2+) or ScreenCaptureKit, AAC-ELD, per-app mute and volume on the viewer, off for excluded apps | Written, not run. Jitter buffer, timeline, policy and mix settings unit-tested. |
| Virtual display for headless hosts and windows bigger than the host's screen (setting: Off / When needed / Always) | Written, not run. Planner and type-encoding checks unit-tested. Uses a private API (risk 9). |
| Share links: one window in a browser over LAN or Tailscale (HTTPS, self-signed, one-time token, WebCodecs H.264), view-only by default with a revocable pointer-and-click switch, expiry, guest list and kick | Written; Swift side not run. Web stack and link store unit-tested; page checked in headless Chrome. |
| App icon (original vector art, every size) and Dock helper icons with a ring in the source Mac's colour | Built. Icon rendered and checked at 16–1024 px; helper layout unit-tested, AppKit drawing not run. |
| Auto-update (Sparkle 2, EdDSA-signed feed and archives, daily checks after first-launch consent) and a signed, notarized DMG release (`scripts/release.sh`) | Written, not run. Update configuration and consent unit-tested; release script dry-run on Linux with stub tools. A hand-signed fb88767 DMG was notarized (`asc`, Accepted) and passed `spctl`; helpers launching from a downloaded copy on a second Mac is the open check (RELEASING §5, `--dock-helper-selftest`). |

## Build

Requirements: macOS 14+, Xcode 15.3+ (Swift 5.10+).

```bash
swift test                  # core unit tests (also on Linux)
scripts/make-app.sh         # build/app.noindex/paneshare.app, ad hoc signed
open build/app.noindex/paneshare.app
```

Build copies stay out of Spotlight, Launchpad and "Open With": the bundle sits in a `*.noindex` folder and is
unregistered from LaunchServices after each build, so only an installed copy in `/Applications` is listed.
Opening a build copy registers it again; `scripts/make-app.sh unregister` drops it (and any other bundle under
`build/`).

Or open `Package.swift` in Xcode. To test permissions, use the bundle from `make-app.sh` (see TESTING §2).

The app icon is original artwork: vector sources in `Resources/Icon/` (`paneshare.svg` for 64 px and up, and a
simplified `paneshare-small.svg` for 16 and 32 px, both on the macOS 824/1024 superellipse grid). After editing
them, run `scripts/icon/build-icon.sh` (needs `rsvg-convert`) to regenerate `Resources/AppIcon.icns`, which
`make-app.sh` copies into the bundle. Dock helpers get the remote app's icon inside a ring in the source Mac's
colour (ARCHITECTURE §6.2).

**Releases** (Developer ID signed, notarized DMG, Sparkle appcast) are made on the release Mac with
`scripts/release.sh` (signs as NEXOBE INC, team TV289JZ58M, and notarizes with `asc` by default); one-time setup,
the exact commands and where to host the feed are in
[`docs/RELEASING.md`](docs/RELEASING.md). Local builds have no update feed and never check for updates.

## Use

1. **Host:** grant Screen Recording and Accessibility when onboarding asks. If paneshare isn't in the Screen
   Recording list, click + and choose it from Applications. Go to **Share**, turn sharing on,
   and tick the windows you want to offer.
2. **Viewer:** go to **Connect** and click **Pair** next to the host (or **Pair by address** for Tailscale). It
   shows a 6-digit code.
3. **Host:** a prompt pops up: "“<viewer>” wants to pair with this Mac". Type the code from the viewer and click
   **Accept**, or **Decline**.
4. **Viewer:** choose **Open** next to a window. It gets a Dock icon named "<App> on <Host>". The app's sound
   plays too; each open app gets a mute button and a volume slider under the host. The host can turn sound off
   for all apps or per app in **Windows to share** (the first time, macOS asks to allow System Audio Recording).
5. **Browser guest (optional):** on the host, click the link icon next to a shared window, pick how long it lasts
   and whether the guest may point and click, and send one of the URLs. The guest opens it in Safari, Chrome, Edge
   or Firefox on the same network or tailnet, accepts the certificate warning (the sheet shows its fingerprint to
   compare), and types a name. The host panel lists links and guests, with **Pointer**, **Revoke** and **Kick**.

## How it works

One app with two roles, in small SwiftPM modules: `PaneshareCore` (pure and tested), plus `Capture`,
`Encode`, `Decode`, `Audio`, `Transport`, `Discovery`, `Input`, `Viewer`, `DockLink`, the `paneshare-dock-helper`
executable and the SwiftUI `App`. The host captures one
window with `SCStream` at the viewer's pixel density and encodes it in real time with VideoToolbox (one frame in
flight, drop rather than queue). It sends access units over a TLS 1.3 connection with ALPN `paneshare/1`. The
viewer feeds them to `AVSampleBufferDisplayLayer` in an `NSWindow`. Input travels back as normalized
coordinates and is injected with CGEvents after the window is raised. Resizes go through Accessibility. For each
remote app the viewer writes a tiny helper `.app`, signs it ad hoc in process, and launches it; the helper only
forwards Dock clicks, Command-Tab activation, its Dock menu and quit to the main app over a verified local socket.
Each shared app's sound is captured with a Core Audio process tap, encoded as AAC-ELD, and played through a
40 ms jitter buffer on the viewer, timestamped on the same host clock as the video. Share links run a second,
HTTPS-only listener on TCP 47822 while a link exists; the browser page decodes the same H.264 with WebCodecs.

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). That covers how the design maps to the functional spec
([`docs/SPEC.md`](docs/SPEC.md)), the wire protocol, pairing and threat model, the Dock helpers, sizing, latency
budget, failure modes, threading model, the two swappable seams (`DockPresenter` and `MessageChannel`), and the
planned LiveKit transport.

## Security model, in short

- **Nothing listens while sharing is off.** While it's on, the only port (TCP 47821) speaks TLS 1.3 with
  required client certificates. A session is admitted only if the peer's key is pinned. Pairing is accepted only
  as a request: it shows a prompt on the host and gains nothing unless the host user types the right code.
  Requests are rate-limited per address and overall, and ignored while cooling down after a decline.
- **TLS verification is never off.** Certificates are self-signed and trusted only by SHA-256 SPKI pin,
  never by CA or name. Tickets and resumption are disabled.
- **Pairing:** the viewer asks and shows a single-use 6-digit code (5 minutes, 5 tries, one attempt at a time); the
  host user types it into the prompt. Each try runs a PAKE (X25519 with an Elligator 2 generator derived from the
  code and both TLS keys, HKDF and HMAC confirmations). A man in the middle gets one guess per try and nothing to
  test offline. The host prompt is hidden from screen capture.
- **Input stays in the shared window:** it's accepted only for streams the viewer opened, clamped to the window, and keys
  are sent only when that window's app is frontmost. Key presses pause while secure input is on at the host.
- **The clipboard stays put unless you ask:** sync is off by default and needs both Macs. Text moves only while a
  remote window is in front on the viewer, and items marked private stay on their Mac.
- **Files need the receiver's say-so:** receiving is off by default on each side, with separate settings for files
  from viewers and files from hosts. A sent name can't choose the folder or replace a
  file, and received files are quarantined so Gatekeeper still checks them.
- **A whole screen is a wider grant:** it's off until the host ticks it. Rejected apps are left out of the picture,
  but one that opens during a stream can show for up to 2 seconds. Clicks can land anywhere on that screen.
- **Sensitive windows never leave the host:** password managers, system password and Touch ID prompts, hidden
  apps, and our own windows are filtered when listing and again when a window is opened. Their **sound** is
  never captured either, whatever the audio switches say; other apps' sound flows only while one of their
  windows is open on the viewer.
- **Share links are separate and short-lived:** port 47822 opens only while a link or guest exists. A link is a
  128-bit ID plus a 256-bit one-time token in the URL fragment (never sent to the server in the request line);
  five bad tokens burn it. Guests are view-only unless the host allows clicks and scrolls, never get the
  keyboard, see only that one window, get no audio, and can be kicked. Its certificate is separate from the
  pinned device identity, which browsers never see.
- **Dock helpers are verified:** the local socket is owner-only, and the main app accepts only helpers whose code
  signature matches the identifier and cdhash it signed. In Developer ID builds each helper also requires
  paneshare's Team ID of the process it talks to.
- **Updates are signed twice and never silent:** Sparkle checks the EdDSA signature of the feed and of each DMG
  (key only on the release Mac) and the new app's Developer ID signature, over HTTPS only. Checks start only after
  the user agrees on first launch, and installing always asks.
- **No shell commands (helpers are signed in process, not with `codesign`), no telemetry.** One private API
  (`CGVirtualDisplay`) is used, only when the host turns on the virtual display; see risk 9.

## Known risks

1. **Newer features have only been compiled, not run on two Macs.** See Status for the list. Expect some bugs
   on the first real run.
2. **Key storage on ad hoc builds.** Without a provisioning profile, the identity key and the pin list live in the
   login keychain, where another process running as the same user could plant a key or a pin before
   first launch. The **This Mac** tab shows which store is in use. Release builds need Developer ID signing with a
   keychain-access-group entitlement.
3. **Accessibility resize** is asynchronous and app-dependent. Some apps ignore it, or resize late. The viewer snaps
   to whatever size the host reports back, but very fast live resizes may stutter.
4. **Latency is unmeasured.** The budget (≤ 35 ms p50 glass-to-glass on a wired LAN) is a target. There's no
   adaptive bitrate yet. On a congested link, backpressure drops frames and asks for a keyframe.
5. **One TLS stream carries video and input**, so a large keyframe can delay input on a slow link
   (head-of-line blocking). The LiveKit transport behind `MessageChannel` is the planned fix (ARCHITECTURE §13.2).
6. **Dock helpers rely on LaunchServices accepting ad hoc signed bundles we generate at runtime.** This is
   untested on a real Mac. In notarized releases they still aren't assessed by Gatekeeper because they're never
   quarantined (RELEASING §5); App Management behaviour on macOS 13+ is unverified. After a helper hands activation to paneshare, Command-Tab shows paneshare as frontmost.
   `defaults write dev.paneshare.app dockHelpers -bool false` switches to the single-icon fallback.
7. **Secure-input detection is global**: any app with secure keyboard entry on pauses typing into every shared
   window until it's off.
8. **Audio is unverified on a Mac.** The process-tap code follows Apple's headers but hasn't run. Safari's web
   audio plays from WebKit helper processes that can't be attributed to Safari with public API, so it may be
   missing (TESTING A14). A/V sync relies on the audio and video paths having similar delays and isn't
   measured yet.
9. **The virtual display uses a private API** (`CGVirtualDisplay`). That rules out the Mac App Store (guideline
   2.5.1), and a macOS update could remove or change it. paneshare checks the classes and method signatures at
   run time and reports the feature unavailable instead of crashing; windows then stay on the real screen. It's off
   by default. After a crash, macOS moves windows off the vanished display but not to their exact old positions.
10. **Share links use a self-signed certificate.** Browsers warn once per host. A guest who clicks through without
    comparing the fingerprint could be fooled by someone already able to intercept their LAN traffic. Whoever
    opens a link first becomes its guest, so send links privately and keep lifetimes short. While pointer control
    is on, a guest's clicks move the host's real cursor. Guests get no sound, no keyboard, and H.264 only
    (no 4:4:4), so text is a little softer than in the native viewer. Share links don't reach the internet; that's
    a design only ([`docs/SHARE-LINKS-INTERNET.md`](docs/SHARE-LINKS-INTERNET.md)).
11. **Updates depend on the feed host and the signing keys.** The private repository can't host the feed, so a
    public static host is needed (RELEASING §3). Losing the Sparkle key *and* the Developer ID certificate would
    strand installed copies. Back both up (RELEASING §1). The audio-input entitlement for the process tap under
    the hardened runtime is a precaution, and still unverified.

## Roadmap

1. Run the rest of TESTING.md on two Macs (pairing v2, sharpness diagnostics, input, Dock) and record latency.
2. A loopback TLS pairing and session integration test on the macOS CI runner.
3. Dock helpers: real-window ownership inside the helper (ARCHITECTURE §6, option E) so Command-Tab stays on it.
4. LiveKit transport (Apache-2.0): UDP media with congestion control and multiple viewers.
5. Adaptive bitrate and frame rate from RTT and send-queue depth.
6. Clipboard and drag-and-drop of text.
7. Take-over mode (stream a whole virtual desktop), building on the virtual display.
8. Share links: Opus audio and an optional keyboard scope for guests, a trusted certificate via `tailscale cert`,
   and internet links per `docs/SHARE-LINKS-INTERNET.md`.
9. Run the first signed release (TESTING §4.10) and pick a feed host (RELEASING §3); then the data-protection
   keychain (needs a provisioning profile) and Swift 6 language mode.

## Third-party code and license

Third-party code, dependencies and design references, with their licenses, are listed in
[`THIRD_PARTY.md`](THIRD_PARTY.md). All of it is Apache-2.0, MIT or BSD, with no GPL or AGPL code. The project
is released under the [MIT License](LICENSE).

The design follows the clean-room functional spec [`docs/SPEC.md`](docs/SPEC.md).

To report a security problem, see [`SECURITY.md`](SECURITY.md). To contribute, see
[`CONTRIBUTING.md`](CONTRIBUTING.md).
