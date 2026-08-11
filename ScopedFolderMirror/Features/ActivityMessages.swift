import Foundation

extension FolderMirrorViewModel {
  static func message(for record: ActivityRecord) -> String {
    switch record.code {
    case .succeeded: "Sync verified and the configured volume was ejected."
    case .succeededKeptMounted: "Sync verified. The configured volume remains mounted."
    case .succeededNotEjected: "Sync verified. Eject the configured volume manually."
    case .automationPaused: "Automation is paused."
    case .needsAuthorization: "Choose the source and destination folders again."
    case .sourceUnavailable:
      "The source is unavailable. The current mirror and archives were not modified."
    case .sourceChanging: "Source files are still changing. The current mirror was not modified."
    case .destinationUnavailable:
      "The configured external destination is unavailable or does not match."
    case .insufficientSpace:
      "The destination does not have enough free space for a safe transaction."
    case .unsupportedEntry: "The source contains an unsupported filesystem entry."
    case .verificationFailed: "Verification failed. The previous mirror was restored."
    case .transactionCleanupFailed:
      "Sync data is verified, but protected transaction cleanup could not finish."
    case .transactionRecoveryFailed:
      "Transaction recovery needs attention. The current mirror was not replaced."
    case .canceled: "Sync was canceled."
    case .unexpectedFailure: "Sync failed without changing the verified mirror."
    }
  }
}
