import XCTest
@testable import CodexTokenBar

final class PlanCostNormalizationTests: XCTestCase {
    private func breakdown(_ input: Int = 1_000_000) -> TokenCacheBreakdown {
        TokenCacheBreakdown(inputTokens: input, cachedInputTokens: 0, outputTokens: 0,
                            reasoningOutputTokens: 0, totalTokens: input, calls: 1)
    }
    func testMixedModelsKeepOriginalAndNormalizePerModel() {
        let rows = ["gpt-5.6-sol", "gpt-6-astra", "gpt-5.6-luna", "gpt-5.6-terra"].map {
            ModelTokenBreakdown(model: $0, breakdown: breakdown())
        }
        let total = TokenCacheBreakdown(inputTokens: 4_000_000, cachedInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 4_000_000, calls: 4)
        let estimate = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
            fallbackBreakdown: total, fallbackModel: .gpt56Sol, standardAPI: true,
            rates: { $0.currentPriceRates })
        XCTAssertEqual(estimate.costUSD, 16.2, accuracy: 0.000001)
        XCTAssertEqual(estimate.normalizedCostUSD, 21.4, accuracy: 0.000001)
    }
    func testHistoricalAliasUsesItsDatedModel() {
        for (date, original, normalized) in [("2026-07-29T12:00:00Z", 2.5, 2.5), ("2026-08-01T12:00:00Z", 0.2, 0.4)] {
            let estimate = ModelAwareAPIPriceEstimator.estimate(
                modelBreakdowns: [ModelTokenBreakdown(model: "codex-auto-review", breakdown: breakdown())],
                eventDate: ISO8601DateFormatter().date(from: date)!,
                fallbackBreakdown: breakdown(), fallbackModel: .gpt56Sol)
            XCTAssertEqual(estimate.costUSD, original, accuracy: 0.000001)
            XCTAssertEqual(estimate.normalizedCostUSD, normalized, accuracy: 0.000001)
        }
    }
    func testFallbackAndUnknownPreserveExistingPricingRules() {
        let fallback = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [],
            fallbackBreakdown: breakdown(), fallbackModel: .gpt6Astra, rates: { $0.currentPriceRates })
        XCTAssertEqual(fallback.costUSD, 10)
        XCTAssertEqual(fallback.normalizedCostUSD, 15)
        let unknown = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: [ModelTokenBreakdown(model: "future-model", breakdown: breakdown())],
            fallbackBreakdown: breakdown(), fallbackModel: .gpt6Astra, rates: { $0.currentPriceRates })
        XCTAssertEqual(unknown.costUSD, 0)
        XCTAssertEqual(unknown.normalizedCostUSD, 0)
        XCTAssertEqual(unknown.unpricedModels, ["future-model"])
    }
}
