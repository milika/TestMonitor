import XCTest

/// UI tests for the "double-click MenuBarExtra popup header → open main window" feature.
final class MenuBarDoubleClickTests: XCTestCase {

  var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
    // Give the menu-bar extra time to appear in the status bar.
    Thread.sleep(forTimeInterval: 1.0)
  }

  override func tearDownWithError() throws {
    app.terminate()
  }

  // MARK: - Helpers

  /// Returns the MenuBarExtra status item (accessibility label = "TestMonitor").
  private var statusItem: XCUIElement {
    app.statusItems["TestMonitor"]
  }

  @discardableResult
  private func waitForMainWindow(timeout: TimeInterval = 4) -> Bool {
    app.windows["TestMonitor"].waitForExistence(timeout: timeout)
  }

  // MARK: - Tests

  /// Double-clicking the popup header while the main window is open should
  /// keep it visible / bring it to the foreground.
  func testDoubleClickHeaderKeepsMainWindowVisible() throws {
    XCTAssertTrue(waitForMainWindow(), "Main window must be present on launch")

    XCTAssertTrue(statusItem.waitForExistence(timeout: 3), "Status item not found")
    statusItem.click()

    let popup = app.windows.element(boundBy: 0)
    XCTAssertTrue(popup.waitForExistence(timeout: 2), "Popup window didn't appear")

    // Double-click the very top (tab-bar / drag-handle) area of the popup.
    popup.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).doubleClick()

    XCTAssertTrue(waitForMainWindow(), "Main window should remain visible after double-click")
  }

  /// Double-clicking the popup header after the main window was closed should
  /// reopen it.
  func testDoubleClickHeaderReopensClosedMainWindow() throws {
    let mainWindow = app.windows["TestMonitor"]
    XCTAssertTrue(mainWindow.waitForExistence(timeout: 3), "Main window must be present on launch")

    mainWindow.buttons[XCUIIdentifierCloseWindow].click()
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertFalse(mainWindow.exists, "Main window should be gone after closing")

    XCTAssertTrue(statusItem.waitForExistence(timeout: 3), "Status item not found")
    statusItem.click()

    let popup = app.windows.element(boundBy: 0)
    XCTAssertTrue(popup.waitForExistence(timeout: 2), "Popup window didn't appear")

    popup.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).doubleClick()

    XCTAssertTrue(
      waitForMainWindow(timeout: 4),
      "Main window should reopen after double-clicking popup header"
    )
  }
}
