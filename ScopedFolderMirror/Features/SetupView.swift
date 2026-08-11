import SwiftUI

@MainActor
struct SetupView: View {
  @ObservedObject var model: FolderMirrorViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      folderRow(title: "Source folder", label: model.sourceLabel, id: "choose-source") {
        model.chooseSource()
      }
      folderRow(
        title: "Destination folder", label: model.destinationLabel, id: "choose-destination"
      ) {
        model.chooseDestination()
      }
      controls
      status
      activity
      Divider()
      configurationActions
      appActions
    }
    .padding()
    .frame(width: 420)
    .alert("Destination is not reported as encrypted", isPresented: $model.showUnencryptedWarning) {
      Button("Cancel", role: .cancel) { model.rejectUnencryptedDestination() }
      Button("Use Anyway") { model.acceptUnencryptedDestination() }
    } message: {
      Text(
        "Files on this destination may be readable if the device is lost. The app will still restrict its own write access to the selected folder."
      )
    }
  }

  private var header: some View {
    HStack {
      Image(systemName: "externaldrive.badge.checkmark").font(.title2)
      Text("Scoped Folder Mirror").font(.headline)
      Spacer()
      Text(model.phase.rawValue.capitalized).foregroundStyle(.secondary)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading) {
      Toggle(
        "Pause automation",
        isOn: Binding(get: { model.automationPaused }, set: { model.setAutomationPaused($0) })
      )
      .disabled(!model.isConfigured)
      .accessibilityIdentifier("pause-automation")
      Toggle(
        "Launch at Login",
        isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
      )
      .accessibilityIdentifier("launch-at-login")
      Toggle(
        "Eject destination after successful sync",
        isOn: Binding(
          get: { model.ejectAfterSuccessfulSync },
          set: { model.setEjectAfterSuccessfulSync($0) }
        )
      )
      .accessibilityIdentifier("eject-after-sync")
      Button("Sync Now") { model.syncNow() }
        .disabled(!model.isConfigured)
        .accessibilityIdentifier("sync-now")
    }
  }

  private var status: some View {
    Text(model.statusMessage)
      .font(.callout)
      .foregroundStyle(model.statusMessage.contains("Warning") ? .orange : .primary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("status-message")
  }

  private var activity: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recent activity").font(.subheadline).fontWeight(.semibold)
      if model.activities.isEmpty {
        Text("No sync activity yet.").foregroundStyle(.secondary)
      } else {
        ForEach(model.activities.prefix(5)) { record in
          Text(FolderMirrorViewModel.message(for: record)).font(.caption)
        }
      }
    }
  }

  private var configurationActions: some View {
    HStack {
      Button("Revoke Source", role: .destructive) { model.revokeSource() }
      Button("Revoke Destination", role: .destructive) { model.revokeDestination() }
      Button("Reset All", role: .destructive) { model.resetAll() }
    }
  }

  private var appActions: some View {
    HStack {
      Button("About") { model.showAbout() }
      Spacer()
      Button("Quit") { model.quit() }.keyboardShortcut("q")
    }
  }

  private func folderRow(title: String, label: String, id: String, action: @escaping () -> Void)
    -> some View
  {
    HStack {
      VStack(alignment: .leading) {
        Text(title)
        Text(label).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button("Choose", action: action).accessibilityIdentifier(id)
    }
  }
}
