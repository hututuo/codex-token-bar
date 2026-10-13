import XCTest
@testable import CodexTokenBar

final class FloatingModelKnownSubtotalTests: XCTestCase {
    func testDatedEstimatorAlreadyPreservesKnownCostWithinPartiallyPricedModel() {
        let rows = [
            row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z"),
            row("gpt61sol", input: 20_000_000, at: "2026-09-29T00:00:00Z"),
        ]
        let combined = ModelUsagePresentation.combinedRows(rows)
        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: combined,
            fallbackBreakdown: rows.map(\.breakdown).combined,
            fallbackModel: .gpt56Sol,
            standardAPI: true,
            rates: { $0.currentPriceRates }
        )

        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.pricingRows.count, 2)
        XCTAssertEqual(estimate.costUSD, 40, accuracy: 0.000001)
        XCTAssertEqual(estimate.detectedModels, [.gpt61Sol])
        XCTAssertEqual(estimate.unpricedModels, ["gpt-6.1-sol"])
        XCTAssertEqual(estimate.unpricedCalls, 1)
        XCTAssertEqual(estimate.fallbackCalls, 0)
    }

    func testCombinedModelKeepsKnownSubtotalWhileFullCostRemainsUnknown() throws {
        for mergeAutoReview in [false, true] {
            let items = FloatingTodayModelUsagePresentation.items(
                from: [
                    row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z"),
                    row("gpt61sol", input: 20_000_000, at: "2026-09-29T00:00:00Z"),
                    row("gpt-6-astra", input: 100_000, at: "2026-09-29T00:00:00Z"),
                ],
                fallbackModel: .gpt56Sol,
                mergeAutoReview: mergeAutoReview
            )
            let partial = try XCTUnwrap(items.first { $0.id == "gpt-6.1-sol" })

            XCTAssertEqual(partial.tokens, 21_000_000)
            XCTAssertNil(partial.costUSD)
            XCTAssertEqual(partial.valueText(for: .cost), "价格未知")
            XCTAssertEqual(try XCTUnwrap(partial.knownPartialCostUSD), 40, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: items)),
                41, accuracy: 0.000001)
        }
    }

    func testAllUnpricedPeriodsNeverBecomeMeasuredZeroThroughPlaceholdersOrSpark() throws {
        let unknown = row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z")
        for showPlaceholders in [false, true] {
            let items = FloatingTodayModelUsagePresentation.items(
                from: [unknown, row("gpt-5.3-codex-spark", input: 20_000_000, at: "2026-09-29T00:00:00Z")],
                fallbackModel: .gpt56Sol,
                showPlaceholders: showPlaceholders
            )
            let item = try XCTUnwrap(items.first { $0.id == "gpt-6.1-sol" })
            XCTAssertNil(item.costUSD)
            XCTAssertNil(item.knownPartialCostUSD)
            XCTAssertEqual(item.valueText(for: .cost), "价格未知")
            XCTAssertNil(FloatingTodayModelUsagePresentation.knownCostUSD(in: items))
        }
    }

    func testFullyPricedPeriodsRetainFullCostAndExcludeIndependentReferenceCost() throws {
        let items = FloatingTodayModelUsagePresentation.items(
            from: [
                row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-29T00:00:00Z"),
                row("gpt61sol", input: 20_000_000, at: "2026-10-13T00:00:00Z"),
                row("gpt-5.3-codex-spark", input: 20_000_000, at: "2026-10-13T00:00:00Z"),
            ],
            fallbackModel: .gpt56Sol
        )
        let sol = try XCTUnwrap(items.first { $0.id == "gpt-6.1-sol" })
        let spark = try XCTUnwrap(items.first { $0.usesIndependentQuota })

        XCTAssertEqual(try XCTUnwrap(sol.costUSD), 42, accuracy: 0.000001)
        XCTAssertNil(sol.knownPartialCostUSD)
        XCTAssertEqual(sol.valueText(for: .cost), "$42.0")
        XCTAssertNil(spark.costUSD)
        XCTAssertNil(spark.knownPartialCostUSD)
        XCTAssertEqual(try XCTUnwrap(spark.referenceCostUSD), 35, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: items)),
            42, accuracy: 0.000001)
    }

    func testPeriodKnownSubtotalIncludesTodayUsingTheSameDatedPricingRows() throws {
        let todayRows = [row("gpt-6.1-sol", input: 20_000_000, at: "2026-10-13T00:00:00Z")]
        let earlierRows = [
            row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z"),
            row("gpt-6.1-sol", input: 500_000, at: "2026-09-29T00:00:00Z"),
            row("gpt-5.3-codex-spark", input: 20_000_000, at: "2026-09-29T00:00:00Z"),
        ]
        let todayItems = FloatingTodayModelUsagePresentation.items(from: todayRows, fallbackModel: .gpt56Sol)
        let earlierItems = FloatingTodayModelUsagePresentation.items(from: earlierRows, fallbackModel: .gpt56Sol)
        let periodItems = FloatingTodayModelUsagePresentation.items(from: earlierRows + todayRows, fallbackModel: .gpt56Sol)
        let todayCost = try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: todayItems))
        let earlierCost = try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: earlierItems))
        let periodCost = try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: periodItems))

        XCTAssertEqual(todayCost, 40, accuracy: 0.000001)
        XCTAssertEqual(earlierCost, 1, accuracy: 0.000001)
        XCTAssertEqual(periodCost, 41, accuracy: 0.000001)
        XCTAssertEqual(periodCost, todayCost + earlierCost, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(periodCost, todayCost)
        XCTAssertNil(periodItems.first { $0.id == "gpt-6.1-sol" }?.costUSD)
    }

    func testIncompleteMixedPriceProjectionDoesNotExposeFallbackAsKnownPartialCost() throws {
        let unknown = row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z")
        let known = row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-29T00:00:00Z")
        let incomplete = ModelTokenBreakdown(
            model: "gpt-6.1-sol",
            breakdown: row("gpt-6.1-sol", input: 20_000_000, at: "2026-09-29T00:00:00Z").breakdown,
            pricePeriods: unknown.pricingRows + known.pricingRows
        )
        let item = try XCTUnwrap(FloatingTodayModelUsagePresentation.items(
            from: [incomplete], fallbackModel: .gpt56Sol
        ).first)

        XCTAssertNil(item.costUSD)
        XCTAssertNil(item.knownPartialCostUSD)
        XCTAssertNil(FloatingTodayModelUsagePresentation.knownCostUSD(in: [item]))
    }

    func testKnownZeroDollarPeriodIsDifferentFromEntirelyUnpricedUsage() throws {
        let unknown = row("gpt-6.1-sol", input: 1_000_000, at: "2026-09-28T23:59:59Z")
        // A measured priced call can have no charged input/output tokens.
        // Its zero is a known contribution, unlike an omitted unknown price.
        let zero = row("gpt-6.1-sol", input: 0, at: "2026-09-29T00:00:00Z")
        let item = try XCTUnwrap(FloatingTodayModelUsagePresentation.items(
            from: [ModelTokenBreakdown(
                model: "gpt-6.1-sol",
                breakdown: [unknown.breakdown, zero.breakdown].combined,
                pricePeriods: unknown.pricingRows + zero.pricingRows
            )],
            fallbackModel: .gpt56Sol
        ).first)

        XCTAssertNil(item.costUSD)
        XCTAssertEqual(item.knownPartialCostUSD, 0)
        XCTAssertEqual(item.valueText(for: .cost), "价格未知")
        XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: [item]), 0)
    }

    private func row(_ model: String, input: Int, at timestamp: String) -> ModelTokenBreakdown {
        let breakdown = TokenCacheBreakdown(
            inputTokens: input, cachedInputTokens: 0, outputTokens: 0,
            reasoningOutputTokens: 0, totalTokens: input, calls: 1
        )
        return ModelTokenBreakdown(model: model, breakdown: breakdown, pricePeriods: [
            ModelTokenPricePeriod(model: model, start: ISO8601DateFormatter().date(from: timestamp)!, breakdown: breakdown),
        ])
    }
}
