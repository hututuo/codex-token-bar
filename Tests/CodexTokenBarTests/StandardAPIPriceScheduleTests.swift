import XCTest
@testable import CodexTokenBar

final class StandardAPIPriceScheduleTests: XCTestCase {
    func testAggregatePreservesUnpricedRowsBeforeFirstQuoteWithoutChangingNoDateEstimates() {
        let breakdown = TokenCacheBreakdown(inputTokens: 1_000_000, cachedInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000_000, calls: 1)
        for (model, expected) in [("gpt-6-sol", 2.0), ("gpt-6-luna", 0.1)] {
            let rows = [ModelTokenBreakdown(model: model, breakdown: breakdown)]
            let before = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
                eventDate: date("2026-09-21T23:59:59Z"), fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
            XCTAssertEqual(before.costUSD, 0); XCTAssertEqual(before.unpricedModels, [model]); XCTAssertEqual(before.unpricedCalls, 1)
            let after = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
                eventDate: date("2026-09-22T00:00:00Z"), fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
            XCTAssertEqual(after.costUSD, expected); XCTAssertTrue(after.unpricedModels.isEmpty)
            let noDate = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
                timestamp: nil, fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
            XCTAssertEqual(noDate.costUSD, expected); XCTAssertTrue(noDate.unpricedModels.isEmpty)
        }
    }
    func testSolUsesOldPriceBeforeCutoverAndNewPriceAtUTCBoundary() throws {
        let before = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.6-sol",
            at: date("2026-08-20T23:59:59Z")
        ))
        XCTAssertEqual(before.modelKey, "gpt-5.6-sol")
        XCTAssertEqual(before.rates, APIPriceRates(
            inputUSDPerMillion: 5,
            cachedInputUSDPerMillion: 0.5,
            outputUSDPerMillion: 30
        ))
        XCTAssertEqual(before.revision, "standard-api-gpt-5.6-sol-before-2026-08-21")

        let atBoundary = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "GPT5.6_SOL",
            at: date("2026-08-21T00:00:00Z")
        ))
        XCTAssertEqual(atBoundary.rates, APIPriceRates(
            inputUSDPerMillion: 4,
            cachedInputUSDPerMillion: 0.4,
            outputUSDPerMillion: 20
        ))
        XCTAssertEqual(atBoundary.revision, "standard-api-gpt-5.6-sol-from-2026-08-21")
    }

    func testTerraAndLunaUseTheirOwnJulyBoundary() throws {
        let terraBefore = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.6-terra",
            at: date("2026-07-29T23:59:59Z")
        ))
        XCTAssertEqual(terraBefore.rates, APIPriceRates(
            inputUSDPerMillion: 2.5,
            cachedInputUSDPerMillion: 0.25,
            outputUSDPerMillion: 15
        ))

        let terraAfter = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.6-terra",
            at: date("2026-07-30T00:00:00Z")
        ))
        XCTAssertEqual(terraAfter.rates, APIPriceRates(
            inputUSDPerMillion: 2,
            cachedInputUSDPerMillion: 0.2,
            outputUSDPerMillion: 12
        ))

        let lunaBefore = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.6-luna",
            at: date("2026-07-29T23:59:59Z")
        ))
        XCTAssertEqual(lunaBefore.rates, APIPriceRates(
            inputUSDPerMillion: 1,
            cachedInputUSDPerMillion: 0.1,
            outputUSDPerMillion: 6
        ))

        let lunaAfter = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.6-luna",
            at: date("2026-07-30T00:00:00Z")
        ))
        XCTAssertEqual(lunaAfter.rates, APIPriceRates(
            inputUSDPerMillion: 0.2,
            cachedInputUSDPerMillion: 0.02,
            outputUSDPerMillion: 1.2
        ))
    }

    func testGPT55IsIndependentFromSolCutoverAndNoPromotionIsApplied() throws {
        let before = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-5.5",
            at: date("2026-08-20T23:59:59Z")
        ))
        let after = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt55",
            at: date("2026-08-21T00:00:00Z")
        ))
        let expected = APIPriceRates(
            inputUSDPerMillion: 5,
            cachedInputUSDPerMillion: 0.5,
            outputUSDPerMillion: 30
        )
        XCTAssertEqual(before.modelKey, "gpt-5.5")
        XCTAssertEqual(before.rates, expected)
        XCTAssertEqual(after.rates, expected)
        XCTAssertEqual(StandardAPIPriceSchedule.currentQuote(for: "gpt-5.6-sol")?.rates.inputUSDPerMillion, 4)
        XCTAssertEqual(StandardAPIPriceSchedule.currentQuote(for: "gpt-5.5")?.rates, expected)
    }

    func testMissingDateDoesNotSilentlyUseCurrentAndUnknownAliasesAreUnpriced() {
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt-5.6-sol", at: nil))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt-5.6", at: date("2026-08-21T00:00:00Z")))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt5.6", at: date("2026-08-21T00:00:00Z")))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt56", at: date("2026-08-21T00:00:00Z")))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "codex-auto-review", at: date("2026-08-21T00:00:00Z")))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt-5.3-codex-spark", at: date("2026-08-21T00:00:00Z")))
        XCTAssertNil(StandardAPIPriceSchedule.currentQuote(for: "unknown-model"))
    }

    func testExistingNonCutoverCardsRemainAvailable() throws {
        let astra = try XCTUnwrap(StandardAPIPriceSchedule.quote(
            for: "gpt-6-astra",
            at: date("2025-01-01T00:00:00Z")
        ))
        XCTAssertEqual(astra.rates, APIPriceRates(
            inputUSDPerMillion: 10,
            cachedInputUSDPerMillion: 1,
            outputUSDPerMillion: 50
        ))

        let legacy = try XCTUnwrap(StandardAPIPriceSchedule.currentQuote(for: "gpt-5.4"))
        XCTAssertEqual(legacy.rates, APIPriceRates(
            inputUSDPerMillion: 2.5,
            cachedInputUSDPerMillion: 0.25,
            outputUSDPerMillion: 15
        ))
    }


    func testGPT61SolAliasesAndReleaseBoundaryStayIndependentFromPreviousSol() throws {
        let boundary = date("2026-09-29T00:00:00Z")
        let expected = APIPriceRates(inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.1, outputUSDPerMillion: 10)
        for alias in ["gpt-6.1-sol", "GPT_6.1_SOL", "GPT 6.1 Sol", "gpt61-sol", "gpt61sol"] {
            XCTAssertEqual(OfficialAPIPriceModel.detected(from: alias), .gpt61Sol)
            XCTAssertEqual(StandardAPIPriceSchedule.canonicalModelKey(for: alias), "gpt-6.1-sol")
            XCTAssertNil(StandardAPIPriceSchedule.quote(for: alias, at: boundary.addingTimeInterval(-1)))
            XCTAssertEqual(StandardAPIPriceSchedule.quote(for: alias, at: boundary)?.rates, expected)
            XCTAssertEqual(StandardAPIPriceSchedule.currentQuote(for: alias)?.rates, expected)
        }
        XCTAssertEqual(OfficialAPIPriceModel.storedValue(for: "gpt61Sol"), .gpt61Sol)
        XCTAssertEqual(OfficialAPIPriceModel.gpt61Sol.title, "GPT-6.1 Sol")
        XCTAssertNil(OfficialAPIPriceModel.detected(from: "gpt-6.1-sol-preview"))
        XCTAssertNil(StandardAPIPriceSchedule.currentQuote(for: "gpt-6.1"))
        XCTAssertNil(StandardAPIPriceSchedule.quote(for: "gpt-6.1-sol", at: nil))
        XCTAssertEqual(StandardAPIPriceSchedule.currentQuote(for: "gpt-6-sol")?.rates.cachedInputUSDPerMillion, 0.2)
        XCTAssertEqual(StandardAPIPriceSchedule.partitionStart(at: boundary), boundary)
        XCTAssertEqual(StandardAPIPriceSchedule.partitionStart(at: boundary.addingTimeInterval(-1)), date("2026-09-22T00:00:00Z"))
        XCTAssertNotEqual(ModelPricingKey(model: "gpt-6.1-sol", at: boundary),
                          ModelPricingKey(model: "gpt-6.1-sol", at: boundary.addingTimeInterval(-1)))
        XCTAssertTrue(StandardAPIPriceSchedule.sqlPartitionExpression(timestamp: "bucket_start")
            .contains(">= \(Int(boundary.timeIntervalSince1970)) THEN 4"))
    }

    func testGPT61SolAggregateUsesItsCacheRateWithoutFallback() {
        let breakdown = TokenCacheBreakdown(inputTokens: 1_000_000, cachedInputTokens: 500_000,
            outputTokens: 100_000, reasoningOutputTokens: 0, totalTokens: 1_100_000, calls: 1)
        let boundary = date("2026-09-29T00:00:00Z")
        let rows = [ModelTokenBreakdown(model: "gpt-6.1-sol", breakdown: breakdown)]
        let before = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
            eventDate: boundary.addingTimeInterval(-1), fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
        XCTAssertEqual(before.costUSD, 0)
        XCTAssertEqual(before.unpricedModels, ["gpt-6.1-sol"])
        let after = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
            eventDate: boundary, fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
        XCTAssertEqual(after.costUSD, 2.05, accuracy: 0.000001)
        XCTAssertEqual(after.detectedModels, [.gpt61Sol])
        XCTAssertEqual(after.fallbackCalls, 0)
        XCTAssertTrue(after.unpricedModels.isEmpty)
        let noDate = ModelAwareAPIPriceEstimator.estimate(modelBreakdowns: rows,
            timestamp: nil, fallbackBreakdown: breakdown, fallbackModel: .gpt56Sol)
        XCTAssertEqual(noDate.costUSD, 2.05, accuracy: 0.000001)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
