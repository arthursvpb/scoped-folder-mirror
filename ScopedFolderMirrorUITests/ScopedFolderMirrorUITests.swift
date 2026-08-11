import XCTest

final class ScopedFolderMirrorUITests: XCTestCase {
  @MainActor
  func testFreshInstallShowsDisabledSyncAndBothPickers() {
    let app = launchApp()

    XCTAssertTrue(app.buttons["choose-source"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["choose-destination"].exists)
    XCTAssertFalse(app.buttons["sync-now"].isEnabled)
  }

  @MainActor
  func testDismissingFolderPickerKeepsAppRunning() {
    let app = launchApp()
    let sourceButton = app.buttons["choose-source"]
    XCTAssertTrue(sourceButton.waitForExistence(timeout: 3))

    sourceButton.click()
    let cancelButton = app.windows["open-panel"].buttons["CancelButton"]
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
    cancelButton.click()

    XCTAssertTrue(sourceButton.waitForExistence(timeout: 3))
    XCTAssertEqual(app.state, .runningForeground)
  }

  @MainActor
  private func launchApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
    app.launch()
    addTeardownBlock { app.terminate() }
    return app
  }
}
