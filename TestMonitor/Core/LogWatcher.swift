import Foundation

/// Watches a file for new content using kernel-level DispatchSource events.
/// Zero polling — wakes only on write events.
final class LogWatcher {
  private let path: String
  private let onNewContent: (String) -> Void

  private var fileSource: DispatchSourceFileSystemObject?
  private var dirSource: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var currentOffset: UInt64 = 0

  private let queue = DispatchQueue(label: "com.testmonitor.logwatcher", qos: .utility)

  init(path: String, onNewContent: @escaping (String) -> Void) {
    self.path = path
    self.onNewContent = onNewContent
  }

  func start() {
    openAndWatch()
    watchParentDirectory()
  }

  func stop() {
    fileSource?.cancel()
    dirSource?.cancel()
    fileSource = nil
    dirSource = nil
    if fileDescriptor != -1 {
      Darwin.close(fileDescriptor)
      fileDescriptor = -1
    }
  }

  // MARK: Private

  private func openAndWatch() {
    let fd = Darwin.open(path, O_EVTONLY)
    guard fd != -1 else { return }
    fileDescriptor = fd
    currentOffset = 0

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: .write,
      queue: queue
    )
    src.setEventHandler { [weak self] in self?.readNewContent() }
    src.setCancelHandler { Darwin.close(fd) }
    src.resume()
    fileSource = src

    // Drain any content already in the file.
    readNewContent()
  }

  private func readNewContent() {
    guard fileDescriptor != -1 else { return }
    let fileSize = lseek(fileDescriptor, 0, SEEK_END)
    guard fileSize > Int64(currentOffset) else { return }

    let bytesToRead = Int(fileSize) - Int(currentOffset)
    var buffer = [UInt8](repeating: 0, count: bytesToRead)
    lseek(fileDescriptor, Int64(currentOffset), SEEK_SET)
    let bytesRead = read(fileDescriptor, &buffer, bytesToRead)
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
      guard let self, self.fileDescriptor == -1 else { return }
      self.openAndWatch()
    }
    src.setCancelHandler { Darwin.close(dirFd) }
    src.resume()
    dirSource = src
  }

  deinit { stop() }
}
