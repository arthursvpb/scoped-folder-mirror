# Release Verification

Use a disposable destination folder or APFS disk image. Never use existing backup data.

Record:

- Source, current mirror, and archive SHA-256 manifests using redacted labels.
- Initial copy, replacement, removal, hidden file, nested path, and symlink results.
- No-space, source-mutation, staged-hash, archive, swap, and rollback failure results.
- The unencrypted-volume warning and explicit acceptance behavior.
- Ejection only after a verified transaction, targeting the containing external volume.
- The mounted DMG app architecture, strict code-sign result, entitlements, checksum, raw artifact-string scan, and absence of coverage instrumentation.

Unsigned preview verification does not satisfy the stable-release signing and notarization gate.
