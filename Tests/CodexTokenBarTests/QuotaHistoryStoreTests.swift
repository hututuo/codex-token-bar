import SQLite3
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

    func testPeerStableHistoryAddsRealZeroWithoutWritingPeerSchema() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let localQuota = identifiedSnapshot(
            usedPercent: 82,
            reset: reset,
            homeIdentity: "/fixture/peer-home",
            stableAccountKey: "sub:peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Peer User",
            at: now.addingTimeInterval(-60)
        )
        let peerQuota = identifiedSnapshot(
            usedPercent: 100,
            reset: reset,
            homeIdentity: "/fixture/peer-home",
            stableAccountKey: "sub:peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Peer User",
            at: now
        )
        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(localQuota, createdAt: now.addingTimeInterval(-60)))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: peerQuota,
            source: "tauri",
            createdAt: now
        )

        let loaded = try database.loadSnapshot(for: localQuota, now: now)

        XCTAssertTrue(
            loaded.recentBins.contains { $0.sevenDayRemainingPercent == 0 },
            "a stable Tauri peer row with used_7d=100 must remain visible as 0% remaining"
        )
        XCTAssertTrue(
            loaded.hourlyBins.contains { $0.sevenDayRemainingPercent == 0 },
            "the same peer zero must remain available to the 7d/30d coarse history"
        )
        let peerTables = try SQLiteDatabaseDriver(url: peerURL).readRows(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;"
        ) { statement in
            statement.text(0) ?? ""
        }
        XCTAssertFalse(
            peerTables.contains("quota_history_legacy_claims"),
            "peer reads must not migrate or create Swift-only claim tables"
        )
    }

    func testPeerWALSnapshotRemainsReadableWithoutPeerSchemaWrites() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true, enableWAL: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = identifiedSnapshot(
            usedPercent: 100,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/wal-peer-home",
            stableAccountKey: "sub:wal-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "WAL Peer User",
            at: now
        )
        var localQuota = quota
        localQuota.fiveHour = AccountQuotaWindow(
            label: "5h",
            usedPercent: 82,
            resetsAt: quota.fiveHour?.resetsAt
        )
        localQuota.sevenDay = AccountQuotaWindow(
            label: "7d",
            usedPercent: 82,
            resetsAt: quota.sevenDay?.resetsAt
        )
        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(localQuota, createdAt: now.addingTimeInterval(-60)))

        // Seed the peer after the local row so the zero below can only arrive
        // through the read-only WAL supplement, not local normalization.
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: quota,
            source: "tauri",
            createdAt: now,
            enableWAL: true
        )
        let walURL = URL(fileURLWithPath: peerURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: peerURL.path + "-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))

        let loaded = try database.loadSnapshot(for: localQuota, now: now)
        XCTAssertTrue(loaded.hourlyBins.contains { $0.sevenDayRemainingPercent == 0 })

        let peerTables = try SQLiteDatabaseDriver(
            url: peerURL,
            readOnly: true,
            createsFileIfMissing: false
        ).readRows("SELECT name FROM sqlite_master WHERE type = 'table';") { statement in
            statement.text(0) ?? ""
        }
        XCTAssertFalse(peerTables.contains("quota_history_legacy_claims"))
    }

    func testPeerCheckpointedWALWithoutSidecarsMergesThroughImmutableReadOnlyFallback() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true, enableWAL: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let localQuota = identifiedSnapshot(
            usedPercent: 82,
            reset: reset,
            homeIdentity: "/fixture/immutable-peer-home",
            stableAccountKey: "sub:immutable-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Immutable Peer User",
            at: now.addingTimeInterval(-60)
        )
        let peerQuota = identifiedSnapshot(
            usedPercent: 100,
            reset: reset,
            homeIdentity: "/fixture/immutable-peer-home",
            stableAccountKey: "sub:immutable-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Immutable Peer User",
            at: now
        )

        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(localQuota, createdAt: now.addingTimeInterval(-60)))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: peerQuota,
            source: "tauri",
            createdAt: now,
            enableWAL: true
        )
        try SQLiteDatabaseDriver(url: peerURL, enableWAL: true)
            .execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try removeQuotaHistorySidecars(at: peerURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: peerURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: peerURL.path + "-shm"))
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: localQuota, now: now),
            [82, 100],
            "a checkpointed WAL main file remains a valid peer supplement without sidecars"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: peerURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: peerURL.path + "-shm"))
    }

    func testPeerSidecarCandidatesResolveToTheQuotaHistoryMainDatabase() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true, enableWAL: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let localQuota = identifiedSnapshot(
            usedPercent: 82,
            reset: reset,
            homeIdentity: "/fixture/sidecar-peer-home",
            stableAccountKey: "sub:sidecar-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Sidecar Peer User",
            at: now.addingTimeInterval(-60)
        )
        let peerQuota = identifiedSnapshot(
            usedPercent: 100,
            reset: reset,
            homeIdentity: "/fixture/sidecar-peer-home",
            stableAccountKey: "sub:sidecar-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Sidecar Peer User",
            at: now
        )

        let localDatabase = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try localDatabase.record(localQuota, createdAt: now.addingTimeInterval(-60)))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: peerQuota,
            source: "tauri",
            createdAt: now,
            enableWAL: true
        )

        let walURL = URL(fileURLWithPath: peerURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: peerURL.path + "-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))

        for candidateURL in [walURL, shmURL] {
            let database = QuotaHistoryDatabase(
                databaseURL: localURL,
                peerDatabaseURL: candidateURL
            )
            XCTAssertEqual(
                try database.recordedFiveHourUsedPercents(for: localQuota, now: now),
                [82, 100],
                "a sidecar candidate must resolve to quota-history.sqlite, not open as a second main database"
            )
        }

        // A checkpoint may rotate or remove both sidecars. A stale candidate
        // URL must still resolve to the surviving main database and retain the
        // valid peer history.
        try SQLiteDatabaseDriver(url: peerURL, enableWAL: true)
            .execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let afterRotation = QuotaHistoryDatabase(
            databaseURL: localURL,
            peerDatabaseURL: walURL
        )
        XCTAssertEqual(
            try afterRotation.recordedFiveHourUsedPercents(for: localQuota, now: now),
            [82, 100],
            "sidecar rotation must not turn a stale WAL URL into the main database"
        )
    }

    func testLockedPeerFallsBackQuicklyAndResumesAfterUnlock() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let localQuota = identifiedSnapshot(
            usedPercent: 82,
            reset: reset,
            homeIdentity: "/fixture/locked-peer-home",
            stableAccountKey: "sub:locked-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Locked Peer User",
            at: now.addingTimeInterval(-60)
        )
        let peerQuota = identifiedSnapshot(
            usedPercent: 100,
            reset: reset,
            homeIdentity: "/fixture/locked-peer-home",
            stableAccountKey: "sub:locked-peer-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Locked Peer User",
            at: now
        )

        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(localQuota, createdAt: now.addingTimeInterval(-60)))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: peerQuota,
            source: "tauri",
            createdAt: now
        )

        var locked: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                peerURL.path,
                &locked,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        defer {
            if let locked {
                sqlite3_exec(locked, "ROLLBACK;", nil, nil, nil)
                sqlite3_close_v2(locked)
            }
        }
        XCTAssertNotNil(locked)
        XCTAssertEqual(sqlite3_exec(locked, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let start = Date()
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: localQuota, now: now),
            [82],
            "a locked peer must not hide local history"
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "peer busy downgrade should stay bounded")

        XCTAssertEqual(sqlite3_exec(locked, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: localQuota, now: now),
            [82, 100],
            "valid peer history should resume after the lock is released"
        )
    }

    func testPeerMergeDropsExactMigrationDuplicateButRetainsOrderedIndependentSource() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let first = identifiedSnapshot(
            usedPercent: 42,
            reset: reset,
            homeIdentity: "/fixture/merge-home",
            stableAccountKey: "sub:merge-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Merge User",
            at: now.addingTimeInterval(-120)
        )
        let second = identifiedSnapshot(
            usedPercent: 50,
            reset: reset,
            homeIdentity: "/fixture/merge-home",
            stableAccountKey: "sub:merge-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Merge User",
            at: now.addingTimeInterval(-60)
        )
        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        let firstAt = now.addingTimeInterval(-120)
        let secondAt = now.addingTimeInterval(-60)
        XCTAssertTrue(try database.record(first, createdAt: firstAt))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: first,
            source: "swift",
            createdAt: firstAt
        )
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: second,
            source: "tauri",
            createdAt: secondAt
        )

        let values = try database.recordedFiveHourUsedPercents(for: first, now: now)

        XCTAssertEqual(
            values,
            [42, 50],
            "identical migration rows dedupe, while a Tauri observation remains time-ordered"
        )
    }

    func testPeerMergeCollapsesSameQuotaObservationAcrossRuntimeSources() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = identifiedSnapshot(
            usedPercent: 42,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/cross-runtime-merge",
            stableAccountKey: "sub:cross-runtime-merge",
            planType: "Pro",
            limitID: "codex",
            accountName: "Cross Runtime Merge",
            at: now
        )
        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)

        XCTAssertTrue(try database.record(quota, createdAt: now))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: quota,
            source: "tauri",
            createdAt: now
        )

        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: quota, now: now),
            [42],
            "the same quota observation must not be counted once per runtime"
        )
    }

    func testUnavailableOrLegacyPeerFallsBackToLocalHistory() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = identifiedSnapshot(
            usedPercent: 17,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/fallback-home",
            stableAccountKey: "sub:fallback-account",
            planType: "Pro",
            limitID: "codex",
            accountName: "Fallback User",
            at: now
        )

        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(quota, createdAt: now))
        try FileManager.default.createDirectory(at: peerURL, withIntermediateDirectories: true)
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: quota, now: now),
            [17],
            "a missing/unopenable peer must not make the main history fail"
        )

        try FileManager.default.removeItem(at: peerURL)
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: false)
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: quota, now: now),
            [17],
            "an old peer schema without stable identity columns must be ignored"
        )
    }

    func testSwiftMaintenanceAndReadsNeverMutatePeerDatabase() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)
        let now = Date()
        let quota = identifiedSnapshot(
            usedPercent: 27,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/read-only-peer",
            stableAccountKey: "sub:read-only-peer",
            planType: "Pro",
            limitID: "codex",
            accountName: "Read Only Peer",
            at: now
        )
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: quota,
            source: "tauri",
            createdAt: now.addingTimeInterval(-60)
        )
        let peerDriver = SQLiteDatabaseDriver(url: peerURL, readOnly: true)
        let columnsBefore = try peerDriver.readRows("PRAGMA table_info(quota_snapshots);") {
            $0.text(1) ?? ""
        }
        let rowsBefore = try peerDriver.readRows(
            "SELECT created_at, five_hour_used_percent, seven_day_used_percent FROM quota_snapshots ORDER BY id;"
        ) { statement in
            [
                String(statement.double(0) ?? 0),
                String(statement.int(1) ?? -1),
                String(statement.int(2) ?? -1)
            ].joined(separator: "|")
        }

        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        try database.migrate()
        XCTAssertTrue(try database.record(quota, createdAt: now))
        _ = try database.loadSnapshot(for: quota, now: now)

        let columnsAfter = try peerDriver.readRows("PRAGMA table_info(quota_snapshots);") {
            $0.text(1) ?? ""
        }
        let rowsAfter = try peerDriver.readRows(
            "SELECT created_at, five_hour_used_percent, seven_day_used_percent FROM quota_snapshots ORDER BY id;"
        ) { statement in
            [
                String(statement.double(0) ?? 0),
                String(statement.int(1) ?? -1),
                String(statement.int(2) ?? -1)
            ].joined(separator: "|")
        }
        XCTAssertEqual(columnsAfter, columnsBefore)
        XCTAssertEqual(rowsAfter, rowsBefore)
        XCTAssertFalse(columnsAfter.contains("five_hour_cycle_generation"))
    }

    func testPeerStableIdentityMismatchCannotCrossAccountHistory() throws {
        let localURL = try makeDatabaseURL()
        let peerURL = try makeDatabaseURL()
        try createPeerQuotaSnapshotsTable(at: peerURL, includeStableIdentity: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let localQuota = identifiedSnapshot(
            usedPercent: 12,
            reset: reset,
            homeIdentity: "/fixture/account-a-home",
            stableAccountKey: "sub:account-a",
            planType: "Pro",
            limitID: "codex",
            accountName: "Same Display Name",
            at: now
        )
        let otherAccountQuota = identifiedSnapshot(
            usedPercent: 99,
            reset: reset,
            homeIdentity: "/fixture/account-b-home",
            stableAccountKey: "sub:account-b",
            planType: "Pro",
            limitID: "codex",
            accountName: "Same Display Name",
            at: now.addingTimeInterval(30)
        )
        let database = QuotaHistoryDatabase(databaseURL: localURL, peerDatabaseURL: peerURL)
        XCTAssertTrue(try database.record(localQuota, createdAt: now))
        try insertStableIdentitySnapshot(
            databaseURL: peerURL,
            quota: otherAccountQuota,
            source: "tauri",
            createdAt: now.addingTimeInterval(30)
        )

        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(for: localQuota, now: now.addingTimeInterval(60)),
            [12],
            "same display/account/limit labels cannot override a different stable identity"
        )
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

    func testSafelyClaimedLegacyBridgeIsPermanentAndUnbounded() throws {
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

        XCTAssertEqual(values.count, 515, "all safely claimed legacy rows remain available")
        XCTAssertTrue(values.contains(99), "legacy rows older than 45 days remain permanently retained")
    }

    func testStableQuotaHistoryIsRetainedBeyondFormerFortyFiveDayWindow() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let oldQuota = identifiedSnapshot(
            usedPercent: 11,
            reset: oldDate.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/permanent-retention",
            stableAccountKey: "sub:permanent-retention",
            planType: "Pro",
            limitID: "codex",
            accountName: "Permanent Retention",
            at: oldDate
        )
        let currentQuota = identifiedSnapshot(
            usedPercent: 22,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/permanent-retention",
            stableAccountKey: "sub:permanent-retention",
            planType: "Pro",
            limitID: "codex",
            accountName: "Permanent Retention",
            at: now
        )

        XCTAssertTrue(try database.record(oldQuota, createdAt: oldDate))
        XCTAssertTrue(try database.record(currentQuota, createdAt: now))

        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(
                for: currentQuota,
                now: now,
                age: 90 * 24 * 60 * 60
            ),
            [11, 22]
        )
    }

    func testResetTimestampJitterIsDeduplicatedButUsageTransitionsAreRetained() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let first = identifiedSnapshot(
            usedPercent: 1,
            reset: reset,
            homeIdentity: "/fixture/reset-jitter",
            stableAccountKey: "sub:reset-jitter",
            planType: "Pro",
            limitID: "codex",
            accountName: "Reset Jitter",
            at: now
        )
        let jittered = identifiedSnapshot(
            usedPercent: 1,
            reset: reset.addingTimeInterval(5),
            homeIdentity: "/fixture/reset-jitter",
            stableAccountKey: "sub:reset-jitter",
            planType: "Pro",
            limitID: "codex",
            accountName: "Reset Jitter",
            at: now.addingTimeInterval(60)
        )
        let changed = identifiedSnapshot(
            usedPercent: 2,
            reset: reset.addingTimeInterval(7),
            homeIdentity: "/fixture/reset-jitter",
            stableAccountKey: "sub:reset-jitter",
            planType: "Pro",
            limitID: "codex",
            accountName: "Reset Jitter",
            at: now.addingTimeInterval(5 * 60)
        )

        XCTAssertTrue(try database.record(first, createdAt: now))
        XCTAssertTrue(try database.record(jittered, createdAt: now.addingTimeInterval(60)))
        let driver = SQLiteDatabaseDriver(url: url)
        XCTAssertEqual(
            try driver.readRows(
                "SELECT count(*) FROM quota_snapshots WHERE identity_version = 1;"
            ) { statement in
                statement.int(0) ?? 0
            }.first,
            1,
            "reset countdown jitter alone must not create a duplicate row"
        )

        XCTAssertTrue(try database.record(changed, createdAt: now.addingTimeInterval(5 * 60)))
        XCTAssertEqual(
            try database.recordedFiveHourUsedPercents(
                for: changed,
                now: now.addingTimeInterval(5 * 60),
                age: 60 * 60
            ),
            [1, 2],
            "a real 99% to 98% remaining transition must keep both timestamped observations"
        )
        XCTAssertEqual(
            try driver.readRows(
                "SELECT created_at FROM quota_snapshots WHERE identity_version = 1 ORDER BY created_at;"
            ) { statement in
                statement.date(0)
            }.compactMap { $0 },
            [now, now.addingTimeInterval(5 * 60)]
        )
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

    func testInitialHistoryLoadIncludesTwoMonthsForWarmRangeBuffer() throws {
        let url = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-45 * 24 * 60 * 60)
        let oldQuota = identifiedSnapshot(
            usedPercent: 11,
            reset: oldDate.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/two-month-window",
            stableAccountKey: "sub:two-month-window",
            planType: "Pro",
            limitID: "codex",
            accountName: "Two Month Window",
            at: oldDate
        )
        let currentQuota = identifiedSnapshot(
            usedPercent: 22,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/two-month-window",
            stableAccountKey: "sub:two-month-window",
            planType: "Pro",
            limitID: "codex",
            accountName: "Two Month Window",
            at: now
        )
        try database.migrate()
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: oldQuota,
            source: "swift",
            createdAt: oldDate
        )
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: currentQuota,
            source: "swift",
            createdAt: now
        )

        let loaded = try database.loadSnapshot(for: currentQuota, now: now)

        XCTAssertTrue(
            loaded.hourlyBins.contains { $0.fiveHourRemainingPercent == 89 },
            "the initial load should include a quota sample from 45 days ago"
        )
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

    func testCycleGenerationRequiresStrictResetDeltaAndFullBoundarySample() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let make = { (used: Int, shifted: TimeInterval, at: Date) in
            self.identifiedSnapshot(
                usedPercent: used,
                reset: reset.addingTimeInterval(shifted),
                homeIdentity: "/fixture/cycle-generation",
                stableAccountKey: "sub:cycle-generation",
                planType: "Pro",
                limitID: "codex",
                accountName: "Cycle",
                at: at
            )
        }

        XCTAssertTrue(try database.record(make(20, 0, now), createdAt: now))
        XCTAssertTrue(try database.record(make(0, 300, now.addingTimeInterval(60)), createdAt: now.addingTimeInterval(60)))
        XCTAssertTrue(try database.record(make(0, 301, now.addingTimeInterval(120)), createdAt: now.addingTimeInterval(120)))
        XCTAssertTrue(try database.record(make(1, 301, now.addingTimeInterval(180)), createdAt: now.addingTimeInterval(180)))

        let rows = try SQLiteDatabaseDriver(url: url).readRows(
            """
            SELECT five_hour_used_percent, five_hour_cycle_generation, five_hour_reset_anchor
            FROM quota_snapshots ORDER BY created_at;
            """
        ) { statement in
            (statement.int(0), statement.int(1), statement.int(2))
        }
        XCTAssertEqual(rows.map(\.0), [20, 0, 0, 1])
        XCTAssertEqual(rows.map(\.1), [0, 0, 1, 1])
        XCTAssertEqual(rows.map(\.2), [1, 0, 1, 0])
    }

    func testNormalizedCurrentQuotaPublishesIndependentOpaqueCycleIDs() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let fiveReset = now.addingTimeInterval(3 * 60 * 60)
        let sevenReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let make = { (fiveUsed: Int, sevenUsed: Int, fiveShift: TimeInterval, sevenShift: TimeInterval, at: Date) in
            var quota = AccountQuotaSnapshot(
                fiveHour: AccountQuotaWindow(
                    label: "5h",
                    usedPercent: fiveUsed,
                    resetsAt: fiveReset.addingTimeInterval(fiveShift)
                ),
                sevenDay: AccountQuotaWindow(
                    label: "7d",
                    usedPercent: sevenUsed,
                    resetsAt: sevenReset.addingTimeInterval(sevenShift)
                ),
                planType: "Pro",
                limitName: "codex",
                accountName: "Cycle IDs",
                status: "额度已更新",
                updatedAt: at
            )
            quota.selectedLimitID = "codex"
            quota.historyIdentity = QuotaHistoryIdentity(
                homeIdentity: "/fixture/current-cycle-ids",
                stableAccountKey: "sub:current-cycle-ids",
                planType: "Pro",
                limitID: "codex"
            )
            return quota
        }

        let initial = make(20, 30, 0, 0, now)
        XCTAssertTrue(try database.record(initial, createdAt: now))
        let sameCycle = try database.normalizedSnapshot(
            make(1, 31, 301, 301, now.addingTimeInterval(60))
        )
        XCTAssertEqual(sameCycle.fiveHour?.cycleID, "g0")
        XCTAssertEqual(sameCycle.sevenDay?.cycleID, "g0")

        let fiveOnlyReset = try database.normalizedSnapshot(
            make(0, 32, 301, 302, now.addingTimeInterval(120))
        )
        XCTAssertEqual(fiveOnlyReset.fiveHour?.cycleID, "g1")
        XCTAssertEqual(fiveOnlyReset.sevenDay?.cycleID, "g0")
    }

    func testBoundedHistoryReplayKeepsPersistedCurrentCycleID() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let dates = [
            now.addingTimeInterval(-61 * 24 * 60 * 60),
            now.addingTimeInterval(-59 * 24 * 60 * 60),
            now
        ]
        for (index, date) in dates.enumerated() {
            let quota = identifiedSnapshot(
                usedPercent: index == 0 ? 20 : 0,
                reset: date.addingTimeInterval(3 * 60 * 60),
                homeIdentity: "/fixture/bounded-cycle-offset",
                stableAccountKey: "sub:bounded-cycle-offset",
                planType: "Pro",
                limitID: "codex",
                accountName: "Bounded Cycle Offset",
                at: date
            )
            XCTAssertTrue(try database.record(quota, createdAt: date))
        }

        let current = identifiedSnapshot(
            usedPercent: 0,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/bounded-cycle-offset",
            stableAccountKey: "sub:bounded-cycle-offset",
            planType: "Pro",
            limitID: "codex",
            accountName: "Bounded Cycle Offset",
            at: now
        )
        let normalized = try database.normalizedSnapshot(current)
        let loaded = try database.loadSnapshot(for: current, now: now)

        XCTAssertEqual(normalized.fiveHour?.cycleID, "g2")
        XCTAssertEqual(
            loaded.recentBins.last?.fiveHourObservations.last?.cycleID,
            "g2",
            "the two-month cutoff must not renumber the current persisted cycle"
        )
    }

    func testFiveMinuteStableBandWritesFinalRawAnchorAndCompactsOnlyResetRows() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let make = { (shifted: TimeInterval, at: Date) in
            self.identifiedSnapshot(
                usedPercent: 20,
                reset: reset.addingTimeInterval(shifted),
                homeIdentity: "/fixture/five-minute-stability",
                stableAccountKey: "sub:five-minute-stability",
                planType: "Pro",
                limitID: "codex",
                accountName: "Stable",
                at: at
            )
        }

        XCTAssertTrue(try database.record(make(0, now), createdAt: now))
        XCTAssertTrue(try database.record(make(60, now.addingTimeInterval(60)), createdAt: now.addingTimeInterval(60)))
        XCTAssertTrue(try database.record(make(61, now.addingTimeInterval(120)), createdAt: now.addingTimeInterval(120)))
        XCTAssertTrue(try database.record(make(59, now.addingTimeInterval(240)), createdAt: now.addingTimeInterval(240)))
        let finalAt = now.addingTimeInterval(360)
        XCTAssertTrue(try database.record(make(60, finalAt), createdAt: finalAt))

        let driver = SQLiteDatabaseDriver(url: url)
        var anchors = try driver.readRows(
            "SELECT created_at, five_hour_reset_anchor FROM quota_snapshots ORDER BY created_at;"
        ) { ($0.date(0), $0.int(1) ?? 0) }
        XCTAssertEqual(anchors.count, 3, "small in-band samples stay out of the history table")
        XCTAssertEqual(
            try XCTUnwrap(anchors.last?.0).timeIntervalSince1970,
            finalAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the final server observation keeps its original timestamp"
        )
        XCTAssertEqual(anchors.last?.1, 1)

        try driver.execute(
            "UPDATE quota_history_maintenance SET value = ? WHERE key = 'last_compacted_at';",
            bindings: [.text(String(now.addingTimeInterval(-25 * 60 * 60).timeIntervalSince1970))]
        )
        try database.migrate()

        anchors = try driver.readRows(
            "SELECT created_at, five_hour_reset_anchor FROM quota_snapshots ORDER BY created_at;"
        ) { ($0.date(0), $0.int(1) ?? 0) }
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors.map(\.1), [1, 1])
        XCTAssertEqual(
            try XCTUnwrap(anchors.last?.0).timeIntervalSince1970,
            finalAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testMigrationCompacts56And59Then15SecondDriftWithoutLosingQuotaChanges() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let observed = Date(timeIntervalSince1970: 1_900_720_000)
        let reset = Date(timeIntervalSince1970: 1_900_730_000)
        let observations: [(TimeInterval, Int, TimeInterval)] = [
            (0, 20, 0),
            (60, 20, 56),
            (120, 21, 59),
            (180, 21, 15),
            (240, 22, 16),
            (480, 22, 14)
        ]
        try database.migrate()
        for (offset, used, resetDelta) in observations {
            let createdAt = observed.addingTimeInterval(offset)
            let quota = identifiedSnapshot(
                usedPercent: used,
                reset: reset.addingTimeInterval(resetDelta),
                homeIdentity: "/fixture/migration-real-drift",
                stableAccountKey: "sub:migration-real-drift",
                planType: "Pro",
                limitID: "codex",
                accountName: "Migration Real Drift",
                at: createdAt
            )
            try insertStableIdentitySnapshot(
                databaseURL: url,
                quota: quota,
                source: "swift",
                createdAt: createdAt
            )
        }
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.execute(
            "UPDATE quota_history_maintenance SET value = '0' WHERE key IN ('policy_version', 'last_compacted_at');"
        )

        try database.migrate()

        let retained = try driver.readRows(
            """
            SELECT created_at, five_hour_used_percent,
                   five_hour_resets_at, five_hour_reset_anchor
            FROM quota_snapshots ORDER BY created_at, id;
            """
        ) { statement in
            (
                statement.date(0),
                statement.int(1),
                statement.date(2),
                statement.int(3) ?? 0
            )
        }
        XCTAssertEqual(retained.count, 4)
        XCTAssertEqual(retained.compactMap(\.1), [20, 21, 22, 22])
        XCTAssertEqual(
            retained.compactMap(\.0).map(\.timeIntervalSince1970),
            [0, 120, 240, 480].map { observed.addingTimeInterval($0).timeIntervalSince1970 }
        )
        XCTAssertEqual(
            try XCTUnwrap(retained.last?.2).timeIntervalSince1970,
            reset.addingTimeInterval(14).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(retained.last?.3, 1)
    }

    func testHourlyHeartbeatNoLongerCreatesQuotaHistoryRows() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let quota = identifiedSnapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/no-heartbeat",
            stableAccountKey: "sub:no-heartbeat",
            planType: "Pro",
            limitID: "codex",
            accountName: "No Heartbeat",
            at: now
        )
        XCTAssertTrue(try database.record(quota, createdAt: now))
        XCTAssertTrue(try database.record(quota, createdAt: now.addingTimeInterval(2 * 60 * 60)))
        let count = try SQLiteDatabaseDriver(url: url).readRows(
            "SELECT count(*) FROM quota_snapshots;"
        ) { $0.int(0) ?? 0 }.first
        XCTAssertEqual(count, 1)
    }

    func testMaintenanceFailureRollsBackRowsAndMetadata() throws {
        let url = try makeDatabaseURL()
        let database = QuotaHistoryDatabase(databaseURL: url)
        let now = Date()
        let quota = identifiedSnapshot(
            usedPercent: 20,
            reset: now.addingTimeInterval(3 * 60 * 60),
            homeIdentity: "/fixture/maintenance-rollback",
            stableAccountKey: "sub:maintenance-rollback",
            planType: "Pro",
            limitID: "codex",
            accountName: "Maintenance Rollback",
            at: now
        )
        try database.migrate()
        try insertStableIdentitySnapshot(
            databaseURL: url,
            quota: quota,
            source: "swift",
            createdAt: now
        )
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.execute(
            "UPDATE quota_history_maintenance SET value = '0' WHERE key IN ('policy_version', 'last_compacted_at');"
        )
        try driver.execute(
            """
            CREATE TRIGGER fail_quota_cycle_backfill
            BEFORE UPDATE OF five_hour_cycle_generation ON quota_snapshots
            BEGIN
                SELECT RAISE(ABORT, 'fixture maintenance failure');
            END;
            """
        )

        XCTAssertThrowsError(try database.migrate())
        let generation: Int? = try driver.readRows(
            "SELECT five_hour_cycle_generation FROM quota_snapshots LIMIT 1;"
        ) { $0.int(0) }.first ?? nil
        let metadata = try driver.readRows(
            "SELECT key, value FROM quota_history_maintenance ORDER BY key;"
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }

        XCTAssertNil(generation)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: metadata)["policy_version"], "0")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: metadata)["last_compacted_at"], "0")
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
        createdAt: Date,
        enableWAL: Bool = false
    ) throws {
        let identity = try XCTUnwrap(quota.historyIdentity)
        let accountName = quota.accountName ?? "default"
        let driver = SQLiteDatabaseDriver(url: databaseURL, enableWAL: enableWAL)
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

    private func removeQuotaHistorySidecars(at url: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    private func createPeerQuotaSnapshotsTable(
        at url: URL,
        includeStableIdentity: Bool,
        enableWAL: Bool = false
    ) throws {
        let stableColumns = includeStableIdentity
            ? """
                source TEXT,
                identity_version INTEGER,
                home_identity TEXT,
                stable_account_key TEXT,
                identity_plan_type TEXT,
                identity_limit_id TEXT
            """
            : """
                source TEXT
            """
        let driver = SQLiteDatabaseDriver(url: url, enableWAL: enableWAL)
        try driver.execute(
            """
            CREATE TABLE quota_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                account_key TEXT NOT NULL,
                plan_type TEXT,
                limit_name TEXT,
                account_name TEXT,
                five_hour_used_percent INTEGER,
                five_hour_resets_at REAL,
                seven_day_used_percent INTEGER,
                seven_day_resets_at REAL,
                status TEXT NOT NULL,
                \(stableColumns)
            );
            """
        )
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
