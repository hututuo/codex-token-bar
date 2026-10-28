import AgentSpeedCore
import Combine
import CryptoKit
import Foundation

enum ClaudeLocalSpeedMethod: String, Equatable, Sendable {
    case agentSpeedResponseInterval
}

struct ClaudeLocalResponseSpeedSample: Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let model: String?
    let outputTokens: Int
    let duration: TimeInterval?
    let endedAt: Date
    let method: ClaudeLocalSpeedMethod

    var responseIntervalOutputTokensPerSecond: Double? {
        guard let duration, duration.isFinite, duration > 0, outputTokens > 0 else { return nil }
        let value = Double(outputTokens) / duration
        return value.isFinite ? value : nil
    }
}

struct ClaudeLocalRuntimeSnapshot: Equatable, Sendable {
    let coreState: MonitorState
    let enabled: Bool
    let sourceAvailable: Bool
    let configurationIssue: String?
    let timestamp: Date
    let live: Rate
    /// Upstream request-timeline estimate, not a body-stream measurement.
    let estimatedShare: Double
    let today: TokenTotals
    let sourceTotals: [String: TokenTotals]
    let modelRates: [ModelRateContribution]
    let running: RunningThreadSummary
    let rows: [ClaudeLocalResponseSpeedSample]

    static let empty = ClaudeLocalRuntimeSnapshot(
        coreState: .noSources,
        enabled: false,
        sourceAvailable: false,
        configurationIssue: nil,
        timestamp: .distantPast,
        live: .zero,
        estimatedShare: 0,
        today: .zero,
        sourceTotals: [:],
        modelRates: [],
        running: .unavailable,
        rows: []
    )
}

@MainActor
protocol ClaudeLocalRuntimeMonitoring: AnyObject {
    var configuration: MonitorConfiguration { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    func update(configuration: MonitorConfiguration)
}

extension LiveMonitor: ClaudeLocalRuntimeMonitoring {}

@MainActor
final class ClaudeLocalRuntime: ObservableObject {
    static let shared = ClaudeLocalRuntime()

    static let responseRowLimit = 1_000
    static let responseRetention: TimeInterval = 30 * 60
    static let activeStatusFreshness: TimeInterval = 5 * 60

    @Published private(set) var snapshot: ClaudeLocalRuntimeSnapshot = .empty

    private let store: SpeedStore
    private let monitor: any ClaudeLocalRuntimeMonitoring
    private var liveListener: UUID?
    private var eventListener: UUID?
    private var configuredSources: Set<SourceKind> = []
    private var activitySourceIdentity: String?
    private var monitoringEnabled = false
    private var configurationIssue: String?
    private var latestCoreSnapshot = SpeedSnapshot.empty
    private var responseRows: [ClaudeLocalResponseSpeedSample] = []

    private struct ConfigurationPlan {
        let configuration: MonitorConfiguration
        let enabledSources: Set<SourceKind>
        let issue: String?
    }

    init(
        makeMonitor: @MainActor (SpeedStore, MonitorConfiguration) -> any ClaudeLocalRuntimeMonitoring = { store, configuration in
            LiveMonitor(store: store, configuration: configuration)
        }
    ) {
        let store = SpeedStore()
        let disabledConfiguration = MonitorConfiguration(enabledSources: [])
        self.store = store
        self.monitor = makeMonitor(store, disabledConfiguration)
        self.liveListener = store.addLiveListener { [weak self] snapshot in
            self?.receive(snapshot)
        }
        self.eventListener = store.addEventListener { [weak self] event in
            self?.receive(event)
        }
    }

    /// Applies explicit Claude preferences. Monitoring is disabled until the caller enables it.
    /// A single AgentSpeed monitor supports one Claude root, shared by Claude Code and Desktop.
    func configure(preferences: [MultiClientUsagePreference], monitoringEnabled: Bool = true) {
        let plan = Self.configurationPlan(preferences: preferences)
        self.monitoringEnabled = monitoringEnabled
        configuredSources = plan.enabledSources
        configurationIssue = plan.issue

        if !monitoringEnabled || plan.enabledSources.isEmpty || plan.issue != nil {
            monitor.stop()
            updateMonitorConfigurationIfNeeded(plan.configuration)
            clearLiveState()
            return
        }

        let configurationChanged = monitor.configuration != plan.configuration
        if configurationChanged {
            latestCoreSnapshot = Self.startingSnapshot()
            responseRows.removeAll(keepingCapacity: true)
        }
        if configurationChanged || activitySourceIdentity == nil {
            activitySourceIdentity = ActivitySpeedSourceIdentity.root(plan.configuration.claudeRoot ?? LiveMonitor.defaultClaudeRoot)
        }
        for source in plan.enabledSources {
            ActivitySpeedHistoryController.shared.selectSource(client: source.rawValue, identity: activitySourceIdentity)
        }
        updateMonitorConfigurationIfNeeded(plan.configuration)
        if !monitor.isRunning {
            latestCoreSnapshot = Self.startingSnapshot()
            monitor.start()
            publishProjection()
        } else if configurationChanged {
            publishProjection()
        }
    }

    func start() {
        guard monitoringEnabled, !configuredSources.isEmpty, configurationIssue == nil else { return }
        guard !monitor.isRunning else { return }
        latestCoreSnapshot = Self.startingSnapshot()
        monitor.start()
        publishProjection()
    }

    func stop() {
        monitoringEnabled = false
        monitor.stop()
        clearLiveState()
    }

    /// Returns a client-filtered view. `allowed` uses `UsageClient.rawValue` values.
    func projection(allowed: Set<String>) -> ClaudeLocalRuntimeSnapshot {
        let allowedSources = Set(configuredSources.filter { allowed.contains($0.rawValue) })
        guard monitoringEnabled, !allowedSources.isEmpty, configurationIssue == nil else {
            return Self.project(
                from: .empty,
                allowedSources: [],
                rows: [],
                enabled: false,
                configurationIssue: configurationIssue
            )
        }
        return Self.project(
            from: latestCoreSnapshot,
            allowedSources: allowedSources,
            rows: responseRows,
            enabled: true,
            configurationIssue: configurationIssue,
            displayNow: Date()
        )
    }

    /// Purely projects the vendored monitor snapshot into safe local presentation data.
    static func project(
        from core: SpeedSnapshot,
        allowedSources: Set<SourceKind>,
        rows: [ClaudeLocalResponseSpeedSample] = [],
        enabled: Bool = true,
        configurationIssue: String? = nil,
        displayNow: Date? = nil
    ) -> ClaudeLocalRuntimeSnapshot {
        let selectedSources = allowedSources.intersection([.claudeCode, .claudeDesktop])
        guard enabled, !selectedSources.isEmpty else {
            return ClaudeLocalRuntimeSnapshot(
                coreState: .noSources,
                enabled: false,
                sourceAvailable: false,
                configurationIssue: configurationIssue,
                timestamp: core.timestamp,
                live: .zero,
                estimatedShare: 0,
                today: .zero,
                sourceTotals: [:],
                modelRates: [],
                running: .unavailable,
                rows: []
            )
        }

        let now = core.timestamp
        let selectedStatuses = core.sources.filter { selectedSources.contains($0.kind) && $0.enabled }
        let sourceAvailable = selectedStatuses.contains(where: \.available)
        let sourceTotals = Dictionary(uniqueKeysWithValues: selectedStatuses.map { ($0.kind.rawValue, $0.today) })
        let live = selectedStatuses.reduce(into: Rate.zero) { result, status in
            result.output += status.live.output
            result.total += status.live.total
        }
        // Use the core's calibrated estimate directly, scoped to the same
        // sources as the total. No independent speed predictor is introduced.
        let estimated = selectedStatuses.reduce(0.0) { partial, source in
            partial + (source.liveEstimated.output.isFinite ? max(0, source.liveEstimated.output) : 0)
        }
        let estimatedShare = live.output.isFinite && live.output > 0 ? min(1, max(0, estimated / live.output)) : 0
        let today = selectedStatuses.reduce(into: TokenTotals.zero) { result, status in
            result.requests += status.today.requests
            result.input += status.today.input
            result.cachedInput += status.today.cachedInput
            result.cacheWriteInput += status.today.cacheWriteInput
            result.output += status.today.output
            result.reasoning += status.today.reasoning
        }

        let currentAgents = core.agents.filter { agent in
            selectedSources.contains(agent.source)
                && isFreshActive(agent, at: now)
        }
        // The upstream live window can still include a completed response.
        // Keep those contributions and retain unknown-model rate explicitly.
        let modelRates = selectedSources.sorted { $0.rawValue < $1.rawValue }.flatMap { source in
            AgentSpeedDisplayRuntime.modelRates(snapshot: core, source: source, now: displayNow)
        }

        let running = runningSummary(
            agents: core.agents.filter { selectedSources.contains($0.source) },
            activeAgents: currentAgents,
            sourceAvailable: sourceAvailable,
            state: core.state
        )
        let filteredRows = rows
            .filter { row in selectedSources.contains(where: { $0.rawValue == row.sourceID }) }
            .sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt < $1.endedAt }
            .suffix(responseRowLimit)

        return ClaudeLocalRuntimeSnapshot(
            coreState: core.state,
            enabled: true,
            sourceAvailable: sourceAvailable,
            configurationIssue: configurationIssue,
            timestamp: now,
            live: live,
            estimatedShare: estimatedShare,
            today: today,
            sourceTotals: sourceTotals,
            modelRates: modelRates,
            running: running,
            rows: Array(filteredRows)
        )
    }

    private static func configurationPlan(preferences: [MultiClientUsagePreference]) -> ConfigurationPlan {
        var preferenceBySource: [SourceKind: MultiClientUsagePreference] = [:]
        if let code = preferences.first(where: { $0.client == .claudeCode }) {
            preferenceBySource[.claudeCode] = code
        }
        if let desktop = preferences.first(where: { $0.client == .claudeDesktop }) {
            preferenceBySource[.claudeDesktop] = desktop
        }
        let enabledSources = Set(preferenceBySource.compactMap { source, preference in
            preference.enabled ? source : nil
        })

        let roots = enabledSources.compactMap { source -> URL? in
            guard let preference = preferenceBySource[source] else { return nil }
            let path = preference.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return LiveMonitor.defaultClaudeRoot.standardizedFileURL }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        let uniqueRoots = Set(roots.map(\.path))
        let hasConflictingRoots = uniqueRoots.count > 1
        let root = hasConflictingRoots ? nil : roots.first
        let defaultRoot = LiveMonitor.defaultClaudeRoot.standardizedFileURL
        let configuration = MonitorConfiguration(
            enabledSources: hasConflictingRoots ? [] : enabledSources,
            claudeRoot: root == defaultRoot ? nil : root
        )
        return ConfigurationPlan(
            configuration: configuration,
            enabledSources: enabledSources,
            issue: hasConflictingRoots ? "Claude Code and Claude Desktop use different folders; one local monitor cannot read both." : nil
        )
    }

    private func updateMonitorConfigurationIfNeeded(_ configuration: MonitorConfiguration) {
        guard monitor.configuration != configuration else { return }
        monitor.update(configuration: configuration)
    }

    private func receive(_ snapshot: SpeedSnapshot) {
        guard monitoringEnabled else { return }
        latestCoreSnapshot = snapshot
        let mode = ActivitySpeedDisplayMode.normalized(UserDefaults.standard.string(forKey: ActivitySpeedDisplayMode.key))
        for source in configuredSources {
            ActivitySpeedHistoryController.shared.record(client: source.rawValue,
                sourceIdentity: activitySourceIdentity ?? "legacy/unscoped",
                rates: AgentSpeedDisplayRuntime.modelRates(snapshot: snapshot, source: source), at: snapshot.timestamp.timeIntervalSince1970,
                available: snapshot.sources.contains { $0.kind == source && $0.available }, mode: mode)
        }
        pruneRows(at: snapshot.timestamp)
        publishProjection()
    }

    private func receive(_ event: SpeedEvent) {
        guard monitoringEnabled else { return }
        guard case .responseCompleted(let response) = event,
              configuredSources.contains(response.source),
              [.claudeCode, .claudeDesktop].contains(response.source) else { return }
        let row = Self.responseRow(from: response)
        responseRows.removeAll { $0.id == row.id }
        responseRows.append(row)
        pruneRows(at: latestCoreSnapshot.timestamp)
        publishProjection()
    }

    private func pruneRows(at now: Date) {
        let oldest = now.addingTimeInterval(-Self.responseRetention)
        responseRows.removeAll { $0.endedAt < oldest || $0.endedAt > now.addingTimeInterval(5) }
        if responseRows.count > Self.responseRowLimit {
            responseRows.sort { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt < $1.endedAt }
            responseRows = Array(responseRows.suffix(Self.responseRowLimit))
        }
    }

    private func publishProjection() {
        let next = Self.project(
            from: latestCoreSnapshot,
            allowedSources: configuredSources,
            rows: responseRows,
            enabled: monitoringEnabled && !configuredSources.isEmpty && configurationIssue == nil,
            configurationIssue: configurationIssue,
            displayNow: Date()
        )
        guard !Self.sameMeaningfulContent(snapshot, next) else { return }
        snapshot = next
    }

    private func clearLiveState() {
        ActivitySpeedHistoryController.shared.reset(client: "claudeCode")
        ActivitySpeedHistoryController.shared.reset(client: "claudeDesktop")
        latestCoreSnapshot = .empty
        responseRows.removeAll(keepingCapacity: true)
        publishProjection()
        if snapshot.enabled || snapshot.sourceAvailable || !snapshot.rows.isEmpty {
            snapshot = .empty
        }
    }

    private static func startingSnapshot() -> SpeedSnapshot {
        var snapshot = SpeedSnapshot.empty
        snapshot.timestamp = Date()
        snapshot.state = .starting(progress: 0)
        return snapshot
    }

    private static func responseRow(from response: ResponseSummary) -> ClaudeLocalResponseSpeedSample {
        let duration = response.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let model = cleaned(response.model)
        let identity = [
            response.source.rawValue,
            model ?? "unknown",
            String(max(0, response.outputTokens)),
            String(response.endedAt.timeIntervalSince1970.bitPattern),
            duration.map { String($0.bitPattern) } ?? "unknown-duration"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return ClaudeLocalResponseSpeedSample(
            id: "claude-response:\(digest)",
            sourceID: response.source.rawValue,
            model: model,
            outputTokens: max(0, response.outputTokens),
            duration: duration,
            endedAt: response.endedAt,
            method: .agentSpeedResponseInterval
        )
    }

    private static func isFreshActive(_ agent: AgentStatus, at now: Date) -> Bool {
        guard agent.phase == .generating || agent.phase == .tools else { return false }
        let age = now.timeIntervalSince(agent.lastActivity)
        return age.isFinite && age >= -5 && age <= activeStatusFreshness
    }

    private static func runningSummary(
        agents: [AgentStatus],
        activeAgents: [AgentStatus],
        sourceAvailable: Bool,
        state: MonitorState
    ) -> RunningThreadSummary {
        let mainAgents = activeAgents.filter { !$0.isSubagent }
        let subagents = activeAgents.filter(\.isSubagent)
        let allByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func topParentID(for agent: AgentStatus) -> String? {
            var candidate = agent.parentId
            var visited = Set<String>()
            while let id = candidate, visited.insert(id).inserted, let parent = allByID[id], parent.isSubagent {
                candidate = parent.parentId
            }
            return candidate
        }

        func member(_ agent: AgentStatus) -> RunningThreadMember {
            RunningThreadMember(
                threadID: opaqueThreadID(agent.id),
                title: agent.isSubagent ? "Claude subagent" : "Claude session",
                model: cleaned(agent.model),
                reasoningEffort: nil
            )
        }

        var groupedSubagents: [String: [RunningThreadMember]] = [:]
        var unassigned: [RunningThreadMember] = []
        for agent in subagents {
            guard let parentID = topParentID(for: agent), !parentID.isEmpty else {
                unassigned.append(member(agent))
                continue
            }
            groupedSubagents[parentID, default: []].append(member(agent))
        }

        var mainByID = Dictionary(uniqueKeysWithValues: mainAgents.map { ($0.id, member($0)) })
        for parentID in groupedSubagents.keys where mainByID[parentID] == nil {
            let model = allByID[parentID]?.model
            mainByID[parentID] = RunningThreadMember(
                threadID: opaqueThreadID(parentID),
                title: "Claude session",
                model: cleaned(model),
                reasoningEffort: nil
            )
        }
        let groups = groupedSubagents.keys.sorted().compactMap { parentID -> RunningThreadGroup? in
            guard let main = mainByID[parentID] else { return nil }
            let children = (groupedSubagents[parentID] ?? []).sorted { $0.threadID < $1.threadID }
            return RunningThreadGroup(mainThread: main, subagents: children)
        }

        let freshness: RunningThreadFreshness
        if case .starting = state {
            freshness = .loading
        } else if sourceAvailable {
            freshness = .fresh
        } else {
            freshness = .unavailable
        }

        return RunningThreadSummary(
            main: mainAgents.count,
            subagents: subagents.count,
            mainModels: modelBreakdown(mainAgents),
            subagentModels: modelBreakdown(subagents),
            groups: groups,
            unassignedSubagents: unassigned.sorted { $0.threadID < $1.threadID },
            lastCheckedAt: nil,
            dataUpdatedAt: activeAgents.map(\.lastActivity).max(),
            freshness: freshness
        )
    }

    private static func modelBreakdown(_ agents: [AgentStatus]) -> [RunningThreadModelBreakdown] {
        var counts: [String: (model: String?, count: Int)] = [:]
        for agent in agents {
            let model = cleaned(agent.model)
            let key = model ?? "unknown"
            var value = counts[key] ?? (model, 0)
            value.count += 1
            counts[key] = value
        }
        return counts.keys.sorted().compactMap { key in
            guard let value = counts[key], value.count > 0 else { return nil }
            return RunningThreadModelBreakdown(model: value.model, reasoningEffort: nil, count: value.count)
        }
    }

    private static func opaqueThreadID(_ rawID: String) -> String {
        let digest = SHA256.hash(data: Data(rawID.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return "claude:\(digest)"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func sameMeaningfulContent(
        _ lhs: ClaudeLocalRuntimeSnapshot,
        _ rhs: ClaudeLocalRuntimeSnapshot
    ) -> Bool {
        lhs.coreState == rhs.coreState
            && lhs.enabled == rhs.enabled
            && lhs.sourceAvailable == rhs.sourceAvailable
            && lhs.configurationIssue == rhs.configurationIssue
            && lhs.live == rhs.live
            && lhs.estimatedShare == rhs.estimatedShare
            && lhs.today == rhs.today
            && lhs.sourceTotals == rhs.sourceTotals
            && lhs.modelRates == rhs.modelRates
            && lhs.running.main == rhs.running.main
            && lhs.running.subagents == rhs.running.subagents
            && lhs.running.mainModels == rhs.running.mainModels
            && lhs.running.subagentModels == rhs.running.subagentModels
            && lhs.running.groups == rhs.running.groups
            && lhs.running.unassignedSubagents == rhs.running.unassignedSubagents
            && lhs.running.dataUpdatedAt == rhs.running.dataUpdatedAt
            && lhs.running.freshness == rhs.running.freshness
            && lhs.rows == rhs.rows
    }
}
