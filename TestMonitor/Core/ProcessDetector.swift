import Foundation

/// Polls `pgrep` every 2 seconds to detect when an xcodebuild test run starts or ends.
final class ProcessDetector {
  private let grepPattern: String
  private let onStarted: () -> Void
  private let onEnded: () -> Void

  private var timer: Timer?
  private var wasRunning = false

  init(grepPattern: String, onStarted: @escaping () -> Void, onEnded: @escaping () -> Void) {
    self.grepPattern = grepPattern
    self.onStarted = onStarted
    self.onEnded = onEnded
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.check()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  // MARK: Private

  private func check() {
    let running = isProcessRunning()
    defer { wasRunning = running }
    if running && !wasRunning { onStarted() }
    else if !running && wasRunning { onEnded() }
  }

  private func isProcessRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", grepPattern]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
      try task.run()
      task.waitUntilExit()
      return task.terminationStatus == 0
    } catch {
      return false
    }
  }

  deinit { stop() }
}
