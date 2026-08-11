import Foundation

protocol DestinationCoordinating: Sendable {
  func coordinateWrite(at destination: URL, operation: (URL) throws -> Void) throws
}

struct SystemDestinationCoordinator: DestinationCoordinating {
  func coordinateWrite(at destination: URL, operation: (URL) throws -> Void) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var operationError: Error?
    coordinator.coordinate(
      writingItemAt: destination, options: .forMerging, error: &coordinationError
    ) {
      coordinatedDestination in
      do {
        try operation(coordinatedDestination)
      } catch {
        operationError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
  }
}
