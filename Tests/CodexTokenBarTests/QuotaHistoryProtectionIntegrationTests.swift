import XCTest
@testable import CodexTokenBar

final class QuotaHistoryProtectionIntegrationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        directories.append(directory)
        return directory.appendingPathComponent("quota.sqlite")
    }

    private func input(_ used: Int, at: Date, reset: Date) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: used, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 50, resetsAt: reset.addingTimeInterval(500_000)),
            planType: "Plus", limitName: "codex", accountName: "protection", updatedAt: at,
            selectedLimitID: "codex",
            historyIdentity: QuotaHistoryIdentity(homeIdentity: "/fixture/protection", stableAccountKey: "sub:protection", planType: "Plus", limitID: "codex")
        )
    }

    func testRawCorrectionEvidenceSurvivesRestartAndMaintenanceWithoutChangingRealtimeQuota() throws {
        let url = try databaseURL()
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = start.addingTimeInterval(20_000)
        let database = QuotaHistoryDatabase(databaseURL: url)
        try database.record(input(12, at: start, reset: reset))
        for offset in [10.0, 160.0] {
            try database.record(input(8, at: start.addingTimeInterval(offset), reset: reset))
        }
        let reopened = QuotaHistoryDatabase(databaseURL: url)
        let current = input(8, at: start.addingTimeInterval(310), reset: reset)
        let before = try reopened.loadSnapshot(for: current, now: start.addingTimeInterval(200))
        XCTAssertEqual(before.recentBins.last?.fiveHourRemainingPercent, 92)
        XCTAssertEqual(before.recentBins.last?.sevenDayRemainingPercent, 50)
        try reopened.record(current)
        try reopened.migrate()
        let raw = try SQLiteDatabaseDriver(url: url).readRows(
            "SELECT five_hour_used_percent, five_hour_cycle_generation FROM quota_snapshots ORDER BY created_at;"
        ) { ($0.int(0), $0.int(1)) }
        XCTAssertEqual(raw.map(\.0), [12, 8, 8, 8])
        XCTAssertEqual(raw.map(\.1), [0, 0, 0, 0])
        let accepted = try reopened.loadSnapshot(for: current, now: current.updatedAt!)
        XCTAssertEqual(accepted.recentBins.last?.fiveHourRemainingPercent, 92)
        let realtime = try reopened.normalizedSnapshot(input(3, at: current.updatedAt!, reset: reset))
        XCTAssertEqual(realtime.fiveHour?.usedPercent, 3, "history must not modify successful realtime values")
    }

    func testFreshEqualResponseIsDurableButReplayedOrOlderResponsesCannotConfirm() throws {
        let url = try databaseURL()
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = start.addingTimeInterval(20_000)
        let database = QuotaHistoryDatabase(databaseURL: url)
        let first = input(12, at: start, reset: reset)
        XCTAssertTrue(try database.record(first))
        XCTAssertFalse(try database.record(first))
        XCTAssertTrue(try database.record(input(12, at: start.addingTimeInterval(20), reset: reset)))
        let reopened = QuotaHistoryDatabase(databaseURL: url)
        XCTAssertFalse(try reopened.record(input(8, at: start.addingTimeInterval(15), reset: reset)))
        for offset in [30.0, 330.0] {
            let lower = input(8, at: start.addingTimeInterval(offset), reset: reset)
            XCTAssertTrue(try reopened.record(lower))
            XCTAssertFalse(try reopened.record(lower))
        }
        let pending = try reopened.loadSnapshot(for: first, now: start.addingTimeInterval(330))
        XCTAssertEqual(pending.recentBins.last?.fiveHourRemainingPercent, 92)
        let confirmed = input(8, at: start.addingTimeInterval(331), reset: reset)
        XCTAssertTrue(try reopened.record(confirmed))
        let accepted = try reopened.loadSnapshot(for: confirmed, now: confirmed.updatedAt!)
        XCTAssertEqual(accepted.recentBins.last?.fiveHourRemainingPercent, 92)
        let count = try SQLiteDatabaseDriver(url: url).readRows("SELECT COUNT(*) FROM quota_snapshots;") { $0.int(0) }.first!
        XCTAssertEqual(count, 5)
    }

    func testHighUsedBoundaryChangesOnlyItsOwnWindowAndAllowsExhaustedFirstSample() throws {
        let url = try databaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = start.addingTimeInterval(20_000)
        let original = input(90, at: start, reset: reset)
        try database.record(original)
        var first = input(80, at: start.addingTimeInterval(60), reset: reset.addingTimeInterval(1801))
        first.sevenDay = original.sevenDay
        try database.record(first)
        var second = first
        second.updatedAt = start.addingTimeInterval(120)
        second.sevenDay = AccountQuotaWindow(label: "7d", usedPercent: 100, resetsAt: original.sevenDay!.resetsAt!.addingTimeInterval(1801))
        try database.record(second)
        let generations = try SQLiteDatabaseDriver(url: url).readRows(
            "SELECT five_hour_cycle_generation, seven_day_cycle_generation FROM quota_snapshots ORDER BY created_at;"
        ) { ($0.int(0), $0.int(1)) }
        XCTAssertEqual(generations.map(\.0), [0, 1, 1])
        XCTAssertEqual(generations.map(\.1), [0, 0, 1])
        let loaded = try database.loadSnapshot(for: second, now: second.updatedAt!)
        XCTAssertEqual(loaded.recentBins.last?.fiveHourRemainingPercent, 20)
        XCTAssertEqual(loaded.recentBins.last?.sevenDayRemainingPercent, 0)
    }

    func testUnambiguousLegacyOnlyHistoryLoadsWithoutRewritingOriginalRows() throws {
        let url = try databaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        try database.migrate()
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = start.addingTimeInterval(20_000)
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.execute(
            """
            INSERT INTO quota_snapshots (created_at, account_key, source, plan_type,
                limit_name, account_name, five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status)
            VALUES (?, 'protection|Plus|codex', 'swift', 'Plus', 'codex', 'protection',
                20, ?, 50, ?, 'legacy');
            """,
            bindings: [.date(start), .date(reset), .date(reset.addingTimeInterval(500_000))]
        )
        let loaded = try database.loadSnapshot(for: input(20, at: start, reset: reset), now: start.addingTimeInterval(60))
        XCTAssertEqual(loaded.recentBins.last?.fiveHourRemainingPercent, 80)
        let values = try driver.readRows("SELECT five_hour_used_percent, identity_version FROM quota_snapshots;") { ($0.int(0), $0.int(1)) }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].0, 20)
        XCTAssertNil(values[0].1)
    }
}

extension QuotaHistoryProtectionIntegrationTests {
    func testRetrospectiveRemovalRebuildsBinsAndCyclesWithoutDeletingRawRows() throws {
        let url = try databaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(5000)
        func sample(_ offset: Double, _ seven: Int, _ shift: Double, _ five: Int) -> AccountQuotaSnapshot {
            var quota = input(five, at: now.addingTimeInterval(offset), reset: reset)
            quota.sevenDay = AccountQuotaWindow(label: "7d", usedPercent: seven, resetsAt: reset.addingTimeInterval(shift))
            return quota
        }
        let first = sample(-600, 42, 500_000, 20)
        let glitch = sample(-310, 1, 540_674, 0)
        let recovery = sample(-20, 42, 500_000, 20)
        try database.record(first)
        try database.record(glitch)
        let pending = try database.loadSnapshot(for: glitch, now: now.addingTimeInterval(-30))
        XCTAssertEqual(pending.recentBins.last?.sevenDayRemainingPercent, 99)
        try database.record(recovery)
        let reopened = QuotaHistoryDatabase(databaseURL: url)
        let after = try reopened.loadSnapshot(for: recovery, now: now)
        let beforeRecovery = try reopened.loadSnapshot(for: recovery, now: now.addingTimeInterval(-30))
        XCTAssertEqual(beforeRecovery.recentBins.last?.sevenDayRemainingPercent, 99, "future recovery cannot change an earlier as-of query")
        let middle = try XCTUnwrap(after.recentBins.first { abs($0.start.addingTimeInterval(300).timeIntervalSince(now.addingTimeInterval(-300))) < 0.001 })
        XCTAssertEqual(middle.sevenDayRemainingPercent, 58, "flat bridge crosses the removed point and the bin boundary")
        XCTAssertEqual(try XCTUnwrap(middle.fiveHourRemainingPercent), 100 - 20 * 10 / 290, accuracy: 0.001)
        XCTAssertTrue(after.recentBins.flatMap(\.fiveHourObservations).contains { $0.remainingPercent == 100 }, "the measured 5h spike remains; bin edges still use normal interpolation")
        let observations = after.recentBins.flatMap(\.sevenDayObservations)
        XCTAssertEqual(observations.map(\.remainingPercent), [58, 58])
        XCTAssertEqual(Set(observations.compactMap(\.cycleID)), ["g0"], "rejected reset must not advance the cycle")
        let raw = try SQLiteDatabaseDriver(url: url).readRows("SELECT seven_day_used_percent, seven_day_resets_at FROM quota_snapshots ORDER BY created_at;") { ($0.int(0), $0.double(1)) }
        XCTAssertEqual(raw.map(\.0), [42, 1, 42])
        XCTAssertEqual(raw[1].1, glitch.sevenDay!.resetsAt!.timeIntervalSince1970)
    }

    func testJumpAloneConnectsUpwardRemainingAcrossChangedCycle() throws {
        let url = try databaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = now.addingTimeInterval(5000)
        for (offset, used, shift) in [(-600.0, 80, 500_000.0), (-310.0, 1, 540_000.0), (-20.0, 60, 540_000.0)] {
            var quota = input(20, at: now.addingTimeInterval(offset), reset: reset)
            quota.sevenDay = AccountQuotaWindow(label: "7d", usedPercent: used, resetsAt: reset.addingTimeInterval(shift))
            try database.record(quota)
        }
        let result = try database.loadSnapshot(for: input(20, at: now, reset: reset), now: now)
        let middle = try XCTUnwrap(result.recentBins.first { abs($0.start.addingTimeInterval(300).timeIntervalSince(now.addingTimeInterval(-300))) < 0.001 })
        XCTAssertEqual(try XCTUnwrap(middle.sevenDayRemainingPercent), 20 + 20 * 300 / 580, accuracy: 0.001)
        XCTAssertEqual(result.recentBins.flatMap(\.sevenDayObservations).map(\.remainingPercent), [20,40])
    }
}
