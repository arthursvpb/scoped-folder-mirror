import AppKit
import Foundation

@MainActor
final class FolderSelectionController {
  private var activePanel: NSOpenPanel?

  func selectFolder(prompt: String, canCreateDirectories: Bool) async -> URL? {
    await withCheckedContinuation { continuation in
      let panel = NSOpenPanel()
      panel.message = prompt
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = canCreateDirectories
      panel.allowsMultipleSelection = false
      activePanel = panel
      NSRunningApplication.current.activate()
      panel.begin { [weak self] response in
        defer { self?.activePanel = nil }
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
