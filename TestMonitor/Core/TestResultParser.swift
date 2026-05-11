import Foundation

/// Incrementally parses xcodebuild output, extracting test results line by line.
final class TestResultParser {
  private var remainder = ""
  private var currentWorkerIndex = 0
  private(set) var verdict: Verdict?
  private(set) var startDate: Date?

  // MARK: Patterns

  private static let casePattern = try! NSRegularExpression(
    pattern: #"Test Case '-\[(\w+) (\w+)\]' (passed|failed|skipped) \((\d+\.\d+) seconds\)\."#
  )
  private static let clonePattern = try! NSRegularExpression(
    pattern: #"Clone (\d+)"#
  )
  private static let succeededPattern = try! NSRegularExpression(
    pattern: #"\*\* TEST SUCCEEDED \*\*"#
  )
  private static let failedPattern = try! NSRegularExpression(
    pattern: #"\*\* TEST FAILED \*\*"#
  )
  private static let suiteStartPattern = try! NSRegularExpression(
    pattern: #"Test Suite '.*' started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)"#
  )
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  // MARK: Public

  func parse(chunk: String) -> [TestResult] {
    remainder += chunk
    let lines = remainder.components(separatedBy: "\n")
    remainder = lines.last ?? ""

    var results: [TestResult] = []
    for line in lines.dropLast() {
      parseSuiteStart(from: line)
      updateWorkerIndex(from: line)
      if let result = parseTestCase(from: line) {
        results.append(result)
      }
      checkVerdict(in: line)
    }
    return results
  }

  // MARK: Private

  private func parseSuiteStart(from line: String) {
    guard startDate == nil else { return }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.suiteStartPattern.firstMatch(in: line, range: range) else { return }
    let dateStr = substring(line, match: match, group: 1)
    startDate = Self.dateFormatter.date(from: dateStr)
  }

  private func updateWorkerIndex(from line: String) {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.clonePattern.firstMatch(in: line, range: range) else { return }
    currentWorkerIndex = Int(substring(line, match: match, group: 1)) ?? 0
  }

  private func parseTestCase(from line: String) -> TestResult? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.casePattern.firstMatch(in: line, range: range) else { return nil }

    let suite    = substring(line, match: match, group: 1)
    let name     = substring(line, match: match, group: 2)
    let statusStr = substring(line, match: match, group: 3)
    let duration = Double(substring(line, match: match, group: 4)) ?? 0

    let status: TestStatus
    switch statusStr {
    case "passed":  status = .passed
    case "failed":  status = .failed
    default:        status = .skipped
    }

    return TestResult(
      suite: suite,
      name: name,
      status: status,
      duration: duration,
      workerIndex: currentWorkerIndex
    )
  }

  private func checkVerdict(in line: String) {
    guard verdict == nil else { return }
    let range = NSRange(line.startIndex..., in: line)
    if Self.succeededPattern.firstMatch(in: line, range: range) != nil {
      verdict = .succeeded
    } else if Self.failedPattern.firstMatch(in: line, range: range) != nil {
      verdict = .failed
    }
  }

  private func substring(_ string: String, match: NSTextCheckingResult, group: Int) -> String {
    guard let range = Range(match.range(at: group), in: string) else { return "" }
    return String(string[range])
  }
}
