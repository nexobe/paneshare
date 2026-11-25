# Releasing paneshare

How a signed, notarized paneshare is built, and how installed copies update themselves with Sparkle 2.
Everything here runs on the release Mac. Nothing in the repository holds a secret. Only `scripts/publish.sh`
uploads anything, and it asks first.

| Piece | Where it lives |
| --- | --- |
| Developer ID Application certificate and private key | Login keychain of the release Mac |
| Notary credentials (App Store Connect API key) | The `asc` CLI's keychain profile (default), or a `notarytool` keychain profile |
| Sparkle EdDSA private key | Login keychain (item "Private key for signing Sparkle updates") |
| Sparkle EdDSA public key | Written into each release's `Info.plist` (`SUPublicEDKey`). Public by design. |
| Feed URL | Written into each release's `Info.plist` (`SUFeedURL`) from `PANESHARE_FEED_URL` |

## 1. One-time setup

You need Xcode (`xcode-select -p` prints a path) and an Apple Developer Program membership in which you can
create Developer ID certificates (the Account Holder role; for an individual membership that's you).

### 1.1 Developer ID Application certificate

Either way works:

- **Xcode:** Xcode → Settings → Accounts → select the team → **Manage Certificates…** → **+** →
  **Developer ID Application**.
- **Web:** Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority…*
  (saved to disk), then upload the request at developer.apple.com → Certificates → **+** →
  *Developer ID Application*, download the certificate and double-click it.

Check it, and note the exact name with the Team ID in parentheses:

```bash
security find-identity -v -p codesigning
#   1) 1A2B… "Developer ID Application: NEXOBE INC (TV289JZ58M)"
```

The release Mac already has this identity, and `scripts/release.sh` uses it by default
(`PANESHARE_SIGN_IDENTITY`, team `PANESHARE_TEAM_ID` = `TV289JZ58M`). Set both only to release under another team.

Back up the certificate *with its private key* (Keychain Access → export as .p12 with a strong password) to
somewhere offline. A lost key means a new certificate, and Sparkle can rotate the certificate or the EdDSA key
in one update, but not both at once.

### 1.2 Notary credentials

**Default: the `asc` CLI.** The release Mac's `asc` (Rork asc 5.14.1) already has an App Store Connect API
key profile in the keychain. `release.sh` runs, for the zipped app and then the DMG:

```bash
asc notarization submit --file <file> --wait --timeout 30m --output json
```

and requires `"status": "Accepted"` in the JSON. That exact command notarized a hand-signed DMG of an earlier
development build.
Nothing else to set up; `PANESHARE_ASC` points at another `asc` binary if it isn't on `PATH`.

**Fallback: `xcrun notarytool`**, chosen with `PANESHARE_NOTARY_TOOL=notarytool` plus
`PANESHARE_NOTARY_PROFILE=<profile>`. Create an app-specific password at account.apple.com → Sign-In and
Security → App-Specific Passwords, then store it in the keychain under a profile name. Leave out `--password`
so it's typed at the prompt rather than saved in your shell history:

```bash
xcrun notarytool store-credentials paneshare-notary \
  --apple-id "<your Apple ID email>" --team-id TV289JZ58M
xcrun notarytool history --keychain-profile paneshare-notary   # works = credentials are good
```

An App Store Connect API key works too:
`xcrun notarytool store-credentials paneshare-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>`.

### 1.3 Sparkle EdDSA keys

Sparkle's tools come with the SwiftPM package:

```bash
cd ~/src/paneshare            # your clone
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys        # creates the key in the login keychain, prints the public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p     # prints only the public key (release.sh does this)
```

Back up the private key once, encrypted and offline, then delete the exported file:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/paneshare-sparkle-key.txt
# store it in your password manager or an encrypted disk image, then:
rm -P ~/Desktop/paneshare-sparkle-key.txt
```

`generate_keys -f <file>` imports it on a new Mac. Every shipped build trusts this key: keep the same key for
every release.

### 1.4 Pick where the feed lives

See §3. The feed URL is baked into every build, so choose it before the first release.

## 2. Making a release

### The short way: one command

From a clean, committed checkout, with paneshare quit:

```bash
scripts/ship.sh 0.2.0
```

It runs `scripts/release.sh` (build, sign, notarize, staple, Dock self-test, signed appcast) with the feed at
`https://github.com/nexobe/paneshare/releases/latest/download/appcast.xml`, downloads under
`https://github.com/nexobe/paneshare/releases/download/v0.2.0/`, and the notes in `docs/release-notes/0.2.0.md`
if that file exists. Then it runs `scripts/publish.sh 0.2.0`, which checks the DMG and the appcast again and asks
you to type `publish 0.2.0`. After that it creates the GitHub Release `v0.2.0` on `nexobe/paneshare` at the
pushed `HEAD`, with the DMG, notes, deltas and `appcast.xml` attached and the SHA-256 in the body. Every key
stays on the release Mac. GitHub Actions only builds and tests (`.github/workflows/ci.yml`); it signs nothing.

If `asc` is a shell alias rather than a file on `PATH`, set `PANESHARE_ASC` to its path first.

The rest of this section is what those two scripts do, step by step.

### Building by hand

From a clean, committed checkout (the script refuses uncommitted changes):

```bash
cd ~/src/paneshare
git pull
export PANESHARE_FEED_URL="https://github.com/nexobe/paneshare/releases/latest/download/appcast.xml"
export PANESHARE_DOWNLOAD_URL_PREFIX="https://github.com/nexobe/paneshare/releases/download/v0.2.0/"
PANESHARE_FEED_MAX_VERSIONS=1 PANESHARE_VERSION=0.2.0 scripts/release.sh
```

That signs as "Developer ID Application: NEXOBE INC (TV289JZ58M)" and notarizes with `asc`. To notarize
with `notarytool` instead:

```bash
PANESHARE_NOTARY_TOOL=notarytool PANESHARE_NOTARY_PROFILE=paneshare-notary PANESHARE_VERSION=0.2.0 scripts/release.sh
```

Quit paneshare first: the last check launches a copy of the release (step 6 below). If macOS asks whether to
open "paneshare" downloaded from the Internet, click **Open**.

Optional: `PANESHARE_RELEASE_NOTES=notes/0.2.0.md` (Markdown, shown in the update dialog and signed with the
feed), `PANESHARE_BUILD_NUMBER` (default: commit count, which only grows on one branch),
`PANESHARE_DOWNLOAD_URL_PREFIX` (default: the feed's folder), `PANESHARE_FEED_MAX_VERSIONS` (versions kept in
the appcast; `ship.sh` sets 1), `PANESHARE_UPDATES_DIR` (default `build/updates`),
`PANESHARE_NOTARY_TIMEOUT` (default `30m`), and `PANESHARE_SKIP_DOCK_SELFTEST=1` (skips step 6).

What `scripts/release.sh` does, in order:

1. Checks the environment: macOS, a Developer ID Application identity of team `PANESHARE_TEAM_ID` that exists in
   the keychain, an `https://…/*.xml` feed URL, a numeric version, a clean tree, the notary tool (`asc` or
   `notarytool`), `stapler`, and Sparkle's tools.
   It reads the EdDSA public key with `generate_keys -p`.
2. Runs `scripts/make-app.sh release` with the signing identity, feed URL, public key, version and build number
   as build settings. That builds the app and the Dock helper template, writes `SUFeedURL`, `SUPublicEDKey`,
   `CFBundleShortVersionString` and `CFBundleVersion`, embeds `Sparkle.framework`, and signs inside out with
   `--options runtime --timestamp`. The order is Sparkle's `Installer.xpc`, `Downloader.xpc` (entitlements
   preserved), `Autoupdate`, `Updater.app`, the framework, then `Contents/Helpers/paneshare-dock-helper`, then the
   app with `paneshare.entitlements`. It never uses `--deep`.
3. Checks that each of those is Developer ID signed by team `PANESHARE_TEAM_ID`, with a timestamp and the hardened runtime, then runs
   `codesign --verify --deep --strict`.
4. Zips the app, notarizes it (`asc notarization submit … --wait`, or `xcrun notarytool submit … --wait`), staples it, and
   checks it with `xcrun stapler validate` and `spctl -a -vv -t exec` (expect `source=Notarized Developer ID`).
5. Builds `paneshare-<version>.dmg` with `scripts/dmg/make-dmg.sh`: the app and an `/Applications` link on a
   dark background with a "drag to Applications" arrow (`Resources/DMG/`, drawn by `scripts/dmg/background.py`),
   and the app icon as the volume icon. Finder writes the window layout, so the first run asks to let the
   terminal control Finder (Privacy & Security > Automation). Then it signs the DMG, notarizes it, staples it,
   and checks it with `stapler validate` and `spctl -a -vv -t open --context context:primary-signature`.
6. **Dock helper self-test** (§5): copies the DMG, marks the copy quarantined as a browser would, installs the
   app from it into a temporary folder (also marked quarantined), checks it with `spctl`, and launches it with
   `open -W -n … --args --dock-helper-selftest <file>`. That copy generates, ad hoc signs and launches one Dock
   helper the way a remote window does, and the release stops unless the helper connects over the verified link.
7. Copies the DMG (and notes) into `build/updates/` and runs Sparkle's `generate_appcast`. Because the app sets
   `SURequireSignedFeed`, that signs the archive, the appcast and the release notes with the Keychain's EdDSA
   key (allow the Keychain prompt). It checks the appcast lists the new DMG with a signature.

If notarization fails, the script prints the notary tool's JSON (and, with `notarytool`, the submission's log) and stops.

Then `scripts/publish.sh <version>` uploads the files the appcast points at, plus the appcast, as assets of the
GitHub Release, and puts the DMG's SHA-256 in the release body. Keep `build/updates/` for the next release:
`generate_appcast` uses the older DMGs in it to make delta updates. The SHA-256 goes in the release body, not the
Sparkle release notes: `generate_appcast` signs those notes, and editing them after that breaks the signature.
Users compare this value with the "Verify this build" box in the README.

## 3. Hosting the feed

Users' copies fetch the feed and the DMGs without credentials, so any static HTTPS host works. **The chosen host
is GitHub Release assets on `nexobe/paneshare`.** Each release `vX.Y.Z` carries the DMG, its notes, its deltas
and `appcast.xml`. The feed URL that every build has baked in is
`https://github.com/nexobe/paneshare/releases/latest/download/appcast.xml`; GitHub redirects it to the newest
release's asset over HTTPS, so it never changes. No GitHub Pages or Actions is involved.

Every file `generate_appcast` writes shares one download prefix, and each release has its own folder
(`releases/download/vX.Y.Z/`). So each appcast lists only its own version (`--maximum-versions 1`), plus delta
updates to it from the older DMGs kept in `build/updates`. Older copies still update: Sparkle offers them the one
version in the feed, using a delta when there is one. Limits: 2 GiB per asset, no bandwidth cap.

Whatever the host, it must be HTTPS: the app refuses a non-HTTPS feed, and Sparkle verifies the EdDSA signatures
of the feed and of each DMG before using them, so a compromised host can't push code or redirect users elsewhere.

To move hosts later, ship one release from the current host whose `PANESHARE_FEED_URL` is the new URL, and keep
the old feed up until users have updated.

**History:** 0.1.0 and 0.1.1 were built with the feed at `https://nexobe.github.io/paneshare-releases/appcast.xml`.
That repo was deleted when releases moved here, so those two versions can't find updates. Their users need to
download the next version by hand once.

## 4. What the app does about updates

- A build only updates if `make-app.sh` was given a feed URL and public key, and the `Info.plist` asks for a
  signed feed with archives verified before extraction. Otherwise the updater never starts and **Check for
  Updates…** is disabled (`UpdateConfiguration`). Local and CI builds are like this.
- **First launch** of an updatable build asks once: "Check for paneshare updates automatically?" (**Check
  Automatically** / **Don't Check**). Nothing is fetched before the answer. The choice is Sparkle's own
  `SUEnableAutomaticChecks` setting and can be changed with **paneshare → Check for Updates Automatically**.
- Automatic checks happen once a day (`SUScheduledCheckInterval` 86400). **Check for Updates…** in the app menu
  checks right away.
- Updates are never installed silently (`SUAllowsAutomaticUpdates` is off): Sparkle shows the version and
  notes, and installs only when the user chooses to. No system profile is sent (`SUEnableSystemProfiling` off).
  The request carries Sparkle's usual User-Agent (app and Sparkle versions).
- To test the schedule: `defaults delete dev.paneshare.app SULastCheckTime` and relaunch.

## 5. Dock helpers, Gatekeeper and notarization

The viewer generates one small helper app per remote app (ARCHITECTURE §6) and signs it **ad hoc at run time**,
in process. We checked whether that still works once paneshare itself is hardened, notarized and downloaded.

**Expected:** it does, with nothing more than defensive changes. A pre-signed template wouldn't work for
per-app tiles (see "Plan B" below).

**Verified so far:** on the release Mac, a hand-signed earlier development build (app and helper template with
`--options runtime --timestamp`, then a signed DMG) was notarized with `asc` (Accepted), stapled, and
`spctl` reported `accepted, source=Notarized Developer ID`.

**Not yet verified, the open risk:** that a *downloaded* copy on a **second Mac** still launches the helpers it
generates. That's the only setup where the app and its template are quarantined and Gatekeeper assesses paneshare
on first launch. Points 1–7 below are why it should work. The watchdog and self-test after them make sure a
failure is noticed and contained rather than leaving windows without a Dock tile.

1. **No quarantine, so no Gatekeeper assessment.** Gatekeeper checks code (signature, notarization ticket) at
   first launch when the file carries `com.apple.quarantine`. That attribute is added by the app that
   *downloads* a file (browsers, Mail, AirDrop) or by apps that opt in with `LSFileQuarantineEnabled`.
   paneshare doesn't opt in, and it writes every byte of a helper itself (`Data.write`: the template executable is
   read into memory, so no attributes are copied). So helpers carry no quarantine and Gatekeeper doesn't assess
   them. The DMG and the app *are* quarantined after download, and those are notarized and stapled. As a
   precaution, `DockHelperFactory` still removes `com.apple.quarantine` from every file of a staged helper
   before validating it.
2. **Notarization covers what we ship.** That's the app, Sparkle, and the helper *template* in
   `Contents/Helpers`, all Developer ID signed with the hardened runtime and a timestamp. Generated helpers are
   never distributed, so there's nothing to notarize.
3. **Execution still requires a valid signature.** Apple silicon refuses unsigned code, and an ad hoc
   signature satisfies it. Every generated helper passes `SecStaticCodeCheckValidity` (strict, against its
   exact cdhash) before it's moved into place or launched.
4. **The hardened runtime applies to paneshare's own process** (library validation, no `DYLD_*`, no debugger
   attach). It doesn't limit which programs paneshare writes or launches. Helpers are separate processes with
   their own signatures.
5. **The template's Developer ID signature is replaced, not edited.** `AdHocSigner` truncates the template at
   its `LC_CODE_SIGNATURE` data and writes a fresh ad hoc signature for the helper's identifier, `Info.plist` and
   icon. It handles one architecture per file, so `make-app.sh` fails the build if the template is universal.
   A release is built for the release Mac's architecture (Apple silicon).
6. **App Management (macOS 13+).** macOS can stop one app from modifying another app's bundle. When paneshare is
   Developer ID signed, each helper's `Info.plist` gets `NSUpdateSecurityPolicy` allowing only paneshare's Team
   ID and bundle ID to update it. This is untested so far: if macOS still shows a "paneshare was prevented from
   modifying apps" notice, allow paneshare under System Settings → Privacy & Security → App Management. If
   regenerating fails, the presenter falls back to the single Dock icon.
7. **Trust on the local link tightens with Developer ID.** The helper's `Info.plist` also records paneshare's
   Team ID (`PaneshareMainTeamID`), and the helper then accepts the link's server only if its running code (by
   audit token) satisfies `anchor apple generic and identifier "dev.paneshare.app" and certificate
   leaf[subject.OU] = "<TEAMID>"`, on top of the bundle-ID and parent-PID checks. The main app keeps pinning each
   helper by its exact cdhash. Ad hoc builds keep the earlier checks.

8. **Generated helpers don't use the hardened runtime.** The template is signed with it, but `AdHocSigner`
   writes a fresh CodeDirectory with only the ad hoc flag. So the runtime's library validation and
   launch-time checks can't reject a helper. The cost: a same-user process could start a helper with
   `DYLD_INSERT_LIBRARIES`. It would then pass the main app's cdhash check and see the menu (remote window
   titles), but no pixels, input or keys. Adding the runtime flag to ad hoc helpers is a follow-up, once the
   self-test below has passed on a second Mac with and without it.

**What happens if a helper is blocked anyway.** Either:
- `NSWorkspace` reports the launch failed; or
- the helper process is started and then killed (Gatekeeper refusal or a code signing kill), so it never connects.

Before, the second case left that app's windows with no Dock tile until they were closed. Now
`HelperDockPresenter` gives each launch 10 s to say hello on the link. Otherwise it terminates the helper, moves
its windows to paneshare's own Dock tile (the single-tile mode), and logs:

```
paneshare: Dock helper … launched but didn't connect within 10 s (stopped by Gatekeeper or code signing?)
```

After two silent helpers in a session, every app uses the single tile until paneshare is relaunched, so the user
isn't hit by a series of refusals. Remote windows always open.

**Self-test: `--dock-helper-selftest`.** It runs before any window, discovery or update prompt, and needs no
host. It generates one helper exactly as a remote window would, launches it, waits up to 20 s for it to connect
and pass the link's code signature check, then quits and deletes it. It writes a short report whose last line
is `dock-helper-selftest: PASS` or `… FAIL <reason>`. The report also says whether the app and the helper
carry quarantine, and gives the team ID and the helper's cdhash. `release.sh` step 6 runs it on a quarantined
install of every release. On a second Mac:

```bash
# 1. Get the DMG there the way users will (download it in Safari, or AirDrop it): both add quarantine.
xattr -p com.apple.quarantine ~/Downloads/paneshare-0.2.0.dmg        # must print a value
# 2. Open the DMG, drag paneshare to Applications, open it once from Finder (click Open), then quit it.
# 3. Self-test through LaunchServices, as a real launch:
open -W -n /Applications/paneshare.app --args --dock-helper-selftest /tmp/paneshare-dock-selftest.txt
cat /tmp/paneshare-dock-selftest.txt                                 # last line: PASS
# 4. Then for real: pair, open a remote window, check its Dock tile (TESTING §4.10 U13–U16).
log show --last 10m --style compact --predicate 'process == "syspolicyd" OR eventMessage CONTAINS "paneshare-dock-helper"'
```

If it fails, the log line above shows whether Gatekeeper (`syspolicyd`) or the kernel refused the helper. Send
the self-test report and that log output. The fallback keeps paneshare usable meanwhile.

**Residual risk.** macOS 13+ also tags files created by apps with `com.apple.provenance`. That isn't
quarantine and doesn't trigger Gatekeeper today. If a future macOS assessed unquarantined ad hoc apps, the
self-test would fail at release time, and installed copies would fall back to the single Dock tile as
described above. Plan B below would then be the starting point.

**Plan B (designed, not built): a pre-signed template app.** A Developer ID signed, notarized
`paneshare Helper.app` would ship inside paneshare.app and be copied unchanged per remote app. Its signature seals
`Info.plist` and `Resources/`, so the per-app parts that show up in the Dock and Command-Tab can't change
without invalidating it. Those parts are `CFBundleName`, `CFBundleIdentifier` (one tile per bundle ID) and
the icon file. What stays possible: the running helper sets its Dock icon at run time
(`NSApp.applicationIconImage`), and per-app data goes in launch arguments. But every copy would share one
bundle ID and name, which defeats a separate tile and Command-Tab entry per remote app. Plan B is therefore
only a fallback if ad hoc helpers stop launching. As far as we know, Chromium's installed-web-app shims are
generated and ad hoc signed on the user's Mac in the same way.

## 6. Checking a release by hand

```bash
codesign -dv --verbose=4 build/app.noindex/paneshare.app 2>&1 | grep -E "Authority|Timestamp|flags"
spctl -a -vv -t exec build/app.noindex/paneshare.app                      # accepted, source=Notarized Developer ID
xcrun stapler validate build/updates/paneshare-0.2.0.dmg
xattr -l ~/Library/Application\ Support/paneshare/DockHelpers/*/*/*.app   # no com.apple.quarantine
open -W -n build/app.noindex/paneshare.app --args --dock-helper-selftest /tmp/dock.txt && tail -1 /tmp/dock.txt   # PASS
```

The manual test list is TESTING §4.10.

## 7. Troubleshooting

- **`errSecInternalComponent` while signing** (often over SSH): the login keychain is locked. Run
  `security unlock-keychain ~/Library/Keychains/login.keychain-db` and retry.
- **Notarization "Invalid":** the script prints the notary log. Common causes are a nested binary without the
  hardened runtime or timestamp, or a `get-task-allow` entitlement. Re-run after fixing; nothing is published
  on failure.
- **`asc` returns something other than Accepted, or no status:** the script prints `asc`'s JSON as is. It reads
  `status` at the top level or at `data.attributes.status`. If a newer `asc` reports it elsewhere, use
  `PANESHARE_NOTARY_TOOL=notarytool` meanwhile.
- **Dock helper self-test fails:** see §5. Nothing is copied to `build/updates/`. The stapled app stays in `build/`,
  and the DMG is deleted with the script's temporary folder.
- **Several "paneshare" apps in Spotlight or Launchpad:** build copies registered with LaunchServices, for example
  an old `build/paneshare.app` or a hand-made `build/release/paneshare.app`. `scripts/make-app.sh unregister`
  drops every bundle under `build/`. Both scripts already keep their own bundles out: `build/` gets
  `.metadata_never_index`, bundles live only in `*.noindex` folders, and `release.sh` unregisters its build, DMG
  staging, mounted and translocated self-test copies when it exits. A stale registration matters beyond the
  menu: a pinned Dock helper and Sparkle look paneshare up by bundle ID and could pick the build copy.
- **"No Sparkle EdDSA key in the Keychain":** run `generate_keys` (§1.3) or import your backup with `-f`.
- **Users don't get the update:** `CFBundleVersion` must be higher than theirs (the default build number is the
  commit count, so release from the same branch), and the uploaded `appcast.xml` must be the freshly signed
  one. Editing the appcast after `generate_appcast` breaks its signature, and Sparkle then ignores it.
