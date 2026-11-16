import Foundation

/// A compact, display-only day. Reuses the chart's client/model identity and
/// recorded-price semantics; never becomes a second accounting store.
struct HeatmapDayUsage: Equatable, Sendable {
    let date: Date
    let usage: ChartUsageSummary

    static func project(codex: DashboardSnapshot, external: [ClientTrendBucket],
                        allowed: Set<String>, priceModel: OfficialAPIPriceModel,
                        calendar: Calendar = .current) -> [Self] {
        let includeCodex = allowed.contains("codex")
        let codexDays = Dictionary(grouping: includeCodex ? codex.dailyUsage : [], by: { calendar.startOfDay(for: $0.date) })
        let codexCache = Dictionary(grouping: includeCodex ? codex.cacheUsage.daily : [], by: { calendar.startOfDay(for: $0.start) })
        let codexModels = Dictionary(grouping: includeCodex ? codex.cacheUsage.dailyModelBreakdowns : [], by: { calendar.startOfDay(for: $0.start) })
        let others = Dictionary(grouping: external.filter { allowed.contains($0.client.rawValue) }) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.startUnix)))
        }
        return Set(codexDays.keys).union(others.keys).sorted().compactMap { date in
            guard !Task.isCancelled else { return nil }
            let original = (codexCache[date] ?? []).map(\.breakdown).combined
            let days = codexDays[date] ?? []
            let originalTokens = days.reduce(0) { $0 + $1.tokens }
            let originalCalls = days.reduce(0) { $0 + $1.calls }
            var models = (codexModels[date] ?? []).flatMap(\.modelBreakdowns).map { row in
                let price = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [row], fallbackBreakdown: row.breakdown,
                    fallbackModel: priceModel, standardAPI: true, rates: { $0.currentPriceRates })
                return ChartModelUsage(client: "codex", model: ModelPresentationIdentity.resolve(row.model).key,
                    sourceModels: [row.model ?? "unknown"], breakdown: row.breakdown, cacheReadComplete: true,
                    cacheWriteTokens: nil, knownCostUSD: price.unpricedCalls < row.breakdown.calls ? price.costUSD : nil,
                    unpricedRequests: price.unpricedCalls)
            }
            let missing = max(0, originalTokens - models.reduce(0) { $0 + $1.breakdown.totalTokens })
            let missingCalls = max(0, originalCalls - models.reduce(0) { $0 + $1.breakdown.calls })
            if missing > 0 || missingCalls > 0 {
                models.append(.init(client: "codex", model: "unknown", sourceModels: ["模型明细未提供"],
                    breakdown: .init(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0,
                        totalTokens: missing, calls: missingCalls), cacheReadComplete: false, cacheWriteTokens: nil,
                    knownCostUSD: nil, unpricedRequests: missingCalls))
            }
            var parts = [original]
            let externalRows = others[date] ?? []
            for row in externalRows {
                let part = TokenCacheBreakdown(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(row.cacheReadTokens ?? 0),
                    outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0),
                    totalTokens: Int(row.tokens), calls: row.requests)
                parts.append(part)
                models.append(.init(client: row.client.rawValue, model: ModelPresentationIdentity.resolve(row.model).key,
                    sourceModels: [row.model ?? "模型明细未提供"], breakdown: part,
                    cacheReadComplete: row.inputTokens == 0 || row.cacheReadComplete == true && row.cacheReadTokens != nil,
                    cacheWriteTokens: row.cacheWriteComplete == true ? row.cacheWriteTokens.map(Int.init) : nil,
                    knownCostUSD: row.apiCostMicroUSD.map { Double($0) / 1_000_000 },
                    unpricedRequests: row.apiCostMicroUSD == nil ? row.requests : row.unpricedRequests))
            }
            let sum = parts.combined
            let tokens = originalTokens + externalRows.reduce(0) { $0 + Int($1.tokens) }
            let calls = originalCalls + externalRows.reduce(0) { $0 + $1.requests }
            let complete = missing == 0 && missingCalls == 0 && externalRows.allSatisfy { $0.model != nil }
            let cacheComplete = (originalTokens == 0 || original.calls >= originalCalls && original.totalTokens == originalTokens)
                && externalRows.allSatisfy { $0.inputTokens == 0 || $0.cacheReadComplete == true && $0.cacheReadTokens != nil }
            let costs = models.compactMap(\.knownCostUSD)
            return Self(date: date, usage: .init(
                breakdown: .init(inputTokens: sum.inputTokens, cachedInputTokens: sum.cachedInputTokens,
                    outputTokens: sum.outputTokens, reasoningOutputTokens: sum.reasoningOutputTokens, totalTokens: tokens, calls: calls),
                models: ChartModelUsage.combined(models), cacheReadComplete: cacheComplete, modelComplete: complete,
                knownCostUSD: costs.reduce(0, +), hasKnownCost: !costs.isEmpty || calls == 0 && tokens == 0,
                unpricedRequests: models.reduce(0) { $0 + $1.unpricedRequests }))
        }
    }
}

extension ChartUsageSummary {
    var heatmapCostText: String {
        let partial = unpricedRequests > 0 || !modelComplete
        guard hasKnownCost else { return breakdown.totalTokens == 0 && breakdown.calls == 0 ? "$0.00" : "金额未报告" }
        return (partial ? "已知金额 " : "API 等值 ") + knownCostUSD.quotaEstimatorMoneyText
    }
    func heatmapModelText(cost: Bool) -> String {
        let rows = models.map { row in
            let value = cost ? row.knownCostUSD?.quotaEstimatorMoneyText ?? "金额未报告"
                : row.breakdown.totalTokens.abbreviatedTokens + " Token"
            return row.clientLabel + " · " + row.label + " " + value
        }
        return (rows + (modelComplete ? [] : ["部分用量未报告模型"])).joined(separator: "；")
    }
}
