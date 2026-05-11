import Foundation
import Observation

/// Manages installation of the transparent `xcodebuild` shell wrapper in ~/.zshrc.
/// The wrapper auto-tees `xcodebuild test` output to the log files TestMonitor watches.
@Observable
final class ShellWrapperManager {

  // The exact block written to / searched for in ~/.zshrc
  private static let beginMarker = "# >>> TestMonitor xcodebuild wrapper <<<"
  private static let endMarker   = "# <<< TestMonitor xcodebuild wrapper >>>"

  private static let wrapperBlock = """
  # >>> TestMonitor xcodebuild wrapper <<<
  # Auto-tees `xcodebuild test` output so TestMonitor picks up live results.
  # Remove by choosing "Remove Shell Wrapper" from the TestMonitor menu bar.
  xcodebuild() {
    if [[ " $* " != *" test "* ]]; then
      command xcodebuild "$@"
      return
    fi
    local logfile
    if [[ " $* " == *"SmartTubeTests"* ]] || [[ " $* " == *"-parallel-testing-enabled NO"* ]]; then
      logfile="/tmp/smarttube-unit-tests.log"
    else
      logfile="/tmp/smarttube-parallel-test.log"
    fi
    > "$logfile"
    echo "  [TestMonitor] → $logfile"
    command xcodebuild "$@" 2>&1 | tee -a "$logfile"
  }
  # <<< TestMonitor xcodebuild wrapper >>>
  """

  private(set) var isInstalled: Bool = false
  private(set) var lastError: String?

  private let zshrcPath: String

  init() {
    zshrcPath = (("~/.zshrc" as NSString).expandingTildeInPath)
    refresh()
  }

  /// Re-read disk state (call after install/remove, or on app launch).
  func refresh() {
    let content = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
    isInstalled = content.contains(Self.beginMarker)
    lastError = nil
  }

  func install() {
    guard !isInstalled else { return }
    do {
      var content = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
      if !content.hasSuffix("\n") { content += "\n" }
      content += "\n" + Self.wrapperBlock + "\n"
      try content.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
      isInstalled = true
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func remove() {
    guard isInstalled else { return }
    do {
      var content = try String(contentsOfFile: zshrcPath, encoding: .utf8)
      // Remove every line between (and including) the begin/end markers
      let lines = content.components(separatedBy: "\n")
      var result: [String] = []
      var inside = false
      for line in lines {
        if line.hasPrefix(Self.beginMarker) { inside = true }
        if !inside { result.append(line) }
        if line.hasPrefix(Self.endMarker) { inside = false }
      }
      // Collapse multiple blank lines that may be left behind
      content = result.joined(separator: "\n")
        .replacingOccurrences(of: "\n\n\n", with: "\n\n")
      try content.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
      isInstalled = false
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }
}
