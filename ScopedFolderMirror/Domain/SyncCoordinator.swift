import Foundation

private enum CoordinatorState: Equatable {
  case idle
  case paused
  case debouncing
  case running(automationEnabled: Bool, followUp: FollowUp)
}

private enum FollowUp: Equatable {
  case none
  case automatic
  case manual
}

private enum SyncOutcome {
  case success(MirrorReceipt, ejection: EjectionOutcome)
  case failure(SyncFailure)
}

private enum EjectionOutcome {
  case ejected
  case keptMounted
  case failed
}

actor SyncCoordinator {
  typealias UpdateHandler = @MainActor @Sendable (SyncPhase, ActivityRecord?) -> Void

  private let configurationStore: ConfigurationStore
  private let activityStore: ActivityLogStore
  private let volumeAssessor: any VolumeAssessing
  private let ownership: DestinationOwnership
  private let relationshipValidator: FolderRelationshipValidator
  private let stableSourceDetector: StableSourceDetector
  private let mirrorTransaction: any MirrorExecuting
  private let volumeEjector: any VolumeEjecting
  private let securityScope: any SecurityScopeAccessing
  private let sleeper: any SyncSleeping
  private let updateHandler: UpdateHandler
  private var state: CoordinatorState = .idle
  private var debounceTask: Task<Void, Never>?

  init(
    configurationStore: ConfigurationStore,
    activityStore: ActivityLogStore,
    volumeAssessor: any VolumeAssessing = SystemVolumeAssessor(),
    ownership: DestinationOwnership = DestinationOwnership(),
    relationshipValidator: FolderRelationshipValidator = FolderRelationshipValidator(),
    stableSourceDetector: StableSourceDetector = StableSourceDetector(),
    mirrorTransaction: any MirrorExecuting = MirrorTransaction(),
    volumeEjector: any VolumeEjecting = SystemVolumeEjector(),
    securityScope: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
    sleeper: any SyncSleeping = SystemSyncSleeper(),
    updateHandler: @escaping UpdateHandler
  ) {
    self.configurationStore = configurationStore
    self.activityStore = activityStore
    self.volumeAssessor = volumeAssessor
    self.ownership = ownership
    self.relationshipValidator = relationshipValidator
    self.stableSourceDetector = stableSourceDetector
    self.mirrorTransaction = mirrorTransaction
    self.volumeEjector = volumeEjector
    self.securityScope = securityScope
    self.sleeper = sleeper
    self.updateHandler = updateHandler
  }

  func setAutomationPaused(_ paused: Bool) async {
    debounceTask?.cancel()
    debounceTask = nil
    if case .running(_, let followUp) = state {
      state = .running(automationEnabled: !paused, followUp: paused ? .none : followUp)
    } else {
      state = paused ? .paused : .idle
    }
    await updateHandler(.awaitingVolume, nil)
  }

  func automaticEvent() {
    switch state {
    case .paused:
      return
    case .running(let automationEnabled, _):
      guard automationEnabled else { return }
      state = .running(automationEnabled: true, followUp: .automatic)
    case .idle, .debouncing:
      scheduleDebounce()
    }
  }

  func manualSync() async {
    if case .running(let automationEnabled, _) = state {
      state = .running(automationEnabled: automationEnabled, followUp: .manual)
      return
    }
    let automationEnabled = state != .paused
    debounceTask?.cancel()
    debounceTask = nil
    await runOnce(automationEnabled: automationEnabled)
  }

  private func scheduleDebounce() {
    debounceTask?.cancel()
    state = .debouncing
    Task { await updateHandler(.debouncing, nil) }
    debounceTask = Task { [sleeper] in
      do {
        try await sleeper.sleep(for: .seconds(15))
        await self.debounceFinished()
      } catch {}
    }
  }

  private func debounceFinished() async {
    guard !Task.isCancelled, state == .debouncing else { return }
    debounceTask = nil
    await runOnce(automationEnabled: true)
  }

  private func runOnce(automationEnabled: Bool) async {
    state = .running(automationEnabled: automationEnabled, followUp: .none)
    await updateHandler(.checking, nil)
    let ejectAfterSuccess = await configurationStore.ejectAfterSuccessfulSync()
    let result = await performSync(ejectAfterSuccess: ejectAfterSuccess)
    await record(result)
    guard case .running(let currentAutomationEnabled, let followUp) = state else { return }
    switch followUp {
    case .automatic where currentAutomationEnabled:
      scheduleDebounce()
    case .manual:
      await runOnce(automationEnabled: currentAutomationEnabled)
    case .none, .automatic:
      state = currentAutomationEnabled ? .idle : .paused
    }
  }

  private func performSync(ejectAfterSuccess: Bool) async -> SyncOutcome {
    do {
      let inputs = try await resolveInputs()
      defer {
        securityScope.stopAccessing(inputs.source)
        securityScope.stopAccessing(inputs.destination)
      }
      try validate(inputs)
      let manifest = try await stableSourceDetector.stableManifest(at: inputs.source)
      await updateHandler(.copying, nil)
      let receipt = try mirrorTransaction.execute(
        source: inputs.source,
        destination: inputs.destination,
        sourceManifest: manifest,
        runName: RunName.make(),
        mirrorID: inputs.configuration.mirrorID
      )
      guard ejectAfterSuccess else { return .success(receipt, ejection: .keptMounted) }
      await updateHandler(.ejecting, nil)
      do {
        try volumeEjector.eject(inputs.assessment.rootURL)
        return .success(receipt, ejection: .ejected)
      } catch {
        return .success(receipt, ejection: .failed)
      }
    } catch let failure as SyncFailure {
      return .failure(failure)
    } catch {
      return .failure(.unexpected)
    }
  }

  private struct SyncInputs {
    let source: URL
    let destination: URL
    let configuration: StoredConfiguration
    let assessment: VolumeAssessment
  }

  private func resolveInputs() async throws -> SyncInputs {
    guard let source = try await configurationStore.resolveBookmark(.source) else {
      throw SyncFailure.needsAuthorization
    }
    guard securityScope.startAccessing(source) else {
      throw SyncFailure.needsAuthorization
    }
    guard
      let destination = try await configurationStore.resolveBookmark(.destination),
      let configuration = try await configurationStore.configuration(),
      securityScope.startAccessing(destination)
    else {
      securityScope.stopAccessing(source)
      throw SyncFailure.needsAuthorization
    }
    do {
      return SyncInputs(
        source: source,
        destination: destination,
        configuration: configuration,
        assessment: try volumeAssessor.assess(destination)
      )
    } catch {
      securityScope.stopAccessing(source)
      securityScope.stopAccessing(destination)
      throw error
    }
  }

  private func validate(_ inputs: SyncInputs) throws {
    guard
      inputs.assessment.uuid.caseInsensitiveCompare(inputs.configuration.volume.uuid)
        == .orderedSame
    else {
      throw SyncFailure.invalidDestination(.wrongVolume)
    }
    guard inputs.assessment.isExternal else { throw SyncFailure.invalidDestination(.notExternal) }
    guard inputs.assessment.isWritable else { throw SyncFailure.invalidDestination(.notWritable) }
    guard inputs.assessment.isEjectable else { throw SyncFailure.invalidDestination(.notExternal) }
    guard !isFilesystemRoot(inputs.source),
      inputs.destination.standardizedFileURL.path
        != inputs.assessment.rootURL.standardizedFileURL.path
    else {
      throw SyncFailure.invalidDestination(.notDedicatedFolder)
    }
    try ownership.validate(inputs.destination, mirrorID: inputs.configuration.mirrorID)
    try relationshipValidator.validate(source: inputs.source, destination: inputs.destination)
  }

  private func isFilesystemRoot(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    return standardized.path == "/"
      || standardized.deletingLastPathComponent().path == standardized.path
  }

  private func record(_ result: SyncOutcome) async {
    let record: ActivityRecord
    let phase: SyncPhase
    switch result {
    case .success(let receipt, let ejection):
      record = ActivityRecord(
        code: activityCode(for: ejection),
        fileCount: receipt.fileCount,
        byteCount: receipt.byteCount
      )
      phase = .succeeded
    case .failure(let failure):
      record = ActivityRecord(code: activityCode(for: failure))
      phase = .failed
    }
    await activityStore.append(record)
    await updateHandler(phase, record)
  }

  private func activityCode(for ejection: EjectionOutcome) -> ActivityCode {
    switch ejection {
    case .ejected: .succeeded
    case .keptMounted: .succeededKeptMounted
    case .failed: .succeededNotEjected
    }
  }

  private func activityCode(for failure: SyncFailure) -> ActivityCode {
    switch failure {
    case .needsAuthorization: .needsAuthorization
    case .sourceUnavailable: .sourceUnavailable
    case .sourceChanging: .sourceChanging
    case .invalidDestination: .destinationUnavailable
    case .insufficientSpace: .insufficientSpace
    case .unsupportedEntry: .unsupportedEntry
    case .verificationFailed: .verificationFailed
    case .transactionCleanupFailed: .transactionCleanupFailed
    case .transactionRecoveryFailed: .transactionRecoveryFailed
    case .canceled: .canceled
    case .unexpected: .unexpectedFailure
    }
  }
}
