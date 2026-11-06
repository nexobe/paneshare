# Third-party code, dependencies and design references

paneshare is released under the MIT License (see `LICENSE`). Everything below is compatible with it.
**No GPL, AGPL, LGPL, MPL, PolyForm or unlicensed code is copied.** Projects under those licenses were
read only for design ideas, and none of their code or text is in this repository.

Three kinds of use:

- **Dependency:** linked through SwiftPM and used unmodified.
- **Adapted code:** this repository contains a rewritten derivative of specific source files. Each derived
  file says so in a header comment that names the upstream file, keeps the copyright line and notes that it
  was changed (Apache-2.0 §4(b) and (c)).
- **Design reference:** read to learn an approach. No code was copied.

## Dependencies (SwiftPM)

| Package | Version used | License | Copyright | Used for |
| --- | --- | --- | --- | --- |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 (range 3.0.0..<4.0.0) | Apache-2.0 | Copyright 2019 The SwiftCrypto Project | P-256 keys, SHA-256, HMAC, `SymmetricKey`. On macOS the `Crypto` module re-exports Apple CryptoKit. On Linux it builds a vendored BoringSSL (OpenSSL/ISC-style licenses, see the package's own notices), which is used only for the Linux unit tests. |
| [apple/swift-certificates](https://github.com/apple/swift-certificates) | 1.15.1 (range 1.0.0..<1.16.0) | Apache-2.0 | Copyright 2022 The SwiftCertificates Project | Building and parsing the self-signed X.509 device certificate (`SelfSignedCertificate`). |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | 1.4.0 (range 1.0.0..<1.5.0) | Apache-2.0 | Copyright 2022 The SwiftASN1 Project | DER serialization of that certificate. |
| [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 (range 2.10.1..<3.0.0), the project's prebuilt XCFramework | MIT; bundles bsdiff/bspatch (BSD-2-Clause, Colin Percival), sais-lite (MIT, Yuta Mori), ed25519 (zlib, Orson Peters) and `SUSignatureVerifier` (BSD-2-Clause, Mark Hamlin) | Copyright (c) 2006-2013 Andy Matuschak and the other holders listed in its LICENSE | Auto-update (`UpdaterController`, docs/RELEASING.md). Embedded unmodified as `Contents/Frameworks/Sparkle.framework`; `make-app.sh` copies its LICENSE to `Contents/Resources/Licenses/Sparkle.txt`, as MIT, BSD and zlib require. `scripts/release.sh` also runs its `generate_keys` and `generate_appcast` tools on the release Mac. |

The upper bounds are the last releases whose manifests need at most Swift 5.10, so the package resolves
on Xcode 15.3 and later.

## Adapted code

### Sill: Apache-2.0

- Upstream: [github.com/Saffsanity/sill](https://github.com/Saffsanity/sill), read at commit `41e8cb8`
  (2026-11-03). License: Apache License 2.0, "Copyright 2026 Noah Saffer". Sill ships no `NOTICE` file, so
  there is no NOTICE text to carry over.
- What was adapted, and where:

| paneshare file | Sill source | What was taken | What changed |
| --- | --- | --- | --- |
| `Sources/PaneshareTransport/PinnedTLS.swift` | `Sources/StreamProtocol/RemoteTLS.swift` | TLS 1.3-only options, tickets and resumption off, peer authentication required on the server, two ALPNs, a verify block that pins the SPKI and never evaluates the trust object, TCP keepalive settings | paneshare's ALPNs, port and service type. Fingerprints go through swift-crypto. No home-door or peer-to-peer variant. |
| `Sources/PaneshareEncode/VideoEncoder.swift` | `Sources/SillHost/HEVCEncoder.swift` | Session properties (real-time, no reordering, a 4 s safety keyframe interval, data-rate limit, speed over quality), drop rather than queue, re-encoding the last frame for an on-demand keyframe | Much simpler: no watchdog or slow-state machinery. H.264 and software fallbacks added. Parameter-set extraction added. |
| `Sources/PaneshareInput/AXWindow.swift` | `Sources/SillHost/WindowSizer.swift` | Finding the AX window by PID plus frame with a tolerance, per-element messaging timeouts | Rewritten. Title tiebreak, raise and resize added. |
| `Sources/PaneshareVirtualDisplay/VirtualDisplay.swift` | `Sources/SillHost/VirtualDisplay.swift` (itself derived from KhaosT/CGVirtualDisplay, Apache-2.0, and DeskPad, MIT) | Looking up the private `CGVirtualDisplay*` classes at run time and checking each selector's Objective-C type encoding before calling it, the descriptor/settings/mode sequence, waiting for the display to come online, selecting the requested mode | Rewritten around one display per viewer: a serial from the viewer fingerprint, top-left `bounds`/`visibleFrame`, a static `apiProblem` probe, and `physicalScreenSizes`. No DisplayWake/power assertions. The file keeps an Apache-2.0 header naming Sill, KhaosT and DeskPad. |
| `Sources/PaneshareCore/Geometry/VirtualDisplayPlanner.swift` (`ObjCTypeEncoding`) | `Sources/SillHost/VirtualDisplay.swift` | Normalizing type encodings (dropping offsets and qualifiers) before comparing | Moved into Core as a pure function so it is unit-tested on Linux. |
| `Sources/PaneshareInput/EventInjector.swift` | `Sources/SillHost/InputInjector.swift` | HID-state `CGEventSource`, click state, continuous pixel scrolling with phases (`scrollWheelEvent2Source` and the point-delta fields) | Rewritten for normalized window coordinates and paneshare's `InputEvent`. No gestures or trackpad mode. |

- Design only, no code: the reasoning behind `KeychainStore` (prefer the data-protection keychain,
  because the login keychain can't authenticate an item's creator; never silently replace a key that can't
  be read), the split between a pairing ALPN and a session ALPN, and binding pairing to both TLS fingerprints.
- **No longer used:** revision 2 adapted Sill's 12-digit Damm code and its PBKDF2/HMAC pairing proof
  (`PairingCode.swift`, `PairingProof.swift`, `PBKDF2.swift`). Revision 3 replaced them with a 6-digit code and
  our own PAKE (below), deleted `PairingProof.swift` and `PBKDF2.swift`, and rewrote `PairingCode.swift`; nothing
  from Sill's pairing code remains.

## Written from public specifications (no code copied)

| paneshare file | Specification | License of the specification | Notes |
| --- | --- | --- | --- |
| `Sources/PaneshareCore/Pairing/Curve25519Field.swift` | [RFC 9380](https://www.rfc-editor.org/rfc/rfc9380) §6.7.1 (Elligator 2) and Appendix J.4.2 test vectors; [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748) (curve25519 parameters, low-order points) | IETF Trust, BCP 78 / Revised BSD for code components | Field arithmetic written from scratch. The test vectors are facts from the RFC. |
| `Sources/PaneshareCore/Pairing/PairingExchange.swift` | The CPace design ([draft-irtf-cfrg-cpace](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/)) | IETF Trust | Our own simplified construction and labels, not an implementation of the draft's exact encoding; see ARCHITECTURE §4.2. X25519, HKDF and HMAC come from CryptoKit / swift-crypto. |
| `Sources/PaneshareCore/Dock/AdHocSigner.swift`, `BundleSeal.swift` | Apple's open-source xnu headers `osfmk/kern/cs_blobs.h` and `EXTERNAL_HEADERS/mach-o/loader.h` ([apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu)) | APSL-2.0 headers, used only as a format reference | Magic numbers, struct layouts and slot numbers are interface facts. No header text or code is copied. |
| `Sources/PaneshareCore/Dock/BundleSeal.swift` (`ICNSWriter`) | The `.icns` container layout (public format documentation) | — | Header plus PNG entries only. |
| `Sources/PaneshareCore/Web/WebSocketCodec.swift` | [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455) (The WebSocket Protocol), including the §1.3 handshake example used as a test vector | IETF Trust, BCP 78 | Framing, masking, control frames and the accept value written from the RFC. |
| `Sources/PaneshareCore/Web/HTTPRequest.swift` | [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112) (HTTP/1.1 message syntax) | IETF Trust | A deliberately small subset: one GET head per connection, no bodies, `Connection: close`. |
| `Sources/PaneshareCore/Web/GuestProtocol.swift` (`H264DecoderConfig`) | ISO/IEC 14496-15 §5.3.3 (`AVCDecoderConfigurationRecord`), [RFC 6381](https://www.rfc-editor.org/rfc/rfc6381) §3.3 (`avc1.PPCCLL` codec strings), and the [W3C WebCodecs AVC registration](https://www.w3.org/TR/webcodecs-avc-codec-registration/) | ISO (format facts only); IETF Trust; W3C Document License | Byte layout and string format are interface facts; nothing copied. |
| `Sources/PaneshareCore/Web/WebViewerAssets.swift` (the page's script) | [W3C WebCodecs](https://www.w3.org/TR/webcodecs/) (`VideoDecoder`, `EncodedVideoChunk`), WHATWG HTML and DOM (`WebSocket`, `sessionStorage`, `history.replaceState`), W3C CSP Level 3 | W3C Document License; WHATWG CC-BY 4.0 | Our own script, written against the specifications' interfaces. No sample code copied. |
| `Sources/PaneshareCore/Web/WebCertificate.swift` | [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280) and the CA/Browser Forum baseline profile (SAN, `serverAuth` EKU, not-CA, validity) | IETF Trust; CA/B Forum (public) | Built with swift-certificates (dependency above). |

## Development-only verification tools (not shipped, not linked, no code copied)

| Tool | License | How it was used |
| --- | --- | --- |
| [indygreg/apple-platform-rs](https://github.com/indygreg/apple-platform-rs) `rcodesign` (apple-codesign 0.29.0, installed from PyPI/crates on the build VM) | MPL-2.0 | Run once on Linux to ad hoc sign the same test binary as `AdHocSigner`, and the two outputs were compared byte by byte. MPL-2.0 code was **executed, not copied**; nothing from it is in this repository. |
| [Zig](https://ziglang.org) (`ziglang` from PyPI) | MIT | Its bundled linker produced an arm64 macOS test binary on Linux for that comparison. |
| Python 3 | PSF-2.0 | Independent reference model of the PAKE used to produce the fixed test vectors (kept outside the repository). |
| [FFmpeg](https://ffmpeg.org) with libx264 (distribution packages on the build VM) | LGPL-2.1+ / GPL-2.0+ (libx264) | `scripts/web-viewer-e2e/run.sh` runs it to make a throwaway H.264 test clip. **Executed, not copied, not linked**; the clip isn't committed. |
| Google Chrome (headless) | Chrome terms of service (Chromium is BSD-3-Clause) | The same harness runs the web viewer page in it through the DevTools protocol. Executed only. |
| [python-websockets](https://github.com/python-websockets/websockets) | BSD-3-Clause | The harness's DevTools-protocol client (`drive.py`). Imported by a development script, not shipped. |
| [librsvg](https://gitlab.gnome.org/GNOME/librsvg) `rsvg-convert` (distribution package) | LGPL-2.1+ | `scripts/icon/build-icon.sh` and `helper-preview.py` run it to render our own SVG icon sources to PNG. **Executed only**; the rendered `Resources/AppIcon.icns` is our artwork, not librsvg code. `iconutil` (Apple) is used instead when present. |
| `/usr/bin/codesign` | Apple system tool | `scripts/make-app.sh` (developer script) and the macOS-only `CodesignVerifyTests`. The app itself never runs it. |

## Planned dependencies (not in this PR)

| Package | License | Planned use |
| --- | --- | --- |
| [livekit/livekit](https://github.com/livekit/livekit) (server) | Apache-2.0 | Embedded on the host as the transport upgrade path (ARCHITECTURE §13.2): UDP media, several viewers, audio; could later carry share links over WebRTC |
| [livekit/client-sdk-swift](https://github.com/livekit/client-sdk-swift) | Apache-2.0 | Client on host and viewer behind `MessageChannel` |
| [webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc) (LiveKit's WebRTC build) | BSD-3-Clause, with its bundled third-party notices | Media transport under the LiveKit SDK |

All three are compatible with Apache-2.0 and MIT. Their NOTICE files must be carried in the app bundle when
they're added.

### Rectangle: MIT

- Upstream: [github.com/rxhanson/Rectangle](https://github.com/rxhanson/Rectangle),
  `Rectangle/AccessibilityElement.swift`. GitHub reports its license as NOASSERTION, so the file was read
  by hand: MIT.
- What was used: the pattern of temporarily turning off an app's `AXEnhancedUserInterface` around an AX
  resize, because some apps animate or ignore AX resizes while it's on. That's one technique, re-implemented
  in five lines of `AXWindow.resize(to:)`. No code was copied, and the notice is reproduced to be safe:

```
MIT License

Copyright (c) 2019-2026 Ryan Hanson
Based on the Spectacle app, Copyright (c) 2017 Eric Czarny eczarny@gmail.com

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Design references (no code copied)

| Project | License | What was learned |
| --- | --- | --- |
| Apple sample code: "Capturing screen content in macOS" (ScreenCaptureKit) | Apple sample code license (MIT-style) | The `SCShareableContent` → `SCContentFilter(desktopIndependentWindow:)` → `SCStream` flow, and reading `SCFrameStatus` from the frame-info attachments |
| Apple sample code: "Building a custom peer-to-peer protocol" (Network.framework) | Apple sample code license (MIT-style) | `NWListener`/`NWBrowser` with Bonjour. Its TLS-PSK-from-passcode scheme was deliberately **not** used (see ARCHITECTURE §4). |
| [nonstrict-hq/ScreenCaptureKit-Recording-example](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example) | MIT | Scale-factor handling for single-window capture |
| [chromium/chromium](https://github.com/chromium/chromium) `chrome/app_shim/` | BSD-3-Clause | The per-app shim bundle model, which is Dock option C in ARCHITECTURE §6 (`HelperBundlePlan`, `DockHelperFactory`, `paneshare-dock-helper`) |
| Sill PR #66 (`SillDockProxy`, an unmerged fork PR) | Apache-2.0 (contribution to an Apache-2.0 repo) | Same option C applied to remote windows. Read for design only, because an unmerged fork PR's licensing intent is less certain than merged code. |
| [ianyh/Amethyst](https://github.com/ianyh/Amethyst), [tmandry/Swindler](https://github.com/tmandry/Swindler) | MIT | AX window lookup by PID; window-event modeling |
| [insidegui/AudioCap](https://github.com/insidegui/AudioCap) (read at commit `6f609e8`) | BSD-2-Clause, "Copyright (c) 2024 Guilherme Rambo" | The order of Core Audio calls for a process tap: `CATapDescription` → `AudioHardwareCreateProcessTap` → a private aggregate device whose tap list names the tap's UUID → `kAudioTapPropertyFormat` → an IO proc block → teardown in reverse. `ProcessTapCapture.swift` was written from Apple's `AudioHardware.h`/`CATapDescription.h` headers with that sequence in mind; no code was copied. |
| [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay) | Apache-2.0 | The original public demonstration of the private `CGVirtualDisplay` classes and their headers. Credited in `VirtualDisplay.swift` because Sill's version descends from it. |
| [m1k1o/neko](https://github.com/m1k1o/neko), [pion/webrtc](https://github.com/pion/webrtc) | Apache-2.0, MIT | Considered for share links: a browser viewer over WebRTC. Not used; WebCodecs over a WebSocket needs no native WebRTC stack (ARCHITECTURE §7.4). No code read for implementation. |
| [Stengo/DeskPad](https://github.com/Stengo/DeskPad) (read at commit `c3349f0`) | MIT, "Copyright (c) 2022 Bastian Andelefski" | A virtual display as a shipping app: HiDPI modes (`hiDPI = 1`, the point size as the mode size), sizing the display to what the user wants, and tearing it down when the app quits. No code was copied from DeskPad itself. |

## Apple frameworks

The app links system frameworks only through public API: ScreenCaptureKit, VideoToolbox, CoreMedia,
AVFoundation (`AVAudioConverter` for AAC-ELD, `AVAudioEngine`), CoreAudio and AudioToolbox (process taps,
aggregate devices; macOS 14.2+), Network, Security (including `SecCode`/`SecStaticCode` validity checks), ApplicationServices
(Accessibility), Carbon HIToolbox (`IsSecureEventInputEnabled` only), CoreGraphics, AppKit and SwiftUI, plus
Darwin sockets (`LOCAL_PEERPID`, `LOCAL_PEERTOKEN`).

**One private API is used, and only when the host turns it on:** the `CGVirtualDisplay`,
`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings` and `CGVirtualDisplayMode` classes in
CoreGraphics, for the virtual display (ARCHITECTURE §7.3). They are looked up by name at run time and
every selector's type encoding is checked first, so if Apple changes or removes them the feature reports
itself unavailable instead of crashing. Using them rules out the Mac App Store (App Review guideline 2.5.1).
No other private frameworks or symbols are used (for example, `_AXUIElementGetWindow` and SkyLight are not).

## Target-derived input

`docs/SPEC.md` is the sanitized functional spec from a separate clean-room analysis of public sources. It describes
behaviour, Apple APIs and architecture only, and is the only input derived from the reference product. No code, text,
names or assets from that product are in this repository.
