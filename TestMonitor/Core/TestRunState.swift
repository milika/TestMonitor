import Foundation
import Observation

// MARK: - Types

enum TestStatus: Sendable {
  case passed, failed, skipped
}

enum Verdict: Sendable {
  case succeeded, failed
}

struct TestResult: Identifiable, Sendable {
  let id = UUID()
  let suite: String
  let name: String
  let status: TestStatus
  let duration: TimeInterval
  let workerIndex: Int  // 0 = unknown, 1–5 = parallel clone
}

// MARK: - State

@Observable
final class TestRunState: Identifiable {
  let id = UUID()
  let suiteName: String
  let totalKnown: Int
  let logPath: String
  let workerCount: Int

  var results: [TestResult] = []
  var startTime: Date?
  var endTime: Date?
  var isRunning: Bool = false
  var verdict: Verdict?
  var isDismissed: Bool = false

  private var logWatcher: LogWatcher?
  private var parser = TestResultParser()

  init(suiteName: String, totalKnown: Int, logPath: String, workerCount: Int = 1) {
    self.suiteName = suiteName
    self.totalKnown = totalKnown
    self.logPath = logPath
    self.workerCount = workerCount
  }

  // MARK: Derived

  var passed: Int  { results.filter { $0.status == .passed  }.count }
  var failed: Int  { results.filter { $0.status == .failed  }.count }
  var skipped: Int { results.filter { $0.status == .skipped }.count }
  var completed: Int { results.count }

  var progressFraction: Double {
    guard totalKnown > 0 else { return 0 }
    return Double(completed) / Double(totalKnown)
  }

  var eta: TimeInterval? {
    guard let start = startTime, completed >= 5 else { return nil }
    let elapsed = Date().timeIntervalSince(start)
    guard elapsed > 0 else { return nil }
    let rate = Double(completed) / elapsed
    guard rate > 0 else { return nil }
    return Double(totalKnown - completed) / rate
  }

  var perWorkerResults: [Int: [TestResult]] {
    Dictionary(grouping: results, by: \.workerIndex)
  }

  // MARK: Watching

  func startWatching() {
    guard logWatcher == nil else { return }
    let watcher = LogWatcher(path: logPath) { [weak self] chunk in
      DispatchQueue.main.async { self?.ingest(chunk: chunk) }
    }
    logWatcher = watcher
    watcher.start()
  }

  func stopWatching() {
    logWatcher?.stop()
    logWatcher = nil
  }

  func reset() {
    results = []
    startTime = nil
    endTime = nil
    isRunning = false
    verdict = nil
    isDismissed = false
    parser = TestResultParser()
  }

  // MARK: Private

  private func ingest(chunk: String) {
    let newResults = parser.parse(chunk: chunk)

    // Prefer the date stamped in the log over wall-clock time.
    if startTime == nil, let parsed = parser.startDate {
      startTime = parsed
      isRunning = true
    } else if startTime == nil && !newResults.isEmpty {
      startTime = Date()
      isRunning = true
    }

    results.append(contentsOf: newResults)

    if let v = parser.verdict, verdict == nil {
      verdict = v
      endTime = Date()
      isRunning = false
    }
  }
}
