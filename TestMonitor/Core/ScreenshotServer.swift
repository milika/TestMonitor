import AppKit
import CoreGraphics
import Foundation
import Network

/// Tiny local HTTP server that serves a PNG screenshot, JSON status, and log tails.
/// Endpoints:
///   GET /ss      → PNG screenshot of the TestMonitor window
///   GET /status  → JSON state of all test suites
///   GET /logs    → plain-text tail of each suite's log file (last 200 lines)
///   GET /debug   → all of the above as a structured plain-text report + base64 screenshot
final class ScreenshotServer {
  private let port: UInt16
  private var listener: NWListener?
  private var suitesProvider: (() -> [TestRunState])?

  init(port: UInt16 = 7777) {
    self.port = port
  }

  func setSuites(_ provider: @escaping () -> [TestRunState]) {
    suitesProvider = provider
  }

  func start() {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port),
          let listener = try? NWListener(using: params, on: nwPort) else {
      print("[ScreenshotServer] Failed to bind on port \(port)")
      return
    }
    self.listener = listener
    listener.stateUpdateHandler = { state in
      if case .ready = state { print("[ScreenshotServer] Listening on port \(self.port)") }
    }
    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
    listener.start(queue: .global(qos: .utility))
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  // MARK: - Private

  private func handle(_ conn: NWConnection) {
    conn.start(queue: .global(qos: .utility))
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
      guard let self else { return }
      let path = Self.parsePath(from: data)
      let response: Data
      switch path {
      case "/status":  response = self.buildStatusResponse()
      case "/logs":    response = self.buildLogsResponse()
      case "/debug":   response = self.buildDebugResponse()
      default:         response = self.buildScreenshotResponse()   // /ss or anything else
      }
      conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
  }

  private static func parsePath(from data: Data?) -> String {
    guard let data, let text = String(data: data, encoding: .utf8) else { return "/" }
    // First line: "GET /path HTTP/1.1"
    let firstLine = text.components(separatedBy: "\r\n").first ?? ""
    let parts = firstLine.components(separatedBy: " ")
    return parts.count >= 2 ? parts[1] : "/"
  }

  // MARK: - /ss

  private func buildScreenshotResponse() -> Data {
    if let png = captureWindow() {
      let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n"
      return header.data(using: .utf8)! + png
    }
    return textResponse(status: "500 Internal Server Error", body: "TestMonitor window not found")
  }

  // MARK: - /status

  private func buildStatusResponse() -> Data {
    let suites = suitesProvider?() ?? []
    var arr: [[String: Any]] = []
    for s in suites {
      var obj: [String: Any] = [
        "name": s.suiteName,
        "isRunning": s.isRunning,
        "passed": s.passed,
        "failed": s.failed,
        "skipped": s.skipped,
        "completed": s.completed,
        "totalKnown": s.totalKnown,
        "progressPct": Int((s.progressFraction * 100).rounded()),
        "logPath": s.logPath,
      ]
      if let v = s.verdict { obj["verdict"] = (v == .succeeded ? "succeeded" : "failed") }
      if let t = s.startTime { obj["startTime"] = ISO8601DateFormatter().string(from: t) }
      if let t = s.endTime   { obj["endTime"]   = ISO8601DateFormatter().string(from: t) }
      if let p = s.xcresultPath { obj["xcresultPath"] = p }
      let recent = s.results.suffix(5).map { r -> [String: Any] in
        ["suite": r.suite, "name": r.name,
         "status": r.status == .passed ? "passed" : r.status == .failed ? "failed" : "skipped",
         "duration": r.duration]
      }
      obj["recentResults"] = recent
      arr.append(obj)
    }
    guard let body = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) else {
      return textResponse(status: "500 Internal Server Error", body: "JSON serialization failed")
    }
    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return header.data(using: .utf8)! + body
  }

  // MARK: - /logs

  private func buildLogsResponse() -> Data {
    let suites = suitesProvider?() ?? []
    var lines: [String] = []
    for s in suites {
      lines.append("=== \(s.suiteName) [\(s.logPath)] ===")
      lines.append(contentsOf: tailFile(path: s.logPath, lineCount: 200))
      lines.append("")
    }
    return textResponse(status: "200 OK", body: lines.joined(separator: "\n"))
  }

  // MARK: - /debug

  private func buildDebugResponse() -> Data {
    let suites = suitesProvider?() ?? []
    var lines: [String] = []
    lines.append("### TestMonitor Debug Report — \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("")
    for s in suites {
      lines.append("## Suite: \(s.suiteName)")
      let statusStr = s.isRunning ? "RUNNING" : (s.verdict == .succeeded ? "PASSED" : s.verdict == .failed ? "FAILED" : "idle")
      lines.append("   Status   : \(statusStr)")
      lines.append("   Progress : \(s.completed)/\(s.totalKnown) (\(Int((s.progressFraction*100).rounded()))%)")
      lines.append("   Passed   : \(s.passed)  Failed: \(s.failed)  Skipped: \(s.skipped)")
      if let t = s.startTime { lines.append("   Start    : \(t)") }
      if let t = s.endTime   { lines.append("   End      : \(t)") }
      if let p = s.xcresultPath { lines.append("   XCResult : \(p)") }
      lines.append("   Log      : \(s.logPath)")
      lines.append("")
      lines.append("   Last 5 results:")
      for r in s.results.suffix(5) {
        let icon = r.status == .passed ? "✓" : r.status == .failed ? "✗" : "↩"
        lines.append("     \(icon) \(r.suite).\(r.name) (\(String(format: "%.3f", r.duration))s)")
      }
      lines.append("")
      lines.append("   Log tail (last 100 lines):")
      lines.append(contentsOf: tailFile(path: s.logPath, lineCount: 100).map { "   | \($0)" })
      lines.append("")
    }
    lines.append("---")
    if let png = captureWindow() {
      let b64 = png.base64EncodedString()
      lines.append("SCREENSHOT_BASE64_PNG:")
      lines.append(b64)
    } else {
      lines.append("SCREENSHOT: unavailable")
    }
    return textResponse(status: "200 OK", body: lines.joined(separator: "\n"))
  }

  // MARK: - Helpers

  private func tailFile(path: String, lineCount: Int) -> [String] {
    let expanded = (path as NSString).expandingTildeInPath
    guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
      return ["(file not found or unreadable: \(path))"]
    }
    let all = content.components(separatedBy: "\n")
    return Array(all.suffix(lineCount))
  }

  private func textResponse(status: String, body: String) -> Data {
    let bodyData = body.data(using: .utf8)!
    let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
    return header.data(using: .utf8)! + bodyData
  }

  /// Capture the on-screen TestMonitor window using CoreGraphics (no entitlement needed).
  private func captureWindow() -> Data? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }

    for info in list {
      guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "TestMonitor",
            let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
      guard let cgImage = CGWindowListCreateImage(
              .null, .optionIncludingWindow, wid,
              [.boundsIgnoreFraming, .bestResolution]
            ) else { continue }
      let rep = NSBitmapImageRep(cgImage: cgImage)
      return rep.representation(using: .png, properties: [:])
    }
    return nil
  }

  deinit { stop() }
}
