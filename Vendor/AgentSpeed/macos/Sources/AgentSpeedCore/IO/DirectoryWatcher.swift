import CoreServices
import Foundation

/// File-level FSEvents stream for a set of directories, delivered on a caller-provided serial queue.
final class DirectoryWatcher: @unchecked Sendable {
    struct Event: Sendable {
        var path: String
        /// The stream lost events or a root changed; callers should rescan.
        var needsRescan: Bool
    }

    typealias Handler = @Sendable ([Event]) -> Void

    /// Owns the handler; retained by the stream context so callbacks never outlive it.
    private final class Callback {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?

    /// Returns nil when FSEvents refuses the stream (for example when no path exists).
    init?(paths: [String], queue: DispatchQueue, latency: TimeInterval = 0.1, handler: @escaping Handler) {
        guard !paths.isEmpty else { return nil }
        let callback = Callback(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Callback>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Stops delivery. Call on the delivery queue so no callback runs concurrently.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
    )

    private static let streamCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = array[index] as? String else { continue }
            events.append(Event(path: path, needsRescan: flags[index] & rescanFlags != 0))
        }
        callback.handler(events)
    }
}
