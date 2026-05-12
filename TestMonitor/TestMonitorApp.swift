import SwiftUI

@main
struct TestMonitorApp: App {
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
