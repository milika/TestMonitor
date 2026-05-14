import SwiftUI

// MARK: - Root Window

struct ContentView: View {
  var suites: [TestRunState]

  @State private var logHeights: [UUID: CGFloat] = [:]

  private var visible: [TestRunState] { suites.filter { !$0.isDismissed } }

  private func logHeightBinding(for state: TestRunState) -> Binding<CGFloat> {
    Binding(
      get: { self.logHeights[state.id] ?? 120 },
      set: { self.logHeights[state.id] = $0 }
    )
  }

  var body: some View {
    Group {
      if visible.isEmpty {
        emptyState
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, state in
              SuiteProgressView(state: state, logHeight: logHeightBinding(for: state).wrappedValue)
                .padding(20)
              if idx < visible.count - 1 {
                DragHandleDivider(height: logHeightBinding(for: state))
              }
            }
          }
        }
      }
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 320)
    .background(.windowBackground)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 44))
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
  var logHeight: CGFloat = 120

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headerRow
      timeRow
      overallBar
      if state.isParallelRun {
        WorkerBarsView(state: state)
      }
      RecentResultsView(results: state.results, logHeight: logHeight)
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
          .tooltip("Estimated time remaining")
      } else if let verdict = state.verdict {
        VerdictBadge(verdict: verdict)
      }
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: state.logPath))
      } label: {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .tooltip("Open log: \(state.logPath)")
      if let xcresult = state.xcresultPath {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: xcresult)])
        } label: {
          Image(systemName: "folder.badge.gearshape")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .tooltip("Reveal in Finder: \(xcresult)")
      }
      Button {
        state.isDismissed = true
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
          .padding(4)
          .background(Color.red.opacity(0.75), in: Circle())
      }
      .buttonStyle(.plain)
      .tooltip("Dismiss")
    }
  }

  @ViewBuilder
  private var timeRow: some View {
    if let start = state.startTime {
      HStack(spacing: 4) {
        Image(systemName: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
          .tooltip("Run start time")
        Text("Started \(timeString(start))")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if let end = state.endTime {
          Text("·")
            .foregroundStyle(.tertiary)
          Text("Ended \(timeString(end))")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(formatDuration(end.timeIntervalSince(start)))
            .font(.footnote.bold())
            .foregroundStyle(.secondary)
        } else {
          Text("· running…")
            .font(.footnote)
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
        Group {
          if state.totalIsConfirmed {
            Text("\(state.completed) / \(state.totalKnown)  (\(Int(state.progressFraction * 100))%)")
          } else if state.completed > 0 {
            Text("\(state.completed) / ?")
          } else {
            Text("waiting…")
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        Spacer()
        HStack(spacing: 10) {
          StatusCount(count: state.passed,  icon: "checkmark",             color: .green,    hint: "Passed")
          StatusCount(count: state.failed,  icon: "xmark",                 color: .red,      hint: "Failed")
          StatusCount(count: state.skipped, icon: "arrow.counterclockwise", color: .secondary, hint: "Skipped")
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
      ForEach(Array(1...state.detectedWorkerCount), id: \.self) { index in
        let count = state.perWorkerResults[index]?.count ?? 0
        let perWorkerTotal = state.totalIsConfirmed ? max(state.totalKnown / state.detectedWorkerCount, 1) : 0
        let perWorkerTotalStr = perWorkerTotal > 0 ? "\(perWorkerTotal)" : "?"
        HStack(spacing: 8) {
          Text("Worker \(index)")
            .font(.footnote)
            .frame(width: 64, alignment: .leading)
          ProgressView(value: Double(count), total: perWorkerTotal > 0 ? Double(perWorkerTotal) : Double(max(count, 1)))
            .progressViewStyle(.linear)
          Text("\(count)/\(perWorkerTotalStr)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
        }
      }
    }
  }
}

// MARK: - Recent Results

struct RecentResultsView: View {
  let results: [TestResult]
  var logHeight: CGFloat = 120

  private var recent: [TestResult] {
    Array(results.suffix(20))
  }

  var body: some View {
    if recent.isEmpty { EmptyView() } else {
      VStack(alignment: .leading, spacing: 2) {
        Text("Recent:")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(recent) { result in
                HStack(spacing: 6) {
                  Image(systemName: result.status.icon)
                    .foregroundStyle(result.status.color)
                    .frame(width: 14)
                    .tooltip(result.status.label)
                  Text("\(result.suite).\(result.name)")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                  Spacer()
                  Text(String(format: "%.1fs", result.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .id(result.id)
              }
            }
          }
          .frame(height: max(60, logHeight))
          .onChange(of: recent.last?.id) { _, newID in
            if let id = newID {
              withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
          }
          .onAppear {
            if let id = recent.last?.id {
              proxy.scrollTo(id, anchor: .bottom)
            }
          }
        }
      }
    }
  }
}

// MARK: - Drag Handle Divider

struct DragHandleDivider: View {
  @Binding var height: CGFloat
  @State private var isDragging = false
  @State private var dragStartHeight: CGFloat = 0

  var body: some View {
    ZStack {
      Rectangle()
        .fill(isDragging ? Color.accentColor.opacity(0.15) : Color.clear)
        .frame(height: 12)
        .contentShape(Rectangle())
      Divider()
      Capsule()
        .fill(isDragging ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.2))
        .frame(width: 36, height: 4)
    }
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { value in
          if !isDragging {
            isDragging = true
            dragStartHeight = height
          }
          // Dragging up (negative y) grows the pane above, down shrinks it
          height = max(60, dragStartHeight - value.translation.height)
        }
        .onEnded { _ in isDragging = false }
    )
    .onHover { hovering in
      if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
    .animation(.easeInOut(duration: 0.1), value: isDragging)
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
  let hint: String

  var body: some View {
    Label("\(count)", systemImage: icon)
      .foregroundStyle(color)
      .font(.footnote)
      .tooltip("\(count) \(hint.lowercased())")
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

  var label: String {
    switch self {
    case .passed:  return "Passed"
    case .failed:  return "Failed"
    case .skipped: return "Skipped"
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
