import Foundation
import XCTest
@testable import CodexTokenBar

final class ExactStagePoolTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configuration: BusinessDatabaseMigration.Configuration
        let target: BusinessSQLiteStore
        let writer: SQLiteDatabaseDriver
        var raw: SQLiteDatabaseDriver {
            SQLiteDatabaseDriver(url: configuration.container, createsFileIfMissing: false, bypassBusinessRoutes: true)
        }
        var backup: URL { configuration.backups.appendingPathComponent("structural-stage-pool-v1") }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-stage-pool-\(UUID().uuidString)")
        addTeardownBlock { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let c = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("legacy"))
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let target = try XCTUnwrap(c.specification(for: c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")))
        try BusinessStoreFiles.registerInActiveContainer(target)
        let writer = SQLiteDatabaseDriver(url: target.logicalURL)
        try writer.execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO schema_meta VALUES('provenance_epoch','fixture-epoch'),('attribution_generation','1'),('published_tokens','123')")
        return Fixture(root: root, configuration: c, target: target, writer: writer)
    }
    private func seed(_ job: ExactStagePool.Job) throws -> SQLiteTemporaryDatabase {
        let work = try SQLiteTemporaryDatabase(), db = work.connection
        try db.execute(ExactStageSchema.sql)
        let columns = try db.readRows("PRAGMA table_info(manifest)") { ($0.text(1)!, $0.text(2)!) }
        let bindings: [SQLiteBinding] = columns.map { name, type in
            if name == "canonical_path" { return .text(job.source.path) }
            if name == "complete" { return .int(1) }
            if ["event_count", "fingerprint_count", "chunk_count"].contains(name) { return .int(1) }
            return type == "TEXT" ? .text("fixture") : type == "REAL" ? .double(100) : .int(0)
        }
        try db.execute("INSERT INTO manifest VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ",")))", bindings: bindings)
        try db.execute("INSERT INTO events VALUES(0,100,11,9,8,2,0,'fixture',NULL,NULL,0,NULL,x'0001'); INSERT INTO fingerprints VALUES(x'0001ff'); INSERT INTO chunks VALUES(0,100,'source-proof')")
        let size = try BusinessStoreFiles.footprint(db)
        try db.execute("UPDATE manifest SET actual_bytes=?", bindings: [.int64(Int64(size))])
        return work
    }
    private func makeJob(_ pool: ExactStagePool, _ f: Fixture, _ index: Int = 0) throws -> ExactStagePool.Job {
        try pool.job(for: f.target, source: f.root.appendingPathComponent("sessions/\(index).jsonl"), contract: Data("request-\(index)".utf8))
    }
    private func count(_ f: Fixture, _ table: String) throws -> Int {
        try XCTUnwrap(f.raw.readRows("SELECT COUNT(*) FROM \(SQLiteStoreNamespace.quote(table))") { $0.int(0) }.first ?? nil)
    }

    func testNewJobsDoNotGrowMainCatalogOrStoresAndSealedRowsRestoreReadOnly() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let objects = try count(f, "sqlite_master"), stores = try count(f, "tb_stores")
        for i in 0..<13 {
            let job = try makeJob(pool, f, i), source = try seed(job)
            try pool.persist(job, from: source.connection)
            XCTAssertEqual(try pool.seal(of: job)?.rows, 4)
            XCTAssertEqual(try pool.lookup(job.url, for: f.target)?.id, job.id)
            let restored = try pool.restore(job)
            XCTAssertEqual(try restored.connection.readRows("SELECT tokens FROM events") { $0.int(0) }, [11])
            XCTAssertThrowsError(try restored.connection.execute("UPDATE events SET tokens=99"))
            XCTAssertThrowsError(try f.raw.execute("UPDATE \(SQLiteStoreNamespace.quote(pool.store.prefix + "event_rows")) SET payload=x'00' WHERE job_id=?", bindings: [.text(job.id)]))
        }
        XCTAssertEqual(try count(f, "sqlite_master"), objects)
        XCTAssertEqual(try count(f, "tb_stores"), stores)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testManifestCountMismatchCannotBecomeASealedOrPublishedJob() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let job = try makeJob(pool, f), source = try seed(job)
        try source.connection.execute("UPDATE manifest SET event_count=0")
        XCTAssertThrowsError(try pool.persist(job, from: source.connection))
        XCTAssertNil(try pool.seal(of: job))
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 0)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testArtifactFacadeCannotCreateAnotherPerFileNamespaceInActiveA() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let before = try count(f, "tb_stores")
        let oldWriterPath = f.configuration.exact.appendingPathComponent("staging/\(f.target.logicalURL.lastPathComponent)/new-job.sqlite")
        XCTAssertThrowsError(try ExactStageAccess(legacyURL: oldWriterPath, readOnly: false, pool: pool))
        XCTAssertEqual(try count(f, "tb_stores"), before)
    }

    func testPooledArtifactFacadePersistsSealsAndReadsWithoutARealStageFile() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let job = try makeJob(pool, f), source = try seed(job)
        let access = try ExactStageAccess(pool: pool, job: job, creating: true)
        try access.withConnection { db in
            try db.execute(ExactStageSchema.sql)
            for name in ExactStageSchema.tables {
                let columns = try XCTUnwrap(ExactStageSchema.columns[name])
                let insert = try db.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns).joined(separator: ",")))")
                try source.connection.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(name))") { row in
                    try insert.execute(ExactStageRowCodec.decode(ExactStageRowCodec.encode(row), expectedColumns: columns))
                }
            }
            try access.seal(connection: db)
            XCTAssertThrowsError(try db.execute("UPDATE events SET tokens=99"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: access.url.path))
        XCTAssertEqual(try access.observation().size, try access.byteCount())
        let restored = try ExactStageAccess(pool: pool, job: job)
        XCTAssertEqual(try restored.readRows("SELECT tokens FROM events") { $0.int(0) }, [11])
    }

    func testPublicationAndReceiptRollbackTogetherThenPermitIdempotentPayloadCleanup() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let job = try makeJob(pool, f), source = try seed(job)
        try pool.persist(job, from: source.connection)
        enum Interrupted: Error { case beforeCommit }
        XCTAssertThrowsError(try f.writer.transaction { tx in
            try tx.execute("UPDATE schema_meta SET value='134' WHERE key='published_tokens'")
            try pool.consume(job, generation: "generation-2", on: tx)
            throw Interrupted.beforeCommit
        })
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 0)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
        XCTAssertThrowsError(try pool.reclaim(job))
        XCTAssertEqual(try pool.seal(of: job)?.rows, 4)
        try f.writer.transaction { tx in
            try tx.execute("UPDATE schema_meta SET value='134' WHERE key='published_tokens'")
            try pool.consume(job, generation: "generation-2", on: tx)
            try pool.consume(job, generation: "generation-2", on: tx)
        }
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 1)
        XCTAssertThrowsError(try f.writer.transaction { try pool.consume(job, generation: "different-generation", on: $0) })
        try pool.reclaim(job); try pool.reclaim(job)
        XCTAssertEqual(try count(f, pool.store.prefix + "event_rows"), 0)
        XCTAssertEqual(try count(f, pool.store.prefix + "jobs"), 1, "Keep the lightweight proof header")
        XCTAssertThrowsError(try pool.restore(job))
    }

    func testUnboundConnectionCannotConsumeAnotherOwnerAndFuturePoolCannotWrite() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let job = try makeJob(pool, f), source = try seed(job)
        try pool.persist(job, from: source.connection)
        XCTAssertThrowsError(try f.raw.transaction { try pool.consume(job, generation: "wrong-owner", on: $0) })
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 0)
        try f.raw.execute("UPDATE tb_stores SET user_version=2 WHERE store_id=?", bindings: [.text(pool.store.id)])
        XCTAssertThrowsError(try pool.job(for: f.target, source: job.source, contract: Data()))
        XCTAssertEqual(try count(f, pool.store.prefix + "event_rows"), 1)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testJobIdentityTracksFactBaseButNotUnrelatedQuotaWrites() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let first = try makeJob(pool, f)
        try f.raw.execute("INSERT INTO tb_container_meta VALUES('fixture-unrelated-quota','updated')")
        XCTAssertEqual(try makeJob(pool, f).id, first.id)
        try f.writer.execute("UPDATE schema_meta SET value='2' WHERE key='attribution_generation'")
        XCTAssertNotEqual(try makeJob(pool, f).id, first.id)
    }

    func testLegacyNamespaceIsCopiedReadOnlyAndRequiresItsPublicationReceiptBeforeCleanup() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let request = try makeJob(pool, f), source = try seed(request)
        let legacyURL = f.configuration.exact.appendingPathComponent("staging/\(f.target.logicalURL.lastPathComponent)/legacy.sqlite")
        let legacyDriver = SQLiteDatabaseDriver(url: legacyURL)
        try legacyDriver.withConnection { db in
            try db.execute(ExactStageSchema.sql)
            for name in ExactStageSchema.tables {
                let columns = try XCTUnwrap(ExactStageSchema.columns[name])
                let insert = try db.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns).joined(separator: ",")))")
                try source.connection.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(name))") { row in
                    try insert.execute(ExactStageRowCodec.decode(ExactStageRowCodec.encode(row), expectedColumns: columns))
                }
            }
            try BusinessStoreFiles.seal(at: legacyURL, connection: db)
        }
        let legacy = try XCTUnwrap(BusinessSQLiteRoutes.store(for: legacyURL))
        let original = try XCTUnwrap(pool.legacyObservation(legacy))
        let work = try XCTUnwrap(pool.restoreLegacy(legacy))
        XCTAssertEqual(try work.connection.readRows("SELECT tokens FROM events") { $0.int(0) }, [11])
        XCTAssertThrowsError(try work.connection.execute("DELETE FROM events"))
        XCTAssertFalse(try pool.mayReclaimLegacy(legacy, for: f.target))
        try f.writer.transaction { try pool.consumeLegacy(legacy, generation: "legacy-generation", on: $0) }
        XCTAssertTrue(try pool.mayReclaimLegacy(legacy, for: f.target))
        let retained = try XCTUnwrap(pool.legacyObservation(legacy))
        XCTAssertEqual(retained.size, original.size)
        XCTAssertEqual(retained.physicalStamp, original.physicalStamp)
        XCTAssertTrue(try BusinessStoreFiles.removeCompletedStage(legacyURL))
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testCompletedSnapshotWithoutReceiptIsAdoptedWithoutRestoringOverNewFacts() throws {
        let f = try fixture()
        try f.raw.withConnection { try ExactStagePoolBackup.ensure(container: f.configuration.container, connection: $0) }
        let image = f.backup.appendingPathComponent("image/snapshot.sqlite")
        let bytes = try Data(contentsOf: image)
        try FileManager.default.removeItem(at: f.backup.appendingPathComponent("receipt.json"))
        try f.writer.execute("UPDATE schema_meta SET value='999' WHERE key='published_tokens'")
        try f.raw.withConnection { try ExactStagePoolBackup.ensure(container: f.configuration.container, connection: $0) }
        XCTAssertEqual(try Data(contentsOf: image), bytes)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["999"])
        XCTAssertNoThrow(try ExactStagePool.shared(for: f.target))
        // Structural backups live under the already excluded owned backup root.
        BusinessSQLiteRoutes.deactivate()
        XCTAssertNoThrow(try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 0))
    }

    func testOwnedIncompleteSnapshotFamilyIsRetainedAndPreparationRetriesAutomatically() throws {
        let f = try fixture()
        try f.raw.withConnection { try ExactStagePoolBackup.ensure(container: f.configuration.container, connection: $0) }
        try FileManager.default.removeItem(at: f.backup.appendingPathComponent("receipt.json"))
        let image = f.backup.appendingPathComponent("image/snapshot.sqlite")
        try Data("owned interrupted copy".utf8).write(to: image)
        try f.raw.withConnection { try ExactStagePoolBackup.ensure(container: f.configuration.container, connection: $0) }
        let entries = try FileManager.default.contentsOfDirectory(at: f.backup, includingPropertiesForKeys: nil)
        let retained = try XCTUnwrap(entries.first { $0.lastPathComponent.hasPrefix("incomplete-") })
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("snapshot.sqlite")), Data("owned interrupted copy".utf8))
        XCTAssertNoThrow(try ExactStagePool.shared(for: f.target))
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testUnknownSnapshotWithoutOwnershipIntentIsNeverMovedOrOverwritten() throws {
        let f = try fixture(), image = f.backup.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        let unknown = image.appendingPathComponent("snapshot.sqlite"), bytes = Data("unknown user material".utf8)
        try bytes.write(to: unknown)
        XCTAssertThrowsError(try f.raw.withConnection { try ExactStagePoolBackup.ensure(container: f.configuration.container, connection: $0) })
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.appendingPathComponent("receipt.json").path))
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }
}
