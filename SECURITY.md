# Security policy

paneshare streams windows and forwards input between Macs, so we treat security reports as urgent.

## Report a problem

Do not open a public issue. Use GitHub's private vulnerability reporting instead:
**Security → Report a vulnerability** on this repository, or go straight to
<https://github.com/nexobe/paneshare/security/advisories/new>.

Include the paneshare version, the macOS versions on both Macs, the steps to reproduce, and what an
attacker can do. We reply within 3 working days and keep you informed until a fix ships.

## Disclosure

We follow coordinated disclosure. After we confirm a report, we aim to ship a fix within 90 days, then
publish a GitHub security advisory that credits you, unless you ask us not to. If a problem is being
exploited, we move faster and tell you the plan. Please give us that time before you publish details.

## Supported versions

Only the latest release gets security fixes. Installed copies update through Sparkle, which accepts only
updates signed with the project's EdDSA key and the NEXOBE INC Developer ID.

## Scope

The threat model is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and the "Security model" section of
the README. In scope: pairing, the encrypted session, input forwarding, share links, Dock helpers and the
updater. Out of scope: a Mac that is already compromised, and people you chose to pair with or send a link to.
