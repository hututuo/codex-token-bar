import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class QuotaConsumptionEstimatorTests: XCTestCase {
    func testQuotaSeriesVisibilityUsesCurrentOfficialWindowsInsteadOfHistoricalColumns() {
        let visibility = RecentChartQuotaSeriesVisibility(
            currentFiveHourPresent: false,
            currentSevenDayPresent: true,
            historyHasFiveHour: true,
            historyHasSevenDay: true
        )

        XCTAssertFalse(visibility.showsFiveHour)
        XCTAssertTrue(visibility.showsSevenDay)
        XCTAssertEqual(visibility.accessibilityLabels, ["7 天额度"])
    }

    func testQuotaEstimateVisibilityUsesHistoricalWindowsAfterOfficialWindowRemoval() {
        let visibility = RecentChartQuotaEstimateVisibility(
            historyHasFiveHour: true,
            historyHasSevenDay: true
        )

        XCTAssertTrue(visibility.showsFiveHour)
        XCTAssertTrue(visibility.showsSevenDay)
    }

    func testEstimatePresentationShowsMissingOfficialWindowInsteadOfSmallDrop() {
        let selection = selection(fiveHourBudget: 0, sevenDayBudget: 552)
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(
            selection: selection,
            showsFiveHourQuota: true,
            showsSevenDayQuota: true,
            currentFiveHourQuotaPresent: false,
            currentSevenDayQuotaPresent: true
        )

        XCTAssertEqual(presentation.fiveHourChip.detail, "无 5h 额度")
        XCTAssertEqual(presentation.fiveHourChip.accessibilityText, "当前无 5 小时额度")
        XCTAssertFalse(presentation.showsBudgetRatio)
        XCTAssertEqual(
            presentation.accessibilityValue,
            "选区 \(presentation.timeRangeText)，持续 10分钟，本段消耗 $1.18，5 小时 当前无 5 小时额度，7 天 反推总额度 $552，下降 1.1%"
        )
    }

    func testQuotaEstimateVisibilityAdaptsToSevenDayOnlyHistory() {
        let visibility = RecentChartQuotaEstimateVisibility(
            historyHasFiveHour: false,
            historyHasSevenDay: true
        )

        XCTAssertFalse(visibility.showsFiveHour)
        XCTAssertTrue(visibility.showsSevenDay)
    }

    @MainActor
    func testOptionalChartPathKeepsAnIsolatedObservedSampleVisible() {
        let chart = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        let path = chart.optionalLinePath(points: [CGPoint(x: 4, y: 6), nil])

        XCTAssertGreaterThan(path.boundingRect.width, 0)
    }

    @MainActor
    func testCacheHitPathBridgesUnknownBucketsWithoutInventingSamples() {
        let chart = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        let path = chart.bridgedOptionalLinePath(points: [
            CGPoint(x: 0, y: 20),
            nil,
            nil,
            CGPoint(x: 30, y: 10),
        ])
        var moveCount = 0
        path.forEach { element in
            if case .move = element {
                moveCount += 1
            }
        }

        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(path.boundingRect.maxX, 30, accuracy: 0.0001)
    }

    @MainActor
    func testRecentUsageChartEquatableBoundaryTracksEveryExternalInput() {
        let baseline = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: [],
            currentFiveHourQuotaPresent: true,
            currentSevenDayQuotaPresent: true
        )
        let identical = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: [],
            currentFiveHourQuotaPresent: true,
            currentSevenDayQuotaPresent: true
        )
        let changedUsage = RecentUsageChart(
            bins: [BinUsage(start: Date(timeIntervalSince1970: 1_800), tokens: 1, calls: 1)],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: [],
            currentFiveHourQuotaPresent: true,
            currentSevenDayQuotaPresent: true
        )
        let changedQuotaAvailability = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: [],
            currentFiveHourQuotaPresent: false,
            currentSevenDayQuotaPresent: true
        )
        let changedAttributionEvents = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            attributionEvents: [
                TokenCacheAttributionEvent(
                    id: "model-row",
                    start: Date(timeIntervalSince1970: 1_800),
                    model: "gpt-5.6-sol",
                    breakdown: .empty
                )
            ],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )
        let selectionForContext = attributionSelection(
            sevenDayDrop: 13,
            quotaDropObserved: true
        )
        let changedAttributionContext = RecentUsageChart(
            bins: [],
            hourlyBins: [],
            cacheRecentBins: [],
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: [],
            currentFiveHourQuotaPresent: true,
            currentSevenDayQuotaPresent: true,
            sharedAccountAttributionContext: attributionContext(
                for: selectionForContext,
                radarTotalUSD: 1_000
            )
        )

        XCTAssertEqual(baseline, identical)
        XCTAssertNotEqual(baseline, changedUsage)
        XCTAssertNotEqual(baseline, changedQuotaAvailability)
        XCTAssertNotEqual(baseline, changedAttributionEvents)
        XCTAssertNotEqual(baseline, changedAttributionContext)
    }

    @MainActor
    func testPreparedDataKeepsLowActivityCacheGapsUnknownInsteadOfCarryingStaleRates() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let bins = [
            BinUsage(start: start, tokens: 1, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 0, calls: 0),
            BinUsage(start: start.addingTimeInterval(600), tokens: 1, calls: 1),
        ]
        let cacheRecentBins = [
            TokenCacheBucket(
                start: bins[0].start,
                breakdown: TokenCacheBreakdown(inputTokens: 100, cachedInputTokens: 51, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 100, calls: 1)
            ),
            TokenCacheBucket(
                start: bins[2].start,
                breakdown: TokenCacheBreakdown(inputTokens: 100, cachedInputTokens: 91, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 100, calls: 1)
            ),
        ]

        let prepared = RecentUsageChart.prepare(
            range: .twentyFourHours,
            recentBins: bins,
            hourlyBins: [],
            cacheRecentBins: cacheRecentBins,
            cacheHourlyBins: [],
            quotaRecentBins: [],
            quotaHourlyBins: []
        )

        XCTAssertEqual(try XCTUnwrap(prepared.observedCacheHitRates[0]), 0.51, accuracy: 0.0001)
        XCTAssertNil(prepared.observedCacheHitRates[1])
        XCTAssertEqual(try XCTUnwrap(prepared.observedCacheHitRates[2]), 0.91, accuracy: 0.0001)
    }

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
        XCTAssertTrue(estimate.quotaDropObserved)
    }

    func testSelectionAttributionComputesAccountLocalAndPositiveNonLocalDifference() throws {
        let selection = attributionSelection(sevenDayDrop: 13, quotaDropObserved: true)
        let result = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(for: selection, radarTotalUSD: 1_000)
        )

        XCTAssertEqual(result.state, .suspectedNonLocalUsage)
        XCTAssertTrue(result.allowsAttributionConclusion)
        XCTAssertEqual(try XCTUnwrap(result.accountDropPercent), 13, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 100, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), 3, accuracy: 0.0001)

        let presentation = QuotaSelectionAttributionPresentation(result: result)
        XCTAssertEqual(presentation.accountText, "13%")
        XCTAssertEqual(presentation.localText, "≈10%")
        XCTAssertEqual(presentation.differenceTitle, "疑似他人")
        XCTAssertEqual(presentation.differenceText, "≈3%")
    }

    func testSelectionAttributionAutomaticallyPricesMixedModelsForCurrentAndRadarRevisions() throws {
        let start = Date(timeIntervalSince1970: 1_800)
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
        let events = [
            TokenCacheAttributionEvent(id: "sol", start: start, model: "gpt-5.6-sol", breakdown: sol),
            TokenCacheAttributionEvent(id: "terra", start: start.addingTimeInterval(300), model: "gpt-5.6-terra", breakdown: terra),
        ]
        let selection = attributionSelection(
            sevenDayDrop: 10,
            quotaDropObserved: true,
            fallbackModel: .gpt56Luna,
            sevenDayComparisonBreakdown: [sol, terra].combined,
            sevenDayAttributionEvents: events
        )
        let result = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(
                for: selection,
                radarTotalUSD: 100,
                priceRevision: .radar20260730
            )
        )

        XCTAssertEqual(result.localCurrentOfficialCostUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 7.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 7.5, accuracy: 0.0001)
        XCTAssertEqual(result.detectedModels, [.gpt56Sol, .gpt56Terra])
        XCTAssertEqual(result.fallbackModelCalls, 0)
        XCTAssertEqual(result.pricingModelText, "自动 · Sol/Terra")
    }

    func testSelectionAttributionPreservesNegativeDifference() throws {
        let selection = attributionSelection(sevenDayDrop: 5, quotaDropObserved: true)
        let result = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(for: selection, radarTotalUSD: 1_000)
        )

        XCTAssertEqual(result.state, .localEstimateExceedsAccountDrop)
        XCTAssertTrue(result.allowsAttributionConclusion)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), -5, accuracy: 0.0001)
        XCTAssertEqual(
            QuotaSelectionAttributionPresentation(result: result).differenceText,
            "5%"
        )
    }

    func testFlatZeroQuotaMovementIsObservedAndDistinctFromMissingHistory() throws {
        let flatSelection = attributionSelection(sevenDayDrop: 0, quotaDropObserved: true)
        let flatResult = QuotaSelectionAttributionEstimator.estimate(
            selection: flatSelection,
            context: attributionContext(for: flatSelection, radarTotalUSD: 1_000)
        )
        XCTAssertEqual(flatResult.state, .localEstimateExceedsAccountDrop)
        XCTAssertEqual(try XCTUnwrap(flatResult.accountDropPercent), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(flatResult.nonLocalDifferencePercent), -10, accuracy: 0.0001)

        let missingSelection = attributionSelection(sevenDayDrop: 0, quotaDropObserved: false)
        let missingResult = QuotaSelectionAttributionEstimator.estimate(
            selection: missingSelection,
            context: attributionContext(for: missingSelection, radarTotalUSD: 1_000)
        )
        XCTAssertEqual(missingResult.state, .missingQuotaHistory)
        XCTAssertNil(missingResult.accountDropPercent)
        XCTAssertNil(missingResult.nonLocalDifferencePercent)
    }

    func testSelectionAttributionFailsClosedForMissingRadarAndUnknownPriceRevision() {
        let selection = attributionSelection(sevenDayDrop: 13, quotaDropObserved: true)
        let missingRadar = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(for: selection, radarTotalUSD: nil)
        )
        XCTAssertEqual(missingRadar.state, .missingRadarTierBaseline)
        XCTAssertEqual(missingRadar.accountDropPercent, 13)
        XCTAssertNil(missingRadar.localSharePercent)

        let estimatedSelection = attributionSelection(
            sevenDayDrop: 13,
            quotaDropObserved: false,
            quotaDropBasis: .estimated
        )
        let estimatedMissingRadar = QuotaSelectionAttributionEstimator.estimate(
            selection: estimatedSelection,
            context: attributionContext(for: estimatedSelection, radarTotalUSD: nil)
        )
        XCTAssertTrue(
            QuotaSelectionAttributionPresentation(result: estimatedMissingRadar)
                .differenceFormula.contains("账号暂算下降")
        )

        let unknownPrice = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(
                for: selection,
                radarTotalUSD: 1_000,
                priceRevision: .unavailable
            )
        )
        XCTAssertEqual(unknownPrice.state, .missingCompatiblePriceRevision)
        XCTAssertNil(unknownPrice.localSharePercent)
        XCTAssertNil(unknownPrice.nonLocalDifferencePercent)
    }

    func testUnsafeSelectionContextsRemainProvisionalInsteadOfAccusingOtherUsers() {
        let selection = attributionSelection(sevenDayDrop: 13, quotaDropObserved: true)
        let stale = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(
                for: selection,
                radarTotalUSD: 1_000,
                quotaDataStale: true
            )
        )
        XCTAssertEqual(stale.state, .provisional)
        XCTAssertFalse(stale.allowsAttributionConclusion)
        XCTAssertEqual(stale.nonLocalDifferencePercent, 3)
        XCTAssertTrue(stale.caveats.contains { $0.contains("旧数据") })

        let highWatermark = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(
                for: selection,
                radarTotalUSD: 1_000,
                usedHighWatermark: true
            )
        )
        XCTAssertEqual(highWatermark.state, .provisional)
        XCTAssertTrue(highWatermark.caveats.contains { $0.contains("高水位") })

        let outsideSegment = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(
                for: selection,
                radarTotalUSD: 1_000,
                segmentStart: selection.startDate.addingTimeInterval(60)
            )
        )
        XCTAssertEqual(outsideSegment.state, .provisional)
        XCTAssertTrue(outsideSegment.caveats.contains { $0.contains("安全基线") })
        XCTAssertEqual(
            QuotaSelectionAttributionPresentation(result: outsideSegment).differenceTitle,
            "暂算差额"
        )

        let partialBuckets = attributionSelection(
            sevenDayDrop: 13,
            quotaDropObserved: true,
            comparisonUsesConservativeBuckets: true
        )
        let conservative = QuotaSelectionAttributionEstimator.estimate(
            selection: partialBuckets,
            context: attributionContext(for: partialBuckets, radarTotalUSD: 1_000)
        )
        XCTAssertEqual(conservative.state, .provisional)
        XCTAssertTrue(conservative.caveats.contains { $0.contains("首尾整桶") })
    }

    func testEstimatedQuotaDropStaysProvisionalAndUsesOnlyObservationCoveredTokens() throws {
        let comparisonBreakdown = TokenCacheBreakdown(
            inputTokens: 10_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 10_000_000,
            calls: 1
        )
        let selection = attributionSelection(
            sevenDayDrop: 13,
            quotaDropObserved: false,
            quotaDropBasis: .estimated,
            sevenDayComparisonBreakdown: comparisonBreakdown
        )
        let result = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: attributionContext(for: selection, radarTotalUSD: 1_000)
        )

        XCTAssertEqual(result.state, .provisional)
        XCTAssertFalse(result.allowsAttributionConclusion)
        XCTAssertEqual(try XCTUnwrap(result.accountDropPercent), 13, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), 8, accuracy: 0.0001)
        XCTAssertTrue(result.caveats.contains { $0.contains("暂算") })
        let presentation = QuotaSelectionAttributionPresentation(result: result)
        XCTAssertEqual(presentation.accountTitle, "账号暂降")
        XCTAssertEqual(presentation.accountText, "≈13%")
        XCTAssertEqual(presentation.differenceTitle, "暂算差额")
        XCTAssertTrue(presentation.differenceFormula.contains("账号暂算下降"))
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
            observedCacheHitRates: [0.2, 0.4, 0.4],
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

    func testPreparedSelectionUsesRecordedModelsInsteadOfTheFallbackPicker() throws {
        let start = Date(timeIntervalSince1970: 1_800)
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
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: [
                BinUsage(start: start, tokens: 1_000_000, calls: 1),
                BinUsage(start: start.addingTimeInterval(300), tokens: 1_000_000, calls: 1),
            ],
            bucketInterval: 300,
            maxTokens: 1_000_000,
            maxCalls: 1,
            tokenTotal: 2_000_000,
            callTotal: 2,
            recentCacheBreakdown: [sol, terra].combined,
            cacheBreakdowns: [sol, terra],
            observedCacheHitRates: [0, 0],
            fiveHourRemainingPercents: [80, 70],
            sevenDayRemainingPercents: [90, 80],
            latestFiveHourRemaining: 70,
            latestSevenDayRemaining: 80,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: [0, 1]
        )
        let events = [
            TokenCacheAttributionEvent(id: "sol", start: start, model: "gpt-5.6-sol", breakdown: sol),
            TokenCacheAttributionEvent(id: "terra", start: start.addingTimeInterval(300), model: "gpt-5.6-terra", breakdown: terra),
        ]

        let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(
            startIndex: 0,
            endIndex: 1,
            priceCard: .officialAPI(.gpt56Luna),
            attributionEvents: events
        ))

        XCTAssertEqual(selection.fullCurrentAPIPriceEstimate.costUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(selection.fiveHour.selectedCostUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(selection.sevenDay.selectedCostUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(selection.fullCurrentAPIPriceEstimate.detectedModels, [.gpt56Sol, .gpt56Terra])
    }

    func testFlatZeroQuotaRangeStillBuildsSelectionSummary() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let bins = [
            BinUsage(start: start, tokens: 10, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 20, calls: 1)
        ]
        let cache = Array(repeating: TokenCacheBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 50_000,
            outputTokens: 20_000,
            reasoningOutputTokens: 0,
            totalTokens: 120_000,
            calls: 1
        ), count: 2)
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: bins,
            bucketInterval: 300,
            maxTokens: 20,
            maxCalls: 1,
            tokenTotal: 30,
            callTotal: 2,
            recentCacheBreakdown: cache.combined,
            cacheBreakdowns: cache,
            observedCacheHitRates: [0.5, 0.5],
            fiveHourRemainingPercents: [0, 0],
            sevenDayRemainingPercents: [0, 0],
            latestFiveHourRemaining: 0,
            latestSevenDayRemaining: 0,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: [0, 1]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 1,
                priceCard: .officialAPI(.gpt55)
            )
        )
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(selection: selection)

        XCTAssertEqual(selection.bucketCount, 2)
        XCTAssertEqual(selection.endDate.timeIntervalSince(selection.startDate), 600, accuracy: 0.0001)
        XCTAssertEqual(selection.fiveHour.quotaDropPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(selection.fiveHour.confidence, .insufficientQuotaMovement)
        XCTAssertEqual(selection.sevenDay.confidence, .insufficientQuotaMovement)
        XCTAssertEqual(presentation.durationText, "持续 10分钟")
        XCTAssertEqual(presentation.fiveHourChip.detail, "暂算降 0% · 不反推")
        XCTAssertTrue(presentation.accessibilityValue.contains("持续 10分钟"))
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
            observedCacheHitRates: [0, 0, 0, 0],
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
            observedCacheHitRates: [0, 0, 0, 0],
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
                observedCacheHitRates: [0.2, 0.2, 0.2],
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

    func testChartEdgeFadeStateOnlyShowsAvailableHistoryDirections() {
        XCTAssertEqual(
            RecentChartEdgeFadeState(currentWindowIndex: 0, windowCount: 1),
            RecentChartEdgeFadeState(showsLeft: false, showsRight: false)
        )
        XCTAssertEqual(
            RecentChartEdgeFadeState(currentWindowIndex: 1, windowCount: 3),
            RecentChartEdgeFadeState(showsLeft: true, showsRight: true)
        )
        XCTAssertEqual(
            RecentChartEdgeFadeState(currentWindowIndex: 2, windowCount: 3),
            RecentChartEdgeFadeState(showsLeft: true, showsRight: false)
        )
        XCTAssertEqual(
            RecentChartEdgeFadeState(currentWindowIndex: 0, windowCount: 3),
            RecentChartEdgeFadeState(showsLeft: false, showsRight: true)
        )
    }

    func testAutoScrollOnlyFollowsAChangedTimelineFromTheLatestWindow() {
        let start = Date(timeIntervalSince1970: 1_800)
        let original = [
            BinUsage(start: start, tokens: 10, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 20, calls: 2),
        ]
        let valueOnlyUpdate = [
            BinUsage(start: start, tokens: 10, calls: 1),
            BinUsage(start: start.addingTimeInterval(300), tokens: 50, calls: 3),
        ]
        let newBucket = valueOnlyUpdate + [
            BinUsage(start: start.addingTimeInterval(600), tokens: 1, calls: 1),
        ]

        XCTAssertFalse(
            RecentChartAutoScrollPolicy.shouldFollowLatest(
                previousBins: original,
                updatedBins: valueOnlyUpdate,
                wasAtLatest: true
            ),
            "Token updates inside the current bucket must not start a new scroll animation"
        )
        XCTAssertTrue(
            RecentChartAutoScrollPolicy.shouldFollowLatest(
                previousBins: valueOnlyUpdate,
                updatedBins: newBucket,
                wasAtLatest: true
            )
        )
        XCTAssertFalse(
            RecentChartAutoScrollPolicy.shouldFollowLatest(
                previousBins: valueOnlyUpdate,
                updatedBins: newBucket,
                wasAtLatest: false
            ),
            "Live updates must not pull a user away from an older history window"
        )
        XCTAssertTrue(
            RecentChartAutoScrollPolicy.shouldFollowLatest(
                previousBins: [],
                updatedBins: original,
                wasAtLatest: nil
            )
        )
    }

    func testScrollPresentationClampsOffsetsAndPreservesPartialEndpointMovement() {
        struct Case {
            let offset: CGFloat
            let viewport: CGFloat
            let content: CGFloat
            let windows: Int
            let expectedOffset: CGFloat
            let expectedIndex: Int
            let atOldest: Bool
            let atLatest: Bool
            let backwardTarget: Int
            let forwardTarget: Int
        }

        let cases = [
            Case(offset: 0, viewport: 100, content: 300, windows: 3, expectedOffset: 0, expectedIndex: 0, atOldest: true, atLatest: false, backwardTarget: 0, forwardTarget: 1),
            Case(offset: -30, viewport: 100, content: 300, windows: 3, expectedOffset: 0, expectedIndex: 0, atOldest: true, atLatest: false, backwardTarget: 0, forwardTarget: 1),
            Case(offset: 0.3, viewport: 100, content: 300, windows: 3, expectedOffset: 0.3, expectedIndex: 0, atOldest: false, atLatest: false, backwardTarget: 0, forwardTarget: 1),
            Case(offset: 100, viewport: 100, content: 300, windows: 3, expectedOffset: 100, expectedIndex: 1, atOldest: false, atLatest: false, backwardTarget: 0, forwardTarget: 2),
            Case(offset: 100.4, viewport: 100, content: 300, windows: 3, expectedOffset: 100.4, expectedIndex: 1, atOldest: false, atLatest: false, backwardTarget: 0, forwardTarget: 2),
            Case(offset: 199.7, viewport: 100, content: 300, windows: 3, expectedOffset: 199.7, expectedIndex: 1, atOldest: false, atLatest: false, backwardTarget: 0, forwardTarget: 2),
            Case(offset: 199.8, viewport: 100, content: 300, windows: 3, expectedOffset: 199.8, expectedIndex: 2, atOldest: false, atLatest: true, backwardTarget: 1, forwardTarget: 2),
            Case(offset: 250, viewport: 100, content: 300, windows: 3, expectedOffset: 200, expectedIndex: 2, atOldest: false, atLatest: true, backwardTarget: 1, forwardTarget: 2),
            Case(offset: 8, viewport: 0, content: 0, windows: 0, expectedOffset: 0, expectedIndex: 0, atOldest: true, atLatest: true, backwardTarget: 0, forwardTarget: 0)
        ]

        for item in cases {
            let state = RecentChartScrollPresentation(
                contentOffset: item.offset,
                viewportWidth: item.viewport,
                contentWidth: item.content,
                windowCount: item.windows
            )
            XCTAssertEqual(state.contentOffset, item.expectedOffset, accuracy: 0.0001)
            XCTAssertEqual(state.currentWindowIndex, item.expectedIndex)
            XCTAssertEqual(state.isAtOldest, item.atOldest)
            XCTAssertEqual(state.isAtLatest, item.atLatest)
            XCTAssertEqual(state.targetWindowIndex(for: .backward), item.backwardTarget)
            XCTAssertEqual(state.targetWindowIndex(for: .forward), item.forwardTarget)
        }

        let movedLeftFromLatest = RecentChartScrollPresentation(
            contentOffset: 199.7,
            viewportWidth: 100,
            contentWidth: 300,
            windowCount: 3
        )
        XCTAssertEqual(movedLeftFromLatest.edgeFadeState, .init(showsLeft: true, showsRight: true))
        XCTAssertEqual(movedLeftFromLatest.targetWindowIndex(for: .forward), 2)

        let movedRightFromOldest = RecentChartScrollPresentation(
            contentOffset: 0.3,
            viewportWidth: 100,
            contentWidth: 300,
            windowCount: 3
        )
        XCTAssertEqual(movedRightFromOldest.edgeFadeState, .init(showsLeft: true, showsRight: true))
        XCTAssertEqual(movedRightFromOldest.targetWindowIndex(for: .backward), 0)
    }

    func testChartNavigationAccessibilityPresentationsAreDistinctAndStateful() {
        let presentations = RecentChartRange.allCases.map { range in
            RecentChartRangeOptionPresentation(range: range, isSelected: range == .sevenDays)
        }

        XCTAssertEqual(presentations.map(\.visibleTitle), ["24h", "7d", "30d"])
        XCTAssertEqual(
            presentations.map(\.accessibilityLabel),
            ["曲线范围 24 小时窗口", "曲线范围 7 天窗口", "曲线范围 30 天窗口"]
        )
        XCTAssertEqual(presentations.map(\.accessibilityValue), ["未选择", "已选择", "未选择"])
        XCTAssertEqual(RecentChartScrollDirection.backward.accessibilityLabel, "上一时间窗口")
        XCTAssertEqual(RecentChartScrollDirection.forward.accessibilityLabel, "下一时间窗口")
    }

    @MainActor
    func testNativeChartNavigationAccessibilityRepresentationsExposeSemanticAX() {
        let selectedRange = RecentChartRangeOptionPresentation(
            range: .sevenDays,
            isSelected: true
        ).accessibilityButton
        let rangeButton = RecentChartAccessibilityButtonRepresentation.makeButton(
            presentation: selectedRange
        )
        XCTAssertEqual(rangeButton.accessibilityLabel(), "曲线范围 7 天窗口")
        XCTAssertEqual(rangeButton.accessibilityValue() as? String, "已选择")
        XCTAssertTrue(rangeButton.isEnabled)

        let backwardButton = RecentChartAccessibilityButtonRepresentation.makeButton(
            presentation: RecentChartScrollDirection.backward.accessibilityButton(isEnabled: true)
        )
        let forwardButton = RecentChartAccessibilityButtonRepresentation.makeButton(
            presentation: RecentChartScrollDirection.forward.accessibilityButton(isEnabled: false)
        )
        XCTAssertEqual(backwardButton.accessibilityLabel(), "上一时间窗口")
        XCTAssertEqual(forwardButton.accessibilityLabel(), "下一时间窗口")
        XCTAssertNotEqual(backwardButton.accessibilityLabel(), "chevron.left")
        XCTAssertNotEqual(forwardButton.accessibilityLabel(), "chevron.right")
        XCTAssertTrue(backwardButton.isEnabled)
        XCTAssertFalse(forwardButton.isEnabled)
    }

    @MainActor
    func testHostedScrollOffsetReaderTracksBridgeUpdatesAndDetachesCleanly() throws {
        var callbacks: [HostedScrollCallback] = []
        let hostingView = NSHostingView(
            rootView: HostedRecentChartScrollReaderHarness(
                viewportWidth: 100,
                contentWidth: 300,
                revision: 1,
                isReaderEnabled: true,
                onOffsetChange: { callbacks.append($0) }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()

        let scrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        XCTAssertTrue(scrollView.contentView.postsBoundsChangedNotifications)

        callbacks.removeAll()
        var gestureBounds = scrollView.contentView.bounds
        gestureBounds.origin.x = 36.5
        scrollView.contentView.bounds = gestureBounds
        XCTAssertEqual(
            callbacks.last?.offset ?? -1,
            scrollView.contentView.bounds.origin.x,
            accuracy: 0.0001
        )
        XCTAssertEqual(callbacks.last?.viewportWidth, 100)
        XCTAssertEqual(callbacks.last?.contentWidth, 300)
        XCTAssertEqual(callbacks.last?.revision, 1)

        hostingView.rootView = HostedRecentChartScrollReaderHarness(
            viewportWidth: 120,
            contentWidth: 420,
            revision: 2,
            isReaderEnabled: true,
            onOffsetChange: { callbacks.append($0) }
        )
        hostingView.frame.size.width = 120
        window.setContentSize(NSSize(width: 120, height: 40))
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()

        let resizedScrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        XCTAssertTrue(resizedScrollView === scrollView)
        callbacks.removeAll()
        resizedScrollView.contentView.scroll(to: NSPoint(x: 84.25, y: 0))
        resizedScrollView.reflectScrolledClipView(resizedScrollView.contentView)
        XCTAssertEqual(callbacks.last?.offset ?? -1, 84.25, accuracy: 0.0001)
        XCTAssertEqual(callbacks.last?.viewportWidth, 120)
        XCTAssertEqual(callbacks.last?.contentWidth, 420)
        XCTAssertEqual(callbacks.last?.revision, 2)

        callbacks.removeAll()
        hostingView.rootView = HostedRecentChartScrollReaderHarness(
            viewportWidth: 120,
            contentWidth: 420,
            revision: 3,
            isReaderEnabled: true,
            onOffsetChange: { callbacks.append($0) }
        )
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()
        let revisionThreeScrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        XCTAssertTrue(revisionThreeScrollView === resizedScrollView)
        XCTAssertTrue(callbacks.isEmpty, "Re-evaluating the same scroll view must not feed state back into SwiftUI")
        callbacks.removeAll()
        revisionThreeScrollView.contentView.scroll(to: NSPoint(x: 91.5, y: 0))
        revisionThreeScrollView.reflectScrolledClipView(revisionThreeScrollView.contentView)
        XCTAssertEqual(callbacks.filter { abs($0.offset - 91.5) < 0.0001 }.count, 1)
        XCTAssertEqual(callbacks.last?.revision, 3)

        hostingView.rootView = HostedRecentChartScrollReaderHarness(
            viewportWidth: 120,
            contentWidth: 420,
            revision: 4,
            isReaderEnabled: false,
            onOffsetChange: { callbacks.append($0) }
        )
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()
        let activeScrollViewWithoutReader = try XCTUnwrap(firstScrollView(in: hostingView))
        XCTAssertTrue(activeScrollViewWithoutReader === resizedScrollView)
        callbacks.removeAll()
        activeScrollViewWithoutReader.contentView.scroll(to: NSPoint(x: 110, y: 0))
        activeScrollViewWithoutReader.reflectScrolledClipView(activeScrollViewWithoutReader.contentView)
        XCTAssertTrue(callbacks.isEmpty)
    }

    @MainActor
    func testHostedChartInteractionLayerReceivesRealClicksBeforeAndAfterScrolling() throws {
        var clickLocations: [CGPoint] = []
        var selectionState = RecentChartConsumptionSelectionState()
        let hostingView = NSHostingView(
            rootView: HostedRecentChartClickHarness { location in
                clickLocations.append(location)
                let index = min(max(Int(location.x / 60), 0), 9)
                selectionState.click(index: index, validCount: 10)
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 70)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        runMainLoopBriefly()

        let trackingView = try XCTUnwrap(firstChartTrackingView(in: hostingView))
        try clickHostedChartTrackingView(trackingView, window: window, localX: 65)
        try clickHostedChartTrackingView(trackingView, window: window, localX: 245)
        runMainLoopBriefly()

        XCTAssertEqual(clickLocations.count, 2)
        XCTAssertEqual(selectionState.startIndex, 1)
        XCTAssertEqual(selectionState.fixedEndIndex, 4)

        let scrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try clickHostedChartTrackingView(trackingView, window: window, localX: 185)
        runMainLoopBriefly()

        XCTAssertEqual(clickLocations.count, 3)
        XCTAssertEqual(selectionState.startIndex, 3)
        XCTAssertNil(selectionState.fixedEndIndex)
    }

    func testTimeMarkerLabelsUseDatesForScrollableRanges() {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 13, minute: 45))!

        XCTAssertEqual(ChartTimeMarkerLabel.text(for: date, range: .twentyFourHours), "7月6日")
        XCTAssertEqual(ChartTimeMarkerLabel.text(for: date, range: .sevenDays), "7月6日")
        XCTAssertEqual(ChartTimeMarkerLabel.text(for: date, range: .thirtyDays), "7月6日")
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

        XCTAssertTrue(source.contains("@AppStorage(SharedAccountUsageAttributionSettings.priceModelKey)"))
        XCTAssertTrue(source.contains("consumptionSelectionState"))
        XCTAssertTrue(source.contains("quotaConsumptionSelection("))
        XCTAssertTrue(source.contains("onClick:"))
        XCTAssertTrue(source.contains(".accessibilityAdjustableAction"))
        XCTAssertTrue(source.contains(".accessibilityAction(named: Text(\"设置选区点\"))"))
        XCTAssertTrue(source.contains(".onMoveCommand"))
        XCTAssertTrue(source.contains(".onKeyPress(.space)"))
        XCTAssertTrue(componentSource.contains("onClose:"))
        XCTAssertFalse(componentSource.contains("RecentChartQuotaEstimateModelSelector"))
        XCTAssertTrue(componentSource.contains("RecentChartQuotaEstimateOverlay"))
    }

    func testEstimateSummaryLivesBelowPlotInsteadOfInsideTheHitLayer() throws {
        let source = try String(contentsOfFile: "Sources/CodexTokenBar/RecentUsageChart.swift", encoding: .utf8)
        let chartStart = try XCTUnwrap(source.range(of: "private func chartPlot(")).lowerBound
        let canvasStart = try XCTUnwrap(source.range(of: "private func chartPlotCanvas")).lowerBound
        let summaryStart = try XCTUnwrap(
            source.range(of: "private func consumptionSelectionSummary(")
        ).lowerBound
        let bodyStart = try XCTUnwrap(
            source.range(of: "var body: some View", range: summaryStart..<source.endIndex)
        ).lowerBound
        let accessibilityStart = try XCTUnwrap(
            source.range(of: "private var accessibilitySummary", range: bodyStart..<source.endIndex)
        ).lowerBound
        let plotSource = source[chartStart..<canvasStart]
        let bodySource = source[bodyStart..<accessibilityStart]

        XCTAssertTrue(
            bodySource.contains(
                "chartPlot(consumptionSelection: consumptionSelection)\n            consumptionSelectionSummary("
            )
        )
        XCTAssertFalse(plotSource.contains("RecentChartQuotaEstimateOverlay"))
        XCTAssertFalse(source.contains(".position(x: 205, y: -40)"))
    }

    func testComparisonCoveragePresentationKeepsObservedAndEstimatedProvenanceDistinct() {
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(basis: .observed).sectionTitle,
            "7d 观测覆盖内归因统计"
        )
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(
                basis: .observed,
                usesConservativeBuckets: true
            ).sectionTitle,
            "7d 保守整桶归因统计"
        )
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(
                basis: .observed,
                usesConservativeBuckets: true
            ).sourceTitle,
            "保守整桶计入范围"
        )
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(basis: .estimated).sectionTitle,
            "7d 暂算覆盖内归因统计"
        )
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(basis: .estimated).sourceTitle,
            "额度暂算覆盖"
        )
        XCTAssertEqual(
            QuotaConsumptionComparisonCoveragePresentation(basis: .unavailable).sourceTitle,
            "额度可比范围"
        )
    }

    func testEstimateAffordancePresentationProvidesChartHelpWithoutManualModelOptions() {
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

        let estimate = ModelAwareAPIPriceEstimate(
            costUSD: 7,
            detectedModels: [.gpt56Sol, .gpt56Terra],
            fallbackCalls: 0
        )
        XCTAssertEqual(
            estimate.pricingModelText(fallbackModel: .gpt56Luna),
            "自动 · Sol/Terra"
        )
    }

    func testOverlayPresentationBuildsSummaryAndAccessibilityForMeasuredSelection() throws {
        let selection = selection(fiveHourBudget: 92, sevenDayBudget: 552)
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(selection: selection)
        let expectedRange = "\(DateFormatter.hourMinute.string(from: selection.startDate))-\(DateFormatter.hourMinute.string(from: selection.endDate))"

        XCTAssertEqual(presentation.costTitle, "本段消耗")
        XCTAssertEqual(presentation.costText, "$1.18")
        XCTAssertEqual(presentation.timeRangeText, expectedRange)
        XCTAssertEqual(presentation.durationText, "持续 10分钟")
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
            "选区 \(expectedRange)，持续 10分钟，本段消耗 $1.18，5 小时 反推总额度 $92.0，下降 10%，7 天 反推总额度 $552，下降 1.1%，倍率 6.0x"
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
        let missingQuotaSamples = QuotaConsumptionEstimate(
            selectedCostUSD: 1,
            impliedWindowBudgetUSD: nil,
            quotaDropPercent: 0,
            quotaDropObserved: false,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            calls: 1,
            cacheHitRate: 0,
            confidence: .insufficientQuotaMovement
        )
        let estimatedQuotaDrop = QuotaConsumptionEstimate(
            selectedCostUSD: 1,
            impliedWindowBudgetUSD: 20,
            quotaDropPercent: 5,
            quotaDropBasis: .estimated,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            calls: 1,
            cacheHitRate: 0,
            confidence: .measured
        )
        let conservativeBoundary = QuotaConsumptionEstimate(
            selectedCostUSD: 1,
            impliedWindowBudgetUSD: 20,
            quotaDropPercent: 5,
            quotaDropBasis: .observed,
            comparisonUsesConservativeBuckets: true,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            calls: 1,
            cacheHitRate: 0,
            confidence: .measured
        )

        XCTAssertEqual(QuotaConsumptionEstimatePresentation(title: "5h", estimate: insufficient).detail, "降 0% · 不反推")
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "5h", estimate: insufficient).accessibilityText,
            "额度下降 0%，不能反推总额度"
        )
        XCTAssertEqual(QuotaConsumptionEstimatePresentation(title: "7d", estimate: noToken).detail, "无 token")
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: noToken).accessibilityText,
            "没有 token 用量"
        )
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: missingQuotaSamples).detail,
            "7d 样本不足"
        )
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: missingQuotaSamples).accessibilityText,
            "选区内缺少足够的 7 天额度样本"
        )
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: estimatedQuotaDrop).detail,
            "≈$20.0 · 暂算降 5%"
        )
        XCTAssertTrue(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: estimatedQuotaDrop)
                .accessibilityText.contains("暂算")
        )
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: conservativeBoundary).detail,
            "≈$20.0 · 边界暂算降 5%"
        )
        XCTAssertTrue(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: conservativeBoundary)
                .accessibilityText.contains("首尾整桶保守计入")
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

    private func attributionSelection(
        sevenDayDrop: Double,
        quotaDropObserved: Bool,
        quotaDropBasis: QuotaConsumptionDropBasis? = nil,
        fallbackModel: OfficialAPIPriceModel = .gpt56Sol,
        sevenDayComparisonBreakdown: TokenCacheBreakdown? = nil,
        comparisonUsesConservativeBuckets: Bool = false,
        sevenDayAttributionEvents: [TokenCacheAttributionEvent] = []
    ) -> QuotaConsumptionSelection {
        let start = Date(timeIntervalSince1970: 1_800)
        let end = start.addingTimeInterval(600)
        let breakdown = TokenCacheBreakdown(
            inputTokens: 20_000_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 20_000_000,
            calls: 2
        )
        return QuotaConsumptionSelection(
            startIndex: 0,
            endIndex: 1,
            bucketCount: 2,
            startDate: start,
            endDate: end,
            priceCard: .officialAPI(fallbackModel),
            breakdown: breakdown,
            fiveHour: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: 20,
                priceCard: .officialAPI(fallbackModel)
            ),
            sevenDay: QuotaConsumptionEstimate(
                selectedCostUSD: 100,
                impliedWindowBudgetUSD: sevenDayDrop > 0
                    ? 100 / (sevenDayDrop / 100)
                    : nil,
                quotaDropPercent: sevenDayDrop,
                quotaDropObserved: quotaDropObserved,
                quotaDropBasis: quotaDropBasis,
                comparisonBreakdown: sevenDayComparisonBreakdown,
                comparisonUsesConservativeBuckets: comparisonUsesConservativeBuckets,
                inputTokens: breakdown.inputTokens,
                cachedInputTokens: breakdown.cachedInputTokens,
                outputTokens: breakdown.outputTokens,
                calls: breakdown.calls,
                cacheHitRate: breakdown.cacheHitRate,
                confidence: sevenDayDrop > 0
                    ? .measured
                    : .insufficientQuotaMovement
            ),
            sevenDayAttributionEvents: sevenDayAttributionEvents
        )
    }

    private func attributionContext(
        for selection: QuotaConsumptionSelection,
        radarTotalUSD: Double?,
        priceRevision: SharedAccountRadarPriceRevision = .currentOfficial,
        quotaDataStale: Bool = false,
        usedHighWatermark: Bool = false,
        segmentStart: Date? = nil
    ) -> QuotaSelectionAttributionContext {
        QuotaSelectionAttributionContext(
            sourceState: .suspectedNonLocalUsage,
            tier: .twentyXPro,
            model: .gpt56Sol,
            priceRevision: priceRevision,
            cycleStart: selection.startDate.addingTimeInterval(-60 * 60),
            cycleEnd: selection.endDate.addingTimeInterval(60 * 60),
            localSegmentStart: segmentStart ?? selection.startDate.addingTimeInterval(-60),
            quotaUpdatedAt: selection.endDate.addingTimeInterval(5 * 60),
            radarSevenDayTotalUSD: radarTotalUSD,
            radarBasis: "API-equivalent",
            radarDate: "2026-07-31",
            radarPricingBasisDate: "2026-07-31",
            radarUpdatedAt: "2026-07-31T12:00:00Z",
            radarSource: "Codex Radar",
            quotaDataStale: quotaDataStale,
            radarDataStale: false,
            usagePendingQuotaRefresh: false,
            localHistoryAmbiguous: false,
            usedHighWatermark: usedHighWatermark,
            hasFinalAttributionConclusion: true
        )
    }
}

private struct HostedScrollCallback {
    let offset: CGFloat
    let viewportWidth: CGFloat
    let contentWidth: CGFloat
    let revision: Int
}

private struct HostedRecentChartScrollReaderHarness: View {
    let viewportWidth: CGFloat
    let contentWidth: CGFloat
    let revision: Int
    let isReaderEnabled: Bool
    let onOffsetChange: (HostedScrollCallback) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: contentWidth, height: 40)

                if isReaderEnabled {
                    RecentChartScrollOffsetReader { offset in
                        onOffsetChange(
                            HostedScrollCallback(
                                offset: offset,
                                viewportWidth: viewportWidth,
                                contentWidth: contentWidth,
                                revision: revision
                            )
                        )
                    }
                    .frame(width: 1, height: 1)
                }
            }
            .frame(width: contentWidth, height: 40)
        }
        .frame(width: viewportWidth, height: 40)
    }
}

private struct HostedRecentChartClickHarness: View {
    let onClick: (CGPoint) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 600, height: 70)
                HoverTrackingArea(
                    onMove: { _ in },
                    onClick: onClick,
                    onExit: {}
                )
                .frame(width: 600, height: 60)
            }
        }
    }
}

@MainActor
private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView {
        return scrollView
    }
    for subview in view.subviews {
        if let scrollView = firstScrollView(in: subview) {
            return scrollView
        }
    }
    return nil
}

@MainActor
private func firstChartTrackingView(
    in view: NSView
) -> HoverTrackingArea.TrackingView? {
    if let trackingView = view as? HoverTrackingArea.TrackingView {
        return trackingView
    }
    for subview in view.subviews {
        if let trackingView = firstChartTrackingView(in: subview) {
            return trackingView
        }
    }
    return nil
}

@MainActor
private func clickHostedChartTrackingView(
    _ trackingView: HoverTrackingArea.TrackingView,
    window: NSWindow,
    localX: CGFloat
) throws {
    let localPoint = NSPoint(x: localX, y: trackingView.bounds.midY)
    let windowPoint = trackingView.convert(localPoint, to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    )
    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
}

@MainActor
private func runMainLoopBriefly() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
