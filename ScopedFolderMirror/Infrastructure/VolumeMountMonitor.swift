import AppKit

@MainActor
final class VolumeMountMonitor {
  nonisolated(unsafe) private var observer: NSObjectProtocol?

  init(onMount: @escaping @Sendable () -> Void) {
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification,
      object: nil,
      queue: .main
    ) { _ in onMount() }
  }

  deinit {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }
}
