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

    @MainActor
    func testOlderReloadCannotOverwriteNewerRecordedSnapshot() async throws {
        let client = SuspendedQuotaHistoryClient()
        let store = QuotaHistoryStore(historyClient: client)
        let now = Date()

        store.reload()
        await waitUntil("reload request pending") {
            await client.hasPending(.reload)
        }

        store.record(snapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            planType: "Pro",
            limitName: "codex",
            at: now
        ))
        await waitUntil("record request pending") {
            await client.hasPending(.record)
        }

        await client.complete(.record, with: quotaHistorySnapshot(latest: now))
        await waitUntil("record snapshot published") {
            store.snapshot.latest == now
        }

        await client.complete(.reload, with: quotaHistorySnapshot(latest: now.addingTimeInterval(-60)))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.latest, now)
    }

    @MainActor
    func testStaleReloadFailureCannotClearNewerRecordedSnapshot() async throws {
        let client = SuspendedQuotaHistoryClient()
        let store = QuotaHistoryStore(historyClient: client)
        let now = Date()

        store.reload()
        await waitUntil("reload request pending") {
            await client.hasPending(.reload)
        }

        store.record(snapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            planType: "Pro",
            limitName: "codex",
            at: now
        ))
        await waitUntil("record request pending") {
            await client.hasPending(.record)
        }

        await client.complete(.record, with: quotaHistorySnapshot(latest: now))
        await waitUntil("record snapshot published before stale failure") {
            store.snapshot.latest == now
        }

        await client.fail(.reload, error: QuotaHistoryTestError())
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.latest, now)
    }

    func testRecentHistoryIncludesLegacyCodexAccountKeyRows() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let legacyTime = now.addingTimeInterval(-20 * 60)
        let codexTime = now.addingTimeInterval(-15 * 60)

        try database.record(snapshot(
            usedPercent: 13,
            reset: reset,
            planType: "Pro",
            limitName: "codex",
            at: codexTime
        ), createdAt: codexTime)
        try insertRawSnapshot(
            databaseURL: url,
            createdAt: legacyTime,
            accountKey: "来先生|pro",
            source: "legacy",
            planType: "pro",
            limitName: nil,
            accountName: "来先生",
            fiveHourUsedPercent: 12,
            fiveHourResetsAt: reset,
            sevenDayUsedPercent: 40,
            sevenDayResetsAt: reset.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertTrue(
            recentValues.contains { $0 > 87 && $0 <= 88 },
            "legacy pro row should remain visible in the 24h quota curve, including smoothed transitions"
        )
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

    func testSwiftWritesCanonicalCodexAccountKeyAndSource() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()

        try database.record(snapshot(
            usedPercent: 12,
            reset: now.addingTimeInterval(3 * 60 * 60),
            planType: "pro",
            limitName: nil,
            at: now
        ), createdAt: now)

        let driver = SQLiteDatabaseDriver(url: url)
        let columns = try driver.readRows("PRAGMA table_info(quota_snapshots);") { statement in
            statement.text(1) ?? ""
        }
        let rows = try driver.readRows(
            "SELECT account_key, plan_type, limit_name, source FROM quota_snapshots ORDER BY id ASC;"
        ) { statement in
            (
                accountKey: statement.text(0),
                planType: statement.text(1),
                limitName: statement.text(2),
                source: statement.text(3)
            )
        }

        XCTAssertTrue(columns.contains("source"))
        XCTAssertEqual(rows.first?.accountKey, "来先生|Pro|codex")
        XCTAssertEqual(rows.first?.planType, "Pro")
        XCTAssertEqual(rows.first?.limitName, "codex")
        XCTAssertEqual(rows.first?.source, "swift")
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

    func testRecentHistoryDropsSameCycleQuotaJumpAcrossSources() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)

        try database.record(snapshot(usedPercent: 10, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-20 * 60)), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(usedPercent: 11, reset: reset, planType: "pro", limitName: nil, at: now.addingTimeInterval(-15 * 60)), createdAt: now.addingTimeInterval(-15 * 60))
        try database.record(snapshot(usedPercent: 45, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-10 * 60)), createdAt: now.addingTimeInterval(-10 * 60))
        try database.record(snapshot(usedPercent: 12, reset: reset, planType: "pro", limitName: nil, at: now.addingTimeInterval(-5 * 60)), createdAt: now.addingTimeInterval(-5 * 60))

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertFalse(recentValues.contains(55), "same-cycle quota jumps from another source should not create a false 5h pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 88)
    }

    func testRecentHistoryInterpolatesAcrossMissingQuotaSamplesInSameCycle() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)

        try database.record(
            snapshot(usedPercent: 20, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-4 * 60 * 60)),
            createdAt: now.addingTimeInterval(-4 * 60 * 60)
        )
        try database.record(
            snapshot(usedPercent: 22, reset: reset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-30 * 60)),
            createdAt: now.addingTimeInterval(-30 * 60)
        )

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)
        let interpolatedValues = recentValues.filter { $0 < 79.9 && $0 > 78.1 }

        XCTAssertFalse(interpolatedValues.isEmpty, "quota curve should connect 80% to 78% smoothly across a sleep/no-sample gap")
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

    func testRecentHistorySuppressesLatestSevenDayFullUsageSpike() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(3 * 60 * 60)
        let sevenDayReset = now.addingTimeInterval(4 * 24 * 60 * 60)

        try database.record(snapshot(usedPercent: 2, sevenDayUsedPercent: 0, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-20 * 60)), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(usedPercent: 3, sevenDayUsedPercent: 100, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-5 * 60)), createdAt: now.addingTimeInterval(-5 * 60))

        let loaded = try database.loadSnapshot(now: now)
        let recentValues = loaded.recentBins.compactMap(\.sevenDayRemainingPercent)

        XCTAssertFalse(recentValues.contains(0), "latest full-usage spike should not leave a 7d quota pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 99)
    }

    func testCurrentHourlyQuotaBucketDoesNotLookPastNow() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        components.year = 2026
        components.month = 6
        components.day = 25
        components.hour = 14
        components.minute = 23
        components.second = 0
        let now = try XCTUnwrap(components.date)
        let futureSevenDayReset = now.addingTimeInterval(37 * 60)

        try database.record(
            snapshot(
                usedPercent: 23,
                sevenDayUsedPercent: 56,
                reset: now.addingTimeInterval(3 * 60 * 60),
                sevenDayReset: futureSevenDayReset,
                planType: "Pro",
                limitName: "codex",
                at: now.addingTimeInterval(-10 * 60)
            ),
            createdAt: now.addingTimeInterval(-10 * 60)
        )

        let loaded = try database.loadSnapshot(now: now)

        XCTAssertEqual(loaded.hourlyBins.last?.sevenDayRemainingPercent, 44)
    }

    func testLargeStableHistoryLoadsWithoutQuadraticSpikeScan() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        try database.record(
            snapshot(
                usedPercent: 10,
                sevenDayUsedPercent: 40,
                reset: reset,
                sevenDayReset: reset.addingTimeInterval(4 * 24 * 60 * 60),
                planType: "Pro",
                limitName: "codex",
                at: now.addingTimeInterval(-30 * 24 * 60 * 60)
            ),
            createdAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )

        try insertStableRawSnapshots(
            databaseURL: url,
            count: 3_200,
            start: now.addingTimeInterval(-30 * 24 * 60 * 60),
            step: 12 * 60,
            fiveHourReset: reset,
            sevenDayReset: reset.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let start = Date()
        let loaded = try database.loadSnapshot(now: now)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(loaded.recentBins.count, 30 * 24 * 12)
        XCTAssertLessThan(elapsed, 1.0, "stable quota histories should not spend seconds scanning future rows")
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

    private func insertStableRawSnapshots(
        databaseURL: URL,
        count: Int,
        start: Date,
        step: TimeInterval,
        fiveHourReset: Date,
        sevenDayReset: Date
    ) throws {
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.transaction { connection in
            for index in 0..<count {
                let createdAt = start.addingTimeInterval(Double(index + 1) * step)
                try connection.execute(
                    """
                    INSERT INTO quota_snapshots (
                        created_at, account_key, source, plan_type, limit_name, account_name,
                        five_hour_used_percent, five_hour_resets_at,
                        seven_day_used_percent, seven_day_resets_at, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .date(createdAt),
                        .text("来先生|Pro|codex"),
                        .text("test"),
                        .text("Pro"),
                        .text("codex"),
                        .text("来先生"),
                        .int(10),
                        .date(fiveHourReset),
                        .int(40),
                        .date(sevenDayReset),
                        .text("stable")
                    ]
                )
            }
        }
    }

    @MainActor
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private func quotaHistorySnapshot(latest: Date) -> QuotaHistorySnapshot {
        QuotaHistorySnapshot(daily: [], recentBins: [], hourlyBins: [], latest: latest)
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("quota-history.sqlite")
    }

    private func insertRawSnapshot(
        databaseURL: URL,
        createdAt: Date,
        accountKey: String,
        source: String?,
        planType: String?,
        limitName: String?,
        accountName: String?,
        fiveHourUsedPercent: Int,
        fiveHourResetsAt: Date,
        sevenDayUsedPercent: Int,
        sevenDayResetsAt: Date
    ) throws {
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.execute(
            """
            INSERT INTO quota_snapshots (
                created_at, account_key, source, plan_type, limit_name, account_name,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .date(createdAt),
                .text(accountKey),
                .optionalText(source),
                .optionalText(planType),
                .optionalText(limitName),
                .optionalText(accountName),
                .int(fiveHourUsedPercent),
                .date(fiveHourResetsAt),
                .int(sevenDayUsedPercent),
                .date(sevenDayResetsAt),
                .text("legacy")
            ]
        )
    }
}

private enum QuotaHistoryTestOperation: Hashable {
    case reload
    case record
}

private actor SuspendedQuotaHistoryClient: QuotaHistoryLoading {
    private var continuations: [QuotaHistoryTestOperation: CheckedContinuation<QuotaHistorySnapshot, Error>] = [:]

    func loadSnapshot() async throws -> QuotaHistorySnapshot {
        try await suspend(.reload)
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try await suspend(.record)
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot {
        quota
    }

    func hasPending(_ operation: QuotaHistoryTestOperation) -> Bool {
        continuations[operation] != nil
    }

    func complete(_ operation: QuotaHistoryTestOperation, with snapshot: QuotaHistorySnapshot) {
        continuations.removeValue(forKey: operation)?.resume(returning: snapshot)
    }

    func fail(_ operation: QuotaHistoryTestOperation, error: Error) {
        continuations.removeValue(forKey: operation)?.resume(throwing: error)
    }

    private func suspend(_ operation: QuotaHistoryTestOperation) async throws -> QuotaHistorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations[operation] = continuation
        }
    }
}

private struct QuotaHistoryTestError: LocalizedError {
    var errorDescription: String? {
        "旧额度历史读取失败"
    }
}
