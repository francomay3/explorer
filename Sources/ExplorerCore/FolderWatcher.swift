import Darwin
import Foundation

/// Calls `onChange` on the main queue when entries are added to, removed from or renamed in a folder.
/// It does not see edits inside a file, because those do not touch the folder.
public final class FolderWatcher {
    public var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    /// A burst of changes, such as a download or a checkout, reports once.
    public init(debounce: TimeInterval = 0.15) {
        self.debounce = debounce
    }

    deinit { stop() }

    public func watch(_ url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
