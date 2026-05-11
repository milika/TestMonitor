import Testing
import Foundation
@testable import TestMonitor

@Suite("LogWatcher")
struct LogWatcherTests {

  // MARK: - Helpers

  /// Creates a temp file, returns its path. Caller is responsible for cleanup.
  private func makeTempFile(content: String = "") throws -> String {
    let path = NSTemporaryDirectory() + "logwatcher_test_\(UUID().uuidString).log"
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  // MARK: - Tests

  @Test("delivers existing content immediately on start")
  func deliversExistingContent() async throws {
    let content = "Test case 'HomeUITests.testA()' passed on 'Clone 1 of iPhone 17 - Runner (1)' (1.0 seconds)\n"
    let path = try makeTempFile(content: content)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let received = ActorCollector<String>()

    let watcher = LogWatcher(path: path) { chunk in
      Task { await received.append(chunk) }
    }
    watcher.start()

    // Give the watcher a moment to drain the initial content.
    try await Task.sleep(for: .milliseconds(200))
    watcher.stop()

    let chunks = await received.values
    let joined = chunks.joined()
    #expect(joined.contains("testA"))
  }

  @Test("delivers new content appended after start")
  func deliversAppendedContent() async throws {
    let path = try makeTempFile()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let received = ActorCollector<String>()

    let watcher = LogWatcher(path: path) { chunk in
      Task { await received.append(chunk) }
    }
    watcher.start()
    try await Task.sleep(for: .milliseconds(150))

    // Append new content using FileHandle forUpdating (more reliable than forWritingAtPath)
    let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
    handle.seekToEndOfFile()
    handle.write("hello watcher\n".data(using: .utf8)!)
    try handle.close()

    // Give DispatchSource event + async Task enough time to propagate
    try await Task.sleep(for: .milliseconds(600))
    watcher.stop()

    let joined = await received.values.joined()
    #expect(joined.contains("hello watcher"))
  }

  @Test("does not crash when file does not exist")
  func handlesNonExistentFile() async throws {
    let path = NSTemporaryDirectory() + "nonexistent_\(UUID().uuidString).log"
    let watcher = LogWatcher(path: path) { _ in }
    // Should not throw or crash
    watcher.start()
    try await Task.sleep(for: .milliseconds(100))
    watcher.stop()
  }

  @Test("stop can be called multiple times safely")
  func multipleStopCallsSafe() async throws {
    let path = try makeTempFile()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let watcher = LogWatcher(path: path) { _ in }
    watcher.start()
    watcher.stop()
    watcher.stop()  // should not crash
  }

  @Test("does not deliver content after stop")
  func noDeliveryAfterStop() async throws {
    let path = try makeTempFile()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let received = ActorCollector<String>()

    let watcher = LogWatcher(path: path) { chunk in
      Task { await received.append(chunk) }
    }
    watcher.start()
    try await Task.sleep(for: .milliseconds(50))
    watcher.stop()

    // Write after stop — should not be delivered
    let handle = try FileHandle(forWritingAtPath: path)!
    handle.seekToEndOfFile()
    handle.write("after stop\n".data(using: .utf8)!)
    handle.closeFile()

    try await Task.sleep(for: .milliseconds(300))

    let joined = await received.values.joined()
    #expect(!joined.contains("after stop"))
  }
}

// MARK: - Thread-safe collector

/// Actor used to safely accumulate values sent from concurrent contexts in tests.
actor ActorCollector<T> {
  private(set) var values: [T] = []
  func append(_ value: T) { values.append(value) }
}
