import XCTest

@testable import ScopedFolderMirror

struct SnapshotSequenceFake: SourceSnapshotBuilding {
  let manifests: [SourceManifest]
  private let index = SnapshotIndex()

  func build(at root: URL) throws -> SourceManifest { index.next(from: manifests) }
}

private final class SnapshotIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next(from manifests: [SourceManifest]) -> SourceManifest {
    lock.lock()
    defer { lock.unlock() }
    let selected = manifests[min(value, manifests.count - 1)]
    value += 1
    return selected
  }
}

final class StabilityTests: XCTestCase {
  func testChangedSecondSnapshotIsRejected() async throws {
    let first = SourceManifest(entries: [entry(size: 1, date: Date(timeIntervalSince1970: 1))])
    let second = SourceManifest(entries: [entry(size: 2, date: Date(timeIntervalSince1970: 2))])
    let detector = StableSourceDetector(
      snapshotBuilder: SnapshotSequenceFake(manifests: [first, second]),
      sleeper: ImmediateSleeper(),
      interval: .zero
    )

    do {
      _ = try await detector.stableManifest(at: URL(filePath: "/source"))
      XCTFail("Expected changing source rejection")
    } catch {
      XCTAssertEqual(error as? SyncFailure, .sourceChanging)
    }
  }

  private func entry(size: Int64, date: Date) -> ManifestEntry {
    ManifestEntry(
      relativePath: "file.txt",
      kind: .regularFile,
      byteCount: size,
      allocatedByteCount: size,
      modificationDate: date,
      contentDigest: "digest-\(size)",
      symbolicLinkTarget: nil
    )
  }
}
