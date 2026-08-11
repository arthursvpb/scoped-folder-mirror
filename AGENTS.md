# Contributor Instructions

## Structure

- `ScopedFolderMirror/App`: app entry point.
- `ScopedFolderMirror/Features`: menu UI and retained picker controller.
- `ScopedFolderMirror/Domain`: manifests, stability, coordination, and transaction logic.
- `ScopedFolderMirror/Infrastructure`: bookmarks, volumes, login item, and persistence.
- `ScopedFolderMirrorTests`: unit and transaction tests with named fakes.
- `ScopedFolderMirrorUITests`: picker and menu behavior tests.
- `Configuration`: the reviewed entitlement allowlist.
- `scripts`: build, package, and release verification.

## Commands

```sh
make test
make lint
make build
make package-preview VERSION=0.1.0-preview.1 ARCH=arm64
make verify
```

Regenerate `ScopedFolderMirror.xcodeproj` with `xcodegen generate` after editing `project.yml`.

## Code Rules

- Prefer files below 300 lines and functions near 20 lines.
- Use explicit domain types at filesystem, bookmark, volume, and persistence boundaries.
- Name test fakes by role. Do not hide behavior in inline stubs.
- Keep control flow visible and dependencies directed toward protocols.
- Add source comments only for a non-obvious WHY that naming and structure cannot express.
- Do not add speculative layers, generic utility buckets, or application-specific exclusions.
- Preserve hidden files and symlinks. Reject unsupported special files visibly.

## Security Invariants

- Source bookmarks are read-only. Destination bookmarks cover one dedicated folder and are read-write.
- Never request network, automation, Full Disk Access, helper, or shell authority.
- Reject roots, overlap, recursion, wrong volumes, internal volumes, and read-only volumes before mutation.
- Persist no paths, folder labels, raw errors, file contents, bookmark bytes, or volume identifiers in activity records.
- Verify staging and archives before swap. Restore rollback on commit failure. Eject only after verification.
- Never delete completed archives automatically.

## Release Checks

- Run tests on arm64 and Intel macOS runners.
- Run swift-format, gitleaks, entitlement allowlist, helper/shell denylist, architecture, signing, DMG mount, checksum, and artifact-string checks.
- Pin third-party Actions to full commit SHAs.
- Publish unsigned artifacts only as prereleases labeled `UNSIGNED PREVIEW`.
- Stable releases require Developer ID signing, Hardened Runtime, timestamping, notarization, and stapling.
