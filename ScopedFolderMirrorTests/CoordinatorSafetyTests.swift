import XCTest

@testable import ScopedFolderMirror

final class CoordinatorSafetyTests: XCTestCase {
  func testFailedMirrorDoesNotEjectVolume() async throws {
    let fixture = try await makeFixture(mirror: FailingMirrorExecutor())

    await fixture.coordinator.manualSync()

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .verificationFailed)
  }

  func testVerifiedMirrorEjectsContainingVolume() async throws {
    let fixture = try await makeFixture(mirror: SuccessfulMirrorExecutor())

    await fixture.coordinator.manualSync()

    XCTAssertEqual(
      try String(contentsOf: fixture.ejectionRecord, encoding: .utf8), fixture.volumeRoot.path)
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeeded)
  }

  private func makeFixture(mirror: any MirrorExecuting) async throws -> CoordinatorFixture {
    let root = try makeTemporaryDirectory()
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try write("content", to: source.appending(path: "file.txt"))
    let mirrorID = try DestinationOwnership().prepare(destination)
    let suite = "CoordinatorSafetyTests.\(UUID().uuidString)"
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
      mirrorTransaction: mirror,
      volumeEjector: RecordingVolumeEjector(recordURL: ejectionRecord),
      securityScope: SecurityScopeAccessFake()
    ) { _, _ in }
    return CoordinatorFixture(
      coordinator: coordinator,
      activityStore: activityStore,
      volumeRoot: root,
      ejectionRecord: ejectionRecord
    )
  }
}

private struct CoordinatorFixture {
  let coordinator: SyncCoordinator
  let activityStore: ActivityLogStore
  let volumeRoot: URL
  let ejectionRecord: URL
}
