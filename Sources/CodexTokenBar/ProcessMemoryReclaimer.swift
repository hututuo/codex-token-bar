import Darwin
import Foundation
import CSQLiteMemory

/// Return already-free allocator pages after a burst, once native resources
/// have been destroyed. This never purges live objects, files or SQLite rows.
enum ProcessMemoryReclaimer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pending = false
        var lastRun: TimeInterval = -.infinity
    }
    private static let state = State()

    static func schedule() {
        state.lock.lock()
        guard !state.pending else { state.lock.unlock(); return }
        state.pending = true
        let delay = max(2, 15 - (ProcessInfo.processInfo.systemUptime - state.lastRun))
        state.lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            _ = tb_sqlite_memory_reclaim()
            _ = malloc_zone_pressure_relief(nil, 0)
            state.lock.lock()
            state.pending = false
            state.lastRun = ProcessInfo.processInfo.systemUptime
            state.lock.unlock()
        }
    }
}
