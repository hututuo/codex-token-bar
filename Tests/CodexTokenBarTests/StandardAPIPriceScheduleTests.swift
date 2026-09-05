import XCTest
@testable import CodexTokenBar

final class StandardAPIPriceScheduleTests: XCTestCase {
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

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
