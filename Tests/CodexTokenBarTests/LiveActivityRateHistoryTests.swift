import XCTest
@testable import CodexTokenBar

final class LiveActivityRateHistoryTests: XCTestCase {
    @MainActor
    func testFiveSecondMeanWeightsActualElapsedTimeAndKeepsModelContributions() throws {
        let history = LiveActivityRateHistory()
        history.record(now: 100, rates: [.init(model: "gpt-6-astra", tokensPerSecond: 40)])
        history.record(now: 101, rates: [.init(model: "gpt-6.1-sol", tokensPerSecond: 80)])
        history.record(now: 103, rates: [.init(model: "gpt-6-astra", tokensPerSecond: 20)])
        history.record(now: 105, rates: [])
        let point = try XCTUnwrap(history.points.first)
        XCTAssertEqual(point.start, 100)
        XCTAssertEqual(point.total, 48, accuracy: 0.000001)
        XCTAssertEqual(point.modelRates.first { $0.model == "gpt-6-astra" }?.tokensPerSecond, 16)
        XCTAssertEqual(point.modelRates.first { $0.model == "gpt-6.1-sol" }?.tokensPerSecond, 32)
    }
    @MainActor
    func testLongSamplingGapDoesNotInventContinuousWorkAndHistoryIsBounded() {
        let history = LiveActivityRateHistory()
        history.record(now: 100, rates: [.init(model: "gpt-6-astra", tokensPerSecond: 40)])
        history.record(now: 110, rates: [])
        history.record(now: 115, rates: [])
        XCTAssertFalse(history.points.contains { $0.start == 105 })
        XCTAssertTrue(history.points.filter { $0.start >= 110 }.allSatisfy { $0.total == 0 })
        for at in stride(from: 116.0, through: 2116.0, by: 1) { history.record(now: at, rates: []) }
        XCTAssertLessThanOrEqual(history.points.count, 360)
        XCTAssertTrue(history.points.allSatisfy { $0.start >= 2116 - 1800 })
        history.clear()
        XCTAssertTrue(history.points.isEmpty)
    }
    func testYuanConversionPricesEachModelAndRefusesUnknownOrUnattributedAmounts() throws {
        let rates: [ModelRateContribution] = [.init(model: "gpt-6-astra", tokensPerSecond: 40), .init(model: "gpt-6.1-sol", tokensPerSecond: 60)]
        let a = try XCTUnwrap(StandardAPIPriceSchedule.currentQuote(for: "gpt-6-astra"))
        let s = try XCTUnwrap(StandardAPIPriceSchedule.currentQuote(for: "gpt-6.1-sol"))
        let expected = (40 * a.outputUSDPerMillion + 60 * s.outputUSDPerMillion) * 7.2 / 1_000_000
        XCTAssertEqual(try XCTUnwrap(ActivityRateUnit.yuan.value(total: 100, rates: rates, exchangeRate: 7.2)), expected, accuracy: 0.000000001)
        XCTAssertNil(ActivityRateUnit.yuan.value(total: 101, rates: rates, exchangeRate: 7.2))
        XCTAssertNil(ActivityRateUnit.yuan.value(total: 10, rates: [.init(model: "private-model", tokensPerSecond: 10)], exchangeRate: 7.2))
        XCTAssertEqual(ActivityRateUnit.yuan.value(total: 0, rates: [], exchangeRate: 7.2), 0)
        XCTAssertEqual(ActivityRateUnit.tokens.value(total: 100, rates: [], exchangeRate: .nan), 100)
        XCTAssertEqual(ActivityRateUnit.safeExchangeRate(.nan), 7.2)
        XCTAssertEqual(ActivityRateUnit.yuan.text(0.00001), "<0.0001")
    }
}
