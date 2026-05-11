import Foundation

/// Parses a completed `.xcresult` bundle using `xcresulttool` to get the
/// authoritative test count, individual results, and final verdict.
///
/// Replaces the streaming estimates produced by reading Staging files, which
/// disappear once a run completes. Works on both live and already-finished bundles.
final class XCResultToolParser {

  struct ParsedResults {
    let results: [TestResult]
    let totalCount: Int
    let verdict: Verdict
    let startDate: Date?
    let endDate: Date?
  }

  /// Parse an xcresult bundle asynchronously. Returns nil if xcresulttool fails
  /// or the bundle contains no test data.
  static func parse(xcresultPath: String) async -> ParsedResults? {
    // Step 1: get root invocation record to find the testsRef ID.
    // Note: Xcode 16+ requires `get object --legacy` form.
    guard let root = await runXCResultTool(["get", "object", "--legacy", "--format", "json", "--path", xcresultPath]),
          let testsRefId = extractTestsRefId(from: root) else {
      return nil
    }

    // Step 2: get the full test plan run summaries via the ref ID.
    guard let summariesJSON = await runXCResultTool([
      "get", "object", "--legacy", "--format", "json", "--path", xcresultPath, "--id", testsRefId
    ]) else {
      return nil
    }

    return parseSummaries(from: summariesJSON)
  }

  // MARK: - Private

  private static func runXCResultTool(_ args: [String]) async -> [String: Any]? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcresulttool"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
          try process.run()
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            continuation.resume(returning: nil)
            return
          }
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
          continuation.resume(returning: json)
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Walks the ActionsInvocationRecord to find the first testsRef id.
  private static func extractTestsRefId(from root: [String: Any]) -> String? {
    guard let actionsObj = root["actions"] as? [String: Any],
          let actions = actionsObj["_values"] as? [[String: Any]] else { return nil }
    for action in actions {
      if let ar = action["actionResult"] as? [String: Any],
         let ref = ar["testsRef"] as? [String: Any],
         let idObj = ref["id"] as? [String: Any],
         let id = idObj["_value"] as? String {
        return id
      }
    }
    return nil
  }

  private static func parseSummaries(from json: [String: Any]) -> ParsedResults? {
    var results: [TestResult] = []
    var overallVerdict: Verdict = .succeeded

    guard let summariesObj = json["summaries"] as? [String: Any],
          let summaries = summariesObj["_values"] as? [[String: Any]] else { return nil }

    for summary in summaries {
      guard let testablesObj = summary["testableSummaries"] as? [String: Any],
            let testables = testablesObj["_values"] as? [[String: Any]] else { continue }
      for testable in testables {
        let defaultSuite = strVal(testable["name"]) ?? "Unknown"
        guard let testsObj = testable["tests"] as? [String: Any],
              let tests = testsObj["_values"] as? [[String: Any]] else { continue }
        for node in tests {
          collectTests(from: node, suiteName: defaultSuite, results: &results, verdict: &overallVerdict)
        }
      }
    }

    guard !results.isEmpty else { return nil }
    return ParsedResults(results: results, totalCount: results.count,
                         verdict: overallVerdict, startDate: nil, endDate: nil)
  }

  private static func collectTests(from node: [String: Any],
                                   suiteName: String,
                                   results: inout [TestResult],
                                   verdict: inout Verdict) {
    let typeName = (node["_type"] as? [String: Any])?["_name"] as? String ?? ""

    if typeName == "ActionTestMetadata" {
      // Leaf node — actual test case
      let rawName = strVal(node["name"]) ?? "unknown"
      // Strip trailing "()" from Swift function names
      let name = rawName.hasSuffix("()") ? String(rawName.dropLast(2)) : rawName
      let statusStr = strVal(node["testStatus"]) ?? "Success"
      let durationStr = strVal(node["duration"]) ?? "0"
      let duration = Double(durationStr) ?? 0

      let status: TestStatus
      switch statusStr {
      case "Success":           status = .passed
      case "Failure":           status = .failed; verdict = .failed
      default:                  status = .skipped   // "Skipped", "Expected Failure"
      }
      results.append(TestResult(suite: suiteName, name: name,
                                status: status, duration: duration, workerIndex: 0))
      return
    }

    // Group node — use its name as the suite name for its children
    let groupName = strVal(node["name"]) ?? suiteName
    if let subtestsObj = node["subtests"] as? [String: Any],
       let subtests = subtestsObj["_values"] as? [[String: Any]] {
      for child in subtests {
        collectTests(from: child, suiteName: groupName, results: &results, verdict: &verdict)
      }
    }
  }

  private static func strVal(_ obj: Any?) -> String? {
    (obj as? [String: Any])?["_value"] as? String
  }
}
