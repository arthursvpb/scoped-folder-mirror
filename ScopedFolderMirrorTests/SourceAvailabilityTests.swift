import XCTest

@testable import ScopedFolderMirror

final class SourceAvailabilityTests: XCTestCase {
  func testMissingSourceFailsWithTypedError() throws {
    let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    XCTAssertThrowsError(try SourceManifestBuilder().build(at: source)) { error in
      XCTAssertEqual(error as? SyncFailure, .sourceUnavailable)
    }
  }

  func testSourceDisappearingBeforeManifestGenerationFails() throws {
    let source = try makeTemporaryDirectory()
    try FileManager.default.removeItem(at: source)

    XCTAssertThrowsError(try SourceManifestBuilder().build(at: source)) { error in
      XCTAssertEqual(error as? SyncFailure, .sourceUnavailable)
    }
  }

  func testGenuinelyEmptySourceProducesEmptyManifest() throws {
    let source = try makeTemporaryDirectory()

    XCTAssertEqual(try SourceManifestBuilder().build(at: source), SourceManifest(entries: []))
  }

  func testSourceDisappearingBetweenStabilitySnapshotsFails() async throws {
    let source = try makeTemporaryDirectory()
    try write("content", to: source.appending(path: "file.txt"))
    let detector = StableSourceDetector(
      snapshotBuilder: RemovingSourceSnapshotBuilder(),
      sleeper: ImmediateSleeper(),
      interval: .zero
    )

    do {
      _ = try await detector.stableManifest(at: source)
      XCTFail("Expected unavailable source failure")
    } catch {
      XCTAssertEqual(error as? SyncFailure, .sourceUnavailable)
    }
  }

  func testNonDirectorySourceFailsAsUnavailable() throws {
    let root = try makeTemporaryDirectory()
    let source = root.appending(path: "file.txt")
    try write("not a directory", to: source)

    XCTAssertThrowsError(try SourceManifestBuilder().build(at: source)) { error in
      XCTAssertEqual(error as? SyncFailure, .sourceUnavailable)
    }
  }

  func testUnavailableSourceLeavesMirrorArchiveAndEjectionUntouched() async throws {
    let fixture = try await SourceUnavailableCoordinatorFixture.make()

    await fixture.coordinator.manualSync()

    XCTAssertEqual(
      try String(contentsOf: fixture.destination.appending(path: "Current Mirror/file.txt")),
      "old"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.destination.appending(path: "Archive").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .sourceUnavailable)
  }
}

private struct RemovingSourceSnapshotBuilder: SourceSnapshotBuilding {
  func build(at root: URL) throws -> SourceManifest {
    let manifest = try SourceManifestBuilder().build(at: root)
    try FileManager.default.removeItem(at: root)
    return manifest
  }
}

private struct SourceUnavailableCoordinatorFixture {
  let coordinator: SyncCoordinator
  let activityStore: ActivityLogStore
  let destination: URL
  let ejectionRecord: URL

  static func make() async throws -> Self {
    let root = try makeTemporaryDirectory()
    let source = root.appending(path: "missing-source", directoryHint: .isDirectory)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let mirrorID = try DestinationOwnership().prepare(destination)
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    let suite = "SourceUnavailableCoordinatorFixture.\(UUID().uuidString)"
    let configurationStore = ConfigurationStore(
      defaults: UserDefaults(suiteName: suite)!, bookmarkAccess: BookmarkAccessFake())
    try await configurationStore.saveBookmark(source, kind: .source)
    try await configurationStore.saveBookmark(destination, kind: .destination)
    try await configurationStore.saveConfiguration(
      StoredConfiguration(
        volume: VolumeIdentity(uuid: "test-volume"),
        mirrorID: mirrorID,
        acceptedUnencryptedVolume: false
      ))
    let activityStore = ActivityLogStore(defaults: UserDefaults(suiteName: suite)!)
    let ejectionRecord = root.appending(path: "ejected.txt")
    let assessment = VolumeAssessment(
      rootURL: root,
      uuid: "test-volume",
      isExternal: true,
      isWritable: true,
      isEjectable: true,
      isEncrypted: true
    )
    let coordinator = SyncCoordinator(
      configurationStore: configurationStore,
      activityStore: activityStore,
      volumeAssessor: FixedVolumeAssessor(assessment: assessment),
      stableSourceDetector: StableSourceDetector(sleeper: ImmediateSleeper(), interval: .zero),
      volumeEjector: RecordingVolumeEjector(recordURL: ejectionRecord),
      securityScope: SecurityScopeAccessFake()
    ) { _, _ in }
    return Self(
      coordinator: coordinator,
      activityStore: activityStore,
      destination: destination,
      ejectionRecord: ejectionRecord
    )
  }
}
