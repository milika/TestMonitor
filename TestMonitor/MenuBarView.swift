import SwiftUI

// MARK: - Menu Bar Item Label

struct MenuBarLabel: View {
  var suites: [TestRunState]

  private var visible: [TestRunState] { suites.filter { !$0.isDismissed } }

  var body: some View {
    if let active = visible.first(where: \.isRunning) {
      RunningMenuBarLabel(state: active)
    } else if let failed = visible.first(where: { $0.verdict == .failed }) {
      let _ = failed  // suppress unused warning
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(Color.red)
    } else if visible.contains(where: { $0.verdict == .succeeded }) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(Color.green)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(Color.secondary)
    }
  }
}

struct RunningMenuBarLabel: View {
  var state: TestRunState

  var body: some View {
    HStack(spacing: 3) {
      ProgressView()
        .scaleEffect(0.7)
        .frame(width: 18, height: 18)
      if let eta = state.eta {
        Text("\(shortSuiteName): \(state.completed)/\(state.totalKnown) · \(formatETA(eta))")
          .font(.system(size: 13))
      } else {
        Text("\(shortSuiteName): \(state.completed)/\(state.totalKnown)")
          .font(.system(size: 13))
      }
    }
  }

  private var shortSuiteName: String {
    state.suiteName.contains("UI") ? "UI Tests" : "Unit Tests"
  }
}

// MARK: - Menu Bar Popover

struct MenuBarView: View {
  var suites: [TestRunState]
  var shellWrapper: ShellWrapperManager

  @Environment(\.openWindow) private var openWindow

  private var visible: [TestRunState] { suites.filter { !$0.isDismissed } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if visible.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .font(.body)
            .foregroundStyle(.green)
          Text("All clear — no active test runs")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(visible) { state in
          CompactSuiteRow(state: state)
        }
      }
      Divider()
      Button("Open TestMonitor") {
        // Bring existing main window to front rather than opening a duplicate.
        if let existing = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) {
          existing.makeKeyAndOrderFront(nil)
        } else {
          openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
      }
      .buttonStyle(.plain)
      .font(.body)
      Divider()
      ShellWrapperToggleRow(manager: shellWrapper)
      Divider()
      Button("Open on GitHub") {
        NSWorkspace.shared.open(URL(string: "https://github.com/milika/TestMonitor")!)
      }
      .buttonStyle(.plain)
      .font(.body)
      Divider()
      Button("Quit") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .font(.body)
    }
    .padding(16)
    .frame(width: 360)
  }
}

// MARK: - Compact Suite Row

struct CompactSuiteRow: View {
  var state: TestRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Circle()
          .fill(indicatorColor)
          .frame(width: 12, height: 12)
          .tooltip(indicatorHint)
        Text(state.suiteName)
          .font(.subheadline.bold())
        Spacer()
        if state.isRunning, let eta = state.eta {
          Text(formatETA(eta))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let verdict = state.verdict {
          Image(systemName: verdict == .succeeded ? "checkmark" : "xmark")
            .foregroundStyle(verdict == .succeeded ? Color.green : Color.red)
            .font(.footnote)
            .tooltip(verdict == .succeeded ? "All tests passed" : "One or more tests failed")
        }
        if !state.isRunning {
          Button {
            state.isDismissed = true
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white)
              .padding(3)
              .background(Color.red.opacity(0.75), in: Circle())
          }
          .buttonStyle(.plain)
          .tooltip("Dismiss")
        }
      }
      if let start = state.startTime {
        HStack(spacing: 3) {
          Text(timeString(start))
            .font(.footnote)
            .foregroundStyle(.secondary)
          if let end = state.endTime {
            Text("→ \(timeString(end))")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text("(\(formatDuration(end.timeIntervalSince(start))))")
              .font(.footnote)
              .foregroundStyle(.tertiary)
          } else {
            Text("→ running…")
              .font(.footnote)
              .foregroundStyle(.tertiary)
          }
        }
      }
      if state.isRunning || state.completed > 0 {
        ProgressView(value: state.progressFraction)
          .progressViewStyle(.linear)
        HStack {
          Text("\(state.completed)/\(state.totalKnown)")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer()
          Text("✓ \(state.passed)  ✗ \(state.failed)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var indicatorColor: Color {
    if state.isRunning { return .blue }
    switch state.verdict {
    case .succeeded: return .green
    case .failed:    return .red
    case nil:        return state.completed > 0 ? .orange : .gray
    }
  }

  private var indicatorHint: String {
    if state.isRunning { return "Running" }
    switch state.verdict {
    case .succeeded: return "Passed"
    case .failed:    return "Failed"
    case nil:        return state.completed > 0 ? "Incomplete" : "Idle"
    }
  }
}

// MARK: - Shell Wrapper Toggle Row

struct ShellWrapperToggleRow: View {
  var manager: ShellWrapperManager

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(manager.isInstalled ? Color.green : Color.secondary.opacity(0.4))
        .frame(width: 11, height: 11)
      Text(manager.isInstalled ? "Shell wrapper active" : "Shell wrapper inactive")
        .font(.body)
        .foregroundStyle(manager.isInstalled ? .primary : .secondary)
      Spacer()
      Button(manager.isInstalled ? "Remove" : "Install") {
        if manager.isInstalled {
          manager.remove()
        } else {
          manager.install()
        }
      }
      .buttonStyle(.plain)
      .font(.body)
      .foregroundStyle(manager.isInstalled ? .red : .accentColor)
    }
    .tooltip(manager.isInstalled
      ? "xcodebuild test output is auto-teed to log files. Run: source ~/.zshrc"
      : "Install a ~/.zshrc wrapper so xcodebuild test output is captured automatically")
    if let err = manager.lastError {
      Text("⚠ \(err)")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}
