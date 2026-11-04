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

    private func seedLegacy(_ f: Fixture, pool: ExactStagePool) throws -> BusinessSQLiteStore {
        let request = try makeJob(pool, f), source = try seed(request)
        let url = f.configuration.exact.appendingPathComponent("staging/\(f.target.logicalURL.lastPathComponent)/legacy.sqlite")
        try SQLiteDatabaseDriver(url: url).withConnection { db in
            try db.execute(ExactStageSchema.sql)
            for name in ExactStageSchema.tables {
                let columns = try XCTUnwrap(ExactStageSchema.columns[name])
                let insert = try db.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns).joined(separator: ",")))")
                try source.connection.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(name))") { row in
                    try insert.execute(ExactStageRowCodec.decode(ExactStageRowCodec.encode(row), expectedColumns: columns))
                }
            }
            try BusinessStoreFiles.seal(at: url, connection: db)
        }
        return try XCTUnwrap(BusinessSQLiteRoutes.store(for: url))
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

    func testLegacyCandidatesUseIndexedSourceBoundsWithoutMixingOwners() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let digest = String(repeating: "b", count: 64)
        let directory = f.configuration.exact.appendingPathComponent("staging/\(f.target.logicalURL.lastPathComponent)")
        let wanted = [digest + ".sqlite", digest + ".candidate-previous.sqlite"].map { directory.appendingPathComponent($0) }
        let foreign = f.configuration.exact.appendingPathComponent("staging/other-home.sqlite/\(digest).sqlite")
        for path in wanted + [foreign, directory.appendingPathComponent(String(repeating: "c", count: 64) + ".sqlite")] {
            let base = try XCTUnwrap(f.configuration.specification(for: path))
            let store = path == wanted[1]
                ? BusinessSQLiteStore(containerURL: base.containerURL, logicalURL: base.logicalURL,
                    module: base.module, sourceIdentity: base.sourceIdentity + "\0job:" + UUID().uuidString)
                : base
            try BusinessStoreFiles.registerInActiveContainer(store)
            // Direct fixture registration does not activate its route. A real
            // startup installs these catalog identities before module reads.
            BusinessSQLiteRoutes.install([store])
        }
        XCTAssertEqual(Set(try pool.legacyURLs(for: f.target, sourceDigest: digest)), Set(wanted))
        for url in wanted {
            XCTAssertFalse(try pool.legacyPresence(try XCTUnwrap(BusinessSQLiteRoutes.store(for: url)), for: f.target),
                "A namespace registered before its producer wrote MAIN tables is unfinished, not published usage")
        }
        let runtime = try XCTUnwrap(BusinessSQLiteRoutes.store(for: wanted[0]))
        let physical = SQLiteStoreNamespace.quote(runtime.prefix + "runtime_fact")
        try f.raw.execute("CREATE TABLE \(physical)(value INTEGER); INSERT INTO \(physical) VALUES(11)")
        XCTAssertEqual(try f.raw.readRows("SELECT COUNT(*) FROM tb_store_objects WHERE store_id=?", bindings: [.text(runtime.id)]) { $0.int(0) }, [0])
        XCTAssertTrue(try pool.legacyPresence(runtime, for: f.target),
            "Runtime-created facts must not disappear merely because the original import catalog is empty")
        try f.raw.execute("DROP TABLE \(physical)")
        XCTAssertFalse(try pool.legacyPresence(runtime, for: f.target), "Schema/foreign commits invalidate the held catalog")
        let plan = try f.raw.readRows("EXPLAIN QUERY PLAN " + ExactStagePool.legacyLookupSQL,
            bindings: [.text(wanted[0].path), .text(directory.appendingPathComponent(digest + ".candidate-").path),
                       .text(directory.appendingPathComponent(digest + ".candidate.").path)]) { $0.text(3) ?? "" }
        XCTAssertFalse(plan.contains { $0.contains("SCAN tb_stores") }, "Each source lookup must use the existing logical_path index: \(plan)")
        XCTAssertTrue(plan.contains { $0.contains("SEARCH tb_stores") })
        try f.raw.execute("UPDATE tb_stores SET source_identity='foreign' WHERE logical_path=?", bindings: [.text(wanted[0].path)])
        XCTAssertThrowsError(try pool.legacyURLs(for: f.target, sourceDigest: digest))
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

    func testVerifiedWorkCacheIsReadOnlyBoundedAndInvalidatedByForeignCommits() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let firstJob = try makeJob(pool, f), firstSource = try seed(firstJob)
        try pool.persist(firstJob, from: firstSource.connection)
        let first = try pool.restore(firstJob)
        XCTAssertTrue(first === (try pool.restore(firstJob)))
        XCTAssertThrowsError(try first.connection.execute("UPDATE events SET tokens=99"))
        try f.writer.execute("UPDATE schema_meta SET value='foreign-epoch' WHERE key='provenance_epoch'")
        let afterCommit = try pool.restore(firstJob)
        XCTAssertFalse(first === afterCommit)
        for index in 1...4 {
            let job = try makeJob(pool, f, index), source = try seed(job)
            try pool.persist(job, from: source.connection)
            _ = try pool.restore(job)
        }
        XCTAssertFalse(afterCommit === (try pool.restore(firstJob)), "A completed batch cannot accumulate private work forever")
        // Bypass the normal immutable-payload guard to simulate damaged A.
        // A foreign data_version invalidates the verified cached copy first.
        try f.raw.execute("DROP TRIGGER \(SQLiteStoreNamespace.quote(pool.store.prefix + "guard_event_rows_update"))")
        try f.raw.execute("UPDATE \(SQLiteStoreNamespace.quote(pool.store.prefix + "event_rows")) SET payload=x'00' WHERE job_id=?", bindings: [.text(firstJob.id)])
        XCTAssertThrowsError(try pool.restore(firstJob))
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

    func testBackgroundCleanupLimitsEachPassAndKeepsPendingPayloadAndAllReceipts() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        for index in 0..<5 {
            let job = try makeJob(pool, f, index), source = try seed(job)
            try pool.persist(job, from: source.connection)
            if index < 4 {
                try f.writer.transaction { try pool.consume(job, generation: "published-2", on: $0) }
            }
        }
        XCTAssertEqual(try pool.reclaimPublished(maximumJobs: 2, budget: 10), 2)
        XCTAssertEqual(try f.raw.readRows("SELECT state,COUNT(*) FROM \(SQLiteStoreNamespace.quote(pool.store.prefix + "jobs")) GROUP BY state ORDER BY state") { "\($0.text(0)!):\($0.int(1)!)" }, ["consumed:2", "reclaimed:2", "sealed:1"])
        XCTAssertEqual(try pool.reclaimPublished(maximumJobs: 4, budget: 10), 2)
        XCTAssertEqual(try pool.reclaimPublished(maximumJobs: 4, budget: 10), 0)
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 4)
        XCTAssertEqual(try count(f, pool.store.prefix + "event_rows"), 1, "An unconsumed payload survives every cleanup pass")
        XCTAssertEqual(try count(f, pool.store.prefix + "jobs"), 5)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testChangedConsumedLegacyCannotBeDeletedByAnOldReceipt() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let request = try makeJob(pool, f), source = try seed(request)
        let url = f.configuration.exact.appendingPathComponent("staging/\(f.target.logicalURL.lastPathComponent)/changed.sqlite")
        try SQLiteDatabaseDriver(url: url).withConnection { db in
            try db.execute(ExactStageSchema.sql)
            for name in ExactStageSchema.tables {
                let columns = try XCTUnwrap(ExactStageSchema.columns[name])
                let insert = try db.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns).joined(separator: ",")))")
                try source.connection.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(name))") { row in
                    try insert.execute(ExactStageRowCodec.decode(ExactStageRowCodec.encode(row), expectedColumns: columns))
                }
            }
            try BusinessStoreFiles.seal(at: url, connection: db)
        }
        let legacy = try XCTUnwrap(BusinessSQLiteRoutes.store(for: url))
        try f.writer.transaction { try pool.consumeLegacy(legacy, generation: "legacy-2", on: $0) }
        try f.raw.execute("UPDATE \(SQLiteStoreNamespace.quote(legacy.prefix + "events")) SET tokens=99")
        XCTAssertThrowsError(try pool.reclaimLegacy(legacy, for: f.target))
        XCTAssertEqual(try f.raw.readRows("SELECT tokens FROM \(SQLiteStoreNamespace.quote(legacy.prefix + "events"))") { $0.int(0) }, [99])
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 1)
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testBusyMaintenanceDefersWithoutHoldingTheForegroundWriterOrLosingItsReceipt() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let job = try makeJob(pool, f), source = try seed(job)
        try pool.persist(job, from: source.connection)
        try f.writer.transaction { try pool.consume(job, generation: "published-2", on: $0) }
        try f.raw.transaction { tx in
            try tx.execute("INSERT INTO tb_container_meta VALUES('unrelated-writer','committing')")
            let began = Date()
            XCTAssertThrowsError(try pool.reclaim(job))
            XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
        }
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 1)
        XCTAssertEqual(try count(f, pool.store.prefix + "event_rows"), 1)
        try pool.reclaim(job)
        XCTAssertEqual(try count(f, pool.store.prefix + "event_rows"), 0)
        XCTAssertEqual(try f.raw.readRows("SELECT value FROM tb_container_meta WHERE key='unrelated-writer'") { $0.text(0) }, ["committing"])
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
        let legacy = try seedLegacy(f, pool: pool)
        let original = try XCTUnwrap(pool.legacyObservation(legacy))
        let work = try XCTUnwrap(pool.restoreLegacy(legacy))
        XCTAssertEqual(try work.connection.readRows("SELECT tokens FROM events") { $0.int(0) }, [11])
        XCTAssertThrowsError(try work.connection.execute("DELETE FROM events"))
        XCTAssertFalse(try pool.mayReclaimLegacy(legacy, for: f.target))
        XCTAssertFalse(try pool.reclaimLegacy(legacy, for: f.target), "Unconsumed evidence is never a cleanup candidate")
        try f.writer.transaction { try pool.consumeLegacy(legacy, generation: "legacy-generation", on: $0) }
        XCTAssertTrue(try pool.mayReclaimLegacy(legacy, for: f.target))
        let retained = try XCTUnwrap(pool.legacyObservation(legacy))
        XCTAssertEqual(retained.size, original.size)
        XCTAssertEqual(retained.physicalStamp, original.physicalStamp)
        XCTAssertEqual(try pool.reclaimPublished(maximumJobs: 1, budget: 2), 1)
        XCTAssertFalse(try pool.reclaimLegacy(legacy, for: f.target), "A repeated cleanup is harmless")
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 1, "The authority outlives its payload")
        XCTAssertEqual(try f.writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, ["123"])
    }

    func testLegacyRestoreCopiesTheSameSnapshotThatPassedItsSealProof() throws {
        let f = try fixture(), pool = try ExactStagePool.shared(for: f.target)
        let legacy = try seedLegacy(f, pool: pool)
        let table = SQLiteStoreNamespace.quote(legacy.prefix + "events")
        let before = try XCTUnwrap(pool.legacyObservation(legacy))
        pool.beforeNextLegacyCopyForTesting {
            // Simulate external damage after the row proof. Both integers have
            // identical encoded length, so a footprint check cannot catch it.
            try f.raw.execute("UPDATE \(table) SET tokens=99")
        }
        let restored = try XCTUnwrap(pool.restoreLegacy(legacy))
        XCTAssertEqual(try f.raw.readRows("SELECT tokens FROM \(table)") { $0.int(0) }, [99],
            "The competing WAL write must actually commit")
        XCTAssertEqual(try restored.connection.readRows("SELECT tokens FROM events") { $0.int(0) }, [11],
            "The restored rows must be exactly those that passed the seal proof")
        XCTAssertEqual(try BusinessStoreFiles.footprint(restored.connection), before.size)
        XCTAssertThrowsError(try restored.connection.execute("UPDATE events SET tokens=77"))
        XCTAssertThrowsError(try pool.restoreLegacy(legacy), "The next call must observe and reject the now-damaged source")
        XCTAssertEqual(try count(f, pool.store.prefix + "publication_receipts"), 0)
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
