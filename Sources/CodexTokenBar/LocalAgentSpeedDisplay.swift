import AgentSpeedCore
import AppKit
import Combine
import Foundation

/// One local reader, with separate presentation/reporting consumers. Acquiring a lease makes no network calls.
@MainActor
final class SharedAgentSpeedCollection {
    static let shared = SharedAgentSpeedCollection()
    private let store = SpeedStore()
    private var monitor: (any AgentSpeedReportingMonitor)?
    private let makeMonitor: (SpeedStore) -> any AgentSpeedReportingMonitor
    private var owners = Set<UUID>()
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    init(makeMonitor: @escaping (SpeedStore) -> any AgentSpeedReportingMonitor = { AgentSpeedCore.LiveMonitor(store: $0, pricing: PriceBook(), realtimeEventMode: true) }) {
        self.makeMonitor = makeMonitor
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.monitor?.stop(); self?.monitor = nil; self?.store.publishLive(.empty) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.reconcile() }
        })
    }
    func lease(for output: SpeedStore) -> any AgentSpeedReportingMonitor { SharedSpeedLease(hub: self, output: output) }
    fileprivate func attach(output: SpeedStore, id: UUID) -> UUID {
        owners.insert(id)
        let listener = store.addLiveListener { [weak output] snapshot in output?.publishLive(snapshot) }
        output.publishLive(store.liveSnapshot)
        reconcile()
        return listener
    }
    fileprivate func detach(id: UUID, listener: UUID) {
        store.removeLiveListener(listener); owners.remove(id)
        reconcile()
    }
    private func reconcile() {
        if owners.isEmpty || sleeping {
            monitor?.stop(); monitor = nil
            if owners.isEmpty { store.publishLive(.empty) }
        } else if monitor == nil {
            let monitor = makeMonitor(store)
            self.monitor = monitor; monitor.start()
        }
    }
}

@MainActor
private final class SharedSpeedLease: AgentSpeedReportingMonitor {
    private let hub: SharedAgentSpeedCollection
    private let output: SpeedStore
    private let id = UUID()
    private var listener: UUID?
    init(hub: SharedAgentSpeedCollection, output: SpeedStore) { self.hub = hub; self.output = output }
    deinit {
        let hub = hub, id = id, token = listener
        if let token { Task { @MainActor in hub.detach(id: id, listener: token) } }
    }
    func start() { if listener == nil { listener = hub.attach(output: output, id: id) } }
    func stop() { if let listener { hub.detach(id: id, listener: listener); self.listener = nil } }
}

struct LocalAgentSpeedReading: Equatable {
    var available = false
    var modelRates: [ModelRateContribution] = []
    var clientRates: [ModelRateContribution] = []
    var status = "等待本地客户端日志"
    var total: Double { modelRates.reduce(0) { $0 + $1.tokensPerSecond } }

    /// This cutoff affects local display only. It must never be fed into ReportSample.
    static func project(_ snapshot: SpeedSnapshot, now: Date, stoppedThreads: [String: Double] = [:]) -> Self {
        guard snapshot.state == .running, now.timeIntervalSince(snapshot.timestamp) <= 3,
              snapshot.timestamp.timeIntervalSince(now) <= 2 else { return .init() }
        var models: [String: Double] = [:], clients: [String: Double] = [:]
        for agent in snapshot.agents where agent.phase != .idle && !agent.localDisplayStopped {
            guard !stoppedThreads.contains(where: { agent.id.contains($0.key) && agent.lastActivity.timeIntervalSince1970 <= $0.value }) else { continue }
            let age = now.timeIntervalSince(agent.lastActivity)
            guard age >= -2, age < 20, agent.live.output.isFinite, agent.live.output > 0 else { continue }
            let model = ModelUsagePresentation.key(for: agent.model)
            models[model, default: 0] += agent.live.output
            clients["client:" + agent.source.rawValue, default: 0] += agent.live.output
        }
        if !snapshot.liveModels.isEmpty {
            models.removeAll(); clients.removeAll()
            var guarded = snapshot
            guarded.agents = snapshot.agents.filter { agent in
                !stoppedThreads.contains { agent.id.contains($0.key) && agent.lastActivity.timeIntervalSince1970 <= $0.value }
            }
            for source in SourceKind.allCases {
                let rates = AgentSpeedDisplayRuntime.modelRates(snapshot: guarded, source: source, now: now)
                for rate in rates { models[ModelUsagePresentation.key(for: rate.model), default: 0] += rate.tokensPerSecond }
                let total = rates.reduce(0) { $0 + $1.tokensPerSecond }
                if total > 0 { clients["client:" + source.rawValue] = total }
            }
        }
        return .init(available: true,
                     modelRates: models.keys.sorted().map { .init(model: $0, tokensPerSecond: models[$0]!) },
                     clientRates: clients.keys.sorted().map { .init(model: $0, tokensPerSecond: clients[$0]!) },
                     status: models.isEmpty ? "等待新增输出 · 停止或超时已归零" : "榜单口径 · 本地活动截止")
    }
}

@MainActor
final class LocalAgentSpeedDisplay: ObservableObject {
    @Published private(set) var reading = LocalAgentSpeedReading()
    let history = LiveActivityRateHistory()
    private var stoppedThreads: [String: Double] = [:]
    let preferences: SpeedDisplayPreferences
    private let store = SpeedStore()
    private let hub: SharedAgentSpeedCollection?
    private var runtimeSubscription: AnyCancellable?
    private var claudeSubscription: AnyCancellable?
    private var lease: (any AgentSpeedReportingMonitor)?
    private var listener: UUID?
    private var timer: Timer?
    private var lastPublication = Date.distantPast
    private var enabled = false
    private var subscription: AnyCancellable?

    init(preferences: SpeedDisplayPreferences = .shared, hub: SharedAgentSpeedCollection? = nil) {
        self.preferences = preferences; self.hub = hub
        if hub == nil {
            runtimeSubscription = AgentSpeedDisplayRuntime.shared.$snapshot.sink { [weak self] snapshot in
                self?.store.publishLive(snapshot); self?.refresh()
            }
            claudeSubscription = ClaudeLocalRuntime.shared.$snapshot.sink { [weak self] _ in
                // Published emits before assignment; project the committed snapshot.
                Task { @MainActor in self?.refresh() }
            }
        }
        subscription = preferences.$mode.sink { [weak self] mode in self?.reconcile(mode: mode) }
    }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled; reconcile(mode: preferences.mode) }
    func stop(threadID: String, at timestamp: Double) {
        guard UUID(uuidString: threadID) != nil, timestamp.isFinite else { return }
        stoppedThreads[threadID] = timestamp
        if stoppedThreads.count > 256 { stoppedThreads = stoppedThreads.filter { $0.value > timestamp - 3600 } }
        refresh()
    }
    private func reconcile(mode: SpeedDisplayMode) {
        guard enabled, mode == .agentSpeed else {
            lease?.stop(); lease = nil; timer?.invalidate(); timer = nil
            if let listener { store.removeLiveListener(listener); self.listener = nil }
            if reading != .init() { reading = .init() }
            return
        }
        guard timer == nil else { return }
        listener = store.addLiveListener { [weak self] _ in self?.refresh() }
        if let hub { let lease = hub.lease(for: store); self.lease = lease; lease.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in self?.refresh() }
        }
    }
    private func refresh() {
        guard enabled, preferences.mode == .agentSpeed else { return }
        let now = Date()
        var updated = LocalAgentSpeedReading.project(store.liveSnapshot, now: now, stoppedThreads: stoppedThreads)
        if hub == nil {
            var models = Dictionary(uniqueKeysWithValues: updated.modelRates.map { ($0.model, $0.tokensPerSecond) })
            for client in ["claudeCode", "claudeDesktop"] {
                let local = ClaudeLocalRuntime.shared.projection(allowed: [client])
                updated.available = updated.available || (local.enabled && local.sourceAvailable)
                for rate in local.modelRates { models[ModelUsagePresentation.key(for: rate.model), default: 0] += rate.tokensPerSecond }
                let total = local.modelRates.reduce(0) { $0 + $1.tokensPerSecond }
                if total > 0 { updated.clientRates.append(.init(model: "client:" + client, tokensPerSecond: total)) }
            }
            updated.modelRates = models.keys.sorted().map { .init(model: $0, tokensPerSecond: models[$0]!) }
            if updated.total > 0 { updated.status = "榜单口径 · 本地活动截止" }
        }
        history.record(now: now.timeIntervalSince1970, rates: updated.modelRates)
        // Keep the app-wide monitor at <=1 Hz while active; stops bypass the throttle.
        if reading != updated, updated.total == 0 || now.timeIntervalSince(lastPublication) >= 0.95 {
            lastPublication = now; reading = updated
        }
    }
}
