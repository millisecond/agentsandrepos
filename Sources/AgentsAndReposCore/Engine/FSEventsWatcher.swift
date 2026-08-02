import CoreServices
import Foundation

/// FSEvents-backed recursive watcher over a set of directory trees.
/// Delivers coalesced batches of changed file paths (file-level granularity).
/// Complements `DirectoryWatcher`, which covers a single non-recursive dir.
public final class FSEventsWatcher: @unchecked Sendable {
    private final class Box {
        let onEvents: @Sendable ([String]) -> Void
        init(_ fn: @escaping @Sendable ([String]) -> Void) { onEvents = fn }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.millisecond.agentsandrepos.fsevents")

    /// `latency` is FSEvents' coalescing window; with `.noDefer` the first
    /// event in a burst is delivered immediately and the rest batch up.
    public init?(
        paths: [String], latency: TimeInterval = 2.0,
        onEvents: @escaping @Sendable ([String]) -> Void
    ) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        let box = Box(onEvents)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil)

        // The C callback must not capture anything; the box rides in `info`
        // and is released by the context's release callback on invalidate.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<NSArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String]
            else { return }
            box.onEvents(paths)
        }

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, existing as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes
                        | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagNoDefer))
        else {
            Unmanaged.passUnretained(box).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
