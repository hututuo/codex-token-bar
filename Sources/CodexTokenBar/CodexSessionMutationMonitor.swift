import CoreServices
import Foundation

enum CodexSessionMutationEventPolicy {
    private static let globalObservationLossFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUnmount
    )
    private static let destructiveItemFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
    )

    static func requiresContinuityCutover(
        flags: FSEventStreamEventFlags
    ) -> Bool {
        flags & (globalObservationLossFlags | destructiveItemFlags) != 0
    }

    static func requiresContinuityCutover(
        path: String?,
        flags: FSEventStreamEventFlags,
        watchedRoots: [String]
    ) -> Bool {
        if flags & globalObservationLossFlags != 0 { return true }
        guard flags & destructiveItemFlags != 0,
              let path else { return false }
        // FSEvents may report `/var/...` even when the watched root was opened
        // through its physical `/private/var/...` spelling. Resolve parent
        // symlinks even after the leaf has been removed so path comparison
        // cannot silently discard a real destructive event.
        let canonicalPath = canonicalSystemPath(path)
        let mayContainSessionJSONL = canonicalPath.lowercased().hasSuffix(".jsonl")
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard mayContainSessionJSONL else { return false }
        return watchedRoots.contains { root in
            let canonicalRoot = canonicalSystemPath(root)
            return canonicalPath == canonicalRoot
                || canonicalPath.hasPrefix(canonicalRoot + "/")
        }
    }

    private static func canonicalSystemPath(_ rawPath: String) -> String {
        var path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        // APFS firmlinks are not reported as symlinks by Foundation. FSEvents
        // nevertheless emits their physical `/private/...` spelling, while a
        // caller commonly registers `/var/...` or `/tmp/...`.
        for alias in ["/var", "/tmp", "/etc"] {
            if path == alias || path.hasPrefix(alias + "/") {
                path = "/private" + path
                break
            }
        }
        return path
    }
}

/// Recursively observes source removals while precise usage polling is active.
/// A create-consume-delete session can otherwise exist entirely between two
/// identical file-tree snapshots. Append/modify events remain on the normal
/// incremental path; only destructive or dropped observations create a
/// conservative continuity cutover.
final class CodexSessionMutationMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.codextokenbar.session-mutation-monitor",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var unsafeEventHandler: (@Sendable (Date) -> Void)?
    private var watchedRootPaths: [String] = []

    @discardableResult
    func start(
        roots: [URL],
        unsafeEventHandler: @escaping @Sendable (Date) -> Void
    ) -> Bool {
        stop()
        let paths = roots
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return false }

        stateLock.lock()
        self.unsafeEventHandler = unsafeEventHandler
        watchedRootPaths = paths
        stateLock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            createFlags
        ) else {
            clearHandler()
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            clearHandler()
            return false
        }
        // FSEventStreamStart schedules the stream asynchronously. Flush once
        // before reporting success so a JSONL that is created and removed
        // immediately after `start` cannot fall into the arming window.
        FSEventStreamFlushSync(stream)

        stateLock.lock()
        self.stream = stream
        stateLock.unlock()
        return true
    }

    func stop() {
        stateLock.lock()
        let stream = self.stream
        self.stream = nil
        unsafeEventHandler = nil
        watchedRootPaths = []
        stateLock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }

    private func clearHandler() {
        stateLock.lock()
        unsafeEventHandler = nil
        watchedRootPaths = []
        stateLock.unlock()
    }

    private func receive(
        count: Int,
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard count > 0 else { return }
        stateLock.lock()
        let roots = watchedRootPaths
        let handler = unsafeEventHandler
        stateLock.unlock()
        var unsafeMutationObserved = false
        for index in 0..<count {
            let path = index < paths.count ? paths[index] : nil
            if CodexSessionMutationEventPolicy.requiresContinuityCutover(
                path: path,
                flags: flags[index],
                watchedRoots: roots
            ) {
                unsafeMutationObserved = true
                break
            }
        }
        guard unsafeMutationObserved else { return }
        handler?(Date())
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, count, eventPaths, flags, _ in
        guard let clientInfo else { return }
        let cfPaths = Unmanaged<CFArray>
            .fromOpaque(eventPaths)
            .takeUnretainedValue()
        let paths = (cfPaths as NSArray).compactMap { $0 as? String }
        Unmanaged<CodexSessionMutationMonitor>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
            .receive(count: count, paths: paths, flags: flags)
    }
}
