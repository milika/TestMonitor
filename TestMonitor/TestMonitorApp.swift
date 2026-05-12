import SwiftUI

@main
struct TestMonitorApp: App {
  private let screenshotServer = ScreenshotServer(port: 7777)
  private let shellWrapper = ShellWrapperManager()

  @State private var suites: [TestRunState] = [
    TestRunState(
      suiteName: "SmartTube UI Tests",
      totalKnown: 155,
      logPath: "/tmp/smarttube-parallel-test.log",
      workerCount: 5,
      xcresultLogsDir: "~/Library/Developer/Xcode/DerivedData/SmartTube-dijhsbsrcshguoabqxncubrdhytc/Logs/Test"
    ),
    TestRunState(
      suiteName: "SmartTube Unit Tests",
      totalKnown: 374,
      logPath: "/tmp/smarttube-unit-full.log",
      workerCount: 1
    ),
  ]

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView(suites: suites)
        .onAppear {
          suites.forEach { $0.startWatching() }
          screenshotServer.setSuites { [suites] in suites }
          screenshotServer.start()
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
