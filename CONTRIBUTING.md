# Contributing to paneshare

Thanks for helping! Contributions of every size are welcome: a bug report with both Macs' details, a test
run of [`docs/TESTING.md`](docs/TESTING.md) on your own two Macs, a docs fix, or code.

**Where to start:** issues labelled
[good first issue](https://github.com/nexobe/paneshare/labels/good%20first%20issue) or
[help wanted](https://github.com/nexobe/paneshare/labels/help%20wanted). For a bigger change, open an issue or
a [discussion](https://github.com/nexobe/paneshare/discussions) first, so we can agree on the approach before
you spend time on it.

**How a pull request goes:** fork the repo, make a branch, and open a pull request against `main`. A maintainer
approves the checks for first-time contributors. The build, the unit tests, CodeQL and a dependency review
must pass, and a maintainer reviews the change. `main` takes changes only through pull requests.

Read the rest of this page before you open a pull request.

## Build and test

You need macOS 14 or later and Xcode with the Swift 6 toolchain.

```bash
swift build
swift test                  # core unit tests
scripts/make-app.sh         # builds build/app.noindex/paneshare.app, ad hoc signed
```

Test anything that touches permissions with the app bundle, not the Xcode scheme. The manual test plan is
[`docs/TESTING.md`](docs/TESTING.md).

## Rules

- **No copying.** Do not copy code, text or assets from any other window-sharing product, and do not
  decompile or inspect one. Design from public behaviour and Apple's public APIs. The project's own spec,
  [`docs/SPEC.md`](docs/SPEC.md), came from a study of how an existing app behaves; see
  ["How this started"](README.md#how-this-started). That work is done, and contributors don't repeat it.
- **Licenses.** Only MIT, BSD or Apache-2.0 code may be reused. Record every reuse in
  [`THIRD_PARTY.md`](THIRD_PARTY.md) and put an attribution header on derived files.
- **No new private APIs.** `CGVirtualDisplay` is the only one, behind an off-by-default setting.
- **In the app:** no shell commands, TLS pinning always on, and no listener while sharing is off.
- Work on a branch and open a pull request against `main`. Keep each pull request to one change.

## License of contributions

By contributing, you agree that your contribution is licensed under the project's [MIT License](LICENSE).

## Security

Report vulnerabilities privately. See [`SECURITY.md`](SECURITY.md).
