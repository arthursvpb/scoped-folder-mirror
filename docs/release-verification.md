# Release Verification

Use a disposable destination folder or APFS disk image. Never use existing backup data.

Record:

- Source, current mirror, and archive SHA-256 manifests using redacted labels.
- Initial copy, replacement, removal, hidden file, nested path, and symlink results.
- No-space, source-mutation, staged-hash, archive, swap, and rollback failure results.
- A missing or temporarily unavailable source leaving the current mirror and archives unchanged.
- Abandoned staging cleanup and reconnection after interrupted rollback cleanup.
- The unencrypted-volume warning and explicit acceptance behavior.
- Ejection enabled, disabled, and failed. Ejection must be attempted only after a verified transaction and must target the containing external volume.
- The mounted DMG app architecture, strict code-sign result, entitlements, checksum, raw artifact-string scan, and absence of coverage instrumentation.

Run these interruption scenarios against disposable data:

1. Unplug the destination during staging, reconnect it, and confirm recovery selects only a complete old or new mirror.
2. Terminate the app after each state boundary: staged mirror verification, pending archive verification, current-to-rollback rename, next-mirror promotion, final-current verification, archive promotion, and rollback-to-cleanup rename.
3. Terminate or disconnect during cleanup deletion, reconnect, and confirm partial cleanup is discarded rather than restored.
4. Make the source temporarily unavailable and confirm the mirror, archives, and ejection state do not change.
5. Sync with ejection enabled and confirm the containing volume ejects only after verification.
6. Sync with ejection disabled and confirm the volume remains mounted without an ejection warning.
7. Cause ejection to fail after a verified sync and confirm the result is success with a manual-ejection warning.

For every interruption, record both the recovered manifest and a successful subsequent synchronization. Recovery testing remains required even when the automated fault matrix passes.

Unsigned preview verification does not satisfy the stable-release signing and notarization gate.
