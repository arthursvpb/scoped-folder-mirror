import XCTest

@testable import ScopedFolderMirror

final class TransactionRecoveryTests: XCTestCase {
  func testEveryInterruptionRecoversCompleteMirrorAndCanSyncAgain() throws {
    for point in TransactionFaultPoint.allCases {
      try verifyRecovery(at: point)
    }
  }

  func testAbandonedStagingRunIsCleanedInsideOwnedDestination() throws {
    let fixture = try RecoveryFixture.make()
    let abandoned = fixture.destination.appending(path: ".staging/abandoned")
    try write("partial", to: abandoned.appending(path: "next/file.txt"))
    try write("keep", to: fixture.destination.appending(path: "unrelated/file.txt"))

    try TransactionRecovery().recoverAll(
      at: fixture.destination, mirrorID: fixture.mirrorID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    XCTAssertEqual(
      try String(contentsOf: fixture.destination.appending(path: "unrelated/file.txt")), "keep")
    XCTAssertEqual(try fixture.currentValue(), "old")
  }

  func testSymlinkedStagingRunFailsWithoutTouchingTargetOrMirror() throws {
    let fixture = try RecoveryFixture.make()
    let outside = try makeTemporaryDirectory()
    try write("outside", to: outside.appending(path: "file.txt"))
    let staging = fixture.destination.appending(path: ".staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: staging.appending(path: "escape"), withDestinationURL: outside)

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(
        at: fixture.destination, mirrorID: fixture.mirrorID)
    ) { error in
      XCTAssertEqual(error as? SyncFailure, .transactionCleanupFailed)
    }
    XCTAssertEqual(try fixture.currentValue(), "old")
    XCTAssertEqual(try String(contentsOf: outside.appending(path: "file.txt")), "outside")
  }

  func testCleanupRequiresValidOwnershipMarker() throws {
    let destination = try makeTemporaryDirectory()
    try write("partial", to: destination.appending(path: ".staging/abandoned/file.txt"))

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(at: destination, mirrorID: UUID()))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: destination.appending(path: ".staging/abandoned/file.txt").path))
  }

  func testUntrackedRollbackIsNeverTreatedAsAuthoritative() throws {
    let fixture = try RecoveryFixture.make()
    try write("untrusted", to: fixture.destination.appending(path: ".rollback/orphan/file.txt"))

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(
        at: fixture.destination, mirrorID: fixture.mirrorID)
    ) { error in
      XCTAssertEqual(error as? SyncFailure, .transactionRecoveryFailed)
    }
    XCTAssertEqual(try fixture.currentValue(), "old")
  }

  func testMalformedTransactionStateFailsWithoutChangingMirror() throws {
    let fixture = try RecoveryFixture.make()
    try write("not-json", to: fixture.destination.appending(path: ".transactions/broken.json"))

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(
        at: fixture.destination, mirrorID: fixture.mirrorID))
    XCTAssertEqual(try fixture.currentValue(), "old")
  }

  func testMultipleTransactionStatesFailAsAmbiguous() throws {
    let fixture = try RecoveryFixture.make()
    let store = TransactionStateStore()
    for runName in ["first-state", "second-state"] {
      let layout = try TransactionLayout(destination: fixture.destination, runName: runName)
      try store.save(
        TransactionState(runName: runName, hadCurrent: true, archiveExpected: true),
        layout: layout
      )
    }

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(
        at: fixture.destination, mirrorID: fixture.mirrorID)
    ) { error in
      XCTAssertEqual(error as? SyncFailure, .transactionRecoveryFailed)
    }
    XCTAssertEqual(try fixture.currentValue(), "old")
  }

  func testTransactionStateContainsOnlyVersionedNonSensitiveFields() throws {
    let fixture = try RecoveryFixture.make()
    let manifest = try SourceManifestBuilder().build(at: fixture.source)
    let transaction = MirrorTransaction(
      freeSpace: UnlimitedSpaceReader(),
      faultInjector: InterruptingFaultInjector(
        point: .afterStagingCreated,
        cleanupFile: fixture.destination.appending(path: ".cleanup/privacy/file.txt")
      )
    )
    XCTAssertThrowsError(
      try transaction.execute(
        source: fixture.source,
        destination: fixture.destination,
        sourceManifest: manifest,
        runName: "privacy",
        mirrorID: fixture.mirrorID
      ))
    let data = try Data(
      contentsOf: fixture.destination.appending(path: ".transactions/privacy.json"))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertEqual(
      Set(object.keys), ["schemaVersion", "runName", "hadCurrent", "archiveExpected", "phase"])
    let encoded = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(encoded.contains(fixture.source.path))
    XCTAssertFalse(encoded.contains(fixture.destination.path))
  }

  func testReservedRunNameCannotEscapeDestination() throws {
    let fixture = try RecoveryFixture.make()
    let manifest = try SourceManifestBuilder().build(at: fixture.source)

    XCTAssertThrowsError(
      try MirrorTransaction(freeSpace: UnlimitedSpaceReader()).execute(
        source: fixture.source,
        destination: fixture.destination,
        sourceManifest: manifest,
        runName: "../escape",
        mirrorID: fixture.mirrorID
      ))
    XCTAssertEqual(try fixture.currentValue(), "old")
  }

  func testReservedCurrentMirrorSymlinkCannotEscapeDestination() throws {
    let destination = try makeTemporaryDirectory()
    let mirrorID = try DestinationOwnership().prepare(destination)
    let outside = try makeTemporaryDirectory()
    try write("outside", to: outside.appending(path: "file.txt"))
    try FileManager.default.createSymbolicLink(
      at: destination.appending(path: "Current Mirror"), withDestinationURL: outside)

    XCTAssertThrowsError(
      try TransactionRecovery().recoverAll(at: destination, mirrorID: mirrorID)
    ) { error in
      XCTAssertEqual(error as? SyncFailure, .transactionRecoveryFailed)
    }
    XCTAssertEqual(try String(contentsOf: outside.appending(path: "file.txt")), "outside")
  }

  private func verifyRecovery(at point: TransactionFaultPoint) throws {
    let fixture = try RecoveryFixture.make()
    let manifest = try SourceManifestBuilder().build(at: fixture.source)
    let previousManifest = try SourceManifestBuilder().build(
      at: fixture.destination.appending(path: "Current Mirror"))
    let fault = InterruptingFaultInjector(
      point: point,
      cleanupFile: fixture.destination.appending(path: ".cleanup/interrupted/file.txt")
    )
    let interrupted = MirrorTransaction(
      freeSpace: UnlimitedSpaceReader(), faultInjector: fault)

    XCTAssertThrowsError(
      try interrupted.execute(
        source: fixture.source,
        destination: fixture.destination,
        sourceManifest: manifest,
        runName: "interrupted",
        mirrorID: fixture.mirrorID
      )
    ) { error in
      XCTAssertTrue(error is SimulatedTransactionInterruption)
    }

    try TransactionRecovery().recoverAll(
      at: fixture.destination, mirrorID: fixture.mirrorID)
    let recovered = try SourceManifestBuilder().build(
      at: fixture.destination.appending(path: "Current Mirror"))
    XCTAssertTrue(
      recovered.hasSameContent(as: previousManifest) || recovered.hasSameContent(as: manifest))
    try assertArchiveIsVerifiedIfPresent(fixture.destination, expected: previousManifest)
    for reserved in [
      ".staging/interrupted", ".rollback/interrupted", ".cleanup/interrupted",
      ".transactions/interrupted.json",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.destination.appending(path: reserved).path),
        "Recovery left reserved state at \(reserved)"
      )
    }

    _ = try MirrorTransaction(freeSpace: UnlimitedSpaceReader()).execute(
      source: fixture.source,
      destination: fixture.destination,
      sourceManifest: manifest,
      runName: "subsequent",
      mirrorID: fixture.mirrorID
    )
    let completed = try SourceManifestBuilder().build(
      at: fixture.destination.appending(path: "Current Mirror"))
    XCTAssertTrue(completed.hasSameContent(as: manifest))
  }

  private func assertArchiveIsVerifiedIfPresent(
    _ destination: URL, expected: SourceManifest
  ) throws {
    let archive = destination.appending(path: "Archive/interrupted")
    guard FileManager.default.fileExists(atPath: archive.path) else { return }
    let archived = try SourceManifestBuilder().build(at: archive)
    XCTAssertTrue(archived.hasSameContent(as: expected))
  }
}

private struct RecoveryFixture {
  let source: URL
  let destination: URL
  let mirrorID: UUID

  static func make() throws -> Self {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    let mirrorID = try DestinationOwnership().prepare(destination)
    try write("new", to: source.appending(path: "file.txt"))
    try write("new nested", to: source.appending(path: "nested/second.txt"))
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    try write("old nested", to: destination.appending(path: "Current Mirror/nested/second.txt"))
    return Self(source: source, destination: destination, mirrorID: mirrorID)
  }

  func currentValue() throws -> String {
    try String(contentsOf: destination.appending(path: "Current Mirror/file.txt"))
  }
}

private struct SimulatedTransactionInterruption: TransactionInterruption {}

private struct InterruptingFaultInjector: TransactionFaultInjecting {
  let point: TransactionFaultPoint
  let cleanupFile: URL

  func hit(_ candidate: TransactionFaultPoint) throws {
    guard candidate == point else { return }
    if candidate == .duringCleanupDeletion,
      FileManager.default.fileExists(atPath: cleanupFile.path)
    {
      try FileManager.default.removeItem(at: cleanupFile)
    }
    throw SimulatedTransactionInterruption()
  }
}
