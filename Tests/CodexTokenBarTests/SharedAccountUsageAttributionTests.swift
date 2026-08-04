import CryptoKit
import Foundation
import XCTest
@testable import CodexTokenBar

final class SharedAccountUsageAttributionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_462_000)
    private var resetAt: Date { now.addingTimeInterval(6 * 24 * 60 * 60) }
    private var cycleStart: Date { resetAt.addingTimeInterval(-7 * 24 * 60 * 60) }

    func testUsesRadarCompatibleAmountDividedByTierTotalAndPreservesPositiveDifference() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: cycleStart.addingTimeInterval(-300), input: 9_000_000, cached: 0, output: 0),
                bucket(at: cycleStart, input: 1_000_000, cached: 400_000, output: 200_000),
            ],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(60),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: 8, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )

        XCTAssertEqual(result.breakdown.inputTokens, 1_000_000)
        XCTAssertEqual(result.priceRevision, .radar20260730)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 4.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localCurrentOfficialCostUSD), 4.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), 3, accuracy: 0.0001)
        XCTAssertEqual(result.state, .suspectedNonLocalUsage)
        XCTAssertEqual(
            SharedAccountUsageAttributionPresentation(result: result).compactSummaryLine,
            "本≈10%·差+3%"
        )
    }

    func testAutomaticallyPricesEachRecordedModelAndUsesFallbackOnlyForUnknownRows() throws {
        let sol = attributionEvent(
            id: "sol",
            at: cycleStart,
            input: 1_000_000,
            model: "gpt-5.6-sol"
        )
        let terra = attributionEvent(
            id: "terra",
            at: cycleStart.addingTimeInterval(300),
            input: 1_000_000,
            model: "gpt-5.6-terra"
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: sol.start, input: 1_000_000, cached: 0, output: 0),
                bucket(at: terra.start, input: 1_000_000, cached: 0, output: 0),
            ],
            recentAttributionEvents: [sol, terra],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Luna,
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 7.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localCurrentOfficialCostUSD), 7.5, accuracy: 0.0001)
        XCTAssertEqual(result.detectedModels, [.gpt56Sol, .gpt56Terra])
        XCTAssertEqual(result.fallbackModelCalls, 0)
        XCTAssertEqual(
            SharedAccountUsageAttributionPresentation(result: result).modelLine,
            "自动：Sol/Terra"
        )
    }

    func testPendingRestartBaselineStillShowsLocalAutomaticEquivalent() throws {
        let event = attributionEvent(
            id: "sol",
            at: cycleStart,
            input: 1_000_000,
            model: "gpt-5.6-sol"
        )
        let pending = SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: cycleStart,
            accountUsedBaselinePercent: 10,
            switchedAccountDuringCycle: false,
            baselineReady: false,
            baselineObservedAt: now.addingTimeInterval(-60),
            accountUsedObservedPercent: 10,
            comparisonUpdatedAt: now.addingTimeInterval(-60),
            quotaMovementPendingUntil: nil,
            requiredLocalObservationAfter: nil,
            cutoverReason: .continuityGap,
            cutoverDetectedAt: now.addingTimeInterval(-120),
            cutoverRecoveredAt: now.addingTimeInterval(-90),
            continuityGapID: UUID()
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            recentAttributionEvents: [event],
            sevenDayQuota: quota(used: 10, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Luna,
            now: now,
            segment: pending
        )

        XCTAssertEqual(result.state, .awaitingAccountSwitchBaseline)
        XCTAssertNil(result.accountUsedPercent)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertNil(result.nonLocalDifferencePercent)
    }

    func testDifferenceWithinTwoPercentagePointsIsNotLabeledNonLocal() throws {
        let result = estimate(
            accountUsed: 11,
            radarTotal: 46,
            tier: .twentyXPro,
            rowTier: "PRO 20×",
            model: .gpt56Terra
        )

        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), 1, accuracy: 0.0001)
        XCTAssertEqual(result.state, .withinTolerance)
        XCTAssertEqual(
            SharedAccountUsageAttributionPresentation(result: result).compactSummaryLine,
            "本≈10%·差<2%"
        )
    }

    func testUnalignedQuotaCycleIncludesTheStraddlingLocalBucketConservatively() throws {
        let alignedReset = floor(resetAt.timeIntervalSince1970 / 300) * 300
        let unalignedReset = Date(timeIntervalSince1970: alignedReset + 120)
        let unalignedCycleStart = unalignedReset.addingTimeInterval(-7 * 24 * 60 * 60)
        let straddlingBucket = Date(
            timeIntervalSince1970: floor(unalignedCycleStart.timeIntervalSince1970 / 300) * 300
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: straddlingBucket, input: 2_000_000, cached: 0, output: 0),
            ],
            sevenDayQuota: quota(used: 10, resetAt: unalignedReset),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(
                date: "2026-07-30",
                tier: "20x Pro",
                fiveHour: nil,
                sevenDay: 100
            ),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(result.localSegmentStart, unalignedCycleStart)
        XCTAssertEqual(result.breakdown.inputTokens, 2_000_000)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 10, accuracy: 0.0001)
        XCTAssertEqual(result.state, .withinTolerance)
    }

    func testNegativeDifferenceIsPreservedInsteadOfClampedToZero() throws {
        let result = estimate(
            accountUsed: 5,
            radarTotal: 46,
            tier: .twentyXPro,
            rowTier: "20x-pro",
            model: .gpt56Terra
        )

        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), -5, accuracy: 0.0001)
        XCTAssertEqual(result.state, .localEstimateExceedsAccountDrop)
        XCTAssertEqual(
            SharedAccountUsageAttributionPresentation(result: result).compactSummaryLine,
            "本机估高-5%"
        )
    }

    func testDoesNotBorrowFiveHourValueWhenSevenDayTierBaselineIsMissing() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 400_000, output: 200_000)],
            sevenDayQuota: quota(used: 10, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: 46, sevenDay: nil),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )

        XCTAssertEqual(result.state, .missingRadarTierBaseline)
        XCTAssertNil(result.radarSevenDayTotalUSD)
        XCTAssertNil(result.localSharePercent)
    }

    func testHiddenSevenDayRadarPolicyRejectsAnOtherwisePositiveLegacyRow() throws {
        let hiddenRadar = try radar(
            date: "2026-07-30",
            tier: "20x Pro",
            fiveHour: 8,
            sevenDay: 1_700,
            sevenDayPolicy: "temporarily_paused_hidden"
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 1, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: hiddenRadar,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertFalse(hiddenRadar.isWindowAvailable(.sevenDay))
        XCTAssertNil(SharedAccountRadarTier.twentyXPro.sevenDayRow(in: hiddenRadar))
        XCTAssertEqual(result.state, .missingRadarTierBaseline)
        XCTAssertNil(result.radarSevenDayTotalUSD)
        XCTAssertNil(result.localSharePercent)
    }

    func testTierMatchingHandlesSpellingOnlyVariantsWithoutCrossTierFallback() throws {
        XCTAssertTrue(SharedAccountRadarTier.twentyXPro.matches(radarTier: "ChatGPT Pro 20×"))
        XCTAssertTrue(SharedAccountRadarTier.fiveXPro.matches(radarTier: "PRO_5-X"))
        XCTAssertTrue(SharedAccountRadarTier.plus.matches(radarTier: "chatgpt plus"))
        XCTAssertFalse(SharedAccountRadarTier.fiveXPro.matches(radarTier: "20x Pro"))
        XCTAssertFalse(SharedAccountRadarTier.plus.matches(radarTier: "Pro"))

        let radar = try radar(date: "2026-07-30", tier: "5x_PRO", fiveHour: nil, sevenDay: 42.3)
        XCTAssertEqual(try XCTUnwrap(SharedAccountRadarTier.fiveXPro.sevenDayRow(in: radar)?.sevenD), 42.3)
        XCTAssertNil(SharedAccountRadarTier.twentyXPro.sevenDayRow(in: radar))
    }

    func testCurrentAndRadarPriceRevisionsUsePublishedGPT56Rates() throws {
        let breakdown = TokenCacheBreakdown(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 200_000,
            reasoningOutputTokens: 0,
            totalTokens: 1_200_000,
            calls: 1
        )

        XCTAssertEqual(OfficialAPIPriceModel.gpt56Sol.currentPriceRates.costUSD(for: breakdown), 9.2, accuracy: 0.0001)
        XCTAssertEqual(OfficialAPIPriceModel.gpt56Terra.currentPriceRates.costUSD(for: breakdown), 4.6, accuracy: 0.0001)
        XCTAssertEqual(OfficialAPIPriceModel.gpt56Luna.currentPriceRates.costUSD(for: breakdown), 1.84, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(SharedAccountRadarPriceRevision.radar20260730.rates(for: .gpt56Terra)).costUSD(for: breakdown),
            4.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(SharedAccountRadarPriceRevision.radar20260730.rates(for: .gpt56Luna)).costUSD(for: breakdown),
            1.84,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(with: try radar(date: "2026-07-31", tier: "20x Pro", fiveHour: nil, sevenDay: 100)),
            .currentOfficial
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-03",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 1_948,
                    sourceKind: "quota_api"
                )
            ),
            .currentOfficial
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-12",
                    basisDate: "2026-07-30",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 100
                )
            ),
            .radar20260730
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-12",
                    basisDate: "2026-08-12",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 100
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-03",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 1_948
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-03",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 1_948,
                    sourceKind: "estimated"
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(
                with: try radar(
                    date: "2026-08-03",
                    tier: "20x Pro",
                    fiveHour: nil,
                    sevenDay: 1_948,
                    sevenDayPolicy: "estimated",
                    sourceKind: "quota_api"
                )
            ),
            .unavailable
        )
        for invalidDate in ["2026-99-99", "2026-13-40"] {
            XCTAssertEqual(
                SharedAccountRadarPriceRevision.compatible(
                    with: try radar(
                        date: invalidDate,
                        tier: "20x Pro",
                        fiveHour: nil,
                        sevenDay: 1_948,
                        sourceKind: "quota_api"
                    )
                ),
                .unavailable,
                invalidDate
            )
        }
        let missingBasisData = try JSONSerialization.data(withJSONObject: [
            "date": "2026-07-31",
            "updated_at": "2026-07-31T08:20:35Z",
            "seven_day_policy": "direct_quota_api",
            "rows": [[
                "tier": "20x Pro",
                "seven_d": 1_693.25,
            ]],
        ])
        let missingBasis = try JSONDecoder.codexRadar.decode(
            CodexRadarQuotaRadar.self,
            from: missingBasisData
        )
        XCTAssertEqual(missingBasis.basisDate, "")
        XCTAssertEqual(
            SharedAccountRadarPriceRevision.compatible(with: missingBasis),
            .unavailable
        )
    }

    func testCurrentRadarMeasurementUsesCurrentBasisEndToEnd() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(
                date: "2026-08-03",
                tier: "20x Pro",
                fiveHour: nil,
                sevenDay: 1_948,
                sourceKind: "quota_api"
            ),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )

        XCTAssertEqual(result.priceRevision, .currentOfficial)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localCurrentOfficialCostUSD), 2.5, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(result.localSharePercent),
            2.5 / 1_948 * 100,
            accuracy: 0.0001
        )
    }

    func testLegacyStoredModelValuesMigrateOnTheExistingStorageKey() {
        XCTAssertEqual(SharedAccountUsageAttributionSettings.priceModelKey, "recentChartQuotaEstimateModel")
        XCTAssertTrue(SharedAccountUsageAttributionSettings.defaultEnabled)
        XCTAssertEqual(SharedAccountUsageAttributionSettings.defaultTier, .twentyXPro)
        XCTAssertEqual(OfficialAPIPriceModel.storedValue(for: "gpt55"), .gpt56Sol)
        XCTAssertEqual(OfficialAPIPriceModel.storedValue(for: "gpt54"), .gpt56Terra)
        XCTAssertEqual(OfficialAPIPriceModel.storedValue(for: "gpt54Mini"), .gpt56Luna)
        XCTAssertEqual(OfficialAPIPriceModel.storedValue(for: "unknown"), .gpt56Sol)
    }

    func testDisabledStateDoesNotCalculateOrPersistAttribution() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: false,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 5, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(result.state, .disabled)
        XCTAssertNil(result.localSharePercent)
        XCTAssertNil(result.highWatermarkKey)
        XCTAssertEqual(result.radarSevenDayTotalUSD, 100)
        XCTAssertEqual(result.priceRevision, .radar20260730)
        XCTAssertEqual(result.radarPricingBasisDate, "2026-07-30")
    }

    func testPendingAndMissingInputStatesRemainDistinct() throws {
        let radarSnapshot = try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100)
        let pending = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: false,
            recentBins: [],
            sevenDayQuota: quota(used: 1, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: radarSnapshot,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )
        let missingQuota = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: nil,
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: radarSnapshot,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )
        let missingReset = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 1, resetAt: nil),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: radarSnapshot,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )
        let unknownPrice = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 1, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "unknown", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(pending.state, .preciseUsagePending)
        XCTAssertEqual(missingQuota.state, .missingSevenDayQuota)
        XCTAssertEqual(missingReset.state, .missingQuotaReset)
        XCTAssertEqual(unknownPrice.state, .missingCompatiblePriceRevision)
        XCTAssertEqual(try XCTUnwrap(unknownPrice.localCurrentOfficialCostUSD), 5, accuracy: 0.0001)
    }

    func testBrokenAttributionPersistenceFailsClosedWithoutRequestingAPreciseRescan() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 5, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            persistenceHealthy: false,
            preciseUsageGeneratedAt: now
        )

        XCTAssertEqual(result.state, .attributionStorageUnavailable)
        XCTAssertFalse(result.needsPreciseCatchUp)
        XCTAssertNil(result.localSharePercent)
        XCTAssertNil(result.highWatermarkCandidate)
    }

    func testContinuityFailureCannotSelfTriggerAnInfinitePreciseRefreshLoop() throws {
        let stale = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 5, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: false,
            preciseUsageGeneratedAt: now.addingTimeInterval(-300)
        )
        let representedGapID = UUID()
        let newerFailedGapID = UUID()
        let readyRecoverySegment = SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: cycleStart,
            accountUsedBaselinePercent: 5,
            switchedAccountDuringCycle: false,
            baselineReady: true,
            baselineObservedAt: now,
            accountUsedObservedPercent: 5,
            comparisonUpdatedAt: now,
            requiredLocalObservationAfter: now,
            cutoverReason: .continuityGap,
            cutoverDetectedAt: now.addingTimeInterval(-60),
            cutoverRecoveredAt: now.addingTimeInterval(-30),
            continuityGapID: representedGapID
        )

        XCTAssertTrue(
            SharedAccountUsageAttributionAutoRefreshPolicy.shouldRequestPreciseCatchUp(
                result: stale,
                continuityLossID: nil,
                segment: nil
            )
        )
        XCTAssertTrue(
            SharedAccountUsageAttributionAutoRefreshPolicy.shouldRequestPreciseCatchUp(
                result: stale,
                continuityLossID: representedGapID,
                segment: readyRecoverySegment
            ),
            "the represented recovery cutover gets one post-baseline catch-up"
        )
        XCTAssertFalse(
            SharedAccountUsageAttributionAutoRefreshPolicy.shouldRequestPreciseCatchUp(
                result: stale,
                continuityLossID: newerFailedGapID,
                segment: readyRecoverySegment
            ),
            "a failed catch-up creates a new loss generation and must wait for normal retry cadence"
        )
    }

    func testLocalUsageNewerThanQuotaSnapshotWaitsForQuotaRefresh() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: now.addingTimeInterval(-60), input: 1_000_000, cached: 400_000, output: 200_000)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(-120),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )

        XCTAssertEqual(result.state, .awaitingQuotaRefresh)
        XCTAssertNotNil(result.nonLocalDifferencePercent)
    }

    func testQuotaSnapshotOnlyIncludesFiveMinuteBucketsThatEndedBeforeItsTimestamp() throws {
        let completed = bucket(at: now.addingTimeInterval(-600), input: 1_000_000, cached: 0, output: 0)
        let overlapping = bucket(at: now.addingTimeInterval(-300), input: 9_000_000, cached: 0, output: 0)
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [completed, overlapping],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(-180),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(result.scannedBreakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(result.scannedComparableCostUSD), 5, accuracy: 0.0001)
        XCTAssertEqual(result.state, .awaitingQuotaRefresh)
    }

    func testMissingStableIdentityDoesNotCalculateOrCreatePersistenceKey() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 5, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: nil,
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(result.state, .missingStableAccountIdentity)
        XCTAssertNil(result.localSharePercent)
        XCTAssertNil(result.highWatermarkKey)
        XCTAssertNil(result.highWatermarkCandidate)
    }

    func testRawTokenHighWatermarkPersistsBeforeRadarBecomesAvailable() throws {
        let store = InMemoryHighWatermarkStore()
        let withoutRadar = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 10, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: nil,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )
        XCTAssertEqual(withoutRadar.state, .missingRadarTierBaseline)
        XCTAssertEqual(withoutRadar.breakdown.inputTokens, 2_000_000)
        XCTAssertEqual(try XCTUnwrap(withoutRadar.localCurrentOfficialCostUSD), 10, accuracy: 0.0001)
        let key = try XCTUnwrap(withoutRadar.highWatermarkKey)
        _ = store.merge(try XCTUnwrap(withoutRadar.highWatermarkCandidate), for: key)

        let afterArchiveAndRadarRecovery = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 400_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 10, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(60),
            highWatermark: store.record(for: key)
        )

        XCTAssertEqual(try XCTUnwrap(afterArchiveAndRadarRecovery.localComparableCostUSD), 10, accuracy: 0.0001)
        XCTAssertEqual(afterArchiveAndRadarRecovery.breakdown.inputTokens, 2_000_000)
        XCTAssertTrue(afterArchiveAndRadarRecovery.usedHighWatermark)
    }

    func testStaleQuotaAndRadarSnapshotsDegradeWithoutPretendingFresh() throws {
        let radarSnapshot = try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100)
        let staleQuota = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: radarSnapshot,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            quotaDataStale: true
        )
        XCTAssertEqual(staleQuota.state, .awaitingQuotaRefresh)
        XCTAssertTrue(staleQuota.quotaDataStale)
        XCTAssertNotNil(staleQuota.highWatermarkCandidate)
        let staleQuotaPresentation = SharedAccountUsageAttributionPresentation(result: staleQuota)
        XCTAssertTrue(staleQuotaPresentation.summaryDetail.contains("额度旧数据"))
        XCTAssertFalse(staleQuotaPresentation.summaryLine.contains("｜  差 "))
        XCTAssertTrue(staleQuotaPresentation.differenceFormula.contains("暂不归因"))

        let staleRadar = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: radarSnapshot,
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            radarDataStale: true
        )
        XCTAssertEqual(staleRadar.state, .awaitingQuotaRefresh)
        XCTAssertTrue(staleRadar.radarDataStale)
        XCTAssertNotNil(staleRadar.highWatermarkCandidate)
        XCTAssertTrue(SharedAccountUsageAttributionPresentation(result: staleRadar).summaryDetail.contains("Radar 旧数据"))
    }

    func testStaleQuotaStillPersistsRawUsageUnderTheDurableCutoverKey() throws {
        let suiteName = "SharedAccountUsageStaleQuotaSegmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let segmentStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "stale-quota-segment-test",
            legacyStorageKeys: []
        )
        _ = segmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-900),
            accountUsedPercent: 10
        )
        let segment = segmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        let durableSegment = try XCTUnwrap(
            segmentStore.existingSegment(identity: identity(), resetAt: resetAt)
        )
        XCTAssertEqual(durableSegment.start, segment.start)
        XCTAssertNotEqual(durableSegment.start, cycleStart)

        let stale = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: now.addingTimeInterval(-300), input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 11, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now,
            segment: durableSegment,
            quotaDataStale: true
        )
        let candidate = try XCTUnwrap(stale.highWatermarkCandidate)
        let key = try XCTUnwrap(stale.highWatermarkKey)
        XCTAssertEqual(key.segmentStart, durableSegment.start)
        XCTAssertEqual(candidate.breakdown.inputTokens, 1_000_000)

        let recovered = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 11, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now,
            segment: durableSegment,
            highWatermark: candidate
        )
        XCTAssertEqual(recovered.breakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(recovered.localSharePercent), 5, accuracy: 0.0001)
    }

    func testPreciseUsageOlderThanQuotaWaitsAndCannotAdvanceHighWatermark() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(result.state, .preciseUsageStale)
        XCTAssertNil(result.localSharePercent)
        XCTAssertNil(result.nonLocalDifferencePercent)
        XCTAssertNil(result.highWatermarkKey)
        XCTAssertNil(result.highWatermarkCandidate)
    }

    func testTwentyXExampleUsesTheRadarSevenDayDollarTotalAsTheDenominator() throws {
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 1, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 1_700),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.radarSevenDayTotalUSD), 1_700, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 10.0 / 1_700.0 * 100, accuracy: 0.000_001)
        XCTAssertTrue(
            SharedAccountUsageAttributionPresentation(result: result)
                .localFormula.contains("$10.00 ÷ $1700.00 × 100")
        )
    }

    func testExpiredQuotaCycleWaitsWithoutCreatingAHighWatermarkCandidate() throws {
        let expiredReset = now.addingTimeInterval(-300)
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: expiredReset.addingTimeInterval(-300), input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 5, resetAt: expiredReset),
            quotaUpdatedAt: now.addingTimeInterval(-600),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now
        )

        XCTAssertEqual(result.state, .awaitingQuotaRefresh)
        XCTAssertNil(result.highWatermarkCandidate)
    }

    func testHighWatermarkProtectsComparableCostWhenLocalHistoryShrinks() throws {
        let stored = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 1_500_000, cached: 600_000, output: 300_000)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(-60)
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 400_000, output: 200_000)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now,
            highWatermark: stored
        )

        XCTAssertEqual(try XCTUnwrap(result.scannedComparableCostUSD), 4.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 6.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), -2, accuracy: 0.0001)
        XCTAssertTrue(result.usedHighWatermark)
    }

    func testHighWatermarkStoreIsInjectableAndNeverMovesBackward() {
        let store = InMemoryHighWatermarkStore()
        let key = highWatermarkKey(resetAt: resetAt)
        let first = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now
        )
        let lower = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 400_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(60)
        )
        let later = highWatermarkRecord(
            bins: [bucket(at: cycleStart.addingTimeInterval(300), input: 600_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(store.merge(first, for: key), first)
        let afterArchive = store.merge(lower, for: key)
        XCTAssertEqual(afterArchive.breakdown.inputTokens, 2_000_000)
        XCTAssertTrue(afterArchive.ambiguityDetected)
        XCTAssertEqual(afterArchive.observedAt, lower.observedAt)
        let afterLaterBucket = store.merge(later, for: key)
        XCTAssertEqual(afterLaterBucket.breakdown.inputTokens, 2_600_000)
        XCTAssertEqual(store.record(for: key), afterLaterBucket)
    }

    func testHighWatermarkKeepsNewLocalBucketsWhenTheWallClockMovesBackward() {
        let stored = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(3_600)
        )
        let clockRolledBackCandidate = highWatermarkRecord(
            bins: [bucket(at: cycleStart.addingTimeInterval(300), input: 1_000_000, cached: 0, output: 0)],
            observedAt: now
        )

        let merged = stored.merging(clockRolledBackCandidate)

        XCTAssertEqual(merged.breakdown.inputTokens, 3_000_000)
        XCTAssertEqual(merged.observedAt, stored.observedAt)
    }

    func testUserDefaultsHighWatermarkStorePersistsPerBucketTokenMaximums() {
        let suiteName = "SharedAccountUsageAttributionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-test"
        )
        let key = highWatermarkKey(resetAt: resetAt)
        let first = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now
        )
        let lower = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 400_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(60)
        )

        XCTAssertEqual(store.merge(first, for: key), first)
        let afterArchive = store.merge(lower, for: key)
        XCTAssertEqual(afterArchive.breakdown.inputTokens, 2_000_000)
        let reloaded = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-test"
        ).record(for: key)
        XCTAssertEqual(reloaded, afterArchive)
        XCTAssertTrue(try! XCTUnwrap(reloaded).ambiguityDetected)
        XCTAssertEqual(reloaded?.observedAt, lower.observedAt)
    }

    func testProductionSafetyDatabaseMigratesHighWatermarkAndSkipsObservationOnlyRewrite() throws {
        let suiteName = "SharedAccountUsageSafetyMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetyMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        let key = highWatermarkKey(resetAt: resetAt)
        let initial = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now
        )
        _ = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-safety-migration"
        ).merge(initial, for: key)

        let migratedStore = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-safety-migration",
            safetyDatabase: database
        )
        XCTAssertEqual(migratedStore.record(for: key), initial)
        XCTAssertTrue(database.persistenceHealthy)
        XCTAssertNil(defaults.data(forKey: "high-water-safety-migration"))

        let driver = SQLiteDatabaseDriver(url: databaseURL)
        let committedBefore = try XCTUnwrap(
            driver.readRows(
                "SELECT committed_at FROM safety_records WHERE kind = ?;",
                bindings: [.text(SharedAccountUsageSafetyDatabase.RecordKind.highWatermarks.rawValue)]
            ) { $0.double(0) }.first
        )
        let observationOnly = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(migratedStore.merge(observationOnly, for: key), initial)
        let committedAfter = try XCTUnwrap(
            driver.readRows(
                "SELECT committed_at FROM safety_records WHERE kind = ?;",
                bindings: [.text(SharedAccountUsageSafetyDatabase.RecordKind.highWatermarks.rawValue)]
            ) { $0.double(0) }.first
        )
        XCTAssertEqual(committedAfter, committedBefore)

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(
            UserDefaultsSharedAccountUsageHighWatermarkStore(
                defaults: defaults,
                storageKey: "high-water-safety-migration",
                safetyDatabase: SharedAccountUsageSafetyDatabase(url: databaseURL)
            ).record(for: key),
            initial
        )
    }

    func testCorruptProductionSafetyPayloadFailsClosedWithoutOverwritingEvidence() throws {
        let suiteName = "SharedAccountUsageSafetyCorruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetyCorruptionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        let corrupt = Data(#"{"unexpected":true}"#.utf8)
        XCTAssertTrue(database.store(corrupt, as: .highWatermarks))
        let store = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            safetyDatabase: database
        )
        let key = highWatermarkKey(resetAt: resetAt)

        XCTAssertNil(store.record(for: key))
        XCTAssertFalse(store.persistenceHealthy)
        _ = store.merge(
            highWatermarkRecord(
                bins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
                observedAt: now
            ),
            for: key
        )
        XCTAssertFalse(store.persistenceHealthy)
        XCTAssertFalse(database.persistenceHealthy)
        XCTAssertNil(database.load(.highWatermarks))
        XCTAssertEqual(
            SharedAccountUsageSafetyDatabase(url: databaseURL)
                .load(.highWatermarks),
            corrupt,
            "typed corruption must remain quarantinable evidence"
        )
    }

    func testCorruptUserDefaultsMigrationMarksSafetyDatabaseRecoverable() throws {
        let suiteName = "SharedAccountUsageCorruptMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageCorruptMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let corruptTypedObject = Data(#"{"unexpected":true}"#.utf8)

        let highWaterKey = "corrupt-high-water-migration"
        defaults.set(corruptTypedObject, forKey: highWaterKey)
        let highWaterDatabase = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("high-water.sqlite")
        )
        let highWaterStore = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: highWaterKey,
            legacyStorageKeys: [],
            safetyDatabase: highWaterDatabase
        )
        XCTAssertNil(highWaterStore.record(for: highWatermarkKey(resetAt: resetAt)))
        XCTAssertFalse(highWaterStore.persistenceHealthy)
        XCTAssertTrue(highWaterDatabase.recoveryRequired)

        let segmentKey = "corrupt-segment-migration"
        defaults.set(corruptTypedObject, forKey: segmentKey)
        let segmentDatabase = SharedAccountUsageSafetyDatabase(
            url: directory.appendingPathComponent("segments.sqlite")
        )
        let segmentStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: segmentKey,
            legacyStorageKeys: [],
            safetyDatabase: segmentDatabase
        )
        XCTAssertNil(segmentStore.existingSegment(identity: identity(), resetAt: resetAt))
        XCTAssertFalse(segmentStore.persistenceHealthy)
        XCTAssertTrue(segmentDatabase.recoveryRequired)
    }

    func testProductionSafetyDatabasePersistsSegmentStateAfterDefaultsDisappear() throws {
        let suiteName = "SharedAccountUsageSafetySegmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetySegmentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let defaultsStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-safety-test",
            legacyStorageKeys: []
        )
        let pending = defaultsStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        let ready = defaultsStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: pending.start.addingTimeInterval(60),
            accountUsedPercent: 11
        )
        XCTAssertTrue(ready.baselineReady)

        let migratedStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-safety-test",
            legacyStorageKeys: [],
            safetyDatabase: SharedAccountUsageSafetyDatabase(url: databaseURL)
        )
        XCTAssertEqual(
            migratedStore.existingSegment(identity: identity(), resetAt: resetAt),
            ready
        )
        XCTAssertNil(defaults.data(forKey: "segment-safety-test"))

        defaults.removePersistentDomain(forName: suiteName)
        let reloaded = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-safety-test",
            legacyStorageKeys: [],
            safetyDatabase: SharedAccountUsageSafetyDatabase(url: databaseURL)
        )
        XCTAssertEqual(
            reloaded.existingSegment(identity: identity(), resetAt: resetAt),
            ready
        )
        XCTAssertTrue(reloaded.persistenceHealthy)
    }

    func testNewObservationSessionCreatesExactlyOneSyntheticRestartCutover() {
        let suiteName = "SharedAccountUsageObserverRestartTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "observer-restart-segments",
            legacyStorageKeys: [],
            observerInstanceID: UUID()
        )
        let firstPending = firstStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-900),
            accountUsedPercent: 10
        )
        let firstReady = firstStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: firstPending.start.addingTimeInterval(60),
            accountUsedPercent: 11
        )
        XCTAssertTrue(firstReady.baselineReady)

        let restartedStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "observer-restart-segments",
            legacyStorageKeys: [],
            observerInstanceID: UUID()
        )
        let restartPending = restartedStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now,
            accountUsedPercent: 17
        )
        XCTAssertFalse(restartPending.baselineReady)
        XCTAssertEqual(restartPending.effectiveCutoverReason, .continuityGap)
        XCTAssertEqual(restartPending.accountUsedBaselinePercent, 17)

        let restartReady = restartedStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: restartPending.start.addingTimeInterval(60),
            accountUsedPercent: 18
        )
        XCTAssertTrue(restartReady.baselineReady)
        XCTAssertEqual(restartReady.accountUsedBaselinePercent, 18)
        XCTAssertEqual(restartReady.effectiveCutoverReason, .continuityGap)
    }

    func testAttributionSafetyGapIdentityIsStableForOneUnsafeGeneration() {
        let first = UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
            provenanceEpoch: "epoch-a",
            unsafeSinceGeneration: 42
        )
        XCTAssertEqual(
            first,
            UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
                provenanceEpoch: "epoch-a",
                unsafeSinceGeneration: 42
            )
        )
        XCTAssertNotEqual(
            first,
            UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
                provenanceEpoch: "epoch-a",
                unsafeSinceGeneration: 43
            )
        )
        XCTAssertNotEqual(
            first,
            UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
                provenanceEpoch: "epoch-b",
                unsafeSinceGeneration: 42
            )
        )
        XCTAssertFalse(
            SharedAccountUsageAttributionPersistencePolicy.shouldMergeHighWatermark(
                attributionUnsafeSinceGeneration: 42
            )
        )
        XCTAssertTrue(
            SharedAccountUsageAttributionPersistencePolicy.shouldMergeHighWatermark(
                attributionUnsafeSinceGeneration: nil
            )
        )
        XCTAssertNil(
            UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
                provenanceEpoch: "epoch-a",
                unsafeSinceGeneration: 42,
                currentScanUnsafeCauseDetected: true
            ),
            "a currently unsafe scan must not create or advance a baseline"
        )
        XCTAssertEqual(
            UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
                provenanceEpoch: "epoch-a",
                unsafeSinceGeneration: 42,
                currentScanUnsafeCauseDetected: false
            ),
            first
        )
    }

    func testIndexRecoveryRequiresNewQuotaAndCoverageAndResetsForLaterUnsafeEpisode() {
        let suiteName = "SharedAccountUsageIndexRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "index-recovery-segments",
            legacyStorageKeys: []
        )
        let firstGeneration: Int64 = 42
        let firstGapID = UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
            provenanceEpoch: "sticky-epoch",
            unsafeSinceGeneration: firstGeneration
        )
        let firstQuotaAt = now.addingTimeInterval(60)
        let firstCoverageAt = now.addingTimeInterval(120)
        let pending = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: firstQuotaAt,
            accountUsedPercent: 10,
            gapID: firstGapID,
            gapDetectedAt: now,
            recoveredCoverageAt: firstCoverageAt,
            cleanRecoveryGeneration: firstGeneration
        )
        XCTAssertFalse(pending.baselineReady)
        XCTAssertEqual(pending.cutoverRecoveryGeneration, firstGeneration)

        let newerQuotaWithoutNewCoverage = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(360),
            accountUsedPercent: 11,
            gapID: firstGapID,
            gapDetectedAt: now,
            recoveredCoverageAt: firstCoverageAt,
            cleanRecoveryGeneration: firstGeneration
        )
        XCTAssertEqual(newerQuotaWithoutNewCoverage, pending)

        let newCoverageWithoutNewQuota = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: firstQuotaAt,
            accountUsedPercent: 10,
            gapID: firstGapID,
            gapDetectedAt: now,
            recoveredCoverageAt: now.addingTimeInterval(420),
            cleanRecoveryGeneration: firstGeneration
        )
        XCTAssertEqual(newCoverageWithoutNewQuota, pending)

        let firstReady = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(360),
            accountUsedPercent: 11,
            gapID: firstGapID,
            gapDetectedAt: now,
            recoveredCoverageAt: now.addingTimeInterval(420),
            cleanRecoveryGeneration: firstGeneration
        )
        XCTAssertTrue(firstReady.baselineReady)
        XCTAssertEqual(firstReady.cutoverRecoveryGeneration, firstGeneration)

        let secondGeneration: Int64 = 43
        let secondGapID = UserDefaultsSharedAccountUsageSegmentStore.attributionSafetyGapID(
            provenanceEpoch: "sticky-epoch",
            unsafeSinceGeneration: secondGeneration
        )
        let secondPending = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(600),
            accountUsedPercent: 13,
            gapID: secondGapID,
            gapDetectedAt: now.addingTimeInterval(570),
            recoveredCoverageAt: now.addingTimeInterval(660),
            cleanRecoveryGeneration: secondGeneration
        )
        XCTAssertFalse(secondPending.baselineReady)
        XCTAssertEqual(secondPending.continuityGapID, secondGapID)
        XCTAssertEqual(secondPending.cutoverRecoveryGeneration, secondGeneration)
        XCTAssertNotEqual(secondPending.start, firstReady.start)
    }

    func testOnlyOneProductionDatabaseInstanceOwnsAttributionObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageObserverOwnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let owner = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )
        let nonOwner = SharedAccountUsageSafetyDatabase(
            url: databaseURL,
            claimsObserverOwnership: true
        )

        XCTAssertTrue(owner.isObserverOwner)
        XCTAssertFalse(nonOwner.isObserverOwner)
        XCTAssertTrue(nonOwner.persistenceHealthy)
    }

    func testInitializedSafetyRecordDeletionAndWholeDatabaseLossBothFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetyLossTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        let payload = try JSONEncoder().encode([String: SharedAccountUsageHighWatermarkRecord]())
        XCTAssertTrue(database.store(payload, as: .highWatermarks))

        try SQLiteDatabaseDriver(url: databaseURL).execute(
            "DELETE FROM safety_records WHERE kind = ?;",
            bindings: [.text(SharedAccountUsageSafetyDatabase.RecordKind.highWatermarks.rawValue)]
        )
        XCTAssertNil(database.load(.highWatermarks))
        XCTAssertFalse(database.persistenceHealthy)
        XCTAssertFalse(database.store(payload, as: .highWatermarks))

        let secondURL = directory.appendingPathComponent("whole-loss.sqlite")
        let secondDatabase = SharedAccountUsageSafetyDatabase(url: secondURL)
        XCTAssertTrue(secondDatabase.store(payload, as: .highWatermarks))
        try FileManager.default.removeItem(at: secondURL)
        try? FileManager.default.removeItem(at: secondURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: secondURL.appendingPathExtension("shm"))
        let reopenedAfterLoss = SharedAccountUsageSafetyDatabase(url: secondURL)
        XCTAssertFalse(reopenedAfterLoss.persistenceHealthy)
        XCTAssertNil(reopenedAfterLoss.load(.highWatermarks))
    }

    func testDamagedSafetyGenerationStaysClosedUntilVerifiedQuarantineRebuild() throws {
        let suiteName = "SharedAccountUsageSafetyRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetyRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("safety.sqlite")
        let database = SharedAccountUsageSafetyDatabase(url: databaseURL)
        XCTAssertTrue(database.store(Data(#"{"unexpected":true}"#.utf8), as: .segments))
        database.reportCorruptPayload(.segments)
        XCTAssertTrue(database.recoveryRequired)
        XCTAssertNil(database.load(.segments))
        XCTAssertFalse(database.store(Data("{}".utf8), as: .segments))

        let retiredKeys = ["old-high-water", "old-segments", "old-continuity"]
        for key in retiredKeys {
            defaults.set(Data("{}".utf8), forKey: key)
        }
        let recoveryLoss = PreciseTimeSeriesContinuityLossRecord(
            id: UUID(),
            detectedAt: now,
            reason: .storageRecovery
        )
        let continuityPayload = try JSONEncoder().encode([
            "home": recoveryLoss,
        ])
        let recovery = try XCTUnwrap(database.rebuildEmptySafetyBaseline(
            preciseContinuityPayload: continuityPayload,
            defaults: defaults,
            retiredUserDefaultsKeys: retiredKeys
        ))

        XCTAssertTrue(database.persistenceHealthy)
        XCTAssertFalse(database.recoveryRequired)
        XCTAssertEqual(database.load(.highWatermarks), Data("{}".utf8))
        XCTAssertEqual(database.load(.segments), Data("{}".utf8))
        XCTAssertEqual(database.load(.preciseContinuity), continuityPayload)
        for key in retiredKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.quarantineDirectory
                    .appendingPathComponent(databaseURL.lastPathComponent).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: databaseURL.appendingPathExtension("recovery-required").path
            )
        )
        let reopened = SharedAccountUsageSafetyDatabase(url: databaseURL)
        XCTAssertTrue(reopened.persistenceHealthy)
        XCTAssertEqual(reopened.load(.preciseContinuity), continuityPayload)
    }

    func testRecoveryMarkerAndOwnerContentionKeepSafetyStateFailedClosed() throws {
        let suiteName = "SharedAccountUsageSafetyRecoveryGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedAccountUsageSafetyRecoveryGateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let interruptedURL = directory.appendingPathComponent("interrupted.sqlite")
        let interrupted = SharedAccountUsageSafetyDatabase(url: interruptedURL)
        XCTAssertTrue(interrupted.store(Data("{}".utf8), as: .segments))
        try Data("recovery-in-progress\n".utf8).write(
            to: interruptedURL.appendingPathExtension("recovery-required"),
            options: .atomic
        )
        let reopenedInterrupted = SharedAccountUsageSafetyDatabase(url: interruptedURL)
        XCTAssertFalse(reopenedInterrupted.persistenceHealthy)
        XCTAssertNil(reopenedInterrupted.load(.segments))

        let ownedURL = directory.appendingPathComponent("owned.sqlite")
        let owner = SharedAccountUsageSafetyDatabase(
            url: ownedURL,
            claimsObserverOwnership: true
        )
        let nonOwner = SharedAccountUsageSafetyDatabase(
            url: ownedURL,
            claimsObserverOwnership: true
        )
        XCTAssertTrue(owner.isObserverOwner)
        XCTAssertFalse(nonOwner.isObserverOwner)
        nonOwner.reportCorruptPayload(.segments)
        defaults.set(Data("{}".utf8), forKey: "must-survive-failed-recovery")
        let emptyContinuity = try JSONEncoder().encode(
            [String: PreciseTimeSeriesContinuityLossRecord]()
        )
        let failedRecovery = withExtendedLifetime(owner) {
            nonOwner.rebuildEmptySafetyBaseline(
                preciseContinuityPayload: emptyContinuity,
                defaults: defaults,
                retiredUserDefaultsKeys: ["must-survive-failed-recovery"]
            )
        }
        XCTAssertNil(failedRecovery)
        XCTAssertNotNil(defaults.object(forKey: "must-survive-failed-recovery"))
    }

    func testSameBucketRestoreNeverDoubleCountsPreviouslyObservedUsage() throws {
        let first = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now
        )
        let archived = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 400_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(60)
        )
        let newUsageInSameBucket = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(120)
        )

        let merged = first.merging(archived).merging(newUsageInSameBucket)

        XCTAssertEqual(merged.breakdown.inputTokens, 2_000_000)
        XCTAssertTrue(merged.ambiguityDetected)
        XCTAssertEqual(
            try XCTUnwrap(
                SharedAccountRadarPriceRevision.radar20260730
                    .rates(for: .gpt56Sol)?
                    .costUSD(for: merged.breakdown)
            ),
            10,
            accuracy: 0.0001
        )

        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            highWatermark: merged
        )
        XCTAssertEqual(result.state, .localHistoryAmbiguous)
        XCTAssertTrue(result.localHistoryAmbiguous)
        XCTAssertFalse(result.hasFinalAttributionConclusion)
    }

    func testZeroBucketsAreNotPersistedOrAllowedToInflatePayload() {
        let record = highWatermarkRecord(
            bins: [
                bucket(at: cycleStart, input: 0, cached: 0, output: 0),
                bucket(at: cycleStart.addingTimeInterval(300), input: 1_000_000, cached: 0, output: 0),
                bucket(at: cycleStart.addingTimeInterval(600), input: 0, cached: 0, output: 0),
            ],
            observedAt: now
        )

        XCTAssertEqual(record.buckets.count, 1)
    }

    func testUnreleasedSlidingBucketStorageIsNotReadAfterFixedBucketUpgrade() throws {
        XCTAssertEqual(
            UserDefaultsSharedAccountUsageHighWatermarkStore.defaultStorageKey,
            "sharedAccountUsageAttributionHighWatermarksV05"
        )
        XCTAssertEqual(
            UserDefaultsSharedAccountUsageSegmentStore.defaultStorageKey,
            "sharedAccountUsageAttributionSegmentsV07"
        )
        let suiteName = "SharedAccountUsageAttributionVersionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = highWatermarkKey(resetAt: resetAt)
        let oldPreview = highWatermarkRecord(
            bins: [bucket(at: cycleStart.addingTimeInterval(17), input: 2_000_000, cached: 0, output: 0)],
            observedAt: now
        )
        defaults.set(
            try JSONEncoder().encode([key.storageIdentifier: oldPreview]),
            forKey: "sharedAccountUsageAttributionHighWatermarksV02"
        )

        let upgradedStore = UserDefaultsSharedAccountUsageHighWatermarkStore(defaults: defaults)

        XCTAssertNil(upgradedStore.record(for: key))
    }

    func testReadySegmentAndV04ArchivedUsageUpgradeFailClosedWithoutLosingTheAmount() throws {
        let suiteName = "SharedAccountUsageAttributionV04MigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let segmentStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            legacyStorageKeys: []
        )
        let pending = segmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        let ready = segmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: pending.start.addingTimeInterval(60),
            accountUsedPercent: 11
        )
        XCTAssertTrue(ready.baselineReady)

        let key = highWatermarkKey(resetAt: resetAt, segmentStart: ready.start)
        let archived = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: ready.start, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now
        )
        defaults.set(
            try JSONEncoder().encode([key.storageIdentifier: archived]),
            forKey: "sharedAccountUsageAttributionHighWatermarksV04"
        )

        let migrated = try XCTUnwrap(
            UserDefaultsSharedAccountUsageHighWatermarkStore(defaults: defaults)
                .record(for: key)
        )
        XCTAssertEqual(migrated.breakdown.inputTokens, 2_000_000)
        XCTAssertTrue(migrated.ambiguityDetected)
        XCTAssertFalse(migrated.eventProvenanceComplete)
        XCTAssertNotNil(
            defaults.data(
                forKey: UserDefaultsSharedAccountUsageHighWatermarkStore.defaultStorageKey
            )
        )
    }

    func testReadyV06AndV03OnlyArchivedUsageBothUpgradeThroughASyntheticCutover() throws {
        let suiteName = "SharedAccountUsageAttributionIntermediatePreviewMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldSegmentStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "sharedAccountUsageAttributionSegmentsV06",
            legacyStorageKeys: []
        )
        let oldPending = oldSegmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        let oldReady = oldSegmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: oldPending.start.addingTimeInterval(60),
            accountUsedPercent: 11
        )
        XCTAssertTrue(oldReady.baselineReady)

        let key = highWatermarkKey(resetAt: resetAt, segmentStart: oldReady.start)
        let archived = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: oldReady.start, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now
        )
        defaults.set(
            try JSONEncoder().encode([key.storageIdentifier: archived]),
            forKey: "sharedAccountUsageAttributionHighWatermarksV03"
        )

        let upgradedSegment = UserDefaultsSharedAccountUsageSegmentStore(defaults: defaults)
            .resolve(
                identity: identity(),
                resetAt: resetAt,
                cycleStart: cycleStart,
                quotaUpdatedAt: now.addingTimeInterval(120),
                accountUsedPercent: 12
            )
        let migratedWatermark = try XCTUnwrap(
            UserDefaultsSharedAccountUsageHighWatermarkStore(defaults: defaults)
                .record(for: key)
        )

        XCTAssertFalse(upgradedSegment.baselineReady)
        XCTAssertEqual(upgradedSegment.effectiveCutoverReason, .legacyMigration)
        XCTAssertEqual(migratedWatermark.breakdown.inputTokens, 2_000_000)
        XCTAssertTrue(migratedWatermark.ambiguityDetected)
    }

    func testEventLedgerAddsNewUsageAfterTheOldEventDisappearsInTheSameBucket() {
        let firstEvent = attributionEvent(id: "old-event", at: cycleStart, input: 2_000_000)
        let newEvent = attributionEvent(id: "new-event", at: cycleStart, input: 3_000_000)
        let first = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now,
            attributionEvents: [firstEvent],
            provenanceEpoch: "index-generation-a"
        )
        let afterArchive = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 3_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(60),
            attributionEvents: [newEvent],
            provenanceEpoch: "index-generation-a"
        )

        let merged = first.merging(afterArchive)

        XCTAssertTrue(merged.eventProvenanceComplete)
        XCTAssertFalse(merged.ambiguityDetected)
        XCTAssertEqual(merged.contributions.count, 2)
        XCTAssertEqual(merged.breakdown.inputTokens, 5_000_000)
    }

    func testEventLedgerTakesTheMonotonicMaximumForAVerifiedSourceAppend() {
        let firstContribution = attributionEvent(
            id: "source-a-bucket",
            at: cycleStart,
            input: 2_000_000
        )
        let appendedContribution = attributionEvent(
            id: "source-a-bucket",
            at: cycleStart,
            input: 3_000_000
        )
        let first = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now,
            attributionEvents: [firstContribution],
            provenanceEpoch: "index-generation-a"
        )
        let appended = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 3_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(60),
            attributionEvents: [appendedContribution],
            provenanceEpoch: "index-generation-a"
        )

        let merged = first.merging(appended)

        XCTAssertFalse(merged.ambiguityDetected)
        XCTAssertEqual(merged.contributions.count, 1)
        XCTAssertEqual(merged.breakdown.inputTokens, 3_000_000)
    }

    func testEventLedgerFailsClosedAcrossIndexEpochOrSourceMutation() {
        let event = attributionEvent(id: "event-a", at: cycleStart, input: 2_000_000)
        let first = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now,
            attributionEvents: [event],
            provenanceEpoch: "index-generation-a"
        )
        let resetIndex = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(60),
            attributionEvents: [event],
            provenanceEpoch: "index-generation-b"
        )
        let rewrittenSource = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: resetAt,
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(120),
            attributionEvents: [event],
            provenanceEpoch: "index-generation-a",
            sourceMutationDetected: true
        )

        XCTAssertTrue(first.merging(resetIndex).ambiguityDetected)
        XCTAssertTrue(first.merging(rewrittenSource).ambiguityDetected)
    }

    func testUserDefaultsHighWatermarkStoreDoesNotPruneAnotherCycleFromWallClock() {
        let suiteName = "SharedAccountUsageAttributionPruningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-pruning-test"
        )
        let completedReset = now.addingTimeInterval(-300)
        let completedKey = highWatermarkKey(resetAt: completedReset)
        let completed = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: completedReset,
            bins: [bucket(at: completedReset.addingTimeInterval(-300), input: 1_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(-600)
        )
        _ = store.merge(completed, for: completedKey)
        XCTAssertNotNil(store.record(for: completedKey))

        let activeKey = highWatermarkKey(resetAt: resetAt)
        let active = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(365 * 24 * 60 * 60)
        )
        _ = store.merge(active, for: activeKey)

        XCTAssertNotNil(store.record(for: completedKey))
        XCTAssertEqual(store.record(for: activeKey), active)
    }

    func testFreshQuotaMetadataPrunesOnlyTheOldestUniqueCycleInTheSameScope() throws {
        let suiteName = "SharedAccountUsageAttributionSafePruningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: "high-water-safe-pruning-test"
        )
        let oldReset = resetAt.addingTimeInterval(-14 * 24 * 60 * 60)
        let previousReset = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let oldKey = highWatermarkKey(resetAt: oldReset, segmentStart: oldReset.addingTimeInterval(-300))
        let previousKey = highWatermarkKey(
            resetAt: previousReset,
            segmentStart: previousReset.addingTimeInterval(-300)
        )
        let currentFirstKey = highWatermarkKey(
            resetAt: resetAt,
            segmentStart: resetAt.addingTimeInterval(-600)
        )
        let currentSecondKey = highWatermarkKey(
            resetAt: resetAt,
            segmentStart: resetAt.addingTimeInterval(-300)
        )
        let otherScopeKey = highWatermarkKey(
            resetAt: oldReset,
            segmentStart: oldReset.addingTimeInterval(-300),
            account: "account-b"
        )

        func staleRecord(for key: SharedAccountUsageHighWatermarkKey) -> SharedAccountUsageHighWatermarkRecord {
            SharedAccountUsageHighWatermarkRecord(
                cycleResetAt: key.resetAt,
                bins: [bucket(at: key.segmentStart, input: 1_000_000, cached: 0, output: 0)],
                priceRevision: .radar20260730,
                observedAt: now,
                scopeIdentifier: key.scopeIdentifier,
                quotaObservationFresh: false
            )
        }

        _ = store.merge(staleRecord(for: oldKey), for: oldKey)
        _ = store.merge(staleRecord(for: previousKey), for: previousKey)
        _ = store.merge(staleRecord(for: currentFirstKey), for: currentFirstKey)
        let currentStale = staleRecord(for: currentSecondKey)
        _ = store.merge(currentStale, for: currentSecondKey)
        _ = store.merge(staleRecord(for: otherScopeKey), for: otherScopeKey)

        let currentFresh = SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: currentSecondKey.resetAt,
            bins: [bucket(at: currentSecondKey.segmentStart, input: 1_000_000, cached: 0, output: 0)],
            priceRevision: .radar20260730,
            observedAt: now.addingTimeInterval(60),
            scopeIdentifier: currentSecondKey.scopeIdentifier,
            quotaObservationFresh: true
        )
        let merged = store.merge(currentFresh, for: currentSecondKey)

        XCTAssertTrue(merged.quotaObservationFresh)
        XCTAssertNil(store.record(for: oldKey))
        XCTAssertNotNil(store.record(for: previousKey))
        XCTAssertNotNil(store.record(for: currentFirstKey))
        XCTAssertNotNil(store.record(for: currentSecondKey))
        XCTAssertNotNil(store.record(for: otherScopeKey))
    }

    func testCorruptAttributionStoresFailClosedWithoutOverwritingEvidence() {
        let suiteName = "SharedAccountUsageCorruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let highWaterKey = "corrupt-high-water"
        let segmentKey = "corrupt-segment"
        let corrupt = Data([0xff, 0x00, 0x7f])
        defaults.set(corrupt, forKey: highWaterKey)
        defaults.set(corrupt, forKey: segmentKey)

        let highWaterStore = UserDefaultsSharedAccountUsageHighWatermarkStore(
            defaults: defaults,
            storageKey: highWaterKey
        )
        XCTAssertNil(highWaterStore.record(for: highWatermarkKey(resetAt: resetAt)))
        XCTAssertFalse(highWaterStore.persistenceHealthy)
        _ = highWaterStore.merge(
            highWatermarkRecord(
                bins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
                observedAt: now
            ),
            for: highWatermarkKey(resetAt: resetAt)
        )
        XCTAssertFalse(highWaterStore.persistenceHealthy)
        XCTAssertEqual(defaults.data(forKey: highWaterKey), corrupt)

        let segmentStore = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: segmentKey,
            legacyStorageKeys: []
        )
        let failClosed = segmentStore.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now,
            accountUsedPercent: 10
        )
        XCTAssertFalse(segmentStore.persistenceHealthy)
        XCTAssertFalse(failClosed.baselineReady)
        XCTAssertEqual(failClosed.effectiveCutoverReason, .continuityGap)
        XCTAssertEqual(defaults.data(forKey: segmentKey), corrupt)
    }

    func testArchiveThenNewBucketAddsToThePreservedLocalUsage() throws {
        let stored = highWatermarkRecord(
            bins: [bucket(at: cycleStart, input: 2_000_000, cached: 0, output: 0)],
            observedAt: now.addingTimeInterval(-600)
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: cycleStart, input: 400_000, cached: 0, output: 0),
                bucket(at: cycleStart.addingTimeInterval(300), input: 600_000, cached: 0, output: 0),
            ],
            sevenDayQuota: quota(used: 15, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            highWatermark: stored
        )

        XCTAssertEqual(try XCTUnwrap(result.scannedComparableCostUSD), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 13, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 13, accuracy: 0.0001)
        XCTAssertEqual(result.breakdown.inputTokens, 2_600_000)
        XCTAssertTrue(result.usedHighWatermark)
    }

    func testAccountSwitchCreatesANewTokenAndQuotaBaseline() throws {
        let segment = SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: now.addingTimeInterval(-600),
            accountUsedBaselinePercent: 13,
            switchedAccountDuringCycle: true,
            baselineReady: true,
            baselineObservedAt: now.addingTimeInterval(-600),
            accountUsedObservedPercent: 16,
            comparisonUpdatedAt: now
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: cycleStart, input: 9_000_000, cached: 0, output: 0),
                bucket(at: now.addingTimeInterval(-600), input: 1_000_000, cached: 0, output: 0),
            ],
            sevenDayQuota: quota(used: 16, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(account: "account-b"),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            segment: segment
        )

        XCTAssertEqual(result.scannedBreakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(result.accountUsedPercent), 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), -2, accuracy: 0.0001)
        XCTAssertEqual(result.localSegmentStart, segment.start)
        XCTAssertTrue(result.switchedAccountDuringCycle)
    }

    func testSegmentStoreKeepsTheCurrentAccountBaselineAndResetsNextCycle() {
        let suiteName = "SharedAccountUsageSegmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-test"
        )

        let firstPending = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        XCTAssertFalse(firstPending.baselineReady)
        XCTAssertEqual(firstPending.effectiveCutoverReason, .initialActivation)
        let first = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-540),
            accountUsedPercent: 10
        )
        XCTAssertEqual(first.start, now.addingTimeInterval(-600))
        XCTAssertEqual(first.accountUsedBaselinePercent, 10)
        XCTAssertFalse(first.switchedAccountDuringCycle)
        XCTAssertTrue(first.baselineReady)
        XCTAssertEqual(first.accountUsedObservedPercent, 10)
        XCTAssertEqual(first.comparisonUpdatedAt, now.addingTimeInterval(-540))

        let unchangedQuotaPoll = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-300),
            accountUsedPercent: 10
        )
        XCTAssertEqual(unchangedQuotaPoll.comparisonUpdatedAt, first.comparisonUpdatedAt)

        let advancedQuota = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-120),
            accountUsedPercent: 11
        )
        XCTAssertEqual(advancedQuota.accountUsedObservedPercent, 11)
        XCTAssertEqual(advancedQuota.comparisonUpdatedAt, first.comparisonUpdatedAt)
        XCTAssertEqual(advancedQuota.quotaMovementPendingUntil, now)

        let switched = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(123),
            accountUsedPercent: 13
        )
        XCTAssertEqual(switched.start, now.addingTimeInterval(300))
        XCTAssertEqual(switched.accountUsedBaselinePercent, 13)
        XCTAssertTrue(switched.switchedAccountDuringCycle)
        XCTAssertFalse(switched.baselineReady)
        XCTAssertEqual(switched.baselineObservedAt, now.addingTimeInterval(123))

        let finalized = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(600),
            accountUsedPercent: 15
        )
        XCTAssertEqual(finalized.start, switched.start)
        XCTAssertEqual(finalized.accountUsedBaselinePercent, 15)
        XCTAssertTrue(finalized.baselineReady)
        XCTAssertEqual(finalized.baselineObservedAt, now.addingTimeInterval(600))

        let returnedToFirstAccount = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(600),
            accountUsedPercent: 15
        )
        XCTAssertEqual(returnedToFirstAccount.start, now.addingTimeInterval(600))
        XCTAssertEqual(returnedToFirstAccount.accountUsedBaselinePercent, 15)
        XCTAssertTrue(returnedToFirstAccount.switchedAccountDuringCycle)
        XCTAssertFalse(returnedToFirstAccount.baselineReady)
        XCTAssertNotEqual(
            highWatermarkKey(resetAt: resetAt).storageIdentifier,
            highWatermarkKey(
                resetAt: resetAt,
                segmentStart: returnedToFirstAccount.start
            ).storageIdentifier
        )

        let nextReset = resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let nextCycleStart = nextReset.addingTimeInterval(-7 * 24 * 60 * 60)
        let nextCycle = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: nextReset,
            cycleStart: nextCycleStart,
            quotaUpdatedAt: resetAt,
            accountUsedPercent: 2
        )
        XCTAssertEqual(nextCycle.start, nextCycleStart)
        XCTAssertEqual(nextCycle.accountUsedBaselinePercent, 2)
        XCTAssertFalse(nextCycle.switchedAccountDuringCycle)
        XCTAssertFalse(nextCycle.baselineReady)
        XCTAssertEqual(nextCycle.effectiveCutoverReason, .initialActivation)

        let nextCycleFinalized = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: nextReset,
            cycleStart: nextCycleStart,
            quotaUpdatedAt: resetAt.addingTimeInterval(60),
            accountUsedPercent: 2
        )
        XCTAssertTrue(nextCycleFinalized.baselineReady)
        XCTAssertEqual(nextCycleFinalized.accountUsedBaselinePercent, 2)
    }

    func testMidCycleFirstActivationNeverAttributesEarlierUnknownUsageToOthers() throws {
        let suiteName = "SharedAccountUsageFirstActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "first-activation-test",
            legacyStorageKeys: []
        )
        let activation = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(123),
            accountUsedPercent: 13
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: activation.comparisonUpdatedAt,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 1_700),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(123),
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now.addingTimeInterval(123),
            segment: activation
        )

        XCTAssertFalse(activation.baselineReady)
        XCTAssertEqual(activation.effectiveCutoverReason, .initialActivation)
        XCTAssertEqual(result.state, .awaitingAccountSwitchBaseline)
        XCTAssertNil(result.accountUsedPercent)
        XCTAssertEqual(result.localSharePercent, 0)
        XCTAssertNil(result.nonLocalDifferencePercent)
    }

    func testQuotaMovementsWaitForTheOpenBucketBoundaryAndOnePostPollScan() {
        let suiteName = "SharedAccountUsageMovementBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "movement-boundary-test",
            legacyStorageKeys: []
        )
        _ = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        let initial = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-300),
            accountUsedPercent: 10
        )
        let sameBucketChange = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(120),
            accountUsedPercent: 11
        )

        XCTAssertEqual(sameBucketChange.comparisonUpdatedAt, initial.comparisonUpdatedAt)
        XCTAssertEqual(sameBucketChange.accountUsedObservedPercent, 11)
        XCTAssertEqual(sameBucketChange.quotaMovementPendingUntil, now.addingTimeInterval(300))
        XCTAssertNil(
            store.advanceComparisonAcrossCompletedBoundaryIfNeeded(
                identity: identity(),
                resetAt: resetAt,
                quotaUpdatedAt: now.addingTimeInterval(240),
                accountUsedPercent: 11
            )
        )

        let released = store.advanceComparisonAcrossCompletedBoundaryIfNeeded(
            identity: identity(),
            resetAt: resetAt,
            quotaUpdatedAt: now.addingTimeInterval(360),
            accountUsedPercent: 11
        )
        XCTAssertEqual(released?.comparisonUpdatedAt, now.addingTimeInterval(360))
        XCTAssertEqual(released?.requiredLocalObservationAfter, now.addingTimeInterval(360))
        XCTAssertNil(released?.quotaMovementPendingUntil)
        XCTAssertNil(
            store.advanceComparisonAcrossCompletedBoundaryIfNeeded(
                identity: identity(),
                resetAt: resetAt,
                quotaUpdatedAt: now.addingTimeInterval(360),
                accountUsedPercent: 11
            )
        )
    }

    func testReleasedQuotaMovementRequiresAnExactObservationAfterTheReleasePoll() throws {
        let releasePoll = now.addingTimeInterval(360)
        let segment = SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: cycleStart,
            accountUsedBaselinePercent: 0,
            switchedAccountDuringCycle: false,
            baselineReady: true,
            baselineObservedAt: cycleStart,
            accountUsedObservedPercent: 11,
            comparisonUpdatedAt: releasePoll,
            requiredLocalObservationAfter: releasePoll
        )
        let stale = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 11, resetAt: resetAt),
            quotaUpdatedAt: releasePoll,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: releasePoll,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: releasePoll.addingTimeInterval(-1),
            segment: segment
        )
        XCTAssertEqual(stale.state, .preciseUsageStale)
        XCTAssertNil(stale.localSharePercent)

        let caughtUp = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 11, resetAt: resetAt),
            quotaUpdatedAt: releasePoll,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: releasePoll,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: releasePoll,
            segment: segment
        )
        XCTAssertNotEqual(caughtUp.state, .preciseUsageStale)
        XCTAssertNotNil(caughtUp.localSharePercent)
    }

    func testOpenBucketMovementCannotReleaseEarlyBecauseAnOlderComparisonBoundaryWasCrossed() {
        let suiteName = "SharedAccountUsageOldBoundaryMovementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "old-boundary-movement-test",
            legacyStorageKeys: []
        )
        _ = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 10
        )
        _ = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now,
            accountUsedPercent: 10
        )
        let movement = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(390),
            accountUsedPercent: 11
        )
        XCTAssertEqual(movement.comparisonUpdatedAt, now)
        XCTAssertEqual(movement.quotaMovementPendingUntil, now.addingTimeInterval(600))
        XCTAssertNil(
            store.advanceComparisonAcrossCompletedBoundaryIfNeeded(
                identity: identity(),
                resetAt: resetAt,
                quotaUpdatedAt: now.addingTimeInterval(390),
                accountUsedPercent: 11
            ),
            "crossing an older comparison boundary must not release a movement in the current open bucket"
        )
        XCTAssertNotNil(
            store.advanceComparisonAcrossCompletedBoundaryIfNeeded(
                identity: identity(),
                resetAt: resetAt,
                quotaUpdatedAt: now.addingTimeInterval(660),
                accountUsedPercent: 11
            )
        )
    }

    func testResetTimestampDriftKeepsCanonicalCycleAndHighWatermarkIdentity() throws {
        let suiteName = "SharedAccountUsageResetDriftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-reset-drift-test",
            legacyStorageKeys: []
        )
        let first = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(-600),
            accountUsedPercent: 8
        )
        let driftedReset = resetAt.addingTimeInterval(90)
        let drifted = store.resolve(
            identity: identity(),
            resetAt: driftedReset,
            cycleStart: driftedReset.addingTimeInterval(-7 * 24 * 60 * 60),
            quotaUpdatedAt: now,
            accountUsedPercent: 9
        )

        XCTAssertEqual(first.cycleResetAt, resetAt)
        XCTAssertEqual(drifted.cycleResetAt, resetAt)
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 9, resetAt: driftedReset),
            quotaUpdatedAt: drifted.comparisonUpdatedAt,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            segment: drifted
        )
        XCTAssertEqual(result.cycleEnd, resetAt)
        XCTAssertEqual(try XCTUnwrap(result.highWatermarkKey).resetAt, resetAt)
    }

    func testOpenBucketIsPersistedAndRemainsPendingAfterSessionArchive() throws {
        let quotaObservation = now.addingTimeInterval(120)
        let openBucket = bucket(at: now, input: 1_000_000, cached: 0, output: 0)
        let first = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [openBucket],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: quotaObservation,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: quotaObservation,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: quotaObservation
        )
        let candidate = try XCTUnwrap(first.highWatermarkCandidate)
        XCTAssertEqual(first.scannedBreakdown.inputTokens, 0)
        XCTAssertEqual(candidate.breakdown.inputTokens, 1_000_000)
        XCTAssertEqual(first.state, .awaitingQuotaRefresh)

        let afterArchive = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 8, resetAt: resetAt),
            quotaUpdatedAt: quotaObservation,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(360),
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now.addingTimeInterval(360),
            highWatermark: candidate
        )
        XCTAssertEqual(afterArchive.breakdown.inputTokens, 0)
        XCTAssertEqual(afterArchive.state, .awaitingQuotaRefresh)
        XCTAssertTrue(afterArchive.usedHighWatermark == false)

        let quotaCaughtUp = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [],
            sevenDayQuota: quota(used: 9, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(360),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(360),
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now.addingTimeInterval(360),
            highWatermark: candidate
        )
        XCTAssertEqual(quotaCaughtUp.breakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(quotaCaughtUp.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertTrue(quotaCaughtUp.usedHighWatermark)
    }

    func testPendingAccountSwitchBaselineExcludesPreBoundaryUsageFromAttribution() throws {
        let suiteName = "SharedAccountUsageSegmentBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "segment-boundary-test"
        )
        _ = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now,
            accountUsedPercent: 10
        )

        // Account B is first observed at 12:02. Its token segment begins at
        // 12:05, but the quota baseline is deliberately not frozen at 12:02.
        let pending = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(120),
            accountUsedPercent: 13
        )
        XCTAssertEqual(pending.start, now.addingTimeInterval(300))
        XCTAssertFalse(pending.baselineReady)

        let pendingResult = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: now, input: 2_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(120),
            historyIdentity: identity(account: "account-b"),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(240),
            segment: pending
        )
        XCTAssertEqual(pendingResult.state, .awaitingAccountSwitchBaseline)
        XCTAssertEqual(pendingResult.localSharePercent, 0)
        XCTAssertNil(pendingResult.nonLocalDifferencePercent)

        // The 12:10 quota snapshot becomes the baseline. Usage in the 12:00
        // bucket (including a 12:04 call) is therefore excluded from both the
        // local numerator and the account delta.
        let finalized = store.resolve(
            identity: identity(account: "account-b"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(600),
            accountUsedPercent: 16
        )
        XCTAssertTrue(finalized.baselineReady)
        XCTAssertEqual(finalized.start, now.addingTimeInterval(300))
        XCTAssertEqual(finalized.accountUsedBaselinePercent, 16)

        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [
                bucket(at: now, input: 2_000_000, cached: 0, output: 0),
                bucket(at: now.addingTimeInterval(600), input: 1_000_000, cached: 0, output: 0),
            ],
            sevenDayQuota: quota(used: 17, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(900),
            historyIdentity: identity(account: "account-b"),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now.addingTimeInterval(900),
            segment: finalized
        )
        XCTAssertEqual(result.scannedBreakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(result.accountUsedPercent), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertLessThan(try XCTUnwrap(result.nonLocalDifferencePercent), 0)
    }

    func testLegacySameCycleSegmentStartsWithASyntheticPendingCutover() throws {
        let suiteName = "SharedAccountUsageLegacySegmentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let homeIdentifier = SHA256.hash(data: Data("home-a".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        defaults.set(
            try JSONEncoder().encode([
                homeIdentifier: LegacySegmentHeaderFixture(resetAt: resetAt),
            ]),
            forKey: "sharedAccountUsageAttributionSegmentsV03"
        )
        let store = UserDefaultsSharedAccountUsageSegmentStore(defaults: defaults)

        let cutover = store.resolve(
            identity: identity(account: "account-a"),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(123),
            accountUsedPercent: 13
        )

        XCTAssertFalse(cutover.switchedAccountDuringCycle)
        XCTAssertEqual(cutover.effectiveCutoverReason, .legacyMigration)
        XCTAssertFalse(cutover.baselineReady)
        XCTAssertEqual(cutover.start, now.addingTimeInterval(300))
        XCTAssertEqual(cutover.comparisonUpdatedAt, now.addingTimeInterval(123))
    }

    func testContinuityGapStartsOnlyAtRecoveredCoverageAndWaitsForALaterQuotaBaseline() {
        let suiteName = "SharedAccountUsageContinuityGapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "continuity-gap-test",
            legacyStorageKeys: []
        )
        let gapDetectedAt = now.addingTimeInterval(60)
        let gapID = UUID()
        let recoveredCoverageAt = now.addingTimeInterval(720)
        let quotaAtRecovery = now.addingTimeInterval(750)
        let pending = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: quotaAtRecovery,
            accountUsedPercent: 14,
            gapID: gapID,
            gapDetectedAt: gapDetectedAt,
            recoveredCoverageAt: recoveredCoverageAt
        )

        XCTAssertEqual(pending.start, now.addingTimeInterval(900))
        XCTAssertFalse(pending.baselineReady)
        XCTAssertFalse(pending.switchedAccountDuringCycle)
        XCTAssertEqual(pending.effectiveCutoverReason, .continuityGap)
        XCTAssertEqual(pending.cutoverDetectedAt, gapDetectedAt)
        XCTAssertEqual(pending.continuityGapID, gapID)

        let tooEarly = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(840),
            accountUsedPercent: 15
        )
        XCTAssertFalse(tooEarly.baselineReady)

        let finalized = store.resolve(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(960),
            accountUsedPercent: 16
        )
        XCTAssertTrue(finalized.baselineReady)
        XCTAssertEqual(finalized.accountUsedBaselinePercent, 16)
        XCTAssertEqual(finalized.effectiveCutoverReason, .continuityGap)
        XCTAssertFalse(finalized.switchedAccountDuringCycle)

        let laterSuccessfulScanForTheSameGap = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(960),
            accountUsedPercent: 16,
            gapID: gapID,
            gapDetectedAt: gapDetectedAt,
            recoveredCoverageAt: now.addingTimeInterval(1_020)
        )
        XCTAssertTrue(laterSuccessfulScanForTheSameGap.baselineReady)
        XCTAssertEqual(laterSuccessfulScanForTheSameGap.start, pending.start)
        XCTAssertEqual(laterSuccessfulScanForTheSameGap.cutoverDetectedAt, gapDetectedAt)
    }

    func testSecondContinuityFailureRebuildsAnUnfinishedCutoverAtTheLaterRecovery() {
        let suiteName = "SharedAccountUsageSecondContinuityGapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(
            defaults: defaults,
            storageKey: "second-continuity-gap-test",
            legacyStorageKeys: []
        )
        let firstGapID = UUID()
        let secondGapID = UUID()
        let first = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(120),
            accountUsedPercent: 10,
            gapID: firstGapID,
            gapDetectedAt: now.addingTimeInterval(60),
            recoveredCoverageAt: now.addingTimeInterval(420)
        )
        let second = store.beginContinuityGapCutover(
            identity: identity(),
            resetAt: resetAt,
            cycleStart: cycleStart,
            quotaUpdatedAt: now.addingTimeInterval(900),
            accountUsedPercent: 13,
            gapID: secondGapID,
            gapDetectedAt: now.addingTimeInterval(-60),
            recoveredCoverageAt: now.addingTimeInterval(1_020)
        )

        XCTAssertFalse(first.baselineReady)
        XCTAssertFalse(second.baselineReady)
        XCTAssertGreaterThan(second.start, first.start)
        XCTAssertEqual(second.start, now.addingTimeInterval(1_200))
        XCTAssertEqual(second.cutoverDetectedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(second.continuityGapID, secondGapID)
    }

    func testPendingBaselinePersistsCompletedPostBoundaryBucketsWithoutComparingThemEarly() throws {
        let segmentStart = now.addingTimeInterval(-300)
        let pending = SharedAccountUsageSegment(
            cycleResetAt: resetAt,
            start: segmentStart,
            accountUsedBaselinePercent: 13,
            switchedAccountDuringCycle: true,
            baselineReady: false,
            baselineObservedAt: now.addingTimeInterval(-600),
            accountUsedObservedPercent: 13,
            comparisonUpdatedAt: now.addingTimeInterval(-600)
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: segmentStart, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(-600),
            historyIdentity: identity(account: "account-b"),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now,
            segment: pending
        )

        XCTAssertEqual(result.state, .awaitingAccountSwitchBaseline)
        XCTAssertEqual(result.breakdown.inputTokens, 0)
        XCTAssertEqual(result.scannedBreakdown.inputTokens, 0)
        XCTAssertEqual(try XCTUnwrap(result.highWatermarkCandidate).breakdown.inputTokens, 1_000_000)
        XCTAssertNil(result.accountUsedPercent)
        XCTAssertEqual(result.localSharePercent, 0)
        XCTAssertNil(result.nonLocalDifferencePercent)
    }

    func testStoredBucketsNewerThanQuotaAreNotComparedUntilQuotaCatchesUp() throws {
        let comparedBucket = cycleStart
        let futureBucket = now.addingTimeInterval(-300)
        let stored = highWatermarkRecord(
            bins: [
                bucket(at: comparedBucket, input: 1_000_000, cached: 0, output: 0),
                bucket(at: futureBucket, input: 9_000_000, cached: 0, output: 0),
            ],
            observedAt: now.addingTimeInterval(-60)
        )
        let result = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: comparedBucket, input: 1_000_000, cached: 0, output: 0)],
            sevenDayQuota: quota(used: 5, resetAt: resetAt),
            quotaUpdatedAt: now.addingTimeInterval(-600),
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 100),
            tier: .twentyXPro,
            model: .gpt56Sol,
            now: now,
            preciseUsageFresh: true,
            preciseUsageGeneratedAt: now,
            highWatermark: stored
        )

        XCTAssertEqual(stored.breakdown.inputTokens, 10_000_000)
        XCTAssertEqual(result.breakdown.inputTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(result.localComparableCostUSD), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.localSharePercent), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.nonLocalDifferencePercent), 0, accuracy: 0.0001)
    }

    func testPresentationShowsTheDivisionFormulaAndSignedNegativeDifference() throws {
        let result = estimate(
            accountUsed: 5,
            radarTotal: 46,
            tier: .twentyXPro,
            rowTier: "20x Pro",
            model: .gpt56Terra
        )
        let presentation = SharedAccountUsageAttributionPresentation(result: result)

        XCTAssertTrue(presentation.localFormula.contains("$4.60 ÷ $46.00 × 100 = 10.0%"))
        XCTAssertTrue(presentation.differenceFormula.contains("5.0% − 10.0% = -5.0%"))
        XCTAssertTrue(presentation.summaryLine.contains("差 -5.0%"))
    }

    func testHighWatermarkKeyChangesWithCycleAccountAndSegmentButSharesAcrossPricingChoices() {
        let base = highWatermarkKey(resetAt: resetAt)
        XCTAssertNotEqual(base.storageIdentifier, highWatermarkKey(resetAt: resetAt.addingTimeInterval(7 * 24 * 60 * 60)).storageIdentifier)
        XCTAssertNotEqual(base.storageIdentifier, highWatermarkKey(resetAt: resetAt, segmentStart: cycleStart.addingTimeInterval(300)).storageIdentifier)
        XCTAssertNotEqual(base.storageIdentifier, highWatermarkKey(resetAt: resetAt, account: "account-b").storageIdentifier)
        XCTAssertEqual(base.storageIdentifier, highWatermarkKey(resetAt: resetAt, tier: .fiveXPro).storageIdentifier)
        XCTAssertEqual(base.storageIdentifier, highWatermarkKey(resetAt: resetAt, model: .gpt56Luna).storageIdentifier)
        let currentRevision = highWatermarkKey(resetAt: resetAt, revision: .currentOfficial)
        XCTAssertNotEqual(base.priceRevision, currentRevision.priceRevision)
        XCTAssertEqual(base.storageIdentifier, currentRevision.storageIdentifier)
    }

    func testSameCycleDoesNotMoveBackwardWhenRadarSwitchesPriceRevision() throws {
        let store = InMemoryHighWatermarkStore()
        let oldResult = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 400_000, output: 200_000)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-30", tier: "20x Pro", fiveHour: nil, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )
        let oldKey = try XCTUnwrap(oldResult.highWatermarkKey)
        let oldCandidate = try XCTUnwrap(oldResult.highWatermarkCandidate)
        _ = store.merge(oldCandidate, for: oldKey)

        let currentRaw = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 500_000, cached: 200_000, output: 100_000)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-31", tier: "20x Pro", fiveHour: nil, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now
        )
        let currentKey = try XCTUnwrap(currentRaw.highWatermarkKey)
        XCTAssertEqual(oldKey.storageIdentifier, currentKey.storageIdentifier)

        let protected = SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 500_000, cached: 200_000, output: 100_000)],
            sevenDayQuota: quota(used: 13, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try radar(date: "2026-07-31", tier: "20x Pro", fiveHour: nil, sevenDay: 46),
            tier: .twentyXPro,
            model: .gpt56Terra,
            now: now,
            highWatermark: store.record(for: currentKey)
        )

        XCTAssertEqual(try XCTUnwrap(currentRaw.localComparableCostUSD), 2.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(protected.localComparableCostUSD), 4.6, accuracy: 0.0001)
        XCTAssertTrue(protected.usedHighWatermark)
    }

    private func estimate(
        accountUsed: Int,
        radarTotal: Double,
        tier: SharedAccountRadarTier,
        rowTier: String,
        model: OfficialAPIPriceModel
    ) -> SharedAccountUsageAttributionResult {
        SharedAccountUsageAttributionEstimator.estimate(
            enabled: true,
            preciseUsageReady: true,
            recentBins: [bucket(at: cycleStart, input: 1_000_000, cached: 400_000, output: 200_000)],
            sevenDayQuota: quota(used: accountUsed, resetAt: resetAt),
            quotaUpdatedAt: now,
            historyIdentity: identity(),
            radar: try! radar(date: "2026-07-30", tier: rowTier, fiveHour: nil, sevenDay: radarTotal),
            tier: tier,
            model: model,
            now: now
        )
    }

    private func bucket(
        at date: Date,
        input: Int,
        cached: Int,
        output: Int
    ) -> TokenCacheBucket {
        TokenCacheBucket(
            start: date,
            breakdown: TokenCacheBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: 0,
                totalTokens: input + output,
                calls: 1
            )
        )
    }

    private func attributionEvent(
        id: String,
        at date: Date,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        model: String? = nil
    ) -> TokenCacheAttributionEvent {
        TokenCacheAttributionEvent(
            id: id,
            start: date,
            model: model,
            breakdown: TokenCacheBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: 0,
                totalTokens: input + output,
                calls: 1
            )
        )
    }

    private func quota(used: Int, resetAt: Date?) -> AccountQuotaWindow {
        AccountQuotaWindow(label: "7d", usedPercent: used, resetsAt: resetAt)
    }

    private func identity(account: String = "account-a") -> QuotaHistoryIdentity {
        QuotaHistoryIdentity(
            homeIdentity: "home-a",
            stableAccountKey: account,
            planType: "Pro",
            limitID: "codex"
        )!
    }

    private func highWatermarkRecord(
        bins: [TokenCacheBucket],
        cycleResetAt: Date? = nil,
        priceRevision: SharedAccountRadarPriceRevision = .radar20260730,
        observedAt: Date,
        scopeIdentifier: String? = nil,
        quotaObservationFresh: Bool = true
    ) -> SharedAccountUsageHighWatermarkRecord {
        SharedAccountUsageHighWatermarkRecord(
            cycleResetAt: cycleResetAt ?? resetAt,
            bins: bins,
            priceRevision: priceRevision,
            observedAt: observedAt,
            scopeIdentifier: scopeIdentifier,
            quotaObservationFresh: quotaObservationFresh
        )
    }

    private func radar(
        date: String,
        basisDate: String? = nil,
        tier: String,
        fiveHour: Double?,
        sevenDay: Double?,
        sevenDayPolicy: String = "direct_quota_api",
        sourceKind: String? = nil
    ) throws -> CodexRadarQuotaRadar {
        var row: [String: Any] = [
            "tier": tier,
            "basis": "distributed-radar",
        ]
        if let fiveHour { row["five_h"] = fiveHour }
        if let sevenDay { row["seven_d"] = sevenDay }
        var object: [String: Any] = [
            "date": date,
            "source": "Codex Radar",
            "updated_at": "\(date)T08:20:35Z",
            "basis_date": basisDate ?? date,
            "basis_window": "secondary_7d",
            "basis_window_label": "7d",
            "five_hour_policy": "temporarily_paused_hidden",
            "seven_day_policy": sevenDayPolicy,
            "rows": [row],
        ]
        if let sourceKind { object["source_kind"] = sourceKind }
        return try JSONDecoder.codexRadar.decode(
            CodexRadarQuotaRadar.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func highWatermarkKey(
        resetAt: Date,
        segmentStart: Date? = nil,
        account: String = "account-a",
        tier: SharedAccountRadarTier = .twentyXPro,
        model: OfficialAPIPriceModel = .gpt56Terra,
        revision: SharedAccountRadarPriceRevision = .radar20260730
    ) -> SharedAccountUsageHighWatermarkKey {
        SharedAccountUsageHighWatermarkKey(
            homeIdentity: "home-a",
            stableAccountKey: account,
            planType: "Pro",
            limitID: "codex",
            resetAt: resetAt,
            segmentStart: segmentStart ?? resetAt.addingTimeInterval(-7 * 24 * 60 * 60),
            tier: tier,
            model: model,
            priceRevision: revision
        )
    }
}

private final class InMemoryHighWatermarkStore: SharedAccountUsageHighWatermarkStoring {
    private var values: [String: SharedAccountUsageHighWatermarkRecord] = [:]

    func record(for key: SharedAccountUsageHighWatermarkKey) -> SharedAccountUsageHighWatermarkRecord? {
        values[key.storageIdentifier]
    }

    func merge(
        _ candidate: SharedAccountUsageHighWatermarkRecord,
        for key: SharedAccountUsageHighWatermarkKey
    ) -> SharedAccountUsageHighWatermarkRecord {
        let identifier = key.storageIdentifier
        let merged = values[identifier]?.merging(candidate) ?? candidate
        values[identifier] = merged
        return merged
    }
}

private struct LegacySegmentHeaderFixture: Codable {
    let resetAt: Date
}
