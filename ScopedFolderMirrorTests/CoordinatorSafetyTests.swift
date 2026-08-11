import Dispatch
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

  func testEnabledPreferenceEjectsAfterVerifiedSuccess() async throws {
    let fixture = try await makeFixture(mirror: SuccessfulMirrorExecutor())

    await fixture.coordinator.manualSync()

    XCTAssertEqual(
      try String(contentsOf: fixture.ejectionRecord, encoding: .utf8), fixture.volumeRoot.path)
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeeded)
  }

  func testDisabledPreferenceNeverInvokesEjectorAndReportsPlainSuccess() async throws {
    let fixture = try await makeFixture(
      mirror: SuccessfulMirrorExecutor(), ejectAfterSuccess: false)

    await fixture.coordinator.manualSync()

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeededKeptMounted)
  }

  func testEjectionFailureReturnsSuccessWithWarning() async throws {
    let fixture = try await makeFixture(
      mirror: SuccessfulMirrorExecutor(), ejector: FailingVolumeEjector())

    await fixture.coordinator.manualSync()

    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeededNotEjected)
  }

  func testRunCapturesEjectionPreferenceAtStart() async throws {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let fixture = try await makeFixture(
      mirror: BlockingMirrorExecutor(started: started, resume: resume))
    let sync = Task { await fixture.coordinator.manualSync() }
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

    await fixture.configurationStore.setEjectAfterSuccessfulSync(false)
    resume.signal()
    await sync.value

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeeded)
  }

  func testDisabledPreferenceAppliesToAutomaticSync() async throws {
    let fixture = try await makeFixture(
      mirror: SuccessfulMirrorExecutor(), ejectAfterSuccess: false)

    await fixture.coordinator.automaticEvent()
    try await waitForActivities(1, in: fixture.activityStore)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .succeededKeptMounted)
  }

  func testWrongVolumeIsRejectedWithoutEjection() async throws {
    try await assertDestinationRejected(.wrongVolume)
  }

  func testInternalDestinationIsRejectedWithoutEjection() async throws {
    try await assertDestinationRejected(.internalVolume)
  }

  func testReadOnlyDestinationIsRejectedWithoutEjection() async throws {
    try await assertDestinationRejected(.readOnly)
  }

  func testDestinationRootIsRejectedWithoutEjection() async throws {
    try await assertDestinationRejected(.destinationRoot)
  }

  private func assertDestinationRejected(_ assessmentKind: DestinationAssessmentKind)
    async throws
  {
    let fixture = try await makeFixture(
      mirror: SuccessfulMirrorExecutor(), assessmentKind: assessmentKind)
    await fixture.coordinator.manualSync()

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ejectionRecord.path))
    let activity = await fixture.activityStore.entries().first
    XCTAssertEqual(activity?.code, .destinationUnavailable)
  }

  private func waitForActivities(_ count: Int, in store: ActivityLogStore) async throws {
    for _ in 0..<100 {
      if await store.entries().count >= count { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for sync activity")
  }

  private func makeFixture(
    mirror: any MirrorExecuting,
    ejectAfterSuccess: Bool = true,
    ejector: (any VolumeEjecting)? = nil,
    assessmentKind: DestinationAssessmentKind = .valid
  ) async throws -> CoordinatorFixture {
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
    await configurationStore.setEjectAfterSuccessfulSync(ejectAfterSuccess)
    let activityStore = ActivityLogStore(defaults: UserDefaults(suiteName: suite)!)
    let ejectionRecord = root.appending(path: "ejected.txt")
    let assessment = VolumeAssessment(
      rootURL: assessmentKind == .destinationRoot ? destination : root,
      uuid: assessmentKind == .wrongVolume ? "other-volume" : "test-volume",
      isExternal: assessmentKind != .internalVolume,
      isWritable: assessmentKind != .readOnly,
      isEjectable: true,
      isEncrypted: true
    )
    let coordinator = SyncCoordinator(
      configurationStore: configurationStore,
      activityStore: activityStore,
      volumeAssessor: FixedVolumeAssessor(assessment: assessment),
      stableSourceDetector: StableSourceDetector(sleeper: ImmediateSleeper(), interval: .zero),
      mirrorTransaction: mirror,
      volumeEjector: ejector ?? RecordingVolumeEjector(recordURL: ejectionRecord),
      securityScope: SecurityScopeAccessFake(),
      sleeper: ImmediateSleeper()
    ) { _, _ in }
    return CoordinatorFixture(
      coordinator: coordinator,
      configurationStore: configurationStore,
      activityStore: activityStore,
      volumeRoot: root,
      ejectionRecord: ejectionRecord
    )
  }
}

private enum DestinationAssessmentKind: Equatable {
  case valid
  case wrongVolume
  case internalVolume
  case readOnly
  case destinationRoot
}

private struct CoordinatorFixture {
  let coordinator: SyncCoordinator
  let configurationStore: ConfigurationStore
  let activityStore: ActivityLogStore
  let volumeRoot: URL
  let ejectionRecord: URL
}
