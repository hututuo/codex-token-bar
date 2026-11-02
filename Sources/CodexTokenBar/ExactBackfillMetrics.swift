import Foundation

/// Opt-in timing of actual recovery work. No SQL values, paths, or user text
/// are captured. Release builds execute the original body directly.
enum ExactBackfillMetrics {
    enum Phase: String { case discovery, readyValidation, staging, sourceComparison, lineage, importing, projection, publication, cleanup }
    struct Snapshot { var seconds: [String: Double] = [:]; var calls: [String: Int] = [:] }
    #if DEBUG
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var active = false
        var snapshot = Snapshot()
    }
    private static let state = State()
    #endif

    static func begin() {
        #if DEBUG
        state.lock.lock(); defer { state.lock.unlock() }
        state.snapshot = Snapshot(); state.active = true
        #endif
    }
    static func end() -> Snapshot {
        #if DEBUG
        state.lock.lock(); defer { state.lock.unlock() }
        state.active = false; return state.snapshot
        #else
        return Snapshot()
        #endif
    }
    static func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        state.lock.lock(); let active = state.active; state.lock.unlock()
        guard active else { return try body() }
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            state.lock.lock(); defer { state.lock.unlock() }
            if state.active {
                state.snapshot.seconds[phase.rawValue, default: 0] += elapsed
                state.snapshot.calls[phase.rawValue, default: 0] += 1
            }
        }
        #endif
        return try body()
    }
}
