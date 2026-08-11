import Foundation

enum SyncPhase: String, Codable, Equatable, Sendable {
  case unconfigured
  case awaitingVolume
  case debouncing
  case checking
  case copying
  case verifying
  case ejecting
  case succeeded
  case failed
}

enum ActivityCode: String, Codable, Equatable, Sendable {
  case succeeded
  case succeededNotEjected
  case automationPaused
  case needsAuthorization
  case sourceChanging
  case destinationUnavailable
  case insufficientSpace
  case unsupportedEntry
  case verificationFailed
  case canceled
  case unexpectedFailure
}

struct ActivityRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let timestamp: Date
  let code: ActivityCode
  let fileCount: Int
  let byteCount: Int64

  init(code: ActivityCode, fileCount: Int = 0, byteCount: Int64 = 0, timestamp: Date = .now) {
    id = UUID()
    self.timestamp = timestamp
    self.code = code
    self.fileCount = fileCount
    self.byteCount = byteCount
  }
}

struct VolumeIdentity: Codable, Equatable, Sendable {
  let uuid: String
}

struct StoredConfiguration: Codable, Equatable, Sendable {
  let volume: VolumeIdentity
  let mirrorID: UUID
  let acceptedUnencryptedVolume: Bool
}

enum SyncFailure: Error, Equatable, Sendable {
  case needsAuthorization
  case sourceChanging
  case invalidDestination(DestinationProblem)
  case insufficientSpace
  case unsupportedEntry(String)
  case verificationFailed
  case canceled
  case unexpected
}

enum DestinationProblem: String, Codable, Equatable, Sendable {
  case unavailable
  case notDedicatedFolder
  case notExternal
  case notWritable
  case wrongVolume
  case overlapsSource
  case foreignContents
  case ownershipMismatch
}

struct MirrorReceipt: Equatable, Sendable {
  let fileCount: Int
  let byteCount: Int64
  let archiveCreated: Bool
}
