import Foundation
import XCTest
@testable import CodexTokenBar

final class Incident0910MigrationRecoveryTests: XCTestCase {
    func testQuotaMetadataDriftAndAppendedObservationRetryPreservesDestinationAndWaitsForReady() throws {
        let (_, configuration) = try fixture()

        // Establish an already populated destination partition. A later quota
        // retry must replace only its own partition in the shared container.
        let independentSource = configuration.support.appendingPathComponent("body-speed-independent.sqlite")
        try SQLiteDatabaseDriver(url: independentSource, bypassBusinessRoutes: true).execute(
            "CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(1);"
        )
        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32)
        let independentStore = try XCTUnwrap(configuration.specification(for: independentSource))
        try SQLiteDatabaseDriver(url: independentSource).execute("INSERT INTO samples VALUES(2)")
        XCTAssertEqual(try destinationSampleIDs(configuration, store: independentStore), [1, 2])

        BusinessSQLiteRoutes.deactivate()
        let quotaURL = configuration.support.appendingPathComponent("quota-history.sqlite")
        let quotaDatabase = QuotaHistoryDatabase(databaseURL: quotaURL)
        try quotaDatabase.migrate()
        let firstAt = Date().addingTimeInterval(-60)
        XCTAssertTrue(try quotaDatabase.record(quota(usedPercent: 20, at: firstAt), createdAt: firstAt))
        try sealSQLiteSource(quotaURL)
        let bytesBeforeMigration = try Data(contentsOf: quotaURL)
        let firstSourceProof = try sourceProof(quotaURL)

        enum StopBeforeActivation: Error { case interrupted }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(
            configuration,
            availableBytes: 1 << 32,
            beforeActivation: { throw StopBeforeActivation.interrupted }
        ))

        let quotaStore = try XCTUnwrap(configuration.specification(for: quotaURL))
        var attempts = try attemptReceipts(for: quotaURL, configuration: configuration)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(try quotaSnapshotRows(at: URL(fileURLWithPath: attempts[0].1.backupPath)), 1)
        XCTAssertEqual(try destinationQuotaRows(configuration, store: quotaStore).map(\.2), [20])
        XCTAssertEqual(try Data(contentsOf: quotaURL), bytesBeforeMigration)
        XCTAssertEqual(try containerMeta(configuration.container, key: "activation_state"), "importing")
        XCTAssertNotNil(try containerMeta(configuration.container, key: "migration_pending_sources_v1"))
        XCTAssertEqual(try destinationSampleIDs(configuration, store: independentStore), [1, 2])

        // Repeating an unchanged interrupted start reuses the exact first
        // snapshot pair and cannot create duplicate history rows.
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(
            configuration,
            availableBytes: 1 << 32,
            beforeActivation: { throw StopBeforeActivation.interrupted }
        ))
        attempts = try attemptReceipts(for: quotaURL, configuration: configuration)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(try destinationQuotaRows(configuration, store: quotaStore).count, 1)
        XCTAssertEqual(try Data(contentsOf: quotaURL), bytesBeforeMigration)

        // Simulate the daily policy-3 pass becoming due after the snapshot,
        // then append a real raw quota observation. Migration must notice both
        // the metadata and row changes and make a new verified snapshot pair.
        let oldMaintenanceTime = Date().addingTimeInterval(-25 * 60 * 60)
        try SQLiteDatabaseDriver(url: quotaURL, bypassBusinessRoutes: true).execute(
            "UPDATE quota_history_maintenance SET value=? WHERE key='last_compacted_at';",
            bindings: [.text(String(oldMaintenanceTime.timeIntervalSince1970))]
        )
        let secondAt = Date()
        XCTAssertTrue(try quotaDatabase.record(quota(usedPercent: 21, at: secondAt), createdAt: secondAt))
        let advancedMaintenanceTime = try maintenanceTime(at: quotaURL)
        XCTAssertGreaterThan(advancedMaintenanceTime, oldMaintenanceTime.timeIntervalSince1970 + 24 * 60 * 60)
        XCTAssertEqual(try quotaSnapshotRows(at: quotaURL), 2)
        try sealSQLiteSource(quotaURL)
        let bytesAfterAppend = try Data(contentsOf: quotaURL)
        XCTAssertNotEqual(try sourceProof(quotaURL), firstSourceProof)

        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(
            configuration,
            availableBytes: 1 << 32,
            beforeActivation: { throw StopBeforeActivation.interrupted }
        ))
        attempts = try attemptReceipts(for: quotaURL, configuration: configuration)
        XCTAssertEqual(attempts.count, 2, "Source drift must preserve the old attempt and create a new one")
        let oldAttempt = try XCTUnwrap(attempts.first { try quotaSnapshotRows(at: URL(fileURLWithPath: $0.1.backupPath)) == 1 })
        let newAttempt = try XCTUnwrap(attempts.first { try quotaSnapshotRows(at: URL(fileURLWithPath: $0.1.backupPath)) == 2 })
        XCTAssertEqual(oldAttempt.1.original, firstSourceProof)
        XCTAssertEqual(newAttempt.1.original, try sourceProof(quotaURL))
        for attempt in [oldAttempt, newAttempt] {
            let backupURL = URL(fileURLWithPath: attempt.1.backupPath)
            let normalizedURL = URL(fileURLWithPath: attempt.1.normalizedPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: normalizedURL.path))
            XCTAssertEqual(try sourceProof(backupURL), attempt.1.original)
            XCTAssertEqual(try sourceProof(normalizedURL), attempt.1.imported)
            XCTAssertEqual(try quotaSnapshotRows(at: backupURL), try quotaSnapshotRows(at: normalizedURL))
            try assertReadOnly(backupURL)
            try assertReadOnly(normalizedURL)
        }
        XCTAssertLessThan(try maintenanceTime(at: URL(fileURLWithPath: oldAttempt.1.backupPath)), advancedMaintenanceTime)
        XCTAssertEqual(try maintenanceTime(at: URL(fileURLWithPath: newAttempt.1.backupPath)), advancedMaintenanceTime)
        XCTAssertEqual(try destinationQuotaRows(configuration, store: quotaStore).map(\.2), [20, 21])
        XCTAssertEqual(try destinationSampleIDs(configuration, store: independentStore), [1, 2])
        XCTAssertEqual(try Data(contentsOf: quotaURL), bytesAfterAppend)
        XCTAssertEqual(try containerMeta(configuration.container, key: "activation_state"), "importing")
        XCTAssertNotNil(try containerMeta(configuration.container, key: "migration_pending_sources_v1"))

        // Complete the same batch, then repeat a normal start. The exact two
        // observations and both frozen attempt pairs must remain unchanged.
        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32)
        XCTAssertEqual(try containerMeta(configuration.container, key: "activation_state"), "ready")
        XCTAssertNil(try containerMeta(configuration.container, key: "migration_pending_sources_v1"))
        let completedRows = try destinationQuotaRows(configuration, store: quotaStore)
        XCTAssertEqual(completedRows.map(\.2), [20, 21])
        XCTAssertEqual(Set(completedRows.map(\.0)).count, 2)
        for attempt in [oldAttempt, newAttempt] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: attempt.1.backupPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: attempt.1.normalizedPath))
        }
        XCTAssertEqual(try destinationSampleIDs(configuration, store: independentStore), [1, 2])
        XCTAssertEqual(try Data(contentsOf: quotaURL), bytesAfterAppend)

        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 0)
        XCTAssertEqual(try attemptReceipts(for: quotaURL, configuration: configuration).count, 2)
        XCTAssertEqual(try destinationQuotaRows(configuration, store: quotaStore).map(\.2), [20, 21])
        XCTAssertEqual(try destinationSampleIDs(configuration, store: independentStore), [1, 2])
        XCTAssertEqual(try Data(contentsOf: quotaURL), bytesAfterAppend)
    }

    func testSchemaThirteenExactInputNormalizesOnSnapshotAndKeepsSourceBytes() throws {
        let (_, configuration) = try fixture()
        try FileManager.default.createDirectory(at: configuration.exact, withIntermediateDirectories: true)
        let exactURL = configuration.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        let source = SQLiteDatabaseDriver(url: exactURL, bypassBusinessRoutes: true)
        try source.execute("""
            INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
            VALUES(1,'/fixture/incident-0910.jsonl','incident-0910',1000,100,'probe','1');
            INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
            VALUES(1,100,1000,80,70,50,10,2,'gpt-6.1-sol',0);
            DROP TABLE source_representations;
            DELETE FROM schema_meta WHERE key IN ('representation_revision','representation_upgrade_backup');
            UPDATE schema_meta SET value='13' WHERE key='schema_version';
            """)
        try sealSQLiteSource(exactURL)
        let originalBytes = try Data(contentsOf: exactURL)
        let originalProof = try source.withConnection { try CodexBusinessDatabase.proof($0) }

        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 33)

        XCTAssertEqual(try Data(contentsOf: exactURL), originalBytes, "The source schema-13 file must remain frozen evidence")
        let oldSource = SQLiteDatabaseDriver(url: exactURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        XCTAssertEqual(try oldSource.withConnection { try CodexBusinessDatabase.proof($0) }, originalProof)
        XCTAssertEqual(try scalarInt(oldSource, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 13)

        _ = try XCTUnwrap(configuration.specification(for: exactURL))
        let attempts = try attemptReceipts(for: exactURL, configuration: configuration)
        let receipt = try XCTUnwrap(attempts.first?.1)
        let originalSnapshot = SQLiteDatabaseDriver(url: URL(fileURLWithPath: receipt.backupPath), readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let normalizedSnapshot = SQLiteDatabaseDriver(url: URL(fileURLWithPath: receipt.normalizedPath), readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        XCTAssertEqual(try originalSnapshot.withConnection { try CodexBusinessDatabase.proof($0) }, receipt.original)
        XCTAssertEqual(try normalizedSnapshot.withConnection { try CodexBusinessDatabase.proof($0) }, receipt.imported)
        XCTAssertEqual(try scalarInt(originalSnapshot, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 13)
        XCTAssertEqual(try scalarInt(normalizedSnapshot, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 14)
        XCTAssertEqual(try scalarInt(normalizedSnapshot, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='source_representations'"), 1)
        XCTAssertEqual(try scalarInt(normalizedSnapshot, "SELECT SUM(tokens) FROM events"), 80)
        let representationBackupPath = try XCTUnwrap(normalizedSnapshot.readRows(
            "SELECT value FROM schema_meta WHERE key='representation_upgrade_backup'"
        ) { $0.text(0) }.first ?? nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: representationBackupPath))
        let representationBackup = SQLiteDatabaseDriver(url: URL(fileURLWithPath: representationBackupPath), readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        XCTAssertEqual(try scalarInt(representationBackup, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 13)

        let routed = SQLiteDatabaseDriver(url: exactURL)
        XCTAssertEqual(routed.backingURL, configuration.container)
        XCTAssertEqual(try scalarInt(routed, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 14)
        XCTAssertEqual(try scalarInt(routed, "SELECT SUM(tokens) FROM events"), 80)
        XCTAssertEqual(try scalarInt(routed, "SELECT COUNT(*) FROM events"), 1)
        XCTAssertEqual(try containerMeta(configuration.container, key: "activation_state"), "ready")
        XCTAssertNil(try containerMeta(configuration.container, key: "migration_pending_sources_v1"))
    }

    private func fixture() throws -> (URL, BusinessDatabaseMigration.Configuration) {
        BusinessSQLiteRoutes.deactivate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incident-0910-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            BusinessSQLiteRoutes.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let configuration = BusinessDatabaseMigration.Configuration(
            container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support,
            exact: root.appendingPathComponent("exact", isDirectory: true),
            legacyExact: root.appendingPathComponent("cache", isDirectory: true)
        )
        return (root, configuration)
    }

    private func attemptReceipts(
        for source: URL,
        configuration: BusinessDatabaseMigration.Configuration
    ) throws -> [(URL, BusinessDatabaseMigration.Receipt)] {
        let store = try XCTUnwrap(configuration.specification(for: source))
        let folder = configuration.backups.appendingPathComponent(store.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("attempt-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                (url, try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: url)))
            }
    }

    private func quota(usedPercent: Int, at date: Date) -> AccountQuotaSnapshot {
        var snapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: date.addingTimeInterval(3 * 60 * 60)),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: usedPercent, resetsAt: date.addingTimeInterval(4 * 24 * 60 * 60)),
            planType: "Pro",
            limitName: "codex",
            accountName: "Migration Fixture",
            status: "fixture",
            updatedAt: date
        )
        snapshot.selectedLimitID = "codex"
        snapshot.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "/fixture/incident-0910",
            stableAccountKey: "sub:incident-0910",
            planType: "Pro",
            limitID: "codex"
        )
        return snapshot
    }

    private func sealSQLiteSource(_ url: URL) throws {
        let database = SQLiteDatabaseDriver(url: url, bypassBusinessRoutes: true)
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
    }

    private func sourceProof(_ url: URL) throws -> BusinessStoreProof {
        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try database.withConnection { try CodexBusinessDatabase.proof($0) }
    }

    private func quotaSnapshotRows(at url: URL) throws -> Int {
        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try scalarInt(database, "SELECT COUNT(*) FROM quota_snapshots")
    }

    private func destinationQuotaRows(
        _ configuration: BusinessDatabaseMigration.Configuration,
        store: BusinessSQLiteStore
    ) throws -> [(Int, Double, Int)] {
        let database = SQLiteDatabaseDriver(url: configuration.container, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try database.readRows(
            "SELECT id,created_at,five_hour_used_percent FROM \(store.prefix)quota_snapshots ORDER BY created_at,id"
        ) { ($0.int(0) ?? 0, $0.double(1) ?? 0, $0.int(2) ?? 0) }
    }

    private func destinationSampleIDs(
        _ configuration: BusinessDatabaseMigration.Configuration,
        store: BusinessSQLiteStore
    ) throws -> [Int] {
        let database = SQLiteDatabaseDriver(url: configuration.container, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try database.readRows("SELECT id FROM \(store.prefix)samples ORDER BY id") { $0.int(0) ?? 0 }
    }

    private func maintenanceTime(at url: URL) throws -> Double {
        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try XCTUnwrap(database.readRows(
            "SELECT value FROM quota_history_maintenance WHERE key='last_compacted_at'"
        ) { $0.text(0).flatMap(Double.init) }.first ?? nil)
    }

    private func containerMeta(_ container: URL, key: String) throws -> String? {
        let database = SQLiteDatabaseDriver(url: container, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try database.readRows("SELECT value FROM tb_container_meta WHERE key=?", bindings: [.text(key)]) { $0.text(0) }.first ?? nil
    }

    private func scalarInt(_ database: SQLiteDatabaseDriver, _ sql: String) throws -> Int {
        try XCTUnwrap(database.readRows(sql) { $0.int(0) }.first ?? nil)
    }

    private func assertReadOnly(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue, file: file, line: line)
        XCTAssertEqual(permissions & 0o222, 0, "Frozen snapshot must not be writable", file: file, line: line)
    }
}
