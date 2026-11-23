# paneshare: sanitized functional spec (v1)

Written: 2026-11-04 (America/Chicago). Author: the analyst (gstack).
Audience: the coding agent building nexobe/paneshare in Swift for macOS 14 (Sonoma) or later.

## How to read this

- This spec says WHAT the product does and WHICH public or semi-public Apple APIs can do it. It does not say how any existing product's code is written.
- It contains no decompiled code, no transcribed pseudocode, no symbol, class or file names from the reference product, no copied UI text, no assets and no branding. All names below are ours.
- Each item carries a confidence tag:
  - **[C] confirmed**: directly evidenced by the reference build (its linked frameworks, imported APIs, bundle layout or declared permissions).
  - **[I] inferred**: a strong inference from the evidence, or our own design choice where the evidence only constrains it.
  - **[D] our design**: a recommendation for paneshare with no claim about the reference.
- Evidence basis: static analysis of one public release (bundle layout, declared permissions, linked frameworks, imported APIs). The small Dock helper was also decompiled. The main binary was NOT fully decompiled, so where a numeric value is given it is tagged [I] unless stated otherwise.
- Our names: **Host** is the Mac that owns the real window. **Viewer** is the Mac showing it. A **Mirror** is one shared window as it appears on the Viewer. A **Proxy Tile** is a stand-in app that gives a Mirror its Dock icon and Cmd-Tab entry. A **Shadow Display** is a virtual display on the Host.

## 1. Product behaviour (what users see)

1. On the Viewer, the user picks a Mac, then an app or window from that Mac's list. A live Mirror window opens on the Viewer. [C]
2. Each remote app gets its own Dock icon (the remote app's icon with a ring in the source Mac's colour) and its own Cmd-Tab entry. The Dock icon's menu lists that app's mirrored windows. [C]
3. Resizing the Mirror resizes the real window on the Host. Clicks, scrolling, typing and keyboard shortcuts go to the Host. [C]
4. The stream matches the Viewer's real pixel density, so text is sharp. [C]
5. There are two placement modes: [C]
   - **In place** (default): the real window stays on the Host's screen and anyone at the Host sees it move.
   - **Take over**: the real window leaves the Host's visible screen and renders at full resolution for the Viewer. The Host shows a small notice with a way to bring it back.
6. Whole-display sharing works as well as single windows. Several Mirrors can be open at once, from several Hosts. [C]
7. Headless Macs (no monitor) list and share their windows. [C]
8. Hidden windows, password managers and system password prompts never appear in the picker on either side and are never streamed. [C]
9. Later features (not in the MVP): shared clipboard, file drag onto a Mirror, per-app audio, browser viewer links, dictation into the remote window. [C]
10. Discovery works on the same LAN. Over Tailscale it also works across networks. Media goes directly Mac to Mac, encrypted. Any account service only knows which Macs exist, never their content. [C]

## 2. Architecture overview

```
Viewer Mac                                              Host Mac
┌───────────────────────────┐                          ┌──────────────────────────────┐
│ Main app (one process)     │  control (TLS, pinned)   │ Main app / headless daemon    │
│  - Picker UI               │◀────────────────────────▶│  - Window lister              │
│  - Mirror windows (NSWindow│                          │  - Capture (ScreenCaptureKit) │
│    + video layer)          │   media (WebRTC/SRTP)    │  - Encoder (VideoToolbox)     │
│  - Input forwarder         │◀═════════════════════════│  - Input injector (CGEvent+AX)│
│  - Proxy Tile manager      │                          │  - Shadow Display manager     │
└──────┬────────────────────┘                          │  - Exclusion filter            │
       │ launches, talks over a local IPC channel        └──────────────────────────────┘
┌──────▼──────────┐  ┌─────────────────┐
│ Proxy Tile app A │  │ Proxy Tile app B │   (one tiny process per remote app)
└──────────────────┘  └─────────────────┘
```

- Every Mac runs the same binary in Host and Viewer roles. There is also a CLI or headless mode for Macs with no display. [C]
- A launch agent (registered through `SMAppService`) keeps the Host side running and relaunches it after a crash. [C]
- The app is not sandboxed and is shipped with Developer ID signing and notarization. It needs Screen Recording, Accessibility and Local Network permissions, plus Microphone and Speech only for dictation. [C]

## 3. Dock icon and Cmd-Tab per remote app (the key trick)

**Mechanism [C]:** macOS gives one Dock icon and one Cmd-Tab entry per running app process with a regular activation policy. To get one icon per remote app, the Viewer creates and launches a separate tiny **Proxy Tile app** for each remote app. The real Mirror windows stay in the main Viewer process. The Proxy Tile only supplies the identity (icon and name) and forwards activation.

**Proxy Tile bundle generation [C for the approach, I/D for details]:**
1. On first use of a remote app (keyed by Host device ID plus remote bundle ID), write a minimal `.app` bundle into a cache folder we own, e.g. `~/Library/Application Support/paneshare/Tiles/<hostID>-<hash>.app`. [D]
2. `Info.plist`: a unique `CFBundleIdentifier` under our own prefix (e.g. `com.nexobe.paneshare.tile.<hash>`), `CFBundleName` = "<RemoteApp> (<HostName>)", `CFBundleIconFile`, plus custom keys holding the deep link that reopens this Mirror (e.g. a `paneshare://open?...` URL). Don't set `LSUIElement`, because the tile must be a regular app. [I]
3. Executable: copy (or hard-link) one small, generic helper binary shipped inside the main app, e.g. `Contents/Helpers/paneshare-tile`. The helper is the same for every tile. [C]
4. Icon: get the remote app's icon from the Host with a control message, composite the machine-colour ring, and write an `.icns`. [C]
5. Ad-hoc codesign the generated bundle (`codesign -s - --force`) so Gatekeeper and launch services accept it. [C]
6. Launch it with `NSWorkspace.openApplication(at:configuration:)`, passing the parent PID and tile ID in the environment. Set `addsToRecentItems = false`. [C]
7. Housekeeping: keep a ledger of tiles, delete tiles unused for N days (the reference uses about 60), and respect tiles the user pinned in the Dock. Read-only checking of the Dock's persistent-apps preference is enough to tell. [C]

**Helper (Proxy Tile) behaviour [C]:**
- `NSApplication` with `.regular` activation policy. It sets its icon at launch (`NSApp.applicationIconImage`).
- IPC with the main app. The reference uses `DistributedNotificationCenter`, with named notifications for state, quit and icon updates plus a hello on launch. [C] For paneshare, prefer an XPC listener or a Unix-domain socket for reliability, and keep distributed notifications as a fallback. [D]
- **Activation forwarding:** when the tile becomes active (the user clicks the Dock icon or Cmd-Tabs to it), it tells the main app, which raises and focuses that app's Mirror window(s) and activates itself. Order: the tile becomes active, the main app is notified, the main app calls `NSApp.activate` and `makeKeyAndOrderFront` on the Mirror. [C]
- **Dock menu:** `applicationDockMenu(_:)` returns one item per Mirror window (ID and title, pushed by the main app), plus "Close all". Choosing an item focuses that Mirror. [C]
- **Quit semantics:** if the user quits the tile (Cmd-Q in Cmd-Tab, or Dock > Quit), it asks the main app to close that app's Mirrors. If the main app asked the tile to quit, it just exits. [C]
- **Parent watchdog:** a timer (about 2 s) checks that the parent PID is alive (`kill(pid, 0)`) and exits if not, so no orphan icons are left. [C]
- **Cold start:** if launched with no main app running (a pinned Dock icon clicked later), open the deep link stored in its Info.plist with the main app (`NSWorkspace.open(_:withApplicationAt:configuration:)`), then wait for the hello. If the main app is not installed, exit. [C]
- Known tradeoff: the activation hop between processes adds a frame or two of focus flicker. Mitigate it by having the main app activate with `NSApp.activate(ignoringOtherApps:)` (or `yieldActivation` on macOS 14 or later) as soon as it is notified. [I]

**Alternatives we rejected [I]:** toggling the main app's activation policy only gives one icon in total. Using `NSDockTile` on the main app has the same limit. Faking icons with private Dock SPI is fragile and breaks across macOS releases.

## 4. Host capture

- **API [C]:** ScreenCaptureKit. For a single window, `SCContentFilter(desktopIndependentWindow:)`. For a whole display, `SCContentFilter(display:excludingWindows:)` or `(display:including:exceptingWindows:)` with the exclusion list applied (Section 9). The enumeration is `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`.
- **Configuration [C for which knobs are used, I for values]:**
  - `pixelFormat = kCVPixelFormatType_32BGRA` (full chroma, needed for the 4:4:4 path; use NV12 `420v` when 4:2:0 only). [C]
  - `width`/`height` = window points × backing scale × a quality "level" (1.0, 1.25, 1.5 or 2.0, with a default of about 1.5 on a 2x Viewer). `scalesToFit` as needed, and `sourceRect` for crops. [C]
  - `minimumFrameInterval` = 1/30, 1/60 or 1/120 (user choice, default 60). [C]
  - `queueDepth` small (3 to 5) for latency. `showsCursor = false` for windows, since the Viewer draws its own cursor. Set `colorSpaceName` and `colorMatrix` explicitly (sRGB or Display P3 and BT.709). [C/I]
  - Audio is off in the video stream; per-app audio is separate (Section 11). [C]
- **Cadence [C/I]:**
  - ScreenCaptureKit only delivers frames when content changes. Keep a steady output cadence by re-sending the last frame (repeat frames) at a low rate, so the receiver's jitter buffer and congestion control stay warm. [C]
  - Detect static windows (captured fps below a threshold) and lower the bitrate budget for them. [C]
  - After a period with no change, send one **quality top-up frame**: a high-bitrate P-frame rather than a keyframe, so text converges to lossless quality without a keyframe stall. [C]
  - While content is moving and the encoder is at its bitrate ceiling, step the capture scale down one level, and step back up after about 1 s or more of stillness. [C]
- **Resize:** while a resize drag is in progress, keep the encoder's coded size frozen and letterbox or scale. Reconfigure the stream (`SCStream.updateConfiguration`) and the encoder once at the end of the drag. [C]

## 5. Shadow Display (virtual display on the Host)

**Purpose [C]:**
1. Render a window at a size or resolution larger than the Host's physical screen.
2. Take-over mode: move the window off the user's visible screens while it keeps rendering (an occluded window on a real display still renders, but it is visible and size-clamped).
3. Give headless Macs a real display to render on.

**API [C]:** the private but widely used `CGVirtualDisplay` family (`CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings`). This is the same approach as open-source projects such as BetterDisplay-style tools and the MIT-licensed examples on GitHub. Create it with a name, a pixel size large enough for the biggest Mirror, HiDPI on, and a refresh rate of 60 or 120. Keep a strong reference, because the display disappears when the object is freed. [C]

**Behaviour [C]:**
- Create the display on demand when the first take-over Mirror or oversized resize needs it. Release it when no window is on it, or optionally keep one per session to avoid display-reconfiguration churn.
- Move windows onto it with Accessibility: set `kAXPositionAttribute` to coordinates inside the virtual display's global bounds (`CGDisplayBounds`), then `kAXSizeAttribute`. Record each window's original frame and display so it can be restored.
- On Mirror close, Host shutdown, crash recovery or the next launch, restore every moved window to its original frame. On the next launch, sweep for stranded windows and leftover virtual displays.
- Full-screen windows: take them out of full screen first, then move them.
- Without a Shadow Display, clamp resize requests to the physical screen and report the clamp to the Viewer.
- Observe `CGDisplayRegisterReconfigurationCallback` and wait out reconfigurations before moving windows.
- Headless: if the virtual display is the only display, keep it as the console display. Mirroring changes use `CGConfigureDisplayMirrorOfDisplay`.
- Known side effect: every created virtual display can leave a ColorSync profile entry behind. Reuse a stable vendor, product and serial identity so you don't add a new one each time. [C]
- Optional private window-server queries (Spaces, window owner and tags) improve this but are not required for the MVP. [C, optional]

## 6. Encoder and decoder

- **MVP [D]:** VideoToolbox HEVC Main (4:2:0) hardware encode, `kVTCompressionPropertyKey_RealTime = true`, `AllowFrameReordering = false` (no B-frames), `ExpectedFrameRate` = capture fps, `AverageBitRate` plus `DataRateLimits` cap, a long or infinite `MaxKeyFrameInterval` with keyframes on demand (on packet loss or a new subscriber), and `PrioritizeEncodingSpeedOverQuality` on. Use H.264 High as the fallback for Intel or older hardware.
- **Text clarity mode [C]:** HEVC **Main 4:4:4** from BGRA input when both sides have Apple-silicon hardware support. The receiver needs a decoder path that outputs 4:4:4 (`kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange` and similar) and renders with Metal. Negotiate capability per pair, and fall back to 4:2:0 after repeated 4:4:4 failures.
- **Simulcast [C]:** an optional H.264 backup layer next to HEVC, for receivers that can't decode HEVC (the browser viewer).
- **Bitrate defaults [C/I]:** around 40 Mbps ceiling at 60 fps on LAN. A per-Mirror bits-per-pixel budget sets the ceiling, and congestion feedback lowers it.
- **Decode/render [C]:** VideoToolbox decode to `CVPixelBuffer`, shown with `AVSampleBufferDisplayLayer` or a Metal layer inside the Mirror window. Keep the window hidden, or show a placeholder, until the first decoded frame arrives.

## 7. Transport

**What the reference does [C]:** it is WebRTC based. The Host runs an embedded open-source **LiveKit SFU server** (Apache-2.0) as a local child process, listening on fixed local ports (signaling over WebSocket, media over UDP with TCP fallback). Host and Viewer both join a "room" on the Host's SFU using the LiveKit Swift client SDK (Apache-2.0) and its WebRTC build. The Host signs short-lived access tokens (JWT) with per-participant grants, including a browse-only permission that allows listing without viewing. Control messages travel on WebRTC data channels and RPC within the room. A self-signed TLS proxy in front of the SFU lets paired Viewers pin the Host's certificate. The same SFU serves browser viewers through a bundled web page.

**What paneshare should do [D]:** pick one of two paths.
- **Path A (fastest to parity):** reuse the same open-source building blocks (LiveKit server, Apache-2.0, and the LiveKit Swift SDK, Apache-2.0). This is license-compatible with MIT or Apache-2.0 open-sourcing. It costs a 50 MB Go binary per Host, plus SFU process management.
- **Path B (lean MVP, recommended for v0):** a direct peer-to-peer link with no SFU:
  - **Control:** `Network.framework` TCP with TLS (`NWProtocolTLS` using a self-signed identity pinned after pairing), length-prefixed binary or JSON messages, `noDelay = true`.
  - **Media:** either (a) WebRTC peer connection (Google WebRTC, BSD) with our own VideoToolbox encoder injected, or (b) a custom RTP-like stream over `NWConnection` UDP, or QUIC (`NWProtocolQUIC`, macOS 12+) with one stream per Mirror and datagrams for video. QUIC gives encryption for free.
  - Path B keeps the door open to switch to Path A later for multi-viewer and browser support.

**Ports [D]:** choose our own fixed default port block, configurable. Don't reuse the reference's numbers.

**Discovery [C]:**
- **LAN:** Bonjour through `NWListener.Service` / `NWBrowser` with a TXT record (device ID, display name, protocol version, public-key fingerprint, capabilities such as 4:4:4 and audio). The service type is ours: `_paneshare._tcp`. The Info.plist needs `NSBonjourServices` and `NSLocalNetworkUsageDescription`. [C for the mechanism]
- **Remote:** Tailscale. List peers through the local Tailscale API (`/localapi/v0/status` on the tailscaled socket) or the `tailscale status --json` CLI, then connect by tailnet IP. There is no relay server. [C]
- Use `NWPathMonitor` for network changes. If UDP is blocked, fall back to TCP and warn the user. [C]

**Control message catalog [C for the set of operations, D for names and shape]:**

| Direction | Message | Payload |
|---|---|---|
| V→H | `hello` | protocol version, viewer device ID, capabilities, auth proof (Section 8) |
| H→V | `hello.ok` | host ID, capabilities, display list |
| V→H | `windows.list` / `apps.list` | filter (on-screen only, include apps) |
| H→V | `windows.result` / `apps.result` | [{windowID, appBundleID, appDisplayName, title, frame, scale, isOnScreen}] |
| V→H | `icon.get` | bundleID, size → H→V `icon.data` (PNG bytes) |
| V→H | `mirror.open` | windowID or displayID, mode (inPlace/takeOver), fps, quality level, bitrate cap, codec prefs |
| H→V | `mirror.ready` / `mirror.denied` | mirrorID, stream ID, initial size / reason (excluded, secure prompt, permission) |
| V→H | `mirror.close` | mirrorID |
| V→H | `mirror.setSize` | mirrorID, new size in points (+ edge) |
| H→V | `mirror.sizeIs` / `mirror.sizeLimited` | actual size / max size |
| V→H | `input` | mirrorID, event (see Section 10) |
| V→H | `mirror.setPlacement` | mirrorID, inPlace/takeOver |
| H→V | `window.changed` | mirrorID, title change, moved to another Space/minimized/hidden/closed |
| both | `clip.offer` / `clip.part` / `clip.done` | later feature: types + sizes, chunked data, acks |
| both | `ping`/`pong` | timestamps for RTT and clock skew |

Sequencing: connect, then TLS (pinned), `hello` / `hello.ok`, `windows.list`, the user picks, `mirror.open`, `mirror.ready`, the media stream starts with a keyframe, the first frame is shown and the Viewer window appears, then input, resize and close cycles follow.

## 8. Pairing, trust and encryption

**Reference model [C]:**
- Each Mac has a long-term **Ed25519** identity key stored in a user-only file (private key never leaves the Mac). It keeps a trust list of paired public keys.
- Pairing is **one-way** and per Mac: the Viewer asks, the Host shows a **6-digit code** valid for a few minutes for one requester, and the user types it on the Viewer. From then on that Viewer may view that Host. There is a CLI path to print the code on a headless Host.
- Crypto primitives present: X25519 key agreement, HKDF-SHA256, ChaCha20-Poly1305, HMAC-SHA256, Ed25519 signatures, and PKCS#12 import for the TLS identity.
- The Host's TLS certificate fingerprint is signed by its Ed25519 identity, and the Viewer pins it after pairing.
- Optional account sign-in (an OAuth device flow with a third-party auth provider) lets Macs on the same account skip codes. It also issues signed license tokens ("this Mac may view") that Hosts verify offline against an embedded root public key, with a 30-day offline grace. The account service is never in the media path.

**paneshare design [D]:**
1. On first launch, generate an Ed25519 signing key and an X25519 key with CryptoKit and store them in the Keychain (better than a file). Generate a self-signed TLS identity (P-256), and sign its SPKI hash with Ed25519.
2. **Code-authenticated pairing:** the Viewer sends a `pair.begin` (its Ed25519 public key plus an ephemeral X25519 key). The Host shows a 6-digit code (CSPRNG, 5-minute TTL, single use, rate-limited to about 5 tries). Both sides compute `K = HKDF(X25519(eph), salt = code, info = transcript)`. Each side sends `HMAC(K, transcript)` to confirm, then exchanges long-term public keys sealed with ChaCha20-Poly1305 under K. If you want resistance to offline brute-force of the 6 digits, use a real PAKE (SPAKE2+ or CPace); CryptoKit doesn't ship one, so plain HKDF+HMAC is acceptable only together with the rate limit and short TTL. [D]
3. After pairing, the Viewer stores the Host's Ed25519 key and pins the TLS SPKI hash. Every later connection runs TLS 1.3, with the Host proving its identity through the signed SPKI and the Viewer proving its own with a signed challenge in `hello`.
4. Media: WebRTC's DTLS-SRTP, or QUIC/TLS 1.3, bound to the same identity (put the DTLS fingerprint in signed signaling).
5. Unpair removes the key, and the Host drops that Viewer's sessions at once.
6. No accounts in the MVP.

## 9. Exclusion and privacy rules

- Never list or stream: [C]
  - windows of a deny-list of bundle IDs: password managers (1Password, Bitwarden, the Apple Passwords app, Keychain Access, plus a user-editable list);
  - system authentication or secure-prompt windows (password and Touch ID sheets);
  - windows of hidden apps;
  - windows that are not normal (`kCGWindowLayer != 0`, alpha 0, or zero size);
  - windows marked non-shareable (`sharingType == .none`);
  - our own app's windows.
- Apply the filter on BOTH sides: the Host's `windows.result` filters, and the Host refuses `mirror.open` for excluded windows even if asked directly. [C]
- In whole-display mode, add excluded windows to `excludingWindows`. [C]
- Secure keyboard input: if another process has secure input on (`CGSessionCopyCurrentDictionary` reports a secure-input PID), pause key injection and tell the Viewer. [C]
- Clipboard (later): never send items marked concealed or transient (the `org.nspasteboard.ConcealedType` / `TransientType` conventions). [I]
- Optional privacy cover (later): in take-over or remote-control sessions, the Host can show a full-screen cover window so people at the Host don't see the session, and a local event tap notices someone at the keyboard. [C]

## 10. Input forwarding

- **Viewer side [C]:**
  - The Mirror window's content view captures mouse (moves, buttons, drags), scroll (with precise deltas and phase), magnify and key events, and maps view coordinates to normalized window coordinates (0 to 1). That stays right regardless of scale.
  - Keyboard: send the virtual key code, modifier flags and characters. Use a local `CGEventTap` (needs Accessibility) only if you want to capture system shortcuts such as Cmd-Tab and Cmd-Space for the remote, and make it opt-in.
  - IME and dictation text goes as Unicode strings.
- **Host side [C]:**
  1. Map normalized coordinates to the window's current global frame (from AX or ScreenCaptureKit).
  2. Make sure the target app is frontmost and the window is raised (`AXUIElementPerformAction(kAXRaiseAction)`, then set `kAXMainAttribute` / activate the app). Find the AX window for a window ID using the widely used `_AXUIElementGetWindow` SPI, or by matching frame and title.
  3. Inject with `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent` (+ `CGEventKeyboardSetUnicodeString` for text), and `CGEventCreateScrollWheelEvent2` (pixel units), posted with `CGEventPost(.cghidEventTap)`. Warp the cursor with `CGWarpMouseCursorPosition` when needed, and hide the Host cursor during remote control if no one is local.
  4. Requires the Accessibility permission (`AXIsProcessTrustedWithOptions` prompt).
- In-place mode caveat: injected events move the real cursor on the Host, so a local user and a remote user fight over it. That's why take-over mode exists. [I]
- Keep the Host awake during sessions with `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep)`, plus `IOPMAssertionDeclareUserActivity`. [C]

## 11. Per-app audio (later)

- **API [C]:** Core Audio process taps (macOS 14.2+): `CATapDescription` (stereo mixdown of the target app's process objects, `muteBehavior` = muted while tapped so the Host stays silent, private tap), then `AudioHardwareCreateProcessTap`, then an aggregate device containing the tap (`AudioHardwareCreateAggregateDevice`), then an IO proc or `AVAudioEngine`.
- Encode with Opus at 48 kHz stereo and send as an audio track tied to the Mirror. [C]
- The reference runs audio capture in a separate helper process with its own identity and restricts who can subscribe to it. That is optional for us. [C]
- An alternative for MVP+: ScreenCaptureKit `capturesAudio` with `excludesCurrentProcessAudio` on an app-filtered stream. It is simpler but can't mute the Host. [C]

## 12. Mirror window on the Viewer

- A borderless or titled `NSWindow`, sized in points = remote size ÷ Viewer scale × remote scale, so a 1:1 pixel mapping gives sharp text. A thin top bar shows the window title and Host colour. [C/I]
- Live resize sends a debounced `mirror.setSize` (about 30 to 60 Hz during the drag, final on mouse-up). While waiting, scale the last frame. [C]
- Window close sends `mirror.close`, and the last Mirror of an app quits that app's Proxy Tile. [C]
- Full screen, zoom, and "actual pixels" vs "fit" are options. [C]
- Reconnect: if the link drops, keep the window with a placeholder and auto-reopen when the Host returns. Park idle Mirrors after about 30 minutes. [C]

## 13. Diagnostics (recommended)

The reference ships an extensive CLI covering doctor (permissions, network, peers), log query, a crash-cause readout, a merged two-Mac event timeline and a zipped problem report. [C] We recommend a small `paneshare doctor` (permissions, Bonjour reachability, Tailscale status, ports) and structured JSON logs by category (capture, encode, net, input, resize, trust). [D]

## 14. MVP scope and build order [D]

1. Host: list windows (ScreenCaptureKit + exclusion filter), capture one window as BGRA, encode HEVC 4:2:0 (H.264 fallback).
2. Transport: Bonjour discovery, a TLS control channel (pairing stubbed at first, then the 6-digit code), and media over QUIC or a WebRTC peer connection.
3. Viewer: a Mirror window with a Metal or AVSampleBufferDisplayLayer renderer, keeping a 1:1 pixel mapping.
4. Input: mouse, scroll and keys to the Host through CGEvent, with AX raise.
5. Resize: Viewer request, then an AX set-size on the Host, then stream reconfiguration.
6. Proxy Tile helper: per-app Dock icon and Cmd-Tab, activation forwarding, Dock menu.
7. Shadow Display for take-over mode and headless Hosts.
8. Later: 4:4:4, audio taps, clipboard, files, Tailscale peer list, browser viewer.

## 15. Open-source building blocks and licenses [C for use by the reference, D for recommendation]

| Need | Project | License | Note |
|---|---|---|---|
| SFU (optional Path A) | livekit/livekit (server) | Apache-2.0 | used by the reference as an embedded local server |
| Client SDK (Path A) | livekit/client-sdk-swift | Apache-2.0 | |
| WebRTC | webrtc-sdk/webrtc or Google WebRTC | BSD-3 | |
| Auto-update | sparkle-project/Sparkle | MIT | used by the reference |
| Virtual display | public samples using `CGVirtualDisplay` (check each license; prefer MIT) | varies | private API, so pin behaviour per macOS version |
| Capture samples | Apple ScreenCaptureKit sample code | Apple sample license | |

Avoid GPL code if paneshare will ship under MIT or Apache-2.0.

## 16. Risks and tradeoffs

- **Private APIs** (`CGVirtualDisplay`, `_AXUIElementGetWindow`, window-server queries) can break across macOS releases. Keep them behind protocols with feature detection. Notarization allows them, but App Store distribution would not. [I]
- Proxy Tile bundles must be ad-hoc signed and live in a user-writable folder. Gatekeeper quarantine must not be set on them, so write them ourselves rather than downloading them. [I]
- Moving windows with AX fails on the lock screen, for some modal sheets, and for apps that refuse resizing. Report the clamp or refusal. [C]
- The 4:4:4 HEVC path needs Apple silicon on both ends. [C]
- An embedded SFU adds about 50 MB and a child process to manage, including cleaning up orphaned instances after a crash. [C]

## Addendum A: paneshare changes after the first two-Mac test [D]

Added by the paneshare team on 2026-11-04 from our own tester's feedback. **Nothing here comes from the reference
product**; every item is [D]. Where it differs from the sections above, this addendum wins for paneshare.

**A.1 Pairing is requested from the Viewer and accepted on the Host (replaces §8 design step 2's flow).**
- The Viewer user clicks Pair on a discovered Host or by address. The Viewer generates the 6-digit code and shows
  it. The Host shows a prompt on its own, "<Viewer name> wants to pair with this Mac", with the requester's ID, a
  code field, Accept and Decline; it surfaces even when the app is in the background (floating panel, Dock bounce,
  notification). Nothing is prepared on the Host first.
- The Host user types the code shown on the Viewer. Each Accept is one run of the code-keyed PAKE (CPace-style, as
  built), bound to both TLS keys. Limits stay: 5 minutes, 5 attempts on each side, single use.
- Chosen over numeric comparison (users rubber-stamp a "codes match?" prompt, and both sides would have to confirm)
  and over code-on-Host-typed-on-Viewer (the consent would land on the wrong Mac). With the code typed on the
  target, typing it is the consent, and an active MITM gets one online guess per attempt.
- Spam: one prompt at a time; per-address and overall caps per 10 minutes; a cooldown after a decline or failure;
  over-limit requests are dropped without an answer. Pairing is possible only while the Host is sharing.

**A.2 Text sharpness at native quality (extends §4 and §6).**
- Target: a 1:1 pixel mapping from capture to the Viewer's screen at native quality.
- Capture BGRA at points × the Viewer's backing scale. Encode HEVC 4:4:4 (then 4:2:2) where the encoder offers it
  and the Viewer accepts it, else 4:2:0; the Viewer falls back to 4:2:0 if it can't decode. Tag BT.709.
- Quality top-up: after a short idle period, re-encode the last frame as high-bitrate P-frames.
- The Viewer keeps its window at exactly stream pixels ÷ backing scale and draws with nearest filtering at 1:1.
- A hidden diagnostics overlay reports capture, encoded and displayed pixels, scale, codec, chroma and bitrate.
