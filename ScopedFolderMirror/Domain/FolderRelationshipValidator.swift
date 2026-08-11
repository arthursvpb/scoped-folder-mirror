import Foundation

struct FolderRelationshipValidator: Sendable {
  func validate(source: URL, destination: URL) throws {
    let sourcePath = normalizedDirectoryPath(source)
    let destinationPath = normalizedDirectoryPath(destination)
    guard !sourcePath.hasPrefix(destinationPath), !destinationPath.hasPrefix(sourcePath) else {
      throw SyncFailure.invalidDestination(.overlapsSource)
    }
  }

  private func normalizedDirectoryPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
  }
}
