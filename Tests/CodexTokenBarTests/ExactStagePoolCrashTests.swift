import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class ExactStagePoolCrashTests: XCTestCase {
    private let phases = ["initialize-before-commit", "chunk-committed", "seal-before-commit",
        "seal-committed", "publication-before-commit", "publication-committed", "cleanup-before-commit", "cleanup-committed"]
    private let eventCount = 513
    private func configuration(_ root: URL) -> BusinessDatabaseMigration.Configuration {
        let support = root.appendingPathComponent("support")
        return .init(container: support.appendingPathComponent("codex-ledger.sqlite"), support: support,
            exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("legacy"))
    }
    private func target(_ c: BusinessDatabaseMigration.Configuration) throws -> BusinessSQLiteStore {
        try XCTUnwrap(c.specification(for: c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")))
    }
    private func seed(_ job: ExactStagePool.Job) throws -> SQLiteTemporaryDatabase {
        let work = try SQLiteTemporaryDatabase(), db = work.connection
        try db.execute(ExactStageSchema.sql)
        let columns = try db.readRows("PRAGMA table_info(manifest)") { ($0.text(1)!, $0.text(2)!) }
        let values: [SQLiteBinding] = columns.map { name, type in
            if name == "canonical_path" { return .text(job.source.path) }
            if name == "event_count" { return .int(eventCount) }
            if ["complete", "fingerprint_count", "chunk_count"].contains(name) { return .int(1) }
            return type == "TEXT" ? .text("fixture") : type == "REAL" ? .double(100) : .int(0)
        }
        try db.execute("INSERT INTO manifest VALUES(\(Array(repeating: "?", count: values.count).joined(separator: ",")))", bindings: values)
        try db.transaction { tx in
            let insert = try tx.prepare("INSERT INTO events VALUES(?,100,11,9,8,2,0,'fixture',NULL,NULL,0,NULL,x'0001')")
            for index in 0..<eventCount { try insert.execute([.int(index)]) }
            try tx.execute("INSERT INTO fingerprints VALUES(x'0001ff'); INSERT INTO chunks VALUES(0,100,'source-proof')")
            try tx.execute("UPDATE manifest SET actual_bytes=?", bindings: [.int64(Int64(try BusinessStoreFiles.footprint(tx)))])
        }
        return work
    }
    private func publish(_ job: ExactStagePool.Job, pool: ExactStagePool, store: BusinessSQLiteStore) throws {
        try SQLiteDatabaseDriver(url: store.logicalURL).transaction { tx in
            try tx.execute("UPDATE schema_meta SET value=? WHERE key='published_tokens'", bindings: [.text(String(123 + 11 * eventCount))])
            try tx.execute("UPDATE schema_meta SET value='2' WHERE key='attribution_generation'")
            try pool.consume(job, generation: "2", on: tx)
        }
    }
    private func child(root: URL, point: String) throws -> Never {
        let c = configuration(root)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let store = try target(c), pool = try ExactStagePool.shared(for: store)
        let job = try pool.job(for: store, source: root.appendingPathComponent("source.jsonl"), contract: Data("crash-contract".utf8))
        let source = try seed(job)
        try pool.persist(job, from: source.connection)
        if point == "seal-committed" { Darwin._exit(86) }
        try publish(job, pool: pool, store: store)
        if point == "publication-committed" { Darwin._exit(86) }
        try pool.reclaim(job)
        if point == "cleanup-committed" { Darwin._exit(86) }
        throw NSError(domain: "MissingPoolCrashPoint", code: 1)
    }

    func testCrossProcessCrashesRetainOneCompleteGenerationAndResumeIdempotently() throws {
        #if !DEBUG
        throw XCTSkip("Pool fault hooks are deliberately absent in release binaries")
        #else
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TOKENBAR_POOL_CRASH_ROOT"], let point = environment["TOKENBAR_POOL_CRASH_POINT"] {
            try child(root: URL(fileURLWithPath: path), point: point)
        }
        for point in phases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-crash-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
            try Data("tokenbar-pool-crash-fixture-v1\n".utf8).write(to: root.appendingPathComponent(".tokenbar-pool-crash-fixture"))
            let c = configuration(root)
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
            let store = try target(c)
            try BusinessStoreFiles.registerInActiveContainer(store)
            try SQLiteDatabaseDriver(url: store.logicalURL).execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO schema_meta VALUES('provenance_epoch','crash-epoch'),('attribution_generation','1'),('published_tokens','123')")
            BusinessSQLiteRoutes.deactivate()
            let process = Process()
            if let binary = environment["TOKENBAR_ISOLATED_TESTS_EXECUTABLE"] {
                process.executableURL = URL(fileURLWithPath: binary)
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["xctest", "-XCTest", "CodexTokenBarTests.ExactStagePoolCrashTests/testCrossProcessCrashesRetainOneCompleteGenerationAndResumeIdempotently", Bundle(for: Self.self).bundleURL.path]
            }
            let allowed: Set<String> = ["PATH", "TMPDIR", "HOME", "DEVELOPER_DIR", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "SDKROOT", "TOKENBAR_FIXTURE_REPO"]
            process.environment = environment.filter { allowed.contains($0.key) }
            process.environment?["TOKENBAR_POOL_CRASH_ROOT"] = root.path
            process.environment?["TOKENBAR_POOL_CRASH_POINT"] = point
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + 60) == .success else {
                _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                return XCTFail("Own crash child timed out at \(point)")
            }
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 86, "\(point): \(output)")
            guard process.terminationStatus == 86 else { return }
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
            let pool = try ExactStagePool.shared(for: store)
            let raw = SQLiteDatabaseDriver(url: c.container, createsFileIfMissing: false, bypassBusinessRoutes: true)
            let table: (String) -> String = { SQLiteStoreNamespace.quote(pool.store.prefix + $0) }
            let rows = try raw.readRows("SELECT logical_path,state FROM \(table("jobs"))") { ($0.text(0)!, $0.text(1)!) }
            XCTAssertLessThanOrEqual(rows.count, 1)
            let job: ExactStagePool.Job
            if let row = rows.first { job = try XCTUnwrap(pool.lookup(URL(fileURLWithPath: row.0), for: store)) }
            else { job = try pool.job(for: store, source: root.appendingPathComponent("source.jsonl"), contract: Data("crash-contract".utf8)) }
            let expectedCommitted = ["publication-committed", "cleanup-before-commit", "cleanup-committed"].contains(point)
            let writer = SQLiteDatabaseDriver(url: store.logicalURL)
            let before = try writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }
            XCTAssertEqual(before, [String(expectedCommitted ? 123 + 11 * eventCount : 123)], point)
            let receipts = try raw.readRows("SELECT COUNT(*) FROM \(table("publication_receipts"))") { $0.int(0) }.first ?? nil
            XCTAssertEqual(receipts, expectedCommitted ? 1 : 0, point)
            if !expectedCommitted {
                if try pool.seal(of: job) == nil {
                    XCTAssertThrowsError(try pool.restore(job))
                    let source = try seed(job); try pool.persist(job, from: source.connection)
                }
                XCTAssertEqual(try pool.restore(job).connection.readRows("SELECT COUNT(*) FROM events") { $0.int(0) }, [eventCount])
                try publish(job, pool: pool, store: store)
            }
            try pool.reclaim(job); try pool.reclaim(job)
            XCTAssertThrowsError(try pool.restore(job))
            XCTAssertEqual(try writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, [String(123 + 11 * eventCount)])
            XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM \(table("publication_receipts"))") { $0.int(0) }, [1])
            for _ in 0..<3 {
                try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
                XCTAssertEqual(try writer.readRows("SELECT value FROM schema_meta WHERE key='published_tokens'") { $0.text(0) }, [String(123 + 11 * eventCount)])
            }
        }
        #endif
    }
}
