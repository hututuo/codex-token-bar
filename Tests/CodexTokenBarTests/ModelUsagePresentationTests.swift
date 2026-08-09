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

    func testAutoReviewUsesCurrentGPT54ProfileWithoutMergingRealGPT53() {
        let rows = [
            row("codex-auto-review", tokens: 600, calls: 2),
            row("gpt-5.4", tokens: 100, calls: 1),
            row("gpt-5.3-codex", tokens: 300, calls: 1),
        ]

        let slices = ModelUsagePresentation.slices(from: rows)

        XCTAssertEqual(slices.map(\.label), ["5.4", "5.3"])
        XCTAssertEqual(slices.map(\.tokens), [700, 300])
    }

    func testFloatingTodayModelUsagePricesDetectedModelsWithCacheAndExcludesSpark() throws {
        let rows = [
            ModelTokenBreakdown(
                model: "gpt-5.6-sol",
                breakdown: TokenCacheBreakdown(
                    inputTokens: 1_000_000,
                    cachedInputTokens: 800_000,
                    outputTokens: 100_000,
                    reasoningOutputTokens: 0,
                    totalTokens: 1_100_000,
                    calls: 1
                )
            ),
            ModelTokenBreakdown(
                model: "gpt-5.3-codex-spark",
                breakdown: TokenCacheBreakdown(
                    inputTokens: 250_000,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: 250_000,
                    calls: 1
                )
            ),
        ]

        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: .gpt56Luna
        )
        let sol = try XCTUnwrap(items.first { $0.label == "Sol" })
        let spark = try XCTUnwrap(items.first { $0.label == "Spark" })

        XCTAssertEqual(sol.costUSD ?? -1, 4.4, accuracy: 0.0001)
        XCTAssertFalse(sol.usesIndependentQuota)
        XCTAssertEqual(spark.valueText(for: .cost), "独立")
        XCTAssertNil(spark.costUSD)
        XCTAssertTrue(spark.usesIndependentQuota)
        XCTAssertEqual(items.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
    }

    func testFloatingTodayModelUsageUsesFallbackOnlyForUnknownModel() throws {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000_000,
            calls: 1
        )
        let item = try XCTUnwrap(
            FloatingTodayModelUsagePresentation.items(
                from: [ModelTokenBreakdown(model: "future-model", breakdown: breakdown)],
                fallbackModel: .gpt56Luna
            ).first
        )

        XCTAssertEqual(item.costUSD ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(item.label, "future-model")
    }

    func testFloatingTodayModelUsageShowsFourStableCoreModelsAndUsesCostOrder() throws {
        let rows = [
            rowWithBreakdown(
                "gpt-5.6-luna",
                inputTokens: 2_000_000,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: 2_000_000
            ),
            rowWithBreakdown(
                "gpt-5.6-sol",
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 1_000_000,
                totalTokens: 2_000_000
            )
        ]

        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: .gpt56Sol,
            showPlaceholders: true
        )

        XCTAssertEqual(items.map(\.label), ["Sol", "Luna", "Terra", "5.4"])
        XCTAssertEqual(items.map(\.tokens), [2_000_000, 2_000_000, 0, 0])
        XCTAssertEqual(items.map { $0.valueText(for: .share) }, ["50%", "50%", "0%", "0%"])
        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.items(
                from: rows,
                fallbackModel: .gpt56Sol,
                showPlaceholders: true
            ).map(\.id),
            items.map(\.id),
            "share and cost pages must consume one stable model order"
        )
    }

    func testFloatingTodayModelUsageOverflowExplainsHiddenModels() throws {
        let rows = [
            rowWithBreakdown("gpt-5.6-sol", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000),
            rowWithBreakdown("gpt-5.6-luna", inputTokens: 500_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 500_000),
            rowWithBreakdown("gpt-5.6-terra", inputTokens: 400_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 400_000),
            rowWithBreakdown("codex-auto-review", inputTokens: 300_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 300_000),
            rowWithBreakdown("gpt-5.5", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1),
        ]
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: .gpt56Sol,
            showPlaceholders: true
        )

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.overflowDetailText(items: items),
            "更多模型\ngpt-5.5 · 1 tokens · 占比 <0.1% · $0.00"
        )
        XCTAssertNil(
            FloatingTodayModelUsagePresentation.overflowDetailText(
                items: Array(items.prefix(FloatingTodayModelUsagePresentation.visibleItemLimit))
            )
        )
    }

    private func rowWithBreakdown(
        _ model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) -> ModelTokenBreakdown {
        ModelTokenBreakdown(
            model: model,
            breakdown: TokenCacheBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: 0,
                totalTokens: totalTokens,
                calls: 1
            )
        )
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
