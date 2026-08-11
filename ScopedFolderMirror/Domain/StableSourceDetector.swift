import Foundation

protocol SyncSleeping: Sendable {
  func sleep(for duration: Duration) async throws
}

struct SystemSyncSleeper: SyncSleeping {
  func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

struct StableSourceDetector: Sendable {
  private let snapshotBuilder: any SourceSnapshotBuilding
  private let sleeper: any SyncSleeping
  private let interval: Duration

  init(
    snapshotBuilder: any SourceSnapshotBuilding = SourceManifestBuilder(),
    sleeper: any SyncSleeping = SystemSyncSleeper(),
    interval: Duration = .seconds(10)
  ) {
    self.snapshotBuilder = snapshotBuilder
    self.sleeper = sleeper
    self.interval = interval
  }

  func stableManifest(at source: URL) async throws -> SourceManifest {
    let first = try snapshotBuilder.build(at: source)
    try await sleeper.sleep(for: interval)
    let second = try snapshotBuilder.build(at: source)
    guard first == second else { throw SyncFailure.sourceChanging }
    return second
  }
}
