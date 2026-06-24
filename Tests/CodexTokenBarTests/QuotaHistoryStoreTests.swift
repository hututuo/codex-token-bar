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

    private func snapshot(
        usedPercent: Int,
        reset: Date,
        planType: String,
        limitName: String?,
        at date: Date
    ) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 40, resetsAt: reset.addingTimeInterval(4 * 24 * 60 * 60)),
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
