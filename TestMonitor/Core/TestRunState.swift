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
  var totalKnown: Int
  let logPath: String
  let workerCount: Int
  /// Optional: DerivedData `Logs/Test/` path for XCTest-based UI tests.
  /// When set, an `XCResultWatcher` is used instead of a plain `LogWatcher`.
  let xcresultLogsDir: String?

  var results: [TestResult] = []
  var startTime: Date?
  var endTime: Date?
  var isRunning: Bool = false
  var verdict: Verdict?
  var isDismissed: Bool = false
  var xcresultPath: String?

  private var logWatcher: LogWatcher?
  private var xcresultWatcher: XCResultWatcher?
  private var parser = TestResultParser()

  init(suiteName: String, totalKnown: Int, logPath: String, workerCount: Int = 1, xcresultLogsDir: String? = nil) {
    self.suiteName = suiteName
    self.totalKnown = totalKnown
    self.logPath = logPath
    self.workerCount = workerCount
    self.xcresultLogsDir = xcresultLogsDir
  }

  // MARK: Derived

  var passed: Int  { results.filter { $0.status == .passed  }.count }
  var failed: Int  { results.filter { $0.status == .failed  }.count }
  var skipped: Int { results.filter { $0.status == .skipped }.count }
  var completed: Int { results.count }

  var progressFraction: Double {
    guard totalKnown > 0 else { return 0 }
    return min(1.0, Double(completed) / Double(totalKnown))
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
    guard logWatcher == nil, xcresultWatcher == nil else { return }

    if let dir = xcresultLogsDir {
      let watcher = XCResultWatcher(logsDir: dir) { [weak self] chunk, workerIndex in
        DispatchQueue.main.async { self?.ingest(chunk: chunk, workerIndex: workerIndex) }
      }
      watcher.onStartDate = { [weak self] date in
        DispatchQueue.main.async {
          guard let self else { return }
          // Use the xcresult bundle timestamp as the authoritative start time only
          // if we don't already have a better (log-parsed) value.
          if self.startTime == nil || self.startTime! > date {
            self.startTime = date
            self.isRunning = true
          }
        }
      }
      xcresultWatcher = watcher
      watcher.start()
    }
    // Always also watch the main log file (unit tests / xcodebuild stdout)
    let watcher = LogWatcher(path: logPath) { [weak self] chunk in
      DispatchQueue.main.async { self?.ingest(chunk: chunk, workerIndex: 0) }
    }
    watcher.onTruncated = { [weak self] in
      self?.reset()
    }
    logWatcher = watcher
    watcher.start()
  }

  func stopWatching() {
    logWatcher?.stop()
    logWatcher = nil
    xcresultWatcher?.stop()
    xcresultWatcher = nil
  }

  func reset() {
    results = []
    startTime = nil
    endTime = nil
    isRunning = false
    verdict = nil
    isDismissed = false
    xcresultPath = nil
    parser = TestResultParser()
    // Restart xcresult watcher so it picks up the new xcresult bundle
    xcresultWatcher?.stop()
    xcresultWatcher = nil
    if let dir = xcresultLogsDir {
      let watcher = XCResultWatcher(logsDir: dir) { [weak self] chunk, workerIndex in
        DispatchQueue.main.async { self?.ingest(chunk: chunk, workerIndex: workerIndex) }
      }
      watcher.onStartDate = { [weak self] date in
        DispatchQueue.main.async {
          guard let self else { return }
          if self.startTime == nil || self.startTime! > date {
            self.startTime = date
            self.isRunning = true
          }
        }
      }
      xcresultWatcher = watcher
      watcher.start()
    }
  }

  // MARK: Private

  func ingest(chunk: String, workerIndex: Int = 0) {
    let newResults = parser.parse(chunk: chunk, workerIndex: workerIndex)

    // Prefer the date stamped in the log over wall-clock time.
    if startTime == nil, let parsed = parser.startDate {
      startTime = parsed
      isRunning = true
    } else if startTime == nil, !newResults.isEmpty {
      // Fallback: no suite-start timestamp found yet; use wall clock and keep
      // trying to get the real time from subsequent chunks.
      startTime = Date()
      isRunning = true
    } else if let parsed = parser.startDate, startTime != nil {
      // If we got a wall-clock fallback earlier but now have the real timestamp, fix it.
      if startTime! > parsed { startTime = parsed }
    }

    results.append(contentsOf: newResults)

    if let path = parser.xcresultPath, xcresultPath == nil {
      xcresultPath = path
    }

    // Use auto-detected total if available (Swift Testing reports exact count)
    if let detected = parser.detectedTotal {
      totalKnown = detected
    }

    // If we've seen more results than the hardcoded total, grow the total to match
    if completed > totalKnown {
      totalKnown = completed
    }

    if let v = parser.verdict, verdict == nil {
      // Only finalise if authoritative (** TEST SUCCEEDED/FAILED **) OR if
      // xcresult suite verdict AND the main log watcher has also stopped delivering.
      // Use authoritativeVerdict flag to avoid premature completion from inner suites.
      if parser.authoritativeVerdict {
        verdict = v
        endTime = parser.endDate ?? Date()
        isRunning = false
        // Unit tests (Swift Testing) don't emit a wall-clock timestamp; derive
        // startTime from the elapsed seconds reported in the run summary.
        if parser.startDate == nil, let elapsed = parser.elapsedSeconds {
          startTime = endTime!.addingTimeInterval(-elapsed)
        }
      }
    }
  }
}
