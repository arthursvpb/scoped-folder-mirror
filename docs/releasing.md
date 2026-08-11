# Releasing

## Unsigned Preview

1. Run `make verify` on a clean checkout.
2. Push a tag matching `v*-preview.*`.
3. Confirm both architecture jobs built and verified their DMGs.
4. Confirm the GitHub release is a prerelease and its notes begin with `UNSIGNED PREVIEW`.
5. Confirm `SHA256SUMS` covers both architecture-specific artifacts.

Unsigned previews must tell users that Gatekeeper has not verified the publisher. Support only Finder's Open and macOS Open Anyway flows. Never instruct users to disable Gatekeeper globally.

## Future Stable Release

Join the [Apple Developer Program](https://developer.apple.com/programs/), create and protect a Developer ID Application certificate, and configure protected GitHub environments for signing and notarization credentials. Certificate exports, passwords, API keys, and provisioning files must never enter the repository.

A stable artifact must use Hardened Runtime, secure timestamping, Developer ID signing, Apple notarization, and stapling. Verify it with `codesign --verify --deep --strict`, `spctl --assess`, `xcrun stapler validate`, a DMG mount test, architecture inspection, and checksum verification before publishing it as stable.

## Public Repository Controls

Immediately after changing repository visibility, enable private vulnerability reporting, Dependabot alerts, secret scanning, push protection, and code scanning. Require full commit SHA references for Actions and protect `main` with both architecture checks before announcing the repository.
