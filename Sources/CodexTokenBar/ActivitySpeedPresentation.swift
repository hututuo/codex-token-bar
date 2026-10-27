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
    private var key: String?
    private var home: URL?
    private var sourceIdentity: String?
    private var listener: UUID?
    init() {
        listener = store.addLiveListener { [weak self] snapshot in
            guard let self, key != nil, let sourceIdentity else { return }
            self.snapshot = snapshot
            ActivitySpeedHistoryController.shared.record(client: "codex", sourceIdentity: sourceIdentity,
                rates: Self.modelRates(snapshot: snapshot, source: .codex),
                at: snapshot.timestamp.timeIntervalSince1970,
                available: snapshot.sources.contains { $0.kind == .codex && $0.available }, mode: .agentSpeed)
        }
    }
    func configure(enabled: Bool, codexHome: URL? = nil) {
        if let codexHome { home = codexHome }
        let root = home?.appendingPathComponent("sessions", isDirectory: true)
        let next = enabled ? (root ?? LiveMonitor.defaultCodexRoot).standardizedFileURL.path : nil
        guard key != next else { return }
        monitor?.stop(); monitor = nil; key = next; snapshot = .empty
        if enabled {
            sourceIdentity = ActivitySpeedSourceIdentity.root(home ?? LiveMonitor.defaultCodexRoot.deletingLastPathComponent())
            ActivitySpeedHistoryController.shared.selectSource(client: "codex", identity: sourceIdentity)
            let lease = SharedAgentSpeedMonitorPool.shared.lease(store: store, sources: [.codex], codexRoot: root)
            monitor = lease; lease.start()
        }
    }
    static func modelRates(snapshot: SpeedSnapshot, source: SourceKind) -> [ModelRateContribution] {
        let total = snapshot.sources.first { $0.kind == source && $0.enabled && $0.available }?.live.output ?? 0
        guard total.isFinite, total > 0 else { return [] }
        var sums: [String: Double] = [:]
        for agent in snapshot.agents where agent.source == source && agent.live.output.isFinite && agent.live.output > 0 {
            let raw = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            sums[model, default: 0] += agent.live.output
        }
        let known = sums.values.reduce(0, +)
        if known < total { sums["unknown", default: 0] += total - known }
        if known > total { for key in Array(sums.keys) { sums[key]! *= total / known } }
        return sums.keys.sorted().map { .init(model: $0, tokensPerSecond: sums[$0]!) }
    }
}
