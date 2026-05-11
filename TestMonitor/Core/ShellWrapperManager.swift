import Foundation
import Observation

/// Manages a transparent `xcodebuild` binary shim installed at a PATH-priority
/// location (/opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel).
///
/// Because the shim is a real executable — not a shell function — it intercepts
/// every `xcodebuild test` call in any terminal, script, or CI job without
/// requiring `source ~/.zshrc` or any per-session setup.
@Observable
final class ShellWrapperManager {

  // Marker embedded in the shim so we can distinguish our file from anything else.
  private static let shimMarker = "# TestMonitor xcodebuild shim"

  private static let shimScript = """
  #!/bin/bash
  # TestMonitor xcodebuild shim
  # Transparently tees `xcodebuild test` output to the log files TestMonitor watches.
  # Remove by choosing "Remove Shell Wrapper" from the TestMonitor menu bar.

  REAL_XCODEBUILD="$(xcrun --find xcodebuild 2>/dev/null || echo /usr/bin/xcodebuild)"

  # Pass non-test invocations straight through.
  if [[ " $* " != *" test "* ]]; then
    exec "$REAL_XCODEBUILD" "$@"
  fi

  # Route to the appropriate log based on scheme name.
  # SmartTubeTests scheme = unit tests; everything else = UI/parallel tests.
  if [[ "$*" == *"-scheme SmartTubeTests"* ]]; then
    logfile="/tmp/smarttube-unit-tests.log"
  else
    logfile="/tmp/smarttube-parallel-test.log"
  fi

  : > "$logfile"
  echo "  [TestMonitor] → $logfile" >&2
  exec "$REAL_XCODEBUILD" "$@" 2>&1 | tee -a "$logfile"
  """

  private(set) var isInstalled: Bool = false
  private(set) var lastError: String?

  /// Directory where the shim is placed. Chosen to appear before /usr/bin in PATH.
  private static var shimDir: String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafeBytes(of: &sysinfo.machine) { bytes in
      String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }
    return machine == "arm64" ? "/opt/homebrew/bin" : "/usr/local/bin"
  }

  private static var shimPath: String { "\(shimDir)/xcodebuild" }

  init() { refresh() }

  func refresh() {
    let content = (try? String(contentsOfFile: Self.shimPath, encoding: .utf8)) ?? ""
    isInstalled = content.contains(Self.shimMarker)
    lastError = nil
  }

  func install() {
    guard !isInstalled else { return }
    // Remove any stale ~/.zshrc wrapper left from the old approach.
    removeZshrcWrapper()
    do {
      try Self.shimScript.write(toFile: Self.shimPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: Self.shimPath
      )
      isInstalled = true
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func remove() {
    guard isInstalled else { return }
    do {
      try FileManager.default.removeItem(atPath: Self.shimPath)
      isInstalled = false
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: - Migration: clean up the old ~/.zshrc function if present

  private func removeZshrcWrapper() {
    let zshrcPath = ("~/.zshrc" as NSString).expandingTildeInPath
    guard var content = try? String(contentsOfFile: zshrcPath, encoding: .utf8),
          content.contains("# >>> TestMonitor xcodebuild wrapper <<<") else { return }
    let lines = content.components(separatedBy: "\n")
    var result: [String] = []
    var inside = false
    for line in lines {
      if line.hasPrefix("# >>> TestMonitor xcodebuild wrapper <<<") { inside = true }
      if !inside { result.append(line) }
      if line.hasPrefix("# <<< TestMonitor xcodebuild wrapper >>>") { inside = false }
    }
    content = result.joined(separator: "\n")
      .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    try? content.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
  }
}
