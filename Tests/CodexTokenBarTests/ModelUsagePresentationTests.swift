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

    func testAutoReviewRemainsSeparateFromRealGPT54AndGPT53() {
        let rows = [
            row("codex-auto-review", tokens: 600, calls: 2),
            row("gpt-5.4", tokens: 100, calls: 1),
            row("gpt-5.3-codex", tokens: 300, calls: 1),
        ]

        let slices = ModelUsagePresentation.slices(from: rows)

        XCTAssertEqual(slices.map(\.label), ["Auto Review（Luna）", "5.3", "5.4"])
        XCTAssertEqual(slices.map(\.tokens), [600, 300, 100])
    }

    func testAutoReviewChartLabelsUseTheEventCutoverDate() throws {
        let cutover = try XCTUnwrap(CodexAutoReviewPricingPolicy.rules.last?.effectiveFrom)
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000,
            calls: 1
        )
        let rows = ModelUsagePresentation.rows(from: [
            TokenCacheAttributionEvent(
                id: "auto-review-legacy",
                start: cutover.addingTimeInterval(-1),
                model: "codex-auto-review",
                breakdown: breakdown
            ),
            TokenCacheAttributionEvent(
                id: "auto-review-luna",
                start: cutover,
                model: "codex_auto_review",
                breakdown: breakdown
            ),
        ])

        XCTAssertEqual(
            ModelUsagePresentation.slices(from: rows).map(\.label),
            ["Auto Review（5.4）", "Auto Review（Luna）"]
        )
    }

    func testFloatingAutoReviewUsesLunaSlotWithoutTakingAnExtraModelSlot() throws {
        let luna = rowWithBreakdown(
            "gpt-5.6-luna",
            inputTokens: 500_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            totalTokens: 500_000
        )
        let autoReview = rowWithBreakdown(
            "codex-auto-review@luna",
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            totalTokens: 300_000
        )

        let items = FloatingTodayModelUsagePresentation.items(
            from: [luna, autoReview],
            fallbackModel: .gpt56Sol
        )

        XCTAssertEqual(items.map(\.label), ["Luna"])
        XCTAssertEqual(items.first?.tokens, 800_000)
        XCTAssertEqual(items.first?.costUSD ?? -1, 0.16, accuracy: 0.0001)
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
        XCTAssertEqual(spark.valueText(for: .cost), "$0.44（不计入总计）")
        XCTAssertEqual(spark.referenceCostUSD ?? -1, 0.4375, accuracy: 0.0001)
        // A non-zero lifetime share must never be rounded down to a misleading
        // 0% label on the cumulative model-cost row.
        let smallShareSpark = FloatingTodayModelUsageItem(
            id: "gpt-5.3-codex-spark",
            label: "Spark",
            tokens: 1,
            share: 0.0010916,
            costUSD: nil,
            usesIndependentQuota: true,
            referenceCostUSD: nil,
            color: .orange
        )
        XCTAssertEqual(smallShareSpark.valueText(for: .share), "0.1%")
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

    func testFloatingTodayModelUsageShowsDefaultModelTrioAndUsesCostOrder() throws {
        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.items(
                from: [],
                fallbackModel: .gpt56Sol,
                showPlaceholders: true
            ).map(\.label),
            ["Sol", "Terra", "Luna"]
        )

        let oneUsedModel = FloatingTodayModelUsagePresentation.items(
            from: [
                rowWithBreakdown(
                    "gpt-5.4",
                    inputTokens: 1_000,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    totalTokens: 1_000
                ),
            ],
            fallbackModel: .gpt56Sol,
            showPlaceholders: true
        )
        XCTAssertEqual(oneUsedModel.count, 3)
        XCTAssertEqual(oneUsedModel.map(\.label), ["5.4", "Sol", "Terra"])

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

        XCTAssertEqual(items.map(\.label), ["Sol", "Luna", "Terra"])
        XCTAssertEqual(items.map(\.tokens), [2_000_000, 2_000_000, 0])
        XCTAssertEqual(items.map { $0.valueText(for: .share) }, ["50%", "50%", "0%"])
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

    func testFloatingTodayModelCostPaginatesBeyondTheCompactFourItemPage() {
        let rows = [
            rowWithBreakdown("gpt-5.6-sol", inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000),
            rowWithBreakdown("gpt-5.6-terra", inputTokens: 900, cachedInputTokens: 0, outputTokens: 0, totalTokens: 900),
            rowWithBreakdown("gpt-5.6-luna", inputTokens: 800, cachedInputTokens: 0, outputTokens: 0, totalTokens: 800),
            rowWithBreakdown("gpt-5.4", inputTokens: 700, cachedInputTokens: 0, outputTokens: 0, totalTokens: 700),
            rowWithBreakdown("gpt-5.3-codex", inputTokens: 600, cachedInputTokens: 0, outputTokens: 0, totalTokens: 600),
        ]
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: .gpt56Sol
        )

        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.pageCount(for: .cost, items: items),
            2
        )
        XCTAssertEqual(FloatingTodayModelUsagePresentation.pageSizes(for: 4), [4])
        XCTAssertEqual(FloatingTodayModelUsagePresentation.pageSizes(for: 5), [3, 2])
        XCTAssertEqual(FloatingTodayModelUsagePresentation.pageSizes(for: 6), [3, 3])
        XCTAssertEqual(FloatingTodayModelUsagePresentation.pageSizes(for: 7), [4, 3])
        XCTAssertEqual(FloatingTodayModelUsagePresentation.pageSizes(for: 8), [4, 4])
        let firstPage = FloatingTodayModelUsagePresentation.pageItems(
            for: .cost,
            items: items,
            pageIndex: 0
        )
        let secondPage = FloatingTodayModelUsagePresentation.pageItems(
            for: .cost,
            items: items,
            pageIndex: 1
        )
        XCTAssertEqual(firstPage.count, 3)
        XCTAssertEqual(secondPage.count, 2)
        XCTAssertEqual(
            Set(firstPage.map(\.id) + secondPage.map(\.id)),
            Set(items.map(\.id))
        )
        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.pageItems(
                for: .cost,
                items: items,
                pageIndex: 99
            ).map(\.id),
            secondPage.map(\.id)
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
            "更多模型\n5.4 · 0 tokens · 占比 0% · $0.00"
        )
        XCTAssertNil(
            FloatingTodayModelUsagePresentation.overflowDetailText(
                items: Array(items.prefix(FloatingTodayModelUsagePresentation.visibleItemLimit))
            )
        )
    }

    func testDashboardModelCostGroupsKeepCoreModelsExpandedAndMoveUsedOthersBelow() {
        let rows = [
            rowWithBreakdown("gpt-5.6-sol", inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000),
            rowWithBreakdown("gpt-5.4", inputTokens: 500, cachedInputTokens: 0, outputTokens: 0, totalTokens: 500),
            rowWithBreakdown("gpt-5.3-codex", inputTokens: 250, cachedInputTokens: 0, outputTokens: 0, totalTokens: 250),
        ]
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: .gpt56Sol
        )

        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.dashboardPrimaryItems(from: items).map(\.label),
            ["Sol", "Terra", "Luna"]
        )
        XCTAssertEqual(
            FloatingTodayModelUsagePresentation.dashboardSecondaryItems(from: items).map(\.label),
            ["5.4", "5.3"]
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
