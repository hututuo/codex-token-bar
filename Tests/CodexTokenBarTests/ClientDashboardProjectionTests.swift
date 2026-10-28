import XCTest
@testable import CodexTokenBar

final class ClientDashboardProjectionTests: XCTestCase {
    func testSummaryUsesRecordedPeriodModelsAndNeverLifetimeTotalsAsFallback() {
        let now = Date()
        let counts = TokenCacheBreakdown(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, reasoningOutputTokens: 0, totalTokens: 120, calls: 1)
        let indexed = TokenCacheAttributionEvent(id: "today", start: now.addingTimeInterval(-1), model: "gpt-6-luna", breakdown: counts)
        let old = TokenCacheAttributionEvent(id: "old", start: now.addingTimeInterval(-8 * 86400), model: "gpt-5.6-sol", breakdown: counts)
        func snapshot(_ events: [TokenCacheAttributionEvent]) -> DashboardSnapshot {
            DashboardSnapshot(stats: DashboardSnapshot.empty.stats,
                dailyUsage: [DayUsage(date: Calendar.current.startOfDay(for: now), tokens: 120, calls: 1)],
                recentBins: [BinUsage(start: now.addingTimeInterval(-1), tokens: 120, calls: 1)], hourlyUsage: [], pluginUsage: [],
                cacheUsage: TokenCacheUsage(total: counts, modelBreakdowns: [.init(model: "lifetime-only", breakdown: counts)],
                    daily: [], hourly: [], recentBins: [], sessions: [], turns: [], attributionEvents: events), generatedAt: now)
        }
        let ready = ClientModelCostPeriods.make(codex: snapshot([old, indexed]), todayCodex: [], rows: [], today: [], sevenDay: [], allowed: ["codex", "claudeCode"], now: now)
        XCTAssertEqual(ready.today.map(\.id), ["codex|gpt-6-luna"])
        XCTAssertEqual(ready.sevenDay.map(\.id), ["codex|gpt-6-luna"])
        XCTAssertFalse(ready.groups(.sevenDay).contains { $0.id.hasPrefix("claude:") })
        let pending = ClientModelCostPeriods.make(codex: snapshot([]), todayCodex: [], rows: [], today: [], sevenDay: [], allowed: ["codex", "claudeCode"], now: now)
        XCTAssertTrue(pending.today.isEmpty)
        XCTAssertTrue(pending.sevenDay.isEmpty)
        XCTAssertEqual(pending.codexPendingScopes, [.today, .sevenDay])
        XCTAssertEqual(pending.lifetime.first?.id, "codex|lifetime-only")
    }
    func testDashboardAutoReviewStaysSeparateWithoutChangingFacts() {
        let original = ["gpt-5.6-luna", "codex-auto-review@luna", "gpt-6-luna"].map {
            ModelTokenBreakdown(model: $0, breakdown: .init(
                inputTokens: 100, cachedInputTokens: 0, outputTokens: 20,
                reasoningOutputTokens: 0, totalTokens: 120, calls: 1
            ))
        }
        let costs = ClientModelCostPeriods.make(
            codex: .empty, todayCodex: original, rows: [], today: [], sevenDay: [],
            allowed: ["codex"], now: Date()
        )
        XCTAssertEqual(costs.today.count, 3)
        XCTAssertEqual(costs.today.first { $0.id == "codex|gpt-5.6-luna" }?.tokens, 120)
        XCTAssertEqual(costs.today.first { $0.id == "codex|gpt-6-luna" }?.tokens, 120)
        XCTAssertTrue(costs.today.contains { $0.label.contains("Auto Review") && $0.costUSD == nil && $0.referenceCostUSD != nil })
        XCTAssertEqual(original[1].model, "codex-auto-review@luna")
    }

    func testCodexScopeReturnsOriginalSnapshotAndLineage() {
        let original = DashboardSnapshot.empty
        let result = ClientDashboardProjection.snapshot(codex: original, rows: [], trend: [], daily: [], allowed: ["codex"])
        XCTAssertEqual(result.generatedAt, original.generatedAt)
        XCTAssertEqual(result.usagePrecision, original.usagePrecision)
        XCTAssertEqual(result.exactGeneration, original.exactGeneration)
        XCTAssertEqual(result.stats.totalTokens, original.stats.totalTokens)
    }
    func testClaudeFactsFeedOriginalChartContractsWithoutDuplicatingCacheTokens() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [ClientUsageSummary(client: .claudeCode, model: "claude-sonnet-4-6", inputTokens: 1000,
            outputTokens: 200, cacheReadTokens: 800, cacheWriteTokens: 100, reasoningTokens: 50,
            requests: 2, lastSeen: now, incompleteFields: false, apiCostUSD: 0.1, cacheReadComplete: true)]
        let trend = [ClientTrendBucket(client: .claudeCode, startUnix: Int64(now.timeIntervalSince1970), inputTokens: 1000, outputTokens: 200,
            cacheReadTokens: 800, cacheWriteTokens: 100, reasoningTokens: 50, requests: 2)]
        let result = ClientDashboardProjection.snapshot(codex: .empty, rows: rows, trend: trend, daily: trend, allowed: ["claudeCode"], now: now)
        XCTAssertEqual(result.stats.totalTokens, 1200)
        XCTAssertEqual(result.recentBins.reduce(0) { $0 + $1.tokens }, 1200)
        XCTAssertEqual(result.hourlyUsage.reduce(0) { $0 + $1.tokens }, 1200)
        XCTAssertEqual(result.dailyUsage.reduce(0) { $0 + $1.tokens }, 1200)
        XCTAssertEqual(result.cacheUsage.recentBins.first?.breakdown.cacheHitRate, 0.8)
        XCTAssertTrue(result.cacheUsage.attributionEvents.isEmpty)
        XCTAssertFalse(result.cacheUsage.attributionEventsComplete)
    }
    func testUnknownCacheDoesNotGenerateAZeroHitPoint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = ClientUsageSummary(client: .claudeCode, model: "unknown", inputTokens: 1000, outputTokens: 20,
            cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil, requests: 1, lastSeen: now, incompleteFields: true)
        let point = ClientTrendBucket(client: .claudeCode, startUnix: Int64(now.timeIntervalSince1970), inputTokens: 1000, outputTokens: 20,
            cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil, requests: 1)
        let result = ClientDashboardProjection.snapshot(codex: .empty, rows: [row], trend: [point], daily: [], allowed: ["claudeCode"], now: now)
        XCTAssertEqual(result.recentBins.first?.tokens, 1020)
        XCTAssertTrue(result.cacheUsage.recentBins.isEmpty)
    }
    func testSparseHistoryKeepsTheOriginalYearGridAndEmptyDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let point = ClientTrendBucket(client: .claudeCode, startUnix: Int64(now.timeIntervalSince1970), inputTokens: 100, outputTokens: 20, cacheReadTokens: 80, cacheWriteTokens: 0, reasoningTokens: nil, requests: 1)
        let result = ClientDashboardProjection.snapshot(codex: .empty, rows: [], trend: [point], daily: [point], allowed: ["claudeCode"], now: now)
        XCTAssertEqual(result.dailyUsage.count, 365)
        XCTAssertEqual(result.dailyUsage.filter { $0.tokens == 0 }.count, 364)
        XCTAssertEqual(result.dailyUsage.reduce(0) { $0 + $1.tokens }, 120)
        let full = HeatmapGridMetrics.cellSize(containerWidth: 980, columnCount: 53)
        for columns in [1, 5, 10, 53] {
            let size = HeatmapGridMetrics.cellSize(containerWidth: 980, columnCount: columns)
            XCTAssertEqual(size, full, "A short history cannot inflate the original cells")
            XCTAssertLessThanOrEqual(size * 7 + 24, 140)
        }
    }

    func testNativeChartGeometryTracksTheActualTrailingViewport() {
        let width: CGFloat = 980 * 30
        XCTAssertNil(RecentChartViewportGeometry.offset(originX: 0, viewportWidth: 980, contentWidth: width, positioned: false))
        let latest = RecentChartViewportGeometry.offset(originX: -(width - 980), viewportWidth: 980, contentWidth: width, positioned: false)
        XCTAssertEqual(latest, width - 980)
        let position = RecentChartScrollPresentation(contentOffset: latest!, viewportWidth: 980, contentWidth: width, windowCount: 30)
        XCTAssertTrue(position.isAtLatest)
        XCTAssertFalse(position.isAtOldest)
        XCTAssertEqual(RecentChartViewportGeometry.offset(originX: 0, viewportWidth: 980, contentWidth: width, positioned: true), 0)
        XCTAssertEqual(RecentChartViewportGeometry.offset(originX: 0, viewportWidth: 980, contentWidth: 980, positioned: false), 0)
    }

    @MainActor
    func testCostProjectionReusesResultsButInvalidatesScopeSourceAndRollingWindow() {
        let cache = ClientModelCostPeriodsCache()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DashboardSnapshot.empty
        let row = ClientUsageSummary(client: .claudeCode, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 20,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: nil, requests: 1, lastSeen: now, incompleteFields: false, apiCostUSD: 0.05, cacheReadComplete: true)
        func value(_ allowed: Set<String> = ["codex", "claudeCode"], time: Date? = nil, updated: Date? = nil,
                   todayCodex: [ModelTokenBreakdown] = []) -> ClientModelCostPeriods {
            cache.value(codex: snapshot, todayCodex: todayCodex, rows: [row], today: [row], sevenDay: [row],
                clientsUpdatedAt: updated ?? now, allowed: allowed, now: time ?? now)
        }
        let first = value()
        for _ in 0..<120 { XCTAssertEqual(value(), first) }
        XCTAssertEqual(cache.computationCount, 1)
        XCTAssertTrue(value(["codex"]).lifetime.isEmpty)
        XCTAssertEqual(cache.computationCount, 2)
        _ = value(time: now.addingTimeInterval(61))
        XCTAssertEqual(cache.computationCount, 3)
        _ = value(time: now.addingTimeInterval(61), updated: now.addingTimeInterval(1))
        XCTAssertEqual(cache.computationCount, 4)
        let todayRow = ModelTokenBreakdown(model: "gpt-6-luna", breakdown: .init(inputTokens: 100, cachedInputTokens: 0,
            outputTokens: 10, reasoningOutputTokens: 0, totalTokens: 110, calls: 1))
        let refreshed = value(time: now.addingTimeInterval(61), updated: now.addingTimeInterval(1), todayCodex: [todayRow])
        XCTAssertEqual(cache.computationCount, 5)
        XCTAssertTrue(refreshed.today.contains { $0.id.hasPrefix("codex|") })
    }

    func testModelCostPeriodsAreSeparateAndRetainClientIdentity() {
        let now = Date()
        let row = ClientUsageSummary(client: .claudeCode, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 20,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: nil, requests: 1, lastSeen: now, incompleteFields: false, apiCostUSD: 0.05, cacheReadComplete: true)
        let context = ClientModelCostPeriods.make(codex: .empty, todayCodex: [], rows: [row], today: [], sevenDay: [row], allowed: ["claudeCode"], now: now)
        XCTAssertTrue(context.today.isEmpty)
        XCTAssertEqual(context.lifetime.first?.id, "claudeCode|claude-sonnet-4-6")
        XCTAssertEqual(context.sevenDay.first?.costUSD, 0.05)
        XCTAssertEqual(context.groups(.lifetime).first?.title, "Claude 最新")
    }
}
