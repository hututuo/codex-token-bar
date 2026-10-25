import XCTest
@testable import CodexTokenBar

final class ClientDashboardProjectionTests: XCTestCase {
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

    func testModelCostPeriodsAreSeparateAndRetainClientIdentity() {
        let now = Date()
        let row = ClientUsageSummary(client: .claudeCode, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 20,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: nil, requests: 1, lastSeen: now, incompleteFields: false, apiCostUSD: 0.05, cacheReadComplete: true)
        let context = ClientModelCostPeriods.make(codex: .empty, todayCodex: [], rows: [row], today: [], sevenDay: [row], allowed: ["claudeCode"], now: now)
        XCTAssertTrue(context.today.isEmpty)
        XCTAssertEqual(context.lifetime.first?.id, "claudeCode|claude-sonnet-4-6")
        XCTAssertEqual(context.sevenDay.first?.costUSD, 0.05)
        XCTAssertEqual(context.groups(.lifetime).first?.title, "Claude")
    }
}
