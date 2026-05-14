import SwiftUI

// MARK: - Notification name

extension NSNotification.Name {
  static let openMainWindow = NSNotification.Name("com.testmonitor.openMainWindow")
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var localMonitor: Any?
  private var globalMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // When launched by the XCUITest runner, LSUIElement (no Dock icon) prevents
    // the test framework from activating the app. Switch to regular policy so
    // XCUITest can bring the app to front and interact with it normally.
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
      NSApp.setActivationPolicy(.regular)
    }

    // Open the main window on double-click in the MenuBarExtra popup.
    // the receiving window (a) has no title bar and (b) its top edge sits within
    // ~40 pt of the screen top (i.e. just below the system menu bar).
    // A raw cursor-Y check (the previous approach) was too brittle because the
    // header area can be 24-35 pt below the screen top on different hardware.
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      if event.clickCount == 2, let window = event.window {
        let screenH = NSScreen.main?.frame.height ?? 0
        let isMenuBarPopup = !window.styleMask.contains(.titled)
                          && window.frame.maxY >= screenH - 40
        if isMenuBarPopup {
          AppDelegate.openMainWindow()
        }
      }
      return event
    }
    // Belt-and-suspenders: global monitor for clicks that occur in the system
    // status-bar area outside any app window (popup already dismissed).
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { event in
      if event.clickCount == 2 {
        let screenH = NSScreen.main?.frame.height ?? 0
        if NSEvent.mouseLocation.y >= screenH - 30 {
          DispatchQueue.main.async { AppDelegate.openMainWindow() }
        }
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let m = localMonitor  { NSEvent.removeMonitor(m) }
    if let m = globalMonitor { NSEvent.removeMonitor(m) }
  }

  /// Bring the main window forward, or reopen it if it was closed.
  /// When the window is gone, a notification is posted; MenuBarView
  /// (which always lives as long as the MenuBarExtra is visible) catches
  /// it and calls openWindow(id: "main").
  static func openMainWindow() {
    if let existing = NSApp.windows.first(where: {
      $0.styleMask.contains(.titled) && !($0 is NSPanel)
    }) {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      // Window was fully closed — signal MenuBarView to recreate it.
      NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }
  }
}

// MARK: - App

@main
struct TestMonitorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
#if DEBUG
  private let screenshotServer = ScreenshotServer(port: 7777)
#endif
  private let shellWrapper = ShellWrapperManager()

  @State private var suites: [TestRunState] = [
    TestRunState(
      suiteName: "SmartTube UI Tests",
      logPath: "/tmp/smarttube-parallel-test.log",
      workerCount: 5,
      schemeName: "SmartTube"         // auto-discovers DerivedData/SmartTube-*/Logs/Test
    ),
    TestRunState(
      suiteName: "SmartTube Unit Tests",
      logPath: "/tmp/smarttube-unit-full.log",
      workerCount: 1,
      schemeName: "SmartTubeTests"    // routed separately in the shim
    ),
  ]

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView(suites: suites)
        .onAppear {
          suites.forEach { $0.startWatching() }
          // Build shim routing table from suite config — no hardcoded paths in the script.
          let routes = suites.compactMap { s in
            s.schemeName.map { ShellWrapperManager.LogRoute(schemeName: $0, logPath: s.logPath) }
          }
          shellWrapper.configure(routes: routes, defaultLogPath: suites.first?.logPath ?? "/tmp/xcodebuild.log")
#if DEBUG
          screenshotServer.setSuites { [suites] in suites }
          screenshotServer.start()
#endif
        }
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 560, height: 500)

    MenuBarExtra {
      MenuBarView(suites: suites, shellWrapper: shellWrapper)
    } label: {
      MenuBarLabel(suites: suites)
    }
    .menuBarExtraStyle(.window)
  }
}
