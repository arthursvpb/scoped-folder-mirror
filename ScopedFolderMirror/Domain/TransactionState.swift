import Foundation

enum TransactionPhase: String, Codable, Equatable, Sendable {
  case staging
  case stagedVerified
  case archiveStaging
  case archiveVerified
  case rollbackMovePrepared
  case rollbackReady
  case currentPromoted
  case currentVerified
  case archivePromotionPrepared
  case archivePromoted
  case rollbackCleanupPrepared
  case cleanupReady
}

struct TransactionState: Codable, Sendable {
  let schemaVersion: Int
  let runName: String
  let hadCurrent: Bool
  let archiveExpected: Bool
  var phase: TransactionPhase

  init(runName: String, hadCurrent: Bool, archiveExpected: Bool) {
    schemaVersion = 1
    self.runName = runName
    self.hadCurrent = hadCurrent
    self.archiveExpected = archiveExpected
    phase = .staging
  }
}

struct TransactionStateStore: Sendable {
  private var fileManager: FileManager { .default }

  func save(_ state: TransactionState, layout: TransactionLayout) throws {
    try fileManager.createDirectory(
      at: layout.transactionStates, withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: layout.stateFile, options: .atomic)
  }

  func remove(_ layout: TransactionLayout) throws {
    guard fileManager.fileExists(atPath: layout.stateFile.path) else { return }
    try fileManager.removeItem(at: layout.stateFile)
  }

  func loadAll(at destination: URL) throws -> [TransactionState] {
    let root = destination.appending(path: ".transactions", directoryHint: .isDirectory)
    guard let rootType = try SafeFileTree().itemType(at: root) else { return [] }
    guard rootType == .typeDirectory else {
      throw SyncFailure.transactionRecoveryFailed
    }
    do {
      return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try load($0) }
    } catch let failure as SyncFailure {
      throw failure
    } catch {
      throw SyncFailure.transactionRecoveryFailed
    }
  }

  private func load(_ url: URL) throws -> TransactionState {
    guard url.pathExtension == "json", try SafeFileTree().isRegularFile(url) else {
      throw SyncFailure.transactionRecoveryFailed
    }
    let state = try JSONDecoder().decode(TransactionState.self, from: Data(contentsOf: url))
    guard state.schemaVersion == 1, TransactionLayout.isValidRunName(state.runName),
      url.deletingPathExtension().lastPathComponent == state.runName
    else {
      throw SyncFailure.transactionRecoveryFailed
    }
    return state
  }
}

enum TransactionFaultPoint: CaseIterable, Sendable {
  case afterStagingCreated
  case afterStagedVerified
  case afterPendingArchiveCreated
  case afterPendingArchiveVerified
  case afterCurrentMovedToRollback
  case afterNextPromoted
  case afterCurrentVerified
  case afterArchivePromoted
  case afterRollbackRenamedForCleanup
  case duringCleanupDeletion
}

protocol TransactionFaultInjecting: Sendable {
  func hit(_ point: TransactionFaultPoint) throws
}

protocol TransactionInterruption: Error {}

struct NoTransactionFaults: TransactionFaultInjecting {
  func hit(_ point: TransactionFaultPoint) throws {}
}
