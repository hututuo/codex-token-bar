import Foundation
import SwiftUI

/// Display identity includes the client. Billing continues to use raw ledger
/// models and event-time prices before this bounded projection is assembled.
struct ChartModelUsage: Equatable, Sendable, Identifiable {
    var client: String
    var model: String
    var sourceModels: [String]
    var breakdown: TokenCacheBreakdown
    var cacheWriteTokens: Int?
    var knownCostUSD: Double?
    var unpricedRequests: Int
    var id: String { client + "|" + model }
    var label: String { ModelPresentationIdentity.resolve(model).label }
    var clientLabel: String { SpeedColorOverrides.clientTitle("client:" + client) }

    static func combined(_ rows: [Self]) -> [Self] {
        Dictionary(grouping: rows, by: \.id).compactMap { _, values in
            guard var first = values.first else { return nil }
            first.breakdown = values.map(\.breakdown).combined
            first.sourceModels = Array(Set(values.flatMap(\.sourceModels))).sorted()
            first.cacheWriteTokens = values.allSatisfy { $0.cacheWriteTokens != nil }
                ? values.reduce(0) { $0 + ($1.cacheWriteTokens ?? 0) } : nil
            let costs = values.compactMap(\.knownCostUSD)
            first.knownCostUSD = costs.isEmpty ? nil : costs.reduce(0, +)
            first.unpricedRequests = values.reduce(0) { $0 + $1.unpricedRequests }
            return first
        }.sorted { $0.breakdown.totalTokens == $1.breakdown.totalTokens ? $0.id < $1.id : $0.breakdown.totalTokens > $1.breakdown.totalTokens }
    }
}

/// Usage and recorded prices for exactly the displayed buckets, independent of
/// the Codex quota provider's samples and attribution evidence.
struct ChartUsageSummary: Equatable, Sendable {
    var breakdown: TokenCacheBreakdown
    var models: [ChartModelUsage]
    var cacheReadComplete: Bool
    var modelComplete: Bool
    var knownCostUSD: Double
    var hasKnownCost: Bool
    var unpricedRequests: Int
    var cacheHitRate: Double? { cacheReadComplete && breakdown.inputTokens > 0 ? breakdown.cacheHitRate : nil }
    var cacheText: String { cacheHitRate.map(\.percentString) ?? "—" }
    var costText: String {
        guard hasKnownCost || unpricedRequests == 0 else { return "金额未报告" }
        return (unpricedRequests > 0 ? "已知金额 " : "金额 ") + knownCostUSD.quotaEstimatorMoneyText
    }
    static func combined(_ rows: [Self]) -> Self {
        .init(breakdown: rows.map(\.breakdown).combined, models: ChartModelUsage.combined(rows.flatMap(\.models)),
            cacheReadComplete: rows.allSatisfy(\.cacheReadComplete), modelComplete: rows.allSatisfy(\.modelComplete),
            knownCostUSD: rows.reduce(0) { $0 + $1.knownCostUSD }, hasKnownCost: rows.contains(where: \.hasKnownCost),
            unpricedRequests: rows.reduce(0) { $0 + $1.unpricedRequests })
    }
}

extension RecentChartPreparedSnapshot {
    func usageSummary(from start: Int, through end: Int) -> ChartUsageSummary? {
        let lower = max(0, min(start, end)), upper = min(usageBuckets.count - 1, max(start, end))
        guard lower <= upper else { return nil }
        return .combined(Array(usageBuckets[lower...upper]))
    }

    static func usageBuckets(display: RecentChartPreparedData, codex: RecentChartPreparedData?,
                             external: [ClientTrendBucket], costs: [Double], known: [Bool], unknown: [Int],
                             priceModel: OfficialAPIPriceModel) -> [ChartUsageSummary] {
        let interval = display.bucketInterval
        let externalByTime = Dictionary(grouping: external) { Int64(floor(Double($0.startUnix) / interval)) }
        return display.bins.enumerated().map { index, bin in
            let others = externalByTime[Int64(floor(bin.start.timeIntervalSince1970 / interval))] ?? []
            let original = codex?.cacheBreakdowns[safe: index] ?? .empty
            var parts = codex == nil ? [] : [original]
            var models = (codex?.modelBreakdowns[safe: index] ?? []).map { row in
                let price = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [row], fallbackBreakdown: row.breakdown,
                    fallbackModel: priceModel, standardAPI: true, rates: { $0.currentPriceRates })
                return ChartModelUsage(client: "codex", model: ModelPresentationIdentity.resolve(row.model).key,
                    sourceModels: [row.model ?? "unknown"], breakdown: row.breakdown, cacheWriteTokens: nil,
                    knownCostUSD: price.unpricedCalls < row.breakdown.calls ? price.costUSD : nil,
                    unpricedRequests: price.unpricedCalls)
            }
            var cacheComplete = codex == nil || original.calls >= (codex?.bins[safe: index]?.calls ?? 0)
            for row in others {
                let part = TokenCacheBreakdown(inputTokens: Int(row.inputTokens), cachedInputTokens: Int(row.cacheReadTokens ?? 0),
                    outputTokens: Int(row.outputTokens), reasoningOutputTokens: Int(row.reasoningTokens ?? 0),
                    totalTokens: Int(row.tokens), calls: row.requests)
                parts.append(part)
                if row.inputTokens > 0 && (row.cacheReadComplete != true || row.cacheReadTokens == nil) { cacheComplete = false }
                models.append(.init(client: row.client.rawValue, model: ModelPresentationIdentity.resolve(row.model).key,
                    sourceModels: [row.model ?? "unknown"], breakdown: part,
                    cacheWriteTokens: row.cacheWriteComplete == true ? row.cacheWriteTokens.map(Int.init) : nil,
                    knownCostUSD: row.apiCostMicroUSD.map { Double($0) / 1_000_000 },
                    unpricedRequests: row.apiCostMicroUSD == nil ? row.requests : row.unpricedRequests))
            }
            let combined = parts.combined
            let breakdown = TokenCacheBreakdown(inputTokens: combined.inputTokens, cachedInputTokens: combined.cachedInputTokens,
                outputTokens: combined.outputTokens, reasoningOutputTokens: combined.reasoningOutputTokens,
                totalTokens: bin.tokens, calls: bin.calls)
            return ChartUsageSummary(breakdown: breakdown, models: ChartModelUsage.combined(models), cacheReadComplete: cacheComplete,
                modelComplete: models.reduce(0) { $0 + $1.breakdown.totalTokens } == bin.tokens,
                knownCostUSD: costs[safe: index] ?? 0, hasKnownCost: known[safe: index] ?? false,
                unpricedRequests: unknown[safe: index] ?? 0)
        }
    }
}

/// All selected models remain inspectable; no top-three truncation that can
/// hide a whole client. Scroll is local to large model lists.
struct ChartModelUsageList: View {
    let summary: ChartUsageSummary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.models) { row in
                    HStack(spacing: 5) {
                        Circle().fill(ModelUsagePresentation.color(for: row.model)).frame(width: 6, height: 6)
                        Text(row.label + " " + String(summary.breakdown.totalTokens > 0 ? Int((Double(row.breakdown.totalTokens) / Double(summary.breakdown.totalTokens) * 100).rounded()) : 0) + "%")
                        Text(row.clientLabel).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.breakdown.totalTokens.abbreviatedTokens).monospacedDigit()
                    }.help(row.clientLabel + " · " + row.sourceModels.joined(separator: ", "))
                }
                if !summary.modelComplete { Text("部分用量未报告模型").foregroundStyle(.secondary) }
            }.font(.system(size: 10))
        }.frame(width: 300, height: min(CGFloat(max(summary.models.count, 1)) * 18 + (summary.modelComplete ? 0 : 18), 180))
    }
}
