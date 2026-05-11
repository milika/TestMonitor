# TestMonitor — Development Progress

---

## Status: Active

---

## Session 1 — Initial Build (May 11, 2026)

### What was built

Full macOS SwiftUI app from scratch matching the spec in `TestMonitor.md`.

**Core layer (`TestMonitor/Core/`)**

| File | Responsibility |
|------|----------------|
| `LogWatcher.swift` | Kernel-level `DispatchSource` file watcher. `O_EVTONLY` open, zero polling. Watches parent dir so monitor starts before file is created. |
| `TestResultParser.swift` | Incremental line parser. Regex-extracts suite, name, status, duration, worker index from xcodebuild output. Tracks verdict (`** TEST SUCCEEDED/FAILED **`). |
| `TestRunState.swift` | `@Observable` state model. Holds results, progress, ETA. Owns `LogWatcher` lifecycle. |
| `ProcessDetector.swift` | `pgrep`-based polling (2 s) to detect xcodebuild test processes starting/ending. |

**UI layer**

| File | Responsibility |
|------|----------------|
| `TestMonitorApp.swift` | `@main`. `WindowGroup` + `MenuBarExtra`. |
| `ContentView.swift` | Main progress window. Per-suite cards with progress bar, worker bars, recent results list. |
| `MenuBarView.swift` | Menu bar label (idle / running / pass / fail) and popover with compact suite rows. |

**Project**

- `project.yml` — xcodegen spec, macOS 14 deployment target, Swift 5.9
- Xcode project generated with `xcodegen generate`
- Build target: `com.testmonitor.TestMonitor`

---

## Session 2 — Start/End Time, Dismiss (May 11, 2026)

### Problem

Tests already run in a terminal leave completed output in the log. The app had no concept of when a run started/ended and showed everything without a way to clear it.

### Changes

**`TestResultParser.swift`**
- Added `startDate: Date?` — parsed from `Test Suite '...' started at YYYY-MM-DD HH:mm:ss.SSS` line in the log so actual run time is captured, not wall-clock time.

**`TestRunState.swift`**
- Added `endTime: Date?` — stamped when `** TEST SUCCEEDED/FAILED **` is parsed.
- Added `workerCount: Int` — passed in at init, used by `WorkerBarsView` instead of a hardcoded constant.
- Added `isDismissed: Bool` — toggled by the × button to hide a suite from the window.
- `reset()` now clears `endTime` and `isDismissed`.
- `ingest()` prefers the log-parsed `startDate` over wall-clock time.

**`ContentView.swift`**
- Takes `suites: [TestRunState]` instead of two named properties.
- Shows only `!isDismissed` suites. Shows "No active test runs" empty state when all are dismissed.
- Each suite card shows: `Started HH:mm:ss · Ended HH:mm:ss · Xm YYs` time row beneath the title.
- × dismiss button in the header (visible when not running).

**`MenuBarView.swift`**
- `MenuBarLabel` and `MenuBarView` take `suites: [TestRunState]`.
- `CompactSuiteRow` shows start → end time row.

**`TestMonitorApp.swift`**
- `suites` is now `[TestRunState]` — extensible without changing views.
- `workerCount: 5` passed for UI tests, `workerCount: 1` for unit tests.

---

## Known Totals

| Suite | Tests | Workers | Log |
|-------|-------|---------|-----|
| SmartTube UI Tests | 101 | 5 | `/tmp/smarttube-parallel-test.log` |
| SmartTube Unit Tests | 57 | 1 | `/tmp/smarttube-unit-tests.log` |

---

## Testing Manually

Pipe fake xcodebuild output to a log file to exercise the UI without running a full suite:

```bash
# Fake a run start
echo "Test Suite 'SmartTubeUITests' started at $(date '+%Y-%m-%d %H:%M:%S.000')." \
  >> /tmp/smarttube-parallel-test.log

# Fake passing tests
for name in testA testB testC testD testE testF; do
  echo "Test Case '-[HomeUITests $name]' passed ($(python3 -c 'import random; print(round(random.uniform(0.5,5),3))') seconds)." \
    >> /tmp/smarttube-parallel-test.log
  sleep 0.3
done

# Fake a failure
echo "Test Case '-[HomeUITests testBroken]' failed (5.001 seconds)." \
  >> /tmp/smarttube-parallel-test.log

# Finish the run
echo "** TEST SUCCEEDED **" >> /tmp/smarttube-parallel-test.log
```

---

## Backlog / Ideas

- [ ] Auto-reset when a new `Test Suite '...' started at` line appears in the same log (new run in same session)
- [ ] Persist last-run results across app restarts (write to `~/.testmonitor/`)
- [ ] Sound / notification on failure
- [ ] Click a failed test row to copy the test name to clipboard
- [ ] Show test duration histogram / slowest tests list
- [ ] Support arbitrary suites added at runtime (drag-drop a log file)
