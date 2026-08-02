import Foundation

/// kqueue-backed watcher for a single directory (entry create/delete/rename).
/// Content changes inside existing files do NOT fire — the agents poll covers those.
public final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let queue = DispatchQueue(label: "com.millisecond.agentsandrepos.dirwatcher")
    private var pending: DispatchWorkItem?

    public init?(path: String, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { onChange() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
