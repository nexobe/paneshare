# paneshare

Share one macOS window between Macs as a native window. Open source (MIT, six files Apache-2.0), by NEXOBE.

Read `.clinerules` first. It holds the non-negotiables, code patterns and lessons. `README.md` covers the product and
the security model. `docs/TESTING.md` is the manual test plan. `docs/RELEASING.md` covers releases.

## Commands

```bash
swift test                  # core unit tests
scripts/make-app.sh         # builds build/app.noindex/paneshare.app, ad hoc signed
open build/app.noindex/paneshare.app
scripts/release.sh          # signed, notarized DMG. See docs/RELEASING.md first.
```

Use the app bundle for anything that touches permissions, not the Xcode scheme. The Xcode scheme makes macOS
attribute grants to a binary in DerivedData.

The syntax-only check in `.clinerules` is for machines without a Mac. On a Mac, build for real.

## Permissions

- Code: `Sources/PaneshareInput/Permissions.swift`, `Sources/PaneshareApp/Views/OnboardingView.swift`. `AppModel`
  polls both permissions once per second.
- macOS ties grants to the code signature. An ad hoc signature changes on each rebuild, so an old grant can stop
  applying. A Developer ID build keeps its grant across rebuilds.
- Screen Recording and Accessibility grants for `dev.paneshare.app` are shared by every copy with a matching
  signature. Reset them with `tccutil reset ScreenCapture dev.paneshare.app` and
  `tccutil reset Accessibility dev.paneshare.app`.
- On macOS 27.2, `CGRequestScreenCaptureAccess` and `SCShareableContent` did not add test apps to the Screen
  Recording list. The apps were ad hoc signed. `SCShareableContent` failed at once with -3801. Two onboarding clicks
  in the notarized build added no row either. Users add the app with the + button, and the row then appears.
- Do not grant permissions for the user. The toggles are theirs to set.

## Docs rule

Never name the reference product in code, UI, docs or commit messages.
