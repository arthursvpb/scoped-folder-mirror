import CryptoKit
import Foundation

enum ManifestEntryKind: String, Codable, Equatable, Sendable {
  case directory
  case regularFile
  case symbolicLink
}

struct ManifestEntry: Codable, Equatable, Sendable {
  let relativePath: String
  let kind: ManifestEntryKind
  let byteCount: Int64
  let allocatedByteCount: Int64
  let modificationDate: Date?
  let contentDigest: String?
  let symbolicLinkTarget: String?

  var contentIdentity: String {
    [kind.rawValue, String(byteCount), contentDigest ?? "", symbolicLinkTarget ?? ""].joined(
      separator: ":")
  }
}

struct SourceManifest: Equatable, Sendable {
  let entries: [ManifestEntry]

  var byPath: [String: ManifestEntry] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
  }
  var regularFileCount: Int { entries.filter { $0.kind == .regularFile }.count }
  var byteCount: Int64 { entries.reduce(0) { $0 + $1.byteCount } }
  var allocatedByteCount: Int64 { entries.reduce(0) { $0 + $1.allocatedByteCount } }

  func hasSameContent(as other: SourceManifest) -> Bool {
    let left = byPath.mapValues(\.contentIdentity)
    let right = other.byPath.mapValues(\.contentIdentity)
    return left == right
  }
}

protocol CoordinatedFileAccessing: Sendable {
  func digest(_ url: URL) throws -> String
  func copy(from source: URL, to destination: URL) throws
}

struct SystemCoordinatedFileAccess: CoordinatedFileAccessing {
  func digest(_ url: URL) throws -> String {
    try coordinateRead(url) { coordinatedURL in
      let handle = try FileHandle(forReadingFrom: coordinatedURL)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  func copy(from source: URL, to destination: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var copyResult: Result<Void, Error> = .failure(SyncFailure.unexpected)
    coordinator.coordinate(
      readingItemAt: source,
      options: [],
      writingItemAt: destination,
      options: .forReplacing,
      error: &coordinationError
    ) { readableURL, writableURL in
      copyResult = Result { try FileManager.default.copyItem(at: readableURL, to: writableURL) }
    }
    if let coordinationError { throw coordinationError }
    try copyResult.get()
  }

  private func coordinateRead<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var result: Result<T, Error> = .failure(SyncFailure.unexpected)
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinatedURL in
      result = Result { try operation(coordinatedURL) }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }
}

protocol SourceSnapshotBuilding: Sendable {
  func build(at root: URL) throws -> SourceManifest
}

struct SourceManifestBuilder: SourceSnapshotBuilding {
  private var fileManager: FileManager { .default }
  private let fileAccess: any CoordinatedFileAccessing

  init(fileAccess: any CoordinatedFileAccessing = SystemCoordinatedFileAccess()) {
    self.fileAccess = fileAccess
  }

  func build(at root: URL) throws -> SourceManifest {
    guard isReadableDirectory(root) else { throw SyncFailure.sourceUnavailable }
    let normalizedRoot = root.standardizedFileURL
    var traversalFailed = false
    guard
      let enumerator = fileManager.enumerator(
        at: normalizedRoot,
        includingPropertiesForKeys: resourceKeys,
        options: [],
        errorHandler: { _, _ in
          traversalFailed = true
          return false
        }
      )
    else {
      throw SyncFailure.sourceUnavailable
    }
    var entries: [ManifestEntry] = []
    do {
      while let url = enumerator.nextObject() as? URL {
        entries.append(try entry(for: url, root: normalizedRoot, enumerator: enumerator))
      }
    } catch let failure as SyncFailure {
      throw failure
    } catch {
      throw SyncFailure.sourceUnavailable
    }
    guard !traversalFailed, isReadableDirectory(root) else {
      throw SyncFailure.sourceUnavailable
    }
    return SourceManifest(entries: entries.sorted { $0.relativePath < $1.relativePath })
  }

  private func isReadableDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue && fileManager.isReadableFile(atPath: url.path)
  }

  private var resourceKeys: [URLResourceKey] { [.fileAllocatedSizeKey] }

  private func entry(for url: URL, root: URL, enumerator: FileManager.DirectoryEnumerator) throws
    -> ManifestEntry
  {
    let relativePath = try relativePath(for: url, root: root)
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let type = attributes[.type] as? FileAttributeType
    let modificationDate = attributes[.modificationDate] as? Date
    if type == .typeSymbolicLink {
      enumerator.skipDescendants()
      return ManifestEntry(
        relativePath: relativePath,
        kind: .symbolicLink,
        byteCount: 0,
        allocatedByteCount: 0,
        modificationDate: modificationDate,
        contentDigest: nil,
        symbolicLinkTarget: try fileManager.destinationOfSymbolicLink(atPath: url.path)
      )
    }
    if type == .typeDirectory {
      return directoryEntry(relativePath, modificationDate: modificationDate)
    }
    guard type == .typeRegular else { throw SyncFailure.unsupportedEntry(relativePath) }
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let resourceValues = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
    return ManifestEntry(
      relativePath: relativePath,
      kind: .regularFile,
      byteCount: byteCount,
      allocatedByteCount: Int64(resourceValues.fileAllocatedSize ?? Int(byteCount)),
      modificationDate: modificationDate,
      contentDigest: try fileAccess.digest(url),
      symbolicLinkTarget: nil
    )
  }

  private func directoryEntry(_ relativePath: String, modificationDate: Date?) -> ManifestEntry {
    ManifestEntry(
      relativePath: relativePath,
      kind: .directory,
      byteCount: 0,
      allocatedByteCount: 0,
      modificationDate: modificationDate,
      contentDigest: nil,
      symbolicLinkTarget: nil
    )
  }

  private func relativePath(for url: URL, root: URL) throws -> String {
    let canonicalRoot = root.resolvingSymlinksInPath().path
    let canonicalURL = url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appending(path: url.lastPathComponent).path
    let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
    guard canonicalURL.hasPrefix(prefix) else {
      throw SyncFailure.unsupportedEntry(url.lastPathComponent)
    }
    return String(canonicalURL.dropFirst(prefix.count))
  }
}
