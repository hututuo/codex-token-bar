import AgentSpeedCore
import Combine
import Foundation

enum ActivitySpeedDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar
    case agentSpeed
    static let key = "activitySpeed.displayMode.v1"
    var id: String { rawValue }
    var title: String { self == .bar ? "Bar 模式" : "Agent Speed" }
    static func normalized(_ raw: String?) -> Self { Self(rawValue: raw ?? "") ?? .bar }
}

/// Output activity only. Body TPS never enters this projection. The configured
/// runtime does not instantiate a reporter or perform discovery/network calls.
@MainActor
final class AgentSpeedDisplayRuntime: ObservableObject {
    static let shared = AgentSpeedDisplayRuntime()
    @Published private(set) var snapshot: SpeedSnapshot = .empty
    private let store = SpeedStore()
    private var monitor: (any AgentSpeedReportingMonitor)?
    private var configuration: ActivitySourceConfiguration?
    private var sourceIdentities: [SourceKind: String] = [:]
    private var home: URL?
    private var codexSourceReady = false
    private var preferences: [MultiClientUsagePreference] = []
    private var listener: UUID?
    init() {
        listener = store.addLiveListener { [weak self] snapshot in
            guard let self, let configuration else { return }
            self.snapshot = snapshot
            for source in configuration.sources {
                guard let client = ActivitySourceConfiguration.client(for: source), let identity = self.sourceIdentities[source] else { continue }
                ActivitySpeedHistoryController.shared.record(client: client, sourceIdentity: identity,
                    rates: Self.modelRates(snapshot: snapshot, source: source, now: Date()), at: snapshot.timestamp.timeIntervalSince1970,
                    available: snapshot.sources.contains { $0.kind == source && $0.available }, mode: .agentSpeed)
            }
        }
    }
    func configure(monitoringEnabled: Bool, codexEnabled: Bool, preferences: [MultiClientUsagePreference]? = nil, codexHome: URL? = nil, codexSourceAvailable: Bool? = nil) {
        if let codexHome { home = codexHome }
        if let codexSourceAvailable { codexSourceReady = codexSourceAvailable }
        if let preferences { self.preferences = preferences }
        var next = ActivitySourceConfiguration.make(codexEnabled: codexEnabled && codexSourceReady, codexHome: home, preferences: self.preferences)
        if !monitoringEnabled { next.sources = [] }
        guard configuration != next else { return }
        let prior = configuration
        monitor?.stop(); monitor = nil; configuration = next; snapshot = .empty
        for source in (prior?.sources ?? []).subtracting(next.sources) {
            if let client = ActivitySourceConfiguration.client(for: source) { ActivitySpeedHistoryController.shared.selectSource(client: client, identity: nil) }
        }
        sourceIdentities = Dictionary(uniqueKeysWithValues: next.sources.compactMap { source in
            next.identity(for: source).map { (source, $0) }
        })
        guard !next.sources.isEmpty else { return }
        for source in next.sources {
            if let client = ActivitySourceConfiguration.client(for: source) {
                ActivitySpeedHistoryController.shared.selectSource(client: client, identity: sourceIdentities[source])
            }
        }
        let lease = SharedAgentSpeedMonitorPool.shared.lease(store: store, configuration: next.monitorConfiguration, sources: next.sources)
        monitor = lease; lease.start()
    }
    func externalModelRates(allowed: Set<String>) -> [ModelRateContribution] {
        allowed.sorted().flatMap { client in
            guard client != "codex", let source = ActivitySourceConfiguration.source(for: client), configuration?.sources.contains(source) == true else { return [ModelRateContribution]() }
            return Self.modelRates(snapshot: snapshot, source: source, now: Date())
        }
    }
    func hasCoverage(allowed: Set<String>) -> Bool {
        snapshot.sources.contains { item in
            item.enabled && item.available && configuration?.sources.contains(item.kind) == true && ActivitySourceConfiguration.client(for: item.kind).map(allowed.contains) == true
        }
    }
    nonisolated static func modelRates(snapshot: SpeedSnapshot, source: SourceKind, now: Date? = nil) -> [ModelRateContribution] {
        if let now {
        guard snapshot.state == .running, abs(now.timeIntervalSince(snapshot.timestamp)) <= 3,
              snapshot.agents.contains(where: { $0.source == source && $0.phase != .idle && !$0.localDisplayStopped
                  && now.timeIntervalSince($0.lastActivity) >= -2 && now.timeIntervalSince($0.lastActivity) < 20 }) else { return [] }
        }
        let total = snapshot.sources.first { $0.kind == source && $0.enabled && $0.available }?.live.output ?? 0
        guard total.isFinite, total > 0 else { return [] }
        var sums: [String: Double] = [:]
        for item in snapshot.liveModels where item.source == source && item.rate.output.isFinite && item.rate.output > 0 {
            let raw = item.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            sums[model, default: 0] += item.rate.output
        }
        let known = sums.values.reduce(0, +)
        if known < total { sums["unknown", default: 0] += total - known }
        if known > total { for key in Array(sums.keys) { sums[key]! *= total / known } }
        return sums.keys.sorted().map { .init(model: $0, tokensPerSecond: sums[$0]!) }
    }
}
