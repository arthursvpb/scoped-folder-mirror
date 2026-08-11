import Foundation

protocol FreeSpaceReading: Sendable {
  func availableBytes(at url: URL) -> Int64?
}

protocol MirrorExecuting: Sendable {
  func execute(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt
}

protocol MirrorFileManaging: Sendable {
  func fileExists(at url: URL) -> Bool
  func createDirectory(at url: URL) throws
  func createSymbolicLink(at url: URL, target: String) throws
  func moveItem(at source: URL, to destination: URL) throws
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

}

struct SystemFreeSpaceReader: FreeSpaceReading {
  func availableBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}

struct MirrorTransaction: MirrorExecuting, Sendable {
  private let snapshotBuilder: any SourceSnapshotBuilding
  let fileAccess: any CoordinatedFileAccessing
  private let freeSpace: any FreeSpaceReading
  private let destinationCoordinator: any DestinationCoordinating
  let fileSystem: any MirrorFileManaging
  private let stateStore: TransactionStateStore
  private let recovery: TransactionRecovery
  private let faultInjector: any TransactionFaultInjecting
  private let metadataReserve: Int64 = 16 * 1_024 * 1_024

  init(
    snapshotBuilder: any SourceSnapshotBuilding = SourceManifestBuilder(),
    fileAccess: any CoordinatedFileAccessing = SystemCoordinatedFileAccess(),
    freeSpace: any FreeSpaceReading = SystemFreeSpaceReader(),
    destinationCoordinator: any DestinationCoordinating = SystemDestinationCoordinator(),
    fileSystem: any MirrorFileManaging = SystemMirrorFileManager(),
    faultInjector: any TransactionFaultInjecting = NoTransactionFaults()
  ) {
    self.snapshotBuilder = snapshotBuilder
    self.fileAccess = fileAccess
    self.freeSpace = freeSpace
    self.destinationCoordinator = destinationCoordinator
    self.fileSystem = fileSystem
    stateStore = TransactionStateStore()
    recovery = TransactionRecovery(fileSystem: fileSystem)
    self.faultInjector = faultInjector
  }

  func execute(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt {
    var result: Result<MirrorReceipt, Error> = .failure(SyncFailure.unexpected)
    try destinationCoordinator.coordinateWrite(at: destination) { coordinatedDestination in
      result = Result {
        try executeCoordinated(
          source: source,
          destination: coordinatedDestination,
          sourceManifest: sourceManifest,
          runName: runName,
          mirrorID: mirrorID
        )
      }
    }
    return try result.get()
  }

  private func executeCoordinated(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt {
    try recovery.recoverAll(at: destination, mirrorID: mirrorID)
    let layout = try TransactionLayout(destination: destination, runName: runName)
    let currentManifest = try manifestIfPresent(at: layout.current)
    let displaced = displacedEntries(current: currentManifest, next: sourceManifest)
    try preflight(destination, next: sourceManifest, displaced: displaced)
    var state = TransactionState(
      runName: runName,
      hadCurrent: fileSystem.fileExists(at: layout.current),
      archiveExpected: !displaced.isEmpty
    )
    try stateStore.save(state, layout: layout)
    do {
      try buildVerifiedStaging(source, sourceManifest, displaced, layout, state: &state)
      try commit(layout, expected: sourceManifest, state: &state)
      return MirrorReceipt(
        fileCount: sourceManifest.regularFileCount,
        byteCount: sourceManifest.byteCount,
        archiveCreated: !displaced.isEmpty
      )
    } catch let interruption as any TransactionInterruption {
      throw interruption
    } catch {
      try recovery.handleFailure(state, destination: destination)
      throw error
    }
  }

  private func buildVerifiedStaging(
    _ source: URL,
    _ sourceManifest: SourceManifest,
    _ displaced: [ManifestEntry],
    _ layout: TransactionLayout,
    state: inout TransactionState
  ) throws {
    try stage(
      source: source, manifest: sourceManifest, at: layout.next, sourceMayBeUnavailable: true)
    try faultInjector.hit(.afterStagingCreated)
    try verify(layout.next, matches: sourceManifest)
    try advance(&state, to: .stagedVerified, layout: layout)
    try faultInjector.hit(.afterStagedVerified)
    try advance(&state, to: .archiveStaging, layout: layout)
    try stageArchive(from: layout.current, entries: displaced, at: layout.pendingArchive)
    try faultInjector.hit(.afterPendingArchiveCreated)
    try verifyArchive(layout.pendingArchive, entries: displaced)
    try advance(&state, to: .archiveVerified, layout: layout)
    try faultInjector.hit(.afterPendingArchiveVerified)
  }

  private func commit(
    _ layout: TransactionLayout,
    expected: SourceManifest,
    state: inout TransactionState
  ) throws {
    try advance(&state, to: .rollbackMovePrepared, layout: layout)
    if state.hadCurrent {
      try fileSystem.createDirectory(at: layout.rollbackRuns)
      try fileSystem.moveItem(at: layout.current, to: layout.rollback)
    }
    try faultInjector.hit(.afterCurrentMovedToRollback)
    try advance(&state, to: .rollbackReady, layout: layout)
    try fileSystem.moveItem(at: layout.next, to: layout.current)
    try faultInjector.hit(.afterNextPromoted)
    try advance(&state, to: .currentPromoted, layout: layout)
    try verify(layout.current, matches: expected)
    try faultInjector.hit(.afterCurrentVerified)
    try advance(&state, to: .currentVerified, layout: layout)
    try promoteArchive(layout, state: &state)
    try finishCleanup(layout, state: &state)
  }

  private func promoteArchive(_ layout: TransactionLayout, state: inout TransactionState) throws {
    try advance(&state, to: .archivePromotionPrepared, layout: layout)
    if state.archiveExpected {
      try fileSystem.createDirectory(at: layout.archives)
      try fileSystem.moveItem(at: layout.pendingArchive, to: layout.archiveRun)
    }
    try advance(&state, to: .archivePromoted, layout: layout)
    try faultInjector.hit(.afterArchivePromoted)
  }

  private func finishCleanup(_ layout: TransactionLayout, state: inout TransactionState) throws {
    if state.hadCurrent {
      try advance(&state, to: .rollbackCleanupPrepared, layout: layout)
      try fileSystem.createDirectory(at: layout.cleanupRuns)
      try fileSystem.moveItem(at: layout.rollback, to: layout.cleanup)
      try faultInjector.hit(.afterRollbackRenamedForCleanup)
    }
    try advance(&state, to: .cleanupReady, layout: layout)
    try faultInjector.hit(.duringCleanupDeletion)
    try SafeFileTree().removeTree(layout.cleanup, inside: layout.cleanupRuns)
    try SafeFileTree().removeTree(layout.stagingRoot, inside: layout.stagingRuns)
    try stateStore.remove(layout)
  }

  private func advance(
    _ state: inout TransactionState,
    to phase: TransactionPhase,
    layout: TransactionLayout
  ) throws {
    state.phase = phase
    try stateStore.save(state, layout: layout)
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

  private func manifestIfPresent(at root: URL) throws -> SourceManifest {
    guard fileSystem.fileExists(at: root) else { return SourceManifest(entries: []) }
    return try destinationManifest(at: root)
  }

  func destinationManifest(at root: URL) throws -> SourceManifest {
    do {
      return try snapshotBuilder.build(at: root)
    } catch SyncFailure.sourceUnavailable {
      throw SyncFailure.verificationFailed
    }
  }
}

enum RunName {
  static func make(date: Date = .now, id: UUID = UUID()) -> String {
    let timestamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(
      of: ":", with: "-")
    return timestamp + "-" + id.uuidString.lowercased()
  }
}
