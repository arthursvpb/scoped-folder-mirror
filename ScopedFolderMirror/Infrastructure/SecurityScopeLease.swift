import Foundation

protocol SecurityScopeAccessing: Sendable {
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
}

struct SystemSecurityScopeAccess: SecurityScopeAccessing {
  func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
  func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

@MainActor
final class SecurityScopeLease {
  let url: URL
  private let active: Bool

  init?(url: URL) {
    self.url = url
    active = url.startAccessingSecurityScopedResource()
    guard active else { return nil }
  }

  deinit {
    if active { url.stopAccessingSecurityScopedResource() }
  }
}
