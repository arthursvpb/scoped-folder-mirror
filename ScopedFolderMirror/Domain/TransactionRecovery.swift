import Foundation

struct TransactionRecovery: Sendable {
  private let ownership: DestinationOwnership
  private let fileSystem: any MirrorFileManaging
  private let stateStore: TransactionStateStore
  private let safeTree: SafeFileTree

  init(
    ownership: DestinationOwnership = DestinationOwnership(),
    fileSystem: any MirrorFileManaging = SystemMirrorFileManager(),
    stateStore: TransactionStateStore = TransactionStateStore(),
    safeTree: SafeFileTree = SafeFileTree()
  ) {
    self.ownership = ownership
    self.fileSystem = fileSystem
    self.stateStore = stateStore
    self.safeTree = safeTree
  }

  func recoverAll(at destination: URL, mirrorID: UUID) throws {
    try ownership.validate(destination, mirrorID: mirrorID)
    try validateReservedRoots(at: destination)
    let states = try stateStore.loadAll(at: destination)
    guard states.count <= 1 else { throw SyncFailure.transactionRecoveryFailed }
    for state in states {
      try recover(state, destination: destination)
    }
    try cleanupAbandonedRuns(at: destination)
    try rejectUntrackedRollbacks(at: destination)
  }

  func recover(_ state: TransactionState, destination: URL) throws {
    let layout = try TransactionLayout(destination: destination, runName: state.runName)
    try validateControlPaths(layout)
    switch state.phase {
    case .staging, .stagedVerified, .archiveStaging, .archiveVerified:
      try discardUncommitted(layout)
    case .rollbackMovePrepared:
      try recoverPreparedRollback(state, layout: layout)
    case .rollbackReady, .currentPromoted:
      try restorePrevious(state, layout: layout)
    case .currentVerified, .archivePromotionPrepared:
      try finishVerifiedCurrent(state, layout: layout)
    case .archivePromoted, .rollbackCleanupPrepared, .cleanupReady:
      try finalizeCleanup(state, layout: layout)
    }
  }

  func handleFailure(_ state: TransactionState, destination: URL) throws {
    let layout = try TransactionLayout(destination: destination, runName: state.runName)
    try validateControlPaths(layout)
    switch state.phase {
    case .staging, .stagedVerified, .archiveStaging, .archiveVerified:
      try discardUncommitted(layout)
    case .rollbackMovePrepared:
      try recoverPreparedRollback(state, layout: layout)
    case .rollbackReady, .currentPromoted:
      try restorePrevious(state, layout: layout)
    case .currentVerified, .archivePromotionPrepared:
      if fileSystem.fileExists(at: layout.archiveRun) {
        try finishVerifiedCurrent(state, layout: layout)
      } else {
        try restorePrevious(state, layout: layout)
      }
    case .archivePromoted, .rollbackCleanupPrepared, .cleanupReady:
      throw SyncFailure.transactionCleanupFailed
    }
  }

  private func recoverPreparedRollback(_ state: TransactionState, layout: TransactionLayout)
    throws
  {
    let hasCurrent = fileSystem.fileExists(at: layout.current)
    let hasRollback = fileSystem.fileExists(at: layout.rollback)
    if hasRollback {
      guard !hasCurrent, state.hadCurrent else { throw SyncFailure.transactionRecoveryFailed }
      try fileSystem.moveItem(at: layout.rollback, to: layout.current)
    } else if !hasCurrent && state.hadCurrent {
      throw SyncFailure.transactionRecoveryFailed
    }
    try discardUncommitted(layout)
  }

  private func restorePrevious(_ state: TransactionState, layout: TransactionLayout) throws {
    if fileSystem.fileExists(at: layout.current) {
      try moveCurrentToCleanup(layout)
    }
    if state.hadCurrent {
      guard fileSystem.fileExists(at: layout.rollback) else {
        throw SyncFailure.transactionRecoveryFailed
      }
      try fileSystem.moveItem(at: layout.rollback, to: layout.current)
    }
    try removeCleanup(layout.discardedCurrent, parent: layout.cleanupRuns)
    try discardUncommitted(layout)
  }

  private func finishVerifiedCurrent(_ state: TransactionState, layout: TransactionLayout) throws {
    var updated = state
    updated.phase = .archivePromotionPrepared
    try stateStore.save(updated, layout: layout)
    try promoteVerifiedArchive(updated, layout: layout)
    updated.phase = .archivePromoted
    try stateStore.save(updated, layout: layout)
    try finalizeCleanup(updated, layout: layout)
  }

  private func promoteVerifiedArchive(_ state: TransactionState, layout: TransactionLayout) throws {
    let hasPending = fileSystem.fileExists(at: layout.pendingArchive)
    let hasArchive = fileSystem.fileExists(at: layout.archiveRun)
    guard state.archiveExpected else {
      guard !hasPending, !hasArchive else { throw SyncFailure.transactionRecoveryFailed }
      return
    }
    guard hasPending != hasArchive else { throw SyncFailure.transactionRecoveryFailed }
    guard hasPending else { return }
    try fileSystem.createDirectory(at: layout.archives)
    try fileSystem.moveItem(at: layout.pendingArchive, to: layout.archiveRun)
  }

  private func finalizeCleanup(_ state: TransactionState, layout: TransactionLayout) throws {
    var updated = state
    if state.hadCurrent, state.phase != .cleanupReady {
      updated.phase = .rollbackCleanupPrepared
      try stateStore.save(updated, layout: layout)
      try moveRollbackToCleanup(layout)
    }
    updated.phase = .cleanupReady
    try stateStore.save(updated, layout: layout)
    try removeCleanup(layout.cleanup, parent: layout.cleanupRuns)
    try removeCleanup(layout.stagingRoot, parent: layout.stagingRuns)
    try stateStore.remove(layout)
  }

  private func moveRollbackToCleanup(_ layout: TransactionLayout) throws {
    let hasRollback = fileSystem.fileExists(at: layout.rollback)
    let hasCleanup = fileSystem.fileExists(at: layout.cleanup)
    guard hasRollback != hasCleanup else { throw SyncFailure.transactionRecoveryFailed }
    guard hasRollback else { return }
    try fileSystem.createDirectory(at: layout.cleanupRuns)
    try fileSystem.moveItem(at: layout.rollback, to: layout.cleanup)
  }

  private func moveCurrentToCleanup(_ layout: TransactionLayout) throws {
    guard !fileSystem.fileExists(at: layout.discardedCurrent) else {
      throw SyncFailure.transactionRecoveryFailed
    }
    try fileSystem.createDirectory(at: layout.cleanupRuns)
    try fileSystem.moveItem(at: layout.current, to: layout.discardedCurrent)
  }

  private func discardUncommitted(_ layout: TransactionLayout) throws {
    try removeCleanup(layout.stagingRoot, parent: layout.stagingRuns)
    try stateStore.remove(layout)
  }

  private func cleanupAbandonedRuns(at destination: URL) throws {
    do {
      for rootName in [".staging", ".cleanup"] {
        let root = destination.appending(path: rootName, directoryHint: .isDirectory)
        for child in try safeTree.directChildren(of: root) {
          guard TransactionLayout.isValidRunName(child.lastPathComponent) else {
            throw SyncFailure.transactionCleanupFailed
          }
          try safeTree.removeTree(child, inside: root)
        }
      }
    } catch let failure as SyncFailure {
      throw failure
    } catch {
      throw SyncFailure.transactionCleanupFailed
    }
  }

  private func rejectUntrackedRollbacks(at destination: URL) throws {
    let root = destination.appending(path: ".rollback", directoryHint: .isDirectory)
    do {
      guard try safeTree.directChildren(of: root).isEmpty else {
        throw SyncFailure.transactionRecoveryFailed
      }
    } catch {
      throw SyncFailure.transactionRecoveryFailed
    }
  }

  private func removeCleanup(_ target: URL, parent: URL) throws {
    do {
      try safeTree.removeTree(target, inside: parent)
    } catch let failure as SyncFailure {
      throw failure
    } catch {
      throw SyncFailure.transactionCleanupFailed
    }
  }

  private func validateReservedRoots(at destination: URL) throws {
    for name in ["Current Mirror", "Archive", ".staging", ".rollback", ".cleanup", ".transactions"]
    {
      let url = destination.appending(path: name, directoryHint: .isDirectory)
      guard let type = try safeTree.itemType(at: url) else { continue }
      guard type == .typeDirectory else { throw SyncFailure.transactionRecoveryFailed }
    }
  }

  private func validateControlPaths(_ layout: TransactionLayout) throws {
    for url in [
      layout.stagingRoot, layout.next, layout.pendingArchive, layout.rollback, layout.cleanup,
      layout.discardedCurrent, layout.archiveRun,
    ] {
      guard let type = try safeTree.itemType(at: url) else { continue }
      guard type == .typeDirectory else { throw SyncFailure.transactionRecoveryFailed }
    }
  }
}
