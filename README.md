# TestMonitor

A lightweight macOS SwiftUI app that watches `xcodebuild` log files and displays live test progress — pass/fail counts, per-worker breakdowns, ETA, and run timestamps — all in a native window and menu bar extra.

**Passive by design.** TestMonitor reads the log output your existing commands already produce. No process wrapping, no interception, zero CPU overhead during tests.

---

## What It Looks Like

```
┌─────────────────────────────────────────────────────┐
│  SmartTube UI Tests                      ⏱ ETA 4m22s │
│  🕐 Started 12:34:56 · Ended — · running…            │
│                                                       │
│  ████████████████░░░░░░░░░  67 / 155  (43%)           │
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

**Menu bar states:** gray `●` idle → `↻ UI Tests: 67/155 · ETA 4m22s` running → green `✓` passed → red `✗` failed.

When all suites are dismissed the menu bar popover shows "All clear — no active test runs".

---

## Features

### Progress & Results
- **Live progress bar** — updates incrementally as each test line lands in the log
- **Pass / fail / skip counts** with colour-coded icons per suite
- **Per-worker breakdown** bars for parallel test runs (any number of clones)
- **ETA** calculated from elapsed time and completion rate (shown after ≥5 results)
- **Accurate start/end timestamps** — parsed from the log itself, not wall-clock time
- **Total run duration** displayed once a suite completes (`Started 12:34:56 · Ended 12:38:41 · 4m05s`)
- **Recent results list** — last 20 test results, auto-scrolls to latest

### Navigation
- **Open log file** button (magnifying glass) — opens the raw log in the default text editor
- **Reveal xcresult in Finder** button — available for XCTest-based suites once the bundle is created
- **Dismiss** completed suites with × from either the main window **or** the menu bar popover — both stay in sync
- **"No active test runs"** empty state in the window when everything is dismissed
- **Open TestMonitor** button in the popover brings the window to front

### Shell Wrapper
- **Install / Remove** a transparent `xcodebuild` shell wrapper directly from the menu bar popover
- The wrapper patches `~/.zshrc` to auto-`tee` `xcodebuild test` output to the watched log files — no manual piping needed after a one-time install
- Status indicator (green / grey dot) shows whether the wrapper is currently active

### Developer Utility
- **Screenshot HTTP server** on `localhost:7777` — `GET /ss` returns a PNG of the TestMonitor window, useful for CI screenshot diffing or remote inspection:
  ```bash
  curl -s localhost:7777/ss > /tmp/ss.png && open /tmp/ss.png
  ```

---

## Requirements

| | |
|---|---|
| macOS | 14.0+ (Sonoma) |
| Xcode | 15+ |
| Swift | 5.9+ |

---

## How It Works

### For XCTest-based UI tests (xcresult watcher)

For `xcodebuild test` runs that produce xcresult bundles, TestMonitor uses `XCResultWatcher`: it watches the DerivedData `Logs/Test/` directory for new `.xcresult` bundles, then streams each worker's `StandardOutputAndStandardError.txt` from the Staging area as it is written. The xcresult bundle name encodes the actual run start time, which is used for accurate timestamps.

### For Swift Testing / unit tests (log watcher)

For plain log files, TestMonitor uses `LogWatcher` (`DispatchSource.makeFileSystemObjectSource` with `O_EVTONLY`). Bytes are read incrementally from a tracked offset — the file is never re-read from the start. The parent directory is also watched so monitoring begins before the log file is created.

### Shell wrapper (optional)

Instead of manually piping to `tee`, install the shell wrapper once. It wraps the `xcodebuild` command in `~/.zshrc`:

```bash
# After installing the wrapper, just run xcodebuild normally:
xcodebuild test -scheme SmartTubeTests …
# TestMonitor automatically receives the output via tee
```

To install without the app: add this to `~/.zshrc` manually and point the log paths at what TestMonitor watches.

### Parsed log patterns

```
Test Suite 'SuiteName' started at 2026-05-11 12:34:56.789
Test Case '-[Suite testName]' started.
Test Case '-[Suite testName]' passed (2.341 seconds).
Test Case '-[Suite testName]' failed (5.012 seconds).
Test Case '-[Suite testName]' skipped (0.001 seconds).
** TEST SUCCEEDED **
** TEST FAILED **
```

Worker index is inferred from the `Clone N` path in parallel test session result lines. Swift Testing format (`✔ Test "name" passed after X seconds.`) is also supported.

---

## Project Structure

```
TestMonitor/
├── Core/
│   ├── LogWatcher.swift          # DispatchSource file watcher (O_EVTONLY)
│   ├── XCResultWatcher.swift     # xcresult bundle + Staging area watcher for XCTest
│   ├── TestResultParser.swift    # Incremental line parser (XCTest + Swift Testing)
│   ├── TestRunState.swift        # @Observable state model, ETA, xcresult path
│   ├── ProcessDetector.swift     # pgrep-based xcodebuild process detection
│   ├── ShellWrapperManager.swift # ~/.zshrc wrapper install / remove
│   └── ScreenshotServer.swift    # HTTP server — GET /ss returns a window PNG
├── ContentView.swift             # Main window: suite cards, progress, worker bars
├── MenuBarView.swift             # MenuBarExtra label, popover, shell wrapper toggle
└── TestMonitorApp.swift          # App entry point, suite configuration
```

---

## Configuration

Suites are configured in `TestMonitorApp.swift`:

```swift
@State private var suites: [TestRunState] = [
    TestRunState(
        suiteName: "SmartTube UI Tests",
        totalKnown: 155,
        logPath: "/tmp/smarttube-parallel-test.log",
        workerCount: 5,
        xcresultLogsDir: "~/Library/Developer/Xcode/DerivedData/SmartTube-<hash>/Logs/Test"
    ),
    TestRunState(
        suiteName: "SmartTube Unit Tests",
        totalKnown: 304,
        logPath: "/tmp/smarttube-unit-tests.log",
        workerCount: 1
    ),
]
```

| Property | Description |
|---|---|
| `suiteName` | Display name shown in the window and menu bar |
| `totalKnown` | Expected total test count (used for progress bar and ETA) |
| `logPath` | Absolute path to the log file being tailed |
| `workerCount` | Number of parallel workers (1 for serial runs) |
| `xcresultLogsDir` | *(optional)* DerivedData `Logs/Test/` path; enables xcresult bundle watching for XCTest suites |

---

## Building

```bash
# Generate the Xcode project (requires xcodegen)
brew install xcodegen
xcodegen generate

# Open in Xcode
open TestMonitor.xcodeproj
```

Command-line build:

```bash
xcodebuild -project TestMonitor.xcodeproj \
           -scheme TestMonitor \
           -configuration Debug \
           build
```

---

## Testing the UI Without a Real Test Run

Pipe fake xcodebuild output into a log file to exercise all UI states:

```bash
# Start a fake run
echo "Test Suite 'SmartTubeUITests' started at $(date '+%Y-%m-%d %H:%M:%S.000')." \
  >> /tmp/smarttube-parallel-test.log

# Stream passing tests
for name in testA testB testC testD testE testF; do
  echo "Test Case '-[HomeUITests $name]' passed ($(python3 -c 'import random; print(round(random.uniform(0.5,5),3))') seconds)." \
    >> /tmp/smarttube-parallel-test.log
  sleep 0.3
done

# Inject a failure
echo "Test Case '-[HomeUITests testBroken]' failed (5.001 seconds)." \
  >> /tmp/smarttube-parallel-test.log

# Finish
echo "** TEST FAILED **" >> /tmp/smarttube-parallel-test.log
```

---

## Architecture Notes

- **`@Observable`** (Swift 5.9 / macOS 14) — no `ObservableObject` boilerplate; shared reference type means dismiss state is automatically in sync between the window and menu bar
- **`MenuBarExtra`** with `.window` style — native popover, no `NSStatusItem` hacks
- **`O_EVTONLY`** file descriptor — won't block deletion or rotation of the log file
- Parent directory is also watched so monitoring begins before the log file is created
- **`XCResultWatcher`** parses the xcresult bundle directory name timestamp (e.g. `Test-SmartTube-2026.05.11_15-57-21-+0200.xcresult`) for accurate run start times independent of when the app launched

---

## License

MIT
