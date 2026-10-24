import XCTest
@testable import CodexTokenBar

/// Synthetic successful observations, not a replay of a customer's database.
final class QuotaActualCycleRegressionTests: XCTestCase {
    private func d(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
    private func o(_ at: Double, _ used: Int, _ reset: Double) -> QuotaCycleObservation {
        .init(at: d(at), usedPercent: used, resetsAt: d(reset))
    }
    private func breakdown(_ tokens: Int) -> TokenCacheBreakdown {
        .init(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0,
              reasoningOutputTokens: 0, totalTokens: tokens, calls: 1)
    }
    private func event(_ at: Double, _ tokens: Int) -> TokenCacheAttributionEvent {
        .init(id: "fixture:\(at)", start: d(at), model: "gpt-5.6-sol", breakdown: breakdown(tokens))
    }

    func testTenSecondCorrectionsKeepFreshUsageAndBillingCoverage() throws {
        for shift in [-10.0, 10.0] {
            let cycles = QuotaActualCycleProjector.project([
                o(0, 3, 10000), o(60, 4, 10000 + shift),
                o(300, 20, 10000 + shift), o(600, 50, 10000 + shift)
            ], now: d(900))
            let current = try XCTUnwrap(cycles.first)
            XCTAssertEqual(cycles.count, 1)
            XCTAssertEqual(current.lastObservedAt, d(600), "shift \(shift)")
            XCTAssertEqual(current.certainEnd, d(600), "shift \(shift)")
            XCTAssertEqual(current.scheduledResetAt, d(10000 + shift))
            let events = [event(0, 100), event(300, 200), event(600, 400)]
            XCTAssertEqual(QuotaCycleUsage(events: events, cycle: current, coverageEnd: d(300)).total.totalTokens, 100)
            XCTAssertEqual(QuotaCycleUsage(events: events, cycle: current, coverageEnd: d(900)).total.totalTokens, 300,
                           "coverage may advance to the last observation, never blindly to now")
        }
    }

    func testContinuous502ObservationsCompareTrueResetWithLatestUsedValue() throws {
        for shift in [-10.0, 0, 10.0] {
            var samples = (0..<500).map { index in
                o(Double(index * 60), 3 + index * 47 / 499, 100000 + (index == 0 ? 0 : shift))
            }
            samples += [o(30000, 0, 200000), o(30060, 1, 200000)]
            let cycles = QuotaActualCycleProjector.project(samples, now: d(30100))
            XCTAssertEqual(cycles.count, 2, "shift \(shift)")
            guard cycles.count == 2 else { continue }
            XCTAssertTrue(cycles[1].endedEarly)
            XCTAssertEqual(cycles[1].end, .exact(d(30000)))
            XCTAssertEqual(cycles[0].start, cycles[1].end)
            XCTAssertEqual(cycles[0].lastObservedAt, d(30060))
        }
    }

    func testCumulativeSubToleranceDriftDoesNotBecomeAResetOrFreeze() throws {
        for direction in [-1.0, 1.0] {
            let samples = (0...251).map { index in
                o(Double(index * 60), 20 + index / 10, 200000 + direction * Double(index * 4))
            }
            let cycles = QuotaActualCycleProjector.project(samples, now: d(15100))
            XCTAssertEqual(cycles.count, 1)
            let current = try XCTUnwrap(cycles.first)
            XCTAssertEqual(current.certainEnd, d(15060))
            XCTAssertEqual(current.scheduledResetAt, samples.last?.resetsAt)
            XCTAssertFalse(current.resetChangePending)
        }
    }

    func testResetScheduleNeverGatesARealDrop() throws {
        for shift in [-901.0, -900, -10, -5, 0, 5, 10, 900, 901, 7200] {
            let cycles = QuotaActualCycleProjector.project([
                o(0, 50, 10000), o(60, 0, 10000 + shift), o(120, 1, 10000 + shift)
            ], now: d(180))
            XCTAssertEqual(cycles.count, 2, "shift \(shift)")
            XCTAssertEqual(cycles.first?.start, .exact(d(60)))
            XCTAssertEqual(cycles.first?.certainEnd, d(120))
        }
    }

    func testStableNewResetConsumptionReturningToOldUsageDoesNotUndoCycle() throws {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(60, 30, 20000), o(180, 31, 20000),
            o(2400, 50, 20000), o(2460, 51, 20000)
        ], now: d(2500))
        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles.first?.certainEnd, d(2460))
    }

    func testAbruptUsageReturnWithOldResetReallyWithdrawsCandidate() throws {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(60, 30, 20000), o(180, 31, 20000),
            o(2400, 50, 10000), o(2460, 51, 10000)
        ], now: d(2500), consumption: { _, _ in .absent })
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles.first?.lastObservedAt, d(2460))
        XCTAssertFalse(try XCTUnwrap(cycles.first).resetChangePending)
    }

    func testIdleResetAndRepeatedResponsesSwitchImmediately() throws {
        for readings in [
            [o(0, 50, 10000), o(300, 0, 20000), o(300, 1, 20000)],
            [o(0, 50, 10000), o(300, 0, 20000), o(360, 0, 20000), o(600, 0, 20000)],
            [o(0, 50, 10000), o(300, 0, 20000), o(350, 1, 20000)]
        ] {
            let cycles = QuotaActualCycleProjector.project(readings, now: d(700))
            XCTAssertEqual(cycles.count, 2)
            let current = try XCTUnwrap(cycles.first)
            XCTAssertFalse(current.resetChangePending)
            XCTAssertEqual(current.lastObservedAt, readings.last?.at)
            XCTAssertEqual(current.certainStart, d(300))
        }
    }

    func testImmediateBoundaryHasNoPendingCost() throws {
        let current = try XCTUnwrap(QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(300, 0, 20000), o(600, 0, 20000)
        ], now: d(900)).first)
        XCTAssertEqual(current.certainStart, d(300))
        let usage = QuotaCycleUsage(exactEvents: [event(300, 200)])
        XCTAssertEqual(usage.total.totalTokens, 200)
        XCTAssertEqual(usage.unassignedTokens, 0)
    }

    func testConfirmedInteriorsAndSharedBoundaryReconcileWithoutDoubleCounting() throws {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 10000), o(300, 65, 10010), o(420, 0, 20000),
            o(480, 1, 20000), o(600, 2, 20000)
        ], now: d(900))
        XCTAssertEqual(cycles.count, 2)
        guard cycles.count == 2 else { return }
        let minutes = (0..<5).map { index in
            TokenCacheBucket(start: d(300 + Double(index * 60)), breakdown: breakdown((index + 1) * 100))
        }
        let events = [event(0, 100), TokenCacheAttributionEvent(id: "edge", start: d(300),
            model: "gpt-5.6-sol", breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)]
        let old = QuotaCycleUsage(events: events, cycle: cycles[1], coverageEnd: d(900))
        let current = QuotaCycleUsage(events: events, cycle: cycles[0], coverageEnd: d(900))
        XCTAssertEqual(old.total.totalTokens, 400)
        XCTAssertEqual(current.total.totalTokens, 1200)
        XCTAssertEqual(old.unassignedTokens, 0)
        XCTAssertEqual(current.unassignedTokens, 0)
        XCTAssertEqual(old.total.totalTokens + current.total.totalTokens + current.unassignedTokens, 1600)
    }

    func testNaturalExpiryUsesCorrectedResetAndOfflineGapDoesNotInventCycles() throws {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 50, 600), o(300, 90, 610), o(660, 5, 605410)
        ], now: d(700))
        XCTAssertEqual(cycles.count, 2)
        guard cycles.count == 2 else { return }
        XCTAssertEqual(cycles[1].end, .exact(d(660)))
        XCTAssertEqual(cycles[0].start, cycles[1].end)
        let offline = QuotaActualCycleProjector.project([
            o(0, 50, 600), o(300, 60, 610), o(1300000, 5, 1700000)
        ], now: d(1300100))
        XCTAssertEqual(offline.count, 2)
        XCTAssertEqual(offline.first?.start, .exact(d(1300000)))
        XCTAssertEqual(offline.last?.end, .exact(d(1300000)))
    }

    func testProFilterRetainsStableResetLowPointThroughDatabaseRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        let database = QuotaHistoryDatabase(databaseURL: url)
        let readings: [(Double, Int, Double)] = [(0, 7, 10000), (60, 0, 20000), (120, 3, 20000),
            (180, 3, 20000), (240, 3, 20000), (300, 3, 20000), (360, 3, 20000), (420, 4, 20000)]
        let samples = readings.map { at, used, reset in quota(at, used, reset, plan: "Pro") }
        for sample in samples { XCTAssertTrue(try database.record(sample)) }
        let rawBefore = try rawValues(url)
        XCTAssertEqual(rawBefore, [7, 0, 3, 3, 3, 3, 3, 4])
        for db in [database, QuotaHistoryDatabase(databaseURL: url)] {
            let snapshot = try db.loadSnapshot(for: samples.last!, now: d(450))
            XCTAssertEqual(snapshot.actualCycles.count, 2)
            XCTAssertTrue(snapshot.recentBins.flatMap(\.sevenDayObservations).contains { $0.remainingPercent == 100 })
            XCTAssertEqual(snapshot.actualCycles.first?.certainStart, d(60))
            XCTAssertEqual(snapshot.actualCycles.first?.certainEnd, d(420))
        }
        XCTAssertEqual(try rawValues(url), rawBefore, "reprojection must not rewrite raw history")
    }

    func testRestartReplaysCorrectionsAndKeepsIdentityPlanAndHomeIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        let database = QuotaHistoryDatabase(databaseURL: url)
        let current = quota(480, 1, 20000, plan: "Plus")
        for sample in [quota(0, 3, 10000, plan: "Plus"), quota(300, 50, 10010, plan: "Plus"),
                       quota(420, 0, 20000, plan: "Plus"), current] {
            XCTAssertTrue(try database.record(sample))
        }
        let isolated = [quota(500, 20, 25000, plan: "Pro"),
            quota(500, 20, 25000, plan: "Plus", account: "b"),
            quota(500, 20, 25000, plan: "Plus", home: "/another-home"),
            quota(500, 20, 25000, plan: "Plus", limit: "another-limit")]
        for sample in isolated { XCTAssertTrue(try database.record(sample)) }
        let restarted = QuotaHistoryDatabase(databaseURL: url)
        XCTAssertEqual(try restarted.loadSnapshot(for: current, now: d(550)).actualCycles.count, 2)
        for sample in isolated {
            let loaded = try restarted.loadSnapshot(for: sample, now: d(550))
            XCTAssertEqual(loaded.actualCycles.count, 1)
            XCTAssertNil(loaded.actualCycles.first?.start)
            XCTAssertEqual(loaded.cycleIdentity, sample.historyIdentity)
        }
    }

    func testConfirmedResetSurvivesLaterTenSecondCorrectionInProFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        let database = QuotaHistoryDatabase(databaseURL: url)
        let samples = [quota(0, 7, 10000, plan: "Pro"), quota(60, 0, 20000, plan: "Pro"),
                       quota(120, 1, 20000, plan: "Pro"), quota(180, 4, 20010, plan: "Pro")]
        for sample in samples { XCTAssertTrue(try database.record(sample)) }
        let loaded = try database.loadSnapshot(for: samples.last!, now: d(200))
        XCTAssertEqual(loaded.actualCycles.count, 2)
        XCTAssertEqual(loaded.actualCycles.first?.certainStart, d(60))
        XCTAssertEqual(loaded.actualCycles.first?.scheduledResetAt, d(20010))
        XCTAssertTrue(loaded.recentBins.flatMap(\.sevenDayObservations).contains { $0.remainingPercent == 100 })
        XCTAssertEqual(try rawValues(url), [7, 0, 1, 4])
    }

    func testRepeatedReplenishmentsNeverLeaveAPendingAttributionGap() throws {
        let cycles = QuotaActualCycleProjector.project([
            o(0, 60, 10000), o(300, 30, 20000), o(360, 29, 20000),
            o(600, 15, 20000), o(660, 16, 20000)
        ], now: d(700))
        XCTAssertEqual(cycles.count, 3)
        XCTAssertEqual(cycles.map { $0.start?.latest }, [d(600), d(300), nil])
        XCTAssertEqual(cycles[1].certainEnd, d(600))
        XCTAssertEqual(cycles[2].certainEnd, d(300))
        XCTAssertTrue(cycles.allSatisfy { $0.pendingBoundary == nil && !$0.resetChangePending })
    }

    func testLaterPendingResetCannotEraseEarlierConfirmedResetThroughProFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        let database = QuotaHistoryDatabase(databaseURL: url)
        let samples = [quota(0, 7, 10000, plan: "Pro"), quota(60, 0, 20000, plan: "Pro"),
                       quota(120, 1, 20000, plan: "Pro"), quota(240, 6, 20000, plan: "Pro"),
                       quota(300, 0, 30000, plan: "Pro"), quota(330, 3, 30000, plan: "Pro")]
        for sample in samples { XCTAssertTrue(try database.record(sample)) }
        let rawBefore = try rawValues(url)
        XCTAssertEqual(rawBefore, [7, 0, 1, 6, 0, 3])
        for db in [database, QuotaHistoryDatabase(databaseURL: url)] {
            let loaded = try db.loadSnapshot(for: samples.last!, now: d(350))
            XCTAssertEqual(loaded.actualCycles.count, 3)
            let current = try XCTUnwrap(loaded.actualCycles.first)
            XCTAssertEqual(current.certainStart, d(300))
            XCTAssertEqual(current.certainEnd, d(330))
            XCTAssertEqual(current.lastObservedAt, d(330))
            XCTAssertNil(current.pendingBoundary)
            XCTAssertFalse(current.resetChangePending)
            XCTAssertTrue(loaded.actualCycles.last?.endedEarly == true)
            let observations = loaded.recentBins.flatMap(\.sevenDayObservations)
            XCTAssertTrue(observations.contains { $0.remainingPercent == 100 && $0.observedAt == d(60) })
            XCTAssertTrue(observations.contains { $0.remainingPercent == 99 && $0.observedAt == d(120) })
        }
        XCTAssertEqual(try rawValues(url), rawBefore)
    }

    func testConfirmedStartProtectionStillRejectsReturnToOldResetThroughDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.sqlite")
        let database = QuotaHistoryDatabase(databaseURL: url)
        let samples = [quota(0, 7, 10000, plan: "Pro"), quota(60, 0, 20000, plan: "Pro"),
                       quota(120, 1, 20000, plan: "Pro"), quota(180, 2, 10000, plan: "Pro")]
        for sample in samples { XCTAssertTrue(try database.record(sample)) }
        let rawBefore = try rawValues(url)
        for db in [database, QuotaHistoryDatabase(databaseURL: url)] {
            let loaded = try db.loadSnapshot(for: samples.last!, now: d(200))
            XCTAssertEqual(loaded.actualCycles.count, 2)
            XCTAssertEqual(loaded.actualCycles.first?.lastObservedAt, d(180))
            let observations = loaded.recentBins.flatMap(\.sevenDayObservations)
            XCTAssertTrue(observations.contains { $0.observedAt == d(60) || $0.observedAt == d(120) })
            XCTAssertTrue(observations.contains { $0.remainingPercent == 98 && $0.observedAt == d(180) })
        }
        XCTAssertEqual(rawBefore, [7, 0, 1, 2])
        XCTAssertEqual(try rawValues(url), rawBefore)
    }

    func testDiagnosticsContainOnlyChangesAndDoNotRepeatNormalMinuteReadings() {
        let ordinary = [o(0, 3, 10000), o(60, 4, 10000), o(120, 5, 10000)]
        XCTAssertTrue(QuotaActualCycleProjector.projectWithDiagnostics(ordinary, now: d(180)).diagnostics.isEmpty)
        let projection = QuotaActualCycleProjector.projectWithDiagnostics([
            o(0, 3, 10000), o(60, 4, 10010), o(120, 50, 10010),
            o(300, 0, 20000), o(360, 1, 20000), o(420, 2, 20000)
        ], now: d(450))
        XCTAssertEqual(projection.diagnostics.map(\.kind), [.confirmed])
        XCTAssertEqual(projection.diagnostics.map(\.at), [d(300)])
    }

    private func quota(_ at: Double, _ used: Int, _ reset: Double, plan: String,
                       account: String = "a", home: String = "/fixture", limit: String = "codex") -> AccountQuotaSnapshot {
        .init(sevenDay: .init(label: "7d", usedPercent: used, resetsAt: d(reset)), planType: plan,
              limitName: limit, accountName: account, updatedAt: d(at),
              historyIdentity: .init(homeIdentity: home, stableAccountKey: account, planType: plan, limitID: limit))
    }

    private func rawValues(_ url: URL) throws -> [Int?] {
        try SQLiteDatabaseDriver(url: url).readRows("SELECT seven_day_used_percent FROM quota_snapshots ORDER BY created_at;") { $0.int(0) }
    }
}
