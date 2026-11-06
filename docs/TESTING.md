# Testing paneshare

There are two levels:

1. **Automated:** `swift test` runs the platform-neutral core (framing, messages, coordinate mapping,
   sizing, pairing and the PAKE, identity, trust, policies, the Dock helper signer and link framing, the audio
   jitter buffer, timeline, policy and mix settings, the virtual display planner, and the share-link web stack).
   It runs on Linux and macOS. A separate development harness checks the browser viewer in headless Chrome (§1.1).
2. **Manual, on two Macs:** everything that needs ScreenCaptureKit, VideoToolbox, Network.framework,
   Accessibility and TCC permissions. This document is mostly about this level.

Throughout, **host** is the Mac whose window is shared, and **viewer** is the Mac that shows it.

## 1. Automated tests

```bash
swift build            # whole package (on Linux, the macOS targets compile to nothing)
swift test             # 175 core tests on Linux (1 skipped: the §1.1 fixture writer); on macOS also CodesignVerifyTests (below)
```

On macOS, `CodesignVerifyTests` signs the real `paneshare-dock-helper` binary with paneshare's in-process ad hoc
signer and checks the bundle with `codesign --verify --strict`. It's skipped unless the helper is built first:

```bash
swift build --product paneshare-dock-helper && swift test --filter CodesignVerifyTests
```

CI (`.github/workflows/ci.yml`) runs `swift test` in a `swift:6.0` Linux container, and builds every
target, runs the tests and assembles the app bundle on `macos-14` and `macos-15` runners.

### 1.1 Browser viewer harness (development only)

`scripts/web-viewer-e2e/run.sh` checks the web viewer page in a real browser without a Mac. It needs `swift`,
`ffmpeg` with libx264, Google Chrome (or Chromium; set `CHROME=/path/to/chrome`), and Python 3 with `websockets`
(`pip install websockets`).

```bash
scripts/web-viewer-e2e/run.sh      # fixtures go to $PANESHARE_E2E_DIR (default /tmp/paneshare-web-e2e)
```

1. ffmpeg encodes a 640×400 test pattern to H.264 Annex B.
2. `WebViewerFixtureTests` (skipped unless `PANESHARE_E2E_DIR` is set) turns it into exactly what the host sends:
   the HTTP responses from `WebRouter`, `GuestWire` notices and video messages, and a `WebCertificate` key pair.
3. `server.py` replays those over TLS on 127.0.0.1:47822 and logs what the browser sends.
4. `drive.py` runs headless Chrome through the DevTools protocol and checks 21 things, including: the token leaves
   the address bar; the join carries it; the picture decodes and matches the pattern; view-only sends moves but no
   clicks; after "pointer on", clicks and scrolls (in macOS's sign) arrive; a dropped socket resumes with the
   session secret; a kick explains itself and forgets the session; a used link can't be reopened; an unknown link
   is a 404 page; no CSP violation or page exception. It prints `ALL PASSED` or exits non-zero.

It doesn't exercise the Swift server or ScreenCaptureKit; §4.9 covers those on real Macs.

## 2. Build the app

Requirements: macOS 14 or later on both Macs, and Xcode 15.3 or later (Swift 5.10+) on the Mac that
builds. Apple silicon is recommended for the hardware HEVC encoder, but Intel Macs with an HEVC-capable GPU work too.

```bash
scripts/make-app.sh          # release build → build/app.noindex/paneshare.app, ad hoc signed
scripts/make-app.sh debug    # debug build
open build/app.noindex/paneshare.app
```

Copy `build/app.noindex/paneshare.app` to the other Mac (AirDrop, or `scp -r`), or build it there too. You can also open
`Package.swift` in Xcode and run the `paneshare` scheme. However, macOS then attributes permissions to the
binary inside DerivedData, so **use the app bundle for anything involving permissions**.

Notes on the ad hoc signature:

- macOS ties Screen Recording and Accessibility grants to the code signature. **An ad hoc signature changes
  on every rebuild**, so after rebuilding, the old grant can silently stop applying. If a permission shows
  "granted" in System Settings but paneshare says it isn't, remove paneshare from the list (the minus button)
  and grant it again, or run `tccutil reset ScreenCapture dev.paneshare.app` and
  `tccutil reset Accessibility dev.paneshare.app`.
- An app copied over AirDrop gets the quarantine attribute. On first launch, right-click the app, choose
  **Open**, and confirm.
- Ad hoc builds can't use the data-protection keychain, so the identity key goes to the login keychain.
  **This Mac** shows which one is in use. See the README's known risks.

## 3. One-time setup on each Mac

| Step | Host | Viewer |
| --- | --- | --- |
| Launch `paneshare.app` | ✓ | ✓ |
| Onboarding: **Screen Recording**. Choose "Open System Settings", enable paneshare under Privacy & Security → Screen & System Audio Recording, then quit and reopen paneshare if macOS asks. If paneshare isn't in the list, click + and choose it from Applications (needed in testing on macOS 27.2). | required | not needed |
| Onboarding: **Accessibility**. Enable paneshare under Privacy & Security → Accessibility. | required for input and resize | not needed |
| **Local Network** (macOS 15+): allow the prompt, or enable it under Privacy & Security → Local Network | required for Bonjour | required for Bonjour |
| macOS firewall (if on): allow incoming connections for paneshare when prompted | required | not needed |

The viewer needs no privacy permissions. Without Local Network permission, Bonjour discovery doesn't work,
but pairing by address still does.

## 4. Two Macs on the same LAN

Put both Macs on the same network segment (Wi-Fi or Ethernet, no client isolation). Record your results
in the table in §7.

### 4.1 Hosting and pairing

The host limits pairing prompts to 3 per viewer address per 10 minutes, with a 2-minute cooldown after a decline or
failure (L10, L15). Running L5–L17 from one viewer hits that: turn sharing off and on again on the host to clear
the limits between rows.

| # | Steps | Expected |
| --- | --- | --- |
| L1 | Host: **Share** tab. Leave "Share windows from this Mac" **off**. Viewer: run `nc -vz <host>.local 47821` in Terminal. | The connection is refused. **No port is open while sharing is off.** On the host, `lsof -nP -iTCP:47821 -sTCP:LISTEN` prints nothing. |
| L2 | Host: turn sharing **on**. | The status shows that it's listening. `lsof` shows paneshare listening on 47821. |
| L3 | Viewer: from another Mac or the viewer, run `openssl s_client -connect <host>.local:47821 -alpn paneshare/1 </dev/null`. | The handshake fails: there's no client certificate, or the certificate isn't pinned. No paneshare bytes are exchanged. `-alpn paneshare-pair/1` (the old pairing version) also fails. |
| L4 | Viewer: **Connect** tab. | The host appears under **On this network** within about 2 s, with its name and ID. |
| L5 | Host: do nothing (no button to press). Viewer: click **Pair** next to the host. | The viewer's sheet shows a 6-digit code in two groups (`482 913`), "This Mac's ID: …", and "Asking “<host>”…", then "On “<host>”, type this code and click Accept." **Within about a second a prompt appears on the host on its own**: "“<viewer name>” wants to pair with this Mac", its ID (the same as the viewer's sheet shows), its address, a code field, a 5:00 countdown, Decline and Accept. |
| L6 | Repeat L5 with paneshare on the host in the background (another app frontmost, or on another Space or in a full-screen app). | The prompt still appears on top, on the current Space, and the code field takes typing without switching apps. paneshare's Dock icon bounces, and a "Pairing request" notification is posted (first time: allow notifications). Answering the prompt withdraws the notification and stops the bounce. |
| L7 | Host: take a screenshot (Cmd-Shift-3), or share the host's screen in another app, while the prompt is up. | **The prompt is missing from the capture.** Its `sharingType` is `.none`. |
| L8 | Host: type a wrong 6-digit code and click Accept. | Host prompt: "That code didn't match. 4 tries left." and the field clears. Viewer: "The code typed on “<host>” didn't match. 4 tries left." Nothing is pinned on either side. Letters or 5 digits keep Accept disabled; spaces and dashes are ignored, so `482-913` works. |
| L9 | Host: type the right code and click Accept (or press Return). | Both sides show "Paired with …". The host lists the viewer under Viewers; the viewer's sheet closes and the host moves to **Paired Macs** and connects. |
| L10 | Start a new request (unpair first) and click **Decline** on the host. | Viewer: "The request was declined on that Mac." Clicking **Try again** at once is **ignored** for 2 minutes (no prompt appears; the viewer reports the host closed the connection). After 2 minutes a new request prompts again. |
| L11 | Start a request and wait 5 minutes without answering. | The countdown reaches 0:00, the host prompt closes, the viewer says "The request expired. Click Pair to try again." |
| L12 | Start a request and enter 5 wrong codes on the host. | After the 5th the prompt closes; the viewer says "Too many wrong codes were typed on the host…". Nothing is pinned. |
| L13 | Start a request, then click **Cancel** on the viewer while the host prompt is up. | The host prompt closes within a second and the host shows "The other Mac cancelled its pairing request." |
| L14 | Two viewers click Pair on the same host within a second (or one viewer while another's prompt is up). | Only one prompt. The other viewer gets "That Mac is answering another pairing request. Try again in a moment." |
| L15 | Spam: from one viewer, start and cancel requests repeatedly (or Decline each). | At most 3 prompts per 10 minutes from that address; further requests are dropped silently (no prompt, no answer), and the host log shows `ignored a pairing request from <address>`. |
| L16 | Host: turn sharing **off** while a prompt is up; then try Pair from the viewer. | The prompt closes; the viewer says "That Mac stopped sharing." With sharing off the host disappears from **On this network** and Pair by address fails to connect (no port open, as L1). |
| L17 | Pair by address: viewer **Pair by address…**, enter the host's IP, click **Pair**. | Same as L5–L9: the prompt shows the viewer's name, ID and IP. |

### 4.2 Sharing a window

Use windows of different kinds: a text editor, Safari playing a video, a Finder window, and a Terminal.

| # | Steps | Expected |
| --- | --- | --- |
| S1 | Host: in **Windows to share**, tick a TextEdit window. | The viewer lists that window under the host within about 1 s. Nothing else is listed. |
| S2 | Host: look for a password manager or Keychain Access window, and for paneshare's own windows. | They're not in the host's list. |
| S2a | Host: bring up a system password prompt (System Settings → Users & Groups → a change that asks for your password, or a Touch ID / passkey prompt in Safari). Look at the host's list, and at the viewer's list. | The prompt is in neither list, even if a password manager isn't involved. |
| S2b | Host: share a TextEdit window, then hide TextEdit (Cmd-H). | Its windows leave the list on both sides. A viewer that tries to open it from a stale list gets "That window is no longer available." An already open viewer window keeps its last frame. Unhide brings the entries back. |
| S3 | Viewer: **Open**. | A native window opens. Its title is the source window's title, its subtitle is "on <host name>", and it has the same point size as the source. A **new Dock icon** appears: the source app's icon in a coloured ring, named "<App> on <Host>" (see §4.6). |
| S4 | Compare text sharpness between a 2× viewer and a 2× host (Quality: Native). Put the viewer window next to the source; zoom with the Accessibility zoom (Ctrl-scroll) on both. | Within about 0.3 s of the text stopping changing it is pixel-identical to the source in black-on-white text: no blur, no colour fringes, no blocky edges. On a 1× external display, it should match a native 1× window. See §4.2.1 to diagnose. |
| S5 | Host: type in the source window. | The viewer updates in under ~50 ms. Measure in §6. |
| S6 | Host: leave the window untouched for 30 s. | The host's CPU and network stay near idle, because unchanged frames aren't encoded. |
| S7 | Play a 60 fps video in a shared Safari window. | Smooth playback with no growing delay. Switching tabs keeps it smooth. |
| S8 | Host: minimize the source window, or switch it to another Space. | The viewer keeps the last frame and doesn't disconnect. It resumes when the window is restored. |
| S9 | Host: untick the window. | The viewer window closes, and the window disappears from the viewer's list. |
| S10 | Host: close the source window. | The viewer window closes within about 1 s. |
| S11 | Share a second window from the same app and one from another app, and open both. | Three independent viewer windows, and two helper Dock icons: one per remote app. |
| S12 | Viewer: **Connect** tab → **Quality for new windows** → Balanced, then Economy; open a window each time. | Text is slightly softer at Balanced and visibly softer at Economy; network use (Activity Monitor) drops to about 56% and 25%. Native is the default and pixel-sharp. Already open windows keep their quality. |
| S12b | Viewer: turn on **Lower quality automatically on a slow network** and open a window with moving video. Limit the network with Network Link Conditioner. Then remove the limit. | Console on the host shows `bitrate factor` stepping down and video keeps moving. After about 15 s per step with no drops, it steps back up to 1.00. With the setting off, the factor never changes. |
| S13 | Host: open a window on the viewer, then run `pmset -g assertions \| grep -i paneshare` on the host. Close the window and run it again. | While the stream runs, paneshare holds idle-sleep and display-sleep assertions. After the last stream closes, they are gone. With a browser guest watching, the same holds. |
| S14 | Host: tick a **Whole screen** row. Viewer: open it. Click, type and scroll in it. | The whole screen appears in one window. Input lands where you point. It can't be resized from the viewer, and the stream has no sound. |
| S15 | Host: have a password manager window open when the stream starts, then open another during the stream. Type on the viewer with the password manager in front. | Both windows stay hidden in the stream (the second within 2 seconds). Key presses don't reach it. |
| S16 | Host with two screens: offer both. Viewer: **Open every screen**. | Each screen opens in its own window. Input maps correctly on the second screen, including when it's left of the main one. |
| S17 | Use the notarized app in `/Applications`. **This Mac → Startup:** turn on **Open paneshare when I log in**. If **Allow in Login Items…** appears, follow it. Log out and back in. | paneshare opens by itself and sharing stays off. Turning the setting off and logging in again doesn't open it. |
| S18 | Turn on **Turn on sharing when paneshare opens**. Quit and reopen paneshare. Connect from a paired viewer. | Sharing is on without a click, and the viewer connects. Its list has no windows until you tick some on the **Share** tab. |
| S19 | Same setting, with Screen Recording off for paneshare. Reopen paneshare. | Sharing stays off and no permission prompt appears from the launch. Console shows `sharing stayed off at launch`. |
| S20 | Host: sharing on, **Let paired Macs open apps on this Mac** off. Viewer: look at the host's row. | No apps section appears. |
| S21 | Host: turn the setting on. Viewer: open **Apps on this Mac**, search for an app that isn't running, and click **Open**. | The app opens on the host, the host shows who opened it, and its window opens on the viewer. Password managers and paneshare aren't in the list. |
| S22 | Viewer: open an app that's running with a window on another Space or none. A second viewer stays connected. | If it has a window, it opens on the viewer and shows on the second viewer's list. If not, the row says it has no window to share. |
| S23 | Host: turn the setting off. | The viewer's apps section goes away. Windows already shared stay shared until you untick them. |
| S24 | Old host with a new viewer, and new host with an old viewer. | No apps section on the viewer, and normal window sharing still works in both. |
| S25 | Run `/Applications/paneshare.app/Contents/MacOS/paneshare --doctor` with paneshare quit. Then use **This Mac → Copy Problem Report** and paste it. | The command prints the checks and exits with no window, and exits 1 only on a `[problem]`. The pasted report also shows permissions, sharing and counts. Neither has a Mac name, address, fingerprint or window title. |
| S26 | Viewer: **This Mac → Outline remote windows** on, then open windows from two Macs. On one Mac's row, choose another colour from the … menu and open a new window. | Each window has a thin outline in its Mac's colour, and the new one uses the chosen colour. Clicks still land where you point. With the setting off, new windows have no outline. |
| S27 | Host: turn on **Remember the apps I share**, tick a Terminal window, and quit and reopen paneshare (with **Turn on sharing when paneshare opens** on). | Terminal's windows are ticked again without a click, and appear on the viewer. Other apps aren't ticked. |
| S28 | Same setting: open a new Terminal window. | Within about 5 s, it's ticked and on the viewer's list. |
| S29 | Same setting: untick a Terminal window, wait 10 s, then restart paneshare. | It stays unticked, and Terminal's windows don't come back after the restart until you tick one. |
| S30 | Turn **Remember the apps I share** off, then back on after a restart. | Nothing old comes back. Only apps ticked since then are remembered. |
| S31 | Host: turn on **Share my whole screen when sharing starts** and restart paneshare. | Every screen is ticked, and **Whole screen** rows appear on the viewer. With the setting off, none are. |

#### 4.2.1 Sharpness diagnostics

Turn on the hidden overlay on the **viewer** and restart paneshare:

```bash
defaults write dev.paneshare.app debugOverlay -bool YES
```

Each remote window now shows an overlay at the top left (it ignores clicks), refreshed every second and logged
every 5 s (`log stream --predicate 'process == "paneshare"' --info | grep "paneshare viewer stream"`). The host logs
one `paneshare host stream …` line per encoder build regardless of the setting.

| # | Steps | Expected |
| --- | --- | --- |
| Q1 | Open a TextEdit window at Native, both Macs 2×. Read the overlay. | `host window W×H pt @2x · capture 2W×2H BGRA`; `enc HEVC 4:4:4 hw · 2W×2H` (or `4:2:2`/`4:2:0` if the hardware lacks the profile; the profile line names it); `view decoded 2W×2H · shown 2W×2H px = W×H pt @2x · 1:1`. **Capture px = encoded px = decoded px = shown px, and mapping `1:1`.** |
| Q2 | Type a line, then stop. | `rx` jumps while typing; about 0.15 s after you stop, the top-up count goes up by 2 and the text visibly snaps sharp if it wasn't. (A blinking caret is a change too, so the count keeps rising by 2 per blink.) |
| Q3 | Resize the viewer window by dragging, then let go. | During the drag the mapping may say `scaled ×…`; after the release it returns to `1:1` with all four sizes equal again. |
| Q4 | Drag the viewer window to a 1× display (if available). | `@1x`, a new encoder build (host log), and `1:1` again at half the pixels. |
| Q5 | `defaults write dev.paneshare.app chroma 4:2:0`, reopen the window. | `enc … 4:2:0`. Coloured text (syntax highlighting, red-on-white) shows fringes compared with Q1; black-on-white is close. Set back with `defaults delete dev.paneshare.app chroma`. |
| Q6 | Quality Balanced, reopen. | Mapping `scaled ×1.333` (expected: Balanced is ¾ resolution). |

If Q1 shows anything other than `1:1`, or capture px smaller than shown px, send the overlay text (or the two
log lines) with the bug report. If a 4:4:4 stream fails to decode on the viewer, the log says
`… failed to decode here; re-opening in 4:2:0` and the window comes back in 4:2:0 by itself.
Turn the overlay off with `defaults delete dev.paneshare.app debugOverlay`.

### 4.3 Input

| # | Steps | Expected |
| --- | --- | --- |
| I1 | Viewer: click in the shared window. | The host raises the source window (and app), and the click lands where the pointer is on the viewer, within about 1 pt. |
| I2 | Type, including accented characters (Option-e then e), arrow keys, Delete, Return and Tab. | Same result as typing on the host. The **host's** keyboard layout applies. |
| I3 | Command shortcuts: Cmd-A, Cmd-C, Cmd-V, Cmd-Z, Cmd-S. | They act in the host app, not on the viewer. **Cmd-Q quits the viewer app**, by design. |
| I4 | Hold a key (key repeat), and hold Shift while clicking (to extend a selection). | Repeats arrive. Modifiers are respected, and no key stays stuck when you release it. |
| I5 | Scroll with a trackpad (with momentum) and with a mouse wheel. | Smooth pixel scrolling with momentum on a trackpad, and line steps with a wheel. |
| I6 | Drag to select text. Drag a window's scroll bar. | It tracks smoothly. Releasing ends the drag on the host. |
| I7 | Right-click (and Control-click). | The context menu opens on the host, at the pointer. |
| I8 | Double-click and triple-click a word. | Selects the word, then the line. |
| I9 | Host: bring another app to the front. Viewer: type without clicking. | **Nothing is typed into the other app.** Keys are dropped until the next click in the viewer raises the source window. |
| I10 | Host: move the source window to another display, including one to the left of or above the main display. | Clicks still land in the right place within about 250 ms. |
| I11 | Host: turn Accessibility **off** for paneshare while a viewer window is open. | Within about 1 s the viewer window's subtitle says "view only (that Mac hasn't allowed Accessibility)". Video works, and input and resize do nothing. Turning it back on makes input work and clears the subtitle within about 1 s. |
| I12 | Host: click into a password field (a Safari login form), or turn on Terminal → **Secure Keyboard Entry**. Viewer: type into the shared window. | Within about 1 s the subtitle says "typing paused while that Mac is entering a password". Key presses don't arrive; clicks and scrolling still work. A key held while it starts doesn't stay stuck. Leaving the field (or turning Secure Keyboard Entry off) resumes typing within about 1 s. |
| I13 | Both Macs: **This Mac** → turn on clipboard sync. With a remote window in front on the viewer, copy text on the viewer and paste in the remote window. Copy in the remote window and paste on the viewer. | The text arrives both ways. macOS may ask once to allow clipboard access. |
| I14 | Turn sync off on one Mac, or put a local app in front on the viewer, and copy text. | Nothing moves. |
| I15 | Copy a password from a password manager that marks items as concealed, with a remote window in front. | It stays on that Mac. |
| I16 | Copy about 900 KB of text on the viewer with a remote window in front. | It arrives, and the session stays connected. Above 1 MB, nothing moves and the session stays connected. |
| I17 | Host: **This Mac** → accept files. Viewer: drag a file from Finder onto a remote window. | Progress shows under the host in **Connect**. The file appears in `Downloads/paneshare` on the host with matching contents (`shasum`), and the host panel offers **Show in Finder**. |
| I18 | With accepting off on the host, drop a file. Then, with it on, drop a folder, and drop a file with the same name twice. | The first is refused with a message. The folder is refused. The second copy is named `name 2.ext`, and nothing is replaced. |
| I19 | Quit the viewer in the middle of a large transfer. | No `.part` file stays in `Downloads/paneshare` on the host. Typing still works during a transfer. |
| I20 | Send an app or script, then open it on the host. | Gatekeeper treats it as downloaded, and `xattr -l` shows `com.apple.quarantine`. |
| I21 | Viewer: **This Mac** → turn on **Accept files from Macs I connect to**, and open one of the host's windows. Host: under **Viewers**, click **Send Files…** on the viewer's row and pick two files. Then drag a file onto the same row. | Each file appears in `Downloads/paneshare` on the viewer with matching contents (`shasum`), one after the other. Progress shows under the viewer's row on the host. The viewer's **Connect** tab says the host sent the file and offers **Show in Finder**. The file has `com.apple.quarantine`. |
| I22 | With the viewer setting off, send a file. Then turn it on, close every remote window on the viewer, and send again. | Both are refused with a message under the viewer's row on the host. Nothing is written on the viewer. Accepting dropped files on the viewer (I17's setting) doesn't let a host send. |
| I23 | Disconnect the viewer, or quit the host, in the middle of a large transfer. | No `.part` file stays in `Downloads/paneshare` on the viewer. Typing in the remote window still works during a transfer. |

### 4.4 Resize

| # | Steps | Expected |
| --- | --- | --- |
| R1 | Viewer: drag the viewer window's corner slowly for a few seconds. | The **host** window follows the drag (at most one update per 100 ms). **During** the drag the picture keeps its resolution and is scaled or letterboxed into the viewer window, and the host's CPU doesn't spike (the encoder isn't rebuilt). Within about 0.2 s of releasing, the picture becomes sharp at the new size. |
| R2 | Resize an app with a minimum size (for example System Settings) below its minimum. | The viewer snaps back to the size the host app accepted. |
| R3 | Resize a fixed-size window (for example a dialog-like window). | The viewer snaps back to the host's size. |
| R4 | Full-screen the viewer window (green button). | The host window grows to the viewer screen's point size, if the host display has room. Otherwise it's capped at the size the host accepts. |
| R5 | Option-click the green button (zoom), or use a tiling shortcut on the viewer. | One resize, applied at once and sharp immediately (a one-shot resize is final). |

### 4.6 Dock icons and Command-Tab (viewer)

Default is one helper app per remote app. To compare with the single-icon fallback, run
`defaults write dev.paneshare.app dockHelpers -bool false` and relaunch (`-bool true` or `defaults delete` to undo).

| # | Steps | Expected |
| --- | --- | --- |
| D1 | Open a window from a host app (for example Xcode on "Studio"). | A Dock icon "Xcode on Studio" appears with Xcode's icon in a ring of the host's colour. A second host gets a different colour. |
| D2 | Press Cmd-Tab. | "Xcode on Studio" has its own entry, separate from paneshare and from a local Xcode. |
| D3 | Focus another app, then click the helper's Dock icon (or Cmd-Tab to it). | That app's viewer windows come to the front and the keyboard goes to the most recent one. Expect a frame or two of focus flicker; afterwards Cmd-Tab shows paneshare as the frontmost app (a known limitation). |
| D4 | Right-click the helper's Dock icon. | The menu lists that app's viewer windows by title, then **Close All**. Choosing a title focuses it; **Close All** closes them all and the icon goes away. |
| D5 | Cmd-Tab to the helper and press Cmd-Q (or Dock → Quit). | That app's viewer windows close; other apps' windows stay. |
| D6 | Close the last viewer window of an app. | Its helper icon disappears within about 1 s. |
| D7 | Open windows of two remote apps, then force-quit paneshare (Activity Monitor). | Both helper icons disappear within about 2 s (watchdog). |
| D8 | Force-quit one helper (Activity Monitor → "Xcode on Studio"). | It comes back within about 1 s and its windows are unaffected. After a third forced quit, that app falls back to paneshare's own icon. |
| D9 | Right-click a helper → Options → **Keep in Dock**. Quit paneshare. Click the pinned icon. | paneshare launches, connects to that host and reopens that app's shared windows. If the host isn't reachable or nothing is shared, the helper quits after about 30 s. |
| D10 | Unpair the host, relaunch paneshare. | That host's helpers are deleted from `~/Library/Application Support/paneshare/DockHelpers/`. |
| D11 | In Terminal: `codesign --verify --strict --verbose=2 ~/Library/Application\ Support/paneshare/DockHelpers/*/*/*.app` | Every helper is "valid on disk" and "satisfies its Designated Requirement". No helper has a quarantine attribute (`xattr -l`). |
| D12 | In Terminal: `ls -la ~/Library/Application\ Support/paneshare/run/` while paneshare runs; then try `nc -U ~/Library/Application\ Support/paneshare/run/dock.sock` and type `{}`. | The directory is `drwx------` and `dock.sock` is `srw-------`. The `nc` connection is closed within about 3 s without any effect, because `nc` isn't a helper paneshare signed. |
| D13 | Set the Dock to its smallest size (System Settings → Desktop & Dock → Size), and open Cmd-Tab. | The helper's ring is still a visible coloured outline at the small size, and its colour matches the other helpers from that host. At normal size the paneshare badge shows at the bottom right. |
| D14 | With helpers already generated by a build from before the ring icon (or any lower `HelperBundlePlan.revision`), switch to this build and reopen a window from that app. | The helper is regenerated with the new look (Dock tile refreshes, possibly after a moment); there's no stale icon. |
| D15 | Finder: select `build/app.noindex/paneshare.app` and press Cmd-I; copy it to `/Applications` and look at it in the Dock and Launchpad. | paneshare's own icon (two screens, a pane shareing between them) shows at every size, with no generic app icon. At 16 px (Finder list view) the simplified art reads as a screen and a tilted pane. |
| D16 | Run `scripts/make-app.sh` (and, on the release Mac, `scripts/release.sh`) with paneshare also in `/Applications`, then search Spotlight for "paneshare" and open Launchpad. Then run `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \| grep -E '^path: .*paneshare\.app'`. | One paneshare in Spotlight and Launchpad: the one in `/Applications`. The dump lists no path under `build/` or `$TMPDIR` (after opening a build copy, `scripts/make-app.sh unregister` removes it again). |

### 4.5 Connection lifecycle and trust

| # | Steps | Expected |
| --- | --- | --- |
| C1 | Viewer: turn Wi-Fi off for 5 s, then on. | The viewer shows "Retrying." with the reason, reconnects within about 1–10 s (backoff), and **the same viewer window comes back** with fresh video. |
| C2 | Host: turn sharing off. | The viewer windows close, and the viewer shows the host as not connected and retries. Turning sharing on reconnects it. |
| C3 | Host: quit paneshare. Relaunch it and turn sharing on. | The viewer reconnects without pairing again, because the identity persisted in the Keychain. |
| C3b | With a Developer ID build, note **This Mac → Mac ID**. Quit and reopen paneshare twice. Install a newer build and open it. | The Mac ID never changes, and paired Macs reconnect with no new pairing. `security find-generic-password -s dev.paneshare.identity -a device-key` shows the same `mdat`. |
| C3c | Turn on sharing and open **Connect** on the same Mac. | This Mac doesn't list itself under **On this network**. |
| C4 | Host: **Unpair** the viewer. | The viewer's live session drops at once, and reconnecting fails inside the TLS handshake. Expect "The other Mac's identity is not trusted. Pair again." If a different TLS status shows up as "Network error: …", note the code so the mapping in `ChannelError` can be extended. |
| C5 | Host: **This Mac → Reset identity and all pairings…**, then relaunch. | Every viewer fails with "not trusted. Pair again." It never connects silently. Pairing again works. |
| C6 | Viewer: **Unpair** the host. | The session closes, and the host disappears from the paired list (it may still be discovered). |
| C7 | Put the host to sleep for 1 minute, then wake it. | The viewer reconnects within about 10 s of the host's network coming back. |
| C8 | Host: turn sharing off for 30 s while a viewer is connected, watching the viewer's row. | The status stays on "Retrying." and the button stays **Stop Trying**, with no flicker. Tries slow to one every 10 s. **Stop Trying** shows **Connect**. Turning sharing on reconnects it within about 10 s. |

### 4.7 App audio

Setup: on the host, open **Music** (or Spotify) and **QuickTime Player** with a video, and keep a **TextEdit**
window too. Plug headphones or speakers into the viewer. The first time the host shares sound, macOS asks to
allow paneshare to record **System Audio** (System Settings → Privacy & Security → Screen & System Audio
Recording → "System Audio Recording Only"); allow it. On macOS 14.0–14.1 there is no prompt, because the
ScreenCaptureKit fallback uses Screen Recording.

| # | Steps | Expected |
| --- | --- | --- |
| A1 | Host: share a Music window and start a song. Viewer: open that window. | Within about 1 s the song plays on the viewer, and the viewer's host row shows "Sound: Music — playing" with a speaker button and a slider. The song keeps playing on the host's own speakers. Host log: `audioStarted` is preceded by no error; Console shows no `paneshare audio:` failure lines. |
| A2 | Host: share a QuickTime window playing a clip with visible speech (or a clapperboard / metronome video); open it on the viewer. Watch lips or claps. | Sound and picture match. If there's a lag it's audio slightly behind (≤ about 100 ms), never audio ahead. |
| A3 | Play sound in two shared apps (Music and QuickTime) with both windows open on the viewer. Move the Music slider to 20 %. | Two independent rows. Only Music gets quieter. Mixing has no clicks. |
| A4 | Viewer: click Music's speaker button (mute). | Music goes silent at once; the row says "muted". Activity Monitor → Network on the host: paneshare's sent bytes drop by about 12 KB/s (the stream stops at the host). Unmute: sound returns within about 1 s at the saved volume. |
| A5 | Viewer: quit and relaunch paneshare, reconnect, reopen the Music window. | The mute state and volume from A3/A4 are remembered for that host and app. |
| A6 | Host: in **Windows to share**, click the speaker next to Music (turn its sound off). | The viewer's Music row says "no sound"; QuickTime still plays. Click again: Music's sound comes back. |
| A7 | Host: turn off **Share the sound of shared apps**. | Every app goes silent on the viewer; the picture continues. Turn it on: sound comes back for the open windows. |
| A8 | Host: share TextEdit only and play Music unshared. | The viewer hears **nothing** — only apps with a shared window that is open on the viewer send sound. |
| A9 | Host: close the shared Music window (keep Music playing). | The viewer window closes and its sound stops. |
| A10 | Excluded apps: on the host, trigger a sound in an app on the deny-list (for example 1Password's or Keychain Access's alert sound) while the viewer has other windows open. | Nothing from it reaches the viewer, and no speaker button is shown for such apps (they are never in the list). |
| A11 | Host: change the output device (plug in headphones, or pick another output in Control Center) while A1 plays. | Sound continues on the viewer within about 2 s, possibly after a short gap. If it stops, close and reopen the window and note it in §7. |
| A12 | Fallback: on the host run `defaults write dev.paneshare.app audioCapture screenCaptureKit`, relaunch, repeat A1–A2. Then `defaults delete dev.paneshare.app audioCapture`. | Same behaviour through ScreenCaptureKit. Console: `using ScreenCaptureKit` is **not** logged (it was forced, not a failure). |
| A13 | Viewer: Network Link Conditioner "3G" for 30 s while A1 plays, then off. | Sound may break up but never builds up a growing delay; within 1 s of switching the profile off it's back in sync. |
| A14 | Safari: share a Safari window playing a YouTube video. | **Known limit:** web audio comes from WebKit helper processes, so the tap may capture nothing. Note whether you hear it. Repeat with A12's fallback and note the result. |

### 4.8 Virtual display

Logs are in Console (filter on `paneshare host`). "Host panel" means the host Mac's paneshare window. Setup for
V1–V8: an ordinary host Mac with one screen. V9–V10 need a Mac mini (or a MacBook in clamshell mode with an
external display unplugged) with **no screen** attached, reached by the viewer over the LAN; set it up first with
a screen attached (permissions, pairing, sharing on), then unplug the screen.

| # | Steps | Expected |
| --- | --- | --- |
| V1 | Host panel: **Virtual display** shows **Off** (default). Share TextEdit; open it on the viewer; full-screen the viewer window. | As before: the host window grows only as far as the host's screen. No `virtual display` log lines. System Settings → Displays on the host lists no extra display. |
| V2 | Host panel → Virtual display → **When needed**. Viewer: close and reopen the TextEdit window at its normal size. | Nothing moves (it fits on the real screen). No extra display. |
| V3 | With **When needed**, viewer: full-screen the viewer window (the viewer's screen must be bigger than the host's, e.g. a 27" viewer and a 13" host; otherwise drag the viewer window larger than the host's screen and release). | After the release, the TextEdit window disappears from the host's screen and a display named "paneshare …" appears in System Settings → Displays. Log: `moved to a WxH pt virtual display (2W×2H px)`. The viewer shows the window at the full requested size, **sharp** (zoom with the viewer's Accessibility zoom: text edges have no blur). The diagnostics panel shows capture pixels at 2× the point size. |
| V4 | Viewer: close the TextEdit viewer window. | Within about 1 s the TextEdit window is back on the host's screen at its **original position**, and the "paneshare" display is gone from System Settings → Displays. |
| V5 | Host panel → **Always**. Open two windows (TextEdit and Notes) on the viewer. | Both move to one virtual display (one "paneshare" display in Displays, not two). Close one: the display stays. Close the other: both windows are back and the display is gone. |
| V6 | With **Always** and a window on the virtual display, host panel: turn **sharing off**. | The window returns to its original position and the display disappears. |
| V7 | With **Always** and a window on the virtual display, quit paneshare on the host (Cmd-Q). | The window returns, the display disappears, and nothing is left in Displays. |
| V8 | With **Always** and a window on the virtual display, force-quit paneshare on the host (Activity Monitor → Force Quit, or `kill -9`). | The display disappears within a few seconds and macOS moves the window to the host's screen (maybe not at its original position — known limit). Relaunch: no stray display. |
| V9 | Headless host (no screen), **When needed**. Viewer: open a TextEdit window and full-screen it. | The window moves to a virtual display the size of the viewer's screen and is sharp at that size, not limited to the headless fallback resolution. Typing, clicking and resizing work. |
| V10 | Headless host, setting **Off**. Repeat V9. | Streaming still works, but windows are limited to (and blurry beyond) the small headless framebuffer. This is the "before" picture for V9. |
| V11 | Unavailable API (simulated): there's no switch to hide the private classes, so check the degraded path by reading Console during V2 on each macOS version you test. | If macOS ever removes or changes the API, the host panel shows "Not available on this Mac (…)" under the picker, the log says `virtual display unavailable … ` once, and windows stay on the real screen as in V1. On current macOS (14, 15, 26) this note should **not** appear. |
| V12 | Two viewers, **Always**: viewer A and viewer B each open a different window. | Two "paneshare" displays, one per viewer, each sized to its viewer's screen. Disconnecting viewer A brings its window back and removes only A's display. |
| V13 | Host: **Let paired Macs move shared windows off this screen** off, virtual display **Off**. Viewer: open a window. | No **Move Away** button. |
| V14 | Host: turn it on. Viewer: click **Move Away** on an open window, then click and type in it. | The window leaves the host's screen and video keeps running. Input lands where you point. The host shows **Bring Back** under Viewers. |
| V15 | Viewer: **Bring Back**. Repeat V14, then **Bring Back** on the host. Repeat V14, then disconnect the viewer or quit either app. | Each time, the window returns to its old spot on the host's screen. |
| V16 | Whole-screen stream, and a host with Accessibility off. | No **Move Away** button. |

### 4.9 Share links (browser guest)

Here the second Mac is a **guest**: it needs only a browser (Safari 16.4+, Chrome or Edge, or Firefox 130+), not
paneshare. Use a different Mac, or a Windows or Linux laptop, on the same LAN. Setup: host has sharing on and
**TextEdit** shared (checkbox ticked) with a document full of text. Each link works for **one** guest; for a second
guest make a second link.

| # | Steps | Expected |
| --- | --- | --- |
| W1 | Host: before making any link, on the guest run `curl -k https://<host-ip>:47822/` (or `nc -vz <host-ip> 47822`). | Connection refused: the port is closed while no link exists. |
| W2 | Host panel: click the link icon (🔗+) next to TextEdit. Leave **1 hour** and pointer **off**; click **Create Link**. | The sheet lists URLs (Tailscale first if present, then "Local network", then "Local name"), each `https://…:47822/s/…#…`, plus a SHA-256 fingerprint and the expiry time. A "Share links" section appears in the host panel: TextEdit, `59:5x left`, "Not opened yet". |
| W3 | Copy the "Local network" URL to the guest (Messages, AirDrop, email). Open it in the guest's browser. | The browser warns about the certificate. Open its details (Safari: "Show Certificate"; Chrome: "Not secure" → "Certificate is not valid") and compare the SHA-256 with the sheet: they match. Proceed. |
| W4 | Guest: type a name ("Ann") and click **Join**. | The address bar no longer has the `#…` part. Within 2 s TextEdit appears, sharp at the guest's screen scale, titled with the window title; "View only" and "Link ends at …" show. Host panel: "Ann · <guest IP> · since …" under the link. |
| W5 | Host: type in TextEdit and scroll it. | The guest sees each change within a frame or two. |
| W6 | Guest: move the mouse over the picture, then click on some text and scroll. | On the host an **orange arrow labelled "Ann"** follows the guest's mouse over TextEdit; it vanishes 3 s after the guest stops. The click and scroll do **nothing** on the host (view only). The arrow isn't in a screenshot of the host (Cmd-Shift-3) or in another viewer's stream. |
| W7 | Host panel: switch **Pointer** on for that link. Guest: click to place the caret, drag to select text, right-click, scroll. | The guest's mode line says "You can point, click and scroll". The caret moves, the selection is made, the context menu opens, the document scrolls. The guest pressing keys types **nothing**. |
| W8 | Guest: start dragging a selection and keep the button down; host: switch **Pointer** off. | The guest's mode line goes back to "View only", the drag ends on the host (no stuck button), and further clicks do nothing. |
| W9 | Guest: reload the page. Then close the tab and open the same URL again in a new tab. | Reload: back in the picture in a couple of seconds, no name prompt. New tab: "This link was already used…" (the token is one-time; the session lives only in the first tab). |
| W10 | Guest: switch Wi-Fi off for 10 s, then on. | "Connection lost. Reconnecting…", then the picture comes back without a new name prompt. Host panel shows the guest leave and come back. |
| W11 | Host panel: **Kick** Ann. | Guest: "The host removed you from this window." Reloading doesn't get back in. The link row says "Guest not connected…". |
| W12 | Make a new link with **15 minutes** and open it on the guest. Wait for it to run out (or set the host's clock forward 16 minutes). | At expiry the guest sees "The link has expired." and the link leaves the host panel within 5 s. When the last link goes, W1 again shows the port closed. |
| W13 | New link, guest joined. Host panel: **Revoke**. | Guest disconnected with "This link isn't valid any more…"; the URL gives "This link has expired or doesn't exist" afterwards. |
| W14 | New link, guest joined. Host: untick TextEdit (stop sharing it), or close the TextEdit window. | Guest: "The host closed this window." The link is gone from the panel. |
| W15 | Two links for the same window, two guests (a second browser or private window). | Both see it; both arrows show with their names; the pointer switch applies per link. Kick one: the other stays. |
| W16 | Create a link with **1 week**. | The sheet shows the date and time, the row shows `6d 23h left`, and the guest page shows the date. Quit paneshare: the link stops working. |
| W17 | Create a link and click **QR Code**. Scan it with a phone on the same network. | The code stays hidden until clicked. The phone opens the link and, after the certificate warning, joins as a guest. Clicking again hides the code. |
| W18 | Phone guest with the pointer on: tap, double-tap, drag, long-press and two-finger scroll in the window. | A tap clicks, a double-tap double-clicks, a drag drags, a long press right-clicks, and two fingers scroll. No button stays held after lifting a finger. |
| W19 | Phone guest with the pointer off: tap and drag. | The host sees the guest's arrow move, and nothing is clicked. |
| W20 | Phone guest: pinch out and move, then two-finger tap. Turn the phone sideways. | The picture zooms and moves on the phone only, and taps still land on the right spot. The two-finger tap puts it back. Sideways, the header hides and the picture fills the screen. |
| W16 | Guest joined. Host: turn **sharing off**. | Guest: "The host stopped sharing." All links are gone; W1 shows the port closed. |
| W17 | Link to a window, then quit and relaunch paneshare on the host; open the link. | "This link has expired or doesn't exist" (links live only in memory). |
| W18 | Guest: open `https://<host-ip>:47822/s/AAAAAAAAAAAAAAAAAAAAAA`, `/viewer.js`, `/etc/passwd`, and a `POST` with `curl -k -X POST`. | Unknown link: the 404 text. `viewer.js`: the script (no secrets in it). Others: 404; POST: 405. |
| W19 | Share a password manager window (excluded by policy) — it can't be ticked, so the link icon never appears for it. | No link possible. |
| W20 | Guest with an old browser (Safari 15, or Firefox before 130). | "This browser can't show the window: it needs WebCodecs…". |

### 4.10 Signed release and updates (release Mac, then a second Mac)

Needs the one-time setup in docs/RELEASING.md §1 and a feed host from §3 (a throwaway Pages site is fine for
testing; use a test feed URL, never the real one, until U10 passes). "Old build" means a release made with a
lower `PANESHARE_VERSION` and build number.

| # | Steps | Expected |
| --- | --- | --- |
| U1 | Quit paneshare. Run `scripts/release.sh` as in RELEASING §2 from a clean checkout (default: `asc`). | It ends with "Done". Both notarizations say `notarized … with asc` (`Accepted`), the Dock helper self-test prints `app quarantined: yes`, `helper quarantined: no` and `dock-helper-selftest: PASS`, `spctl` says `accepted … source=Notarized Developer ID` for the app and the DMG, `stapler validate` passes for both, and `build/updates/` has the DMG and `appcast.xml`. |
| U2 | Same, with an uncommitted change, an `http://` feed, an Apple Development identity, an identity of another team, `PANESHARE_NOTARY_TOOL=foo`, or a version like `v2`. | It stops before building, with a one-line reason. |
| U2b | Repeat U1 with `PANESHARE_NOTARY_TOOL=notarytool PANESHARE_NOTARY_PROFILE=<profile>` and a higher version. | Same result, with `notarized … with notarytool`. |
| U3 | On a second Mac, download the DMG with Safari from the host, open it, drag paneshare to Applications, and open it. | The usual "downloaded from the Internet" prompt (Apple checked it for malicious software); no "cannot be opened" or "damaged" warning. `xattr -p com.apple.quarantine` on the DMG shows the quarantine flag. |
| U4 | First launch of that copy. | After the main window, one question: "Check for paneshare updates automatically?". Choose **Check Automatically**. It's never asked again (relaunch to check). |
| U5 | Repeat U3–U4 on a clean user account and choose **Don't Check**. Watch for 2 minutes with Little Snitch or `nettop -p paneshare`. | No connection to the feed host. **paneshare → Check for Updates Automatically** is unticked; ticking it schedules a check. |
| U6 | Install the old build, publish the new one to the test feed, then **Check for Updates…**. | Sparkle shows the new version and its notes. **Install Update** downloads, verifies, replaces and relaunches; paneshare → About shows the new version. Nothing installs without that click. |
| U7 | Edit one character in the uploaded `appcast.xml` (don't re-run `generate_appcast`), then **Check for Updates…** from the old build. | The update is refused (the feed signature fails; Console shows Sparkle's signing error). Restore the file afterwards. |
| U8 | Ad hoc build from `scripts/make-app.sh`. | No consent question, **Check for Updates…** disabled, and no automatic-check item. |
| U9 | On the downloaded release, open a remote window so a Dock helper is generated (§4.6 D1). Then run `xattr -l` on the helper (path in RELEASING §6) and `codesign -dv` on it. | The helper launches with its ring icon. It has no `com.apple.quarantine`; it's ad hoc signed (`Signature=adhoc`) and its `Info.plist` has `PaneshareMainTeamID` and `NSUpdateSecurityPolicy`. |
| U10 | With U9's helper running, update paneshare (U6), then open a window from the same app. | The helper is reused, or regenerated with no "prevented from modifying apps" notice. If that notice appears, record it (RELEASING §5 item 6) and allow paneshare under App Management. |
| U11 | Run a copy of `paneshare-dock-helper` (from a generated helper) while paneshare isn't running and another process listens on `run/dock.sock`, for example `nc -lU`. | The helper quits without sending anything: the listener is not Developer ID signed by the team. |
| U12 | App audio on the notarized build (§4.7 A1). | Sound plays on the viewer. If capture fails only in the notarized build, note the Console error: the hardened runtime may need another entitlement. |
| U13 | **Second Mac, the open risk.** After U3 (downloaded, quarantined, opened once, then quit), run the self-test from RELEASING §5: `open -W -n /Applications/paneshare.app --args --dock-helper-selftest /tmp/paneshare-dock-selftest.txt`. | The report says `team: TV289JZ58M`, `helper quarantined: no`, `helper connected…`, and ends `dock-helper-selftest: PASS`. No dialog about the helper. |
| U14 | Same Mac: pair with the host and open windows of two remote apps. | Each gets its own ringed Dock tile and Cmd-Tab entry within about 2 s, as in §4.6 D1–D2. No "cannot be opened", "damaged" or "Apple could not verify" dialog. |
| U15 | Same as U13, but run the copy straight from the mounted DMG, or from `~/Downloads` without moving it (App Translocation). | Still PASS: helpers are written to Application Support, never next to the app. |
| U16 | Force a silent helper: with paneshare running and no window of some remote app open, run `chmod 000 ~/Library/Application\ Support/paneshare/run` (new helpers then can't reach the link), open a window of that app, and afterwards `chmod 700` it back. | The helper's tile appears briefly and goes away, and within about 10 s the window is under paneshare's own Dock tile. Console shows "launched but didn't connect within 10 s". The window keeps working throughout. A second app opened the same way logs "Dock helpers off until relaunch" and goes straight to the single tile; after relaunching paneshare, helpers work again. |

## 5. Tailscale variant

Bonjour does not cross a tailnet, so this variant uses **Pair by address** and the saved address.

1. Install Tailscale on both Macs and sign both into the same tailnet. Check with `tailscale status`.
2. If you use ACLs, allow the viewer to reach the host on **TCP 47821**.
3. Find the host's address: its MagicDNS name (`studio` or `studio.<tailnet>.ts.net`) or its `100.x.y.z`
   IPv4 or `fd7a:…` IPv6 address. Check the path with `tailscale ping <host>`. "via DERP" means the traffic is
   relayed, so expect higher latency. A direct path is what we want to measure.
4. Host: turn sharing on.
5. Viewer: **Pair by address (Tailscale or IP)…**. Enter `studio.<tailnet>.ts.net`, `100.101.102.103`,
   `100.101.102.103:47821` or `[fd7a:115c:a1e0::1]:47821` and click **Pair**. On the host, type the code the
   viewer shows into the prompt that appears, and click Accept.

| # | Steps | Expected |
| --- | --- | --- |
| T1 | Pair over Tailscale, with the viewer on a different network (for example a phone hotspot). | Paired. The viewer saves the address. |
| T2 | Open a window. Repeat S3–S5, I1–I3 and A1–A2. | Same behavior as on the LAN. Latency is RTT/2 higher. The RTT readout next to the host shows the tailnet RTT. |
| T3 | Viewer: quit and relaunch, then **Connect**. | It reconnects using the saved address, with no Bonjour. |
| T4 | Viewer: **Set address…** to a wrong name. | "Not found" / failed state with retry. Setting it back reconnects. |
| T5 | Turn Tailscale off on the viewer for 10 s. | Reconnects with backoff, like C1. |
| T6 | **Pair by address** with invalid addresses: `foo bar`, `host:0`, `host:70000`, `user@host`, `http://host`. | "That address isn't valid…" before anything is dialed. (**Set address…** currently ignores an invalid entry without saying so.) |
| T7 | Both Macs on the same LAN **and** tailnet. | Discovery uses the LAN. A saved Tailscale address is used only when the host isn't found by Bonjour. |
| T8 | Share link over Tailscale: ACLs must allow the guest to reach the host on **TCP 47822**. Make a link; send the guest the **Tailscale** URL (`https://100.x.y.z:47822/…`). Guest on another network, signed into the tailnet. Repeat W3–W11. | Same as on the LAN. A guest outside the tailnet can't connect at all (that's the expected limit; internet links are design-only, `docs/SHARE-LINKS-INTERNET.md`). |

## 6. Latency and performance

**Glass-to-glass stopwatch.** On the host, share a window showing a millisecond clock: a local HTML page
with `performance.now()` drawn on every animation frame, or any ms stopwatch app. Put the viewer Mac's
screen next to the host's screen, open the shared window, and take several phone photos (or a 240 fps slow-motion
video) that capture both clocks. The latency is host clock minus viewer clock. Take at least 10 samples and
report the median and worst case. Targets are in ARCHITECTURE §8: ≤ 35 ms p50 and ≤ 55 ms p95 wired, ≤ 60 ms p95 on Wi-Fi.

**Input latency.** Type into a shared TextEdit window and film both screens at 240 fps. Count frames from
the key press on the viewer to the glyph appearing on the viewer.

**Load.** While S7 plays, watch Activity Monitor on both Macs (CPU, GPU and network). Check `VTEncoderXPCService`
on the host and `VTDecoderXPCService` on the viewer: they show that hardware is in use. Software
encoding shows up as high CPU in paneshare itself.

**Degraded network.** Install Network Link Conditioner (from Xcode's "Additional Tools") on the viewer.
Apply the "3G" profile and then "Very Bad Network". Expected: video drops frames but stays current (no
growing delay), input still arrives, and the window recovers within about 1 s when the profile is
switched off.

## 7. Results template

| Date | Build (commit) | Host (model, macOS) | Viewer (model, macOS) | Network | Tests passed | Failures and notes | Latency p50 / p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

## 8. Known gaps in this plan

- There's no automated macOS integration test yet (for example, a loopback TLS pairing test between two in-process
  identities). It's on the roadmap.
- The Dock helper flow (§4.6) and the in-process signer have been checked only by unit tests and the
  `codesign` test; LaunchServices behaviour (icon caching, Command-Tab ordering) needs a real Mac.
- The port (47821) can only be changed in code (`HostListener(port:)`). There's no UI for it yet. The same
  goes for the share-link port (47822, `WebShareServer(port:)`).
- The browser viewer's page logic is checked in headless Chrome only (§1.1); Safari and Firefox need the manual
  W-tests.
