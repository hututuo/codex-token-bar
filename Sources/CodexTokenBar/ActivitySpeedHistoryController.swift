import Combine
import CryptoKit
import Foundation

enum ActivitySpeedSourceIdentity {
    static func root(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return "root-" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class ActivitySpeedHistoryController: ObservableObject {
    static let shared = ActivitySpeedHistoryController()
    @Published private(set) var series: [ActivitySpeedSeries] = []
    @Published private(set) var issue: String?
    @Published private(set) var daySeries: [ActivitySpeedSeries] = []
    @Published private(set) var dayIssue: String?
    @Published private(set) var dayAsOf = Date()
    private var dayReaders: Set<UUID> = []
    private var dayRequest: Task<Void, Never>?
    private var lastDayRead: Double = 0
    private var ledger: ActivitySpeedStore?
    private var opening: Task<ActivitySpeedStore, Error>?
    private struct Last {
        let time: Double
        let rates: [ModelRateContribution]
        let mode: String
    }
    private var last: [String: Last] = [:]
    private var activeSources: [String: String] = [:]
    private var queued: [ActivitySpeedSample] = []
    private var writer: Task<Void, Never>?
    private var lastRefresh: Double = 0
    private var epoch = UUID().uuidString
    private var enabled = false
    /// Production composition opts in explicitly; fixture runtimes cannot write app data.
    func start() { enabled = true }
    func reset(client: String) { last = last.filter { !$0.key.hasPrefix(client + "|") } }
    func selectSource(client: String, identity: String?) {
        guard activeSources[client] != identity else { return }
        activeSources[client] = identity
        reset(client: client)
        series.removeAll { $0.dimensions.client == client && $0.dimensions.sourceIdentity != identity }
        daySeries.removeAll { $0.dimensions.client == client && $0.dimensions.sourceIdentity != identity }
        lastDayRead = 0
    }

    func record(client: String, sourceIdentity: String, rates: [ModelRateContribution], at time: Double, available: Bool, mode: ActivitySpeedDisplayMode) {
        guard enabled, time.isFinite else { return }
        selectSource(client: client, identity: sourceIdentity)
        let captureKey = client + "|" + sourceIdentity + "|" + mode.rawValue
        guard available else { last.removeValue(forKey: captureKey); return }
        if let prior = last[captureKey], time - prior.time < 1 { return }
        let prior = last.updateValue(.init(time: time, rates: rates, mode: mode.rawValue), forKey: captureKey)
        guard let prior, prior.mode == mode.rawValue, time > prior.time, time - prior.time <= 3 else { return }
        // Store interval summaries, not animation frames or transcript text. Idle
        // intervals without any active output need no raw detail record.
        for rate in prior.rates where rate.tokensPerSecond.isFinite && rate.tokensPerSecond > 0 {
            let model = ModelUsagePresentation.autoReviewUnderlyingModelKey(for: rate.model) ?? ModelUsagePresentation.key(for: rate.model)
            let identity = "\(epoch)|\(client)|\(sourceIdentity)|\(mode.rawValue)|\(model)|\(prior.time)|\(time)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            queued.append(.init(id: id, displayMode: mode.rawValue,
                estimatorID: client == "codex" && mode == .bar ? "tokenbar" : "agent-speed", estimatorVersion: "1",
                metricKind: "output-activity", client: client, model: model,
                startedAt: prior.time, endedAt: time, outputRate: rate.tokensPerSecond, coveredSeconds: time-prior.time,
                sourceIdentity: sourceIdentity))
        }
        if queued.count > 4096 {
            // Speed visualization may be incomplete, but the durable usage
            // ledger is independent and never dropped by this bounded queue.
            queued.removeFirst(queued.count-4096); issue = "活动速度记录暂不完整"
        }
        if !queued.isEmpty && writer == nil && (queued.count >= 128 || time-lastRefresh >= 5) { drain(now: time) }
    }
    func refresh() {
        guard enabled, writer == nil else { return }
        drain(now: Date().timeIntervalSince1970)
    }
    func showDayTrend(_ visible: Bool, consumer: UUID) {
        if visible { dayReaders.insert(consumer); refreshDayTrend() }
        else { dayReaders.remove(consumer) }
    }
    func refreshDayTrend(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard enabled, !dayReaders.isEmpty, dayRequest == nil,
              force || now - lastDayRead >= 60 else { return }
        let sources = activeSources
        let selectedMode = ActivitySpeedDisplayMode.agentSpeed.rawValue
        lastDayRead = now
        dayRequest = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await open()
                var rows: [ActivitySpeedSeries] = []
                for source in Set(sources.values).sorted() {
                    let result = try await store.activityHistory(now: now,
                        filter: .init(sourceIdentity: source, displayMode: selectedMode), windowSeconds: 86400)
                    rows += result.series
                }
                guard sources == activeSources else {
                    dayRequest = nil; lastDayRead = 0
                    refreshDayTrend()
                    return
                }
                let scoped = rows.filter { sources[$0.dimensions.client] == $0.dimensions.sourceIdentity }
                if daySeries != scoped { daySeries = scoped }
                dayAsOf = Date(timeIntervalSince1970: now)
                dayIssue = nil
            } catch { dayIssue = "活动速率历史暂不可用" }
            dayRequest = nil
        }
    }
    private func open() async throws -> ActivitySpeedStore {
        if let ledger { return ledger }
        if opening == nil {
            let url = MultiClientUsageStore.defaultDatabaseURL
            opening = Task.detached(priority: .utility) {
                // Initialize the existing B schema first. An activity-only first
                // launch must not make user_version=0 look like an old ledger.
                _ = try MultiClientUsageLedger(url: url)
                _ = try LegacyClaudeSpeedMigration.migrate(
                    source: url.deletingLastPathComponent().appendingPathComponent("claude-local-speed.sqlite"),
                    target: url
                )
                return try ActivitySpeedStore(url: url)
            }
        }
        do {
            let value = try await opening!.value
            opening = nil; ledger = value; return value
        } catch { opening = nil; throw error }
    }
    private func drain(now: Double) {
        lastRefresh = now
        let batch = queued; queued.removeAll(keepingCapacity: true)
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await open()
                _ = try await store.addBatch(samples: batch, now: now)
                let selectedMode = ActivitySpeedDisplayMode.normalized(UserDefaults.standard.string(forKey: ActivitySpeedDisplayMode.key)).rawValue
                var results: [ActivitySpeedSeries] = []
                for source in Set(activeSources.values).sorted() {
                    let result = try await store.query(now: now,
                        filter: .init(sourceIdentity: source, displayMode: selectedMode, trendSince: max(0, now - 2_100)),
                        trendPointLimit: 8)
                    results += result.series
                }
                let scoped = results.filter { activeSources[$0.dimensions.client] == $0.dimensions.sourceIdentity }
                if series != scoped { series = scoped }
                issue = nil
            } catch { issue = "活动速度索引暂不可用" }
            writer = nil
            refreshDayTrend()
        }
    }
}
