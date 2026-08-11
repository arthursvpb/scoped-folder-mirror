import Foundation

private struct OwnershipMarker: Codable, Equatable {
  let schemaVersion: Int
  let mirrorID: UUID
}

struct DestinationOwnership: Sendable {
  static let markerName = ".scoped-folder-mirror.json"
  private var fileManager: FileManager { .default }

  func prepare(_ destination: URL, expectedID: UUID? = nil) throws -> UUID {
    let contents = try visibleOwnershipContents(destination)
    if let marker = try readMarker(destination) {
      guard expectedID == nil || expectedID == marker.mirrorID else {
        throw SyncFailure.invalidDestination(.ownershipMismatch)
      }
      return marker.mirrorID
    }
    guard contents.isEmpty else { throw SyncFailure.invalidDestination(.foreignContents) }
    let mirrorID = expectedID ?? UUID()
    try writeMarker(OwnershipMarker(schemaVersion: 1, mirrorID: mirrorID), destination: destination)
    return mirrorID
  }

  func validate(_ destination: URL, mirrorID: UUID) throws {
    guard let marker = try readMarker(destination),
      marker == OwnershipMarker(schemaVersion: 1, mirrorID: mirrorID)
    else {
      throw SyncFailure.invalidDestination(.ownershipMismatch)
    }
  }

  private func visibleOwnershipContents(_ destination: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent != ".DS_Store" }
  }

  private func readMarker(_ destination: URL) throws -> OwnershipMarker? {
    let url = destination.appending(path: Self.markerName)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(OwnershipMarker.self, from: Data(contentsOf: url))
  }

  private func writeMarker(_ marker: OwnershipMarker, destination: URL) throws {
    let data = try JSONEncoder().encode(marker)
    try data.write(to: destination.appending(path: Self.markerName), options: .atomic)
  }
}
