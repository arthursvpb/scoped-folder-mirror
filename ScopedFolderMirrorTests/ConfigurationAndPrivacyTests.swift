import XCTest

@testable import ScopedFolderMirror

final class ConfigurationAndPrivacyTests: XCTestCase {
  func testBookmarksEncodeSourceAsReadOnlyAndDestinationAsWritable() async throws {
    let suite = "ScopedFolderMirrorTests.\(UUID().uuidString)"
    let store = ConfigurationStore(
      defaults: UserDefaults(suiteName: suite)!, bookmarkAccess: BookmarkAccessFake())
    try await store.saveBookmark(URL(filePath: "/source"), kind: .source)
    try await store.saveBookmark(URL(filePath: "/destination"), kind: .destination)
    let stored = UserDefaults(suiteName: suite)!

    XCTAssertEqual(
      String(decoding: stored.data(forKey: "scoped-folder-mirror.bookmark.source")!, as: UTF8.self),
      "read|/source")
    XCTAssertEqual(
      String(
        decoding: stored.data(forKey: "scoped-folder-mirror.bookmark.destination")!, as: UTF8.self),
      "write|/destination")
  }

  func testStaleBookmarkRequiresAuthorization() async throws {
    let suite = "ScopedFolderMirrorTests.\(UUID().uuidString)"
    let store = ConfigurationStore(
      defaults: UserDefaults(suiteName: suite)!, bookmarkAccess: StaleBookmarkAccessFake())
    try await store.saveBookmark(URL(filePath: "/source"), kind: .source)

    do {
      _ = try await store.resolveBookmark(.source)
      XCTFail("Expected stale bookmark rejection")
    } catch {
      XCTAssertEqual(error as? SyncFailure, .needsAuthorization)
    }
  }

  func testOwnershipMarkerContainsNoLocationOrIdentityData() throws {
    let destination = try makeTemporaryDirectory()
    let mirrorID = try DestinationOwnership().prepare(destination)
    let marker = try String(
      contentsOf: destination.appending(path: DestinationOwnership.markerName), encoding: .utf8)

    XCTAssertTrue(marker.contains(mirrorID.uuidString))
    XCTAssertFalse(marker.contains(destination.path))
    let object = try JSONSerialization.jsonObject(with: Data(marker.utf8)) as! [String: Any]
    XCTAssertEqual(Set(object.keys), ["schemaVersion", "mirrorID"])
  }

  func testUnrelatedNonemptyDestinationIsRejected() throws {
    let destination = try makeTemporaryDirectory()
    try write("existing", to: destination.appending(path: "unrelated.txt"))
    XCTAssertThrowsError(try DestinationOwnership().prepare(destination)) { error in
      XCTAssertEqual(error as? SyncFailure, .invalidDestination(.foreignContents))
    }
  }

  func testActivityRecordPersistsOnlyTypedFields() throws {
    let record = ActivityRecord(code: .verificationFailed, fileCount: 2, byteCount: 42)
    let object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    XCTAssertEqual(Set(object.keys), ["id", "timestamp", "code", "fileCount", "byteCount"])
  }

  func testSourceAndDestinationOverlapIsRejected() throws {
    let source = try makeTemporaryDirectory()
    let nestedDestination = source.appending(path: "mirror", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: nestedDestination, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try FolderRelationshipValidator().validate(source: source, destination: nestedDestination)
    ) { error in
      XCTAssertEqual(error as? SyncFailure, .invalidDestination(.overlapsSource))
    }
  }

  func testSiblingSourceAndDestinationAreAccepted() throws {
    let parent = try makeTemporaryDirectory()
    let source = parent.appending(path: "source", directoryHint: .isDirectory)
    let destination = parent.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    XCTAssertNoThrow(
      try FolderRelationshipValidator().validate(source: source, destination: destination))
  }
}
