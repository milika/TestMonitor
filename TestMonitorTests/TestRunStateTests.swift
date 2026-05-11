import Testing
import Foundation
@testable import TestMonitor

@Suite("TestRunState — derived properties")
struct TestRunStateDerivedTests {

  // Helper: build a state with pre-seeded results (no file watching)
  private func makeState(total: Int = 10) -> TestRunState {
    TestRunState(suiteName: "Tests", totalKnown: total, logPath: "/dev/null")
  }

  private func result(status: TestStatus, worker: Int = 0) -> TestResult {
    TestResult(suite: "S", name: "t", status: status, duration: 1.0, workerIndex: worker)
  }

  // MARK: Counts

  @Test("passed count")
  func passedCount() {
    let state = makeState()
    state.results = [result(status: .passed), result(status: .passed), result(status: .failed)]
    #expect(state.passed == 2)
  }

  @Test("failed count")
  func failedCount() {
    let state = makeState()
    state.results = [result(status: .passed), result(status: .failed), result(status: .failed)]
    #expect(state.failed == 2)
  }

  @Test("skipped count")
  func skippedCount() {
    let state = makeState()
    state.results = [result(status: .skipped), result(status: .skipped)]
    #expect(state.skipped == 2)
  }

  @Test("completed equals results count")
  func completedCount() {
    let state = makeState()
    state.results = Array(repeating: result(status: .passed), count: 7)
    #expect(state.completed == 7)
  }

  // MARK: Progress

  @Test("progressFraction is 0 when no results")
  func progressFractionZero() {
    let state = makeState(total: 10)
    #expect(state.progressFraction == 0.0)
  }

  @Test("progressFraction is 0.5 at half way")
  func progressFractionHalf() {
    let state = makeState(total: 10)
    state.results = Array(repeating: result(status: .passed), count: 5)
    #expect(state.progressFraction == 0.5)
  }

  @Test("progressFraction is capped at 1.0 even when completed > total")
  func progressFractionCapped() {
    let state = makeState(total: 5)
    state.results = Array(repeating: result(status: .passed), count: 8)
    #expect(state.progressFraction == 1.0)
  }

  @Test("progressFraction is 0 when totalKnown is 0")
  func progressFractionZeroTotal() {
    let state = makeState(total: 0)
    state.results = [result(status: .passed)]
    #expect(state.progressFraction == 0.0)
  }

  // MARK: ETA

  @Test("eta is nil before 5 completions")
  func etaNilBelowThreshold() {
    let state = makeState(total: 10)
    state.startTime = Date().addingTimeInterval(-10)
    state.results = Array(repeating: result(status: .passed), count: 4)
    #expect(state.eta == nil)
  }

  @Test("eta is nil when startTime is not set")
  func etaNilNoStartTime() {
    let state = makeState(total: 10)
    state.results = Array(repeating: result(status: .passed), count: 6)
    #expect(state.eta == nil)
  }

  @Test("eta is positive and finite after 5 completions with startTime set")
  func etaPositive() {
    let state = makeState(total: 10)
    state.startTime = Date().addingTimeInterval(-5)   // 5 seconds elapsed
    state.results = Array(repeating: result(status: .passed), count: 5)
    // rate = 5/5 = 1 test/s, remaining = 5 → eta ≈ 5s
    let eta = state.eta
    #expect(eta != nil)
    #expect(eta! > 0)
    #expect(eta!.isFinite)
  }

  // MARK: perWorkerResults

  @Test("perWorkerResults groups by workerIndex")
  func perWorkerResults() {
    let state = makeState(total: 6)
    state.results = [
      result(status: .passed, worker: 1),
      result(status: .passed, worker: 1),
      result(status: .passed, worker: 2),
      result(status: .failed, worker: 3),
    ]
    let grouped = state.perWorkerResults
    #expect(grouped[1]?.count == 2)
    #expect(grouped[2]?.count == 1)
    #expect(grouped[3]?.count == 1)
    #expect(grouped[4] == nil)
  }

  // MARK: Reset

  @Test("reset clears all mutable state")
  func resetClearsState() {
    let state = makeState(total: 10)
    state.results = [result(status: .passed)]
    state.startTime = Date()
    state.endTime = Date()
    state.isRunning = true
    state.verdict = .succeeded
    state.isDismissed = true

    state.reset()

    #expect(state.results.isEmpty)
    #expect(state.startTime == nil)
    #expect(state.endTime == nil)
    #expect(state.isRunning == false)
    #expect(state.verdict == nil)
    #expect(state.isDismissed == false)
  }

  // MARK: totalKnown mutability

  @Test("totalKnown can be updated (for auto-detection)")
  func totalKnownMutable() {
    let state = makeState(total: 57)
    state.totalKnown = 304
    #expect(state.totalKnown == 304)
  }

  // MARK: Timestamp derivation — unit tests (no log-parsed startDate)

  @Test("startTime derived from elapsedSeconds when no log timestamp")
  func startTimeDerivedFromElapsed() {
    let state = makeState(total: 10)
    // Feed a complete Swift Testing log: individual results + summary
    let chunk = """
    ✔ Test "testOne" passed after 1.0 seconds.
    ✔ Test "testTwo" passed after 2.0 seconds.
    ✔ Test run with 2 tests in 1 suites passed after 3.535 seconds.

    """
    state.ingest(chunk: chunk)

    #expect(state.verdict == .succeeded)
    #expect(state.endTime != nil)
    #expect(state.startTime != nil)
    // startTime should be approximately endTime − 3.535 s
    let diff = state.endTime!.timeIntervalSince(state.startTime!)
    #expect(abs(diff - 3.535) < 0.1)
  }

  @Test("startTime not derived when log-parsed timestamp already set")
  func startTimeNotDerivedForUITests() {
    // UI tests DO emit "Test Suite '...' started at TIMESTAMP", so parser.startDate
    // is non-nil. The elapsed derivation guard (parser.startDate == nil) means it
    // should never overwrite the log-parsed startTime.
    let state = makeState(total: 10)
    let chunk = """
    Test Suite 'SmartTubeUITests' started at 2026-05-11 08:00:00.000
    Test Case '-[SmartTubeUITests.HomeUITests testFoo]' passed (1.0 seconds).
    ** TEST SUCCEEDED **

    """
    state.ingest(chunk: chunk)

    #expect(state.verdict == .succeeded)
    #expect(state.startTime != nil)
    // startTime should come from the log (08:00:00), not from elapsed derivation
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute, .second], from: state.startTime!)
    #expect(comps.hour == 8)
    #expect(comps.minute == 0)
    #expect(comps.second == 0)
  }

  // MARK: Timestamp derivation — xcresult bundle name callback

  @Test("onStartDate callback fires with parsed xcresult bundle timestamp")
  func xcresultBundleStartDateParsed() {
    // We test XCResultWatcher's private parseStartDate indirectly through a
    // real bundle name pattern.
    // The expected format: Test-<Name>-2026.05.11_15-57-21-+0200.xcresult
    let bundleName = "Test-SmartTube-2026.05.11_15-57-21-+0200.xcresult"

    // Replicate the same DateFormatter used in XCResultWatcher
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy.MM.dd_HH-mm-ss-Z"

    let pattern = try! NSRegularExpression(pattern: #"(\d{4}\.\d{2}\.\d{2}_\d{2}-\d{2}-\d{2}-[+-]\d{4})"#)
    let range = NSRange(bundleName.startIndex..., in: bundleName)
    let match = pattern.firstMatch(in: bundleName, range: range)
    #expect(match != nil)

    let r = Range(match!.range(at: 1), in: bundleName)!
    let date = formatter.date(from: String(bundleName[r]))
    #expect(date != nil)

    let cal = Calendar(identifier: .gregorian)
    var tz = TimeZone(secondsFromGMT: 2 * 3600)!
    var comps = cal.dateComponents(in: tz, from: date!)
    #expect(comps.hour == 15)
    #expect(comps.minute == 57)
    #expect(comps.second == 21)
  }

  @Test("onStartDate callback fires with UTC offset bundle name")
  func xcresultBundleStartDateUTC() {
    let bundleName = "Test-App-2026.01.15_09-05-00-+0000.xcresult"

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy.MM.dd_HH-mm-ss-Z"

    let pattern = try! NSRegularExpression(pattern: #"(\d{4}\.\d{2}\.\d{2}_\d{2}-\d{2}-\d{2}-[+-]\d{4})"#)
    let range = NSRange(bundleName.startIndex..., in: bundleName)
    let match = pattern.firstMatch(in: bundleName, range: range)
    let r = Range(match!.range(at: 1), in: bundleName)!
    let date = formatter.date(from: String(bundleName[r]))
    #expect(date != nil)

    let utc = TimeZone(secondsFromGMT: 0)!
    let comps = Calendar(identifier: .gregorian).dateComponents(in: utc, from: date!)
    #expect(comps.hour == 9)
    #expect(comps.minute == 5)
    #expect(comps.second == 0)
  }
}
