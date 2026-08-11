import Foundation

extension MirrorTransaction {
  func stage(
    source: URL,
    manifest: SourceManifest,
    at destination: URL,
    sourceMayBeUnavailable: Bool
  ) throws {
    do {
      try fileSystem.createDirectory(at: destination)
      try createDirectories(manifest.entries, at: destination)
      for entry in manifest.entries where entry.kind != .directory {
        try copyEntry(entry, from: source, to: destination)
      }
    } catch let failure as SyncFailure {
      throw failure
    } catch {
      throw sourceMayBeUnavailable ? SyncFailure.sourceUnavailable : error
    }
  }

  func stageArchive(from current: URL, entries: [ManifestEntry], at destination: URL) throws {
    guard !entries.isEmpty else { return }
    try stage(
      source: current,
      manifest: SourceManifest(entries: entries),
      at: destination,
      sourceMayBeUnavailable: false
    )
  }

  func createDirectories(_ entries: [ManifestEntry], at root: URL) throws {
    let directories = entries.filter { $0.kind == .directory }.sorted {
      $0.relativePath.count < $1.relativePath.count
    }
    for entry in directories {
      try fileSystem.createDirectory(at: root.appending(path: entry.relativePath))
    }
  }

  func copyEntry(_ entry: ManifestEntry, from sourceRoot: URL, to destinationRoot: URL) throws {
    let source = sourceRoot.appending(path: entry.relativePath)
    let destination = destinationRoot.appending(path: entry.relativePath)
    try fileSystem.createDirectory(at: destination.deletingLastPathComponent())
    if entry.kind == .symbolicLink {
      try fileSystem.createSymbolicLink(at: destination, target: entry.symbolicLinkTarget ?? "")
    } else {
      try fileAccess.copy(from: source, to: destination)
    }
  }

  func verify(_ destination: URL, matches expected: SourceManifest) throws {
    let actual = try destinationManifest(at: destination)
    guard actual.hasSameContent(as: expected) else { throw SyncFailure.verificationFailed }
  }

  func verifyArchive(_ archive: URL, entries: [ManifestEntry]) throws {
    guard !entries.isEmpty else { return }
    let actual = try destinationManifest(at: archive).byPath
    for entry in entries {
      guard actual[entry.relativePath]?.contentIdentity == entry.contentIdentity else {
        throw SyncFailure.verificationFailed
      }
    }
  }
}
