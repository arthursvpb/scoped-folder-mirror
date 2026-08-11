import Foundation

struct TransactionLayout {
  let destination: URL
  let runName: String

  init(destination: URL, runName: String) throws {
    guard Self.isValidRunName(runName) else { throw SyncFailure.transactionRecoveryFailed }
    self.destination = destination.standardizedFileURL
    self.runName = runName
  }

  var current: URL { child("Current Mirror") }
  var archives: URL { child("Archive") }
  var archiveRun: URL { archives.appending(path: runName, directoryHint: .isDirectory) }
  var stagingRuns: URL { child(".staging") }
  var stagingRoot: URL { stagingRuns.appending(path: runName, directoryHint: .isDirectory) }
  var next: URL { stagingRoot.appending(path: "next", directoryHint: .isDirectory) }
  var pendingArchive: URL { stagingRoot.appending(path: "archive", directoryHint: .isDirectory) }
  var rollbackRuns: URL { child(".rollback") }
  var rollback: URL { rollbackRuns.appending(path: runName, directoryHint: .isDirectory) }
  var cleanupRuns: URL { child(".cleanup") }
  var cleanup: URL { cleanupRuns.appending(path: runName, directoryHint: .isDirectory) }
  var discardedCurrent: URL {
    cleanupRuns.appending(path: runName + "-discarded", directoryHint: .isDirectory)
  }
  var transactionStates: URL { child(".transactions") }
  var stateFile: URL { transactionStates.appending(path: runName + ".json") }

  static func isValidRunName(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy {
        $0.value == 45 || (48...57).contains($0.value) || (65...90).contains($0.value)
          || (97...122).contains($0.value)
      }
  }

  private func child(_ name: String) -> URL {
    destination.appending(path: name, directoryHint: .isDirectory)
  }
}
