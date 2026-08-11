import Foundation

final class SourceChangeMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let onChange: @Sendable () -> Void

  init(source: URL, onChange: @escaping @Sendable () -> Void) {
    presentedItemURL = source
    self.onChange = onChange
    super.init()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
    NSFileCoordinator.addFilePresenter(self)
  }

  func presentedItemDidChange() { onChange() }
  func presentedSubitemDidChange(at url: URL) { onChange() }

  deinit { NSFileCoordinator.removeFilePresenter(self) }
}
