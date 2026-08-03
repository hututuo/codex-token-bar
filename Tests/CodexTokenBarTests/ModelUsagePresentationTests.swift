import XCTest
@testable import CodexTokenBar

final class ModelUsagePresentationTests: XCTestCase {
    func testSlicesCombineAliasesAndSortByTokenShare() {
        let rows = [
            row("gpt-5.6-sol", tokens: 600, calls: 2),
            row("gpt_5.6_sol", tokens: 100, calls: 1),
            row("gpt-5.6-luna", tokens: 300, calls: 1),
        ]

        let slices = ModelUsagePresentation.slices(from: rows)

        XCTAssertEqual(slices.map(\.label), ["Sol", "Luna"])
        XCTAssertEqual(slices.map(\.tokens), [700, 300])
        XCTAssertEqual(slices[0].share, 0.7, accuracy: 0.0001)
        XCTAssertEqual(slices[1].share, 0.3, accuracy: 0.0001)
        XCTAssertEqual(ModelUsagePresentation.compactText(from: rows), "Sol 70% · Luna 30%")
    }

    func testUnknownModelsKeepStableSeparatePresentation() {
        let rows = [row(nil, tokens: 25, calls: 1), row("custom-model", tokens: 75, calls: 1)]
        let slices = ModelUsagePresentation.slices(from: rows)

        XCTAssertEqual(Set(slices.map(\.label)), Set(["未知模型", "custom-model"]))
        XCTAssertEqual(slices.reduce(0) { $0 + $1.tokens }, 100)
    }

    @MainActor
    func testRecentChartPreparationCarriesFiveMinuteModelBreakdownToPointPreview() throws {
        let start = Date(timeIntervalSince1970: 1_786_051_200)
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000,
            cachedInputTokens: 100,
            outputTokens: 200,
            reasoningOutputTokens: 0,
            totalTokens: 1_200,
            calls: 1
        )
        let prepared = RecentUsageChart.prepare(
            range: .twentyFourHours,
            recentBins: [BinUsage(start: start, tokens: 1_200, calls: 1)],
            hourlyBins: [],
            cacheRecentBins: [TokenCacheBucket(start: start, breakdown: breakdown)],
            cacheHourlyBins: [],
            attributionEvents: [
                TokenCacheAttributionEvent(
                    id: "point-sol",
                    start: start.addingTimeInterval(30),
                    model: "gpt-5.6-sol",
                    breakdown: breakdown
                )
            ],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(prepared.modelBreakdowns.count, 1)
        XCTAssertEqual(prepared.modelBreakdowns[0].first?.model, "gpt-5.6-sol")
        XCTAssertEqual(ModelUsagePresentation.compactText(from: prepared.modelBreakdowns[0]), "Sol 100%")
    }

    private func row(_ model: String?, tokens: Int, calls: Int) -> ModelTokenBreakdown {
        ModelTokenBreakdown(
            model: model,
            breakdown: TokenCacheBreakdown(
                inputTokens: tokens,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: tokens,
                calls: calls
            )
        )
    }
}
