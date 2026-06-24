import XCTest
@testable import CodexTokenBar

final class QuotaHistoryStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testRecentHistoryIncludesLegacyCodexAccountKeyRows() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let legacyTime = now.addingTimeInterval(-20 * 60)
        let codexTime = now.addingTimeInterval(-15 * 60)

        try database.record(snapshot(
            usedPercent: 12,
            reset: reset,
            planType: "pro",
            limitName: nil,
            at: legacyTime
        ), createdAt: legacyTime)
        try database.record(snapshot(
            usedPercent: 13,
            reset: reset,
            planType: "Pro",
            limitName: "codex",
            at: codexTime
        ), createdAt: codexTime)

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertTrue(recentValues.contains(88), "legacy pro row should remain visible in the 24h quota curve")
        XCTAssertTrue(recentValues.contains(87), "current Pro|codex row should remain visible in the 24h quota curve")
    }

    func testRecentHistoryDoesNotMergeOtherLimitNames() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)

        try database.record(snapshot(
            usedPercent: 66,
            reset: reset,
            planType: "pro",
            limitName: "GPT-5.3-Codex-Spark",
            at: now.addingTimeInterval(-20 * 60)
        ), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(
            usedPercent: 13,
            reset: reset,
            planType: "Pro",
            limitName: "codex",
            at: now.addingTimeInterval(-15 * 60)
        ), createdAt: now.addingTimeInterval(-15 * 60))

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertFalse(recentValues.contains(34), "non-codex limit rows should not be mixed into the Codex quota curve")
        XCTAssertTrue(recentValues.contains(87))
    }

    func testRecentHistorySuppressesRecoveredFiveHourFullUsageSpikeAcrossMergedAccountKeys() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)

        try database.record(snapshot(usedPercent: 0, reset: reset, planType: "pro", limitName: nil, at: now.addingTimeInterval(-20 * 60)), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(usedPercent: 0, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-19 * 60)), createdAt: now.addingTimeInterval(-19 * 60))
        try database.record(snapshot(usedPercent: 1, reset: reset, planType: "pro", limitName: nil, at: now.addingTimeInterval(-18 * 60)), createdAt: now.addingTimeInterval(-18 * 60))
        try database.record(snapshot(usedPercent: 100, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-17 * 60)), createdAt: now.addingTimeInterval(-17 * 60))
        try database.record(snapshot(usedPercent: 2, reset: reset, planType: "pro", limitName: nil, at: now.addingTimeInterval(-13 * 60)), createdAt: now.addingTimeInterval(-13 * 60))
        try database.record(snapshot(usedPercent: 2, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-10 * 60)), createdAt: now.addingTimeInterval(-10 * 60))

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertFalse(recentValues.contains(0), "recovered full-usage spike should not create a 5h quota pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 98)
    }

    func testRecentHistorySuppressesRecoveredSevenDayFullUsageSpike() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(3 * 60 * 60)
        let sevenDayReset = now.addingTimeInterval(4 * 24 * 60 * 60)

        try database.record(snapshot(usedPercent: 2, sevenDayUsedPercent: 0, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-20 * 60)), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(usedPercent: 3, sevenDayUsedPercent: 100, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-15 * 60)), createdAt: now.addingTimeInterval(-15 * 60))
        try database.record(snapshot(usedPercent: 10, sevenDayUsedPercent: 2, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-5 * 60)), createdAt: now.addingTimeInterval(-5 * 60))

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.sevenDayRemainingPercent)

        XCTAssertFalse(recentValues.contains(0), "recovered full-usage spike should not create a 7d quota pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 98)
    }

    private func snapshot(
        usedPercent: Int,
        sevenDayUsedPercent: Int = 40,
        reset: Date,
        sevenDayReset: Date? = nil,
        planType: String,
        limitName: String?,
        at date: Date
    ) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: sevenDayUsedPercent, resetsAt: sevenDayReset ?? reset.addingTimeInterval(4 * 24 * 60 * 60)),
            planType: planType,
            limitName: limitName,
            accountName: "来先生",
            status: "额度已更新",
            updatedAt: date
        )
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("quota-history.sqlite")
    }
}
