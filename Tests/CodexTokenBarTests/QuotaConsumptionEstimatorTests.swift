import XCTest
@testable import CodexTokenBar

final class QuotaConsumptionEstimatorTests: XCTestCase {
    func testOfficialAPIPriceComputesSelectedWindowCostFromCacheAwareTokens() {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 200_000,
            reasoningOutputTokens: 0,
            totalTokens: 1_200_000,
            calls: 12
        )

        let estimate = QuotaConsumptionEstimator.estimate(
            breakdown: breakdown,
            quotaStartPercent: 80,
            quotaEndPercent: 70,
            priceCard: .officialAPI(.gpt55)
        )

        XCTAssertEqual(estimate.selectedCostUSD, 9.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(estimate.impliedWindowBudgetUSD), 92.0, accuracy: 0.0001)
        XCTAssertEqual(estimate.cacheHitRate, 0.4, accuracy: 0.0001)
    }

    func testEstimateIsUnavailableWhenQuotaDidNotDrop() {
        let estimate = QuotaConsumptionEstimator.estimate(
            breakdown: TokenCacheBreakdown(
                inputTokens: 200_000,
                cachedInputTokens: 100_000,
                outputTokens: 80_000,
                reasoningOutputTokens: 0,
                totalTokens: 280_000,
                calls: 3
            ),
            quotaStartPercent: 60,
            quotaEndPercent: 60,
            priceCard: .officialAPI(.gpt55)
        )

        XCTAssertNil(estimate.impliedWindowBudgetUSD)
        XCTAssertEqual(estimate.confidence, .insufficientQuotaMovement)
    }

    func testPreparedDataBuildsEstimatorSelectionFromClickedRange() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let bins = [
            BinUsage(start: start, tokens: 10, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 20, calls: 1),
            BinUsage(start: start.addingTimeInterval(600), tokens: 30, calls: 1)
        ]
        let cache = [
            TokenCacheBreakdown(inputTokens: 100_000, cachedInputTokens: 20_000, outputTokens: 50_000, reasoningOutputTokens: 0, totalTokens: 150_000, calls: 1),
            TokenCacheBreakdown(inputTokens: 200_000, cachedInputTokens: 80_000, outputTokens: 100_000, reasoningOutputTokens: 0, totalTokens: 300_000, calls: 1),
            TokenCacheBreakdown(inputTokens: 300_000, cachedInputTokens: 120_000, outputTokens: 150_000, reasoningOutputTokens: 0, totalTokens: 450_000, calls: 1)
        ]
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: bins,
            bucketInterval: 300,
            maxTokens: 30,
            maxCalls: 1,
            tokenTotal: 60,
            callTotal: 3,
            recentCacheBreakdown: cache.combined,
            cacheBreakdowns: cache,
            carriedCacheHitRates: [0.2, 0.4, 0.4],
            fiveHourRemainingPercents: [80, 75, 70],
            sevenDayRemainingPercents: [90, 88, 86],
            latestFiveHourRemaining: 70,
            latestSevenDayRemaining: 86,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: [0, 1, 2]
        )

        let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(startIndex: 0, endIndex: 2, priceCard: .officialAPI(.gpt55)))

        XCTAssertEqual(selection.bucketCount, 3)
        XCTAssertEqual(try XCTUnwrap(selection.fiveHour.impliedWindowBudgetUSD), 110.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(selection.sevenDay.impliedWindowBudgetUSD), 275.25, accuracy: 0.0001)
    }

    func testPreparedDataUsesCumulativeQuotaDropAcrossClickedRange() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let bins = [
            BinUsage(start: start, tokens: 10, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 20, calls: 1),
            BinUsage(start: start.addingTimeInterval(600), tokens: 30, calls: 1),
            BinUsage(start: start.addingTimeInterval(900), tokens: 40, calls: 1)
        ]
        let cache = Array(repeating: TokenCacheBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 100_000,
            calls: 1
        ), count: 4)
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: bins,
            bucketInterval: 300,
            maxTokens: 40,
            maxCalls: 1,
            tokenTotal: 100,
            callTotal: 4,
            recentCacheBreakdown: cache.combined,
            cacheBreakdowns: cache,
            carriedCacheHitRates: [0, 0, 0, 0],
            fiveHourRemainingPercents: [80, 75, 78, 70],
            sevenDayRemainingPercents: [90, 88, 89, 86],
            latestFiveHourRemaining: 70,
            latestSevenDayRemaining: 86,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: [0, 1, 2, 3]
        )

        let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(startIndex: 0, endIndex: 3, priceCard: .officialAPI(.gpt55)))

        XCTAssertEqual(selection.fiveHour.quotaDropPercent, 13, accuracy: 0.0001)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(selection.fiveHour.impliedWindowBudgetUSD), 15.3846, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(selection.sevenDay.impliedWindowBudgetUSD), 40.0, accuracy: 0.0001)
    }

    func testPreparedDataBuildsEstimatorSelectionForSevenAndThirtyDayRanges() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let cache = Array(repeating: TokenCacheBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 50_000,
            reasoningOutputTokens: 0,
            totalTokens: 150_000,
            calls: 1
        ), count: 3)

        for range in [RecentChartRange.sevenDays, .thirtyDays] {
            let bins = [
                BinUsage(start: start, tokens: 10, calls: 1),
                BinUsage(start: start.addingTimeInterval(range.bucketInterval), tokens: 20, calls: 1),
                BinUsage(start: start.addingTimeInterval(range.bucketInterval * 2), tokens: 30, calls: 1)
            ]
            let prepared = RecentChartPreparedData(
                range: range,
                bins: bins,
                bucketInterval: range.bucketInterval,
                maxTokens: 30,
                maxCalls: 1,
                tokenTotal: 60,
                callTotal: 3,
                recentCacheBreakdown: cache.combined,
                cacheBreakdowns: cache,
                carriedCacheHitRates: [0.2, 0.2, 0.2],
                fiveHourRemainingPercents: [80, 75, 70],
                sevenDayRemainingPercents: [90, 88, 86],
                latestFiveHourRemaining: 70,
                latestSevenDayRemaining: 86,
                hasCacheCalls: true,
                hasFiveHourQuota: true,
                hasSevenDayQuota: true,
                markerIndices: [0, 1, 2]
            )

            let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(startIndex: 0, endIndex: 2, priceCard: .officialAPI(.gpt55)))

            XCTAssertEqual(selection.bucketCount, 3)
            XCTAssertEqual(selection.endDate.timeIntervalSince(selection.startDate), range.bucketInterval * 3, accuracy: 0.001)
            XCTAssertEqual(selection.fiveHour.quotaDropPercent, 10, accuracy: 0.0001)
            XCTAssertEqual(selection.sevenDay.quotaDropPercent, 4, accuracy: 0.0001)
        }
    }

    func testSelectionStatePreviewsOnHoverThenPinsEndOnSecondClick() {
        var state = RecentChartConsumptionSelectionState()

        state.click(index: 4, validCount: 10)

        XCTAssertEqual(state.startIndex, 4)
        XCTAssertNil(state.fixedEndIndex)
        XCTAssertEqual(state.activeEndIndex(hoveredIndex: 7, fallbackEndIndex: 9), 7)

        state.click(index: 7, validCount: 10)

        XCTAssertEqual(state.startIndex, 4)
        XCTAssertEqual(state.fixedEndIndex, 7)
        XCTAssertEqual(state.activeEndIndex(hoveredIndex: 9, fallbackEndIndex: 9), 7)

        state.click(index: 2, validCount: 10)

        XCTAssertEqual(state.startIndex, 2)
        XCTAssertNil(state.fixedEndIndex)
        XCTAssertEqual(state.activeEndIndex(hoveredIndex: 5, fallbackEndIndex: 9), 5)
    }

    func testRecentUsageChartExposesClickToEstimateQuotaUI() throws {
        let source = try String(contentsOfFile: "Sources/CodexTokenBar/RecentUsageChart.swift", encoding: .utf8)
        let componentSource = try String(contentsOfFile: "Sources/CodexTokenBar/RecentUsageChartComponents.swift", encoding: .utf8)
        let estimatorSource = try String(contentsOfFile: "Sources/CodexTokenBar/QuotaConsumptionEstimator.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("@AppStorage(\"recentChartQuotaEstimateModel\")"))
        XCTAssertTrue(source.contains("consumptionSelectionState"))
        XCTAssertTrue(estimatorSource.contains("fixedEndIndex"))
        XCTAssertTrue(source.contains("quotaConsumptionSelection("))
        XCTAssertTrue(source.contains("onClick:"))
        XCTAssertTrue(source.contains("点击图表估算额度"))
        XCTAssertTrue(componentSource.contains("点击图表可估算额度"))
        XCTAssertTrue(componentSource.contains("RecentChartQuotaEstimateModelSelector"))
        XCTAssertTrue(componentSource.contains("RecentChartQuotaEstimateOverlay"))
        XCTAssertTrue(componentSource.contains("本段消耗"))
        XCTAssertTrue(componentSource.contains("反推总额度"))
        XCTAssertTrue(componentSource.contains("官方 API"))
    }
}
