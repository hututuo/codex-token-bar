import XCTest
@testable import CodexTokenBar

final class QuotaHistoryConsumerProtectionTests: XCTestCase {
    func testWeeklyAttributionAcceptsHighUsedForwardBoundaryAndRejectsBackwardResetAsANewCycle() throws {
        let suite = "QuotaHistoryConsumerProtection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSharedAccountUsageSegmentStore(defaults: defaults, storageKey: "fixture")
        let identity = try XCTUnwrap(QuotaHistoryIdentity(homeIdentity: "fixture", stableAccountKey: "sub:fixture", planType: "Plus", limitID: "codex"))
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = start.addingTimeInterval(7 * 86400)
        _ = store.resolve(identity: identity, resetAt: reset, cycleStart: start, quotaUpdatedAt: start, accountUsedPercent: 90)
        let backward = store.resolve(identity: identity, resetAt: reset.addingTimeInterval(-1801), cycleStart: start, quotaUpdatedAt: start.addingTimeInterval(300), accountUsedPercent: 0)
        XCTAssertEqual(backward.cycleResetAt, reset)
        let forward = store.resolve(identity: identity, resetAt: reset.addingTimeInterval(1801), cycleStart: start.addingTimeInterval(1801), quotaUpdatedAt: start.addingTimeInterval(600), accountUsedPercent: 80)
        XCTAssertEqual(forward.cycleResetAt, reset.addingTimeInterval(1801))
    }

    @MainActor
    func testCycleIDProvenancePreservesExhaustionAndSameCycleCorrectionsWithoutNegativeUse() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        // A confirmed exhaustion followed by a same-cycle revision. No reset
        // timestamp is required when the backend supplies a cycle identity.
        let values: [Double] = [100, 0, 99, 98]
        let bins = values.indices.map { BinUsage(start: start.addingTimeInterval(Double($0) * 300), tokens: 0, calls: 0) }
        let observations = values.enumerated().map {
            QuotaHistoryObservation(observedAt: bins[$0.offset].start, remainingPercent: $0.element, resetsAt: nil, cycleID: "confirmed-cycle")
        }
        let prepared = RecentChartPreparedData(
            range: .twentyFourHours, bins: bins, bucketInterval: 300,
            maxTokens: 1, maxCalls: 1, tokenTotal: 0, callTotal: 0,
            recentCacheBreakdown: .empty, cacheBreakdowns: Array(repeating: .empty, count: 4),
            observedCacheHitRates: Array(repeating: nil, count: 4),
            fiveHourRemainingPercents: values.map(Optional.some), sevenDayRemainingPercents: values.map(Optional.some),
            fiveHourQuotaObservations: observations, sevenDayQuotaObservations: observations,
            quotaObservationProvenanceAvailable: true,
            latestFiveHourRemaining: 98, latestSevenDayRemaining: 98,
            hasCacheCalls: false, hasFiveHourQuota: true, hasSevenDayQuota: true,
            markerIndices: []
        )
        let selection = try XCTUnwrap(prepared.quotaConsumptionSelection(startIndex: 0, endIndex: 3, priceCard: .officialAPI(.gpt56Sol)))
        XCTAssertEqual(selection.fiveHour.quotaDropBasis, .observed)
        XCTAssertEqual(selection.sevenDay.quotaDropBasis, .observed)
        XCTAssertEqual(selection.fiveHour.quotaDropPercent, 101)
        XCTAssertEqual(selection.sevenDay.quotaDropPercent, 101)
    }
}
