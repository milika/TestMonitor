import SwiftUI

// MARK: - Menu Bar Item Label

struct MenuBarLabel: View {
  var suites: [TestRunState]

  var body: some View {
    if let active = suites.first(where: \.isRunning) {
      RunningMenuBarLabel(state: active)
    } else if let failed = suites.first(where: { $0.verdict == .failed }) {
      let _ = failed  // suppress unused warning
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(Color.red)
    } else if suites.contains(where: { $0.verdict == .succeeded }) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.green)
    } else {
      Image(systemName: "circle.fill")
        .foregroundStyle(Color.secondary)
    }
  }
}

struct RunningMenuBarLabel: View {
  var state: TestRunState

  var body: some View {
    HStack(spacing: 3) {
      ProgressView()
        .scaleEffect(0.5)
        .frame(width: 14, height: 14)
      if let eta = state.eta {
        Text("\(shortSuiteName): \(state.completed)/\(state.totalKnown) · \(formatETA(eta))")
          .font(.system(size: 11))
      } else {
        Text("\(shortSuiteName): \(state.completed)/\(state.totalKnown)")
          .font(.system(size: 11))
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

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(suites) { state in
        CompactSuiteRow(state: state)
      }
      Divider()
      Button("Open TestMonitor") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      .buttonStyle(.plain)
      .font(.caption)
      Button("Quit") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .font(.caption)
    }
    .padding(12)
    .frame(width: 300)
  }
}

// MARK: - Compact Suite Row

struct CompactSuiteRow: View {
  var state: TestRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Circle()
          .fill(indicatorColor)
          .frame(width: 8, height: 8)
        Text(state.suiteName)
          .font(.caption.bold())
        Spacer()
        if state.isRunning, let eta = state.eta {
          Text(formatETA(eta))
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let verdict = state.verdict {
          Image(systemName: verdict == .succeeded ? "checkmark" : "xmark")
            .foregroundStyle(verdict == .succeeded ? Color.green : Color.red)
            .font(.caption2)
        }
      }
      if let start = state.startTime {
        HStack(spacing: 3) {
          Text(timeString(start))
            .font(.caption2)
            .foregroundStyle(.secondary)
          if let end = state.endTime {
            Text("→ \(timeString(end))")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text("(\(formatDuration(end.timeIntervalSince(start))))")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          } else {
            Text("→ running…")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
      if state.isRunning || state.completed > 0 {
        ProgressView(value: state.progressFraction)
          .progressViewStyle(.linear)
        HStack {
          Text("\(state.completed)/\(state.totalKnown)")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
          Text("✓ \(state.passed)  ✗ \(state.failed)")
            .font(.caption2)
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
}
