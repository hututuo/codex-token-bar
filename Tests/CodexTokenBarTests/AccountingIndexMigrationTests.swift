import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountingIndexMigrationTests: XCTestCase {
    func testUnknownAccountingRevisionIsRejectedBeforeLegacyPreparation() throws {
        for schema in ["6", "11", "12"] {
            let fixture = try makeFixture()
            let database = SQLiteDatabaseDriver(url: fixture.databaseURL)
            try seedLegacyEvents(in: database)
            try database.execute("UPDATE schema_meta SET value = ? WHERE key = 'schema_version';", bindings: [.text(schema)])
            try database.execute("INSERT INTO schema_meta(key,value) VALUES ('accounting_revision','future-accounting');")
            let before = try preMigrationEventSnapshots(in: database)
            XCTAssertThrowsError(try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: fixture.databaseURL)) { error in
                XCTAssertTrue(error is CodexUsageIndexUpgradeRequiredError)
            }
            XCTAssertEqual(try schemaValue("schema_version", in: database), schema)
            XCTAssertEqual(try schemaValue("accounting_revision", in: database), "future-accounting")
            XCTAssertEqual(try preMigrationEventSnapshots(in: database), before)
        }
    }

    func testSchema11AccountingMigrationPreservesLegacyValuesAndCountsOnlyValidEvents() throws {
        let fixture = try makeFixture()
        let database = SQLiteDatabaseDriver(url: fixture.databaseURL)
        try seedLegacyEvents(in: database)

        _ = try CodexUsageHistoryIndex(
            sessionCatalogTestingDatabaseURL: fixture.databaseURL
        )

        let migrated = SQLiteDatabaseDriver(url: fixture.databaseURL)
        XCTAssertEqual(
            try eventSnapshots(in: migrated),
            [
                EventSnapshot(tokens: 110, kind: 0, reported: nil, legacy: 999),
                EventSnapshot(tokens: 0, kind: 3, reported: nil, legacy: 53_707),
            ]
        )
        XCTAssertEqual(
            try scalarInt64(
                "SELECT COALESCE(SUM(calls), 0) FROM dashboard_5m;",
                in: migrated
            ),
            1,
            "invalid legacy total-only events must not enter dashboard aggregates"
        )
        XCTAssertEqual(
            try scalarInt64(
                "SELECT COALESCE(SUM(calls), 0) FROM attribution_source_buckets;",
                in: migrated
            ),
            1,
            "invalid legacy total-only events must not enter attribution aggregates"
        )
        XCTAssertEqual(
            try schemaValue("schema_version", in: migrated),
            "13"
        )
        XCTAssertEqual(
            try schemaValue("accounting_revision", in: migrated),
            "codex-components-v1"
        )
        XCTAssertEqual(
            try schemaValue("accounting_coverage", in: migrated),
            "legacy-source-audit-required"
        )

        let snapshotsBeforeReopen = try eventSnapshots(in: migrated)
        let rowCountBeforeReopen = try scalarInt64(
            "SELECT COUNT(*) FROM events;",
            in: migrated
        )

        _ = try CodexUsageHistoryIndex(
            sessionCatalogTestingDatabaseURL: fixture.databaseURL
        )

        let reopened = SQLiteDatabaseDriver(url: fixture.databaseURL)
        XCTAssertEqual(try eventSnapshots(in: reopened), snapshotsBeforeReopen)
        XCTAssertEqual(
            try scalarInt64("SELECT COUNT(*) FROM events;", in: reopened),
            rowCountBeforeReopen
        )
        XCTAssertEqual(
            try scalarInt64(
                "SELECT COALESCE(SUM(calls), 0) FROM dashboard_5m;",
                in: reopened
            ),
            1
        )
    }

    func testAccountingMigrationRollsBackDDLAndDataWhenConversionFails() throws {
        let fixture = try makeFixture()
        let database = SQLiteDatabaseDriver(url: fixture.databaseURL)
        try seedLegacyEvents(in: database, includeInvalidEvent: false)
        try removeAccountingColumnsForDDLRollback(in: database)
        try database.execute(
            """
            CREATE TRIGGER accounting_migration_test_abort
            BEFORE UPDATE ON events
            BEGIN
                SELECT RAISE(ABORT, 'accounting migration test failure');
            END;
            """
        )

        XCTAssertThrowsError(
            try CodexUsageHistoryIndex(
                sessionCatalogTestingDatabaseURL: fixture.databaseURL
            )
        )

        let failed = SQLiteDatabaseDriver(url: fixture.databaseURL)
        XCTAssertEqual(
            try preMigrationEventSnapshots(in: failed),
            [PreMigrationEventSnapshot(tokens: 999)]
        )
        XCTAssertEqual(try schemaValue("schema_version", in: failed), "11")
        XCTAssertNil(try schemaValue("accounting_revision", in: failed))
        XCTAssertNil(try schemaValue("accounting_structural_receipt", in: failed))
        XCTAssertNil(try schemaValue("accounting_coverage", in: failed))
        XCTAssertFalse(try tableColumns("sources", in: failed).contains("accounting_state"))
        XCTAssertFalse(try tableColumns("events", in: failed).contains("accounting_kind"))
        XCTAssertFalse(try tableColumns("events", in: failed).contains("reported_total_tokens"))
        XCTAssertFalse(try tableColumns("events", in: failed).contains("legacy_tokens"))
        XCTAssertEqual(
            try scalarInt64(
                "SELECT COUNT(*) FROM pragma_index_list('events') WHERE name = 'events_unresolved_accounting';",
                in: failed
            ),
            0
        )

        try failed.execute("DROP TRIGGER accounting_migration_test_abort;")
        _ = try CodexUsageHistoryIndex(
            sessionCatalogTestingDatabaseURL: fixture.databaseURL
        )

        let recovered = SQLiteDatabaseDriver(url: fixture.databaseURL)
        XCTAssertEqual(
            try eventSnapshots(in: recovered),
            [EventSnapshot(tokens: 110, kind: 0, reported: nil, legacy: 999)]
        )
        XCTAssertEqual(try schemaValue("schema_version", in: recovered), "13")
        XCTAssertEqual(
            try schemaValue("accounting_revision", in: recovered),
            "codex-components-v1"
        )
    }

    @MainActor
    func testUnresolvedAccountingCoverageSurvivesRichDetailAndCompactHeadlineMerges() throws {
        func snapshot(_ generation: Int64, _ kind: DashboardSnapshotCoverageKind, _ accounting: String) -> DashboardSnapshot {
            DashboardSnapshot(
                stats: DashboardSnapshot.empty.stats,
                dailyUsage: [], recentBins: [], hourlyUsage: [], pluginUsage: [],
                cacheUsage: DashboardSnapshot.empty.cacheUsage,
                generatedAt: Date(timeIntervalSince1970: Double(generation)),
                homeIdentity: "accounting-test-home", coverageKind: kind,
                exactGeneration: generation, accountingCoverage: accounting
            )
        }
        let olderFull = snapshot(1, .full, "complete")
        let newerSummary = snapshot(2, .summary, "unresolved-events")
        for merged in [
            CodexUsageStore.mergeSnapshots(newerSummary, into: olderFull),
            CodexUsageStore.mergeSnapshots(olderFull, into: newerSummary)
        ] {
            XCTAssertEqual(merged.accountingCoverage, "unresolved-events")
            let restored = try JSONDecoder().decode(DashboardSnapshot.self, from: JSONEncoder().encode(merged))
            XCTAssertEqual(restored.accountingCoverage, "unresolved-events")
        }
    }

    private func makeFixture() throws -> AccountingMigrationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-token-bar-accounting-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let databaseURL = root.appendingPathComponent("usage-index.sqlite")
        _ = try CodexUsageHistoryIndex(
            sessionCatalogTestingDatabaseURL: databaseURL
        )
        return AccountingMigrationFixture(root: root, databaseURL: databaseURL)
    }

    private func seedLegacyEvents(
        in database: SQLiteDatabaseDriver,
        includeInvalidEvent: Bool = true
    ) throws {
        try database.execute(
            """
            INSERT INTO sources(
                source_id, path, session_id, size_bytes, modified_at,
                content_probe, last_seen_generation
            ) VALUES (1, ?, 'accounting-migration-session', 0, 0, '', 'test');
            """,
            bindings: [
                .text(database.url.deletingLastPathComponent()
                    .appendingPathComponent("accounting-source.jsonl").path)
            ]
        )
        try database.execute(
            """
            INSERT INTO events(
                source_id, source_offset, timestamp, tokens,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, model
            ) VALUES (1, 10, 1700000000, 999, 100, 40, 10, 7, 'gpt-5.6-sol');
            """
        )
        if includeInvalidEvent {
            try database.execute(
                """
                INSERT INTO events(
                    source_id, source_offset, timestamp, tokens,
                    input_tokens, cached_input_tokens, output_tokens,
                    reasoning_output_tokens, model
                ) VALUES (1, 20, 1700000300, 53707, 0, 0, 0, 0, 'gpt-5.6-sol');
                """
            )
        }
        try database.execute(
            """
            DELETE FROM schema_meta
            WHERE key IN (
                'accounting_revision',
                'accounting_structural_receipt',
                'accounting_coverage'
            );
            """
        )
        try database.execute(
            "UPDATE schema_meta SET value = '11' WHERE key = 'schema_version';"
        )
    }

    private func eventSnapshots(
        in database: SQLiteDatabaseDriver
    ) throws -> [EventSnapshot] {
        try database.readRows(
            """
            SELECT tokens, accounting_kind, reported_total_tokens, legacy_tokens
            FROM events
            ORDER BY source_offset;
            """
        ) { row in
            EventSnapshot(
                tokens: row.int64(0),
                kind: row.int(1),
                reported: row.int(2),
                legacy: row.int(3)
            )
        }
    }

    private func preMigrationEventSnapshots(
        in database: SQLiteDatabaseDriver
    ) throws -> [PreMigrationEventSnapshot] {
        try database.readRows(
            """
            SELECT tokens
            FROM events
            ORDER BY source_offset;
            """
        ) { row in
            PreMigrationEventSnapshot(
                tokens: row.int64(0)
            )
        }
    }

    private func removeAccountingColumnsForDDLRollback(
        in database: SQLiteDatabaseDriver
    ) throws {
        // This fixture models a pre-accounting release. It cannot retain the
        // current writer's triggers referencing columns that did not exist.
        try database.execute("""
            DROP TRIGGER IF EXISTS retain_usage_before_event_update;
            DROP TRIGGER IF EXISTS retain_usage_before_event_delete;
            DROP TRIGGER IF EXISTS retain_usage_before_source_delete;
            DROP TRIGGER IF EXISTS retain_usage_before_identity_update;
            DROP TRIGGER IF EXISTS retain_usage_before_fingerprint_delete;
            """)
        try database.execute(
            "DROP INDEX IF EXISTS events_unresolved_accounting;"
        )
        let sourceColumns = try tableColumns("sources", in: database)
        if sourceColumns.contains("accounting_state") {
            try database.execute(
                "ALTER TABLE sources DROP COLUMN accounting_state;"
            )
        }
        let eventColumns = try tableColumns("events", in: database)
        for column in ["legacy_tokens", "reported_total_tokens", "accounting_kind"]
            where eventColumns.contains(column) {
            try database.execute(
                "ALTER TABLE events DROP COLUMN \(column);"
            )
        }
    }

    private func scalarInt64(
        _ sql: String,
        in database: SQLiteDatabaseDriver
    ) throws -> Int64 {
        try XCTUnwrap(
            database.readRows(sql) { $0.int64(0) }.first ?? nil
        )
    }

    private func schemaValue(
        _ key: String,
        in database: SQLiteDatabaseDriver
    ) throws -> String? {
        try database.readRows(
            "SELECT value FROM schema_meta WHERE key = ?;",
            bindings: [.text(key)]
        ) { $0.text(0) }.first ?? nil
    }

    private func tableColumns(
        _ table: String,
        in database: SQLiteDatabaseDriver
    ) throws -> Set<String> {
        Set(
            try database.readRows("PRAGMA table_info(\(table));") {
                $0.text(1) ?? ""
            }
        )
    }
}

private struct AccountingMigrationFixture {
    let root: URL
    let databaseURL: URL
}

private struct EventSnapshot: Equatable {
    let tokens: Int64?
    let kind: Int?
    let reported: Int?
    let legacy: Int?
}

private struct PreMigrationEventSnapshot: Equatable {
    let tokens: Int64?
}
