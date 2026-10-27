import AgentSpeedCore
import Foundation

/// A process-local owner for the upstream non-Claude transcript reader. Display
/// and opt-in reporting share a monitor, never each start a Codex tailer.
/// Claude uses its separately constrained local-only reader and is not admitted.
@MainActor
final class SharedAgentSpeedMonitorPool {
    static let shared = SharedAgentSpeedMonitorPool()
    private struct Subscriber {
        let store: SpeedStore
        let sources: Set<SourceKind>
    }
    @MainActor private final class Entry {
        let store = SpeedStore()
        let monitor: LiveMonitor
        var subscribers: [UUID: Subscriber] = [:]
        init(root: URL?) {
            monitor = LiveMonitor(store: store, configuration: .init(enabledSources: [], codexRoot: root), pricing: PriceBook())
        }
    }
    private var entries: [String: Entry] = [:]
    private let factory: ((URL?) -> Void)?
    init(onCreate: ((URL?) -> Void)? = nil) { factory = onCreate }

    func lease(store: SpeedStore, sources: Set<SourceKind>, codexRoot: URL? = nil) -> any AgentSpeedReportingMonitor {
        Lease(pool: self, store: store, sources: sources.subtracting([.claudeCode, .claudeDesktop]), root: codexRoot)
    }
    private func start(id: UUID, store: SpeedStore, sources: Set<SourceKind>, root: URL?) {
        guard !sources.isEmpty else { return }
        let key = (root ?? LiveMonitor.defaultCodexRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let entry: Entry
        if let saved = entries[key] { entry = saved }
        else {
            factory?(root)
            entry = Entry(root: root)
            entries[key] = entry
            _ = entry.store.addLiveListener { [weak entry] snapshot in
                guard let entry else { return }
                for subscriber in entry.subscribers.values { subscriber.store.publishLive(snapshot) }
            }
            _ = entry.store.addEventListener { [weak entry] event in
                guard let entry else { return }
                for subscriber in entry.subscribers.values {
                    subscriber.store.publishLive(entry.store.liveSnapshot, events: [event])
                }
            }
        }
        entry.subscribers[id] = .init(store: store, sources: sources)
        var config = entry.monitor.configuration
        config.enabledSources = entry.subscribers.values.reduce(into: Set<SourceKind>()) { $0.formUnion($1.sources) }
        entry.monitor.update(configuration: config)
        if !entry.monitor.isRunning { entry.monitor.start() }
    }
    private func stop(id: UUID) {
        for (key, entry) in entries where entry.subscribers.removeValue(forKey: id) != nil {
            if entry.subscribers.isEmpty { entry.monitor.stop(); entries.removeValue(forKey: key) }
            else {
                var config = entry.monitor.configuration
                config.enabledSources = entry.subscribers.values.reduce(into: Set<SourceKind>()) { $0.formUnion($1.sources) }
                entry.monitor.update(configuration: config)
            }
            break
        }
    }
    private final class Lease: AgentSpeedReportingMonitor {
        let pool: SharedAgentSpeedMonitorPool
        let store: SpeedStore
        let sources: Set<SourceKind>
        let root: URL?
        let id = UUID()
        var started = false
        init(pool: SharedAgentSpeedMonitorPool, store: SpeedStore, sources: Set<SourceKind>, root: URL?) {
            self.pool = pool; self.store = store; self.sources = sources; self.root = root
        }
        func start() { guard !started else { return }; started = true; pool.start(id: id, store: store, sources: sources, root: root) }
        func stop() { guard started else { return }; started = false; pool.stop(id: id) }
    }
}
