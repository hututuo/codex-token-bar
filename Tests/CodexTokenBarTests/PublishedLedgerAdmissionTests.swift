import Foundation
import XCTest
@testable import CodexTokenBar

/// New recovery work must not revoke access to a previously verified generation.
/// Uses the production migration/router, not a direct-SQL replacement for it.
final class PublishedLedgerAdmissionTests: XCTestCase {
    override func tearDown() {
        BusinessSQLiteRoutes.deactivate()
        super.tearDown()
    }

    private func readyLedger() throws -> (URL, BusinessDatabaseMigration.Configuration, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-ledger-admission-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let c = BusinessDatabaseMigration.Configuration(
            container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support,
            exact: root.appendingPathComponent("exact", isDirectory: true),
            legacyExact: root.appendingPathComponent("legacy", isDirectory: true)
        )
        let quota = support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota, bypassBusinessRoutes: true).execute(
            "CREATE TABLE preserved(id INTEGER PRIMARY KEY, amount INTEGER); INSERT INTO preserved VALUES(42,123)"
        )
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        // Include a post-upgrade record that an old backup cannot replace.
        try SQLiteDatabaseDriver(url: quota).execute("INSERT INTO preserved VALUES(43,789)")
        BusinessSQLiteRoutes.deactivate()
        return (root, c, quota)
    }

    private func addLateSource(_ c: BusinessDatabaseMigration.Configuration) throws -> URL {
        let late = c.support.appendingPathComponent("body-speed-late.sqlite")
        try SQLiteDatabaseDriver(url: late, bypassBusinessRoutes: true).execute(
            "CREATE TABLE preserved(id INTEGER PRIMARY KEY, amount INTEGER); INSERT INTO preserved VALUES(77,456)"
        )
        return late
    }

    func testUnrelatedSupportTreesAndDiagnosticsAreNotMigrationInputs() throws {
        let (root, c, quota) = try readyLedger()
        let export = c.support.appendingPathComponent("exports/user-backup.sqlite")
        let diagnostics = c.support.appendingPathComponent("recovery-diagnostics/v1")
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let bytes = Data("user-owned material".utf8); try bytes.write(to: export)
        let outside = root.appendingPathComponent("outside"); try bytes.write(to: outside)
        let link = diagnostics.appendingPathComponent("not-a-ledger.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true).readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123, 789])
        XCTAssertEqual(try Data(contentsOf: export), bytes)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    private func assertPriorGenerationAvailable(
        _ c: BusinessDatabaseMigration.Configuration, quota: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let raw = SQLiteDatabaseDriver(url: c.container, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try raw.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") {
            $0.text(0)
        }.first ?? nil, "ready", file: file, line: line)
        // Assert routing before any access can accidentally reopen the old file.
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: quota), file: file, line: line)
        XCTAssertEqual(store.containerURL, c.container, file: file, line: line)
        let published = SQLiteDatabaseDriver(url: quota, readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try published.readRows("SELECT amount FROM preserved ORDER BY id") {
            $0.int(0)
        }, [123, 789], file: file, line: line)
        let original = SQLiteDatabaseDriver(url: quota, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try original.readRows("SELECT amount FROM preserved ORDER BY id") {
            $0.int(0)
        }, [123], "The original source remains unchanged", file: file, line: line)
    }

    func testLowSpaceLateImportDoesNotHidePreviouslyPublishedLedger() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        // An operation may report deferred/failed; published availability is independent.
        do { try BusinessDatabaseMigration.migrate(c, availableBytes: 0) } catch {}
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT amount FROM preserved") { $0.int(0) }, [456])
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows(
            "SELECT amount FROM preserved"
        ) { $0.int(0) }, [456])
    }

    func testInterruptedLateImportPreservesPublishedAccessAndDoesNotDuplicateOnRetry() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        do {
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
                beforeActivation: { throw Interrupted.beforeActivation })
        } catch {}
        try assertPriorGenerationAvailable(c, quota: quota)
        for _ in 0..<3 {
            BusinessSQLiteRoutes.deactivate()
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
            try assertPriorGenerationAvailable(c, quota: quota)
            XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows(
                "SELECT amount FROM preserved"
            ) { $0.int(0) }, [456])
        }
    }

    func testMissingOriginalResumesItsBoundAttemptAndKeepsPostImportFacts() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        let target = try XCTUnwrap(c.specification(for: late))
        let raw = SQLiteDatabaseDriver(url: c.container, bypassBusinessRoutes: true)
        try raw.execute("INSERT INTO \(SQLiteStoreNamespace.quote(target.prefix + "preserved")) VALUES(78,999)")
        try FileManager.default.removeItem(at: late)
        // The per-attempt receipt is authoritative; a broken convenience
        // pointer must not make the app pick a different backup by timestamp.
        let pointer = c.backups.appendingPathComponent(target.id).appendingPathComponent("receipt.json")
        try Data("interrupted convenience pointer".utf8).write(to: pointer)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [456,999])
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertTrue(try raw.readRows("SELECT value FROM tb_container_meta WHERE key='migration_pending_sources_v1'") { $0.text(0) }.isEmpty)
        for _ in 0..<3 { try BusinessDatabaseMigration.migrate(c, availableBytes: 0) }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [456,999])
    }

    func testMissingUnversionedOriginalGetsANewVerifiedAttemptFromItsBoundBackup() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        let target = try XCTUnwrap(c.specification(for: late))
        let folder = c.backups.appendingPathComponent(target.id)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object.removeValue(forKey: "normalizationRevision")
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }
        try FileManager.default.removeItem(at: late)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let attempts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("attempt-") && $0.pathExtension == "json" }
        XCTAssertEqual(attempts.count, 2, "An unversioned normalization is preserved, not relabelled as current")
        let receipts = try attempts.map { try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(receipts.filter { $0.normalizationRevision == nil }.count, 1)
        XCTAssertEqual(receipts.filter { $0.normalizationRevision == 1 }.count, 1)
        XCTAssertEqual(receipts.first?.original, receipts.last?.original)
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows("SELECT amount FROM preserved") { $0.int(0) }, [456])
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testInitialBootstrapCanFinishAfterOriginalDisappearsOnlyWithItsBoundVerifiedPair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-bootstrap-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let c = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("legacy"))
        let quota = support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota, bypassBusinessRoutes: true).execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY,amount INTEGER); INSERT INTO preserved VALUES(1,123)")
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        try FileManager.default.removeItem(at: quota)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true).readRows("SELECT amount FROM preserved") { $0.int(0) }, [123])
        XCTAssertFalse(FileManager.default.fileExists(atPath: quota.path))
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true).readRows("SELECT amount FROM preserved") { $0.int(0) }, [123])
    }

    func testMissingOriginalCannotAuthorizeADamagedSnapshotOrAnUnboundExport() throws {
        for damage in ["original", "normalized", "unbound"] {
            let (root, c, quota) = try readyLedger()
            let late = try addLateSource(c)
            enum Interrupted: Error { case beforeActivation }
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
                beforeActivation: { throw Interrupted.beforeActivation }))
            let target = try XCTUnwrap(c.specification(for: late))
            let folder = c.backups.appendingPathComponent(target.id)
            let attempt = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("attempt-") && $0.pathExtension == "json" })
            let receipt = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: attempt))
            if damage == "unbound" {
                let export = root.appendingPathComponent("user-export.sqlite")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: receipt.backupPath), to: export)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: attempt)) as? [String: Any])
                object["backupPath"] = export.path
                try JSONSerialization.data(withJSONObject: object).write(to: attempt, options: .atomic)
            } else {
                let damaged = URL(fileURLWithPath: damage == "original" ? receipt.backupPath : receipt.normalizedPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: damaged.path)
                try SQLiteDatabaseDriver(url: damaged, bypassBusinessRoutes: true).execute("UPDATE preserved SET amount=9999")
            }
            try FileManager.default.removeItem(at: late)
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32), damage)
            try assertPriorGenerationAvailable(c, quota: quota)
            XCTAssertEqual(try SQLiteDatabaseDriver(url: c.container, readOnly: true, bypassBusinessRoutes: true)
                .readRows("SELECT amount FROM \(SQLiteStoreNamespace.quote(target.prefix + "preserved"))") { $0.int(0) }, [456])
            XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        }
    }

    func testPendingOwnerCannotReadOrWriteBeforeVerificationWhileOtherOwnersRemainAvailable() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertThrowsError(try SQLiteDatabaseDriver(url: late, readOnly: true, createsFileIfMissing: false)
            .readRows("SELECT amount FROM preserved") { $0.int(0) })
        XCTAssertThrowsError(try SQLiteDatabaseDriver(url: late).execute("INSERT INTO preserved VALUES(78,999)"))
        try SQLiteDatabaseDriver(url: quota).execute("INSERT INTO preserved VALUES(44,900)")
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123,789,900])
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [456])
    }

    func testPhysicalLegacyBackupNeverExportsTheRoutedPublishedOwner() throws {
        let (root, c, quota) = try readyLedger()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let physical = root.appendingPathComponent("physical-snapshot.sqlite")
        let logical = root.appendingPathComponent("logical-snapshot.sqlite")
        try SQLiteDatabaseDriver(url: physical, bypassBusinessRoutes: true).withConnection {
            try $0.restorePhysicalDatabase(from: quota)
        }
        try SQLiteDatabaseDriver(url: logical, bypassBusinessRoutes: true).withConnection {
            try $0.restoreDatabase(from: quota)
        }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: physical, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123])
        XCTAssertEqual(try SQLiteDatabaseDriver(url: logical, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123,789])
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123,789])
    }

    func testRetryOfIdenticalCommittedImportRetainsIndependentDestinationRows() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        let target = try XCTUnwrap(c.specification(for: late))
        let raw = SQLiteDatabaseDriver(url: c.container, bypassBusinessRoutes: true)
        // Model data written by a released app before this recovery guard was
        // available. The new runtime itself refuses this pending owner write.
        try raw.execute("INSERT INTO \(SQLiteStoreNamespace.quote(target.prefix + "preserved")) VALUES(78,999)")
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [456,999])
    }

    func testChangedLegacyInputCannotReplaceAWithIndependentDestinationFacts() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
            beforeActivation: { throw Interrupted.beforeActivation }))
        let target = try XCTUnwrap(c.specification(for: late))
        let raw = SQLiteDatabaseDriver(url: c.container, bypassBusinessRoutes: true)
        try raw.execute("INSERT INTO \(SQLiteStoreNamespace.quote(target.prefix + "preserved")) VALUES(78,999)")
        try SQLiteDatabaseDriver(url: late, bypassBusinessRoutes: true).execute("INSERT INTO preserved VALUES(79,111)")
        BusinessSQLiteRoutes.deactivate()
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try raw.readRows("SELECT amount FROM \(SQLiteStoreNamespace.quote(target.prefix + "preserved")) ORDER BY id") { $0.int(0) }, [456,999])
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [456,111])
    }

    func testMalformedLateDiscoveryKeepsOldReadsAndClosesWritersUntilItIsClassified() throws {
        let (_, c, quota) = try readyLedger()
        try FileManager.default.createDirectory(at: c.exact, withIntermediateDirectories: true)
        let manifest = c.exact.appendingPathComponent(String(repeating: "d",count:64)+".sqlite.schema11-migration.json")
        try Data("invalid-recovery-json".utf8).write(to: manifest)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertThrowsError(try SQLiteDatabaseDriver(url: quota).execute("INSERT INTO preserved VALUES(44,900)"))
        let unknown = c.support.appendingPathComponent("body-speed-new-owner.sqlite")
        XCTAssertThrowsError(try SQLiteDatabaseDriver(url: unknown).execute("CREATE TABLE forbidden(id INTEGER)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path))
        try FileManager.default.removeItem(at: manifest)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try SQLiteDatabaseDriver(url: quota).execute("INSERT INTO preserved VALUES(44,900)")
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota, readOnly: true)
            .readRows("SELECT amount FROM preserved ORDER BY id") { $0.int(0) }, [123,789,900])
    }

    func testExistingContainerOpenNeverCreatesAnEmptyReplacement() throws {
        let (root, _, _) = try readyLedger()
        let missing = root.appendingPathComponent("never-created.sqlite")
        XCTAssertThrowsError(try CodexBusinessDatabase(url: missing, createsFileIfMissing: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
