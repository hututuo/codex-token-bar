import Foundation
import XCTest
@testable import CodexTokenBar

final class PublishedModuleReadTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configuration: BusinessDatabaseMigration.Configuration
        let quotaStore: BusinessSQLiteStore
        let modelTraceStore: BusinessSQLiteStore
        let quota: AccountQuotaSnapshot
        let observedAt: Date
        let settings: ModelTraceAutoSettings
    }

    private func fixture(writesPaused: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-module-read-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            BusinessSQLiteRoutes.deactivate()
            try? FileManager.default.removeItem(at: root)
        }

        let support = root.appendingPathComponent("support", isDirectory: true)
        let quotaURL = support.appendingPathComponent("quota-history.sqlite")
        let modelTraceURL = support.appendingPathComponent("modeltrace/modeltrace.sqlite")
        let configuration = BusinessDatabaseMigration.Configuration(
            container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support,
            exact: root.appendingPathComponent("exact", isDirectory: true),
            legacyExact: root.appendingPathComponent("legacy-exact", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let observedAt = Date().addingTimeInterval(-60)
        let resetAt = observedAt.addingTimeInterval(3 * 60 * 60)
        let homeIdentity = "/fixture/published-read-home"
        let stableAccountKey = "sub:published-read-account"
        let accountName = "Published Fixture"
        let quota = makeQuota(
            observedAt: observedAt,
            resetAt: resetAt,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            accountName: accountName
        )
        try seedOldQuotaDatabase(
            at: quotaURL,
            observedAt: observedAt,
            resetAt: resetAt,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            accountName: accountName
        )

        let settings = ModelTraceAutoSettings(
            enabled: true,
            intervalHours: 12,
            nextRunAt: 1_800_000_000,
            scopeKey: "scope:published-account"
        )
        try seedOldModelTraceDatabase(at: modelTraceURL, settings: settings)

        let quotaStore = try XCTUnwrap(configuration.specification(for: quotaURL))
        let modelTraceStore = try XCTUnwrap(configuration.specification(for: modelTraceURL))
        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32)
        BusinessSQLiteRoutes.activate(
            configuration,
            stores: [quotaStore, modelTraceStore],
            publishedAdmission: writesPaused,
            blocksAllWriters: writesPaused
        )

        return Fixture(
            root: root,
            configuration: configuration,
            quotaStore: quotaStore,
            modelTraceStore: modelTraceStore,
            quota: quota,
            observedAt: observedAt,
            settings: settings
        )
    }

    func testPublishedQuotaAndModelTraceHistoryStayReadableWhileWritesAreRejected() throws {
        let fixture = try fixture()
        let proofBefore = try containerProof(fixture.configuration)
        let quotaColumnsBefore = try columns(
            in: fixture.configuration,
            store: fixture.quotaStore,
            table: "quota_snapshots"
        )
        let quotaTablesBefore = try tableNames(in: fixture.configuration, store: fixture.quotaStore)
        let claimsTable = fixture.quotaStore.prefix + "quota_history_legacy_claims"
        XCTAssertFalse(try tableExists(in: fixture.configuration, name: claimsTable))
        XCTAssertFalse(quotaColumnsBefore.contains("five_hour_cycle_generation"))
        XCTAssertFalse(quotaColumnsBefore.contains("five_hour_reset_anchor"))
        XCTAssertFalse(quotaColumnsBefore.contains("seven_day_cycle_generation"))
        XCTAssertFalse(quotaColumnsBefore.contains("seven_day_reset_anchor"))

        let quotaDatabase = QuotaHistoryDatabase(databaseURL: fixture.quotaStore.logicalURL)
        XCTAssertEqual(
            try quotaDatabase.recordedFiveHourUsedPercents(
                for: fixture.quota,
                now: fixture.observedAt.addingTimeInterval(60),
                age: 31 * 24 * 60 * 60
            ),
            [37],
            "Stable identity reads must find the legacy row without cycle columns"
        )

        let modelTrace = ModelTraceHistoryStore(url: fixture.modelTraceStore.logicalURL)
        let scopedRuns = try modelTrace.history(scope: "scope:published-account")
        XCTAssertEqual(scopedRuns.map(\.id), ["published-run"])
        XCTAssertEqual(scopedRuns.map(\.status), ["completed"])
        XCTAssertEqual(try modelTrace.history(scope: "scope:other-account").map(\.id), ["other-scope-run"])
        XCTAssertTrue(try modelTrace.history(scope: "scope:unseen-account").isEmpty)
        XCTAssertEqual(try modelTrace.autoSettings(), fixture.settings)

        XCTAssertThrowsError(try quotaDatabase.record(
            fixture.quota,
            createdAt: fixture.observedAt.addingTimeInterval(120)
        ))

        var changedRun = try XCTUnwrap(scopedRuns.first)
        changedRun.status = "cancelled"
        XCTAssertThrowsError(try modelTrace.save(changedRun, scope: "scope:published-account"))
        XCTAssertThrowsError(try modelTrace.saveAutoSettings(
            ModelTraceAutoSettings(enabled: false, intervalHours: 24, nextRunAt: nil, scopeKey: nil)
        ))

        XCTAssertEqual(try containerProof(fixture.configuration), proofBefore)
        XCTAssertEqual(
            try columns(in: fixture.configuration, store: fixture.quotaStore, table: "quota_snapshots"),
            quotaColumnsBefore
        )
        XCTAssertEqual(try tableNames(in: fixture.configuration, store: fixture.quotaStore), quotaTablesBefore)
        XCTAssertFalse(try tableExists(in: fixture.configuration, name: claimsTable))
        XCTAssertEqual(
            try modelTrace.history(scope: "scope:published-account").map(\.status),
            ["completed"],
            "Rejected writes must leave the published modeltrace row unchanged"
        )
        XCTAssertEqual(try modelTrace.autoSettings(), fixture.settings)
    }

    func testUnregisteredConfiguredOwnerCannotReturnFakeEmptyQuotaHistory() throws {
        let fixture = try fixture()
        let proofBefore = try containerProof(fixture.configuration)
        let unregisteredURL = fixture.configuration.support.appendingPathComponent("body-speed-unregistered.sqlite")
        let unregisteredStore = try XCTUnwrap(fixture.configuration.specification(for: unregisteredURL))
        XCTAssertFalse(BusinessSQLiteRoutes.isRegistered(unregisteredStore))

        XCTAssertThrowsError(
            try QuotaHistoryDatabase(databaseURL: unregisteredURL).loadSnapshot(
                for: fixture.quota,
                now: fixture.observedAt.addingTimeInterval(60)
            ),
            "A configured but unregistered owner has no published quota partition to read"
        )

        XCTAssertFalse(BusinessSQLiteRoutes.isRegistered(unregisteredStore))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unregisteredURL.path))

        let unknownURL = fixture.root.appendingPathComponent("unconfigured-owner.sqlite")
        XCTAssertNil(BusinessSQLiteRoutes.store(for: unknownURL))
        XCTAssertThrowsError(
            try QuotaHistoryDatabase(databaseURL: unknownURL).loadSnapshot(
                for: fixture.quota,
                now: fixture.observedAt.addingTimeInterval(60)
            ),
            "A path with no owner cannot be reported as a successful empty history"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownURL.path))
        XCTAssertEqual(try containerProof(fixture.configuration), proofBefore)
    }

    func testHealthyPublishedQuotaAndModelTraceReadsAlsoNeverMigrateOrClaim() throws {
        let fixture = try fixture(writesPaused: false)
        let before = try containerProof(fixture.configuration)
        let quota = QuotaHistoryDatabase(databaseURL: fixture.quotaStore.logicalURL)
        XCTAssertEqual(try quota.recordedFiveHourUsedPercents(for: fixture.quota,
            now: fixture.observedAt.addingTimeInterval(60), age: 31 * 86400), [37])
        let model = ModelTraceHistoryStore(url: fixture.modelTraceStore.logicalURL)
        XCTAssertFalse(model.writesArePaused)
        XCTAssertEqual(try model.history(scope: "scope:published-account").map(\.id), ["published-run"])
        XCTAssertEqual(try model.autoSettings(), fixture.settings)
        XCTAssertEqual(try containerProof(fixture.configuration), before,
            "A healthy reader must not issue DDL, maintain history, or create legacy claims")
    }

    private func makeQuota(
        observedAt: Date,
        resetAt: Date,
        homeIdentity: String,
        stableAccountKey: String,
        accountName: String
    ) -> AccountQuotaSnapshot {
        var quota = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 37, resetsAt: resetAt),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 52, resetsAt: resetAt.addingTimeInterval(4 * 24 * 60 * 60)),
            planType: "Plus",
            limitName: "codex",
            accountName: accountName,
            status: "fixture",
            updatedAt: observedAt
        )
        quota.selectedLimitID = "codex"
        quota.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            planType: "Plus",
            limitID: "codex"
        )
        return quota
    }

    private func seedOldQuotaDatabase(
        at url: URL,
        observedAt: Date,
        resetAt: Date,
        homeIdentity: String,
        stableAccountKey: String,
        accountName: String
    ) throws {
        let driver = SQLiteDatabaseDriver(url: url, bypassBusinessRoutes: true)
        try driver.execute(
            """
            CREATE TABLE quota_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                account_key TEXT NOT NULL,
                source TEXT,
                plan_type TEXT,
                limit_name TEXT,
                account_name TEXT,
                five_hour_used_percent INTEGER,
                five_hour_resets_at REAL,
                seven_day_used_percent INTEGER,
                seven_day_resets_at REAL,
                status TEXT NOT NULL,
                identity_version INTEGER,
                home_identity TEXT,
                stable_account_key TEXT,
                identity_plan_type TEXT,
                identity_limit_id TEXT
            )
            """
        )
        try driver.execute(
            """
            INSERT INTO quota_snapshots (
                created_at, account_key, source, plan_type, limit_name, account_name,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status,
                identity_version, home_identity, stable_account_key,
                identity_plan_type, identity_limit_id
            ) VALUES (?, ?, 'tauri', 'Plus', 'codex', ?, 37, ?, 52, ?, 'legacy', 1, ?, ?, 'Plus', 'codex')
            """,
            bindings: [
                .date(observedAt),
                .text("\(accountName)|Plus|codex"),
                .text(accountName),
                .date(resetAt),
                .date(resetAt.addingTimeInterval(4 * 24 * 60 * 60)),
                .text(homeIdentity),
                .text(stableAccountKey)
            ]
        )
    }

    private func seedOldModelTraceDatabase(at url: URL, settings: ModelTraceAutoSettings) throws {
        let driver = SQLiteDatabaseDriver(url: url, bypassBusinessRoutes: true)
        try driver.execute(
            """
            CREATE TABLE modeltrace_runs (
                scope TEXT NOT NULL,
                id TEXT PRIMARY KEY,
                started_at INTEGER NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE INDEX modeltrace_scope_time ON modeltrace_runs(scope, started_at DESC);
            CREATE TABLE modeltrace_settings (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)
            """
        )
        var publishedRun = ModelTrace.Run(model: ModelTrace.defaultModel)
        publishedRun.id = "published-run"
        publishedRun.startedAt = 1_700_000_001
        publishedRun.completedAt = publishedRun.startedAt + 3
        publishedRun.status = "completed"
        var otherRun = ModelTrace.Run(model: "gpt-5.6-sol")
        otherRun.id = "other-scope-run"
        otherRun.startedAt = 1_700_000_002
        otherRun.status = "completed"
        try insertRun(publishedRun, scope: "scope:published-account", into: driver)
        try insertRun(otherRun, scope: "scope:other-account", into: driver)
        let settingsJSON = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try driver.execute(
            "INSERT INTO modeltrace_settings(id, payload) VALUES(1, ?)",
            bindings: [.text(settingsJSON)]
        )
    }

    private func insertRun(_ run: ModelTrace.Run, scope: String, into driver: SQLiteDatabaseDriver) throws {
        let json = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        try driver.execute(
            "INSERT INTO modeltrace_runs(scope, id, started_at, payload) VALUES(?, ?, ?, ?)",
            bindings: [.text(scope), .text(run.id), .int64(Int64(run.startedAt)), .text(json)]
        )
    }

    private func containerProof(_ configuration: BusinessDatabaseMigration.Configuration) throws -> BusinessStoreProof {
        let raw = SQLiteDatabaseDriver(
            url: configuration.container,
            readOnly: true,
            createsFileIfMissing: false,
            bypassBusinessRoutes: true
        )
        return try raw.withConnection { try CodexBusinessDatabase.proof($0) }
    }

    private func columns(
        in configuration: BusinessDatabaseMigration.Configuration,
        store: BusinessSQLiteStore,
        table: String
    ) throws -> [String] {
        let raw = SQLiteDatabaseDriver(
            url: configuration.container,
            readOnly: true,
            createsFileIfMissing: false,
            bypassBusinessRoutes: true
        )
        let physicalName = SQLiteStoreNamespace.quote(store.prefix + table)
        return try raw.readRows("PRAGMA table_info(\(physicalName))") { $0.text(1) ?? "" }
    }

    private func tableNames(
        in configuration: BusinessDatabaseMigration.Configuration,
        store: BusinessSQLiteStore
    ) throws -> [String] {
        let raw = SQLiteDatabaseDriver(
            url: configuration.container,
            readOnly: true,
            createsFileIfMissing: false,
            bypassBusinessRoutes: true
        )
        return try raw.readRows(
            "SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,?)=? ORDER BY name",
            bindings: [.int(store.prefix.count), .text(store.prefix)]
        ) { $0.text(0) ?? "" }
    }

    private func tableExists(
        in configuration: BusinessDatabaseMigration.Configuration,
        name: String
    ) throws -> Bool {
        let raw = SQLiteDatabaseDriver(
            url: configuration.container,
            readOnly: true,
            createsFileIfMissing: false,
            bypassBusinessRoutes: true
        )
        return try raw.readRows(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            bindings: [.text(name)]
        ) { $0.int(0) }.first == 1
    }
}
