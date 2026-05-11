import AppKit
import CoreGraphics
import Foundation
import Network

/// Tiny local HTTP server that serves a PNG screenshot of the TestMonitor window.
/// Usage:  curl -s localhost:7777/ss > /tmp/ss.png && open /tmp/ss.png
final class ScreenshotServer {
  private let port: UInt16
  private var listener: NWListener?

  init(port: UInt16 = 7777) {
    self.port = port
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
    // Read the HTTP request (we don't care about the content, just drain it).
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
      guard let self else { return }
      let response = self.buildResponse()
      conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
  }

  private func buildResponse() -> Data {
    if let png = captureWindow() {
      let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n"
      return header.data(using: .utf8)! + png
    }
    let body = "TestMonitor window not found"
    let header = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
    return header.data(using: .utf8)! + body.data(using: .utf8)!
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
