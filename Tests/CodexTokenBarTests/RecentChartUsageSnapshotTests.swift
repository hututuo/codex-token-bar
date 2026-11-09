import Foundation
import XCTest
@testable import CodexTokenBar

final class RecentChartUsageSnapshotTests: XCTestCase {
    struct Row: Decodable {
        let client: String?
        let model: String
        let startUnix: Int64
        let inputTokens: Int
        let cacheReadTokens: Int?
        let cacheReadComplete: Bool?
        let cacheWriteTokens: Int?
        let cacheWriteComplete: Bool?
        let outputTokens: Int
        let requests: Int
        let apiCostMicroUSD: Int64?
        let unpricedRequests: Int?
        var breakdown: TokenCacheBreakdown { .init(inputTokens: inputTokens, cachedInputTokens: cacheReadTokens ?? 0,
            outputTokens: outputTokens, reasoningOutputTokens: 0, totalTokens: inputTokens + outputTokens, calls: requests) }
        var date: Date { Date(timeIntervalSince1970: Double(startUnix)) }
        var bucket: ClientTrendBucket { .init(client: UsageClient(rawValue: client!)!, startUnix: startUnix,
            inputTokens: Int64(inputTokens), outputTokens: Int64(outputTokens), cacheReadTokens: cacheReadTokens.map(Int64.init),
            cacheWriteTokens: cacheWriteTokens.map(Int64.init), reasoningTokens: nil, requests: requests,
            apiCostMicroUSD: apiCostMicroUSD, unpricedRequests: unpricedRequests ?? 0, model: model,
            cacheReadComplete: cacheReadComplete, cacheWriteComplete: cacheWriteComplete) }
    }
    struct Fixture: Decodable {
        struct Expected: Decodable { let tokens: Int; let calls: Int; let input: Int; let cached: Int; let knownExternalUSD: Double; let unpriced: Int; let models: [String] }
        let now: Double; let ranges: [String: Double]; let codex: [Row]; let external: [Row]; let expected: Expected
    }
    func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/recent-chart-usage.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    @MainActor func testAllRangesScopesAndEverySummaryUseTheSameClientModelBuckets() throws {
        let fixture = try fixture(), now = Date(timeIntervalSince1970: fixture.now)
        XCTAssertNotNil(RecentChartPolicy.bundled, "The shared range policy must be in the Swift resource bundle")
        func cache(_ width: Double) -> [TokenCacheBucket] {
            Dictionary(grouping: fixture.codex) { floor(Double($0.startUnix) / width) * width }
                .map { .init(start: Date(timeIntervalSince1970: $0.key), breakdown: $0.value.map(\.breakdown).combined) }
                .sorted { $0.start < $1.start }
        }
        let fine = cache(300), hourly = cache(3600)
        let bins = fine.map { BinUsage(start: $0.start, tokens: $0.breakdown.totalTokens, calls: $0.breakdown.calls) }
        let hours = hourly.map { BinUsage(start: $0.start, tokens: $0.breakdown.totalTokens, calls: $0.breakdown.calls) }
        let events = fixture.codex.enumerated().map { index, row in TokenCacheAttributionEvent(id: "fixture-\(index)", start: row.date, model: row.model, breakdown: row.breakdown) }
        let total = fixture.codex.map(\.breakdown).combined
        let codex = DashboardSnapshot(stats: .init(totalTokens: total.totalTokens, peakDayTokens: total.totalTokens, peakThreadTokens: 0,
            currentStreakDays: 1, longestStreakDays: 1, totalCalls: total.calls, totalThreads: 1, mostUsedReasoning: "", skillsExplored: 0, totalSkillsUsed: 0),
            dailyUsage: [], recentBins: bins, hourlyUsage: hours, pluginUsage: [],
            cacheUsage: .init(total: total, daily: [], hourly: hourly, recentBins: fine, sessions: [], turns: [], attributionEvents: events), generatedAt: now)
        let all: Set<String> = ["codex", "claudeCode", "antigravity", "gemini"]
        for range in RecentChartRange.allCases {
            for scope in [all, ["codex"], ["claudeCode"], ["antigravity"], ["gemini"], ["claudeCode", "antigravity"]] as [Set<String>] {
                let external = fixture.external.filter { scope.contains($0.client!) }.map(\.bucket)
                let includeCodex = scope.contains("codex")
                let display = ClientDashboardProjection.snapshot(codex: codex, rows: [], trend: external, daily: [], allowed: scope, now: now)
                let input = RecentChartPreparationInput(bins: display.recentBins, hourlyBins: display.hourlyUsage,
                    cacheRecentBins: display.cacheUsage.recentBins, cacheHourlyBins: display.cacheUsage.hourly,
                    attributionEvents: includeCodex ? events : [], quotaRecentBins: [], quotaHourlyBins: [],
                    quotaCostSource: includeCodex ? .init(bins: bins, hourlyBins: hours, cacheRecentBins: fine, cacheHourlyBins: hourly, attributionEvents: events) : nil,
                    externalCostBuckets: external, includesCodexCost: includeCodex)
                let snapshot = RecentChartPreparedSnapshot.build(range: range, input: input, priceModel: .gpt56Sol)
                XCTAssertEqual(snapshot.data.bucketInterval, fixture.ranges[range.rawValue])
                let last = snapshot.data.bins.count - 1
                let selected = try XCTUnwrap(snapshot.usageSummary(from: last, through: 0))
                let expectedTokens = (includeCodex ? total.totalTokens : 0) + external.reduce(0) { $0 + Int($1.tokens) }
                XCTAssertEqual(selected.breakdown.totalTokens, expectedTokens)
                XCTAssertEqual(selected.models.reduce(0) { $0 + $1.breakdown.totalTokens }, expectedTokens)
                XCTAssertEqual(selected.breakdown.calls, snapshot.data.callTotal)
                XCTAssertEqual(selected.knownCostUSD, snapshot.bucketCostsUSD.reduce(0,+), accuracy: 0.000001)
                XCTAssertEqual(selected, snapshot.usageSummary(from: 0, through: last), "Reverse selection has the same model union")
                let header = snapshot.data.visibleWindowSummary(for: nil)
                XCTAssertEqual(header.tokenTotal, selected.breakdown.totalTokens)
                XCTAssertTrue(selected.models.allSatisfy { scope.contains($0.client) })
                if scope == all {
                    XCTAssertEqual(selected.breakdown.totalTokens, fixture.expected.tokens)
                    XCTAssertEqual(selected.breakdown.inputTokens, fixture.expected.input)
                    XCTAssertEqual(selected.breakdown.cachedInputTokens, fixture.expected.cached)
                    XCTAssertEqual(selected.models.map(\.id).sorted(), fixture.expected.models.sorted())
                    XCTAssertEqual(selected.unpricedRequests, fixture.expected.unpriced)
                    XCTAssertNil(selected.cacheHitRate)
                    var state = RecentChartConsumptionSelectionState()
                    state.click(index: 0, validCount: last + 1); state.click(index: last, validCount: last + 1)
                    let provider = try XCTUnwrap(snapshot.consumptionSelection(state: state))
                    XCTAssertEqual(provider.breakdown.totalTokens, total.totalTokens, "External usage never enters quota estimation")
                    XCTAssertEqual(provider.startIndex, 0); XCTAssertEqual(provider.endIndex, last)
                }
            }
        }
    }
}
