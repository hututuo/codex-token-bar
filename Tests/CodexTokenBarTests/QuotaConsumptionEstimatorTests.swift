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

    func testSelectionReportsSevenDayToFiveHourBudgetRatioAndDivergence() throws {
        let highDivergence = selection(fiveHourBudget: 10, sevenDayBudget: 76)
        let lowDivergence = selection(fiveHourBudget: 10, sevenDayBudget: 44)
        let normal = selection(fiveHourBudget: 10, sevenDayBudget: 60)

        XCTAssertEqual(try XCTUnwrap(highDivergence.sevenDayToFiveHourBudgetRatio), 7.6, accuracy: 0.0001)
        XCTAssertTrue(highDivergence.hasDivergentBudgetRatio)
        XCTAssertEqual(try XCTUnwrap(lowDivergence.sevenDayToFiveHourBudgetRatio), 4.4, accuracy: 0.0001)
        XCTAssertTrue(lowDivergence.hasDivergentBudgetRatio)
        XCTAssertFalse(normal.hasDivergentBudgetRatio)
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

    func testPreparedDataIgnoresFullUsageSpikeWhenEstimatingQuotaDrop() throws {
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
            fiveHourRemainingPercents: [100, 0, 99, 98],
            sevenDayRemainingPercents: [100, 0, 99, 98],
            latestFiveHourRemaining: 98,
            latestSevenDayRemaining: 98,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: [0, 1, 2, 3]
        )

        let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(startIndex: 0, endIndex: 3, priceCard: .officialAPI(.gpt55)))

        XCTAssertEqual(selection.fiveHour.quotaDropPercent, 2, accuracy: 0.0001)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 2, accuracy: 0.0001)
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

    @MainActor
    func testSevenDayRangeUsesHourlyBucketsAcrossFullScrollableHistory() {
        let start = Date(timeIntervalSince1970: 1_800)
        let hourlyBins = (0..<(21 * 24)).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 60 * 60),
                tokens: index + 1,
                calls: 1
            )
        }

        let prepared = RecentUsageChart.prepare(
            range: .sevenDays,
            recentBins: [],
            hourlyBins: hourlyBins,
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(prepared.bucketInterval, 60 * 60)
        XCTAssertEqual(prepared.bins.count, 21 * 24)
        XCTAssertEqual(prepared.bins.first?.start, start)
        XCTAssertEqual(prepared.bins.last?.start, start.addingTimeInterval(Double(21 * 24 - 1) * 60 * 60))
        XCTAssertEqual(prepared.tokenTotal, hourlyBins.reduce(0) { $0 + $1.tokens })
    }

    @MainActor
    func testThirtyDayRangeUsesThreeHourBucketsAcrossFullScrollableHistory() {
        let start = Date(timeIntervalSince1970: 1_800)
        let hourlyBins = (0..<(45 * 24)).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 60 * 60),
                tokens: index + 1,
                calls: 1
            )
        }

        let prepared = RecentUsageChart.prepare(
            range: .thirtyDays,
            recentBins: [],
            hourlyBins: hourlyBins,
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(prepared.bucketInterval, 3 * 60 * 60)
        XCTAssertEqual(prepared.bins.count, 45 * 8)
        XCTAssertEqual(prepared.bins.first?.start, start)
        XCTAssertEqual(prepared.bins.last?.start, start.addingTimeInterval(Double(45 * 8 - 1) * 3 * 60 * 60))
        XCTAssertEqual(prepared.tokenTotal, hourlyBins.reduce(0) { $0 + $1.tokens })
    }

    func testScrollMetricsKeepSelectedWindowAtNormalWidthAndExpandHistory() {
        let start = Date(timeIntervalSince1970: 1_800)
        let twentyFourHours = (0..<288).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 5 * 60), tokens: 1, calls: 1)
        }
        let fortyEightHours = (0..<(2 * 288)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 5 * 60), tokens: 1, calls: 1)
        }
        let sevenDays = (0..<(7 * 24)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 60 * 60), tokens: 1, calls: 1)
        }
        let fourteenDays = (0..<(14 * 24)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 60 * 60), tokens: 1, calls: 1)
        }
        let thirtyDays = (0..<(30 * 8)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 3 * 60 * 60), tokens: 1, calls: 1)
        }
        let sixtyDays = (0..<(60 * 8)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 3 * 60 * 60), tokens: 1, calls: 1)
        }

        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .twentyFourHours,
                bins: twentyFourHours,
                bucketInterval: RecentChartRange.twentyFourHours.bucketInterval,
                viewportWidth: 900
            ),
            900,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .twentyFourHours,
                bins: fortyEightHours,
                bucketInterval: RecentChartRange.twentyFourHours.bucketInterval,
                viewportWidth: 900
            ),
            1_800,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .sevenDays,
                bins: sevenDays,
                bucketInterval: RecentChartRange.sevenDays.bucketInterval,
                viewportWidth: 900
            ),
            900,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .sevenDays,
                bins: fourteenDays,
                bucketInterval: RecentChartRange.sevenDays.bucketInterval,
                viewportWidth: 900
            ),
            1_800,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .thirtyDays,
                bins: thirtyDays,
                bucketInterval: RecentChartRange.thirtyDays.bucketInterval,
                viewportWidth: 900
            ),
            900,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.contentWidth(
                range: .thirtyDays,
                bins: sixtyDays,
                bucketInterval: RecentChartRange.thirtyDays.bucketInterval,
                viewportWidth: 900
            ),
            1_800,
            accuracy: 0.001
        )
    }

    func testScrollMetricsComputeButtonStepWindows() {
        let start = Date(timeIntervalSince1970: 1_800)
        let twentyFourHours = (0..<288).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 5 * 60), tokens: 1, calls: 1)
        }
        let fortyEightHours = (0..<(2 * 288)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 5 * 60), tokens: 1, calls: 1)
        }
        let fortyFiveDays = (0..<(45 * 8)).map { index in
            BinUsage(start: start.addingTimeInterval(Double(index) * 3 * 60 * 60), tokens: 1, calls: 1)
        }

        XCTAssertEqual(
            RecentChartScrollMetrics.windowCount(
                range: .twentyFourHours,
                bins: twentyFourHours,
                bucketInterval: RecentChartRange.twentyFourHours.bucketInterval
            ),
            1
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.windowCount(
                range: .twentyFourHours,
                bins: fortyEightHours,
                bucketInterval: RecentChartRange.twentyFourHours.bucketInterval
            ),
            2
        )
        XCTAssertEqual(
            RecentChartScrollMetrics.windowCount(
                range: .thirtyDays,
                bins: fortyFiveDays,
                bucketInterval: RecentChartRange.thirtyDays.bucketInterval
            ),
            2
        )
        XCTAssertEqual(RecentChartScrollMetrics.shiftedWindowIndex(current: 1, direction: .backward, windowCount: 3), 0)
        XCTAssertEqual(RecentChartScrollMetrics.shiftedWindowIndex(current: 1, direction: .forward, windowCount: 3), 2)
        XCTAssertEqual(RecentChartScrollMetrics.shiftedWindowIndex(current: 0, direction: .backward, windowCount: 3), 0)
        XCTAssertEqual(RecentChartScrollMetrics.shiftedWindowIndex(current: 2, direction: .forward, windowCount: 3), 2)
    }

    func testRecentUsageChartExposesHorizontalScrollingForLongHistory() throws {
        let source = try String(contentsOfFile: "Sources/CodexTokenBar/RecentUsageChart.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("ScrollView(.horizontal"))
        XCTAssertTrue(source.contains("RecentChartScrollMetrics.contentWidth"))
        XCTAssertTrue(source.contains("recent-chart-trailing-edge"))
        XCTAssertTrue(source.contains("RecentChartScrollButton"))
        XCTAssertTrue(source.contains("chevron.left"))
        XCTAssertTrue(source.contains("chevron.right"))
        XCTAssertTrue(source.contains("scrollChart(by:"))
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

        XCTAssertTrue(source.contains("@AppStorage(\"recentChartQuotaEstimateModel\")"))
        XCTAssertTrue(source.contains("consumptionSelectionState"))
        XCTAssertTrue(source.contains("quotaConsumptionSelection("))
        XCTAssertTrue(source.contains("onClick:"))
        XCTAssertTrue(source.contains("y: plot.minY - 58"))
        XCTAssertTrue(componentSource.contains("onClose:"))
        XCTAssertTrue(componentSource.contains("RecentChartQuotaEstimateModelSelector"))
        XCTAssertTrue(componentSource.contains("RecentChartQuotaEstimateOverlay"))
    }

    func testEstimateAffordancePresentationProvidesChartHelpAndModelOptions() {
        XCTAssertEqual(RecentChartQuotaEstimateAffordancePresentation.headerLabel, "点击图表估算额度")
        XCTAssertEqual(
            RecentChartQuotaEstimateAffordancePresentation.headerHelp,
            "第一下定起点，移动鼠标实时预览，第二下固定终点；再次点击重新选择。"
        )
        XCTAssertEqual(
            RecentChartQuotaEstimateAffordancePresentation.inlineInstruction,
            "第一下定起点，移动实时预览，第二下固定终点；第三下重新选择。"
        )
        XCTAssertEqual(RecentChartQuotaEstimateAffordancePresentation.hoverInstruction, "点击起点/终点可估算额度")
        XCTAssertEqual(RecentChartQuotaEstimateAffordancePresentation.hoverAccessibilityPrompt, "点击图表可估算额度")

        let option = RecentChartQuotaEstimateAffordancePresentation.modelOption(
            for: .gpt54Mini,
            selectedModel: .gpt55
        )

        XCTAssertEqual(option.groupLabel, "官方 API")
        XCTAssertEqual(option.shortTitle, "mini")
        XCTAssertEqual(option.accessibilityLabel, "官方 API 定价 GPT-5.4 mini")
        XCTAssertEqual(option.accessibilityValue, "未选择")
    }

    func testOverlayPresentationBuildsSummaryAndAccessibilityForMeasuredSelection() throws {
        let selection = selection(fiveHourBudget: 92, sevenDayBudget: 552)
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(selection: selection)
        let expectedRange = "\(DateFormatter.hourMinute.string(from: selection.startDate))-\(DateFormatter.hourMinute.string(from: selection.endDate))"

        XCTAssertEqual(presentation.costTitle, "本段消耗")
        XCTAssertEqual(presentation.costText, "$1.18")
        XCTAssertEqual(presentation.timeRangeText, expectedRange)
        XCTAssertEqual(presentation.cacheHitText, "命中 40%")
        XCTAssertEqual(presentation.estimateTitle, "反推总额度")
        XCTAssertEqual(presentation.fiveHourChip.title, "5h")
        XCTAssertEqual(presentation.fiveHourChip.detail, "$92.0 · 降 10%")
        XCTAssertEqual(presentation.sevenDayChip.title, "7d")
        XCTAssertEqual(presentation.sevenDayChip.detail, "$552 · 降 1.1%")
        XCTAssertEqual(presentation.ratioTitle, "倍率")
        XCTAssertEqual(presentation.budgetRatioText, "6.0x")
        XCTAssertEqual(presentation.ratioHelpText, "7d/5h，正常约 6x")
        XCTAssertFalse(presentation.showsRatioWarning)
        XCTAssertNil(presentation.ratioWarningText)
        XCTAssertEqual(presentation.closeAccessibilityLabel, "关闭额度估算")
        XCTAssertEqual(presentation.accessibilityLabel, "额度估算")
        XCTAssertEqual(
            presentation.accessibilityValue,
            "本段消耗 $1.18，5 小时 反推总额度 $92.0，下降 10%，7 天 反推总额度 $552，下降 1.1%，倍率 6.0x"
        )
    }

    func testOverlayPresentationShowsRatioWarningOnlyForDivergentSelection() {
        let divergent = QuotaConsumptionEstimatorOverlayPresentation(selection: selection(fiveHourBudget: 10, sevenDayBudget: 76))
        let normal = QuotaConsumptionEstimatorOverlayPresentation(selection: selection(fiveHourBudget: 10, sevenDayBudget: 60))

        XCTAssertTrue(divergent.showsRatioWarning)
        XCTAssertEqual(divergent.ratioWarningText, "偏离 6x，误差可能较大")
        XCTAssertEqual(divergent.ratioWarningDetailText, "可能因 7d 下降太少、颗粒度太低或其他误差。")
        XCTAssertFalse(normal.showsRatioWarning)
        XCTAssertNil(normal.ratioWarningText)
        XCTAssertNil(normal.ratioWarningDetailText)
    }

    func testEstimatePresentationExplainsUnavailableStates() {
        let insufficient = QuotaConsumptionEstimate(
            selectedCostUSD: 1,
            impliedWindowBudgetUSD: nil,
            quotaDropPercent: 0,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            calls: 1,
            cacheHitRate: 0,
            confidence: .insufficientQuotaMovement
        )
        let noToken = QuotaConsumptionEstimate(
            selectedCostUSD: 0,
            impliedWindowBudgetUSD: nil,
            quotaDropPercent: 0,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            calls: 0,
            cacheHitRate: 0,
            confidence: .noTokenUsage
        )

        XCTAssertEqual(QuotaConsumptionEstimatePresentation(title: "5h", estimate: insufficient).detail, "下降太小")
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "5h", estimate: insufficient).accessibilityText,
            "额度下降太小，不能反推"
        )
        XCTAssertEqual(QuotaConsumptionEstimatePresentation(title: "7d", estimate: noToken).detail, "无 token")
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: noToken).accessibilityText,
            "没有 token 用量"
        )
    }

    private func selection(fiveHourBudget: Double, sevenDayBudget: Double) -> QuotaConsumptionSelection {
        QuotaConsumptionSelection(
            startIndex: 0,
            endIndex: 1,
            bucketCount: 2,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 600),
            priceCard: .officialAPI(.gpt55),
            breakdown: TokenCacheBreakdown(
                inputTokens: 180_000,
                cachedInputTokens: 72_000,
                outputTokens: 20_000,
                reasoningOutputTokens: 0,
                totalTokens: 200_000,
                calls: 2
            ),
            fiveHour: QuotaConsumptionEstimate(
                selectedCostUSD: 1,
                impliedWindowBudgetUSD: fiveHourBudget,
                quotaDropPercent: 10,
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                calls: 0,
                cacheHitRate: 0,
                confidence: .measured
            ),
            sevenDay: QuotaConsumptionEstimate(
                selectedCostUSD: 1,
                impliedWindowBudgetUSD: sevenDayBudget,
                quotaDropPercent: 1.1,
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                calls: 0,
                cacheHitRate: 0,
                confidence: .measured
            )
        )
    }
}
