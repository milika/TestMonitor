import Foundation

/// Incrementally parses xcodebuild output, extracting test results line by line.
/// Handles two formats:
///   • xcodebuild parallel UI tests  — "Test case 'Suite.test()' passed on 'Clone N of …' (X.XXX seconds)"
///   • Swift Testing unit tests      — "✔ Test "name" passed after X.XXX seconds."
final class TestResultParser {
  private var remainder = ""
  private(set) var verdict: Verdict?
  private(set) var authoritativeVerdict: Bool = false  // true only when set by ** TEST SUCCEEDED/FAILED **
  private(set) var startDate: Date?
  private(set) var endDate: Date?
  private(set) var detectedTotal: Int?
  private(set) var elapsedSeconds: Double?
  private(set) var xcresultPath: String?
  private var nextLineIsXcresult = false

  // MARK: - Patterns

  // UI tests (xcodebuild parallel output)
  // Test case 'Suite.testFunc()' passed on 'Clone 2 of iPhone 17 - …' (11.820 seconds)
  private static let uiCasePattern = try! NSRegularExpression(
    pattern: #"^Test case '(\w+)\.(\w+)\(\)' (passed|failed|skipped) on 'Clone (\d+) of [^']+' \((\d+\.\d+) seconds\)"#
  )

  // XCTest runner output (inside StandardOutputAndStandardError.txt in xcresult bundle)
  // Test Case '-[SmartTubeUITests.ChannelViewUITests testAllFilterRestoresFeed]' passed (39.289 seconds).
  // Test Case '-[SmartTubeUITests.ChannelViewUITests testAllFilterRestoresFeed]' failed (39.289 seconds).
  private static let xcTestCasePattern = try! NSRegularExpression(
    pattern: #"^Test Case '-\[\w+\.(\w+) (\w+)\]' (passed|failed|skipped) \((\d+\.\d+) seconds\)"#
  )

  // XCTest suite pass/fail — captures timestamp too
  // Test Suite 'SmartTubeUITests' passed at 2026-05-11 15:14:50.053.
  private static let xcTestSuiteVerdictPattern = try! NSRegularExpression(
    pattern: #"^Test Suite '\S+' (passed|failed) at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)"#
  )

  // UI tests verdict
  private static let uiSucceededPattern = try! NSRegularExpression(pattern: #"\*\* TEST SUCCEEDED \*\*"#)
  private static let uiFailedPattern    = try! NSRegularExpression(pattern: #"\*\* TEST FAILED \*\*"#)

  // Swift Testing — quoted test name
  // ✔ Test "readable name" passed after 0.034 seconds.
  // ✘ Test "readable name" failed after 0.034 seconds.
  private static let unitNamedPattern = try! NSRegularExpression(
    pattern: #"^. Test "([^"]+)" (passed|failed) after (\d+\.\d+) seconds\."#
  )

  // Swift Testing — function-style test name (no quotes)
  // ✔ Test funcName() passed after 0.034 seconds.
  private static let unitFuncPattern = try! NSRegularExpression(
    pattern: #"^. Test (\w+)\(\) (passed|failed) after (\d+\.\d+) seconds\."#
  )

  // Swift Testing — run summary (gives total count + overall verdict + elapsed)
  // ✔ Test run with 304 tests in 41 suites passed after 3.535 seconds.
  // ✘ Test run with 304 tests in 41 suites failed after 3.535 seconds.
  private static let testRunSummaryPattern = try! NSRegularExpression(
    pattern: #"^. Test run with (\d+) tests in \d+ suites (passed|failed) after (\d+\.\d+) seconds\."#
  )

  // XCTest executed summary — gives actual test count for the run
  // "         Executed 2 tests, with 2 tests skipped and 0 failures (0 unexpected) in 46.500 (46.504) seconds"
  private static let xcTestExecutedPattern = try! NSRegularExpression(
    pattern: #"Executed (\d+) tests?, with"#
  )

  // xcresult path — appears on the line after the label
  // Test session results, code coverage, and logs:
  //         /path/to/Run.xcresult
  private static let xcresultLabelPattern = try! NSRegularExpression(
    pattern: #"Test session results, code coverage, and logs"#
  )

  // Start timestamp (xcodebuild format)
  // Test Suite 'SmartTubeUITests' started at 2026-05-11 12:34:56.789
  private static let suiteStartPattern = try! NSRegularExpression(
    pattern: #"Test [Ss]uite '.*' started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)"#
  )
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  // MARK: - Public

  func parse(chunk: String, workerIndex: Int = 0) -> [TestResult] {
    remainder += chunk
    let lines = remainder.components(separatedBy: "\n")
    remainder = lines.last ?? ""

    var results: [TestResult] = []
    for line in lines.dropLast() {
      if startDate == nil { parseStartDate(from: line) }
      parseXcresultPath(from: line)
      if let r = parseUITestCase(from: line)                   { results.append(r) }
      else if let r = parseXCTestCase(from: line, workerIndex: workerIndex) { results.append(r) }
      else if let r = parseUnitTest(from: line)                { results.append(r) }
      checkVerdict(in: line)
    }
    return results
  }

  // MARK: - Private

  private func parseStartDate(from line: String) {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.suiteStartPattern.firstMatch(in: line, range: range) else { return }
    startDate = Self.dateFormatter.date(from: substring(line, match: match, group: 1))
  }

  private func parseXcresultPath(from line: String) {
    if nextLineIsXcresult {
      nextLineIsXcresult = false
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasSuffix(".xcresult") {
        xcresultPath = trimmed
      }
      return
    }
    let range = NSRange(line.startIndex..., in: line)
    if Self.xcresultLabelPattern.firstMatch(in: line, range: range) != nil {
      nextLineIsXcresult = true
    }
  }

  private func parseUITestCase(from line: String) -> TestResult? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.uiCasePattern.firstMatch(in: line, range: range) else { return nil }

    let suite  = substring(line, match: match, group: 1)
    let name   = substring(line, match: match, group: 2)
    let status = parseStatus(substring(line, match: match, group: 3))
    let worker = Int(substring(line, match: match, group: 4)) ?? 0
    let dur    = Double(substring(line, match: match, group: 5)) ?? 0

    return TestResult(suite: suite, name: name, status: status, duration: dur, workerIndex: worker)
  }

  // XCTest format from StandardOutputAndStandardError.txt inside xcresult bundle
  // Test Case '-[Module.Suite method]' passed (9.839 seconds).
  private func parseXCTestCase(from line: String, workerIndex: Int) -> TestResult? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.xcTestCasePattern.firstMatch(in: line, range: range) else { return nil }

    let suite  = substring(line, match: match, group: 1)
    let name   = substring(line, match: match, group: 2)
    let status = parseStatus(substring(line, match: match, group: 3))
    let dur    = Double(substring(line, match: match, group: 4)) ?? 0

    return TestResult(suite: suite, name: name, status: status, duration: dur, workerIndex: workerIndex)
  }

  private func parseUnitTest(from line: String) -> TestResult? {
    let range = NSRange(line.startIndex..., in: line)

    // Skip run-level summary lines — handled in checkVerdict
    if Self.testRunSummaryPattern.firstMatch(in: line, range: range) != nil { return nil }

    if let match = Self.unitNamedPattern.firstMatch(in: line, range: range) {
      let name   = substring(line, match: match, group: 1)
      let status = parseStatus(substring(line, match: match, group: 2))
      let dur    = Double(substring(line, match: match, group: 3)) ?? 0
      return TestResult(suite: "UnitTests", name: name, status: status, duration: dur, workerIndex: 0)
    }

    if let match = Self.unitFuncPattern.firstMatch(in: line, range: range) {
      let name   = substring(line, match: match, group: 1)
      let status = parseStatus(substring(line, match: match, group: 2))
      let dur    = Double(substring(line, match: match, group: 3)) ?? 0
      return TestResult(suite: "UnitTests", name: name, status: status, duration: dur, workerIndex: 0)
    }

    return nil
  }

  private func checkVerdict(in line: String) {
    let range = NSRange(line.startIndex..., in: line)

    // XCTest "Executed N tests" — update detectedTotal (pick largest seen, i.e. outermost suite)
    if let match = Self.xcTestExecutedPattern.firstMatch(in: line, range: range) {
      let n = Int(substring(line, match: match, group: 1)) ?? 0
      if detectedTotal == nil || n > (detectedTotal ?? 0) { detectedTotal = n }
    }

    // ** TEST SUCCEEDED/FAILED ** are the most authoritative signals — check them
    // BEFORE the `guard verdict == nil` so they fire even if a tentative verdict
    // was already set by an inner "Test Suite ... failed/passed" line.
    if Self.uiSucceededPattern.firstMatch(in: line, range: range) != nil {
      verdict = .succeeded
      authoritativeVerdict = true
      return
    }
    if Self.uiFailedPattern.firstMatch(in: line, range: range) != nil {
      verdict = .failed
      authoritativeVerdict = true
      return
    }

    guard verdict == nil else { return }

    // Swift Testing summary carries total count, verdict, and elapsed seconds
    if let match = Self.testRunSummaryPattern.firstMatch(in: line, range: range) {
      detectedTotal = Int(substring(line, match: match, group: 1))
      verdict = substring(line, match: match, group: 2) == "passed" ? .succeeded : .failed
      elapsedSeconds = Double(substring(line, match: match, group: 3))
      authoritativeVerdict = true
      return
    }

    // XCTest "Executed N tests" — update detectedTotal (pick largest seen, i.e. outermost suite)
    if let match = Self.xcTestExecutedPattern.firstMatch(in: line, range: range) {
      let n = Int(substring(line, match: match, group: 1)) ?? 0
      if detectedTotal == nil || n > (detectedTotal ?? 0) { detectedTotal = n }
    }

    if let match = Self.xcTestSuiteVerdictPattern.firstMatch(in: line, range: range) {
      // Capture endDate from every suite-end line (last one wins = outermost suite).
      endDate = Self.dateFormatter.date(from: substring(line, match: match, group: 2))
      verdict = substring(line, match: match, group: 1) == "passed" ? .succeeded : .failed
    }
  }

  private func parseStatus(_ s: String) -> TestStatus {
    switch s {
    case "passed": return .passed
    case "failed": return .failed
    default:       return .skipped
    }
  }

  private func substring(_ string: String, match: NSTextCheckingResult, group: Int) -> String {
    guard let range = Range(match.range(at: group), in: string) else { return "" }
    return String(string[range])
  }
}

