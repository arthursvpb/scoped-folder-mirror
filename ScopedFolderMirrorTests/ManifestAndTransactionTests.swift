import XCTest

@testable import ScopedFolderMirror

final class ManifestAndTransactionTests: XCTestCase {
  func testManifestIncludesHiddenFilesAndPreservesSymlinkTargets() throws {
    let source = try makeTemporaryDirectory()
    try write("hidden", to: source.appending(path: ".hidden"))
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "link").path,
      withDestinationPath: ".hidden"
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: source.appending(path: ".hidden").path)
    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)

    let manifest = try SourceManifestBuilder().build(at: source)
    XCTAssertEqual(manifest.byPath[".hidden"]?.kind, .regularFile)
    XCTAssertEqual(manifest.byPath["link"]?.kind, .symbolicLink)
    XCTAssertEqual(manifest.byPath["link"]?.symbolicLinkTarget, ".hidden")
  }

  func testInitialMirrorCopiesNestedAndHiddenFiles() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("one", to: source.appending(path: "nested/file.txt"))
    try write("two", to: source.appending(path: ".hidden"))

    let receipt = try execute(source: source, destination: destination)

    XCTAssertEqual(receipt.fileCount, 2)
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/nested/file.txt")), "one")
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/.hidden")), "two")
  }

  func testReplacementAndRemovalAreArchived() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("old", to: source.appending(path: "changed.txt"))
    try write("removed", to: source.appending(path: "removed.txt"))
    _ = try execute(source: source, destination: destination, runName: "first")
    try write("new", to: source.appending(path: "changed.txt"))
    try FileManager.default.removeItem(at: source.appending(path: "removed.txt"))

    let receipt = try execute(source: source, destination: destination, runName: "second")

    XCTAssertTrue(receipt.archiveCreated)
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Archive/second/changed.txt")), "old")
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Archive/second/removed.txt")), "removed")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "Current Mirror/removed.txt").path))
  }

  func testNoSpaceLeavesCurrentMirrorUnchanged() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    try write("new", to: source.appending(path: "file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(freeSpace: NoSpaceReader())

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "no-space"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
  }

  func testCopyFailureLeavesCurrentMirrorUnchanged() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    try write("new", to: source.appending(path: "file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(
      fileAccess: FailingCopyAccess(), freeSpace: UnlimitedSpaceReader())

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "failure"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
  }

  func testHashMismatchLeavesCurrentMirrorUnchanged() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    try write("new", to: source.appending(path: "file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(
      fileAccess: CorruptingCopyAccess(), freeSpace: UnlimitedSpaceReader())

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "mismatch"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
  }

  func testArchiveCopyFailureLeavesCurrentMirrorUnchanged() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("new", to: source.appending(path: "file.txt"))
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(
      fileAccess: FailingArchiveCopyAccess(), freeSpace: UnlimitedSpaceReader())

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "archive"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
  }

  func testSwapFailureRestoresRollback() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("new", to: source.appending(path: "file.txt"))
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(
      freeSpace: UnlimitedSpaceReader(),
      fileSystem: FailingMoveFileSystem(target: .currentMirror)
    )

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "swap"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appending(path: ".rollback").path))
  }

  func testArchivePromotionFailureRestoresRollback() throws {
    let source = try makeTemporaryDirectory()
    let destination = try makeTemporaryDirectory()
    try write("new", to: source.appending(path: "file.txt"))
    try write("old", to: destination.appending(path: "Current Mirror/file.txt"))
    let manifest = try SourceManifestBuilder().build(at: source)
    let transaction = MirrorTransaction(
      freeSpace: UnlimitedSpaceReader(),
      fileSystem: FailingMoveFileSystem(target: .archiveRun)
    )

    XCTAssertThrowsError(
      try transaction.execute(
        source: source, destination: destination, sourceManifest: manifest, runName: "promotion"))
    XCTAssertEqual(
      try String(contentsOf: destination.appending(path: "Current Mirror/file.txt")), "old")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appending(path: ".rollback").path))
  }

  private func execute(source: URL, destination: URL, runName: String = "run") throws
    -> MirrorReceipt
  {
    let builder = SourceManifestBuilder()
    return try MirrorTransaction(freeSpace: UnlimitedSpaceReader()).execute(
      source: source,
      destination: destination,
      sourceManifest: builder.build(at: source),
      runName: runName
    )
  }
}
