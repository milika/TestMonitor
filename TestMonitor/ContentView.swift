import SwiftUI

// MARK: - Root Window

struct ContentView: View {
  var suites: [TestRunState]

  private var visible: [TestRunState] { suites.filter { !$0.isDismissed } }

  var body: some View {
    Group {
      if visible.isEmpty {
        emptyState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, state in
              SuiteProgressView(state: state)
              if idx < visible.count - 1 {
                Divider()
              }
            }
          }
          .padding(20)
        }
      }
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 320)
    .background(.windowBackground)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("No active test runs")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minHeight: 200)
  }
}

// MARK: - Suite Progress

struct SuiteProgressView: View {
  var state: TestRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerRow
      timeRow
      overallBar
      if state.workerCount > 1 {
        WorkerBarsView(state: state)
      }
      RecentResultsView(results: state.results)
    }
  }

  private var headerRow: some View {
    HStack {
      Text(state.suiteName)
        .font(.headline)
      Spacer()
      if state.isRunning, let eta = state.eta {
        Label("ETA \(formatETA(eta))", systemImage: "timer")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let verdict = state.verdict {
        VerdictBadge(verdict: verdict)
      }
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: state.logPath))
      } label: {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Open log: \(state.logPath)")
      if !state.isRunning {
        Button {
          state.isDismissed = true
        } label: {
          Image(systemName: "xmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
      }
    }
  }

  @ViewBuilder
  private var timeRow: some View {
    if let start = state.startTime {
      HStack(spacing: 4) {
        Image(systemName: "clock")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("Started \(timeString(start))")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let end = state.endTime {
          Text("·")
            .foregroundStyle(.tertiary)
          Text("Ended \(timeString(end))")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(formatDuration(end.timeIntervalSince(start)))
            .font(.caption.bold())
            .foregroundStyle(.secondary)
        } else {
          Text("· running…")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var overallBar: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: state.progressFraction)
        .progressViewStyle(.linear)
      HStack {
        Text("\(state.completed) / \(state.totalKnown)  (\(Int(state.progressFraction * 100))%)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        HStack(spacing: 10) {
          StatusCount(count: state.passed,  icon: "checkmark", color: .green)
          StatusCount(count: state.failed,  icon: "xmark",     color: .red)
          StatusCount(count: state.skipped, icon: "arrow.counterclockwise", color: .secondary)
        }
      }
    }
  }
}

// MARK: - Worker Bars

struct WorkerBarsView: View {
  var state: TestRunState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(1...state.workerCount), id: \.self) { index in
        let count = state.perWorkerResults[index]?.count ?? 0
        let perWorkerTotal = max(state.totalKnown / state.workerCount, 1)
        HStack(spacing: 8) {
          Text("Worker \(index)")
            .font(.caption)
            .frame(width: 58, alignment: .leading)
          ProgressView(value: Double(count), total: Double(perWorkerTotal))
            .progressViewStyle(.linear)
          Text("\(count)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 28, alignment: .trailing)
        }
      }
    }
  }
}

// MARK: - Recent Results

struct RecentResultsView: View {
  let results: [TestResult]

  private var recent: [TestResult] {
    Array(results.suffix(20).reversed())
  }

  var body: some View {
    if recent.isEmpty { EmptyView() } else {
      VStack(alignment: .leading, spacing: 2) {
        Text("Recent:")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        ForEach(recent) { result in
          HStack(spacing: 6) {
            Image(systemName: result.status.icon)
              .foregroundStyle(result.status.color)
              .frame(width: 12)
            Text("\(result.suite).\(result.name)")
              .font(.system(size: 11, design: .monospaced))
              .lineLimit(1)
            Spacer()
            Text(String(format: "%.1fs", result.duration))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

// MARK: - Supporting Views

struct VerdictBadge: View {
  let verdict: Verdict

  var body: some View {
    switch verdict {
    case .succeeded:
      Label("Passed", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.subheadline)
    case .failed:
      Label("Failed", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
        .font(.subheadline)
    }
  }
}

struct StatusCount: View {
  let count: Int
  let icon: String
  let color: Color

  var body: some View {
    Label("\(count)", systemImage: icon)
      .foregroundStyle(color)
      .font(.caption)
  }
}

// MARK: - TestStatus helpers

extension TestStatus {
  var icon: String {
    switch self {
    case .passed:  return "checkmark"
    case .failed:  return "xmark"
    case .skipped: return "arrow.counterclockwise"
    }
  }

  var color: Color {
    switch self {
    case .passed:  return .green
    case .failed:  return .red
    case .skipped: return .secondary
    }
  }
}

// MARK: - Helpers

private let shortTimeFmt: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "HH:mm:ss"
  return f
}()

func timeString(_ date: Date) -> String { shortTimeFmt.string(from: date) }

func formatDuration(_ seconds: TimeInterval) -> String {
  guard seconds.isFinite && seconds >= 0 else { return "" }
  let m = Int(seconds) / 60
  let s = Int(seconds) % 60
  return String(format: "%dm%02ds", m, s)
}

func formatETA(_ seconds: TimeInterval) -> String {
  guard seconds.isFinite && seconds >= 0 else { return "--:--" }
  let m = Int(seconds) / 60
  let s = Int(seconds) % 60
  return String(format: "%d:%02d", m, s)
}
