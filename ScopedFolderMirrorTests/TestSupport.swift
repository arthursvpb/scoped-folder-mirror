import Dispatch
import Foundation

@testable import ScopedFolderMirror

struct UnlimitedSpaceReader: FreeSpaceReading {
  func availableBytes(at url: URL) -> Int64? { Int64.max }
}

struct NoSpaceReader: FreeSpaceReading {
  func availableBytes(at url: URL) -> Int64? { 0 }
}

struct ImmediateSleeper: SyncSleeping {
  func sleep(for duration: Duration) async throws {}
}

struct FailingCopyAccess: CoordinatedFileAccessing {
  func digest(_ url: URL) throws -> String { try SystemCoordinatedFileAccess().digest(url) }
  func copy(from source: URL, to destination: URL) throws { throw SyncFailure.unexpected }
}

struct CorruptingCopyAccess: CoordinatedFileAccessing {
  func digest(_ url: URL) throws -> String { try SystemCoordinatedFileAccess().digest(url) }

  func copy(from source: URL, to destination: URL) throws {
    try Data("corrupted".utf8).write(to: destination)
  }
}

struct FailingArchiveCopyAccess: CoordinatedFileAccessing {
  func digest(_ url: URL) throws -> String { try SystemCoordinatedFileAccess().digest(url) }

  func copy(from source: URL, to destination: URL) throws {
    if source.path.contains("/Current Mirror/") { throw SyncFailure.unexpected }
    try SystemCoordinatedFileAccess().copy(from: source, to: destination)
  }
}

enum MoveFailureTarget: Sendable {
  case currentMirror
  case archiveRun
}

struct FailingMoveFileSystem: MirrorFileManaging {
  let target: MoveFailureTarget
  private let system = SystemMirrorFileManager()

  func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
  func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
  func createSymbolicLink(at url: URL, target: String) throws {
    try system.createSymbolicLink(at: url, target: target)
  }

  func moveItem(at source: URL, to destination: URL) throws {
    let shouldFail =
      target == .currentMirror
      ? destination.lastPathComponent == "Current Mirror" && source.lastPathComponent == "next"
      : destination.path.contains("/Archive/")
    if shouldFail { throw SyncFailure.unexpected }
    try system.moveItem(at: source, to: destination)
  }
}

struct BookmarkAccessFake: BookmarkDataAccessing {
  func create(for url: URL, readOnly: Bool) throws -> Data {
    Data("\(readOnly ? "read" : "write")|\(url.path)".utf8)
  }

  func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
    let value = String(decoding: data, as: UTF8.self)
    let path = value.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
    return (URL(filePath: path), false)
  }
}

struct StaleBookmarkAccessFake: BookmarkDataAccessing {
  func create(for url: URL, readOnly: Bool) throws -> Data { Data(url.path.utf8) }
  func resolve(_ data: Data) throws -> (url: URL, stale: Bool) { (URL(filePath: "/tmp"), true) }
}

struct FixedVolumeAssessor: VolumeAssessing {
  let assessment: VolumeAssessment
  func assess(_ destination: URL) throws -> VolumeAssessment { assessment }
}

struct SecurityScopeAccessFake: SecurityScopeAccessing {
  func startAccessing(_ url: URL) -> Bool { true }
  func stopAccessing(_ url: URL) {}
}

struct FailingMirrorExecutor: MirrorExecuting {
  func execute(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt {
    throw SyncFailure.verificationFailed
  }
}

struct SuccessfulMirrorExecutor: MirrorExecuting {
  func execute(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt {
    MirrorReceipt(
      fileCount: sourceManifest.regularFileCount,
      byteCount: sourceManifest.byteCount,
      archiveCreated: false
    )
  }
}

struct RecordingVolumeEjector: VolumeEjecting {
  let recordURL: URL

  func eject(_ volumeRoot: URL) throws {
    try Data(volumeRoot.path.utf8).write(to: recordURL)
  }
}

struct FailingVolumeEjector: VolumeEjecting {
  func eject(_ volumeRoot: URL) throws { throw SyncFailure.unexpected }
}

struct BlockingMirrorExecutor: MirrorExecuting {
  let started: DispatchSemaphore
  let resume: DispatchSemaphore

  func execute(
    source: URL,
    destination: URL,
    sourceManifest: SourceManifest,
    runName: String,
    mirrorID: UUID
  ) throws -> MirrorReceipt {
    started.signal()
    resume.wait()
    return MirrorReceipt(
      fileCount: sourceManifest.regularFileCount,
      byteCount: sourceManifest.byteCount,
      archiveCreated: false
    )
  }
}

func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func write(_ value: String, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(value.utf8).write(to: url)
}
