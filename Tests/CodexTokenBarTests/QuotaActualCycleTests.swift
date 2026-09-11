import XCTest
@testable import CodexTokenBar

final class QuotaActualCycleTests: XCTestCase {
    private func d(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + value) }
    private func o(_ at: Double, _ used: Int, _ reset: Double) -> QuotaCycleObservation {
        .init(at: d(at), usedPercent: used, resetsAt: d(reset))
    }

    func testFirstObservedPeriodNeverBackdatesSevenDays() {
        let cycles = QuotaActualCycleProjector.project([o(0, 20, 10000), o(60, 21, 10000)], now: d(70))
        XCTAssertEqual(cycles.count, 1)
        XCTAssertNil(cycles[0].start)
        XCTAssertEqual(cycles[0].certainStart, d(0))
        XCTAssertEqual(cycles[0].certainEnd, d(60))
        XCTAssertFalse(cycles[0].hasCompleteBoundaries)
    }

    func testConfirmedEarlyResetSeparatesBothCertainInteriors() {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(300, 65, 10000), o(420, 1, 20000), o(480, 2, 20002)
        ], now: d(500))
        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles[0].certainStart, d(420))
        XCTAssertEqual(cycles[1].certainEnd, d(300))
        XCTAssertEqual(cycles[0].start, cycles[1].end)
        XCTAssertTrue(cycles[1].endedEarly)
        XCTAssertFalse(cycles[0].start!.isExact)
    }

    func testUnconfirmedOrCorrectionNeverCreatesActualCycle() {
        for observations in [
            [o(0, 50, 10000), o(300, 0, 20000)],
            [o(0, 50, 10000), o(300, 51, 20000), o(420, 52, 20000)],
            [o(0, 50, 10000), o(300, 0, 9000), o(420, 1, 9000)],
            [o(0, 60, 10000), o(300, 1, 20000), o(420, 60, 20000)],
            [o(0, 60, 10000), o(300, 2, 20000), o(420, 1, 20000)]
        ] {
            let cycles = QuotaActualCycleProjector.project(observations, now: d(500))
            XCTAssertEqual(cycles.count, 1)
            XCTAssertTrue(cycles[0].resetChangePending)
            XCTAssertEqual(cycles[0].certainEnd, d(0))
        }
    }

    func testJitterAndDuplicateFreshnessCannotConfirmReset() {
        let jitter = QuotaActualCycleProjector.project([o(0, 50, 10000), o(60, 51, 10002), o(120, 52, 9999)], now: d(180))
        XCTAssertEqual(jitter.count, 1)
        XCTAssertFalse(jitter[0].resetChangePending)
        let duplicate = QuotaActualCycleProjector.project([o(0, 50, 10000), o(300, 0, 20000), o(300, 1, 20000)], now: d(400))
        XCTAssertEqual(duplicate.count, 1)
        XCTAssertTrue(duplicate[0].resetChangePending)
    }

    func testWeakDropAndCrossAppEchoDoNotConfirmEarlyReset() {
        for samples in [
            [o(0, 60, 10000), o(300, 59, 20000), o(420, 59, 20000)],
            [o(0, 60, 10000), o(300, 0, 20000), o(303, 0, 20000)],
            [o(0, 60, 10000), o(300, 0, 20000), o(303, 0, 20000), o(350, 60, 10000)]
        ] {
            XCTAssertEqual(QuotaActualCycleProjector.project(samples, now: d(500)).count, 1)
        }
        let sustained = [o(0, 60, 10000), o(300, 0, 20000), o(303, 0, 20000), o(360, 1, 20000)]
        XCTAssertEqual(QuotaActualCycleProjector.project(sustained, now: d(500)).count, 2)
    }

    func testNaturalExpiryAndLongOfflineGapDoNotInventPeriods() {
        let natural = QuotaActualCycleProjector.project([o(0, 50, 600), o(300, 90, 600), o(660, 5, 605400)], now: d(700))
        XCTAssertEqual(natural.count, 2)
        XCTAssertEqual(natural[0].start, .exact(d(600)))
        XCTAssertEqual(natural[1].end, .exact(d(600)))
        let offline = QuotaActualCycleProjector.project([o(0, 50, 600), o(1300000, 5, 1700000)], now: d(1300100))
        XCTAssertEqual(offline.count, 2)
        XCTAssertNil(offline[0].start)
        XCTAssertEqual(offline[1].end, .exact(d(600)))
    }

    func testExpiredObservationIsExcluded() {
        let cycles = QuotaActualCycleProjector.project([o(0, 50, 600), o(700, 50, 600)], now: d(800))
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].lastObservedAt, d(0))
        XCTAssertLessThanOrEqual(cycles[0].certainStart, cycles[0].certainEnd)
    }

    func testClockAloneDoesNotMakeObservedExpiryExact() {
        let cycles = QuotaActualCycleProjector.project([o(0, 50, 600), o(300, 80, 600)], now: d(700))
        XCTAssertEqual(cycles[0].end, .init(earliest: d(300), latest: d(600)))
        XCTAssertFalse(cycles[0].isCurrent)
    }

    func testPendingResetDoesNotKeepExpiredPeriodCurrent() {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 600), o(300, 55, 600), o(420, 1, 1600)
        ], now: d(700))
        XCTAssertEqual(cycles.count, 1)
        XCTAssertTrue(cycles[0].resetChangePending)
        XCTAssertFalse(cycles[0].isCurrent)
        XCTAssertEqual(cycles[0].end, .init(earliest: d(300), latest: d(600)))
        XCTAssertEqual(cycles[0].certainEnd, d(300))
    }

    func testUncertainResetMinutesExcludedFromBothInteriorTotals() {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(300, 65, 10000), o(420, 1, 20000), o(480, 2, 20000)
        ], now: d(500))
        func breakdown(_ amount: Int) -> TokenCacheBreakdown {
            .init(inputTokens: amount, cachedInputTokens: 0, outputTokens: 0,
                reasoningOutputTokens: 0, totalTokens: amount, calls: 1)
        }
        let minutes = (0..<5).map { i in
            TokenCacheBucket(start: d(300 + Double(i * 60)), breakdown: breakdown((i + 1) * 100))
        }
        let events = [
            TokenCacheAttributionEvent(id: "inside", start: d(0), model: "gpt-5.6-sol", breakdown: breakdown(100)),
            TokenCacheAttributionEvent(id: "edge", start: d(300), model: "gpt-5.6-sol",
                breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)
        ]
        let old = QuotaCycleUsage(events: events, cycle: cycles[1], coverageEnd: d(600))
        let current = QuotaCycleUsage(events: events, cycle: cycles[0], coverageEnd: d(600))
        XCTAssertEqual(old.total.totalTokens, 100)
        XCTAssertEqual(current.total.totalTokens, 300)
        XCTAssertEqual(old.unassignedTokens, 300)
        XCTAssertEqual(current.unassignedTokens, 300)
    }

    func testHistoryProjectionRestoresAndIsolatesAccountIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        func snapshot(_ account: String, _ at: Double, _ used: Int, _ reset: Double) -> AccountQuotaSnapshot {
            AccountQuotaSnapshot(sevenDay: .init(label: "7d", usedPercent: used, resetsAt: d(reset)),
                planType: "Plus", limitName: "codex", accountName: account, updatedAt: d(at),
                historyIdentity: .init(homeIdentity: "/fixture", stableAccountKey: account, planType: "Plus", limitID: "codex"))
        }
        let database = QuotaHistoryDatabase(databaseURL: url)
        let records = [snapshot("a", 0, 50, 10000), snapshot("a", 300, 60, 10000),
                       snapshot("a", 420, 1, 20000), snapshot("a", 480, 2, 20000),
                       snapshot("b", 500, 80, 25000)]
        for record in records { XCTAssertTrue(try database.record(record)) }
        let restarted = QuotaHistoryDatabase(databaseURL: url)
        let a = try restarted.loadSnapshot(for: records[3], now: d(550))
        let b = try restarted.loadSnapshot(for: records[4], now: d(550))
        XCTAssertEqual(a.actualCycles.count, 2)
        XCTAssertEqual(b.actualCycles.count, 1)
        XCTAssertEqual(a.cycleIdentity?.stableAccountKey, "a")
        XCTAssertEqual(b.cycleIdentity?.stableAccountKey, "b")
        XCTAssertNil(b.actualCycles[0].start)
    }
}
