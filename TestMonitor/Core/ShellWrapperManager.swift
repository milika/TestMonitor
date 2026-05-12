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

  // MARK: - LogRoute

  /// Maps an xcodebuild scheme name to the log file TestMonitor should watch.
  struct LogRoute {
    let schemeName: String
    let logPath: String
  }

  // MARK: - Constants

  // Marker embedded in the shim so we can distinguish our file from anything else.
  private static let shimMarker = "# TestMonitor xcodebuild shim"

  /// Path where the shim appends every intercepted xcodebuild command for replay / debugging.
  static let commandLogPath = "/tmp/testmonitor-commands.log"

  // MARK: - State

  private(set) var isInstalled: Bool = false
  private(set) var lastError: String?
  private var logRoutes: [LogRoute] = []
  private var defaultLogPath: String = "/tmp/xcodebuild.log"

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

  /// Set the log-routing table that the shim will use.
  /// If the shim is already installed it is regenerated in place.
  func configure(routes: [LogRoute], defaultLogPath: String) {
    self.logRoutes = routes
    self.defaultLogPath = defaultLogPath
    if isInstalled { writeShim() }
  }

  func install() {
    guard !isInstalled else { return }
    removeZshrcWrapper()
    writeShim()
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

  // MARK: - Shim Generation

  /// Write (or overwrite) the shim to disk using the current routing table.
  private func writeShim() {
    let script = Self.makeShimScript(
      routes: logRoutes,
      defaultLogPath: defaultLogPath,
      commandLogPath: Self.commandLogPath
    )
    do {
      try script.write(toFile: Self.shimPath, atomically: true, encoding: .utf8)
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

  private static func makeShimScript(
    routes: [LogRoute],
    defaultLogPath: String,
    commandLogPath: String
  ) -> String {
    // Build routing: start from the default, then override per named scheme.
    let overrides = routes
      .map { r in "  [[ \"$*\" == *\"-scheme \(r.schemeName)\"* ]] && logfile=\"\(r.logPath)\"" }
      .joined(separator: "\n")
    let routingBlock = overrides.isEmpty
      ? "  logfile=\"\(defaultLogPath)\""
      : "  logfile=\"\(defaultLogPath)\"\n\(overrides)"
    return """
    #!/bin/bash
    # TestMonitor xcodebuild shim
    # Transparently tees `xcodebuild test` output to the log files TestMonitor watches.
    # Remove by choosing \"Remove Shell Wrapper\" from the TestMonitor menu bar.

    REAL_XCODEBUILD=\"$(xcrun --find xcodebuild 2>/dev/null || echo /usr/bin/xcodebuild)\"

    # Pass non-test invocations straight through.
    if [[ \" $* \" != *\" test \"* ]]; then
      exec \"$REAL_XCODEBUILD\" \"$@\"
    fi

    # Route to the appropriate log based on -scheme argument.
    \(routingBlock)

    : > \"$logfile\"
    echo \"  [TestMonitor] \u2192 $logfile\" >&2

    # Append the full invoked command for replay / debugging.
    printf '%s | %s %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$REAL_XCODEBUILD\" \"$*\" >> \"\(commandLogPath)\"

    exec \"$REAL_XCODEBUILD\" \"$@\" 2>&1 | tee -a \"$logfile\"
    \"\"\"
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
