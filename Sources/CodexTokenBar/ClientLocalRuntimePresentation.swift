import Foundation

/// One display projection for both sidebar levels. Source accounting and
/// measured request intervals remain separate from the activity animation.
enum ClientLocalRuntimePresentation {
    static func rates(codex: [ModelRateContribution], claude: [ModelRateContribution], allowed: Set<String>, mode: ActivitySpeedDisplayMode = .bar, upstreamCodex: [ModelRateContribution] = [], others: [ModelRateContribution] = []) -> [ModelRateContribution] {
        let codexRates = mode == .agentSpeed ? upstreamCodex : codex
        var sums: [String: Double] = [:]
        for row in (allowed.contains("codex") ? codexRates : []) + claude + others where row.tokensPerSecond.isFinite && row.tokensPerSecond > 0 {
            let key = ModelUsagePresentation.autoReviewUnderlyingModelKey(for: row.model) ?? ModelUsagePresentation.key(for: row.model)
            sums[key, default: 0] += row.tokensPerSecond
        }
        return sums.keys.sorted().map { .init(model: $0, tokensPerSecond: sums[$0]!) }
    }

    static func running(codex: RunningThreadSummary, claude: RunningThreadSummary, allowed: Set<String>) -> RunningThreadSummary {
        if !allowed.contains("codex") { return claude }
        if !allowed.contains("claudeCode") && !allowed.contains("claudeDesktop") { return codex }
        let valid = [codex, claude].filter { $0.freshness == .fresh || $0.freshness == .stale }
        guard !valid.isEmpty else { return .unavailable }
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
            freshness: valid.count == 2 && valid.allSatisfy { $0.freshness == .fresh } ? .fresh : .stale)
    }

    /// A missing client is different from a stale Codex scan. Keep the counts'
    /// conservative freshness while explaining which selected reader is missing.
    static func taskSourceIssue(codex: RunningThreadSummary, claude: RunningThreadSummary,
                                allowed: Set<String>) -> String? {
        if allowed.contains("codex"), codex.freshness != .fresh {
            return codex.freshness == .stale ? "Codex 上次数据" : codex.freshness == .loading ? "Codex 读取中" : "Codex 未就绪"
        }
        if allowed.contains("claudeCode") || allowed.contains("claudeDesktop"), claude.freshness != .fresh {
            return claude.freshness == .stale ? "Claude 上次数据" : claude.freshness == .loading ? "Claude 读取中" : "Claude 未就绪"
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
