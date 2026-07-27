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

    func testSharedQuotaHistoryIdentityFixtureIsStrictAndFailClosed() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SharedFixtures/quota-history-identity-v1.json")
        let fixture = try JSONDecoder().decode(
            SharedQuotaHistoryIdentityFixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(fixture.fixtureVersion, 1)
        XCTAssertEqual(fixture.identityVersion, QuotaHistoryIdentity.currentVersion)

        for scenario in fixture.scenarios {
            let url = try makeDatabaseURL()
            let database = QuotaHistoryDatabase(databaseURL: url)
            try database.migrate()
            let now = Date()

            for (index, step) in scenario.steps.enumerated() {
                XCTAssertFalse(step.limitId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let createdAt = now.addingTimeInterval(Double(index - scenario.steps.count) * 60)
                let quota = fixtureSnapshot(step, at: createdAt)

                switch step.operation {
                case "write":
                    XCTAssertEqual(
                        try database.record(quota, createdAt: createdAt),
                        step.expectedAccepted ?? true,
                        "scenario \(scenario.id) write acceptance"
                    )
                case "read":
                    let actual = try database.recordedFiveHourUsedPercents(
                        for: quota,
                        now: now,
                        age: 31 * 24 * 60 * 60
                    ).sorted()
                    XCTAssertEqual(
                        actual,
                        (step.expectedUsedPercents ?? []).sorted(),
                        "scenario \(scenario.id) read"
                    )
                case "legacyWrite":
                    try insertRawSnapshot(
                        databaseURL: url,
                        createdAt: createdAt,
                        accountKey: "\(step.displayName)|\(step.plan)|\(step.limitId)",
                        source: step.source,
                        planType: step.plan,
                        limitName: step.limitId,
                        accountName: step.displayName,
                        fiveHourUsedPercent: step.usedPercent ?? 0,
                        fiveHourResetsAt: now.addingTimeInterval(3 * 60 * 60),
                        sevenDayUsedPercent: step.usedPercent ?? 0,
                        sevenDayResetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
                    )
                default:
                    XCTFail("unsupported fixture operation \(step.operation)")
                }
            }
        }
    }

    func testIdentityV1SchemaAndSwiftWriteAreAdditive() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let quota = identifiedSnapshot(
            usedPercent: 12,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/schema-home",
            stableAccountKey: "sub:schema-account",
            planType: "Plus",
            limitID: "codex",
            accountName: "Shared User",
            at: now
        )

        XCTAssertTrue(try database.record(quota, createdAt: now))

        let driver = SQLiteDatabaseDriver(url: url)
        let columns = try driver.readRows("PRAGMA table_info(quota_snapshots);") { statement in
            statement.text(1) ?? ""
        }
        let claimColumns = try driver.readRows("PRAGMA table_info(quota_history_legacy_claims);") { statement in
            statement.text(1) ?? ""
        }
        let row = try XCTUnwrap(driver.readRows(
            """
            SELECT source, identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots LIMIT 1;
            """
        ) { statement in
            (
                source: statement.text(0),
                version: statement.int(1),
                home: statement.text(2),
                account: statement.text(3),
                plan: statement.text(4),
                limit: statement.text(5)
            )
        }.first)

        XCTAssertTrue(Set([
            "identity_version", "home_identity", "stable_account_key",
            "identity_plan_type", "identity_limit_id"
        ]).isSubset(of: Set(columns)))
        XCTAssertTrue(Set([
            "legacy_account_name", "legacy_plan_type", "legacy_limit_id", "bridge_kind",
            "owner_identity_version", "owner_home_identity", "owner_stable_account_key",
            "owner_plan_type", "owner_limit_id", "state", "claimed_at", "last_seen_at"
        ]).isSubset(of: Set(claimColumns)))
        XCTAssertEqual(row.source, "swift")
        XCTAssertEqual(row.version, 1)
        XCTAssertEqual(row.home, "/fixture/schema-home")
        XCTAssertEqual(row.account, "sub:schema-account")
        XCTAssertEqual(row.plan, "Plus")
        XCTAssertEqual(row.limit, "codex")
    }

    func testSwiftAndTauriIdentityV1RowsRemainIsolatedInOneDatabase() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let contexts = [
            identifiedSnapshot(
                usedPercent: 10,
                reset: reset,
                homeIdentity: "/fixture/alternate-home-a",
                stableAccountKey: "sub:alternate-a",
                planType: "Plus",
                limitID: "codex",
                accountName: "Alternating User",
                at: now
            ),
            identifiedSnapshot(
                usedPercent: 20,
                reset: reset,
                homeIdentity: "/fixture/alternate-home-a",
                stableAccountKey: "sub:alternate-b",
                planType: "Plus",
                limitID: "codex",
                accountName: "Alternating User",
                at: now
            ),
            identifiedSnapshot(
                usedPercent: 30,
                reset: reset,
                homeIdentity: "/fixture/alternate-home-b",
                stableAccountKey: "sub:alternate-a",
                planType: "Plus",
                limitID: "codex",
                accountName: "Alternating User",
                at: now
            ),
            identifiedSnapshot(
                usedPercent: 40,
                reset: reset,
                homeIdentity: "/fixture/alternate-home-a",
                stableAccountKey: "sub:alternate-a",
                planType: "Team",
                limitID: "codex",
                accountName: "Alternating User",
                at: now
            ),
            identifiedSnapshot(
                usedPercent: 50,
                reset: reset,
                homeIdentity: "/fixture/alternate-home-a",
                stableAccountKey: "sub:alternate-a",
                planType: "Plus",
                limitID: "gpt-5.3-codex-spark",
                accountName: "Alternating User",
                at: now
            )
        ]

        XCTAssertTrue(try database.record(contexts[0], createdAt: now.addingTimeInterval(-50)))
        try database.migrate()
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: contexts[1],
            source: "tauri",
            createdAt: now.addingTimeInterval(-40)
        )
        XCTAssertTrue(try database.record(contexts[2], createdAt: now.addingTimeInterval(-30)))
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: contexts[3],
            source: "tauri",
            createdAt: now.addingTimeInterval(-20)
        )
        XCTAssertTrue(try database.record(contexts[4], createdAt: now.addingTimeInterval(-10)))

        for (index, quota) in contexts.enumerated() {
            XCTAssertEqual(
                try database.recordedFiveHourUsedPercents(for: quota, now: now),
                [(index + 1) * 10]
            )
        }
    }

    func testMissingIdentityUnknownPlanAndBlankLimitFailClosed() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let valid = identifiedSnapshot(
            usedPercent: 21,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/fail-closed",
            stableAccountKey: "sub:valid",
            planType: "Pro",
            limitID: "codex",
            accountName: "Same Name",
            at: now
        )
        XCTAssertTrue(try database.record(valid, createdAt: now))

        var missingIdentity = valid
        missingIdentity.historyIdentity = nil
        let unknownPlan = QuotaHistoryIdentity(
            homeIdentity: "/fixture/fail-closed",
            stableAccountKey: "sub:unknown-plan",
            planType: "unknown",
            limitID: "codex"
        )
        let blankLimit = QuotaHistoryIdentity(
            homeIdentity: "/fixture/fail-closed",
            stableAccountKey: "sub:blank-limit",
            planType: "Plus",
            limitID: "   "
        )

        XCTAssertNil(unknownPlan)
        XCTAssertNil(blankLimit)
        XCTAssertFalse(try database.record(missingIdentity, createdAt: now.addingTimeInterval(60)))
        XCTAssertTrue(try database.recordedFiveHourUsedPercents(for: missingIdentity, now: now).isEmpty)
    }

    func testLegacyBridgeIsBoundedToFortyFiveDaysAndFiveHundredTwelveRows() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let quota = identifiedSnapshot(
            usedPercent: 7,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/legacy-bounds",
            stableAccountKey: "sub:legacy-bounds",
            planType: "Plus",
            limitID: "codex",
            accountName: "Bounded Legacy",
            at: now
        )
        XCTAssertTrue(try database.record(quota, createdAt: now.addingTimeInterval(-30)))
        try insertLegacyRows(
            databaseURL: url,
            count: 513,
            start: now.addingTimeInterval(-513 * 60),
            accountName: "Bounded Legacy",
            planType: "Plus",
            limitID: "codex",
            source: "swift"
        )
        try insertRawSnapshot(
            databaseURL: url,
            createdAt: now.addingTimeInterval(-46 * 24 * 60 * 60),
            accountKey: "Bounded Legacy|Plus|codex",
            source: "swift",
            planType: "Plus",
            limitName: "codex",
            accountName: "Bounded Legacy",
            fiveHourUsedPercent: 99,
            fiveHourResetsAt: now.addingTimeInterval(3 * 60 * 60),
            sevenDayUsedPercent: 99,
            sevenDayResetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let values = try database.recordedFiveHourUsedPercents(
            for: quota,
            now: now,
            age: 60 * 24 * 60 * 60
        )

        XCTAssertEqual(values.count, 513, "one stable row plus at most 512 legacy rows")
        XCTAssertFalse(values.contains(99), "legacy rows older than 45 days must not bridge")
    }

    func testLegacyBridgeClaimSkipsNoOpWritesUntilHeartbeatIsDue() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = identifiedSnapshot(
            usedPercent: 7,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/legacy-claim-heartbeat",
            stableAccountKey: "sub:legacy-claim-heartbeat",
            planType: "Plus",
            limitID: "codex",
            accountName: "Heartbeat Legacy",
            at: now
        )
        XCTAssertTrue(try database.record(quota, createdAt: now.addingTimeInterval(-120)))
        try insertRawSnapshot(
            databaseURL: url,
            createdAt: now.addingTimeInterval(-60),
            accountKey: "Heartbeat Legacy|Plus|codex",
            source: "swift",
            planType: "Plus",
            limitName: "codex",
            accountName: "Heartbeat Legacy",
            fiveHourUsedPercent: 6,
            fiveHourResetsAt: now.addingTimeInterval(3 * 60 * 60),
            sevenDayUsedPercent: 20,
            sevenDayResetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
        )

        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: quota, now: now).sorted(),
            [6, 7]
        )
        let driver = SQLiteDatabaseDriver(url: url)
        let firstSeenAt = try XCTUnwrap(driver.readRows(
            "SELECT last_seen_at FROM quota_history_legacy_claims LIMIT 1;"
        ) { statement in
            statement.date(0)
        }.first ?? nil)

        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(
                for: quota,
                now: now.addingTimeInterval(60)
            ).sorted(),
            [6, 7]
        )
        let unchangedSeenAt = try XCTUnwrap(driver.readRows(
            "SELECT last_seen_at FROM quota_history_legacy_claims LIMIT 1;"
        ) { statement in
            statement.date(0)
        }.first ?? nil)
        XCTAssertEqual(unchangedSeenAt, firstSeenAt)

        _ = try database.recordedFiveHourUsedPercents(
            for: quota,
            now: now.addingTimeInterval(60 * 60 + 1)
        )
        let refreshedSeenAt = try XCTUnwrap(driver.readRows(
            "SELECT last_seen_at FROM quota_history_legacy_claims LIMIT 1;"
        ) { statement in
            statement.date(0)
        }.first ?? nil)
        XCTAssertGreaterThan(refreshedSeenAt, firstSeenAt)
    }

    @MainActor
    func testOlderReloadCannotOverwriteNewerRecordedSnapshot() async throws {
        let client = SuspendedQuotaHistoryClient()
        let store = QuotaHistoryStore(historyClient: client)
        let now = Date()
        let quota = snapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            planType: "Pro",
            limitName: "codex",
            at: now
        )

        store.record(quota)
        await waitUntil("seed record request pending") {
            await client.hasPending(.record)
        }
        await client.complete(.record, with: quotaHistorySnapshot(latest: now.addingTimeInterval(-120)))
        await waitUntil("seed record published") {
            store.snapshot.latest == now.addingTimeInterval(-120)
        }
        store.reload()
        await waitUntil("reload request pending") {
            await client.hasPending(.reload)
        }

        store.record(quota)
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
        let quota = snapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            planType: "Pro",
            limitName: "codex",
            at: now
        )

        store.record(quota)
        await waitUntil("seed record request pending") {
            await client.hasPending(.record)
        }
        await client.complete(.record, with: quotaHistorySnapshot(latest: now.addingTimeInterval(-120)))
        await waitUntil("seed record published") {
            store.snapshot.latest == now.addingTimeInterval(-120)
        }
        store.reload()
        await waitUntil("reload request pending") {
            await client.hasPending(.reload)
        }

        store.record(quota)
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

    @MainActor
    func testUnavailableIdentityClearsPublishedHistoryWithoutStartingDatabaseWork() async {
        let client = SuspendedQuotaHistoryClient()
        let store = QuotaHistoryStore(historyClient: client)
        let now = Date()
        var quota = historyContext(at: now)

        store.record(quota)
        await waitUntil("identified record request pending") {
            await client.hasPending(.record)
        }
        await client.complete(.record, with: quotaHistorySnapshot(latest: now))
        await waitUntil("identified history published") {
            store.snapshot.latest == now
        }

        quota.historyIdentity = nil
        store.record(quota)

        XCTAssertEqual(store.snapshot, .empty)
        let hasPendingRecord = await client.hasPending(.record)
        XCTAssertFalse(hasPendingRecord)
    }

    @MainActor
    func testAccountQuotaSourceBindingChangeClearsPublishedHistoryImmediately() async throws {
        let client = SuspendedQuotaHistoryClient()
        let historyStore = QuotaHistoryStore(historyClient: client)
        let quotaStore = AccountQuotaStore(observesUserDefaults: false)
        quotaStore.setHistoryStore(historyStore)
        let sourceA = CodexDataSource(
            codexHome: try makeDatabaseURL().deletingLastPathComponent(),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: try makeDatabaseURL().deletingLastPathComponent(),
            origin: .userSelected
        )
        quotaStore.setDataSource(sourceA)
        let now = Date()

        historyStore.record(historyContext(at: now))
        await waitUntil("source A history request pending") {
            await client.hasPending(.record)
        }
        await client.complete(.record, with: quotaHistorySnapshot(latest: now))
        await waitUntil("source A history published") {
            historyStore.snapshot.latest == now
        }

        quotaStore.setDataSource(sourceB)

        XCTAssertEqual(historyStore.snapshot, .empty)
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
            source: "swift",
            planType: "pro",
            limitName: nil,
            accountName: "来先生",
            fiveHourUsedPercent: 12,
            fiveHourResetsAt: reset,
            sevenDayUsedPercent: 40,
            sevenDayResetsAt: reset.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertFalse(recentValues.contains(55), "same-cycle quota jumps from another source should not create a false 5h pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 88)
    }

    func testRecentHistoryNormalizesRegressionAcrossLegacyAndStableAccountKeys() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let stableTime = now.addingTimeInterval(-20 * 60)
        let legacyTime = now.addingTimeInterval(-10 * 60)

        try database.record(
            snapshot(
                usedPercent: 84,
                reset: reset,
                planType: "Pro",
                limitName: "codex",
                at: stableTime
            ),
            createdAt: stableTime
        )
        try insertRawSnapshot(
            databaseURL: url,
            createdAt: legacyTime,
            accountKey: "来先生|pro",
            source: "swift",
            planType: "pro",
            limitName: nil,
            accountName: "来先生",
            fiveHourUsedPercent: 71,
            fiveHourResetsAt: reset.addingTimeInterval(90),
            sevenDayUsedPercent: 40,
            sevenDayResetsAt: reset.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)

        XCTAssertEqual(
            loaded.recentBins.last?.fiveHourRemainingPercent,
            16,
            "legacy and stable Codex keys must share one monotonic history stream"
        )
    }

    func testRecentHistorySuppressesMidcycleSpikeAcrossResetTimestampDrift() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)

        try database.record(
            snapshot(
                usedPercent: 10,
                reset: reset,
                planType: "Pro",
                limitName: "codex",
                at: now.addingTimeInterval(-20 * 60)
            ),
            createdAt: now.addingTimeInterval(-20 * 60)
        )
        try database.record(
            snapshot(
                usedPercent: 45,
                reset: reset.addingTimeInterval(90),
                planType: "Pro",
                limitName: "codex",
                at: now.addingTimeInterval(-15 * 60)
            ),
            createdAt: now.addingTimeInterval(-15 * 60)
        )
        try database.record(
            snapshot(
                usedPercent: 12,
                reset: reset,
                planType: "Pro",
                limitName: "codex",
                at: now.addingTimeInterval(-10 * 60)
            ),
            createdAt: now.addingTimeInterval(-10 * 60)
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)

        XCTAssertFalse(recentValues.contains(55), "reset timestamp jitter must not split one spike-recovery cycle")
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let recentValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)
        let interpolatedValues = recentValues.filter { $0 < 79.9 && $0 > 78.1 }

        XCTAssertFalse(interpolatedValues.isEmpty, "quota curve should connect 80% to 78% smoothly across a sleep/no-sample gap")
    }

    func testResetCrossingEmitsOneRecentPointThenStaysUnknownUntilNewSample() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(-2 * 60 * 60)
        let oldSample = reset.addingTimeInterval(-60 * 60)
        let newSample = reset.addingTimeInterval(30 * 60)

        try database.record(
            snapshot(usedPercent: 50, reset: reset, planType: "Pro", limitName: "codex", at: oldSample),
            createdAt: oldSample
        )
        try database.record(
            snapshot(usedPercent: 20, reset: now.addingTimeInterval(5 * 60 * 60), planType: "Pro", limitName: "codex", at: newSample),
            createdAt: newSample
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let boundary = try XCTUnwrap(loaded.recentBins.firstIndex {
            $0.start.addingTimeInterval(5 * 60) == reset
        })
        let recovered = try XCTUnwrap(loaded.recentBins.firstIndex {
            $0.start.addingTimeInterval(5 * 60) >= newSample
        })

        XCTAssertEqual(loaded.recentBins.filter { $0.fiveHourRemainingPercent == 100 }.count, 1)
        XCTAssertEqual(loaded.recentBins[boundary].fiveHourRemainingPercent, 100)
        XCTAssertTrue(loaded.recentBins[(boundary + 1)..<recovered].allSatisfy {
            $0.fiveHourRemainingPercent == nil
        })
        XCTAssertEqual(loaded.recentBins[recovered].fiveHourRemainingPercent, 80)
    }

    func testHourlyResetCrossingEmitsOnePointWithoutExtendingTwoHours() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(-2 * 60 * 60)
        let createdAt = reset.addingTimeInterval(-2 * 60 * 60)

        try database.record(
            snapshot(usedPercent: 50, reset: reset, planType: "Pro", limitName: "codex", at: createdAt),
            createdAt: createdAt
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let boundary = try XCTUnwrap(loaded.hourlyBins.firstIndex {
            $0.start.addingTimeInterval(60 * 60) == reset
        })

        XCTAssertEqual(loaded.hourlyBins.filter { $0.fiveHourRemainingPercent == 100 }.count, 1)
        XCTAssertEqual(loaded.hourlyBins[boundary].fiveHourRemainingPercent, 100)
        XCTAssertNil(loaded.hourlyBins[boundary + 1].fiveHourRemainingPercent)
        XCTAssertNil(loaded.hourlyBins[boundary + 2].fiveHourRemainingPercent)
    }

    func testStaleResetUsesNinetyMinuteCarryAndWindowsRemainIndependent() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdAt = now.addingTimeInterval(-2 * 60 * 60)
        let staleFiveHourReset = createdAt.addingTimeInterval(-60)
        let sevenDayReset = now.addingTimeInterval(-30 * 60)

        try database.record(
            snapshot(
                usedPercent: 50,
                sevenDayUsedPercent: 30,
                reset: staleFiveHourReset,
                sevenDayReset: sevenDayReset,
                planType: "Pro",
                limitName: "codex",
                at: createdAt
            ),
            createdAt: createdAt
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let sevenBoundary = try XCTUnwrap(loaded.recentBins.firstIndex {
            $0.start.addingTimeInterval(5 * 60) == sevenDayReset
        })
        let carriedFive = loaded.recentBins.filter { $0.fiveHourRemainingPercent == 50 }

        XCTAssertFalse(carriedFive.isEmpty)
        XCTAssertFalse(loaded.recentBins.contains { $0.fiveHourRemainingPercent == 100 })
        XCTAssertNil(loaded.recentBins.last?.fiveHourRemainingPercent)
        XCTAssertEqual(loaded.recentBins[sevenBoundary].sevenDayRemainingPercent, 100)
        XCTAssertEqual(loaded.recentBins[sevenBoundary].fiveHourRemainingPercent, 50)
        XCTAssertNil(loaded.recentBins[sevenBoundary + 1].sevenDayRemainingPercent)
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let recentValues = loaded.recentBins.compactMap(\.sevenDayRemainingPercent)

        XCTAssertFalse(recentValues.contains(0), "recovered full-usage spike should not create a 7d quota pit")
        XCTAssertGreaterThanOrEqual(recentValues.min() ?? 100, 98)
    }

    func testHistoryReclassifiesLegacySevenDayOnlyRowsWrittenIntoFiveHourColumns() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        try database.migrate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdAt = now.addingTimeInterval(-5 * 60)
        let sevenDayReset = createdAt.addingTimeInterval(7 * 24 * 60 * 60)
        var legacy = historyContext(at: createdAt)
        legacy.fiveHour = AccountQuotaWindow(label: "5h", usedPercent: 0, resetsAt: sevenDayReset)
        legacy.sevenDay = nil
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: legacy,
            source: "swift",
            createdAt: createdAt
        )

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)

        XCTAssertEqual(loaded.recentBins.last?.fiveHourRemainingPercent, nil)
        XCTAssertEqual(loaded.recentBins.last?.sevenDayRemainingPercent, 100)
    }

    func testHistorySuppressesRecoveredFullRemainingJumpWhenResetTemporarilyShifts() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        try database.migrate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stableFiveReset = now.addingTimeInterval(4 * 60 * 60)
        let shiftedFiveReset = stableFiveReset.addingTimeInterval(-2 * 60 * 60)
        let stableSevenReset = now.addingTimeInterval(157 * 60 * 60)
        let shiftedSevenReset = stableSevenReset.addingTimeInterval(2 * 60 * 60)
        for (minutes, fiveUsed, fiveReset, sevenUsed, sevenReset) in [
            (-15.0, 45, stableFiveReset, 32, stableSevenReset),
            (-11.0, 2, shiftedFiveReset, 1, shiftedSevenReset),
            (-9.0, 46, stableFiveReset, 33, stableSevenReset)
        ] {
            var quota = historyContext(at: now.addingTimeInterval(minutes * 60))
            quota.fiveHour = AccountQuotaWindow(label: "5h", usedPercent: fiveUsed, resetsAt: fiveReset)
            quota.sevenDay = AccountQuotaWindow(label: "7d", usedPercent: sevenUsed, resetsAt: sevenReset)
            try insertStableIdentitySnapshot(
                databaseURL: url,
                quota: quota,
                source: "swift",
                createdAt: now.addingTimeInterval(minutes * 60)
            )
        }

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
        let fiveHourValues = loaded.recentBins.compactMap(\.fiveHourRemainingPercent)
        let sevenDayValues = loaded.recentBins.compactMap(\.sevenDayRemainingPercent)

        XCTAssertFalse(fiveHourValues.contains(98), "the recovered official reset glitch must not create a 5h full-remaining peak")
        XCTAssertFalse(sevenDayValues.contains(99), "the recovered official reset glitch must not create a 7d full-remaining peak")
        XCTAssertEqual(fiveHourValues.last, 54)
        XCTAssertEqual(sevenDayValues.last, 67)
    }

    func testRecentHistorySuppressesLatestSevenDayFullUsageSpike() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(3 * 60 * 60)
        let sevenDayReset = now.addingTimeInterval(4 * 24 * 60 * 60)

        try database.record(snapshot(usedPercent: 2, sevenDayUsedPercent: 0, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-20 * 60)), createdAt: now.addingTimeInterval(-20 * 60))
        try database.record(snapshot(usedPercent: 3, sevenDayUsedPercent: 100, reset: fiveHourReset, sevenDayReset: sevenDayReset, planType: "Pro", limitName: "codex", at: now.addingTimeInterval(-5 * 60)), createdAt: now.addingTimeInterval(-5 * 60))

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
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

        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)

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
        let loaded = try database.loadSnapshot(for: historyContext(at: now), now: now)
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
        var quota = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: sevenDayUsedPercent, resetsAt: sevenDayReset ?? reset.addingTimeInterval(4 * 24 * 60 * 60)),
            planType: planType,
            limitName: limitName,
            accountName: "来先生",
            status: "额度已更新",
            updatedAt: date
        )
        let limitID = limitName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? limitName
            : "codex"
        quota.selectedLimitID = limitID
        quota.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "/fixture/swift-history",
            stableAccountKey: "sub:swift-history-account",
            planType: planType,
            limitID: limitID
        )
        return quota
    }

    private func historyContext(at date: Date) -> AccountQuotaSnapshot {
        snapshot(
            usedPercent: 0,
            reset: date.addingTimeInterval(3 * 60 * 60),
            planType: "Pro",
            limitName: "codex",
            at: date
        )
    }

    private func identifiedSnapshot(
        usedPercent: Int,
        reset: Date,
        homeIdentity: String,
        stableAccountKey: String,
        planType: String,
        limitID: String,
        accountName: String,
        at date: Date
    ) -> AccountQuotaSnapshot {
        var quota = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: reset),
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: usedPercent,
                resetsAt: reset.addingTimeInterval(4 * 24 * 60 * 60)
            ),
            planType: planType,
            limitName: limitID,
            accountName: accountName,
            status: "额度已更新",
            updatedAt: date
        )
        quota.selectedLimitID = limitID
        quota.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            planType: planType,
            limitID: limitID
        )
        return quota
    }

    private func fixtureSnapshot(
        _ step: SharedQuotaHistoryIdentityStep,
        at date: Date
    ) -> AccountQuotaSnapshot {
        var quota = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(
                label: "5h",
                usedPercent: step.usedPercent ?? 0,
                resetsAt: date.addingTimeInterval(3 * 60 * 60)
            ),
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: step.usedPercent ?? 0,
                resetsAt: date.addingTimeInterval(4 * 24 * 60 * 60)
            ),
            planType: step.plan,
            limitName: step.limitId,
            accountName: step.displayName,
            status: "fixture",
            updatedAt: date
        )
        quota.selectedLimitID = step.limitId
        if let homeIdentity = step.homeIdentity {
            quota.historyIdentity = QuotaHistoryIdentity(
                homeIdentity: homeIdentity,
                stableAccountKey: step.stableAccountKey,
                planType: step.plan,
                limitID: step.limitId
            )
        }
        return quota
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
                        seven_day_used_percent, seven_day_resets_at, status,
                        identity_version, home_identity, stable_account_key,
                        identity_plan_type, identity_limit_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .date(createdAt),
                        .text("来先生|Pro|codex"),
                        .text("swift"),
                        .text("Pro"),
                        .text("codex"),
                        .text("来先生"),
                        .int(10),
                        .date(fiveHourReset),
                        .int(40),
                        .date(sevenDayReset),
                        .text("stable"),
                        .int(1),
                        .text("/fixture/swift-history"),
                        .text("sub:swift-history-account"),
                        .text("Pro"),
                        .text("codex")
                    ]
                )
            }
        }
    }

    private func insertStableIdentitySnapshot(
        databaseURL: URL,
        quota: AccountQuotaSnapshot,
        source: String,
        createdAt: Date
    ) throws {
        let identity = try XCTUnwrap(quota.historyIdentity)
        let accountName = quota.accountName ?? "default"
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.execute(
            """
            INSERT INTO quota_snapshots (
                created_at, account_key, source, plan_type, limit_name, account_name,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status,
                identity_version, home_identity, stable_account_key,
                identity_plan_type, identity_limit_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .date(createdAt),
                .text("\(accountName)|\(identity.planType)|\(identity.limitID)"),
                .text(source),
                .text(identity.planType),
                .text(identity.limitID),
                .text(accountName),
                .optionalInt(quota.fiveHour?.usedPercent),
                .optionalDate(quota.fiveHour?.resetsAt),
                .optionalInt(quota.sevenDay?.usedPercent),
                .optionalDate(quota.sevenDay?.resetsAt),
                .text(quota.status),
                .int(identity.version),
                .text(identity.homeIdentity),
                .text(identity.stableAccountKey),
                .text(identity.planType),
                .text(identity.limitID)
            ]
        )
    }

    private func insertLegacyRows(
        databaseURL: URL,
        count: Int,
        start: Date,
        accountName: String,
        planType: String,
        limitID: String,
        source: String?
    ) throws {
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.transaction { connection in
            for index in 0..<count {
                let createdAt = start.addingTimeInterval(Double(index) * 60)
                let usedPercent = 20 + index % 70
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
                        .text("\(accountName)|\(planType)|\(limitID)"),
                        .optionalText(source),
                        .text(planType),
                        .text(limitID),
                        .text(accountName),
                        .int(usedPercent),
                        .date(createdAt.addingTimeInterval(3 * 60 * 60)),
                        .int(usedPercent),
                        .date(createdAt.addingTimeInterval(4 * 24 * 60 * 60)),
                        .text("legacy")
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

    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
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

private struct SharedQuotaHistoryIdentityFixture: Decodable {
    let fixtureVersion: Int
    let identityVersion: Int
    let scenarios: [SharedQuotaHistoryIdentityScenario]
}

private struct SharedQuotaHistoryIdentityScenario: Decodable {
    let id: String
    let steps: [SharedQuotaHistoryIdentityStep]
}

private struct SharedQuotaHistoryIdentityStep: Decodable {
    let operation: String
    let homeIdentity: String?
    let stableAccountKey: String?
    let displayName: String
    let plan: String
    let limitId: String
    let source: String?
    let usedPercent: Int?
    let expectedAccepted: Bool?
    let expectedUsedPercents: [Int]?
}
