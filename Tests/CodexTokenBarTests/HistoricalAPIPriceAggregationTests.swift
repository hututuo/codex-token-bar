import XCTest
@testable import CodexTokenBar

final class HistoricalAPIPriceAggregationTests: XCTestCase {
    func testSolPeriodsSplitAtCutoverAndAggregateUsingEachHistoricalRate() throws {
        let before = date("2026-08-20T23:59:59Z")
        let atCutover = date("2026-08-21T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)
        let aggregate = oldPeriod.combined(with: newPeriod)
        let row = ModelTokenBreakdown(
            model: "gpt-5.6-sol",
            breakdown: aggregate,
            pricePeriods: [
                ModelTokenPricePeriod(model: "gpt-5.6-sol", start: before, breakdown: oldPeriod),
                ModelTokenPricePeriod(model: "gpt-5.6-sol", start: atCutover, breakdown: newPeriod),
            ]
        )

        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: [row],
            fallbackBreakdown: aggregate,
            fallbackModel: .gpt56Sol,
            standardAPI: true,
            rates: { $0.currentPriceRates }
        )

        XCTAssertEqual(estimate.costUSD, 9, accuracy: 0.0001)
        XCTAssertEqual(estimate.detectedModels, [.gpt56Sol])
    }

    func testCombinedRowsRetainAllPricePeriodsForOneDisplayedModel() throws {
        let before = date("2026-08-20T23:59:59Z")
        let atCutover = date("2026-08-21T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)

        let combined = ModelUsagePresentation.combinedRows([
            ModelTokenBreakdown(
                model: "gpt-5.6-sol",
                breakdown: oldPeriod,
                pricePeriods: [
                    ModelTokenPricePeriod(model: "gpt-5.6-sol", start: before, breakdown: oldPeriod)
                ]
            ),
            ModelTokenBreakdown(
                model: "gpt_5.6_sol",
                breakdown: newPeriod,
                pricePeriods: [
                    ModelTokenPricePeriod(model: "gpt_5.6_sol", start: atCutover, breakdown: newPeriod)
                ]
            ),
        ])

        let row = try XCTUnwrap(combined.first)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(row.breakdown, oldPeriod.combined(with: newPeriod))
        XCTAssertEqual(row.pricePeriods?.count, 2)
        XCTAssertEqual(row.pricePeriods?.compactMap(\.start), [before, atCutover])
        XCTAssertEqual(row.pricePeriods?.map(\.breakdown), [oldPeriod, newPeriod])
    }

    func testGPT55DoesNotFollowSolCutover() throws {
        let before = date("2026-08-20T23:59:59Z")
        let atCutover = date("2026-08-21T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)
        let aggregate = oldPeriod.combined(with: newPeriod)
        let row = ModelTokenBreakdown(
            model: "gpt-5.5",
            breakdown: aggregate,
            pricePeriods: [
                ModelTokenPricePeriod(model: "gpt-5.5", start: before, breakdown: oldPeriod),
                ModelTokenPricePeriod(model: "gpt-5.5", start: atCutover, breakdown: newPeriod),
            ]
        )

        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: [row],
            fallbackBreakdown: aggregate,
            fallbackModel: .gpt56Sol,
            standardAPI: true,
            rates: { $0.currentPriceRates }
        )

        XCTAssertEqual(estimate.costUSD, 10, accuracy: 0.0001)
        XCTAssertEqual(estimate.detectedModels, [.gpt55])
    }

    func testAutoReviewUsesTheDatedRouteBeforeAndAfterItsCutover() throws {
        let before = date("2026-07-29T23:59:59Z")
        let atCutover = date("2026-07-30T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)
        let aggregate = oldPeriod.combined(with: newPeriod)
        let row = ModelTokenBreakdown(
            model: "codex-auto-review",
            breakdown: aggregate,
            pricePeriods: [
                ModelTokenPricePeriod(model: "codex-auto-review", start: before, breakdown: oldPeriod),
                ModelTokenPricePeriod(model: "codex_auto_review", start: atCutover, breakdown: newPeriod),
            ]
        )

        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: [row],
            fallbackBreakdown: aggregate,
            fallbackModel: .gpt56Sol,
            standardAPI: true,
            rates: { $0.currentPriceRates }
        )

        XCTAssertEqual(estimate.costUSD, 2.7, accuracy: 0.0001)
        XCTAssertEqual(estimate.detectedModels, [.gpt56Luna, .gpt54Legacy])
    }

    func testExplicitRadarRatesRemainAuthoritativeWhenPeriodsArePresent() throws {
        let before = date("2026-08-20T23:59:59Z")
        let atCutover = date("2026-08-21T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)
        let aggregate = oldPeriod.combined(with: newPeriod)
        let row = ModelTokenBreakdown(
            model: "gpt-5.6-sol",
            breakdown: aggregate,
            pricePeriods: [
                ModelTokenPricePeriod(model: "gpt-5.6-sol", start: before, breakdown: oldPeriod),
                ModelTokenPricePeriod(model: "gpt-5.6-sol", start: atCutover, breakdown: newPeriod),
            ]
        )
        let radarRates = APIPriceRates(
            inputUSDPerMillion: 7,
            cachedInputUSDPerMillion: 0.7,
            outputUSDPerMillion: 42
        )

        let estimate = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: [row],
            fallbackBreakdown: aggregate,
            fallbackModel: .gpt56Sol,
            rates: { _ in radarRates }
        )

        XCTAssertEqual(estimate.costUSD, 14, accuracy: 0.0001)
    }

    func testFloatingCostItemUsesBothPeriodsAfterRowsAreCombined() throws {
        let before = date("2026-08-20T23:59:59Z")
        let atCutover = date("2026-08-21T00:00:00Z")
        let oldPeriod = breakdown(input: 1_000_000)
        let newPeriod = breakdown(input: 1_000_000)
        let aggregate = oldPeriod.combined(with: newPeriod)
        let items = FloatingTodayModelUsagePresentation.items(
            from: [
                ModelTokenBreakdown(
                    model: "gpt-5.6-sol",
                    breakdown: aggregate,
                    pricePeriods: [
                        ModelTokenPricePeriod(model: "gpt-5.6-sol", start: before, breakdown: oldPeriod),
                        ModelTokenPricePeriod(model: "gpt-5.6-sol", start: atCutover, breakdown: newPeriod),
                    ]
                )
            ],
            fallbackModel: .gpt56Sol
        )

        let item = try XCTUnwrap(items.first { $0.id == "gpt-5.6-sol" })
        XCTAssertEqual(try XCTUnwrap(item.costUSD), 9, accuracy: 0.0001)
        XCTAssertEqual(item.tokens, 2_000_000)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func breakdown(input: Int) -> TokenCacheBreakdown {
        TokenCacheBreakdown(
            inputTokens: input,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: input,
            calls: 1
        )
    }
}

private extension TokenCacheBreakdown {
    func combined(with other: TokenCacheBreakdown) -> TokenCacheBreakdown {
        [self, other].combined
    }
}
