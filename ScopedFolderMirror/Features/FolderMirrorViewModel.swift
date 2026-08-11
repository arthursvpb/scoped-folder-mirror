import AppKit
import Foundation
import SwiftUI

@MainActor
final class FolderMirrorViewModel: ObservableObject {
  @Published private(set) var sourceLabel = "Not selected"
  @Published private(set) var destinationLabel = "Not selected"
  @Published private(set) var phase: SyncPhase = .unconfigured
  @Published private(set) var activities: [ActivityRecord] = []
  @Published private(set) var isConfigured = false
  @Published var automationPaused = false
  @Published var launchAtLogin = false
  @Published var ejectAfterSuccessfulSync = true
  @Published var showUnencryptedWarning = false
  @Published var statusMessage = "Choose a source folder and a destination folder."

  private let configurationStore: ConfigurationStore
  private let activityStore: ActivityLogStore
  private let folderSelector: FolderSelectionController
  private let volumeAssessor: any VolumeAssessing
  private let ownership: DestinationOwnership
  private let relationshipValidator: FolderRelationshipValidator
  private let launchController: any LaunchAtLoginManaging
  private var pendingDestination: URL?
  private var sourceLease: SecurityScopeLease?
  private var sourceMonitor: SourceChangeMonitor?
  private var mountMonitor: VolumeMountMonitor?
  private var preferenceUpdateTask: Task<Void, Never>?
  private var testingWindow: NSWindow?

  private lazy var coordinator = SyncCoordinator(
    configurationStore: configurationStore,
    activityStore: activityStore
  ) { [weak self] phase, record in
    guard let self else { return }
    self.phase = phase
    if let record {
      self.activities.insert(record, at: 0)
      self.statusMessage = Self.message(for: record)
    }
  }

  init(
    configurationStore: ConfigurationStore = ConfigurationStore(),
    activityStore: ActivityLogStore = ActivityLogStore(),
    folderSelector: FolderSelectionController = FolderSelectionController(),
    volumeAssessor: any VolumeAssessing = SystemVolumeAssessor(),
    ownership: DestinationOwnership = DestinationOwnership(),
    relationshipValidator: FolderRelationshipValidator = FolderRelationshipValidator(),
    launchController: any LaunchAtLoginManaging = SystemLaunchAtLoginController()
  ) {
    self.configurationStore = configurationStore
    self.activityStore = activityStore
    self.folderSelector = folderSelector
    self.volumeAssessor = volumeAssessor
    self.ownership = ownership
    self.relationshipValidator = relationshipValidator
    self.launchController = launchController
    launchAtLogin = launchController.isEnabled
    mountMonitor = VolumeMountMonitor { [weak self] in
      Task { @MainActor [weak self] in self?.scheduleAutomaticEvent() }
    }
    Task { await refresh() }
    if CommandLine.arguments.contains("--ui-testing") {
      Task { openTestingWindow() }
    }
  }

  func chooseSource() {
    Task {
      guard
        let url = await folderSelector.selectFolder(
          prompt: "Choose the source folder", canCreateDirectories: false)
      else { return }
      guard !isFilesystemRoot(url) else {
        statusMessage = "Choose a dedicated source folder, not a filesystem root."
        return
      }
      do {
        if let destination = try await configurationStore.resolveBookmark(.destination) {
          try relationshipValidator.validate(source: url, destination: destination)
        }
        try await configurationStore.saveBookmark(url, kind: .source)
        await refresh()
      } catch {
        statusMessage = "The source authorization could not be saved."
      }
    }
  }

  func chooseDestination() {
    Task {
      guard
        let url = await folderSelector.selectFolder(
          prompt: "Choose or create a dedicated destination folder", canCreateDirectories: true)
      else { return }
      do {
        let assessment = try volumeAssessor.assess(url)
        try await validateDestinationSelection(url, assessment: assessment)
        if assessment.isEncrypted != true {
          pendingDestination = url
          showUnencryptedWarning = true
        } else {
          try await authorizeDestination(url, assessment: assessment, acceptedUnencrypted: false)
        }
      } catch {
        statusMessage = "Choose a writable folder on an external volume."
      }
    }
  }

  func acceptUnencryptedDestination() {
    showUnencryptedWarning = false
    guard let destination = pendingDestination else { return }
    pendingDestination = nil
    Task {
      do {
        let assessment = try volumeAssessor.assess(destination)
        try await authorizeDestination(
          destination, assessment: assessment, acceptedUnencrypted: true)
      } catch {
        statusMessage = "The destination authorization could not be saved."
      }
    }
  }

  func rejectUnencryptedDestination() {
    pendingDestination = nil
    showUnencryptedWarning = false
  }

  func syncNow() {
    let preferenceUpdateTask = preferenceUpdateTask
    Task {
      await preferenceUpdateTask?.value
      await coordinator.manualSync()
    }
  }

  func setAutomationPaused(_ paused: Bool) {
    automationPaused = paused
    Task { await coordinator.setAutomationPaused(paused) }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try launchController.setEnabled(enabled)
      launchAtLogin = launchController.isEnabled
    } catch {
      launchAtLogin = launchController.isEnabled
      statusMessage = "Launch at Login could not be changed. Check Login Items in System Settings."
    }
  }

  func setEjectAfterSuccessfulSync(_ enabled: Bool) {
    ejectAfterSuccessfulSync = enabled
    preferenceUpdateTask = Task { await configurationStore.setEjectAfterSuccessfulSync(enabled) }
  }

  func revokeSource() {
    Task {
      await configurationStore.revoke(.source)
      await refresh()
    }
  }

  func revokeDestination() {
    Task {
      await configurationStore.revoke(.destination)
      await refresh()
    }
  }

  func resetAll() {
    Task {
      await configurationStore.reset()
      await activityStore.removeAll()
      activities = []
      await refresh()
    }
  }

  func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
  func quit() { NSApp.terminate(nil) }

  private func authorizeDestination(
    _ destination: URL,
    assessment: VolumeAssessment,
    acceptedUnencrypted: Bool
  ) async throws {
    guard let lease = SecurityScopeLease(url: destination) else {
      throw SyncFailure.needsAuthorization
    }
    let mirrorID = try ownership.prepare(destination)
    _ = lease
    try await configurationStore.saveBookmark(destination, kind: .destination)
    try await configurationStore.saveConfiguration(
      StoredConfiguration(
        volume: VolumeIdentity(uuid: assessment.uuid),
        mirrorID: mirrorID,
        acceptedUnencryptedVolume: acceptedUnencrypted
      )
    )
    await refresh()
  }

  private func validateDestinationSelection(_ destination: URL, assessment: VolumeAssessment)
    async throws
  {
    guard assessment.isExternal, assessment.isWritable, assessment.isEjectable else {
      throw SyncFailure.invalidDestination(.notExternal)
    }
    guard destination.standardizedFileURL.path != assessment.rootURL.standardizedFileURL.path else {
      throw SyncFailure.invalidDestination(.notDedicatedFolder)
    }
    if let source = try await configurationStore.resolveBookmark(.source) {
      try relationshipValidator.validate(source: source, destination: destination)
    }
  }

  private func refresh() async {
    let source = try? await configurationStore.resolveBookmark(.source)
    let destination = try? await configurationStore.resolveBookmark(.destination)
    let configuration = try? await configurationStore.configuration()
    ejectAfterSuccessfulSync = await configurationStore.ejectAfterSuccessfulSync()
    sourceLabel = source?.lastPathComponent ?? "Not selected"
    destinationLabel = destination?.lastPathComponent ?? "Not selected"
    isConfigured = source != nil && destination != nil && configuration != nil
    phase = isConfigured ? .awaitingVolume : .unconfigured
    statusMessage =
      isConfigured
      ? encryptionMessage(configuration) : "Choose a source folder and a destination folder."
    activities = await activityStore.entries()
    configureSourceMonitor(source)
  }

  private func configureSourceMonitor(_ source: URL?) {
    sourceMonitor = nil
    sourceLease = nil
    guard let source, let lease = SecurityScopeLease(url: source) else { return }
    sourceLease = lease
    sourceMonitor = SourceChangeMonitor(source: source) { [weak self] in
      Task { @MainActor [weak self] in self?.scheduleAutomaticEvent() }
    }
  }

  private func scheduleAutomaticEvent() {
    let preferenceUpdateTask = preferenceUpdateTask
    Task {
      await preferenceUpdateTask?.value
      await coordinator.automaticEvent()
    }
  }

  private func encryptionMessage(_ configuration: StoredConfiguration?) -> String {
    configuration?.acceptedUnencryptedVolume == true
      ? "Ready. Warning: the configured destination was not reported as encrypted."
      : "Ready. Connect the configured volume or sync now."
  }

  private func isFilesystemRoot(_ url: URL) -> Bool {
    url.standardizedFileURL.path == "/" || url.deletingLastPathComponent().path == url.path
  }

  private func openTestingWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Scoped Folder Mirror"
    window.contentView = NSHostingView(rootView: SetupView(model: self))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    testingWindow = window
  }

}
