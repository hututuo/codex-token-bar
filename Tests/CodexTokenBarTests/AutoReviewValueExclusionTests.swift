import XCTest
@testable import CodexTokenBar

final class AutoReviewValueExclusionTests: XCTestCase {
    private let oneMillion = TokenCacheBreakdown(inputTokens: 1_000_000, cachedInputTokens: 0,
        outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000_000, calls: 1)

    private func row(_ model: String, at date: Date? = nil) -> ModelTokenBreakdown {
        .init(model: model, breakdown: oneMillion,
            pricePeriods: [.init(model: model, start: date, breakdown: oneMillion)])
    }

    func testReviewTokensAndReferenceSurviveButPaidLunaAloneEntersTotal() throws {
        let rows = [row("codex-auto-review"), row("gpt-5.6-luna")]
        let estimate = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
            fallbackBreakdown: rows.map(\.breakdown).combined, fallbackModel: .gpt56Sol,
            rates: { $0.currentPriceRates })
        XCTAssertEqual(estimate.costUSD, OfficialAPIPriceModel.gpt56Luna.currentPriceRates.costUSD(for: oneMillion), accuracy: 0.000001)
        XCTAssertEqual(estimate.excludedModels, ["codex-auto-review"])
        XCTAssertEqual(estimate.excludedCalls, 1)
        XCTAssertEqual(rows.map(\.breakdown).combined.totalTokens, 2_000_000)
        XCTAssertEqual(rows[0].model, "codex-auto-review")
        let items = FloatingTodayModelUsagePresentation.items(from: rows, fallbackModel: .gpt56Sol)
        let review = try XCTUnwrap(items.first { $0.id.hasPrefix("codex-auto-review") })
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(review.isReferenceOnly)
        XCTAssertFalse(review.usesIndependentQuota, "Free review is not the separate Spark quota")
        XCTAssertNil(review.costUSD)
        XCTAssertGreaterThan(try XCTUnwrap(review.referenceCostUSD), 0)
        XCTAssertTrue(review.valueText(for: .cost).contains("不计入总计"))
        XCTAssertEqual(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: items)), estimate.costUSD, accuracy: 0.000001)
    }

    func testDatedReviewReferenceRetainsOldPriceCardsButNoBillableAmount() throws {
        let cutover = try XCTUnwrap(CodexAutoReviewPricingPolicy.rules.last?.effectiveFrom)
        let rows = [row("codex-auto-review", at: cutover.addingTimeInterval(-1)), row("codex-auto-review", at: cutover)]
        let items = FloatingTodayModelUsagePresentation.items(from: rows, fallbackModel: .gpt56Sol)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.compactMap(\.referenceCostUSD).reduce(0,+), 2.7, accuracy: 0.000001)
        XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: items), 0)
        XCTAssertTrue(items.allSatisfy(\.isReferenceOnly))
    }

    func testKnownReviewIsRemovedFromIncompleteCoverageFallback() {
        let estimate = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [row("codex-auto-review")],
            fallbackBreakdown: [oneMillion, oneMillion].combined, fallbackModel: .gpt56Sol,
            rates: { $0.currentPriceRates })
        XCTAssertEqual(estimate.costUSD, OfficialAPIPriceModel.gpt56Sol.currentPriceRates.costUSD(for: oneMillion), accuracy: 0.000001)
        XCTAssertEqual(estimate.fallbackCalls, 1)
        XCTAssertEqual(estimate.excludedCalls, 1)
    }

    func testSubscriptionValueExcludesReviewWithoutHidingTokenUsage() throws {
        let now = Date()
        let rows = [row("codex-auto-review"), row("gpt-5.6-luna")]
        let value = try XCTUnwrap(SubscriptionSavingsEstimator.estimate(
            breakdown: rows.map(\.breakdown).combined, modelBreakdowns: rows,
            firstUsageAt: now.addingTimeInterval(-60), planLabel: "Pro", priceModel: .gpt56Sol, now: now))
        XCTAssertEqual(value.apiEquivalentUSD, OfficialAPIPriceModel.gpt56Luna.currentPriceRates.costUSD(for: oneMillion), accuracy: 0.000001)
        XCTAssertEqual(value.excludedModels, ["codex-auto-review"])
        XCTAssertEqual(value.excludedCalls, 1)
    }

    func testLegacyUnderlyingPricePeriodCannotOverrideKnownFreeParent() throws {
        let period = ModelTokenPricePeriod(model: "gpt-5.6-luna", start: nil, breakdown: oneMillion)
        let legacy = ModelTokenBreakdown(model: "codex-auto-review@luna", breakdown: oneMillion, pricePeriods: [period])
        let value = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [legacy],
            fallbackBreakdown: oneMillion, fallbackModel: .gpt56Sol, rates: { $0.currentPriceRates })
        XCTAssertEqual(value.costUSD, 0)
        XCTAssertEqual(value.excludedCalls, 1)
        XCTAssertEqual(try XCTUnwrap(AutoReviewReferencePricing.costUSD(for: legacy)), 0.2, accuracy: 0.000001)
        XCTAssertEqual(legacy.pricingRows, [period])
    }
}
