import SwiftUI

@main
struct ScopedFolderMirrorApp: App {
  @StateObject private var model = FolderMirrorViewModel()

  var body: some Scene {
    MenuBarExtra("Scoped Folder Mirror", systemImage: "externaldrive.badge.checkmark") {
      SetupView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
