import Testing
import Foundation
@testable import TestMonitor

// MARK: - UI test format (xcodebuild parallel)

@Suite("TestResultParser — UI test format")
struct ParserUIFormatTests {

  @Test("parses a passing UI test case")
  func parsesPassingUICase() {
    var parser = TestResultParser()
    let line = "Test case 'HomeUITests.testHomeFeedLoads()' passed on 'Clone 2 of iPhone 17 - SmartTubeUITests-Runner (65264)' (3.142 seconds)\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    let r = results[0]
    #expect(r.suite == "HomeUITests")
    #expect(r.name == "testHomeFeedLoads")
    #expect(r.status == .passed)
    #expect(r.duration == 3.142)
    #expect(r.workerIndex == 2)
  }

  @Test("parses a failing UI test case")
  func parsesFailingUICase() {
    var parser = TestResultParser()
    let line = "Test case 'SubscriptionsUITests.testListLoads()' failed on 'Clone 1 of iPhone 17 - SmartTubeUITests-Runner (64892)' (5.001 seconds)\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    #expect(results[0].status == .failed)
    #expect(results[0].workerIndex == 1)
  }

  @Test("parses a skipped UI test case")
  func parsesSkippedUICase() {
    var parser = TestResultParser()
    let line = "Test case 'ChannelViewUITests.testAllFilterRestoresFeed()' skipped on 'Clone 1 of iPhone 17 - SmartTubeUITests-Runner (64892)' (38.475 seconds)\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    #expect(results[0].status == .skipped)
    #expect(results[0].duration == 38.475)
  }

  @Test("parses worker index correctly for Clone 4")
  func parsesWorkerIndex() {
    var parser = TestResultParser()
    let line = "Test case 'SettingsUITests.testOpenSettings()' passed on 'Clone 4 of iPhone 17 - SmartTubeUITests-Runner (66163)' (1.234 seconds)\n"

    let results = parser.parse(chunk: line)

    #expect(results[0].workerIndex == 4)
  }

  @Test("detects TEST SUCCEEDED verdict")
  func detectsUISucceeded() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "** TEST SUCCEEDED **\n")
    #expect(parser.verdict == .succeeded)
  }

  @Test("detects TEST FAILED verdict")
  func detectsUIFailed() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "** TEST FAILED **\n")
    #expect(parser.verdict == .failed)
  }

  @Test("does not set verdict on unrelated lines")
  func noFalseVerdicts() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "Test suite 'HomeUITests' started on 'Clone 1 of iPhone 17'\n")
    #expect(parser.verdict == nil)
  }

  @Test("parses multiple results from a single chunk")
  func parsesMultipleResults() {
    var parser = TestResultParser()
    let chunk = """
    Test case 'HomeUITests.testA()' passed on 'Clone 1 of iPhone 17 - Runner (1)' (1.0 seconds)
    Test case 'HomeUITests.testB()' failed on 'Clone 2 of iPhone 17 - Runner (2)' (2.0 seconds)
    Test case 'HomeUITests.testC()' skipped on 'Clone 3 of iPhone 17 - Runner (3)' (3.0 seconds)
    \n
    """

    let results = parser.parse(chunk: chunk)

    #expect(results.count == 3)
    #expect(results[0].status == .passed)
    #expect(results[1].status == .failed)
    #expect(results[2].status == .skipped)
  }

  @Test("parses results split across two chunks")
  func parsesChunkedInput() {
    var parser = TestResultParser()

    let part1 = "Test case 'HomeUITests.testSplitChunk()' passed on 'Clone 1 of iPhone 17 - Runner (1)' (1."
    let part2 = "234 seconds)\n"

    let r1 = parser.parse(chunk: part1)
    let r2 = parser.parse(chunk: part2)

    #expect(r1.isEmpty)         // no newline yet — incomplete line held in buffer
    #expect(r2.count == 1)
    #expect(r2[0].duration == 1.234)
  }

  @Test("extracts startDate from Test Suite started-at line")
  func extractsStartDate() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "Test Suite 'SmartTubeUITests' started at 2026-05-11 12:34:56.789\n")
    #expect(parser.startDate != nil)

    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute, .second], from: parser.startDate!)
    #expect(comps.hour == 12)
    #expect(comps.minute == 34)
    #expect(comps.second == 56)
  }
}

// MARK: - Swift Testing / unit test format

@Suite("TestResultParser — Swift Testing format")
struct ParserUnitFormatTests {

  @Test("parses quoted test name (passed)")
  func parsesQuotedPassed() {
    var parser = TestResultParser()
    let line = "✔ Test \"totalTimeout is reasonable (≤ 30 s)\" passed after 0.034 seconds.\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    #expect(results[0].name == "totalTimeout is reasonable (≤ 30 s)")
    #expect(results[0].status == .passed)
    #expect(results[0].duration == 0.034)
    #expect(results[0].workerIndex == 0)
  }

  @Test("parses quoted test name (failed)")
  func parsesQuotedFailed() {
    var parser = TestResultParser()
    let line = "✘ Test \"myTest fails here\" failed after 1.234 seconds.\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    #expect(results[0].status == .failed)
  }

  @Test("parses function-style test name")
  func parsesFuncStyle() {
    var parser = TestResultParser()
    let line = "✔ Test originalTrackSelectedOverAIDubbedTrackWhenDefaultIsYES() passed after 0.034 seconds.\n"

    let results = parser.parse(chunk: line)

    #expect(results.count == 1)
    #expect(results[0].name == "originalTrackSelectedOverAIDubbedTrackWhenDefaultIsYES")
    #expect(results[0].status == .passed)
  }

  @Test("extracts total count and verdict from run summary line")
  func parsesRunSummary() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "✔ Test run with 304 tests in 41 suites passed after 3.535 seconds.\n")

    #expect(parser.detectedTotal == 304)
    #expect(parser.verdict == .succeeded)
  }

  @Test("run summary with failed verdict")
  func parsesFailedRunSummary() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "✘ Test run with 57 tests in 10 suites failed after 5.0 seconds.\n")

    #expect(parser.detectedTotal == 57)
    #expect(parser.verdict == .failed)
  }

  @Test("run summary captures elapsedSeconds (passed)")
  func parsesElapsedSecondsPassed() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "✔ Test run with 304 tests in 41 suites passed after 3.535 seconds.\n")
    #expect(parser.elapsedSeconds == 3.535)
    #expect(parser.authoritativeVerdict == true)
  }

  @Test("run summary captures elapsedSeconds (failed)")
  func parsesElapsedSecondsFailed() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "✘ Test run with 57 tests in 10 suites failed after 12.001 seconds.\n")
    #expect(parser.elapsedSeconds == 12.001)
  }

  @Test("elapsedSeconds is nil before summary line")
  func elapsedSecondsNilBeforeSummary() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "✔ Test \"someTest\" passed after 0.034 seconds.\n")
    #expect(parser.elapsedSeconds == nil)
  }

  @Test("run summary line does not produce a TestResult")
  func summaryLineNoResult() {
    var parser = TestResultParser()
    let results = parser.parse(chunk: "✔ Test run with 304 tests in 41 suites passed after 3.535 seconds.\n")
    #expect(results.isEmpty)
  }

  @Test("suite-level summary line does not produce a TestResult")
  func suiteSummaryNoResult() {
    var parser = TestResultParser()
    let results = parser.parse(chunk: "✔ Suite \"Current Queue Store\" passed after 0.349 seconds.\n")
    #expect(results.isEmpty)
  }
}

// MARK: - Reset

@Suite("TestResultParser — reset")
struct ParserResetTests {

  @Test("fresh parser after re-init ignores previous state")
  func freshParserIgnoresPreviousState() {
    var parser = TestResultParser()
    _ = parser.parse(chunk: "** TEST FAILED **\n")
    #expect(parser.verdict == .failed)

    // Re-initialise simulates TestRunState.reset()
    parser = TestResultParser()
    #expect(parser.verdict == nil)
    #expect(parser.detectedTotal == nil)
    #expect(parser.startDate == nil)
  }
}
