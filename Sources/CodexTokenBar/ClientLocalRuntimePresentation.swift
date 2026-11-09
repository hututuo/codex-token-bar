import Foundation
import AgentSpeedCore

/// One display projection for both sidebar levels. Source accounting and
/// measured request intervals remain separate from the activity animation.
enum ClientLocalRuntimePresentation {
    static func taskClients(allowed: Set<String>, preferences: [MultiClientUsagePreference]) -> Set<String> {
        allowed.filter { id in id == "codex" || preferences.contains { $0.client.rawValue == id && $0.enabled } }
    }

    @MainActor static func observedRunning(codex: RunningThreadSummary, claude: ClaudeLocalRuntime,
                                          upstream: AgentSpeedDisplayRuntime, allowed: Set<String>,
                                          preferences: [MultiClientUsagePreference]) -> RunningThreadSummary {
        let selected = taskClients(allowed: allowed, preferences: preferences)
        return running(codex: codex, claude: claude.projection(allowed: selected).running,
            allowed: selected, antigravity: upstream.antigravityTasks(allowed: selected))
    }

    /// Thin reader adapter shared by every sidebar speed surface. In particular,
    /// Claude is selected here once, never added again via the upstream reader.
    @MainActor static func liveRate(monitor: LiveRateMonitor, claude: ClaudeLocalRuntime,
                                   upstream: AgentSpeedDisplayRuntime, allowed: Set<String>,
                                   mode: ActivitySpeedDisplayMode, grouping: SpeedColorGrouping,
                                   now: Date = Date()) -> LiveModelRateSnapshot {
        let sources: [ModelRateSource] = allowed.sorted().map { client in
            if client == "codex", mode == .bar {
                let value = monitor.totalSnapshot
                return .init(client: client, sourceKey: String(monitor.sourceBindingGeneration),
                    observedAt: value.updatedAt.timeIntervalSince1970,
                    available: monitor.monitoringEnabled && monitor.dataSource != nil,
                    rates: value.modelRates, total: value.rollingTokensPerSecond)
            }
            if client == "claudeCode" || client == "claudeDesktop" {
                let value = claude.projection(allowed: [client])
                return .init(client: client, sourceKey: claude.displaySourceIdentity, observedAt: value.timestamp.timeIntervalSince1970,
                    available: value.enabled && value.sourceAvailable && abs(now.timeIntervalSince(value.timestamp)) <= 3,
                    rates: claude.displayModelRates(allowed: [client], mode: mode))
            }
            return .init(client: client, sourceKey: upstream.displaySourceIdentity(client: client), observedAt: upstream.snapshot.timestamp.timeIntervalSince1970,
                available: upstream.hasCoverage(allowed: [client]) && upstream.snapshot.state == .running
                    && abs(now.timeIntervalSince(upstream.snapshot.timestamp)) <= 3,
                rates: ActivitySourceConfiguration.source(for: client).map {
                    AgentSpeedDisplayRuntime.modelRates(snapshot: upstream.snapshot, source: $0, now: now)
                } ?? [])
        }
        return ModelRatePresentation.snapshot(sources: sources, enabled: monitor.monitoringEnabled, mode: mode, grouping: grouping)
    }

    static func rates(codex: [ModelRateContribution], claude: [ModelRateContribution], allowed: Set<String>, mode: ActivitySpeedDisplayMode = .bar, upstreamCodex: [ModelRateContribution] = [], others: [ModelRateContribution] = []) -> [ModelRateContribution] {
        let codexRates = mode == .agentSpeed ? upstreamCodex : codex
        return ModelRatePresentation.normalized((allowed.contains("codex") ? codexRates : []) + claude + others)
    }

    static func running(codex: RunningThreadSummary, claude: RunningThreadSummary, allowed: Set<String>, antigravity: RunningThreadSummary = .unavailable) -> RunningThreadSummary {
        let selected = (allowed.contains("codex") ? [codex] : [])
            + (allowed.contains("claudeCode") || allowed.contains("claudeDesktop") ? [claude] : [])
            + (allowed.contains("antigravity") ? [antigravity] : [])
        let fresh = selected.filter { $0.freshness == .fresh }
        // Only aggregate current observations when any are available. A missing
        // reader neither invalidates another reader nor contributes a fake zero.
        let valid = fresh.isEmpty ? selected.filter { $0.freshness == .stale } : fresh
        guard !valid.isEmpty else {
            return selected.contains { $0.freshness == .loading } ? .loading : .unavailable
        }
        func models(_ rows: [RunningThreadModelBreakdown]) -> [RunningThreadModelBreakdown] {
            let grouped = Dictionary(grouping: rows, by: \.id)
            return grouped.keys.sorted().compactMap { key in
                guard let first = grouped[key]?.first else { return nil }
                return .init(model: first.model, reasoningEffort: first.reasoningEffort, count: grouped[key]!.reduce(0) { $0 + $1.count })
            }
        }
        return .init(main: valid.reduce(0) { $0 + $1.main }, subagents: valid.reduce(0) { $0 + $1.subagents },
            mainModels: models(valid.flatMap(\.mainModels)), subagentModels: models(valid.flatMap(\.subagentModels)),
            groups: valid.flatMap(\.groups), unassignedSubagents: valid.flatMap(\.unassignedSubagents),
            lastCheckedAt: valid.compactMap(\.lastCheckedAt).max(), dataUpdatedAt: valid.compactMap(\.dataUpdatedAt).max(),
            freshness: fresh.isEmpty ? .stale : .fresh)
    }

    @MainActor static func antigravityRunning(_ snapshot: SpeedSnapshot, now: Date = Date()) -> RunningThreadSummary {
        guard let status = snapshot.sources.first(where: { $0.kind == .antigravity && $0.enabled }), status.available else { return .unavailable }
        if case .starting = snapshot.state { return .loading }
        guard snapshot.state == .running, abs(now.timeIntervalSince(snapshot.timestamp)) <= 3 else { return .unavailable }
        let agents = snapshot.agents.filter { $0.source == .antigravity }
        let active = agents.filter {
            let age = now.timeIntervalSince($0.lastActivity)
            return !$0.localDisplayStopped && ($0.phase == .generating || $0.phase == .tools) && age >= -5 && age <= 300
        }
        return ClaudeLocalRuntime.runningSummary(agents: agents, activeAgents: active, sourceAvailable: true, state: snapshot.state)
    }

    /// Supplementary source status for task details, independent of the current
    /// task count from readers that have a fresh observation.
    static func taskSourceIssue(codex: RunningThreadSummary, claude: RunningThreadSummary,
                                allowed: Set<String>, antigravity: RunningThreadSummary = .unavailable) -> String? {
        if allowed.contains("codex"), codex.freshness != .fresh {
            return codex.freshness == .stale ? "Codex 上次数据" : codex.freshness == .loading ? "Codex 读取中" : "Codex 暂无任务数据"
        }
        if allowed.contains("claudeCode") || allowed.contains("claudeDesktop"), claude.freshness != .fresh {
            return claude.freshness == .stale ? "Claude 上次数据" : claude.freshness == .loading ? "Claude 读取中" : "Claude 暂无任务数据"
        }
        if allowed.contains("antigravity"), antigravity.freshness != .fresh {
            return antigravity.freshness == .loading ? "Antigravity 读取中" : "Antigravity 暂无任务数据"
        }
        return nil
    }

    static func models(codex: [ModelTokenBreakdown], clients: [ClientUsageSummary], allowed: Set<String>) -> [ModelTokenBreakdown] {
        (allowed.contains("codex") ? codex : []) + clients.filter { allowed.contains($0.client.rawValue) }.map { row in
            .init(model: row.model, breakdown: .init(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(row.cacheReadTokens ?? 0),
                outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0),
                totalTokens: Int(row.inputTokens + row.outputTokens), calls: row.requests))
        }
    }
}
