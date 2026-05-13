import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var eventMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Open main window on double-click on the menu bar icon.
    // A local monitor sees events in our own windows, which includes the
    // invisible MenuBarExtra host window that sits in the menu bar.
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      if event.clickCount == 2 {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let clickY = event.window?.frame.origin.y ?? 0
        // Menu bar sits in the top ~30 pt of the screen.
        if clickY >= screenHeight - 30 {
          AppDelegate.openMainWindow()
        }
      }
      return event
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let m = eventMonitor { NSEvent.removeMonitor(m) }
  }

  static func openMainWindow() {
    if let existing = NSApp.windows.first(where: {
      $0.styleMask.contains(.titled) && !($0 is NSPanel)
    }) {
      existing.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
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
