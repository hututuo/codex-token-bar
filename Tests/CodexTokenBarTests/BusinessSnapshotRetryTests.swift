import Foundation
import XCTest
@testable import CodexTokenBar

// Coverage algorithm adapted from shawway PR #8. Actual migration/import
// entrypoints remain this branch's admission and fixed-pool implementation.
final class BusinessSnapshotRetryTests: XCTestCase {
    func testRetryCoveragePreservesTypedRowsHiddenIDsAndAutoincrementState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.sqlite")
        let newer = root.appendingPathComponent("newer.sqlite")
        let old = SQLiteDatabaseDriver(url: original, bypassBusinessRoutes: true)
        try old.execute("CREATE TABLE records(value); CREATE TABLE retry_coverage(payload BLOB); CREATE TABLE sequence_records(id INTEGER PRIMARY KEY AUTOINCREMENT)")
        try old.execute("INSERT INTO records(rowid,value) VALUES(7,?), (11,?), (19,?), (31,?)",
            bindings: [.int(5), .double(5), .text("kept\0suffix"), .blob(Data([0, 255, 0]))])
        try old.execute("INSERT INTO retry_coverage VALUES(x'00ff'); INSERT INTO sequence_records VALUES(99); DELETE FROM sequence_records")
        let updated = SQLiteDatabaseDriver(url: newer, bypassBusinessRoutes: true)
        func reset() throws { try updated.withConnection { try $0.restoreDatabase(from: original) } }
        try reset()
        try updated.execute("INSERT INTO records(rowid,value) VALUES(55,'appended')")
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(newer, covers: original),
            "Pure append must preserve hidden IDs and may coexist with a user table named like the TEMP proof table")
        for mutation in [
            "UPDATE records SET value=5.0 WHERE rowid=7",
            "UPDATE records SET rowid=8 WHERE rowid=7",
            "UPDATE records SET value='kept' WHERE rowid=19",
            "DELETE FROM records WHERE rowid=31",
            "UPDATE sqlite_sequence SET seq=98 WHERE name='sequence_records'"
        ] {
            try reset()
            try updated.execute(mutation)
            XCTAssertFalse(try CodexBusinessDatabase.snapshot(newer, covers: original), mutation)
        }
    }

    func testQuotaRetryAllowsOnlyPolicyThreeClockProgress() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.sqlite")
        let newer = root.appendingPathComponent("newer.sqlite")
        let old = SQLiteDatabaseDriver(url: original, bypassBusinessRoutes: true)
        try old.execute("CREATE TABLE quota_history_maintenance(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE observations(tokens INTEGER); INSERT INTO observations VALUES(120)")
        try old.execute("INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100'),('unknown_evidence','keep')")
        let updated = SQLiteDatabaseDriver(url: newer, bypassBusinessRoutes: true)
        func reset() throws { try updated.withConnection { try $0.restoreDatabase(from: original) } }
        try reset()
        try updated.execute("UPDATE quota_history_maintenance SET value='200' WHERE key='last_compacted_at'; INSERT INTO observations VALUES(55)")
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(newer, covers: original, module: "quota.swift"))
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(newer, covers: original, module: "body.swift"), "The exception is module scoped")
        for mutation in [
            "UPDATE quota_history_maintenance SET value='99' WHERE key='last_compacted_at'",
            "UPDATE quota_history_maintenance SET value='nan' WHERE key='last_compacted_at'",
            "UPDATE quota_history_maintenance SET value='253402300800' WHERE key='last_compacted_at'",
            "UPDATE quota_history_maintenance SET value='4' WHERE key='policy_version'",
            "UPDATE quota_history_maintenance SET value='changed' WHERE key='unknown_evidence'",
            "UPDATE quota_history_maintenance SET rowid=200 WHERE key='last_compacted_at'",
            "INSERT INTO quota_history_maintenance VALUES('future_key','unknown')",
            "UPDATE observations SET tokens=119"
        ] {
            try reset()
            try updated.execute(mutation)
            XCTAssertFalse(try CodexBusinessDatabase.snapshot(newer, covers: original, module: "quota.swift"), mutation)
        }
        try old.execute("DELETE FROM quota_history_maintenance")
        try reset()
        try updated.execute("INSERT INTO observations VALUES(55)")
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(newer, covers: original, module: "quota.swift"),
            "An unchanged empty maintenance table must not block an ordinary append")
    }

    func testDestructiveRetryRejectsMissingOrChangedHistoryAndKeepsThePublishedImage() throws {
        for mutation in ["DELETE FROM samples WHERE id=2", "UPDATE samples SET tokens=199 WHERE id=2"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root); BusinessSQLiteRoutes.deactivate() }
            let (ledger, store, retained, original) = try frozen(root)
            let next = root.appendingPathComponent("next.sqlite")
            let nextDB = SQLiteDatabaseDriver(url: next, bypassBusinessRoutes: true)
            try nextDB.withConnection { try $0.restoreDatabase(from: retained) }
            try nextDB.execute(mutation)
            let before = try publishedProof(ledger, store)
            XCTAssertThrowsError(try ledger.importSnapshot(next, into: store, backupURL: original,
                replaceExisting: true, skipAlreadyCommitted: true, requireCommittedImportForReplacement: true))
            XCTAssertEqual(try publishedProof(ledger, store), before)
            XCTAssertEqual(try ledger.driver.readRows("SELECT SUM(tokens) FROM \(store.prefix)samples") { $0.int(0)! }, [300])
            XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        }
    }

    func testCoveredAppendCanRetryAndIdenticalRetryPreservesIndependentPublishedWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); BusinessSQLiteRoutes.deactivate() }
        let (ledger, store, retained, original) = try frozen(root)
        let next = root.appendingPathComponent("next.sqlite")
        let nextDB = SQLiteDatabaseDriver(url: next, bypassBusinessRoutes: true)
        try nextDB.withConnection { try $0.restoreDatabase(from: retained) }
        try nextDB.execute("INSERT INTO samples VALUES(3,55)")
        try ledger.importSnapshot(next, into: store, backupURL: original, replaceExisting: true,
            skipAlreadyCommitted: true, requireCommittedImportForReplacement: true)
        try ledger.driver.execute("INSERT INTO \(store.prefix)samples VALUES(999,999)")
        let before = try publishedProof(ledger, store)
        try ledger.importSnapshot(next, into: store, backupURL: original, replaceExisting: true,
            skipAlreadyCommitted: true, requireCommittedImportForReplacement: true)
        XCTAssertEqual(try publishedProof(ledger, store), before)
        XCTAssertThrowsError(try ledger.importSnapshot(retained, into: store, backupURL: original,
            replaceExisting: true, requireCommittedImportForReplacement: true))
        XCTAssertEqual(try publishedProof(ledger, store), before)
    }

    func testLiveLegacyAliasSwitchKeepsOneOwnerInBothDirections() throws {
        let root = try temporaryDirectory()
        defer { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let legacy = support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: legacy, bypassBusinessRoutes: true).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        let alias = root.appendingPathComponent("support-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: support)
        let a = support.appendingPathComponent("codex-ledger.sqlite")
        func configuration(_ directory: URL) -> BusinessDatabaseMigration.Configuration {
            .init(container: a, support: directory, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("old-exact"))
        }
        for directory in [support, alias, support] {
            BusinessSQLiteRoutes.deactivate()
            try BusinessDatabaseMigration.migrate(configuration(directory), availableBytes: 1 << 32)
            let rows = try SQLiteDatabaseDriver(url: directory.appendingPathComponent("quota-history.sqlite"), readOnly: true, createsFileIfMissing: false).readRows("SELECT id FROM samples") { $0.int(0)! }
            XCTAssertEqual(rows, [42])
            let raw = SQLiteDatabaseDriver(url: a, readOnly: true, bypassBusinessRoutes: true)
            XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM tb_stores WHERE module='quota.swift'") { $0.int(0)! }, [1])
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    private func frozen(_ root: URL) throws -> (CodexBusinessDatabase, BusinessSQLiteStore, URL, URL) {
        let id = UUID().uuidString
        let original = root.appendingPathComponent("original-" + id + ".sqlite")
        let retained = root.appendingPathComponent("normalized-" + id + ".sqlite")
        try SQLiteDatabaseDriver(url: original, bypassBusinessRoutes: true).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,tokens INTEGER NOT NULL); INSERT INTO samples VALUES(1,100),(2,200)")
        try SQLiteDatabaseDriver(url: retained, bypassBusinessRoutes: true).withConnection { try $0.restoreDatabase(from: original) }
        let ledger = try CodexBusinessDatabase(url: root.appendingPathComponent("a.sqlite"))
        let store = BusinessSQLiteStore(containerURL: ledger.url, logicalURL: root.appendingPathComponent("quota-history.sqlite"), module: "quota.swift", sourceIdentity: "quota-history.sqlite")
        try ledger.importSnapshot(retained, into: store, backupURL: original)
        return (ledger, store, retained, original)
    }

    private func publishedProof(_ ledger: CodexBusinessDatabase, _ store: BusinessSQLiteStore) throws -> BusinessStoreProof {
        try ledger.driver.withConnection { try CodexBusinessDatabase.proof($0, namespace: SQLiteStoreNamespace(prefix: store.prefix, objectNames: [])) }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-snapshot-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
