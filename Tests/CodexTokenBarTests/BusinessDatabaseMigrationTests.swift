import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessDatabaseMigrationTests: XCTestCase {
    private func fixture() throws -> (URL, BusinessDatabaseMigration.Configuration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("business-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        return (root, .init(container: support.appendingPathComponent("codex-ledger.sqlite"), support: support,
            exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("cache")))
    }
    func testBootstrapPreservesRawWALAndKeysAndReopensWithoutReimporting() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        let source = SQLiteDatabaseDriver(url: legacy, enableWAL: true)
        try source.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,account TEXT,used REAL,payload BLOB); PRAGMA user_version=8")
        try source.execute("INSERT INTO quota_snapshots VALUES(42,'account-a',37.5,?)", bindings: [.blob(Data([0,255,0]))])
        let rawBefore = try source.withConnection { try CodexBusinessDatabase.proof($0) }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let routed = SQLiteDatabaseDriver(url: legacy)
        XCTAssertEqual(routed.backingURL, c.container)
        XCTAssertEqual(try routed.readRows("SELECT payload FROM quota_snapshots WHERE id=42") { $0.data(0) }.first!, Data([0,255,0]))
        try routed.execute("INSERT INTO quota_snapshots VALUES(43,'account-a',38,NULL)")
        let old = SQLiteDatabaseDriver(url: legacy, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try old.withConnection { try CodexBusinessDatabase.proof($0) }, rawBefore)
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
        let receipts = try FileManager.default.subpathsOfDirectory(atPath: c.backups.path)
        XCTAssertTrue(receipts.contains { $0.hasSuffix("receipt.json") })
        XCTAssertTrue(receipts.contains { $0.contains("original-") && $0.hasSuffix(".sqlite") })
    }
    func testFailureBeforeActivationAndOutOfSpaceLeaveOldLedgerAndRetry() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        let source = SQLiteDatabaseDriver(url: legacy)
        try source.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,used INTEGER); INSERT INTO quota_snapshots VALUES(1,77)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 0))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: legacy))
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertEqual(try source.readRows("SELECT used FROM quota_snapshots") { $0.int(0) }.first!, 77)
        try source.execute("INSERT INTO quota_snapshots VALUES(2,80)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
    }
    func testNewModulesWriteOnlyAAndStageSealSurvivesUnrelatedWrites() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let stageURL = c.exact.appendingPathComponent("staging/\(String(repeating: "a", count: 64)).sqlite/job.sqlite")
        let stage = SQLiteDatabaseDriver(url: stageURL)
        try stage.withConnection { db in
            try db.execute("CREATE TABLE events(id INTEGER PRIMARY KEY,payload BLOB); INSERT INTO events VALUES(1,x'000102')")
            try BusinessStoreFiles.seal(at: stageURL, connection: db)
        }
        let before = try SourceFileObservation.read(at: stageURL)
        let quotaURL = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quotaURL).execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        XCTAssertTrue(before.matches(try SourceFileObservation.read(at: stageURL)))
        XCTAssertThrowsError(try stage.execute("DELETE FROM events"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quotaURL.path))
        let old = try XCTUnwrap(BusinessSQLiteRoutes.store(for: stageURL))
        XCTAssertTrue(try BusinessStoreFiles.quarantine(stageURL, into: stageURL.deletingLastPathComponent().appendingPathComponent("preserved/one")))
        let fresh = SQLiteDatabaseDriver(url: stageURL)
        try fresh.execute("CREATE TABLE events(id INTEGER PRIMARY KEY); INSERT INTO events VALUES(2)")
        XCTAssertNotEqual(BusinessSQLiteRoutes.store(for: stageURL)?.id, old.id)
        XCTAssertEqual(try fresh.readRows("SELECT id FROM events") { $0.int(0) }.first!, 2)
        XCTAssertTrue(try BusinessStoreFiles.removeCompletedStage(stageURL))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quotaURL).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 1)
    }
    func testCurrentExactAndDeletedSourceLedgerRemainAvailableAfterMigration() throws {
        let (_, c) = try fixture()
        let url = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        let old = SQLiteDatabaseDriver(url: url)
        try old.execute("""
        INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
        VALUES(1,'/deleted/source.jsonl','same-uuid',1000,100,'probe','1');
        INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
        VALUES(1,100,1000,80,70,50,10,2,'gpt-6.1-sol',0);
        """)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let routed = SQLiteDatabaseDriver(url: url)
        XCTAssertEqual(try routed.readRows("SELECT tokens FROM events") { $0.int(0) }.first!, 80)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        XCTAssertEqual(try routed.readRows("SELECT tokens FROM events") { $0.int(0) }.first!, 80)
        XCTAssertEqual(try routed.readRows("SELECT session_id FROM sources") { $0.text(0) }.first!, "same-uuid")
    }
    func testUnsupportedDormantHomesArePreservedWithoutBlockingSupportedHome() throws {
        let (_, c) = try fixture()
        let supported = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
        var originals: [(URL, BusinessStoreProof)] = []
        // Include a cache-only source, an empty v3 index (the real startup
        // blocker), and a populated future version whose IDs must survive.
        for (version, character, root) in [("3", "b", c.legacyExact), ("999", "c", c.exact)] {
            let url = root.appendingPathComponent(String(repeating: character, count: 64) + ".sqlite")
            let source = SQLiteDatabaseDriver(url: url, enableWAL: true)
            try source.execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE retained(id INTEGER PRIMARY KEY,payload BLOB)")
            try source.execute("INSERT INTO schema_meta VALUES('schema_version',?)", bindings: [.text(version)])
            if version == "999" {
                try source.execute("INSERT INTO retained VALUES(42,?)", bindings: [.blob(Data([0,255,1]))])
            }
            originals.append((url, try source.withConnection { try CodexBusinessDatabase.proof($0) }))
        }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
        for (url, proof) in originals {
            let destination = c.exact.appendingPathComponent(url.lastPathComponent)
            let routed = SQLiteDatabaseDriver(url: destination)
            XCTAssertEqual(routed.backingURL, c.container)
            XCTAssertEqual(try routed.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!,
                url.lastPathComponent.hasPrefix("b") ? "3" : "999")
            let payloads = try routed.readRows("SELECT id,payload FROM retained") { ($0.int(0), $0.data(1)) }
            XCTAssertEqual(payloads.count, url.lastPathComponent.hasPrefix("b") ? 0 : 1)
            if let payload = payloads.first { XCTAssertEqual(payload.0, 42); XCTAssertEqual(payload.1, Data([0,255,1])) }
            let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: destination))
            let receipt = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self,
                from: Data(contentsOf: c.backups.appendingPathComponent(store.id).appendingPathComponent("receipt.json")))
            XCTAssertNotNil(receipt.normalizationDeferredReason)
            XCTAssertEqual(receipt.original, receipt.imported)
            XCTAssertThrowsError(try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: destination)) { error in
                XCTAssertTrue(error.localizedDescription.contains("newer or unknown"), "\(error)")
            }
            XCTAssertEqual(try SQLiteDatabaseDriver(url: url, readOnly: true, bypassBusinessRoutes: true)
                .withConnection { try CodexBusinessDatabase.proof($0) }, proof)
        }
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
    }
    func testNewExactScansInAReuseStagePathsAndDeletedHistorySurvivesAcrossHomes() throws {
        let (root, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let id = "019f1234-1234-1234-1234-123456789abc"
        var urls: [URL] = []
        for i in 0..<2 {
            let home = root.appendingPathComponent("home-\(i)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let file = home.appendingPathComponent("rollout-\(id).jsonl")
            func line(_ value: Int, second: Int) -> String {
                "{\"timestamp\":\"2026-10-01T00:00:0\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(value),\"cached_input_tokens\":0,\"output_tokens\":0,\"total_tokens\":\(value)}}}}\n"
            }
            try Data(line(120 + i, second: 0).utf8).write(to: file)
            let url = c.exact.appendingPathComponent(String(repeating: i == 0 ? "b" : "c", count: 64) + ".sqlite")
            urls.append(url)
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
            let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
            func sync(_ files: [URL]) throws {
                _ = try index.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
                    try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                        insertFingerprint: fingerprint, emit: emit)
                }
            }
            try sync([file])
            // Atomic rewrite forces a second full rebuild at the same logical
            // staging path. A completed prior job must not become a new file.
            try Data((line(120 + i, second: 0) + line(7, second: 1)).utf8).write(to: file, options: .atomic)
            try sync([file])
            try sync([file])
            try FileManager.default.removeItem(at: file)
            try sync([])
            let db = SQLiteDatabaseDriver(url: url)
            XCTAssertEqual(try db.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 127 + i)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNotEqual(BusinessSQLiteRoutes.store(for: urls[0])?.id, BusinessSQLiteRoutes.store(for: urls[1])?.id)
        let physical = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(physical, ["support/codex-ledger.sqlite"])
    }
    func testSafetyRecoveryIsScopedAndDoesNotEraseQuotaOrExact() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,used INTEGER); INSERT INTO quota_snapshots VALUES(1,77)")
        let safetyURL = c.support.appendingPathComponent("shared-account-usage-safety.sqlite")
        let safety = SharedAccountUsageSafetyDatabase(url: safetyURL)
        XCTAssertTrue(safety.persistenceHealthy)
        XCTAssertTrue(safety.store(Data("{\"kept\":true}".utf8), as: .segments))
        safety.reportCorruptPayload(.segments)
        let suite = "scoped-safety-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovered = try XCTUnwrap(safety.rebuildEmptySafetyBaseline(preciseContinuityPayload: Data("{}".utf8),
            defaults: defaults, retiredUserDefaultsKeys: []))
        XCTAssertTrue(safety.persistenceHealthy)
        XCTAssertEqual(safety.load(.segments), Data("{}".utf8))
        XCTAssertEqual(try quota.readRows("SELECT used FROM quota_snapshots") { $0.int(0) }.first!, 77)
        let backup = SQLiteDatabaseDriver(url: recovered.quarantineDirectory.appendingPathComponent("safety-before-recovery.sqlite"), readOnly: true)
        XCTAssertEqual(try backup.readRows("SELECT payload FROM safety_records WHERE kind='segments-v08'") { $0.data(0) }.first!, Data("{\"kept\":true}".utf8))
    }

    func testMissingActivatedContainerCannotResurrectStaleLegacy() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: legacy).execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try SQLiteDatabaseDriver(url: legacy).execute("INSERT INTO quota_snapshots VALUES(2)")
        BusinessSQLiteRoutes.deactivate()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: c.container.path + suffix) }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 1)
    }
    func testContainerMaintenancePreservesOtherModulesAndSealedJobs() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,payload BLOB)")
        try quota.transaction { tx in
            let insert = try tx.prepare("INSERT INTO quota_snapshots VALUES(?,?)")
            for id in 0..<2048 { _ = try insert.execute([.int(id), .blob(Data(repeating: UInt8(id % 255), count: 2048))]) }
        }
        try quota.execute("DELETE FROM quota_snapshots WHERE id>=10")
        let stageURL = c.exact.appendingPathComponent("staging/store.sqlite/sealed.sqlite")
        try SQLiteDatabaseDriver(url: stageURL).withConnection { db in
            try db.execute("CREATE TABLE events(label TEXT); INSERT INTO events(rowid,label) VALUES(150,'retained-rowid')")
            try BusinessStoreFiles.seal(at: stageURL, connection: db)
        }
        let before = try SourceFileObservation.read(at: stageURL)
        let policy = CodexUsageIndexStorageMaintenancePolicy(minimumCheckInterval: 86400, minimumFreeBytes: 1,
            absoluteFreeBytes: 1, minimumFreePercent: 0, diskReserveBytes: 0)
        let result = try BusinessDatabaseMaintenance.run(container: c.container, now: Date(timeIntervalSince1970: 100), policy: policy, availableCapacity: 1 << 32)
        guard case .compacted = result else { return XCTFail("expected scoped container maintenance: \(result)") }
        XCTAssertTrue(before.matches(try SourceFileObservation.read(at: stageURL)))
        XCTAssertEqual(try quota.readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 10)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: stageURL, readOnly: true).readRows("SELECT rowid FROM events") { $0.int(0) }.first!, 150)
        XCTAssertEqual(try BusinessDatabaseMaintenance.run(container: c.container, now: Date(timeIntervalSince1970: 101), policy: policy), .notDue)
    }

    func testOldPhysicalStageMigratesAndResumesWithoutParsingOrLosingCheckpoint() throws {
        let (root, c) = try fixture()
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"cached_input_tokens\":30,\"output_tokens\":0,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let exactURL = c.exact.appendingPathComponent(String(repeating: "d", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
        CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()
        XCTAssertThrowsError(try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        })
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let migrated = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        _ = try migrated.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            XCTFail("a verified migrated stage must be reused")
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: exactURL).readRows("SELECT SUM(tokens),SUM(cached_input_tokens) FROM events") { [$0.int(0),$0.int(1)] }.first!, [120,30])
    }

    func testColdParserDoesNotHoldTheContainersWriteLock() throws {
        let (root, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: c.exact.appendingPathComponent(String(repeating: "e", count: 64) + ".sqlite"))
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        var parses = 0
        _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            parses += 1
            // This write is on a second connection, while the producer's TEMP
            // transaction is open. It would time out if the parser held A.
            try quota.execute("INSERT INTO quota_snapshots VALUES(2) ON CONFLICT(id) DO NOTHING")
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id,
                request: request, insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(try quota.readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
    }
    func testInterruptedLegacyExchangeUsesRollbackWithoutChangingOldFiles() throws {
        let (_, c) = try fixture()
        let main = c.exact.appendingPathComponent(String(repeating: "f", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: main)
        let old = SQLiteDatabaseDriver(url: main)
        try old.execute("INSERT INTO schema_meta(key,value) VALUES('extra-legacy-evidence','kept')")
        try old.execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
        let rollback = URL(fileURLWithPath: main.path + ".schema11-rollback")
        try FileManager.default.moveItem(at: main, to: rollback)
        let manifest = URL(fileURLWithPath: main.path + ".schema11-migration.json")
        let bytes = try JSONSerialization.data(withJSONObject: [
            "manifestVersion": 1, "phase": "switching", "sourcePath": main.path,
            "candidatePath": main.path + ".schema11-candidate", "rollbackPath": rollback.path
        ], options: [.sortedKeys])
        try bytes.write(to: manifest)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.path))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: main).readRows("SELECT value FROM schema_meta WHERE key='extra-legacy-evidence'") { $0.text(0) }.first!, "kept")
    }

}
