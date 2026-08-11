import Foundation

private struct MirrorLayout {
  let destination: URL
  let runName: String

  var current: URL { destination.appending(path: "Current Mirror", directoryHint: .isDirectory) }
  var archives: URL { destination.appending(path: "Archive", directoryHint: .isDirectory) }
  var archiveRun: URL { archives.appending(path: runName, directoryHint: .isDirectory) }
  var stagingRoot: URL {
    destination.appending(path: ".staging/\(runName)", directoryHint: .isDirectory)
  }
  var next: URL { stagingRoot.appending(path: "next", directoryHint: .isDirectory) }
  var pendingArchive: URL { stagingRoot.appending(path: "archive", directoryHint: .isDirectory) }
  var rollback: URL { destination.appending(path: ".rollback", directoryHint: .isDirectory) }
}

protocol FreeSpaceReading: Sendable {
  func availableBytes(at url: URL) -> Int64?
}

protocol MirrorExecuting: Sendable {
  func execute(source: URL, destination: URL, sourceManifest: SourceManifest, runName: String)
    throws -> MirrorReceipt
}

protocol MirrorFileManaging: Sendable {
  func fileExists(at url: URL) -> Bool
  func createDirectory(at url: URL) throws
  func createSymbolicLink(at url: URL, target: String) throws
  func moveItem(at source: URL, to destination: URL) throws
  func removeItem(at url: URL) throws
}

struct SystemMirrorFileManager: MirrorFileManaging {
  private var fileManager: FileManager { .default }

  func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

  func createDirectory(at url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func createSymbolicLink(at url: URL, target: String) throws {
    try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
  }

  func moveItem(at source: URL, to destination: URL) throws {
    try fileManager.moveItem(at: source, to: destination)
  }

  func removeItem(at url: URL) throws { try fileManager.removeItem(at: url) }
}

struct SystemFreeSpaceReader: FreeSpaceReading {
  func availableBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}

struct MirrorTransaction: MirrorExecuting, Sendable {
  private let snapshotBuilder: any SourceSnapshotBuilding
  private let fileAccess: any CoordinatedFileAccessing
  private let freeSpace: any FreeSpaceReading
  private let destinationCoordinator: any DestinationCoordinating
  private let fileSystem: any MirrorFileManaging
  private let metadataReserve: Int64 = 16 * 1_024 * 1_024

  init(
    snapshotBuilder: any SourceSnapshotBuilding = SourceManifestBuilder(),
    fileAccess: any CoordinatedFileAccessing = SystemCoordinatedFileAccess(),
    freeSpace: any FreeSpaceReading = SystemFreeSpaceReader(),
    destinationCoordinator: any DestinationCoordinating = SystemDestinationCoordinator(),
    fileSystem: any MirrorFileManaging = SystemMirrorFileManager()
  ) {
    self.snapshotBuilder = snapshotBuilder
    self.fileAccess = fileAccess
    self.freeSpace = freeSpace
    self.destinationCoordinator = destinationCoordinator
    self.fileSystem = fileSystem
  }

  func execute(source: URL, destination: URL, sourceManifest: SourceManifest, runName: String)
    throws -> MirrorReceipt
  {
    var transactionResult: Result<MirrorReceipt, Error> = .failure(SyncFailure.unexpected)
    try destinationCoordinator.coordinateWrite(at: destination) { coordinatedDestination in
      transactionResult = Result {
        try executeCoordinated(
          source: source,
          destination: coordinatedDestination,
          sourceManifest: sourceManifest,
          runName: runName
        )
      }
    }
    return try transactionResult.get()
  }

  private func executeCoordinated(
    source: URL, destination: URL, sourceManifest: SourceManifest, runName: String
  ) throws -> MirrorReceipt {
    let layout = MirrorLayout(destination: destination, runName: runName)
    try recoverRollback(layout)
    let currentManifest = try snapshotBuilder.build(at: layout.current)
    let displaced = displacedEntries(current: currentManifest, next: sourceManifest)
    try preflight(destination, next: sourceManifest, displaced: displaced)
    try stage(source: source, manifest: sourceManifest, at: layout.next)
    try verify(layout.next, matches: sourceManifest)
    try stageArchive(from: layout.current, entries: displaced, at: layout.pendingArchive)
    try verifyArchive(layout.pendingArchive, entries: displaced)
    try commit(layout, expected: sourceManifest)
    return MirrorReceipt(
      fileCount: sourceManifest.regularFileCount,
      byteCount: sourceManifest.byteCount,
      archiveCreated: !displaced.isEmpty
    )
  }

  private func displacedEntries(current: SourceManifest, next: SourceManifest) -> [ManifestEntry] {
    let nextByPath = next.byPath
    return current.entries.filter {
      nextByPath[$0.relativePath]?.contentIdentity != $0.contentIdentity
    }
  }

  private func preflight(_ destination: URL, next: SourceManifest, displaced: [ManifestEntry])
    throws
  {
    guard let available = freeSpace.availableBytes(at: destination) else { return }
    let archiveBytes = displaced.reduce(Int64(0)) { $0 + $1.allocatedByteCount }
    guard available >= next.allocatedByteCount + archiveBytes + metadataReserve else {
      throw SyncFailure.insufficientSpace
    }
  }

  private func stage(source: URL, manifest: SourceManifest, at destination: URL) throws {
    try fileSystem.createDirectory(at: destination)
    try createDirectories(manifest.entries, at: destination)
    for entry in manifest.entries where entry.kind != .directory {
      try copyEntry(entry, from: source, to: destination)
    }
  }

  private func stageArchive(from current: URL, entries: [ManifestEntry], at destination: URL) throws
  {
    guard !entries.isEmpty else { return }
    try fileSystem.createDirectory(at: destination)
    try createDirectories(entries.filter { $0.kind == .directory }, at: destination)
    for entry in entries where entry.kind != .directory {
      try copyEntry(entry, from: current, to: destination)
    }
  }

  private func createDirectories(_ entries: [ManifestEntry], at root: URL) throws {
    let directories = entries.filter { $0.kind == .directory }.sorted {
      $0.relativePath.count < $1.relativePath.count
    }
    for entry in directories {
      try fileSystem.createDirectory(at: root.appending(path: entry.relativePath))
    }
  }

  private func copyEntry(_ entry: ManifestEntry, from sourceRoot: URL, to destinationRoot: URL)
    throws
  {
    let source = sourceRoot.appending(path: entry.relativePath)
    let destination = destinationRoot.appending(path: entry.relativePath)
    try fileSystem.createDirectory(at: destination.deletingLastPathComponent())
    if entry.kind == .symbolicLink {
      try fileSystem.createSymbolicLink(at: destination, target: entry.symbolicLinkTarget ?? "")
    } else {
      try fileAccess.copy(from: source, to: destination)
    }
  }

  private func verify(_ destination: URL, matches expected: SourceManifest) throws {
    let actual = try snapshotBuilder.build(at: destination)
    guard actual.hasSameContent(as: expected) else { throw SyncFailure.verificationFailed }
  }

  private func verifyArchive(_ archive: URL, entries: [ManifestEntry]) throws {
    guard !entries.isEmpty else { return }
    let actual = try snapshotBuilder.build(at: archive).byPath
    for entry in entries {
      guard actual[entry.relativePath]?.contentIdentity == entry.contentIdentity else {
        throw SyncFailure.verificationFailed
      }
    }
  }

  private func commit(_ layout: MirrorLayout, expected: SourceManifest) throws {
    let hadCurrent = fileSystem.fileExists(at: layout.current)
    if hadCurrent { try fileSystem.moveItem(at: layout.current, to: layout.rollback) }
    do {
      try fileSystem.moveItem(at: layout.next, to: layout.current)
      try verify(layout.current, matches: expected)
      try promoteArchive(layout)
      if hadCurrent { try fileSystem.removeItem(at: layout.rollback) }
      try? fileSystem.removeItem(at: layout.stagingRoot)
    } catch {
      try restore(layout, hadCurrent: hadCurrent)
      throw error
    }
  }

  private func promoteArchive(_ layout: MirrorLayout) throws {
    guard fileSystem.fileExists(at: layout.pendingArchive) else { return }
    try fileSystem.createDirectory(at: layout.archives)
    try fileSystem.moveItem(at: layout.pendingArchive, to: layout.archiveRun)
  }

  private func restore(_ layout: MirrorLayout, hadCurrent: Bool) throws {
    if fileSystem.fileExists(at: layout.current) {
      try fileSystem.removeItem(at: layout.current)
    }
    if hadCurrent, fileSystem.fileExists(at: layout.rollback) {
      try fileSystem.moveItem(at: layout.rollback, to: layout.current)
    }
  }

  private func recoverRollback(_ layout: MirrorLayout) throws {
    guard fileSystem.fileExists(at: layout.rollback) else { return }
    if fileSystem.fileExists(at: layout.current) {
      try fileSystem.removeItem(at: layout.current)
    }
    try fileSystem.moveItem(at: layout.rollback, to: layout.current)
  }
}

enum RunName {
  static func make(date: Date = .now, id: UUID = UUID()) -> String {
    let timestamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(
      of: ":", with: "-")
    return timestamp + "-" + id.uuidString.lowercased()
  }
}
