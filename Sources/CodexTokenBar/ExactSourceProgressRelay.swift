import Foundation

/// Shares the real file counter with bounded source-byte notifications from
/// up to four parser workers. Bytes are informational; no timer completes work.
final class ExactSourceProgressRelay: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let callback: ((PreciseIndexProgress) -> Void)?
    private let clock: () -> TimeInterval
    private var current: PreciseIndexProgress?
    private var lastNotification: TimeInterval = -.infinity

    init(_ callback: ((PreciseIndexProgress) -> Void)?,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.callback = callback; self.clock = clock
    }

    func report(_ progress: PreciseIndexProgress) {
        lock.lock(); defer { lock.unlock() }
        let previousPhase = current?.phase
        current = progress
        let now = clock()
        let finalCount = progress.total.map { $0 > 0 && progress.completed >= $0 } ?? false
        guard previousPhase != progress.phase || finalCount || progress.phase == .failed
                || now - lastNotification >= 0.25 else { return }
        lastNotification = now
        callback?(progress)
    }

    func sourceBytes(_ read: UInt64, total: UInt64) {
        guard callback != nil, total > 0, read > 0, read <= total else { return }
        lock.lock(); defer { lock.unlock() }
        guard let current, [.scanning, .backfillingModel].contains(current.phase) else { return }
        let now = clock()
        guard now - lastNotification >= 0.25 else { return }
        lastNotification = now
        let mib: (UInt64) -> String = { String(format: "%.1f MiB", Double($0) / 1_048_576) }
        callback?(PreciseIndexProgress(phase: current.phase,
            message: current.message + "；当前来源已读取 \(mib(read)) / \(mib(total))",
            completed: current.completed, total: current.total, fraction: current.fraction))
    }
}
