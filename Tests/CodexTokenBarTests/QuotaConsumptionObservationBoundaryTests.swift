import XCTest
@testable import CodexTokenBar

final class QuotaConsumptionObservationBoundaryTests: XCTestCase {
    func testMissingOptionalEndpointRemainsUnavailableInsteadOfObservedZero() {
        let estimate = QuotaConsumptionEstimator.estimate(
            breakdown: breakdown(input: 1_000),
            quotaStartPercent: nil,
            quotaEndPercent: 70,
            priceCard: .officialAPI(.gpt56Sol)
        )

        XCTAssertEqual(estimate.quotaDropBasis, .unavailable)
        XCTAssertFalse(estimate.quotaDropObserved)
        XCTAssertFalse(estimate.quotaDropEstimated)
        XCTAssertEqual(estimate.quotaDropPercent, 0)
        XCTAssertNil(estimate.impliedWindowBudgetUSD)
    }

    func testPreparedDataWithoutObservationProvenanceNeverClaimsObservedDrop() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let bins = (0..<3).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 300),
                tokens: 100,
                calls: 1
            )
        }
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: bins,
            bucketInterval: 300,
            maxTokens: 100,
            maxCalls: 1,
            tokenTotal: 300,
            callTotal: 3,
            recentCacheBreakdown: breakdown(input: 300),
            cacheBreakdowns: Array(repeating: breakdown(input: 100), count: 3),
            observedCacheHitRates: Array(repeating: nil, count: 3),
            fiveHourRemainingPercents: [90, 85, 80],
            sevenDayRemainingPercents: [90, 85, 80],
            latestFiveHourRemaining: 80,
            latestSevenDayRemaining: 80,
            hasCacheCalls: true,
            hasFiveHourQuota: true,
            hasSevenDayQuota: true,
            markerIndices: []
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .estimated)
        XCTAssertFalse(selection.sevenDay.quotaDropObserved)
        XCTAssertTrue(selection.sevenDay.quotaDropEstimated)
    }

    func testDatabasePublishesOneRawObservationForManyCarriedDisplayBuckets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = QuotaHistoryDatabase(
            databaseURL: directory.appendingPathComponent("quota-history.sqlite")
        )
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = quotaSnapshot(usedPercent: 20, observedAt: observedAt)

        XCTAssertTrue(try database.record(quota, createdAt: observedAt))
        let loaded = try database.loadSnapshot(
            for: quota,
            now: observedAt.addingTimeInterval(20 * 60)
        )
        let displayValues = loaded.recentBins.compactMap(\.sevenDayRemainingPercent)
        let observations = loaded.recentBins.flatMap(\.sevenDayObservations)

        XCTAssertGreaterThan(displayValues.count, 2, "one row should still feed carried chart values")
        XCTAssertEqual(observations.count, 1, "carry must not manufacture raw observations")
        XCTAssertEqual(observations.first?.observedAt, observedAt)
        XCTAssertEqual(observations.first?.remainingPercent, 80)
    }

    @MainActor
    func testSingleObservationCarryFailsClosedInsteadOfClaimingAnObservedDrop() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [80, 80, 80],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(60),
                    remainingPercent: 80,
                    resetsAt: reset
                )
            ]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.breakdown.inputTokens, 600)
        XCTAssertEqual(selection.sevenDay.comparisonBreakdown, .empty)
        XCTAssertNil(selection.sevenDay.comparisonStartDate)
        XCTAssertNil(selection.sevenDay.comparisonEndDate)
        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .unavailable)
        XCTAssertFalse(selection.sevenDay.quotaDropObserved)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 0)
        XCTAssertNil(selection.sevenDay.impliedWindowBudgetUSD)
        XCTAssertEqual(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: selection.sevenDay).detail,
            "7d 样本不足"
        )
    }

    @MainActor
    func testObservedDropUsesRealObservationBoundariesAndKeepsFullSelectionTokens() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let firstObservation = QuotaHistoryObservation(
            observedAt: start.addingTimeInterval(60),
            remainingPercent: 90,
            resetsAt: reset
        )
        let lastObservation = QuotaHistoryObservation(
            observedAt: start.addingTimeInterval(660),
            remainingPercent: 80,
            resetsAt: reset
        )
        let prepared = preparedData(
            start: start,
            sevenDayValues: [90, 85, 80],
            sevenDayObservations: [firstObservation, lastObservation]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.breakdown.inputTokens, 600, "full selected token total stays intact")
        XCTAssertEqual(
            selection.sevenDay.comparisonBreakdown.inputTokens,
            200,
            "partial first and last observation buckets are excluded"
        )
        XCTAssertEqual(selection.sevenDay.boundaryBreakdown.leading.inputTokens, 100)
        XCTAssertEqual(selection.sevenDay.boundaryBreakdown.trailing.inputTokens, 300)
        XCTAssertEqual(selection.sevenDay.boundaryBreakdown.totalTokens, 400)
        XCTAssertEqual(selection.sevenDay.boundaryBreakdown.leadingStart, start)
        XCTAssertEqual(
            selection.sevenDay.boundaryBreakdown.trailingStart,
            start.addingTimeInterval(600)
        )
        XCTAssertTrue(
            QuotaConsumptionEstimatePresentation(title: "7d", estimate: selection.sevenDay)
                .detail.contains("边缘另计")
        )
        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .observed)
        XCTAssertTrue(selection.sevenDay.comparisonUsesConservativeBuckets)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 10)
        XCTAssertEqual(selection.sevenDay.comparisonStartDate, start.addingTimeInterval(300))
        XCTAssertEqual(selection.sevenDay.comparisonEndDate, start.addingTimeInterval(600))
    }

    @MainActor
    func testTwoRealFlatObservationsRemainObservedZero() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [0, 0, 0],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(60),
                    remainingPercent: 0,
                    resetsAt: reset
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(660),
                    remainingPercent: 0,
                    resetsAt: reset
                ),
            ]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .observed)
        XCTAssertTrue(selection.sevenDay.quotaDropObserved)
        XCTAssertFalse(selection.sevenDay.quotaDropEstimated)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 0)
    }

    @MainActor
    func testAlignedFiveMinuteObservationsUseOnlyExactlyCoveredBuckets() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [90, 85, 80],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start,
                    remainingPercent: 90,
                    resetsAt: reset
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(600),
                    remainingPercent: 80,
                    resetsAt: reset
                ),
            ]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.breakdown.inputTokens, 600)
        XCTAssertEqual(selection.sevenDay.comparisonBreakdown.inputTokens, 300)
        XCTAssertFalse(selection.sevenDay.comparisonUsesConservativeBuckets)
        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .observed)
    }

    @MainActor
    func testObservationsWithoutOneStableResetBoundaryStayEstimated() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [90, 85, 80],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(60),
                    remainingPercent: 90,
                    resetsAt: nil
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(660),
                    remainingPercent: 80,
                    resetsAt: nil
                ),
            ]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .estimated)
        XCTAssertFalse(selection.sevenDay.quotaDropObserved)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 10)
    }

    @MainActor
    func testGraduallyDriftingResetBoundaryUsesLatestSameCycleSuffix() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [90, 85, 83, 81, 80],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(60),
                    remainingPercent: 90,
                    resetsAt: reset
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(360),
                    remainingPercent: 85,
                    resetsAt: reset.addingTimeInterval(90)
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(660),
                    remainingPercent: 83,
                    resetsAt: reset.addingTimeInterval(150)
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(960),
                    remainingPercent: 81,
                    resetsAt: reset.addingTimeInterval(180)
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(1260),
                    remainingPercent: 80,
                    resetsAt: reset.addingTimeInterval(210)
                ),
            ]
        )

        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 4,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .observed)
        XCTAssertTrue(selection.sevenDay.quotaDropObserved)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 5)
    }

    @MainActor
    func testNonMonotonicObservedQuotaCannotProduceFinalOtherUserAttribution() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let prepared = preparedData(
            start: start,
            sevenDayValues: [16, 38, 30],
            sevenDayObservations: [
                QuotaHistoryObservation(
                    observedAt: start,
                    remainingPercent: 16,
                    resetsAt: reset
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(300),
                    remainingPercent: 38,
                    resetsAt: reset
                ),
                QuotaHistoryObservation(
                    observedAt: start.addingTimeInterval(600),
                    remainingPercent: 30,
                    resetsAt: reset
                ),
            ]
        )
        let selection = try XCTUnwrap(
            prepared.quotaConsumptionSelection(
                startIndex: 0,
                endIndex: 2,
                priceCard: .officialAPI(.gpt56Sol)
            )
        )

        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .unavailable)
        XCTAssertFalse(selection.sevenDay.quotaDropObserved)

        let attribution = QuotaSelectionAttributionEstimator.estimate(
            selection: selection,
            context: QuotaSelectionAttributionContext(
                sourceState: .suspectedNonLocalUsage,
                tier: .twentyXPro,
                model: .gpt56Sol,
                priceRevision: .currentOfficial,
                cycleStart: start.addingTimeInterval(-300),
                cycleEnd: reset,
                localSegmentStart: start.addingTimeInterval(-300),
                quotaUpdatedAt: selection.endDate.addingTimeInterval(300),
                radarSevenDayTotalUSD: 1_000,
                radarBasis: "API-equivalent",
                radarDate: "2026-07-31",
                radarPricingBasisDate: "2026-07-31",
                radarUpdatedAt: "2026-07-31T12:00:00Z",
                radarSource: "Codex Radar",
                quotaDataStale: false,
                radarDataStale: false,
                usagePendingQuotaRefresh: false,
                localHistoryAmbiguous: false,
                usedHighWatermark: false,
                hasFinalAttributionConclusion: true
            )
        )

        XCTAssertEqual(attribution.state, .missingQuotaHistory)
        XCTAssertFalse(attribution.allowsAttributionConclusion)
        XCTAssertTrue(attribution.caveats.contains { $0.contains("至少需要两个") })
    }

    @MainActor
    func testNarrowPreviewSelectionStaysBoundedAcrossThirtyDayFiveMinuteHistory() throws {
        let bucketCount = 30 * 24 * 12
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = start.addingTimeInterval(40 * 24 * 60 * 60)
        let bins = (0..<bucketCount).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 300),
                tokens: 100,
                calls: 1
            )
        }
        let breakdowns = Array(repeating: breakdown(input: 100), count: bucketCount)
        let remaining = (0..<bucketCount).map { index in
            max(100 - Double(index) * 0.01, 0)
        }
        let observations = bins.indices.map { index in
            QuotaHistoryObservation(
                observedAt: bins[index].start,
                remainingPercent: remaining[index],
                resetsAt: reset
            )
        }
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours,
            bins: bins,
            bucketInterval: 300,
            maxTokens: 100,
            maxCalls: 1,
            tokenTotal: bucketCount * 100,
            callTotal: bucketCount,
            recentCacheBreakdown: breakdowns.combined,
            cacheBreakdowns: breakdowns,
            observedCacheHitRates: Array(repeating: nil, count: bucketCount),
            fiveHourRemainingPercents: Array(repeating: nil, count: bucketCount),
            sevenDayRemainingPercents: remaining.map(Optional.some),
            sevenDayQuotaObservations: observations,
            quotaObservationProvenanceAvailable: true,
            latestFiveHourRemaining: nil,
            latestSevenDayRemaining: remaining.last,
            hasCacheCalls: true,
            hasFiveHourQuota: false,
            hasSevenDayQuota: true,
            markerIndices: []
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        var checksum = 0
        for iteration in 0..<200 {
            let lower = bucketCount - 200 + iteration % 100
            let selection = try XCTUnwrap(
                prepared.quotaConsumptionSelection(
                    startIndex: lower,
                    endIndex: lower + 12,
                    priceCard: .officialAPI(.gpt56Sol)
                )
            )
            checksum += selection.breakdown.totalTokens
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertGreaterThan(checksum, 0)
        XCTAssertLessThan(elapsed, 1.0, "200 次鼠标预览统计不应重复扫描整段 30 天历史")
    }

    @MainActor
    private func preparedData(
        start: Date,
        sevenDayValues: [Double],
        sevenDayObservations: [QuotaHistoryObservation]
    ) -> RecentChartPreparedData {
        let bins = (0..<sevenDayValues.count).map { index in
            BinUsage(
                start: start.addingTimeInterval(Double(index) * 300),
                tokens: (index + 1) * 100,
                calls: 1
            )
        }
        let cache = bins.indices.map { index in
            TokenCacheBucket(
                start: bins[index].start,
                breakdown: breakdown(input: (index + 1) * 100)
            )
        }
        let quota = bins.indices.map { index in
            QuotaHistoryRecentBucket(
                start: bins[index].start,
                fiveHourRemainingPercent: nil,
                sevenDayRemainingPercent: sevenDayValues[index],
                sevenDayObservations: sevenDayObservations.filter { observation in
                    observation.observedAt >= bins[index].start
                        && observation.observedAt < bins[index].start.addingTimeInterval(300)
                }
            )
        }
        return RecentUsageChart.prepare(
            range: .twentyFourHours,
            recentBins: bins,
            hourlyBins: [],
            cacheRecentBins: cache,
            cacheHourlyBins: [],
            quotaRecentBins: quota,
            quotaHourlyBins: []
        )
    }

    private func breakdown(input: Int) -> TokenCacheBreakdown {
        TokenCacheBreakdown(
            inputTokens: input,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: input,
            calls: input > 0 ? 1 : 0
        )
    }

    private func quotaSnapshot(
        usedPercent: Int,
        observedAt: Date
    ) -> AccountQuotaSnapshot {
        let reset = observedAt.addingTimeInterval(7 * 24 * 60 * 60)
        var snapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(
                label: "5h",
                usedPercent: usedPercent,
                resetsAt: observedAt.addingTimeInterval(5 * 60 * 60)
            ),
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: usedPercent,
                resetsAt: reset
            ),
            planType: "Pro",
            limitName: "codex",
            accountName: "Observation Test",
            status: "fixture",
            updatedAt: observedAt
        )
        snapshot.selectedLimitID = "codex"
        snapshot.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "/fixture/quota-observation",
            stableAccountKey: "sub:quota-observation",
            planType: "Pro",
            limitID: "codex"
        )
        return snapshot
    }
}
