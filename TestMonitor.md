# TestMonitor — macOS Test Progress App

> **Status: Built and running** — `TestMonitor.xcodeproj` exists at the repo root, builds clean on macOS 14+, and is live. See [progress.md](progress.md) for a full change log.

A lightweight macOS SwiftUI app that watches xcodebuild log files and shows live progress bars, pass/fail counts, and ETA in a native window. No wrapping, no interception — purely a passive observer.

---

## Core Design Principle

**No wrapping, no interception.** You keep running the exact same commands as always. TestMonitor reads the log files those commands already `tee` to:

- `/tmp/smarttube-parallel-test.log` — UI tests (parallel, 5 workers)
- `/tmp/smarttube-unit-tests.log` — unit tests (single worker)

---

## Window Layout

```
┌─────────────────────────────────────────────────────┐
│  SmartTube UI Tests                      ⏱ ETA 4m22s │
│                                                       │
│  ████████████████░░░░░░░░░  67 / 101  (66%)           │
│  ✓ 61  ✗ 4  ↷ 2                                       │
│                                                       │
│  Worker 1  ██████████  22 tests                       │
│  Worker 2  ████████░░  18 tests                       │
│  Worker 3  █████░░░░░  11 tests                       │
│  Worker 4  ████░░░░░░   9 tests                       │
│  Worker 5  ███░░░░░░░   7 tests                       │
│                                                       │
│  Recent:                                              │
│  ✓ PlayerControlsUITests.testPlayPause      2.3s      │
│  ✗ SubscriptionsUITests.testListLoads       5.0s      │
│  ✓ HomeUITests.testHomeFeedLoads            3.1s      │
└─────────────────────────────────────────────────────┘
```

Also lives in the menu bar:
- Idle → gray dot
- Running → blue spinner with `UI Tests: 67/101 · ETA 4m22s`
- Passed → green ✓
- Failed → red ✗

> **Implemented.** The menu bar extra uses `MenuBarExtra` (macOS 13+) with `.window` style. The label component (`MenuBarLabel`) switches between idle/running/pass/fail states reactively.

---

## Architecture

### 1. `LogWatcher.swift` — File Watcher ✅

`DispatchSource.makeFileSystemObjectSource` on the log file path. Kernel-level file event — zero polling, zero overhead.

- Open file with `O_EVTONLY` (read-only, won't block deletion)
- Watch for `.write` events
- On event: read bytes from `currentOffset` to `fileSize`, advance offset
- Re-arm after each event
- Also watch the parent dir for file creation so monitor can start before the run begins

### 2. `TestResultParser.swift` — Incremental Line Parser ✅

Parses xcodebuild output line by line as it arrives. Key patterns matched:

```
Test Case '-[Suite testName]' started.
Test Case '-[Suite testName]' passed (2.341 seconds).
Test Case '-[Suite testName]' failed (5.012 seconds).
Test Case '-[Suite testName]' skipped (0.001 seconds).

# Worker inference: parallel clone paths contain a worker index
Test session results, code coverage, and logs in:
  ~/Library/Developer/.../Clone N/...

# Run start timestamp (used for accurate start time)
Test Suite 'SmartTubeUITests' started at 2026-05-11 12:34:56.789

# Overall verdict
** TEST SUCCEEDED **
** TEST FAILED **
```

Extracts per-test: suite, name, status, duration, worker index.  
Also extracts `startDate` from the `Test Suite '...' started at` line — so runs already completed in the terminal show their actual start time, not app-launch time.

### 3. `TestRunState.swift` — State Model ✅

`@Observable` class (Swift 5.9 / macOS 14):

```swift
struct TestResult: Identifiable {
    let id: UUID
    let suite: String
    let name: String
    let status: TestStatus      // .passed / .failed / .skipped
    let duration: TimeInterval
    let workerIndex: Int        // 0 = unknown, 1–5 = parallel clone
}

@Observable
final class TestRunState: Identifiable {
    let workerCount: Int        // 5 for UI tests, 1 for unit tests
    var results: [TestResult] = []
    var startTime: Date?        // from log timestamp or first result
    var endTime: Date?          // stamped on ** TEST SUCCEEDED/FAILED **
    var isRunning: Bool = false
    var verdict: Verdict?       // nil = in progress
    var isDismissed: Bool = false   // hides card from main window

    var passed:    Int { ... }
    var failed:    Int { ... }
    var skipped:   Int { ... }
    var completed: Int { results.count }
    var progressFraction: Double { ... }
    var eta: TimeInterval? { ... }          // only after ≥ 5 completions
    var perWorkerResults: [Int: [TestResult]] { ... }
}
```

### 4. `ContentView.swift` — Main Window ✅

- Takes `suites: [TestRunState]`; renders only non-dismissed suites
- Shows "No active test runs" empty state when all are dismissed
- Each suite card shows:
  - Title + ETA (while running) or verdict badge (when done)
  - `Started HH:mm:ss · Ended HH:mm:ss · Xm YYs` time row
  - Overall `ProgressView` with counts (✓ / ✗ / ↷)
  - Worker bars (`WorkerBarsView`) for suites with `workerCount > 1`
  - Last 20 results list, color-coded, with duration
  - × dismiss button (visible when not running)
- ETA formatted as `m:ss`, shown only after ≥ 5 tests complete

### 5. `MenuBarView.swift` — Menu Bar Extra ✅

`MenuBarExtra` (macOS 13+):
- Compact label: `67/101 · 4m22s`
- Click → opens main window
- Icon animates while running
- Popover shows compact rows for every suite with start → end times and progress bar

### 6. `ProcessDetector.swift` — Auto-Start (Implemented, not yet wired) ✅

Polls `pgrep` every 2 s to detect when an xcodebuild test process starts or ends.  
Built but not yet connected to `TestRunState.reset()` — wiring it up is a backlog item.

```swift
// Option A: poll pgrep every 2s (implemented)
let detector = ProcessDetector(grepPattern: "xcodebuild.*SmartTubeUITests") {
    state.reset(); state.startWatching()
} onEnded: {
    // log watcher stays alive; verdict arrives via log
}
detector.start()

// Option B: NSWorkspace process launch notifications (not implemented)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didLaunchApplicationNotification, ...
)
```

---

## Project Structure

```
TestMonitor/                          (repo root)
├── TestMonitor.xcodeproj/            ← generated by xcodegen
├── project.yml                       ← xcodegen source of truth
├── progress.md                       ← change log
├── TestMonitor.md                    ← this file
└── TestMonitor/                      ← Swift sources
    ├── TestMonitorApp.swift          # @main — suites array, WindowGroup + MenuBarExtra
    ├── MenuBarView.swift             # MenuBarLabel, MenuBarView, CompactSuiteRow
    ├── ContentView.swift             # SuiteProgressView, WorkerBarsView, RecentResultsView
    ├── Assets.xcassets/
    └── Core/
        ├── LogWatcher.swift          # DispatchSource file watcher
        ├── TestResultParser.swift    # incremental regex line parser + startDate
        ├── TestRunState.swift        # @Observable state model + ETA + dismiss
        └── ProcessDetector.swift    # pgrep-based auto-start detection
```

Standalone Xcode project — nothing to do with SmartTube.xcworkspace.

---

## Known Totals

| Suite | Total | Workers | Log file |
|---|---|---|---|
| `SmartTubeUITests` | 101 | 5 | `/tmp/smarttube-parallel-test.log` |
| `SmartTubeIOSTests` | 57 | 1 | `/tmp/smarttube-unit-tests.log` |

ETA uses these as the denominator. The parser also auto-detects the total from the first `Test Suite '...' started at` line as a fallback.

---

## ETA Algorithm

Linear throughput extrapolation:

```
rate     = completed / elapsed_seconds
remaining = total - completed
eta       = remaining / rate
```

Only shown after ≥ 5 completions to avoid wild early estimates. Displayed as `m:ss`.

---

## Implementation Steps

1. New Xcode project → macOS → App → `TestMonitor`
2. `LogWatcher` — implement and test by tailing a dummy file: `while true; do echo "line" >> /tmp/test.log; sleep 0.5; done`
3. `TestResultParser` — implement with regex, write unit tests against saved log snippets from `/tmp/smarttube-parallel-test.log`
4. Wire `LogWatcher` → parser → `TestRunState`
5. `ContentView` — overall `ProgressView`, per-worker rows, recent list
6. `MenuBarExtra` — status label + color-changing icon
7. `ProcessDetector` — poll `ps` every 2s, auto-activate watcher when xcodebuild starts
8. End-to-end test against a live parallel run

---

## Requirements

- macOS 14+ (Sonoma)
- Swift 6, SwiftUI
- Zero dependencies — pure Foundation + SwiftUI

## Non-goals

- Does not start or stop test runs
- Does not parse `.xcresult` bundles
- Does not need App Sandbox (accesses `/tmp` and `~/Library/Developer`)
- No network, no authentication
