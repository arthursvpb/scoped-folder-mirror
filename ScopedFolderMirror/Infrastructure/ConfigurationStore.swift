import Foundation

enum BookmarkKind: String, CaseIterable, Sendable {
  case source
  case destination
}

protocol BookmarkDataAccessing: Sendable {
  func create(for url: URL, readOnly: Bool) throws -> Data
  func resolve(_ data: Data) throws -> (url: URL, stale: Bool)
}

struct SystemBookmarkDataAccess: BookmarkDataAccessing {
  func create(for url: URL, readOnly: Bool) throws -> Data {
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
    return try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return (url, stale)
  }
}

actor ConfigurationStore {
  private let defaults: UserDefaults
  private let bookmarkAccess: any BookmarkDataAccessing
  private let prefix = "scoped-folder-mirror."

  init(
    defaults: UserDefaults = .standard,
    bookmarkAccess: any BookmarkDataAccessing = SystemBookmarkDataAccess()
  ) {
    self.defaults = defaults
    self.bookmarkAccess = bookmarkAccess
  }

  func saveBookmark(_ url: URL, kind: BookmarkKind) throws {
    let data = try bookmarkAccess.create(for: url, readOnly: kind == .source)
    defaults.set(data, forKey: bookmarkKey(kind))
  }

  func resolveBookmark(_ kind: BookmarkKind) throws -> URL? {
    guard let data = defaults.data(forKey: bookmarkKey(kind)) else { return nil }
    let resolved = try bookmarkAccess.resolve(data)
    guard !resolved.stale else { throw SyncFailure.needsAuthorization }
    return resolved.url
  }

  func saveConfiguration(_ configuration: StoredConfiguration) throws {
    defaults.set(try JSONEncoder().encode(configuration), forKey: prefix + "configuration")
  }

  func configuration() throws -> StoredConfiguration? {
    guard let data = defaults.data(forKey: prefix + "configuration") else { return nil }
    return try JSONDecoder().decode(StoredConfiguration.self, from: data)
  }

  func ejectAfterSuccessfulSync() -> Bool {
    let key = prefix + "eject-after-successful-sync"
    guard defaults.object(forKey: key) != nil else { return true }
    return defaults.bool(forKey: key)
  }

  func setEjectAfterSuccessfulSync(_ enabled: Bool) {
    defaults.set(enabled, forKey: prefix + "eject-after-successful-sync")
  }

  func revoke(_ kind: BookmarkKind) {
    defaults.removeObject(forKey: bookmarkKey(kind))
    if kind == .destination { defaults.removeObject(forKey: prefix + "configuration") }
  }

  func reset() {
    for kind in BookmarkKind.allCases {
      defaults.removeObject(forKey: bookmarkKey(kind))
    }
    defaults.removeObject(forKey: prefix + "configuration")
    defaults.removeObject(forKey: prefix + "eject-after-successful-sync")
  }

  private func bookmarkKey(_ kind: BookmarkKind) -> String { prefix + "bookmark." + kind.rawValue }
}
