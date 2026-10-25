import Foundation

/// Measures network traffic (METRICS 10) and publishes it to a `TrafficStore`: this computer's interfaces every second,
/// per-process counters from a `nettop` child while agent processes run, attributed to sources and agent trees, and
/// the stored daily totals. Every method is called on the main actor; the work runs on a private serial queue and the
/// store is updated once per tick.
@MainActor
public final class TrafficMonitor {
    public let storeURL: URL
    private let store: TrafficStore
    private var core: TrafficCore?

    public init(store: TrafficStore, storeURL: URL = HistoryService.defaultStoreURL) {
        self.store = store
        self.storeURL = storeURL
    }

    /// True between `start(enabled:)` and `stop()`.
    public var isRunning: Bool { core != nil }

    /// Loads the stored days and, when `enabled` (`trafficEnabled`), starts sampling.
    public func start(enabled: Bool) {
        guard core == nil else {
            setEnabled(enabled)
            return
        }
        let core = TrafficCore(
            storePath: storeURL.path,
            publish: { [weak store] snapshot in store?.publish(snapshot) },
            publishDays: { [weak store] days, since in store?.publish(days: days, since: since) })
        self.core = core
        if !enabled { store.publish(.off) }
        core.start(enabled: enabled)
    }

    /// Off stops nettop at once and publishes `TrafficSnapshot.off`; on starts a new stream.
    public func setEnabled(_ enabled: Bool) {
        core?.setEnabled(enabled)
    }

    /// At quit: writes today's totals and kills and reaps the nettop child before returning.
    public func stop() {
        core?.stop()
        core = nil
    }

    /// Writes today's totals now (before sleep).
    public func flush() {
        core?.flush()
    }

    /// The agents of every `SpeedSnapshot` (METRICS 6.7): candidates for per-agent traffic and the adaptive interval.
    public func update(agents: [AgentStatus]) {
        core?.update(agents: agents)
    }

    /// True while a visible surface shows per-source or per-agent traffic (METRICS 10.10: nettop then runs at 1 s).
    public func setDetailDemand(_ shown: Bool) {
        core?.setDetailDemand(shown)
    }

    /// Settings → Retry after `unavailable(sampler)`.
    public func retry() {
        core?.retry()
    }

    /// Call right before `HistoryService.clear()` deletes the database: today's totals restart at zero, no pending
    /// write survives, and the next write recreates today's rows in the new file.
    public func clearHistory() {
        core?.clearHistory()
    }

    /// Diagnostics (the probe): a fixed nettop interval in seconds, 0 for standby, nil for the adaptive cadence.
    public func setForcedInterval(_ seconds: Int?) {
        core?.setForcedInterval(seconds)
    }

    /// Diagnostics (the probe): classified processes, nettop state and the average tick cost.
    public func diagnostics() -> TrafficDiagnostics? {
        core?.diagnostics()
    }
}
