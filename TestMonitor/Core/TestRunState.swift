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
  var isDismissed: Bool = false {
    didSet { Self.setDismissed(logPath: logPath, dismissed: isDismissed) }
  }
  var xcresultPath: String?

  private var logWatcher: LogWatcher?
  private var xcresultWatcher: XCResultWatcher?
  private var parser = TestResultParser()

  // MARK: Dismissed persistence

  private static let dismissedDefaultsKey = "com.testmonitor.dismissedLogPaths"

  private static func dismissedPaths() -> Set<String> {
    let arr = UserDefaults.standard.stringArray(forKey: dismissedDefaultsKey) ?? []
    return Set(arr)
  }

  private static func setDismissed(logPath: String, dismissed: Bool) {
    var paths = dismissedPaths()
    if dismissed { paths.insert(logPath) } else { paths.remove(logPath) }
    UserDefaults.standard.set(Array(paths), forKey: dismissedDefaultsKey)
  }

  init(suiteName: String, totalKnown: Int, logPath: String, workerCount: Int = 1, xcresultLogsDir: String? = nil) {
    self.suiteName = suiteName
    self.totalKnown = totalKnown
    self.logPath = logPath
    self.workerCount = workerCount
    self.xcresultLogsDir = xcresultLogsDir
    self.isDismissed = Self.dismissedPaths().contains(logPath)
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
      let watcher = makeXCResultWatcher(logsDir: dir)
      xcresultWatcher = watcher
      watcher.start()
    }

    // When xcresultLogsDir is set, the XCResultWatcher handles all test result
    // parsing. The LogWatcher is kept to:
    //   1. detect run restarts (truncation)
    //   2. extract "Executed N tests" count so totalKnown reflects the actual run size
    // Individual test results are NOT parsed from the log here to avoid double-counting.
    let onChunk: (String) -> Void = xcresultLogsDir == nil
      ? { [weak self] chunk in DispatchQueue.main.async { self?.ingest(chunk: chunk, workerIndex: 0) } }
      : { [weak self] chunk in DispatchQueue.main.async { self?.ingestCountOnly(chunk: chunk) } }

    let watcher = LogWatcher(path: logPath, onNewContent: onChunk)
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

  /// Clear all run state (results, times, verdict, parser) without touching the watchers.
  /// Called when the XCResultWatcher detects a new bundle mid-session.
  func resetState() {
    results = []
    startTime = nil
    endTime = nil
    isRunning = false
    verdict = nil
    isDismissed = false   // new run → clear persisted dismissal
    xcresultPath = nil
    parser = TestResultParser()
  }

  /// Full reset: clears state AND recreates the xcresult watcher.
  /// Called when the log is truncated (new xcodebuild invocation from scratch).
  func reset() {
    resetState()
    // Restart xcresult watcher so it picks up the new xcresult bundle
    xcresultWatcher?.stop()
    xcresultWatcher = nil
    if let dir = xcresultLogsDir {
      let watcher = makeXCResultWatcher(logsDir: dir)
      xcresultWatcher = watcher
      watcher.start()
    }
  }

  private func makeXCResultWatcher(logsDir: String) -> XCResultWatcher {
    let watcher = XCResultWatcher(logsDir: logsDir) { [weak self] chunk, workerIndex in
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
    watcher.onNewBundle = { [weak self] in
      DispatchQueue.main.async { self?.resetState() }
    }
    watcher.onBundleComplete = { [weak self] path in
      self?.applyXCResultTool(xcresultPath: path)
    }
    return watcher
  }

  // MARK: Private

  /// Shell out to xcresulttool and replace streaming estimates with authoritative data.
  /// Safe to call multiple times — idempotent (deduped by xcresultPath).
  private func applyXCResultTool(xcresultPath path: String) {
    Task {
      guard let parsed = await XCResultToolParser.parse(xcresultPath: path) else { return }
      await MainActor.run {
        // Replace results only if xcresulttool returned data for THIS bundle.
        // Guard against a race where a new run started before we finished parsing.
        if self.xcresultPath == nil || self.xcresultPath == path || !self.isRunning {
          // Build a lookup from the streaming results so we can re-apply their
          // worker indices onto the authoritative xcresulttool results (which
          // always come back with workerIndex == 0).
          var workerByKey: [String: Int] = [:]
          for r in self.results where r.workerIndex > 0 {
            workerByKey["\(r.suite)/\(r.name)"] = r.workerIndex
          }
          let merged = parsed.results.map { r -> TestResult in
            let key = "\(r.suite)/\(r.name)"
            let worker = workerByKey[key] ?? r.workerIndex
            return TestResult(suite: r.suite, name: r.name,
                              status: r.status, duration: r.duration,
                              workerIndex: worker)
          }
          self.results = merged
          self.totalKnown = parsed.totalCount
          self.verdict = parsed.verdict
          self.isRunning = false
          if self.xcresultPath == nil { self.xcresultPath = path }
          if self.endTime == nil { self.endTime = Date() }
        }
      }
    }
  }

  /// Lightweight ingestion for the main xcodebuild log when xcresultLogsDir is active.
  /// Only extracts "Executed N tests" count — does not parse individual results.
  private func ingestCountOnly(chunk: String) {
    let lines = chunk.components(separatedBy: "\n")
    for line in lines {
      // "         Executed 2 tests, with 2 tests skipped and 0 failures ..."
      guard line.contains("Executed"), line.contains("tests") else { continue }
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
      if parts.first == "Executed", let n = Int(parts[1]), n > 0 {
        if n > totalKnown || totalKnown == 155 { totalKnown = max(n, completed) }
      }
    }
  }

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
        // Trigger authoritative xcresulttool parse after a short delay to ensure
        // the bundle is fully flushed before we read it.
        if let cap = xcresultPath {
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.applyXCResultTool(xcresultPath: cap)
          }
        }
      }
    }
  }
}
