import Foundation
import XCTest
@testable import CodexTokenBar

final class SevenDaySavingsEstimatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func breakdown(input: Int, output: Int = 0, calls: Int = 1) -> TokenCacheBreakdown {
        TokenCacheBreakdown(
            inputTokens: input,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: input + output,
            calls: calls
        )
    }

    private func usage(
        events: [TokenCacheAttributionEvent] = [],
        hourly: [TokenCacheBucket] = [],
        recentBins: [TokenCacheBucket] = [],
        complete: Bool = false
    ) -> TokenCacheUsage {
        TokenCacheUsage(
            total: events.map(\.breakdown).combined,
            daily: [],
            hourly: hourly,
            recentBins: recentBins,
            sessions: [],
            turns: [],
            attributionEvents: events,
            attributionEventsComplete: complete
        )
    }

    private func quota(resetAt: Date?) -> AccountQuotaSnapshot {
        var snapshot = AccountQuotaSnapshot.empty
        snapshot.sevenDay = AccountQuotaWindow(label: "7d", usedPercent: 10, resetsAt: resetAt)
        return snapshot
    }

    func testModelCostScopeDefaultsToSevenDay() {
        XCTAssertEqual(DashboardModelCostScope.defaultScope, .sevenDay)
        XCTAssertEqual(DashboardModelCostScope.allCases.first, .sevenDay)
        XCTAssertEqual(DashboardModelCostScope.storedValue(for: nil), .sevenDay)
        XCTAssertEqual(DashboardModelCostScope.storedValue(for: "invalid"), .sevenDay)
        XCTAssertEqual(DashboardModelCostScope.storedValue(for: DashboardModelCostScope.lifetime.rawValue), .lifetime)
    }

    func testMeasuredSevenDayFiltersAtStartAndResetBoundary() {
        let resetAt = now.addingTimeInterval(24 * 60 * 60)
        let cycleStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let atStart = TokenCacheAttributionEvent(
            id: "at-start",
            start: cycleStart,
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 1_000_000)
        )
        let atReset = TokenCacheAttributionEvent(
            id: "at-reset",
            start: resetAt,
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 9_000_000)
        )
        let beforeStart = TokenCacheAttributionEvent(
            id: "before-start",
            start: cycleStart.addingTimeInterval(-1),
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 9_000_000)
        )

        let estimate = SubscriptionSavingsEstimator.sevenDayAPIValue(
            cacheUsage: usage(events: [atReset, beforeStart, atStart], complete: true),
            quotaSnapshot: quota(resetAt: resetAt),
            fallbackModel: .gpt56Terra,
            now: now
        )

        guard case .measured = estimate.quality else {
            return XCTFail("expected complete event stream to be measured")
        }
        XCTAssertEqual(
            estimate.valueUSD,
            OfficialAPIPriceModel.gpt56Sol.currentPriceRates.costUSD(for: breakdown(input: 1_000_000)),
            accuracy: 0.000001
        )
    }

    func testIncompleteEventsUseOnlyCurrentPeriodHourlyFallbackAndMarkEstimate() {
        let resetAt = now.addingTimeInterval(24 * 60 * 60)
        let cycleStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let inside = TokenCacheBucket(
            start: cycleStart.addingTimeInterval(60),
            breakdown: breakdown(input: 1_000_000)
        )
        let outside = TokenCacheBucket(
            start: cycleStart.addingTimeInterval(-60),
            breakdown: breakdown(input: 8_000_000)
        )
        let estimate = SubscriptionSavingsEstimator.sevenDayAPIValue(
            cacheUsage: usage(hourly: [outside, inside], complete: false),
            quotaSnapshot: quota(resetAt: resetAt),
            fallbackModel: .gpt56Terra,
            now: now
        )

        guard case .estimated(let source) = estimate.quality else {
            return XCTFail("expected an explicitly estimated hourly fallback")
        }
        XCTAssertTrue(source.contains("hourly"))
        XCTAssertEqual(
            estimate.valueUSD,
            OfficialAPIPriceModel.gpt56Terra.currentPriceRates.costUSD(for: breakdown(input: 1_000_000)),
            accuracy: 0.000001
        )
        let presentation = SevenDayAPIValuePresentation(estimate: estimate)
        XCTAssertTrue(presentation.labelText.contains("估"))
        XCTAssertTrue(presentation.helpText.contains("回退估算"))
    }

    func testDashboardModelRowsUseCompleteEventsAndKeepSparkAsIndependentRow() {
        let resetAt = now.addingTimeInterval(24 * 60 * 60)
        let cycleStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let sol = TokenCacheAttributionEvent(
            id: "sol",
            start: cycleStart,
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 1_000_000)
        )
        let spark = TokenCacheAttributionEvent(
            id: "spark",
            start: cycleStart.addingTimeInterval(10),
            model: "gpt-5.3-codex-spark",
            breakdown: breakdown(input: 2_000_000)
        )
        let outside = TokenCacheAttributionEvent(
            id: "outside",
            start: resetAt,
            model: "gpt-5.6-terra",
            breakdown: breakdown(input: 8_000_000)
        )

        let data = DashboardSevenDayModelData(
            cacheUsage: usage(events: [outside, spark, sol], complete: true),
            quotaSnapshot: quota(resetAt: resetAt),
            now: now,
            dataAvailable: true
        )

        XCTAssertTrue(data.dataAvailable)
        XCTAssertEqual(data.tokens, 3_000_000)
        XCTAssertEqual(data.rows.count, 2)
        XCTAssertTrue(data.rows.contains { $0.model == "gpt-5.3-codex-spark" })
        XCTAssertTrue(data.rows.contains { $0.model == "gpt-5.6-sol" })
    }

    func testDashboardModelRowsFailClosedForIncompleteEventsOrMissingReset() {
        let resetAt = now.addingTimeInterval(24 * 60 * 60)
        let event = TokenCacheAttributionEvent(
            id: "event",
            start: now,
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 1_000_000)
        )
        let incomplete = DashboardSevenDayModelData(
            cacheUsage: usage(events: [event], complete: false),
            quotaSnapshot: quota(resetAt: resetAt),
            now: now,
            dataAvailable: true
        )
        let missingReset = DashboardSevenDayModelData(
            cacheUsage: usage(events: [event], complete: true),
            quotaSnapshot: quota(resetAt: nil),
            now: now,
            dataAvailable: true
        )

        XCTAssertFalse(incomplete.dataAvailable)
        XCTAssertTrue(incomplete.rows.isEmpty)
        XCTAssertFalse(missingReset.dataAvailable)
        XCTAssertTrue(missingReset.rows.isEmpty)
    }

    func testMissingQuotaShowsWaitingInsteadOfLifetimeValue() {
        let lifetimeEvent = TokenCacheAttributionEvent(
            id: "lifetime",
            start: now.addingTimeInterval(-400 * 24 * 60 * 60),
            model: "gpt-5.6-sol",
            breakdown: breakdown(input: 40_000_000)
        )
        let estimate = SubscriptionSavingsEstimator.sevenDayAPIValue(
            cacheUsage: usage(events: [lifetimeEvent], complete: true),
            quotaSnapshot: nil,
            fallbackModel: .gpt56Sol,
            now: now
        )
        guard case .waiting = estimate.quality else {
            return XCTFail("missing quota must remain a waiting state")
        }
        let presentation = SevenDayAPIValuePresentation(estimate: estimate)
        XCTAssertEqual(presentation.valueText, "待读取")
        XCTAssertTrue(presentation.labelText.contains("待读取"))
    }
}
