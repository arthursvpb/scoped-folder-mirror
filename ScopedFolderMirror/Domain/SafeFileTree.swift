import Darwin
import Foundation

struct SafeFileTree: Sendable {
  private var fileManager: FileManager { .default }

  func removeTree(_ target: URL, inside parent: URL) throws {
    guard let targetType = try itemType(at: target) else { return }
    guard isDirectChild(target, of: parent), try isRealDirectory(parent) else {
      throw SyncFailure.transactionCleanupFailed
    }
    guard targetType == .typeDirectory else { throw SyncFailure.transactionCleanupFailed }
    try validateTree(target)
    try fileManager.removeItem(at: target)
  }

  func isRealDirectory(_ url: URL) throws -> Bool {
    try itemType(at: url) == .typeDirectory
  }

  func isRegularFile(_ url: URL) throws -> Bool {
    try itemType(at: url) == .typeRegular
  }

  func itemType(at url: URL) throws -> FileAttributeType? {
    var metadata = stat()
    let result = url.path.withCString { lstat($0, &metadata) }
    guard result == 0 else {
      guard errno == ENOENT || errno == ENOTDIR else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      return nil
    }
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFDIR): return .typeDirectory
    case mode_t(S_IFREG): return .typeRegular
    case mode_t(S_IFLNK): return .typeSymbolicLink
    case mode_t(S_IFSOCK): return .typeSocket
    case mode_t(S_IFBLK): return .typeBlockSpecial
    case mode_t(S_IFCHR): return .typeCharacterSpecial
    default: return .typeUnknown
    }
  }

  func directChildren(of root: URL) throws -> [URL] {
    guard let rootType = try itemType(at: root) else { return [] }
    guard rootType == .typeDirectory else { throw SyncFailure.transactionCleanupFailed }
    return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
  }

  private func validateTree(_ root: URL) throws {
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      throw SyncFailure.transactionCleanupFailed
    }
    while let entry = enumerator.nextObject() as? URL {
      guard entry.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
        throw SyncFailure.transactionCleanupFailed
      }
      let type = try fileManager.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
      guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
        throw SyncFailure.transactionCleanupFailed
      }
      if type == .typeSymbolicLink { enumerator.skipDescendants() }
    }
  }

  private func isDirectChild(_ target: URL, of parent: URL) -> Bool {
    target.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
  }
}
