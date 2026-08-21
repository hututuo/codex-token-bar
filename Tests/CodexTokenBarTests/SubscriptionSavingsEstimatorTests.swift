import Foundation
import XCTest
@testable import CodexTokenBar

final class SubscriptionSavingsEstimatorTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testEstimateSubtractsMonthlyProCostFromCacheAwareAPIValue() throws {
        let first = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        let now = Date(timeIntervalSince1970: 1_782_864_000) // 2026-07-07 UTC
        let breakdown = TokenCacheBreakdown(
            inputTokens: 2_000_000,
            cachedInputTokens: 1_000_000,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 0,
            totalTokens: 3_000_000,
            calls: 1
        )

        let estimate = try XCTUnwrap(SubscriptionSavingsEstimator.estimate(
            breakdown: breakdown,
            firstUsageAt: first,
            planLabel: "Pro",
            priceModel: .gpt56Sol,
            now: now,
            calendar: utcCalendar
        ))

        XCTAssertEqual(estimate.billingMonths, 7)
        XCTAssertEqual(estimate.apiEquivalentUSD, 35.5, accuracy: 0.0001)
        XCTAssertEqual(estimate.subscriptionCostUSD, 1_400)
        XCTAssertEqual(estimate.netSavingsUSD, -1_364.5)
        XCTAssertEqual(
            SubscriptionSavingsPresentation(estimate: estimate).labelText,
            "累计净薅到（估）"
        )
    }

    func testEstimateAutomaticallyPricesEachRecordedModelAndUsesFallbackOnlyForUnknownRows() throws {
        let first = Date(timeIntervalSince1970: 1_767_225_600)
        let now = Date(timeIntervalSince1970: 1_767_312_000)
        let sol = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000_000,
            calls: 1
        )
        let terra = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000_000,
            calls: 1
        )
        let unknown = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000_000,
            calls: 1
        )

        let estimate = try XCTUnwrap(SubscriptionSavingsEstimator.estimate(
            breakdown: [sol, terra, unknown].combined,
            modelBreakdowns: [
                ModelTokenBreakdown(model: "gpt-5.6-sol", breakdown: sol),
                ModelTokenBreakdown(model: "gpt-5.6-terra", breakdown: terra),
                ModelTokenBreakdown(model: "future-model", breakdown: unknown),
            ],
            firstUsageAt: first,
            planLabel: "Enterprise",
            priceModel: .gpt56Luna,
            now: now,
            calendar: utcCalendar
        ))

        XCTAssertEqual(estimate.apiEquivalentUSD, 7.2, accuracy: 0.0001)
        XCTAssertEqual(estimate.detectedModels, [.gpt56Sol, .gpt56Terra])
        XCTAssertEqual(estimate.fallbackModelCalls, 1)
        XCTAssertTrue(SubscriptionSavingsPresentation(estimate: estimate).helpText.contains("未知记录"))
    }

    func testSparkLifetimeValueIsZeroButIndependentQuotaCallsRemainVisible() throws {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 2_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 2_000_000,
            calls: 2
        )
        let estimate = try XCTUnwrap(SubscriptionSavingsEstimator.estimate(
            breakdown: breakdown,
            modelBreakdowns: [ModelTokenBreakdown(model: "gpt-5.3-codex-spark", breakdown: breakdown)],
            firstUsageAt: Date(timeIntervalSince1970: 1_767_225_600),
            planLabel: "Enterprise",
            priceModel: .gpt56Sol,
            now: Date(timeIntervalSince1970: 1_767_312_000),
            calendar: utcCalendar
        ))

        XCTAssertEqual(estimate.apiEquivalentUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(estimate.detectedModels, [])
        XCTAssertEqual(estimate.fallbackModelCalls, 0)
        XCTAssertEqual(estimate.excludedModels, ["gpt-5.3-codex-spark"])
        XCTAssertEqual(estimate.excludedCalls, 2)
        let helpText = SubscriptionSavingsPresentation(estimate: estimate).helpText
        XCTAssertTrue(helpText.contains("独立额度"))
        XCTAssertFalse(helpText.contains("缺少逐模型历史"))
        XCTAssertFalse(helpText.contains("未知模型回退"))
    }

    func testBillingMonthsAreCalendarMonthsInclusive() {
        let components = DateComponents(timeZone: utcCalendar.timeZone, year: 2025, month: 11, day: 30)
        let first = utcCalendar.date(from: components)!
        let now = utcCalendar.date(from: DateComponents(timeZone: utcCalendar.timeZone, year: 2026, month: 2, day: 1))!
        XCTAssertEqual(SubscriptionSavingsEstimator.billingMonthCount(from: first, through: now, calendar: utcCalendar), 4)
    }

    func testPublicMonthlyPlanPricesAndUnknownPlans() {
        XCTAssertEqual(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("Plus"), 20)
        XCTAssertEqual(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("ChatGPT Pro"), 200)
        XCTAssertEqual(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("Business"), 25)
        XCTAssertEqual(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("Free"), 0)
        XCTAssertNil(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("Enterprise"))
        XCTAssertNil(SubscriptionSavingsEstimator.monthlyPlanPriceUSD("套餐待读取"))
    }

    func testPresentationFallsBackToAPIValueWhenPlanPriceIsUnknown() throws {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 1_000_000,
            calls: 1
        )
        let estimate = try XCTUnwrap(SubscriptionSavingsEstimator.estimate(
            breakdown: breakdown,
            firstUsageAt: Date(timeIntervalSince1970: 1_700_000_000),
            planLabel: "Enterprise",
            priceModel: .gpt56Terra,
            now: Date(timeIntervalSince1970: 1_700_100_000),
            calendar: utcCalendar
        ))
        let presentation = SubscriptionSavingsPresentation(estimate: estimate)

        XCTAssertEqual(presentation.valueText, "$2.00")
        XCTAssertEqual(presentation.labelText, "API 等值（估）")
        XCTAssertTrue(presentation.helpText.contains("暂不计算净节省"))
    }

    func testDashboardStatsLifetimeBreakdownUsesFullAggregateFields() {
        let stats = DashboardStats(
            totalTokens: 165,
            peakDayTokens: 100,
            peakThreadTokens: 80,
            currentStreakDays: 1,
            longestStreakDays: 1,
            totalCalls: 2,
            totalThreads: 2,
            mostUsedReasoning: "中",
            skillsExplored: 0,
            totalSkillsUsed: 0,
            totalInputTokens: 150,
            totalCachedInputTokens: 250,
            totalOutputTokens: 15,
            firstUsageAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(stats.lifetimeTokenBreakdown.inputTokens, 150)
        XCTAssertEqual(stats.lifetimeTokenBreakdown.cachedInputTokens, 150)
        XCTAssertEqual(stats.lifetimeTokenBreakdown.outputTokens, 15)
        XCTAssertEqual(stats.lifetimeTokenBreakdown.totalTokens, 165)
    }

    func testDashboardStatsDecodesSnapshotsWrittenBeforeSavingsFieldsExisted() throws {
        let data = Data(#"{"totalTokens":10,"peakDayTokens":10,"peakThreadTokens":10,"currentStreakDays":1,"longestStreakDays":1,"totalCalls":1,"totalThreads":1,"mostUsedReasoning":"中","skillsExplored":0,"totalSkillsUsed":0}"#.utf8)
        let stats = try JSONDecoder().decode(DashboardStats.self, from: data)

        XCTAssertNil(stats.totalInputTokens)
        XCTAssertNil(stats.totalCachedInputTokens)
        XCTAssertNil(stats.totalOutputTokens)
        XCTAssertNil(stats.firstUsageAt)
    }

    func testTokenCacheUsageDecodesSnapshotWrittenBeforeModelProjectionsExisted() throws {
        let encoded = try JSONEncoder().encode(TokenCacheUsage.empty)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "modelBreakdowns")
        object.removeValue(forKey: "dailyModelBreakdowns")
        object.removeValue(forKey: "attributionModelBucketsComplete")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TokenCacheUsage.self, from: legacyData)

        XCTAssertTrue(decoded.modelBreakdowns.isEmpty)
        XCTAssertTrue(decoded.dailyModelBreakdowns.isEmpty)
        XCTAssertFalse(decoded.attributionModelBucketsComplete)
        XCTAssertEqual(decoded.total, .empty)
    }
}
