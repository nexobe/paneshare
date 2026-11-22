# Contributing to paneshare

Thanks for helping. Read this before you open a pull request.

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

- **Clean room.** Do not copy code, text or assets from any other window-sharing product, and do not
  decompile or inspect one. Design from public behaviour and Apple's public APIs. The project's own spec,
  [`docs/SPEC.md`](docs/SPEC.md), came from a separate analyst's study of one public build; see
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
