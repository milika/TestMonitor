import Foundation

/// Watches a file for new content using kernel-level DispatchSource events.
/// Zero polling — wakes only on write events.
final class LogWatcher {
  private let path: String
  private let onNewContent: (String) -> Void
  /// Called when the file is truncated — signals a new test run starting.
  var onTruncated: (() -> Void)?

  private var fileSource: DispatchSourceFileSystemObject?
  private var dirSource: DispatchSourceFileSystemObject?
  private var pollTimer: DispatchSourceTimer?
  // O_EVTONLY fd — used solely for DispatchSource event subscription (cannot read from it)
  private var eventDescriptor: Int32 = -1
  // O_RDONLY fd — used for actually reading file content
  private var readDescriptor: Int32 = -1
  private var currentOffset: UInt64 = 0

  private let queue = DispatchQueue(label: "com.testmonitor.logwatcher", qos: .utility)

  init(path: String, onNewContent: @escaping (String) -> Void) {
    self.path = path
    self.onNewContent = onNewContent
  }

  func start() {
    openAndWatch()
    watchParentDirectory()
    startPollTimer()
  }

  func stop() {
    pollTimer?.cancel()
    pollTimer = nil
    fileSource?.cancel()
    dirSource?.cancel()
    fileSource = nil
    dirSource = nil
    if eventDescriptor != -1 {
      Darwin.close(eventDescriptor)
      eventDescriptor = -1
    }
    if readDescriptor != -1 {
      Darwin.close(readDescriptor)
      readDescriptor = -1
    }
  }

  // MARK: Private

  private func openAndWatch() {
    // Event fd: O_EVTONLY so we don't prevent the file from being deleted/unmounted
    let evtFd = Darwin.open(path, O_EVTONLY)
    guard evtFd != -1 else { return }
    eventDescriptor = evtFd

    // Read fd: O_RDONLY so we can actually read content (O_EVTONLY forbids read/write)
    let rdFd = Darwin.open(path, O_RDONLY)
    guard rdFd != -1 else {
      Darwin.close(evtFd)
      eventDescriptor = -1
      return
    }
    readDescriptor = rdFd
    currentOffset = 0

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: evtFd,
      eventMask: .write,
      queue: queue
    )
    src.setEventHandler { [weak self] in self?.readNewContent() }
    src.setCancelHandler { Darwin.close(evtFd) }
    src.resume()
    fileSource = src

    // Drain any content already in the file.
    readNewContent()
  }

  private func readNewContent() {
    guard readDescriptor != -1 else { return }
    let fileSize = lseek(readDescriptor, 0, SEEK_END)

    // File was truncated — new run started.
    if fileSize < Int64(currentOffset) {
      currentOffset = 0
      DispatchQueue.main.async { self.onTruncated?() }
    }

    guard fileSize > Int64(currentOffset) else { return }

    let bytesToRead = Int(fileSize) - Int(currentOffset)
    var buffer = [UInt8](repeating: 0, count: bytesToRead)
    lseek(readDescriptor, Int64(currentOffset), SEEK_SET)
    let bytesRead = read(readDescriptor, &buffer, bytesToRead)
    guard bytesRead > 0 else { return }

    currentOffset += UInt64(bytesRead)
    if let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
      onNewContent(text)
    }
  }

  /// Watch the parent directory so we detect file creation before a run starts.
  private func watchParentDirectory() {
    let dir = (path as NSString).deletingLastPathComponent
    let dirFd = Darwin.open(dir, O_EVTONLY)
    guard dirFd != -1 else { return }

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: dirFd,
      eventMask: .write,
      queue: queue
    )
    src.setEventHandler { [weak self] in
      guard let self, self.eventDescriptor == -1 else { return }
      self.openAndWatch()
    }
    src.setCancelHandler { Darwin.close(dirFd) }
    src.resume()
    dirSource = src
  }

  /// Fallback 10-second poll — catches write events that DispatchSource may miss
  /// (e.g. file was already being written before the watcher was registered).
  private func startPollTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if self.eventDescriptor == -1 {
        self.openAndWatch()
      } else {
        self.readNewContent()
      }
    }
    timer.resume()
    pollTimer = timer
  }

  deinit { stop() }
}
