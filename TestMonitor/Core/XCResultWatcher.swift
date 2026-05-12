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
  private var reportedCompleteBundles: Set<String> = []  /// Auto-incrementing index used as last-resort worker assignment when the
  /// clone number cannot be extracted from the path or file content.
  private var nextWorkerIndex: Int = 1
  private var scanTimer: DispatchSourceTimer?
  private var dirSource: DispatchSourceFileSystemObject?
  /// Watches the active xcresult bundle directory so Staging removal (run end)
  /// triggers an immediate scan rather than waiting for the next timer tick.
  private var bundleDirSource: DispatchSourceFileSystemObject?
  private var bundleDirFd: Int32 = -1
  /// Timestamp of the last worker file write — used for crash detection.
  private var lastWorkerActivityDate: Date?
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
    bundleDirSource?.cancel()
    bundleDirSource = nil
    if bundleDirFd != -1 { Darwin.close(bundleDirFd); bundleDirFd = -1 }
    fileWatchers.values.forEach { $0.stop() }
    fileWatchers.removeAll()
    knownFiles.removeAll()
    activeXCResult = ""
    reportedCompleteBundles.removeAll()
  }

  // MARK: - Private

  private func startScanTimer() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1, repeating: 2)
    t.setEventHandler { [weak self] in self?.scan() }
    t.resume()
    scanTimer = t
  }

  /// Watch the active xcresult bundle directory directly so we detect Staging
  /// removal (= run completed) immediately via kernel event, not via timer.
  private func watchBundleDir(_ path: String) {
    // Cancel any previously watched bundle dir.
    bundleDirSource?.cancel()
    bundleDirSource = nil
    if bundleDirFd != -1 { Darwin.close(bundleDirFd); bundleDirFd = -1 }

    let fd = Darwin.open(path, O_EVTONLY)
    guard fd != -1 else { return }
    bundleDirFd = fd

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete],
      queue: queue
    )
    src.setEventHandler { [weak self] in self?.scan() }
    src.setCancelHandler { Darwin.close(fd) }
    src.resume()
    bundleDirSource = src
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
      nextWorkerIndex = 1
      let isSwitch = !activeXCResult.isEmpty   // false on first scan, true on actual switch
      activeXCResult = xcresultPath
      // Watch the bundle directory for immediate Staging-removal detection.
      watchBundleDir(xcresultPath)
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

    // Crash/kill fallback: Staging still exists but xcodebuild is no longer
    // running AND we have seen worker files AND activity has been silent for
    // at least 30 seconds → treat as complete.
    // Use on-disk file mtimes so this also fires on app restart after a crash.
    if stagingExists
        && !reportedCompleteBundles.contains(xcresultPath)
        && !knownFiles.isEmpty
        && !isXcodebuildRunning()
        && mostRecentWorkerActivity() > 30 {
      reportedCompleteBundles.insert(xcresultPath)
      onBundleComplete?(xcresultPath)
    }

    guard let enumerator = fm.enumerator(atPath: stagingPath) else { return }

    for case let relPath as String in enumerator {
      guard relPath.hasSuffix("StandardOutputAndStandardError.txt") else { continue }
      let fullPath = "\(stagingPath)/\(relPath)"
      guard !knownFiles.contains(fullPath) else { continue }

      knownFiles.insert(fullPath)
      let worker = cloneNumberFromPath(fullPath)
                ?? cloneNumber(from: fullPath)
                ?? nextWorkerIndex
      nextWorkerIndex += 1
      lastWorkerActivityDate = Date()
      let watcher = LogWatcher(path: fullPath) { [weak self, worker] chunk in
        self?.lastWorkerActivityDate = Date()
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

  /// Returns true if any xcodebuild test process is currently running.
  private func isXcodebuildRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "xcodebuild.*test"]
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

  /// Seconds since any known worker file was last modified.
  /// Falls back to `lastWorkerActivityDate` for files written during this session.
  /// Returns 0 if no worker files are known.
  private func mostRecentWorkerActivity() -> TimeInterval {
    // First check in-memory date (updated as content arrives)
    if let d = lastWorkerActivityDate {
      return Date().timeIntervalSince(d)
    }
    // On startup the in-memory date is nil — check actual file mtimes on disk.
    let mtimes = knownFiles.compactMap { path -> Date? in
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      return attrs?[.modificationDate] as? Date
    }
    guard let newest = mtimes.max() else { return 0 }
    return Date().timeIntervalSince(newest)
  }

  /// Try to extract "Clone N of" from the file PATH (directory names in the
  /// xcresult Staging area include the clone label, e.g.
  /// "…/Clone 2 of iPhone 17-UUID/…").
  private func cloneNumberFromPath(_ path: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: #"Clone (\d+) of "#),
          let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
          let range = Range(match.range(at: 1), in: path),
          let n = Int(String(path[range])), n > 0 else { return nil }
    return n
  }

  /// Read the first 2 KB of the file to find "Clone N of" in the xcodebuild header.
  private func cloneNumber(from filePath: String) -> Int? {
    guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 2048)
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"Clone (\d+) of "#),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text),
          let n = Int(String(text[range])), n > 0 else { return nil }
    return n
  }

  deinit { stop() }
}
