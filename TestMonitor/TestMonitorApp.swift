import SwiftUI

@main
struct TestMonitorApp: App {
  @State private var suites: [TestRunState] = [
    TestRunState(
      suiteName: "SmartTube UI Tests",
      totalKnown: 101,
      logPath: "/tmp/smarttube-parallel-test.log",
      workerCount: 5
    ),
    TestRunState(
      suiteName: "SmartTube Unit Tests",
      totalKnown: 57,
      logPath: "/tmp/smarttube-unit-tests.log",
      workerCount: 1
    ),
  ]

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView(suites: suites)
        .onAppear {
          suites.forEach { $0.startWatching() }
        }
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 560, height: 500)

    MenuBarExtra {
      MenuBarView(suites: suites)
    } label: {
      MenuBarLabel(suites: suites)
    }
    .menuBarExtraStyle(.window)
  }
}
