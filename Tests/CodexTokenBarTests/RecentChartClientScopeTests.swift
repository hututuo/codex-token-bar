import Foundation
import XCTest
@testable import CodexTokenBar

final class RecentChartClientScopeTests: XCTestCase {
    func testChartClientSelectionIsIndependentAndUnavailableChoiceFollowsPage() {
        let page: Set<String> = ["codex", "claudeCode"]
        let available = ["claudeCode", "antigravity"]
        XCTAssertEqual(RecentChartClientScope.resolved("dashboard", page: page, available: available), page)
        XCTAssertEqual(RecentChartClientScope.resolved("antigravity", page: page, available: available), ["antigravity"])
        XCTAssertEqual(RecentChartClientScope.resolved("codex", page: page, available: available), ["codex"])
        XCTAssertEqual(RecentChartClientScope.resolved("all", page: page, available: available), ["codex", "claudeCode", "antigravity"])
        XCTAssertEqual(RecentChartClientScope.resolved("removed-client", page: page, available: available), page)
        XCTAssertEqual(page, ["codex", "claudeCode"])
    }

    func testChartClientProjectionKeepsTokenSourcesSeparateAcrossAllRanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets: [ClientTrendBucket] = [
            .init(client: .claudeCode, startUnix: Int64(now.timeIntervalSince1970),
                  inputTokens: 100, outputTokens: 20, cacheReadTokens: 60, cacheWriteTokens: nil, reasoningTokens: nil, requests: 2),
            .init(client: .antigravity, startUnix: Int64(now.timeIntervalSince1970),
                  inputTokens: 50, outputTokens: 20, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil, requests: 1)
        ]
        for (client, tokens) in [("claudeCode", 120), ("antigravity", 70)] {
            let allowed = RecentChartClientScope.resolved(client, page: ["codex"], available: [client])
            let value = ClientDashboardProjection.snapshot(codex: .empty, rows: [], trend: buckets, daily: [], allowed: allowed, now: now)
            XCTAssertEqual(value.recentBins.reduce(0) { $0 + $1.tokens }, tokens)
            XCTAssertEqual(value.hourlyUsage.reduce(0) { $0 + $1.tokens }, tokens)
            XCTAssertFalse(value.cacheUsage.attributionEventsComplete)
            XCTAssertTrue(value.cacheUsage.attributionEvents.isEmpty)
        }
    }

    @MainActor
    func testAllClientsFeedOriginalChartScalingAndConserveTokensCallsAndLedgerCosts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let breakdown = TokenCacheBreakdown(inputTokens: 1_000, cachedInputTokens: 200, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000, calls: 1)
        let bins = [BinUsage(start: now, tokens: 1_000, calls: 1)]
        let cache = [TokenCacheBucket(start: now, breakdown: breakdown)]
        let codex = DashboardSnapshot(stats: .init(totalTokens: 1_000, peakDayTokens: 1_000, peakThreadTokens: 1_000,
            currentStreakDays: 1, longestStreakDays: 1, totalCalls: 1, totalThreads: 1, mostUsedReasoning: "", skillsExplored: 0, totalSkillsUsed: 0),
            dailyUsage: [], recentBins: bins, hourlyUsage: bins, pluginUsage: [],
            cacheUsage: .init(total: breakdown, daily: [], hourly: cache, recentBins: cache, sessions: [], turns: []), generatedAt: now)
        let external: [ClientTrendBucket] = UsageClient.allCases.enumerated().map { index, client in
            ClientTrendBucket(client: client, startUnix: Int64(now.timeIntervalSince1970), inputTokens: Int64((index+1)*2_000),
                outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: nil, requests: index+1,
                apiCostMicroUSD: Int64((index+1)*100_000), unpricedRequests: 0)
        }
        let all = Set(["codex"] + external.map { $0.client.rawValue })
        for range in RecentChartRange.allCases {
            let projected = ClientDashboardProjection.snapshot(codex: codex, rows: [], trend: external, daily: [], allowed: all, now: now)
            let input = RecentChartPreparationInput(bins: projected.recentBins, hourlyBins: projected.hourlyUsage,
                cacheRecentBins: projected.cacheUsage.recentBins, cacheHourlyBins: projected.cacheUsage.hourly,
                attributionEvents: [], quotaRecentBins: [], quotaHourlyBins: [],
                quotaCostSource: .init(bins: bins, hourlyBins: bins, cacheRecentBins: cache, cacheHourlyBins: cache, attributionEvents: []),
                externalCostBuckets: external, includesCodexCost: true)
            let prepared = RecentChartPreparedSnapshot.build(range: range, input: input, priceModel: .gpt56Sol)
            let baseline = RecentChartPreparedSnapshot.build(range: range,
                input: .init(bins: bins, hourlyBins: bins, cacheRecentBins: cache, cacheHourlyBins: cache,
                    attributionEvents: [], quotaRecentBins: [], quotaHourlyBins: []), priceModel: .gpt56Sol)
            XCTAssertEqual(prepared.data.tokenTotal, 1_000 + external.reduce(0) { $0+Int($1.tokens) })
            XCTAssertEqual(prepared.data.callTotal, 1 + external.reduce(0) { $0+$1.requests })
            let totalCost = prepared.bucketCostsUSD.reduce(0.0, +)
            let baselineCost = baseline.bucketCostsUSD.reduce(0.0, +)
            let externalMicroUSD: Int64 = external.compactMap(\.apiCostMicroUSD).reduce(0, +)
            XCTAssertEqual(totalCost - baselineCost, Double(externalMicroUSD) / 1_000_000, accuracy: 0.000001)
            XCTAssertEqual(prepared.quotaData?.tokenTotal, 1_000, "External costs must never inflate the Codex quota numerator")
            let window = prepared.data.visibleWindowSummary(for: nil)
            let plot = RecentChartPlotData(bins: prepared.data.bins, prepared: prepared.data,
                plot: .init(x: 0, y: 0, width: 980, height: 215), step: 1, bucketCostsUSD: prepared.bucketCostsUSD,
                fixedScales: .init(callValues: prepared.data.bins.map(\.calls)), renderRange: nil,
                scaleRange: window.startIndex...window.endIndex)
            XCTAssertTrue(plot.tokenPoints.allSatisfy { $0.y.isFinite && $0.y >= 0 && $0.y <= 215 })
            XCTAssertTrue(plot.tokenPoints.contains { $0.y < 200 }, "Real aggregate activity must not flatten at the bottom")
        }
    }
}
