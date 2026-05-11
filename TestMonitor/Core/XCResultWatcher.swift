import Foundation

/// Watches a DerivedData `Logs/Test/` directory for active xcresult bundles,
/// automatically discovers all `StandardOutputAndStandardError.txt` files within
/// the Staging area, and streams their content as new lines are written.
///
/// This is required for XCTest-based UI tests: xcodebuild does NOT write per-test
/// pass/fail lines to its own stdout — they are only in these capture files inside
/// the xcresult bundle.
final class XCResultWatcher {

  /// Directory containing xcresult bundles, e.g.
  /// `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Logs/Test`
  let logsDir: String

  let onNewContent: (String, Int) -> Void  // chunk, workerIndex (1-based, 0 = unknown)
  /// Called (from the watcher's internal queue) when a new xcresult bundle is found
  /// whose directory name encodes a start timestamp. Dispatch to main as needed.
  var onStartDate: ((Date) -> Void)?
  /// Called (from the watcher's internal queue) when the watcher switches to a
  /// **different** xcresult bundle than the one it was previously tracking.
  /// Use this to clear stale state before the new run's results arrive.
  var onNewBundle: (() -> Void)?
  /// Called (from the watcher's internal queue) when a bundle is confirmed complete
  /// (no Staging directory present). Fires at most once per bundle path.
  /// Use this to trigger an authoritative `xcresulttool` parse.
  var onBundleComplete: ((String) -> Void)?

  private var activeXCResult: String = ""
  private var knownFiles: Set<String> = []
  private var fileWatchers: [String: LogWatcher] = [:]
  private var reportedCompleteBundles: Set<String> = []

  private var scanTimer: DispatchSourceTimer?
  private var dirSource: DispatchSourceFileSystemObject?
  private let queue = DispatchQueue(label: "com.testmonitor.xcresultwatcher", qos: .utility)

  // xcresult bundle name timestamp
  // e.g. Test-SmartTube-2026.05.11_15-57-21-+0200.xcresult
  private static let xcresultTimestampPattern = try! NSRegularExpression(
    pattern: #"(\d{4}\.\d{2}\.\d{2}_\d{2}-\d{2}-\d{2}-[+-]\d{4})"#
  )
  private static let xcresultDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy.MM.dd_HH-mm-ss-Z"
    return f
  }()

  init(logsDir: String, onNewContent: @escaping (String, Int) -> Void) {
    self.logsDir = (logsDir as NSString).expandingTildeInPath
    self.onNewContent = onNewContent
  }

  func start() {
    queue.async { [weak self] in
      self?.scan()
      self?.startScanTimer()
      self?.watchLogsDir()
    }
  }

  func stop() {
    scanTimer?.cancel()
    scanTimer = nil
    dirSource?.cancel()
    dirSource = nil
    fileWatchers.values.forEach { $0.stop() }
    fileWatchers.removeAll()
    knownFiles.removeAll()
    activeXCResult = ""
    reportedCompleteBundles.removeAll()
  }

  // MARK: - Private

  private func startScanTimer() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 5, repeating: 5)
    t.setEventHandler { [weak self] in self?.scan() }
    t.resume()
    scanTimer = t
  }

  /// Watch the Logs/Test directory itself so we react immediately when a new
  /// xcresult bundle appears (new test run started).
  private func watchLogsDir() {
    let fd = Darwin.open(logsDir, O_EVTONLY)
    guard fd != -1 else { return }

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: .write,
      queue: queue
    )
    src.setEventHandler { [weak self] in self?.scan() }
    src.setCancelHandler { Darwin.close(fd) }
    src.resume()
    dirSource = src
  }

  private func scan() {
    let fm = FileManager.default

    // Find all xcresult bundles, sorted newest-first (name = timestamp).
    guard let entries = try? fm.contentsOfDirectory(atPath: logsDir) else { return }
    let xcresults = entries.filter { $0.hasSuffix(".xcresult") }.sorted()
    guard let latest = xcresults.last else { return }

    let xcresultPath = "\(logsDir)/\(latest)"

    // If we've switched to a newer xcresult bundle, reset and start fresh.
    if xcresultPath != activeXCResult {
      fileWatchers.values.forEach { $0.stop() }
      fileWatchers.removeAll()
      knownFiles.removeAll()
      let isSwitch = !activeXCResult.isEmpty   // false on first scan, true on actual switch
      activeXCResult = xcresultPath
      if isSwitch {
        onNewBundle?()
      }
      // Parse the bundle directory name for the actual run start timestamp.
      if let startDate = parseStartDate(from: latest) {
        onStartDate?(startDate)
      }
    }

    // Staging dir is only present while the run is in progress.
    let stagingPath = "\(xcresultPath)/Staging"
    let stagingExists = fm.fileExists(atPath: stagingPath)

    // If staging is gone, the run is complete — fire onBundleComplete once.
    if !stagingExists && !reportedCompleteBundles.contains(xcresultPath) {
      reportedCompleteBundles.insert(xcresultPath)
      onBundleComplete?(xcresultPath)
    }

    guard let enumerator = fm.enumerator(atPath: stagingPath) else { return }

    for case let relPath as String in enumerator {
      guard relPath.hasSuffix("StandardOutputAndStandardError.txt") else { continue }
      let fullPath = "\(stagingPath)/\(relPath)"
      guard !knownFiles.contains(fullPath) else { continue }

      knownFiles.insert(fullPath)
      let worker = cloneNumber(from: fullPath)
      let watcher = LogWatcher(path: fullPath) { [weak self, worker] chunk in
        self?.onNewContent(chunk, worker)
      }
      fileWatchers[fullPath] = watcher
      watcher.start()
    }
  }

  /// Extract the start timestamp encoded in the xcresult bundle directory name.
  private func parseStartDate(from bundleName: String) -> Date? {
    let range = NSRange(bundleName.startIndex..., in: bundleName)
    guard let match = Self.xcresultTimestampPattern.firstMatch(in: bundleName, range: range),
          let r = Range(match.range(at: 1), in: bundleName) else { return nil }
    return Self.xcresultDateFormatter.date(from: String(bundleName[r]))
  }

  /// Read the first 2 KB of the file to find "Clone N of" in the xcodebuild header.
  private func cloneNumber(from filePath: String) -> Int {
    guard let handle = FileHandle(forReadingAtPath: filePath) else { return 0 }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 2048)
    guard let text = String(data: data, encoding: .utf8) else { return 0 }
    guard let regex = try? NSRegularExpression(pattern: #"Clone (\d+) of "#),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return 0 }
    return Int(String(text[range])) ?? 0
  }

  deinit { stop() }
}
