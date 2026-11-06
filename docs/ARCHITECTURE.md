# paneshare architecture

Status: MVP design, revision 3 (2026-11-04). Revision 1 was written before the code. Revision 2 recorded where the
implementation settled. Revision 3 reconciles the design with the sanitized functional spec (`docs/SPEC.md`), the
only target-derived input this project uses: §0 maps every spec item to what we built, §4.2 replaces the pairing
ceremony with a 6-digit code and a PAKE, §6 makes per-app Dock helpers the shipped presenter, §7 adds the quality
factor and the frozen stream size during resize, §4.3 and §9 add the secure-input pause and the exclusion list, and
§13 records what is deferred and how transport upgrades to LiveKit. The two seams most likely to change, **Dock/Command-Tab
presentation** and **transport**, stay protocols (see [Swappable seams](#5-swappable-seams)).

All names here are ours. Where the spec uses its own terms we map them once in §0 and then use ours: a spec
"Mirror" is a **viewer window**, a "Proxy Tile" is a **Dock helper**, a "Shadow Display" is a **virtual display**.

## 0. Reconciliation with the functional spec

| Spec item (section) | paneshare | Status |
| --- | --- | --- |
| One Dock icon and Command-Tab entry per remote app via a generated helper app (§3) | `DockHelperFactory` generates `<App> on <Host>.app` per (host, remote bundle ID), ad hoc signs it **in process** (no `codesign` child process), and `HelperDockPresenter` launches it. The helper only proxies activation, the Dock menu and quit to the main app (§6). | Built; runtime unverified (no Mac in CI run) |
| Helper IPC: distributed notifications, or a socket/XPC (§3, D) | A Unix-domain socket in a 0700 directory. The main app verifies each helper by audit token, signing identifier and cdhash; the helper verifies the main app by PID and bundle ID (§6.3). No distributed notifications. | Built |
| Cold start from a pinned Dock icon via a deep link (§3) | The helper launches the main app by bundle ID and says `hello {coldStart: true}`; the main app reopens that app's windows. There is **no URL scheme**, so no other process can trigger opens. | Built |
| Helper housekeeping, about 60 days, respect pinned icons (§3) | `DockHelperLedger`: delete helpers of unpaired hosts, and helpers idle **30 days** unless pinned (read from the Dock's `persistent-apps`, read-only). | Built |
| Capture at points × backing scale × quality level (§4) | `Sizing.pixelSize(points:scale:quality:)` with `StreamQuality` native 1.0, balanced 0.75, economy 0.5. We don't oversample above the viewer's backing scale (§7). | Built |
| Freeze the coded size during a resize drag (§4, §12) | Mid-drag `resize {final: false}` resizes the real window only; the encoder and `SCStream` are rebuilt once on `final: true`, or 1 s after the last request (§7). | Built |
| HEVC with H.264 fallback (§6) | Hardware HEVC, then hardware H.264, then software H.264; mid-stream rebuild prefers H.264 (§9). | Built (already in rev 2) |
| Transport Path B: Network.framework TLS + Bonjour, direct P2P (§7) | `TLSMessageChannel` over TCP + TLS 1.3 with SPKI pinning, Bonjour `_paneshare._tcp`, manual address for Tailscale. Video rides the same connection with a droppable path. | Built |
| Transport Path A: LiveKit (§7) | Documented as the planned upgrade path behind `MessageChannel` (§13.2). Nothing from LiveKit is vendored or linked. | Planned |
| 6-digit code, X25519 + HKDF + HMAC confirmation, then a pinned identity (§8) | A CPace-style PAKE: the code and both TLS fingerprints derive an X25519 generator by Elligator 2, then HKDF-SHA256 confirmation keys and HMAC confirmations. Then each side pins the other's SPKI fingerprint (§4.2). This resists the offline guessing the spec notes plain HKDF is open to. Pairing is started from the viewer; the host user accepts in a prompt by typing the code the viewer shows (pairing v2, §4.2). | Built |
| Identity: Ed25519 signing key plus a TLS key it signs (§8) | One P-256 key per Mac is both the TLS key and the identity; the pin is its SPKI SHA-256. Fewer keys, same property: the pinned key authenticates every session. | Built (diverges deliberately) |
| Input: CGEventPost after AX raise, AX resize (§10) | `EventInjector` (`CGEvent.post(tap: .cghidEventTap)`), `AXWindow.raise()`/`resize(to:)`, `InputGate` (§3.4, §4.3). | Built (already in rev 2) |
| Pause key injection on secure input and tell the viewer (§9) | `IsSecureEventInputEnabled()` (public Carbon API) polled every 0.5 s per stream and on each key press; key presses are dropped; `inputState {paused: secureInput}` updates the viewer window's subtitle (§4.3). | Built |
| Exclusions: password managers, system auth prompts, hidden apps, non-normal windows, `sharingType = .none`, our own windows, on both sides, re-checked at open (§9) | `WindowPolicy`: a fixed system-auth list that user settings can't override, the password-manager deny-list, hidden apps (host only), layers, size, own process and our helpers. Applied when listing and again when a window is opened by ID. | Built |
| Virtual display, take-over mode, headless hosts (§5) | Deferred (§13.1). | Deferred |
| Per-app audio (§11) | Deferred (§13.1). | Deferred |
| Browser viewer (§1.9, §6 simulcast) | Deferred (§13.1); it comes with LiveKit. | Deferred |
| Text clarity: BGRA capture, HEVC 4:4:4 with 4:2:0 fallback, quality top-up P-frames (§4, §6) | BGRA capture; the encoder picks 4:4:4, then 4:2:2, from the profiles VideoToolbox reports and the viewer accepts, else 4:2:0; a still window gets two high-bitrate top-up P-frames; the viewer keeps an exact 1:1 mapping at native (§7.1). Decoded by `AVSampleBufferDisplayLayer`, not a Metal path. | Built; 4:4:4 decode on the viewer unverified |
| Whole-display sharing, clipboard, files, accounts, diagnostics CLI, keep-awake assertion | Not in the MVP (README roadmap). | Not started |

## 1. Goals and non-goals

MVP goals:

- One app containing two roles. The **host** shares chosen windows. The **viewer** shows them as native
  windows, and each remote app gets its **own Dock icon and Command-Tab entry**.
- Per-window capture (ScreenCaptureKit) at the viewer's backing scale × a quality factor, low-latency HEVC or
  H.264 encoding (VideoToolbox), and decoding into an `NSWindow`.
- Key, mouse and scroll input from the viewer to the host, injected with CGEvent after an AX raise. Viewer
  resizes are applied to the source window through Accessibility (AX). Key presses pause while secure input is on.
- LAN discovery over Bonjour, plus a manual address for Tailscale or any routable address.
- Encrypted, mutually authenticated transport only. No plaintext port, no relay, no server.
- Pairing started from the viewer and accepted in a prompt on the host, with a 6-digit expiring code and a PAKE,
  then pinned identities.

Non-goals for the MVP, **deferred** (§13): the virtual display (and with it take-over mode and headless hosts),
audio, and the browser viewer. Also not in the MVP: full-display capture, files, clipboard, accounts, and multiple
viewers per host window.

## 2. Components

```
                   HOST MAC                                              VIEWER MAC
 ┌──────────────────────────────────────────┐          ┌───────────────────────────────────────────┐
 │ PaneshareApp (SwiftUI shell, onboarding)  │          │ PaneshareApp (same binary, viewer role)    │
 │   HostPeer ── per viewer; HostStream ──  │          │   ViewerSession ── one per host           │
 │     │          per shared window         │          │     │                                     │
 │  Capture ──CVPixelBuffer──▶ Encode       │          │  Discovery (NWBrowser) ──▶ endpoints      │
 │  (SCStream,               (VTCompression │          │                                           │
 │   SCShareableContent)      Session)      │          │  Decode (CMSampleBuffer ──▶               │
 │     ▲                        │ AVCC NALs │          │          AVSampleBufferDisplayLayer)      │
 │     │ resize                 ▼           │  TLS 1.3 │     ▲                                     │
 │  Input (CGEvent, AX) ◀── Transport ◀─────┼──────────┼──▶ Transport ──▶ Viewer window (NSWindow) │
 │  secure-input check      (NWListener,    │  mutual  │    (NWConnection)       │  NSEvents        │
 │                          Bonjour adv.)   │  pinned  │                         ▼                  │
 │                                          │          │  HelperDockPresenter ── DockLinkServer    │
 └──────────────────────────────────────────┘          │        │ launches          ▲ Unix socket   │
                                                       │        ▼                   │ (verified)    │
                                                       │  "Xcode on Studio.app"  "Mail on Studio.app"│
                                                       │  (paneshare-dock-helper, one per remote app)│
                                                       └───────────────────────────────────────────┘
                        PaneshareCore (platform-neutral, unit-tested on Linux):
     wire framing and messages · MessageChannel and session rules · address parsing · coordinate mapping,
     sizing and event codes · pairing code, Curve25519 field and Elligator 2, PAKE exchange, gate ·
     identity and certificate · trust store · window exclusion policy · input gate · Dock helper plan,
     Mach-O ad hoc signer, bundle seal and icon container, helper ledger · audio jitter buffer, capture
     timeline, audio policy and per-app mix settings · virtual display planner and type-encoding checks ·
     share links: HTTP head parser, WebSocket codec, guest protocol, link store, router, web certificate,
     viewer page · helper icon layout and source-Mac colour · update configuration and consent

 BROWSER GUEST (§7.4): HostStream ──▶ WebConnection ──wss:// 47822──▶ web viewer (WebCodecs VideoDecoder)
```

| Module (SwiftPM target) | Responsibility | Key APIs | Platform |
| --- | --- | --- | --- |
| `PaneshareCore` | Everything that can be pure: framing, messages, `MessageChannel` and session rules, address parsing, geometry and sizing, pairing (code, field arithmetic, Elligator 2, PAKE, gate), identity, certificate, policies, and the Dock helper bundle pipeline (plan, plist, ad hoc signer, `CodeResources`, `.icns`, ledger) | Foundation, Crypto (CryptoKit or swift-crypto), X509 (swift-certificates) | macOS and Linux |
| `PaneshareDockLink` | The main-app ⇄ helper protocol: messages, length-prefixed framing, socket path, `DockLinkTrust` (Team ID check and the team-pinned requirement for Developer ID builds); on Darwin the socket listener/connection with peer PID and audit token | Foundation, Darwin sockets (`LOCAL_PEERPID`, `LOCAL_PEERTOKEN`) | macOS (framing also on Linux) |
| `PaneshareDockHelper` | The `paneshare-dock-helper` executable inside every generated helper app | AppKit (`NSApplication`, `applicationDockMenu`) | macOS 14+ |
| `PaneshareCapture` | Lists shareable windows (excluding our own and policy-excluded ones) and captures one window at a given pixel size | `SCShareableContent`, `SCContentFilter(desktopIndependentWindow:)`, `SCStream`, `SCStreamConfiguration` | macOS 14+ |
| `PaneshareEncode` | Low-latency encoding to AVCC access units and parameter sets | `VTCompressionSession` | macOS |
| `PaneshareAudio` | Per-app audio: capture with a Core Audio process tap (14.2+) or ScreenCaptureKit, AAC-ELD encode/decode, `AVAudioEngine` playback with one source node per remote app, `HostAudioStream` / `RemoteAudioStream` | `AudioHardwareCreateProcessTap`, `CATapDescription`, `AudioHardwareCreateAggregateDevice`, `SCStreamConfiguration.capturesAudio`, `AVAudioConverter`, `AVAudioSourceNode` | macOS 14+ (taps 14.2+) |
| `PaneshareVirtualDisplay` | One HiDPI virtual display (private `CGVirtualDisplay`, looked up at run time with type-encoding checks), its bounds and visible frame, and the availability probe (§7.3) | Objective-C runtime (`NSClassFromString`, `method_getTypeEncoding`), `CGDisplay*`, `NSScreen` | macOS 14+ |
| `PaneshareDecode` | Rebuilds the format description and sample buffers, then enqueues them for hardware decode and display | `CMVideoFormatDescriptionCreateFromHEVCParameterSets`/`…H264…`, `AVSampleBufferDisplayLayer.sampleBufferRenderer` | macOS 14+ |
| `PaneshareCore/Web` | Share links (§7.4): `HTTPRequest`/`HTTPResponse`, `WebSocketCodec` (RFC 6455), `GuestNotice`/`GuestInbound`/`GuestWire`/`GuestPointer`, `H264DecoderConfig`, `ShareLinkStore`, `ShareAddresses`, `WebRouter`, `WebCertificate`, `WebViewerAssets` (the page, CSS and script) | Foundation, Crypto, X509 | macOS and Linux |
| `PaneshareTransport` | TLS 1.3 options with SPKI pinning, `TLSMessageChannel`, host listener, dialer, `TLSIdentity`, `KeychainStore`; `WebShareServer` and `WebConnection` for share links | `NWListener`, `NWConnection`, `NWProtocolTLS`, `sec_protocol_options_*`, `SecIdentityCreate` | macOS |
| `PaneshareDiscovery` | Bonjour browse with a TXT record (host ID, protocol version) | `NWBrowser(.bonjourWithTXTRecord)` | macOS |
| `PaneshareInput` | Host side: AX window lookup, raise, resize, and CGEvent injection. Also the permission checks. | `AXUIElement*`, `CGEvent`, `AXIsProcessTrustedWithOptions`, `CGPreflightScreenCaptureAccess` | macOS |
| `PaneshareViewer` | The viewer `NSWindow` and video view, `NSEvent` to `InputEvent` translation, and the `DockPresenter` protocol with the single-process fallback | AppKit | macOS |
| `PaneshareApp` | The SwiftUI app: onboarding, host panel, viewer panel, orchestration (`HostController` → `HostPeer` → `HostStream`; `ViewerController` → `ViewerSession`; `PairingRequest` and `PairPromptPanel` on the host, `PairingClient` on the viewer; `ShareLinkController`, `ShareLinkSheet` and `GuestPointerOverlay` for share links), and the Dock helper runtime (`DockHelperFactory`, `DockLinkServer`, `HelperDockPresenter`); `UpdaterController` and `UpdateCommands` (§14) | SwiftUI, AppKit, Security (`SecCode*`, `SecStaticCode*`), Sparkle 2 | macOS 14+ |

Platform-specific targets wrap their sources in `#if os(macOS)` (or `#if canImport(Darwin)`), so `swift build` and
`swift test` run on Linux for the core and the link framing.

## 3. Wire protocol (version 1)

### 3.1 Layering

```
TCP (no Nagle, keepalive) → TLS 1.3 (mutual auth, ALPN) → paneshare frames
```

- **ALPN** `paneshare/1` is a session, allowed only for pinned peers. **ALPN** `paneshare-pair/2` is one pairing
  request (§4.2), then the connection closes. The listener exists only while sharing is on, and what a pairing
  connection may do is limited by `PairRequestLimiter` and the host user. The two are told apart before any
  application byte is sent. The pattern is adapted from Sill.
- Bonjour service type `_paneshare._tcp`. TXT keys: `v=1` (protocol version) and `id=<HostID>`, where
  HostID is 16 Crockford base32 characters taken from the first 80 bits of the host's SPKI fingerprint. The
  TXT record is only a hint, and authentication always comes from the TLS pin.
- Default TCP port 47821 (`PinnedTLS.defaultPort`; `HostListener(port:)` takes another, but there's no UI for it), so a Tailscale or manual dial has a stable target. Manual addresses are parsed by `HostAddress` (name, IPv4, bare or bracketed IPv6, optional `:port`).

### 3.2 Frame header (12 bytes, big-endian)

| Offset | Size | Field | Notes |
| --- | --- | --- | --- |
| 0 | 2 | magic | `0x50 0x57` ("PW"). Anything else is a fatal protocol error. |
| 2 | 1 | version | `1`. A receiver rejects a version it doesn't know (see 3.5). |
| 3 | 1 | kind | `MessageKind` raw value |
| 4 | 1 | flags | bit 0: keyframe, bit 1: quality top-up (both on `videoFrame`). Other bits are reserved and must be 0. |
| 5 | 1 | reserved | must be 0 |
| 6 | 2 | streamID | which shared window. `0` means connection-level. |
| 8 | 4 | length | payload byte count. It must be ≤ the receiver's direction limit: **16 MiB** host to viewer and **64 KiB** viewer to host. Over the limit is a fatal error. |

The `FrameDecoder` (in `PaneshareCore`) is an incremental parser. TCP chunk boundaries are
arbitrary, so it buffers input and emits zero or more complete frames per chunk.

### 3.3 Message kinds

| Raw value | Kind | Direction | Payload |
| --- | --- | --- | --- |
| 0x01 | `hello` | both | JSON `Hello {protocolVersion, appVersion, deviceName, role}`. It must be the first frame on a session, within 10 s. |
| 0x02 | `windowList` | H→V | JSON `[WindowInfo]`: only windows the host user offered, already filtered by `WindowPolicy` |
| 0x03 | `requestWindowList` | V→H | empty |
| 0x04 | `openWindow` | V→H | JSON `OpenWindow {windowID, viewerBackingScale, quality?, chroma?, audio?, viewerDisplay?}`. `audio: true` asks for the app's sound; absent means no. `viewerDisplay` (`WireSize`, points) is the visible size of the viewer's main screen, used to size a virtual display (§7.3); absent means 1920×1200. `quality` is `native`, `balanced` or `economy`; absent means `native`. `chroma` lists the formats the viewer accepts, best first (`"4:4:4"`, `"4:2:2"`, `"4:2:0"`); absent means 4:2:0 only. |
| 0x05 | `streamStarted` | H→V | JSON `StreamStarted {streamID, window: WindowInfo, pointSize, pixelSize, codec, appIconPNG?, inputEnabled?}`. `inputEnabled: false` means the host lacks Accessibility (view-only). Absent means enabled. |
| 0x06 | `parameterSets` | H→V | binary: `codec(1) count(1) [len(2) bytes]…` (VPS/SPS/PPS or SPS/PPS) |
| 0x07 | `videoFrame` | H→V | binary: `ptsMicros(8)` followed by one AVCC access unit (4-byte length-prefixed NALs) |
| 0x08 | `input` | V→H | JSON `InputEvent` (see 3.4) |
| 0x09 | `resize` | V→H | JSON `ResizeRequest {pointSize, final?}`. `final: false` while a live resize is in progress; absent means final (§7). |
| 0x0A | `resized` | H→V | JSON `Resized {pointSize, pixelSize, final?}`: the size the source window actually took. The viewer ignores `final: false` replies. |
| 0x0B | `closeStream` | both | JSON `CloseStream {reason}` |
| 0x0C | `requestKeyframe` | V→H | empty |
| 0x0D | `ping` / 0x0E `pong` | both | 8 bytes, echoed back, for RTT |
| 0x0F | `error` | both | JSON `ProtocolError {code, message}`, sent before close |
| 0x10 | `pairBegin` | V→H | JSON `PairBegin {viewerName, nonce}` (32-byte nonce): the pairing request. Only on `paneshare-pair/2`. |
| 0x11 | `pairResult` | H→V | JSON `PairResult {accepted, reason?, hostName?, confirm?}`, the last pairing message. `reason`: `declined`, `exhausted`, `expired`, `busy`, `notOpen`, `malformed`. |
| 0x12 | `pairChallenge` | H→V | JSON `PairChallenge {nonce, share}` (host nonce, host PAKE share) |
| 0x13 | `pairResponse` | V→H | JSON `PairResponse {share, confirm}` (viewer PAKE share and confirmation) |
| 0x14 | `inputState` | H→V | JSON `InputState {paused?}`, per stream: `secureInput` (key presses dropped), `noAccessibility` (all input dropped), or absent (normal). Sent on change. |
| 0x15 | `pairStatus` | H→V | JSON `PairStatus {state, attemptsLeft?}`: `prompted` (the prompt is on the host's screen) or `wrongCode` (the code typed there didn't match; the prompt stays up). |
| 0x17 | `audioStarted` | H→V | JSON `AudioStarted {bundleID, appName, codec, sampleRate, channels, framesPerPacket, magicCookie?, source, bitrate}` on a new stream ID: one app's audio for this viewer (§7.2). Repeated on the same ID if the format changes. |
| 0x18 | `audioFrame` | H→V | binary: `ptsMicros(8)` (host time of the first sample, the clock video uses) followed by one raw AAC-ELD packet |
| 0x19 | `audioStopped` | H→V | JSON `AudioStopped {bundleID, reason}`: `viewerMuted`, `windowsClosed`, `turnedOffOnHost`, `captureFailed` |
| 0x1A | `audioControl` | V→H | JSON `AudioControl {bundleID, enabled}`: the viewer's mute, applied at the source |
| 0x16 | `streamInfo` | H→V | JSON `StreamInfo {sourceScale?, sourcePoints, capturePixels, captureFormat, encodedPixels, codec, chroma, profile, hardware, bitrate, topUpBitrate}`, per stream, after each (re)build of the encoder. Used by the viewer's diagnostics (§7.1). |

JSON uses `JSONEncoder` with sorted keys. `Data` fields are base64. Video and parameter sets are binary,
because they're the only high-rate or large payloads. Unknown **kinds** are skipped, which is forward-compatible.
Unknown **JSON fields** are ignored. Every field added in revision 3 is optional, so revision 2 peers interoperate
on sessions (pairing changed incompatibly; both sides must run revision 3 to pair).

### 3.4 Input events and coordinates

- Pointer positions are **normalized to the window's content rect**: `x` and `y` are in [0, 1], with the origin at
  the top-left and y pointing down. The viewer converts from its flipped `NSView` coordinates. The host maps
  them onto `SCWindow.frame`, which is in global display points with a top-left origin, i.e. the same space as
  `CGEvent` locations: `global = frame.origin + (x·w, y·h)`, clamped to the frame inset by 0.5 pt.
- Scroll deltas are in points (`hasPreciseScrollingDeltas`) or lines, and carry momentum and phase.
- Keys carry the macOS virtual key code plus the modifier flag bits. Both ends are Macs, so key codes
  pass through unchanged and the host's keyboard layout applies, exactly as if the user typed locally.
- Event kinds: `mouseMove`, `mouseDown`/`mouseUp` (button, clickCount), `mouseDrag`, `scroll`, `keyDown`/`keyUp`,
  and `flagsChanged`.
- Injection order on the host: re-read the AX frame (at most every 250 ms, always on mouse-down), ask `InputGate`,
  raise the window with AX if a click targets a background window, then `CGEvent.post(tap: .cghidEventTap)`.

### 3.5 Versioning

- The `version` byte in every header and `Hello.protocolVersion` are both `1`. A peer that receives a higher major
  version sends `error {code: "unsupportedVersion"}` and closes.
- Additions within version 1 are new kinds and new optional JSON fields only. A breaking change bumps to `2`
  with a new ALPN `paneshare/2`. The host offers both ALPNs during a transition. Pairing has its own ALPN version:
  `paneshare-pair/2` replaced `/1` when the roles in the ceremony were swapped (§4.2), so an old build fails the
  handshake instead of misreading the messages. Sessions (`paneshare/1`) are unchanged.

## 4. Pairing, identity and threat model

### 4.1 Identity

- Each install has one **P-256 key**. It's stored in the Keychain as a generic password holding the raw private key
  (service `dev.paneshare.identity`, account `device-key`), with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  when the data-protection keychain is in use (the file-based login keychain has no equivalent).
  The trusted-peer list is stored next to it (account `trusted-peers`), not in `UserDefaults`, so another process
  can't add a pin by writing a plist.
- `KeychainStore` tries the **data-protection keychain** first (`kSecUseDataProtectionKeychain`), where items
  are bound to the app's code-signing identity. That needs a keychain-access-group entitlement, which in turn needs
  a provisioning profile. Ad hoc builds get `errSecMissingEntitlement` and fall back to the **login keychain**.
  There, any process running as the user could plant a key or a pin before first launch, so the **This Mac** tab
  shows which store is in use. A Developer ID build with a profile is required before treating the login-keychain
  case as closed (see README, known risks).
- An existing item that can't be read or parsed is **never silently replaced**. The app stops and offers
  "Reset identity and quit", so a Keychain hiccup can't rotate the identity and break every pairing.
- A self-signed X.509 v3 certificate is built from that key at launch with swift-certificates. Its CN is random and
  says nothing about the Mac, and its validity runs to 9999. It is never trusted by name or chain.
- The **fingerprint** is SHA-256 of the DER SubjectPublicKeyInfo. That's the pin, i.e. the "pinned identity key"
  of the spec. The HostID is a base32 prefix of it, for display and the Bonjour TXT record.
- Divergence from the spec's two-key design (an Ed25519 identity signing a separate TLS key): one key does both, so
  there's no signature to verify and nothing to keep in sync. If a later transport can't carry our certificate
  (for example WebRTC's DTLS), the same P-256 key signs that transport's fingerprint (§13.2).

### 4.2 Pairing ceremony: requested from the viewer, accepted on the host

Our own construction after the CPace design (draft-irtf-cfrg-cpace), on X25519 from CryptoKit, with the
Elligator 2 map from RFC 9380 implemented in `PaneshareCore/Pairing/Curve25519Field.swift`. No PAKE library is used.
The flow is version 2 (ALPN `paneshare-pair/2`); version 1 made the host user open a pairing window first.

1. **Ask.** On the viewer (Mac A) the user clicks **Pair** next to a discovered Mac, or uses **Pair by address**. The
   viewer makes a **6-digit code** (uniform from a CSPRNG, shown as `482 913`) and shows it with "This Mac's ID"
   (its fingerprint's short ID). It dials with ALPN `paneshare-pair/2` and completes mutual TLS 1.3. Each side records
   the **other side's fingerprint from the TLS session**, never from a message. The viewer sends
   `pairBegin {viewerName, nonceV}`.
2. **Prompt.** The host (Mac B) runs the request past `PairRequestLimiter` (below). If admitted, it replies
   `pairStatus {prompted}` and shows a floating panel on every Space: "“A” wants to pair with this Mac", the
   requester's ID and address, a code field, a 5:00 countdown, **Decline** and **Accept**. The panel is
   non-activating, so it can be typed into without switching apps; if paneshare isn't frontmost the Dock icon bounces
   and a notification is posted. The panel is `sharingType = .none`. Nothing has to be prepared on the host first.
3. **Accept = one attempt.** The host user types the code shown on A and clicks Accept. The host's `PairingGate`
   spends one attempt and sends `pairChallenge {nonceH, Yh}` keyed by **the typed code**. The viewer's own
   `PairingGate` also spends one attempt per challenge it receives, and answers `pairResponse {Yv, confirmV}` keyed
   by **its code**. Both sides compute, with `lv(x)` = 2-byte big-endian length ‖ x:
   - `G = Elligator2(SHA-512(lv("paneshare-pake-v1") ‖ lv(code) ‖ lv(fp_host ‖ fp_viewer) ‖ lv(nonceV ‖ nonceH))[0..<32])`
   - Each side picks a fresh X25519 scalar `y` and sends `Y = X25519(y, G)`. The shared secret is `K = X25519(y, Y_peer)`;
     an all-zero `K` (a low-order share) is rejected, and so is `G` = 0.
   - `transcript = lv(label) ‖ lv(fp_host ‖ fp_viewer) ‖ lv(nonceV ‖ nonceH) ‖ lv(Yh) ‖ lv(Yv)`
   - `kV ‖ kH = HKDF-SHA256(K, salt = SHA-256(transcript), info = "paneshare-pake-v1 confirm", 64 bytes)`
   - `confirmV = HMAC-SHA256(kV, "viewer" ‖ transcript)`, `confirmH = HMAC-SHA256(kH, "host" ‖ transcript)`

   Every attempt uses a fresh `nonceH` and fresh scalars, so no two attempts share a generator.
4. **Verdict.** The host checks `confirmV` in constant time. On a match it pins `fp_viewer` and replies
   `pairResult {accepted, hostName, confirm: confirmH}`; the viewer checks `confirmH` in constant time and only then
   pins `fp_host`. On a mismatch the host sends `pairStatus {wrongCode, attemptsLeft}` and the prompt stays up for
   another try. Decline sends `pairResult {declined}`. The fifth wrong code, or 5 minutes, ends the request on both
   sides (`exhausted`, `expired`). Each request is single-use: after one success both gates are closed.
5. Later sessions use ALPN `paneshare/1`. Each side's TLS verify block accepts the peer **only if its
   fingerprint is pinned**. No chain evaluation is done, so there's no network fetch and no CA trust.

**Spam limits** (`PairRequestLimiter`, pure and unit-tested). A stranger can mint a new key per request, so limits
are per address and overall as well as per key:

- one prompt on screen at a time; a second request gets `pairResult {busy}`;
- at most 3 prompts per address and 10 overall per 10 minutes;
- after a decline or a failed request (wrong codes used up, expired, malformed), that key **and** that address are
  ignored for 2 minutes;
- an ignored request is closed **without an answer**, so a flood learns nothing;
- a request that never sends `pairBegin` is dropped after 10 s.
- turning sharing on (a host-user action) clears the limits.

The host advertises over Bonjour, listens, and accepts pairing requests **only while "Share windows from this Mac" is
on**. Turning sharing off cancels a pending prompt.

**Why this scheme.** Three candidates give the requester-initiated, consent-on-the-target flow:

| Scheme | MITM resistance | Who must act | Verdict |
| --- | --- | --- | --- |
| Numeric comparison (both show a code derived from the session; the host user clicks "match") | Good only if users really compare; a tired user clicks Accept without looking. An attacker can also make A *display* "accepted", so A must confirm too. | Both users click, one compares | Weaker in practice |
| Code shown on B, typed on A | PAKE-strong | The consent is typed on the requester, so B's prompt becomes a "show code" panel | Consent lands on the wrong Mac |
| **Code shown on A, typed on B (chosen)** | PAKE-strong: an active MITM, even one that relays every message, can test one guess per attempt; 5 attempts give 5 × 10⁻⁶. It learns nothing testable offline. | Only B's user types; A's user reads out the code | Strongest and simplest |

Typing is a deliberate act, so a prompt can't be accepted by reflex, and the code being entered on the target is
also the consent. The existing PAKE and its test vectors are reused unchanged; only who shows and who types moved.
The host still gives the 5 attempts, 5-minute and single-use limits, and the viewer enforces them independently, so a
malicious "host" can't run unlimited guesses against a viewer's code either.

Why a PAKE rather than the spec's `HKDF(X25519, salt = code)`: with a plain key exchange salted by the code, an
active attacker who completes one exchange can test all 10⁶ codes offline against the confirmation MAC. With the
code inside the generator, each run of the protocol tests **one** guess. Fixed test vectors in `PairingTests.swift`
were cross-checked against an independent Python implementation written for this project.

### 4.3 Threat model

| Adversary | Attack | Mitigation | Residual risk |
| --- | --- | --- | --- |
| Passive LAN or tailnet observer | Reads the video, input or pairing exchange | TLS 1.3 (ECDHE, AEAD) on every byte, and no plaintext listener. Pairing messages travel inside TLS and reveal nothing about the code even if TLS were stripped (PAKE). | Traffic analysis (frame sizes and timing) |
| Active MITM during pairing | Sits between the viewer and the host | The generator binds both TLS fingerprints, so a MITM presenting its own keys derives a different `G` from each side. It learns nothing testable offline and gets one online guess per attempt; both sides cap a request at 5 attempts, so 5 × 10⁻⁶. The host prompt shows the requester's ID, which the user can compare with "This Mac's ID" on the viewer. | A MITM that can also read the viewer's screen (shoulder surfing) |
| Pairing spam | A stranger floods the host with requests, hoping a user clicks through, or just to annoy | The code must be **typed**, not clicked. One prompt at a time; 3 per address, 10 overall per 10 minutes; 2-minute cooldown on key and address after a decline or failure; over-limit requests are closed without an answer. No pairing at all while sharing is off. | A LAN attacker with many addresses can still put up to 10 prompts per 10 minutes on screen |
| Active MITM after pairing | Impersonates a host or a viewer | SPKI pins on both sides. Tickets and resumption are off, so a removed peer can't resume a session. | Theft of the private key from a logged-in Mac |
| Rogue Bonjour advertiser | Spoofs a host name or ID | The TXT record is only a hint. The connection fails the pin, and an unpaired host must go through pairing. | Denial of service by advertisement flooding |
| Unpaired peer | Connects to the listener | A session ALPN without a pin fails inside the handshake. A pairing connection can only ask, and gets nothing without the host user typing the right code; `PairRequestLimiter` caps how often it may ask. Handshake, `hello` and `pairBegin` timeouts are 10 s each. The listener only runs while hosting is on, and connections are capped at 8. | Resource use from half-open TCP connections |
| Paired but malicious viewer | Tries to act outside the shared window | Input is accepted only for streams this connection opened. Pointer coordinates are clamped to the window frame. Keys are posted only when the target window's process is frontmost after a raise (`InputGate`). Only windows the host user offered are listed or openable. | A paired viewer fully controls the shared window by design, including whatever that app can reach. The host user is shown a "Sharing to …" status. |
| Viewer typing into a host password field | The host user (or the shared app) is entering a secret while the viewer types | `IsSecureEventInputEnabled()` is checked every 0.5 s and on every key press; while it's on, key presses are dropped (releases and modifier changes still pass so nothing sticks), and the viewer is told (`inputState`). | The check is global, not per app: any app with secure input on pauses typing on every stream |
| Local process driving the Dock helper channel | Connects to `dock.sock` and sends `choose`/`closeAll`, or impersonates the main app to a helper | The socket is 0600 inside a 0700 directory. The main app accepts a helper only if its audit token resolves to code whose signing identifier is a helper key it generated **and** whose cdhash is the one it signed (`SecCodeCheckValidity` with `identifier "…" and cdhash H"…"`). A helper only talks to a peer whose PID belongs to the main app's bundle ID (and, when the main app launched it, equals its parent PID). | A process running as the same user that can also write our Application Support folder could replace a helper bundle; it would fail the cdhash check and be re-generated |
| Local malware with Screen Recording | Reads the pairing code | The host's prompt, where the code is typed, is `sharingType = .none`. The code shown on the viewer is only useful to an attacker who is also an active MITM on that request, before the host user finishes it, and it is single-use and expires after 5 minutes. | Malware on the viewer that reads the code and feeds a LAN MITM in real time; malware with Accessibility trust can drive the UI |
| Sensitive windows | A password manager, a system password prompt or a hidden window gets shared | `WindowPolicy`: a fixed system-auth list (`com.apple.SecurityAgent`, `com.apple.LocalAuthentication.UIAgent`, `com.apple.coreautha`, the AuthenticationServices agent, `loginwindow`, the screen saver) that user settings can't override; a password-manager deny-list (1Password, Bitwarden, Dashlane, LastPass, KeePassXC, Keeper, Enpass, NordPass, Proton Pass, Keychain Access, Passwords) plus user additions; hidden apps (`NSRunningApplication.isHidden`); non-normal layers; tiny windows; our own process and helpers (`dev.paneshare.`). Applied before the list leaves the host **and again when a window is opened by ID**. The system already excludes `sharingType = .none` windows. | A deny-list is never complete; bundle IDs drift between releases |

Other security rules:

- The app never runs shell commands: no `Process`/`NSTask`/`popen` in `Sources/`. Dock helpers are signed **in
  process** by `AdHocSigner`, not with `codesign`. (`scripts/make-app.sh` and one macOS-only test call `codesign`
  as developer tools; neither ships.)
- TLS verification is never disabled. The verify block always pins.
- There's no telemetry.

## 5. Swappable seams

Each is a protocol in the app layer:

```swift
// PaneshareViewer. How remote windows appear in the Dock and Command-Tab.
@MainActor
public protocol DockPresenter: AnyObject {
    func didOpen(_ remote: RemoteWindowIdentity, window: NSWindow, appIcon: NSImage?)
    func didActivate(_ remote: RemoteWindowIdentity)
    func didClose(_ remote: RemoteWindowIdentity)
}
// RemoteWindowIdentity = (host fingerprint, host name, windowID, appName, bundleID).

// PaneshareCore. A bidirectional, authenticated, ordered message channel to one peer.
public protocol MessageChannel: AnyObject, Sendable {
    /// From the authenticated channel, never from a message.
    var peerFingerprint: Fingerprint? { get }
    var onMessage: (@Sendable (Frame) -> Void)? { get set }
    var onClose: (@Sendable (Error?) -> Void)? { get set }
    func send(_ frame: Frame)
    /// Non-key video only; false when dropped under backpressure.
    @discardableResult func sendDroppable(_ frame: Frame) -> Bool
    func close()
}
```

- **Dock and Command-Tab:** `HelperDockPresenter` (one helper app per remote app, §6) is the default.
  `SingleProcessDockPresenter` (one icon that follows focus) is the fallback when helpers are turned off
  (`defaults write dev.paneshare.app dockHelpers -bool false`) or a helper can't be built, keeps crashing, or
  launches but doesn't say hello within 10 s (stopped at launch). After two silent helpers in a session, all apps
  use it until relaunch. `paneshare --dock-helper-selftest <file>` runs one helper round trip with no host (RELEASING §5).
- **Transport:** the MVP uses `TLSMessageChannel` (Network.framework, TCP plus TLS 1.3). The app layer
  (`HostPeer`, `HostStream`, `ViewerSession`) depends only on `MessageChannel`. `TLSMessageChannel`,
  `HostListener` and `Dialer` are the only code that knows about Network.framework. A replacement transport has to
  provide an authenticated peer fingerprint, ordered reliable delivery for control frames, and a droppable path for
  video. Pairing needs only the two fingerprints. The planned replacement is LiveKit (§13.2).

## 6. Dock and Command-Tab

macOS gives **one Dock tile and one Command-Tab entry per process** whose activation policy is
`.regular`. A single process can change its icon and list windows in its Dock menu, but it **cannot add
Command-Tab entries**. So each remote app gets a tiny helper process of its own.

### 6.1 Options considered

| Option | How | Dock | Command-Tab | Verdict |
| --- | --- | --- | --- | --- |
| A. Single process | The viewer app's icon follows the frontmost remote app; the Dock menu lists every remote window | 1 tile | 1 entry | Kept as the fallback |
| B. Activation-policy toggling | Switch `.regular`/`.accessory` | 0 or 1 tile | 0 or 1 entry | Rejected: doesn't multiply |
| **C. Helper app per remote app** | A generated `.app` per (host, remote bundle ID) that only proxies activation and the Dock menu | One per remote app, pinnable | One per remote app | **Shipped** (the spec's approach) |
| D. Helper per window | C keyed on window ID | One per window | One per window | Possible by changing the key; clutters the Dock |
| E. Windows inside the helper | The helper owns the `NSWindow` and video | Natural | Natural | Long-term; needs IOSurface over XPC or a decoder per helper |

Private Dock SPI was rejected: fragile across releases.

### 6.2 Generating a helper (`DockHelperFactory`, `HelperBundlePlan`)

- **Key and names:** bundle ID `dev.paneshare.dock.<hostID lowercased>.<sanitized remote bundle ID>`, display name
  `<App> on <Host>` (slashes, colons, leading dots and newlines stripped). Path
  `~/Library/Application Support/paneshare/DockHelpers/<host>/<app>/<name>.app`.
- **Contents:** `Contents/MacOS/paneshare-dock-helper` copied from the main app's `Contents/Helpers/`;
  `Info.plist` with `CFBundleIdentifier`, `CFBundleName`, `CFBundleIconFile`, `LSMinimumSystemVersion`,
  `NSPrincipalClass`, and our keys `PaneshareHostID`, `PaneshareRemoteBundleID`, `PaneshareMainBundleID`; no
  `LSUIElement` (it must be `.regular`); `CFBundleVersion` = `HelperBundlePlan.revision`.
- **Icon** (`HelperIconLayout` in Core, drawn by `HelperIcon` in the app): on the macOS icon grid (body 824/1024,
  the same n = 4.6 superellipse as paneshare's own icon), a **ring in the source Mac's colour**
  (`SourceMacColor`: 8 system hues, index = fingerprint byte 0 mod 8), the remote app's icon (sent by the host in
  `streamStarted.appIconPNG`) scaled so its body sits just inside the ring, and from 64 px up a **paneshare badge**
  at the bottom right. Each size is drawn separately rather than downscaled: at 16 and 32 px the ring is 9% of the
  canvas (at least 1.5 px) and there's no badge, so the coloured outline still reads in a small Dock or the
  Command-Tab list; from 64 px it's 5.5%. A soft dark edge under the ring keeps light hues visible on a light Dock.
  `ICNSWriter` writes all ten entries (icp4 16, ic11 32@2x, icp5 32, ic12 64@2x, ic07 128, ic13 256@2x, ic08 256,
  ic14 512@2x, ic09 512, ic10 1024@2x). `scripts/icon/helper-preview.py` renders the same geometry for review.
- **Revisions:** the ledger records `HelperBundlePlan.revision` for each helper, and a helper from an older
  revision (or a ledger written before revisions) is regenerated rather than reused, so changes like the ring
  reach helpers already in the Dock. Revision 2 = ring icon.
- **Signing, in process:** `AdHocSigner` parses the thin arm64 or x86_64 Mach-O, grows `__LINKEDIT`, rewrites
  `LC_CODE_SIGNATURE`, and writes a SuperBlob with a CodeDirectory (version 0x20400, ad hoc flag, SHA-256 page
  hashes of 4 KiB pages, special slots for `Info.plist`, an empty requirements set and the sealed
  `_CodeSignature/CodeResources`, exec segment = `__TEXT`) and an empty CMS blob. `BundleSeal` writes
  `CodeResources` (files/files2 with SHA-1 and SHA-256, the standard rules). Formats come from Apple's open-source
  xnu headers (`cs_blobs.h`, `loader.h`). The output was compared against a third-party ad hoc signer used only as a
  development check (THIRD_PARTY.md): identical except for reserved-size fields and the resource seal it computes.
- **Developer ID builds** (docs/RELEASING.md §5): the template in `Contents/Helpers` is Developer ID signed and
  notarized with the app; each generated helper is still ad hoc signed locally, which works because files
  paneshare writes carry no quarantine, so Gatekeeper never assesses them. The factory reads its own Team ID
  (`SecCodeCopySigningInformation`) and puts it in each helper as `PaneshareMainTeamID` plus an
  `NSUpdateSecurityPolicy` (only paneshare may update the helper), and strips `com.apple.quarantine` from staged
  files as a precaution.
- **Install:** stage in a sibling `.staging-<uuid>.app`, verify with `SecStaticCodeCheckValidity` (strict, all
  architectures, requirement `identifier "<id>" and cdhash H"<hash>"`), then move into place and record the cdhash in
  `DockHelperLedger`. An existing valid helper of the current revision is reused; anything else is replaced. No quarantine attribute is
  ever set, because we write the bundle ourselves.
- **Housekeeping:** at launch, delete helpers of hosts that are no longer paired, and helpers unused for 30 days
  unless pinned in the Dock (`DockPins` reads `com.apple.dock` `persistent-apps`, read-only) or running.

### 6.3 The local link (`PaneshareDockLink`, `DockLinkServer`)

- Socket `~/Library/Application Support/paneshare/run/dock.sock`; directory 0700, socket 0600 (created under
  `umask 0177`). Frames: 4-byte big-endian length + JSON, at most 64 KiB. `SO_NOSIGPIPE`, 1 s send timeout,
  close-on-exec.
- Helper → main: `hello {helperKey, protocolVersion, coldStart}` (within 3 s of connecting), `activated`,
  `choose {windowID}`, `closeAll`, `userQuit`. Main → helper: `menu {items: [{windowID, title}]}`, `quit`.
- The main app checks each connection: `LOCAL_PEERTOKEN` audit token → `SecCodeCopyGuestWithAttributes` →
  `SecCodeCheckValidity` against `identifier "<helperKey>" and cdhash H"<recorded cdhash>"`. Keys are checked
  against a strict character set before they go into the requirement string.
- The helper checks the server: the socket peer's PID (`LOCAL_PEERPID`) must belong to `PaneshareMainBundleID`, and
  must equal `PANESHARE_PARENT_PID` when the main app launched it. When its `Info.plist` has `PaneshareMainTeamID`
  (Developer ID builds), the peer's running code, looked up by audit token, must also satisfy `anchor apple
  generic and identifier "<main>" and certificate leaf[subject.OU] = "<team>"` (`DockLinkTrust`). If the key is
  present but malformed, the helper refuses rather than falling back.

### 6.4 Helper behaviour (`paneshare-dock-helper`)

- `.regular` app with no windows and no menu bar items of its own. It sets nothing on disk.
- **Activation** (Dock click, Command-Tab, `applicationShouldHandleReopen`): send `activated`, then
  `NSApp.yieldActivation(toApplicationWithBundleIdentifier:)`. The main app calls `NSApp.activate()` and
  `makeKeyAndOrderFront` on that app's windows, most recent first.
- **Dock menu:** `applicationDockMenu` lists the windows from the last `menu` message, then **Close All**.
- **Quit:** user quit (Dock or Command-Tab Cmd-Q) sends `userQuit`, and the main app closes that app's windows;
  a `quit` from the main app (last window closed) just exits.
- **Watchdog:** every 2 s `kill(parentPID, 0)`; exit if the main app is gone, so no orphan icons stay behind.
- **Cold start** (a pinned icon clicked while paneshare isn't running): launch the main app by bundle ID, retry the
  socket for 15 s, say `hello {coldStart: true}`; the main app connects to that host and opens that app's windows,
  and asks the helper to quit after 30 s if nothing opened.
- **Failure policy:** a helper that exits unexpectedly is relaunched up to twice; after that the main app falls
  back to the single-process presenter for that app.

### 6.5 Known limitations

- After a helper hands activation to the main app, Command-Tab shows **paneshare** as the frontmost app, not the
  helper. The helper's entry stays in the list, and choosing it again works. Option E would remove this.
- The activation hop costs a frame or two of focus flicker.
- LaunchServices may take a moment to pick up a new helper's icon the first time.

## 7. Data flow and sizing

1. The host user picks a window in the host panel, which marks it **offered**. The viewer receives `windowList`
   and opens it (`openWindow` with the viewer's `backingScaleFactor` and the chosen `quality`, a viewer setting:
   **Quality for new windows**).
2. The host computes `pixelSize = even(round(pointSize × min(viewerScale, 4) × quality))`, with quality 1.0
   (native), 0.75 (balanced) or 0.5 (economy), clamped to 16 384 px per side and to a 40 MP area
   (`Sizing.pixelSize(points:scale:quality:)`), then starts `SCStream` with
   `SCContentFilter(desktopIndependentWindow:)`, that size and BGRA pixels (`scalesToFit = true`). Native on a
   2× viewer is the window's full backing resolution; the viewer shows it 1:1 (§7.1). We don't oversample above the viewer's backing scale:
   at 1:1 display it adds no detail and costs bandwidth.
3. Frames whose `SCFrameStatus` is `.complete` go to the encoder. `.idle` frames (unchanged content) are
   skipped, so a still window costs almost nothing. The encoder is a mailbox: **one** frame inside VideoToolbox,
   plus at most one waiting, which a newer frame replaces. Older frames are **dropped, not queued**. A keyframe request
   while the window is still re-encodes the last frame, so a viewer that joins or recovers gets a picture at once.
   Once the window has been still for 150 ms the last frame is re-encoded as **quality top-up** P-frames (§7.1).
4. The encoder emits parameter sets on every keyframe (`parameterSets` before the `videoFrame` with flag bit 0
   set). The viewer rebuilds `CMVideoFormatDescription` whenever they change.
5. The viewer enqueues each access unit as a `CMSampleBuffer` with `DisplayImmediately` on an
   `AVSampleBufferDisplayLayer` (`videoGravity = .resizeAspect`) whose `contentsScale` is the window's backing scale.
   At native quality the window's content size is exactly `stream px / backing scale` (§7.1).
6. **Resize with a frozen stream size.** During a live resize the viewer sends `resize {final: false}` (coalesced to
   one every 100 ms). The host applies the AX size so the real window follows the drag, but keeps the encoder and
   `SCStream` at their current pixel size: ScreenCaptureKit scales the window into it and the viewer letterboxes the
   picture. On mouse-up the viewer always sends `resize {final: true}`; a one-shot resize (zoom, tiling) is final
   at once. For a final request the host reads back the size the app accepted, and if the pixel size changed it
   reconfigures `SCStream` (`updateConfiguration`), recreates the encoder, forces a keyframe, and replies
   `resized {final: true}`. If no final request arrives (a lost mouse-up), the host does the same 1 s after the
   last request. The viewer snaps its content size only to final replies.

### 7.1 Text sharpness at native quality

The goal at **Native** is a 1:1 pixel mapping: one captured pixel → one encoded pixel → one screen pixel, with no
resampling anywhere and enough bits that small text isn't smeared. Each stage and what keeps it 1:1:

| Stage | Risk | What paneshare does |
| --- | --- | --- |
| Capture | Capturing at 1× and upscaling on a 2× viewer; 4:2:0 capture throwing away colour detail before the encoder | `pixelSize = points × viewer scale` (never below the viewer's scale at native); the capture format is BGRA, so the encoder gets full colour resolution. The host logs the source window's `pointPixelScale`. |
| Chroma | 4:2:0 halves colour resolution, so coloured and subpixel-rendered text fringes | The viewer sends the formats it accepts (`openWindow.chroma`, default 4:4:4, 4:2:2, 4:2:0). The encoder asks VideoToolbox which `ProfileLevel` names the session supports and picks the richest the viewer accepts (HEVC Main 4:4:4, then 4:2:2, 8-bit first), else Main/High 4:2:0. Streams are tagged BT.709. If the viewer can't decode a 4:2:2/4:4:4 stream it re-opens the window in 4:2:0 for the rest of the session. |
| Rate control | A bitrate tuned for motion leaves text blocky; a still window sends no new frames, so the blur never clears | Base rate 0.1 bit per pixel per frame (×1.25 for 4:2:2, ×1.5 for 4:4:4), 2–50 Mb/s before the chroma factor, set as both average rate and a 1-second data-rate limit. After 150 ms with no change the encoder re-encodes the last frame twice as P-frames at max(8 × base, 40 Mb/s), capped at 400 Mb/s (`videoFrame` flag bit 1), then restores the base rate. This is the spec's quality top-up: the picture converges to near-lossless without a keyframe stall. |
| Viewer size | Window points that differ from `stream px / scale` by a fraction rescale the whole picture | `DisplayFit`: at native the content size is set to exactly `stream px / backing scale` on open, on every final resize reply, when the decoded size changes and when the window moves to a screen with another scale. |
| Viewer layer | Default linear filtering and a stale `contentsScale` | `contentsScale` follows the window's backing scale, including when the view first joins a window; at 1:1 the layer uses nearest filtering (linear only when scaled). |

**Diagnostics.** `defaults write dev.paneshare.app debugOverlay -bool YES` (restart, then open a window) shows an
overlay in each remote window and logs it every 5 s and on every change: the host window's points and scale,
capture px and format, encoder codec, chroma, profile, hardware or software, encoded px, target and top-up bitrate,
decoded px, displayed px and points at the viewer's scale, the mapping (`1:1` or `scaled ×…`), received bitrate,
fps and top-up count. The host logs one `paneshare host stream …` line per encoder build regardless.
`defaults write dev.paneshare.app chroma 4:2:0` (or `4:2:2`, `4:4:4`, `auto`) caps the chroma the viewer asks for.

### 7.2 Per-app audio

Each shared app's sound goes to the viewer that has one of its windows open, on its own stream:

1. **When it flows.** `HostPeer` keeps at most one `HostAudioStream` per (viewer, app). It runs exactly while
   the viewer has a window of that app open, asked for audio (`openWindow.audio`, or a later
   `audioControl {enabled: true}`), and `AudioPolicy` allows it. `AudioPolicy` reuses the window policy's
   app-level rules (`WindowPolicy.appRejection`): system authentication UI, password managers and the deny-list,
   and paneshare itself, are **always off**, with no switch to turn them on. The host user can also turn sharing
   of sound off entirely (`shareAudio`) or per app (`audioMutedApps`) in the host panel; both default to on
   for normal apps. Closing the app's last window, the viewer's mute, or a host switch stops the stream with
   `audioStopped`.
2. **Capture.** On macOS 14.2+ a private Core Audio **process tap** (`CATapDescription(stereoMixdownOfProcesses:)`,
   `muteBehavior = .unmuted`) on every audio process of the app — its own PID plus helpers whose bundle ID is the
   app's ID plus a dot, re-evaluated when the system's process list changes — read through a private aggregate
   device's IO proc. The tap needs the "System Audio Recording" permission (`NSAudioCaptureUsageDescription`).
   If the tap can't be made (macOS 14.0–14.1, permission denied), **ScreenCaptureKit** captures the app's audio
   instead (`SCContentFilter(display:including:[app])`, `capturesAudio`, a 2×2 video output that is ignored).
   `defaults write dev.paneshare.app audioCapture screenCaptureKit` forces the fallback for testing.
3. **Codec: AAC-ELD**, 48 kHz stereo, 96 kb/s, 512-sample packets (10.7 ms), through `AVAudioConverter`. Chosen
   over Opus because it is built into macOS (no C library to vendor or license), it is made for conferencing
   latency, and both ends use public API. Opus would be needed only for a browser viewer.
4. **Timestamps.** `AudioTimeline` maps captured sample counts to host time (µs, mach host clock — the same
   clock as ScreenCaptureKit's video timestamps), re-anchoring after a capture gap over 20 ms. Each packet's
   `ptsMicros` is the host time of its first sample, corrected for the encoder's priming delay.
5. **Playback.** `RemoteAudioStream` decodes on its own serial queue and pushes into an `AudioJitterBuffer`
   behind an unfair lock; an `AVAudioSourceNode` per remote app pulls from it on the render thread (no
   allocation) into one shared `AVAudioEngine`. The buffer waits for **40 ms** before playing (and again after
   running dry), drops the oldest audio when it holds more than **120 ms**, fills timestamp gaps up to 200 ms
   with silence, and starts over on a longer gap or a jump backwards.
6. **Sync.** Video is shown as soon as it decodes; audio plays about 40 ms (jitter target) plus the device's
   output latency behind capture. Since video spends roughly as long in encode, network and decode, the two
   stay within the ITU-R BT.1359 window (audio no more than 45 ms early or 125 ms late). `AVSync.skewMillis`
   computes the skew from the two host timestamps for diagnostics; the jitter buffer's cap keeps audio from
   drifting late. Audio frames are sent reliably (`send`, not `sendDroppable`): they are small, and dropping is
   left to the viewer's buffer.
7. **Viewer controls.** Each host row lists the apps with a window open, with mute and a volume slider. Settings
   are saved per (host, app) in `AudioMixSettings` (UserDefaults `audioMix`). Volume is the source node's gain;
   mute also sends `audioControl {enabled: false}`, so a muted app costs no bandwidth, and windows of that app
   are opened with `audio: false` from then on.

Known limits: Safari and other WebKit apps play web audio from `com.apple.WebKit.WebContent` processes that
can't be attributed to one app with public API, so their web audio isn't captured by the tap (the
ScreenCaptureKit fallback may catch it). There is no echo cancellation or microphone path; paneshare only sends
app output.


### 7.3 Virtual display (headless hosts and oversized windows)

A window can only be as big as the screen it is on, and a Mac with no screen attached (a headless Mac mini)
has only a small fallback framebuffer. So the host can create an invisible **virtual display** per viewer,
sized like that viewer's screen, and move shared windows onto it.

1. **Setting.** Host panel → "Virtual display": **Off** (the default), **When needed** (`auto`) or **Always**,
   stored in UserDefaults `virtualDisplay`. It applies to windows opened, or resized, from then on.
2. **Decision.** `VirtualDisplayPlanner.decide` (Core, unit-tested) returns `useRealScreen`, `useVirtual(size)`
   or `unavailable(reason)`. With **When needed**, a virtual display is used when the host has no physical
   screen, or when the window (or the size the viewer asked for in a final `resize`) doesn't fit on the largest
   physical screen. With **Always**, every shared window moves. The physical screens are `NSScreen.screens`
   minus our own virtual displays.
3. **Size.** The viewer sends the visible size of its main screen in `openWindow.viewerDisplay`. The display is
   that size in points (default 1920×1200, clamped to 640×480…3840×2400, rounded to even), and at least as big
   as the window. It has **one HiDPI mode**: the point size at scale 2, so a 1728×1080 pt display renders
   3456×2160 px and text stays sharp at native quality (§7.1). The display's serial is derived from the viewer's
   fingerprint, so macOS remembers its arrangement between sessions.
4. **Sharing and lifetime.** `VirtualDisplayManager` keeps at most one display per viewer, reference-counted by
   that viewer's streams. `HostStream.start()` (and a final resize that no longer fits) moves the window there with
   AX (`kAXPositionAttribute`, placed at the top-left of the display's visible frame) and remembers its original
   origin. When the stream ends (closed by the viewer, viewer disconnect, hosting stopped, or the app quitting) the
   window is moved back to its original origin and the display is released; the last release destroys it.
5. **Crash cleanup.** A virtual display belongs to the process that created it. If paneshare crashes or is
   force-quit, WindowServer removes the display and macOS moves its windows onto a remaining screen, as it does
   when a monitor is unplugged. They don't go back to their exact original positions in that case; nothing is
   left behind to clean up on the next launch. On a normal quit (`willTerminate`) hosting stops first, which
   moves every window back, and then any remaining displays are destroyed.
6. **Degrading.** `VirtualDisplay.apiProblem` checks once that the four classes exist and that every selector
   paneshare calls has the expected Objective-C type encoding (`ObjCTypeEncoding.matches`). If anything is
   missing or different, the feature is **unavailable**: the host panel says so, the log says why once, and
   windows stay on the real screen (with the usual clamp to it). If creating a display fails at run time, or it
   doesn't come online within 3 s in its HiDPI mode, the stream continues on the display as macOS brought it up (logged); if it doesn't come up at all, the stream continues on the real screen too.

**Private-API risk.** `CGVirtualDisplay` is undocumented and not part of the SDK. Consequences:

- **No Mac App Store.** App Review guideline 2.5.1 forbids non-public APIs. paneshare is distributed outside the
  store (Developer ID plus notarization, which doesn't review API use).
- **It can break in any macOS update.** The run-time checks turn that into "unavailable" rather than a crash, but
  the feature would stop working until updated. It has been stable since macOS 11, and DeskPad, BetterDisplay
  and Sill rely on it.
- **Behavior is unspecified.** Display arrangement, mirroring with "Displays have separate Spaces" off, and
  interaction with Stage Manager are not documented; these are covered by the two-Mac tests (TESTING §4.8).
- It's off by default, so a host that never turns it on never calls the private API (the availability probe only
  looks classes and methods up).

Known limits: a window shared with two viewers moves to the first viewer's display only. Windows that refuse AX
moves (some full-screen or fixed-position windows) stay where they are. A display is not resized when the viewer
moves to a different screen mid-session; it is sized when the first window opens.

### 7.4 Share links (browser guests)

A **share link** lets someone without paneshare view one shared window in a browser, with their own pointer,
installing nothing. It works wherever the guest can reach the host directly: the same LAN, or the same
Tailscale tailnet. There is no relay and nothing is deployed; internet-reachable links are a design only
(`docs/SHARE-LINKS-INTERNET.md`).

**Why WebCodecs over a WebSocket, not WebRTC.** WebRTC needs ICE, DTLS-SRTP, SDP and congestion control on the
host, which means a large native dependency (libwebrtc or pion via cgo). The host already produces H.264 access
units with VideoToolbox, and every current browser can decode them with `VideoDecoder` (WebCodecs: Chrome and Edge
94+, Safari 16.4+, Firefox 130+). A secure WebSocket carries them in TCP order, and the existing backpressure rule
(drop non-key frames past 2 queued) bounds latency the same way it does for paired viewers. The cost is
TCP head-of-line blocking on lossy links; that's acceptable on a LAN or tailnet. WebRTC remains the path for
the LiveKit upgrade (§13.2).

**Flow.**

1. The host (hosting on, window shared) clicks the link button on that window and picks a lifetime: 15 min,
   **1 h** (default) or 8 h (`ShareLinkStore` caps at 24 h), and whether the guest may point and click.
2. `ShareLinkController` starts `WebShareServer` if it isn't running, and `ShareLinkStore.create` makes a link:
   a 128-bit random **link ID** and a 256-bit random **token**, both base64url. The store keeps only the token's
   SHA-256. The sheet shows one URL per address, ranked Tailscale (100.64.0.0/10) first, then LAN, then the
   Bonjour `.local` name: `https://<host>:47822/s/<linkID>#<token>`, plus the server certificate's SHA-256 so the
   guest can check the browser's warning against it. The token is shown once; closing the sheet forgets it.
3. The token is in the **fragment**, so the browser never sends it in the request line, logs or a `Referer`. The page
   (`/s/<linkID>`, served only while that link is live) loads `viewer.js`, which reads the fragment, removes it
   with `history.replaceState`, asks for a display name, and opens `wss://<same host>/ws`.
4. The first WebSocket message is `join {link, token, name, scale}`. `ShareLinkStore.redeem` compares the digest in
   constant time, marks the token **used**, and returns a guest session ID plus a 256-bit **session secret**.
   The page keeps those in `sessionStorage` (this tab only), so a reload or a network blip resumes with
   `join {link, session, secret}`. Five bad tokens burn the link.
5. The host starts a `HostStream` for the guest with the `WebConnection` as its `MessageChannel`, H.264 only, 4:2:0,
   balanced quality, and a pixel scale of 1–2 from the guest's `devicePixelRatio`. No virtual display is made for a
   guest. `GuestWire` translates what the stream sends: `streamStarted` → `started`, `parameterSets` → `config`
   (codec string `avc1.PPCCLL` and the avcC record, from `H264DecoderConfig`), `videoFrame` → binary,
   final `resized` → `size`, `closeStream` → a close code. Audio, cursor and other messages are dropped.

**Guest wire.** Server → browser: JSON text notices with a `t` field, and binary video.

| Message | Fields | Meaning |
| --- | --- | --- |
| `welcome` | `session`, `secret` (first join only), `title`, `pointer`, `expires` (ms since epoch) | Join accepted |
| `started` | `title`, `app`, `w`, `h` (points), `pw`, `ph` (pixels), `input` | The stream is running |
| `config` | `codec`, `description` (base64 avcC) | Configure `VideoDecoder`; sent whenever the encoder's parameter sets change (start, resize, rebuild) |
| `size` | `w`, `h`, `pw`, `ph` | The window was resized |
| `pointer` | `pointer` | The host allowed or revoked pointer control |
| binary | `0x01`, frame flags (1 byte; bit 0 keyframe), PTS in µs (8 bytes BE), AVCC access unit | One video frame |

Browser → server, JSON text, 1 KB at most: `join`; `move`/`down`/`up` with `x`, `y` normalized to the picture,
`b` (DOM button 0 or 2), `c` (click count); `scroll` with `dx`, `dy` in pixels; `leave`; `kf` (ask for a keyframe,
sent when the decoder errors or the tab becomes visible again). Close codes: 4001 expired, 4002 rejected,
4003 kicked, 4004 window closed, 4005 host stopped, 4006 too many guests, 4007 protocol error, 4008 replaced by
the same session in another tab. The page explains each one and forgets the session for every code except 4006 and 4008; on a
plain network drop it reconnects with backoff.

**Guest input scope (`GuestPointer`).** A guest's pointer is always visible to the host user as an orange arrow with
the guest's name (`GuestPointerOverlay`: a click-through panel with `sharingType = .none`, so it never appears in
any capture; hidden after 3 s still). It reaches the window **only** while the host allows pointer control, and then
only as clicks, drags and scrolls (left and right button, 1–3 clicks, scroll clamped to ±2000 px). There are no keys,
no plain mouse moves (which would drag the host user's cursor around), and at most 240 pointer messages a second.
Revoking releases a held button first. Injected events go through the same `HostStream.handle` path as a paired
viewer's, so `InputGate` (Accessibility, secure input) and the window's raise-and-map logic apply.

**Lifetime and host control.** The host panel lists links (time left, pointer switch, revoke) and connected guests
(name, address, kick). A 5 s timer expires links; expiry, revoke, kick, unsharing the window and turning hosting off
all close the guests' sockets with their codes. A kicked guest's session is deleted, so it can't resume; the token
was already used, so the link can't be reopened. When no links or guests remain, the server stops and port 47822
closes.

**Server (`WebShareServer`, `WebConnection`).** `NWListener` on TCP 47822 with TLS 1.2+ (ALPN `http/1.1`),
24 connections at most, 8 guests, 16 links. Each connection sends one HTTP/1.1 request head (8 KB, 40 headers),
gets one response (`Connection: close`), or upgrades on `/ws` after an `Origin` check (must equal
`https://<Host>`). It must send its head and its `join` within 10 s. The WebSocket decoder (RFC 6455) requires
masked client frames, valid UTF-8 and control-frame rules, and rejects binary frames from the browser. Every response
carries `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:;
connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`, `nosniff`, `X-Frame-Options: DENY`,
`no-referrer`, `no-store`, COOP and CORP. Unknown paths are 404, other methods 405.

**Certificate (`WebCertificate`).** A fresh P-256 key per server start, self-signed, valid 30 days, `serverAuth`
EKU, not a CA, with SANs for `<bonjour>.local`, `localhost`, every local IPv4 and 127.0.0.1. It's separate from the
host's pinned device identity (§4.1), which never leaves the paired-viewer listener. Browsers warn about it once
per host; the SHA-256 in the sheet is what the guest compares it to ("Certificate viewer" → SHA-256 fingerprint).

**Threat model, briefly.**

| Threat | Mitigation |
| --- | --- |
| Someone on the network finds the port | Open only while a link or guest exists. Without a live 128-bit link ID every page is 404; the static files carry no secrets. |
| Guessing a token | 256 bits, one use, the link burns after 5 bad tokens. |
| A link leaks after use | The token is already spent; resuming needs the session secret, which stays in that tab's `sessionStorage`. |
| A link leaks before use | Whoever opens it first is the guest. The host sees each guest's name and address and can kick or revoke. Short lifetimes limit this. |
| Token in logs or `Referer` | It's in the fragment, stripped from the address bar at once, and every response sends `no-referrer`. |
| Network attacker (MITM) | TLS; the guest can compare the certificate fingerprint. Without that check, the first-use warning is the weak point (README risks). |
| Cross-site WebSocket or framing | `Origin` must match the host; `frame-ancestors 'none'`, `X-Frame-Options: DENY`. |
| Script injection | No inline script; CSP `script-src 'self'`; titles and names are set with `textContent`; names are sanitized (32 chars, no control characters). |
| Guest takes over the host | No keyboard ever; pointer only when allowed; bound to one window; excluded apps can't be shared; revoke releases buttons. |
| Resource exhaustion | Connection, guest and link caps; 8 KB heads; 1 KB messages; 10 s handshake timeout; pointer rate limit. |

**Threading.** `WebShareServer` and its connections run on one serial queue (`dev.paneshare.web`). Accepted
`join`s and guest messages hop to main with `onMain`, where `ShareLinkController` owns the store, guests, streams
and overlays. Video goes from the encoder callback through `WebConnection.sendDroppable` without touching main,
as for paired viewers.

## 8. Latency budget (targets, not yet measured)

60 fps capture, so a 16.7 ms frame interval. "Glass-to-glass" means a pixel changing on the host until it's
shown on the viewer.

| Stage | Target p50 | Target p95 | Notes |
| --- | --- | --- | --- |
| Capture (ScreenCaptureKit delivery after compositing) | 8 ms | 17 ms | Up to one frame interval |
| Encode (hardware HEVC, RealTime, no reordering) | 4 ms | 8 ms | 1440p-class window on Apple silicon |
| Send plus network, wired LAN | 1 ms | 3 ms | 5–15 ms on Wi-Fi. Over Tailscale: direct WireGuard RTT/2 plus about 1 ms. |
| Decode (hardware) | 3 ms | 6 ms | |
| Display (`DisplayImmediately`, next vsync) | 8 ms | 17 ms | |
| **Glass-to-glass** | **≤ 35 ms** | **≤ 55 ms** | Wired LAN. Wi-Fi target ≤ 60 ms p95. |
| Input (viewer event to host CGEvent posted) | ≤ 5 ms on LAN | ≤ 15 ms | Plus the app's reaction, plus the glass-to-glass time above |

Bitrate defaults to about 0.08 bits per pixel per frame, capped at 50 Mb/s on LAN. A still window drops to near zero
because idle frames are skipped; balanced and economy quality cut pixels to 56% and 25%. Measurement plan:
`ping`/`pong` RTT logged once a second, per-stage timestamps in debug logs, and a manual stopwatch test (TESTING.md).

## 9. Failure modes

| Failure | Detection | Behavior |
| --- | --- | --- |
| Screen Recording not granted | `CGPreflightScreenCaptureAccess()` is false, or `SCShareableContent` throws | Onboarding shows the step with an "Open System Settings" deep link. The host refuses to start sharing. |
| Accessibility not granted, or revoked mid-stream | `AXIsProcessTrusted()` re-checked every 0.5 s per stream | Video still works. Input and resize are dropped by `InputGate`; `streamStarted.inputEnabled = false` and then `inputState {noAccessibility}` make the viewer window's subtitle say "view only". |
| Secure input on at the host | `IsSecureEventInputEnabled()` every 0.5 s and on each key press | Key presses dropped; `inputState {secureInput}`; subtitle "typing paused while that Mac is entering a password". Clears automatically. |
| Local Network denied (macOS 15+) | `NWBrowser` or `NWListener` enter `.waiting` or `.failed` with a policy error | A status message. Manual address dialing over Tailscale still works. |
| Source window closed | `SCStreamDelegate` stream stopped with an error, or the window vanishes from `SCShareableContent` | `closeStream {reason: "windowClosed"}`, and the viewer window closes. |
| Source window minimized or in another Space | SCK delivers no new frames | The viewer keeps the last frame. The session survives. |
| Source app hidden | `NSRunningApplication.isHidden` | Its windows leave the list and can't be opened. An open stream keeps its last frame. |
| App refuses the AX size | The read-back differs from the request | `resized {final: true}` carries the actual size, and the viewer snaps to it. |
| Mouse-up lost during a live resize | No `final` request within 1 s | The host reconfigures for the last size anyway. |
| Encoder creation fails | `VTCompressionSessionCreate` error | `VideoEncoder.make` tries hardware HEVC, then hardware H.264, then software H.264. |
| Encoder fails while running | 30 consecutive frames fail (`VideoEncoder.onFailed`) | `HostStream` rebuilds once, preferring H.264, and forces a keyframe. A second failure ends the stream with `closeStream {reason: error}`. |
| Decoder failure | `sampleBufferRenderer.status == .failed` | Flush, send `requestKeyframe`, and rebuild the format description. |
| Network drop or Wi-Fi blip | `NWConnection` `.waiting` or `.failed`, or TCP keepalive (5 s idle, 2 s interval, 3 probes) | The viewer re-dials with backoff (0.5, 1, 2, 4… up to 10 s) and re-opens its streams by window ID. |
| Slow link or backpressure | The send queue holds more than 2 video frames | Drop non-key frames until the queue drains, and request a keyframe after a drop. |
| Pin mismatch (host reinstalled) | The TLS verify block returns false | The viewer shows "This host's identity changed. Pair again," and never falls back to an unpinned connection. |
| Wrong pairing code | `confirmV` mismatch | `pairResult {wrongCode}` with attempts left; the fifth failure closes the pairing window. |
| Dock helper can't be generated or verified | `AdHocSigner`/`SecStaticCodeCheckValidity` error, or a missing helper binary | That app uses the single-process presenter; the error is logged. |
| Dock helper crashes | Its link connection closes without `userQuit` while it still has windows | Relaunch up to twice, then fall back to the single-process presenter for that app. |
| Main app crashes | Helper watchdog (`kill(pid, 0)` every 2 s) | Helpers exit; no orphan icons. |
| Frame over the size limit or bad magic | `FrameDecoder` throws | Send `error`, then close. |
| Port 47822 taken | `NWListener` fails to start | The link sheet shows the error; no link is created. |
| Browser without WebCodecs | `VideoDecoder` or `EncodedVideoChunk` missing, or the page isn't a secure context | The page says the browser can't show the window and names supported browsers. A decoder error asks for a keyframe and reconfigures. |
| Guest's network drops | Socket closes | The guest's stream stops; the page reconnects with backoff using its session secret until the link expires. |

## 10. Test plan

**Automated (Linux and macOS, `swift test`), in `Tests/PaneshareCoreTests`:**

- Framing: header round trip; streaming decode with arbitrary chunk splits; bad magic, unknown version, non-zero
  reserved bits and oversize length are rejected; unknown kinds surface as `.unknown`; raw values are unique.
- Messages: JSON round trip of every message, including optional revision 3 fields and their absence (older
  peers); an unknown `quality` value is rejected; the binary `parameterSets` and `videoFrame` codecs.
- Coordinate mapping and sizing: viewer flip and normalization; host denormalization on multi-display layouts
  (negative origins); clamping; round trip within 0.5 pt; pixel size (even dimensions, clamps, quality factors);
  the frozen-size rule; resize coalescer timing.
- Pairing: code generation and formatting; field arithmetic and Elligator 2 against RFC 9380 Appendix J.4.2
  vectors; fixed PAKE vectors (generator, both shares, both confirmations) cross-checked with an independent
  Python model; a wrong code, a relay in the middle (even with the right code), malformed inputs and low-order
  shares (0, 1, the order-8 point) all fail; the gate (attempt spent at challenge, one in flight, 5 attempts,
  5-minute expiry, single use).
- Identity: a self-signed certificate parses back; the SPKI fingerprint matches the key; HostID encoding.
- Policies: password managers, system auth prompts, hidden apps, own process and helpers, layer and size filters;
  the input gate including the secure-input pause.
- Dock helpers: bundle plan and sanitization; the ad hoc signer on a synthetic Mach-O (layout, hashes, cdhash,
  load-command rewrite, stable re-signing, refusal of what it can't sign); `CodeResources` and `.icns` output;
  ledger staleness and Dock-pin parsing; link framing (split and merged chunks, oversize, garbage) and the socket
  path length. On macOS, `CodesignVerifyTests` signs the real helper
  binary and checks it with `codesign --verify --strict` (skipped when the helper isn't built).

- Share links: HTTP head parsing and limits; the WebSocket accept value (RFC 6455 §1.3), frame encoding, masking,
  fragmentation, control frames and UTF-8; the avcC record and codec string; `GuestWire` translation; link
  creation, one-time redemption, burn after 5 bad tokens, resume, expiry, kick and revoke; `GuestPointer` scopes,
  rate limit and revoke; address ranking; routes, security headers and the `Origin` check; the web certificate's
  extensions; the viewer assets (no inline script, `[hidden]` rule).
- Browser viewer end to end: `scripts/web-viewer-e2e/run.sh` replays real fixtures to headless Chrome over TLS and
  checks decode, token stripping, input scope, reconnect, kick and 404 (TESTING §1.1). Development only.

**Manual on two Macs:** `docs/TESTING.md`.

**CI:** `.github/workflows/ci.yml` runs the core tests in a `swift:6.0` Linux container, and on `macos-14` and
`macos-15` builds every target (the only type-check of the macOS code), runs the tests, and assembles the
ad hoc-signed bundle. GitHub Actions has not run on this repository yet.

**Not yet automated:** the ScreenCaptureKit, VideoToolbox, Network.framework TLS, AX, LaunchServices and
helper-socket paths at runtime.

## 11. Threading model

| Context | What runs there |
| --- | --- |
| Main actor | All controllers and views: `HostController`, `HostPeer`, `HostStream` (control side, including the input-state timer), `ViewerController`, `ViewerSession`, `RemoteWindowController`, the Dock presenters, `DockHelperFactory`, `DockLinkServer` callbacks, `VirtualDisplayManager` and `VirtualDisplay`. Input injection and AX calls (AX has a 0.5 s messaging timeout per element). |
| One serial network queue per role | `NWListener`, `NWConnection`, the TLS verify blocks, frame decoding, `onMessage`/`onClose`. `PairingRequest` runs on the channel's queue (the PAKE costs a few X25519 operations, so nothing needs to leave it). |
| ScreenCaptureKit sample queue → encode queue → VideoToolbox callback | Host frames: `WindowCapturer.onFrame` → `VideoEncoder.encode` → `onEncoded` → `channel.send`/`sendDroppable`. **Never hops to main.** Shared state is `Locked<…>`/`SendState`. |
| Network queue → display layer | Viewer video: `parameterSets` and `videoFrame` go from `onMessage` straight to the `StreamRenderer` found in a `Locked` map. `audioFrame` goes straight to its `RemoteAudioStream`. Every other kind hops to main. |
| Audio | Host: the tap's IO-proc queue (or ScreenCaptureKit's sample queue) → `AACELDEncoder` → `channel.send`, never main. Viewer: one serial decode queue per remote app → `AudioJitterBuffer` (unfair lock) ← the `AVAudioEngine` render thread. |
| Dock link sockets | A `DispatchSourceRead` per connection on the main queue; messages are tiny. |
| Share-link server | `WebShareServer` and every `WebConnection` on `dev.paneshare.web`; joins and guest messages hop to main (`ShareLinkController`); guest video is sent from the encoder callback. |

Rules the code follows:

- Cross-thread hops use `onMain { }` (`DispatchQueue.main.async` + `MainActor.assumeIsolated`), not
  `Task { @MainActor in }`, because control messages must stay in FIFO order.
- Callbacks set from main and called elsewhere are `@Sendable` and capture `[weak self]`. Callbacks that refer to a
  channel check, on main, that it's still the current one (`self.channel === channel`).
- Channels accepted by the listener don't read until their owner has installed handlers and called
  `startReceiving()`, so the first frame (`hello` or `pairBegin`) can't arrive before anyone listens.
- The package builds in Swift 5 language mode. Swift 6 strict-concurrency mode is a roadmap item.

## 12. Dependency pins

`Package.swift` caps swift-crypto `<4.0.0`, swift-certificates `<1.16.0` and swift-asn1 `<1.5.0`. These are
the last releases whose manifests need at most Swift 5.10, so Xcode 15.3 still resolves the package.
`Package.resolved` is committed (3.15.1, 1.15.1 and 1.4.0). Raise the caps together with the minimum Xcode.
Sparkle is `2.10.1..<3.0.0` (pinned 2.10.1): a prebuilt XCFramework that only the macOS app target links
(`condition: .when(platforms: [.macOS])`); on Linux SwiftPM still downloads the artifact but never uses it.

## 13. Deferred features and upgrade paths

### 13.1 Deferred

| Feature | Why deferred | Where it would go |
| --- | --- | --- |
| Take-over mode (whole virtual desktop) | Only per-window streaming is supported; the virtual display (§7.3) is its building block | Capture the virtual display itself with `SCContentFilter(display:)` |
| Resizing a virtual display mid-session | The display is sized when the first window opens | Recreate it or apply a new mode when the viewer's `viewerDisplay` changes |
| Audio for browser guests | WebCodecs `AudioDecoder` doesn't decode AAC-ELD everywhere; guests would need Opus | An Opus encoder next to `AACELDEncoder`, sent as a second binary tag on the guest socket |
| Microphone / echo cancellation | Out of scope: paneshare sends app output only | `AVAudioEngine` voice processing on the viewer |
| Keyboard for browser guests | A guest typing into a host app is a much larger grant than pointing; needs its own consent and secure-input handling | A third scope in `GuestPointer`, off unless the host turns it on per link |
| HEVC and 4:4:4 for browser guests | Browser support for HEVC in `VideoDecoder` is uneven; 4:4:4 H.264 even more so | Probe `VideoDecoder.isConfigSupported` in the page and report it in `join` |
| Internet-reachable share links | Needs a relay or TURN, which is paid or hosted infrastructure | Design only: `docs/SHARE-LINKS-INTERNET.md` |
| Trusted certificate for share links | A self-signed certificate warns once per host | Tailscale's `tailscale cert` (Let's Encrypt for `*.ts.net`) loaded from a file the user points at |

### 13.2 Transport upgrade: LiveKit

The MVP is the spec's lean path (direct TLS + Bonjour). The planned upgrade is the spec's other path:
**LiveKit** — `livekit/livekit` (server, Apache-2.0) embedded on the host, and `livekit/client-sdk-swift`
(Apache-2.0) with its WebRTC build (BSD-3-Clause) on both sides. Nothing from them is in this PR.

How it fits behind the seams:

1. `LiveKitMessageChannel: MessageChannel`. Control frames go on a reliable data channel; the same 12-byte framing is
   kept so `PaneshareCore` doesn't change. `sendDroppable` maps to the lossy data channel or, better, video is
   moved to a WebRTC video track per stream, fed with our VideoToolbox output (or WebRTC's own VideoToolbox
   encoder) so congestion control and loss recovery come from WebRTC.
2. Identity: the host's embedded server is fronted by our pinned TLS (same SPKI pin), and access tokens are signed
   per paired viewer; DTLS fingerprints are signed with the device key so the pin still covers media.
3. Pairing is unchanged: it needs only "each side learns the other's fingerprint from an authenticated channel",
   which the pinned TLS front door provides.
4. Gains: UDP media with congestion control, several viewers per window, audio tracks, and the browser viewer.
   Costs: about 50 MB for the server binary, a child process to supervise (the host would have to launch it, which
   the current "no child processes" rule would need to allow explicitly), and a larger attack surface.

Until then, video shares the TCP connection with control, so a lossy link causes head-of-line stalls; the
droppable path and keyframe-on-drop keep latency bounded.

## 14. Distribution and updates

Full procedure and the reasoning: docs/RELEASING.md.

- **Signing.** `scripts/make-app.sh` signs ad hoc by default. With `PANESHARE_SIGN_IDENTITY` set it signs inside
  out (Sparkle's XPC services, `Autoupdate`, `Updater.app`, the framework, the Dock helper template, then the
  app with `paneshare.entitlements`), each with `--options runtime --timestamp`. Entitlements: not sandboxed, plus
  `device.audio-input` as a precaution for the process tap under the hardened runtime. Library validation
  stays on.
- **Release.** `scripts/release.sh` (release Mac only) builds with the feed URL, public key, version and build
  number as build settings. It defaults to "Developer ID Application: NEXOBE INC (TV289JZ58M)" and requires that
  team on every signature. It notarizes and staples the app, then a DMG, with `asc notarization submit` by default
  (`PANESHARE_NOTARY_TOOL=notarytool` for `xcrun notarytool`), and checks both with `spctl` and `stapler validate`.
  It then runs the Dock helper self-test on a quarantined install from the DMG, and updates the appcast with
  Sparkle's `generate_appcast`. It reads no secrets: the identity, the notary credentials and the EdDSA private
  key stay in the Keychain. It uploads nothing.
- **Updates.** Sparkle 2 through `UpdaterController`. It starts only when `UpdateConfiguration` (Core) accepts the
  `Info.plist`: an HTTPS `SUFeedURL`, a 32-byte `SUPublicEDKey`, `SURequireSignedFeed` and
  `SUVerifyUpdateBeforeExtraction`, and an interval of at least an hour (86400 is set). The app asks once on
  first launch before any automatic check (`UpdateConsent`). Installs always ask
  (`SUAllowsAutomaticUpdates` off), and no system profile is sent. The app menu has **Check for Updates…** and
  **Check for Updates Automatically**.
- **Feed host.** Any public static HTTPS host; the private repository's releases can't serve anonymous users.
  RELEASING §3 compares a public releases repo with Pages, Release assets, and Cloudflare Pages.
