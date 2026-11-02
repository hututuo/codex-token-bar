import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessDatabaseMigrationExactAppendTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configuration: BusinessDatabaseMigration.Configuration
        let source: URL
        let files: [URL]
        let index: CodexUsageHistoryIndex
        let analyzer: CodexUsageAnalyzer
    }

    private func fixture(hasMessages: Bool = true) throws -> Fixture {
        BusinessSQLiteRoutes.deactivate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let configuration = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("cache"))
        let source = configuration.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: source)
        let files = ["019f1234-1234-1234-1234-123456789abc", "019f1234-1234-1234-1234-123456789def"]
            .map { root.appendingPathComponent("rollout-\($0).jsonl") }
        let prompt = hasMessages ? "{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"retained turn\"}}\n" : ""
        try Data((prompt + line(120, second: 1) + line(35, second: 2)).utf8).write(to: files[0])
        try Data((prompt + line(310, second: 1)).utf8).write(to: files[1])
        let fixture = Fixture(root: root, configuration: configuration, source: source, files: files, index: index,
            analyzer: CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected)))
        _ = try synchronize(fixture)
        return fixture
    }

    private func line(_ tokens: Int, second: Int) -> String {
        "{\"timestamp\":\"2026-10-01T00:00:\(String(format: "%02d", second))Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(tokens),\"cached_input_tokens\":0,\"output_tokens\":0,\"total_tokens\":\(tokens)}}}}\n"
    }

    private func append(_ tokens: Int, second: Int, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(tokens, second: second).utf8))
    }

    @discardableResult
    private func synchronize(_ fixture: Fixture) throws -> CodexUsageHistoryIndex.SynchronizationResult {
        try fixture.index.synchronize(files: fixture.files, sessionID: fixture.analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try fixture.analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
    }

    private func freeze(_ fixture: Fixture) throws -> BusinessDatabaseMigration.Receipt {
        enum Stop: Error { case afterImport }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(fixture.configuration, availableBytes: 1 << 33,
            beforeActivation: { throw Stop.afterImport }))
        let store = try XCTUnwrap(fixture.configuration.specification(for: fixture.source))
        let receipt = fixture.configuration.backups.appendingPathComponent(store.id).appendingPathComponent("receipt.json")
        return try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: receipt))
    }

    private func typedRows(_ db: SQLiteDatabaseDriver, table: String) throws -> Set<Data> {
        Set(try db.readRows("SELECT * FROM \(SQLiteStoreNamespace.quote(table))", map: ExactRetryAppendCoverage.encoded))
    }

    private func addMetadataToRewrittenSource(_ file: URL) throws {
        let original = try Data(contentsOf: file)
        let prefix = """
            {"timestamp":"2026-10-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5"}}
            {"timestamp":"2026-10-01T00:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"restored prompt"}]}}
            {"timestamp":"2026-10-01T00:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"restored answer"}]}}

            """
        // The released writer recognizes an unchanged usage fingerprint after
        // a representation rewrite. No database row or receipt is fabricated.
        try (Data(prefix.utf8) + original).write(to: file, options: .atomic)
    }

    func testRealLedgerEnrichmentAfterFrozenImportRequiresConstrainedMetadataCoverage() throws {
        let f = try fixture(hasMessages: false)
        let raw = SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true)
        let numeric = "SELECT source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,accounting_kind,reported_total_tokens,legacy_tokens FROM events"
        let oldNumeric = Set(try raw.readRows(numeric, map: ExactRetryAppendCoverage.encoded))
        let oldIdentities = try typedRows(raw, table: "usage_ledger_identities")
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM events WHERE model IS NULL AND user_prompt_offset IS NULL") { $0.int(0) }, [3])
        let receipt = try freeze(f)
        let frozen = URL(fileURLWithPath: receipt.normalizedPath)
        let frozenBytes = try Data(contentsOf: frozen)
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath))

        try addMetadataToRewrittenSource(f.files[0])
        XCTAssertEqual(try synchronize(f).rewrittenFiles, 1)
        XCTAssertEqual(Set(try raw.readRows(numeric, map: ExactRetryAppendCoverage.encoded)), oldNumeric)
        XCTAssertEqual(try typedRows(raw, table: "usage_ledger_identities"), oldIdentities)
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM events WHERE source_id=1 AND model='gpt-5' AND user_prompt_offset IS NOT NULL AND assistant_start_offset IS NOT NULL") { $0.int(0) }, [2])
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM retained_usage_revisions WHERE source_id=1 AND model IS NULL") { $0.int(0) }, [2])
        XCTAssertEqual(try raw.readRows("SELECT COUNT(DISTINCT generation) FROM usage_ledger_bindings WHERE source_id=1") { $0.int(0) }, [1])
        let incoming = try raw.withConnection { try CodexBusinessDatabase.proof($0) }
        let incomingBytes = try Data(contentsOf: f.source)
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(f.source, covers: frozen, module: "exact.swift",
            expectedRetained: receipt.imported, expectedCandidate: incoming),
            "Baseline reproduction: typed append-only coverage still rejects production NULL metadata enrichment")
        XCTAssertEqual(try raw.withConnection { try CodexBusinessDatabase.proof($0) }, incoming)
        XCTAssertEqual(try Data(contentsOf: f.source), incomingBytes)
        XCTAssertEqual(try Data(contentsOf: frozen), frozenBytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath)), originalBytes)
    }

    func testRealLegacyAppendResumesFrozenImportAndKeepsUnchangedHistoryWithoutRawFiles() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        let frozenURL = URL(fileURLWithPath: receipt.normalizedPath)
        let frozenBytes = try Data(contentsOf: frozenURL)
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath))
        let raw = SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true)
        let oldEvents = try typedRows(raw, table: "events")
        let oldIdentities = try typedRows(raw, table: "usage_ledger_identities")
        try append(17, second: 3, to: f.files[0])
        XCTAssertEqual(try synchronize(f).incrementallyParsedFiles, 1)
        let incomingProof = try raw.withConnection { try CodexBusinessDatabase.proof($0) }
        let incomingPhysicalBytes = try Data(contentsOf: f.source)
        let incomingEvents = try typedRows(raw, table: "events")
        XCTAssertTrue(oldEvents.isSubset(of: incomingEvents))
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM source_representations WHERE source_id=2 AND verification='verified_full'") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: frozenURL, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT COUNT(*) FROM source_representations WHERE source_id=2") { $0.int(0) }.first!, 0,
            "The frozen source came from its first parse; an extra refresh must not be required for recovery")
        // New raw bytes beyond the frozen candidate are not permission to skip
        // validation or to parse them into this import's proof.
        try append(11, second: 4, to: f.files[0])
        try FileManager.default.removeItem(at: f.files[1])
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(f.source, covers: frozenURL),
            "The generic all-row proof must reject changed source/checkpoint/cache rows")
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: frozenURL, module: "exact.swift",
            expectedRetained: receipt.imported, expectedCandidate: incomingProof))
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        let active = SQLiteDatabaseDriver(url: f.source)
        XCTAssertEqual(try typedRows(active, table: "events"), incomingEvents)
        XCTAssertTrue(oldIdentities.isSubset(of: try typedRows(active, table: "usage_ledger_identities")))
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 482)
        // A released owner captured its standalone route at construction. A
        // new process creates its owners only after activation; model that
        // lifecycle instead of writing through the still-open legacy owner.
        let candidateOwner = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: f.source)
        _ = try candidateOwner.synchronize(files: [f.files[0]], sessionID: f.analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try f.analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 493)
        XCTAssertEqual(try raw.withConnection { try CodexBusinessDatabase.proof($0) }, incomingProof)
        XCTAssertEqual(try Data(contentsOf: f.source), incomingPhysicalBytes)
        try FileManager.default.removeItem(at: f.files[0])
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: f.source)
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 493)
        XCTAssertTrue(oldEvents.isSubset(of: try typedRows(active, table: "events")))
        XCTAssertEqual(try Data(contentsOf: frozenURL), frozenBytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath)), originalBytes)
    }

    func testAddedRepresentationHintCannotHideChangedCheckpointObservationOrNewLedgerRowsWithoutRaw() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        try append(17, second: 3, to: f.files[0])
        _ = try synchronize(f)
        try FileManager.default.removeItem(at: f.files[1])
        let frozen = URL(fileURLWithPath: receipt.normalizedPath)
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: frozen, module: "exact.swift"))
        let mutations = [
            "UPDATE source_representations SET verification='metadata_only' WHERE source_id=2",
            "UPDATE source_representations SET physical_path='/unrelated.jsonl' WHERE source_id=2",
            "UPDATE source_representations SET logical_size=logical_size+1 WHERE source_id=2",
            "UPDATE source_observations SET physical_stamp='different-physical-file' WHERE source_id=2; UPDATE source_representations SET physical_stamp='different-physical-file' WHERE source_id=2",
            "UPDATE sources SET current_model='forged-checkpoint' WHERE source_id=2",
            "UPDATE source_chunks SET sha256=printf('%064d',0) WHERE source_id=2",
            "UPDATE event_enrichment_sources SET imported_generation='unproved-generation' WHERE source_id=2",
            "INSERT INTO usage_ledger_identities SELECT source_id,X'010203',source_offset FROM events WHERE source_id=2 LIMIT 1"
        ]
        for (number, mutation) in mutations.enumerated() {
            let url = f.root.appendingPathComponent("mutated-hint-\(number).sqlite")
            let db = SQLiteDatabaseDriver(url: url, enableWAL: false, bypassBusinessRoutes: true)
            try db.withConnection { try $0.restoreDatabase(from: f.source) }
            try db.execute(mutation)
            let before = try Data(contentsOf: url)
            do {
                XCTAssertFalse(try CodexBusinessDatabase.snapshot(url, covers: frozen, module: "exact.swift"), mutation)
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: f.source).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 482)
    }

    func testUnicodeEquivalentSourcePathsFailWithDiagnosticsWithoutDiscardingHistory() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        let frozen = URL(fileURLWithPath: receipt.normalizedPath)
        let frozenBytes = try Data(contentsOf: frozen)
        let paths = [f.root.path + "/rollout-\u{E9}.jsonl", f.root.path + "/rollout-e\u{301}.jsonl"]
        XCTAssertEqual(paths[0], paths[1], "Swift keys are canonically equivalent")
        XCTAssertNotEqual(Data(paths[0].utf8), Data(paths[1].utf8), "SQLite BINARY keys remain distinct")
        let raw = SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true)
        for (position, path) in paths.enumerated() {
            let id = Int64(position + 1)
            try raw.execute("UPDATE sources SET path=? WHERE source_id=?", bindings: [.text(path), .int64(id)])
            try raw.execute("UPDATE event_enrichment_sources SET canonical_path=? WHERE source_id=?", bindings: [.text(path), .int64(id)])
        }
        XCTAssertEqual(try raw.readRows("PRAGMA quick_check") { $0.text(0) }, ["ok"])
        XCTAssertEqual(try raw.readRows("SELECT COUNT(DISTINCT path COLLATE BINARY) FROM sources") { $0.int(0) }.first!, 2)
        let original = try raw.withConnection { try CodexBusinessDatabase.proof($0) }
        let bytes = try Data(contentsOf: f.source)
        XCTAssertThrowsError(try synchronize(f)) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate source path identity"))
        }
        let diagnostics = BusinessMigrationDiagnostics(root: f.root.appendingPathComponent("unicode-diagnostics"), operation: "retry-proof")
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(f.source, covers: frozen, module: "exact.swift", diagnostics: diagnostics))
        let events = try String(contentsOf: diagnostics.url, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data($0.utf8)) }
        XCTAssertTrue(events.contains { $0.stage == "retry-exact-parser-witness" && $0.status == "failed"
            && ($0.details["error"]?.contains("duplicate source path identity") ?? false) })
        XCTAssertTrue(events.contains { $0.stage == "retry-exact-projections" && $0.status == "started" })
        XCTAssertEqual(try raw.withConnection { try CodexBusinessDatabase.proof($0) }, original)
        XCTAssertEqual(try Data(contentsOf: f.source), bytes)
        XCTAssertEqual(try Data(contentsOf: frozen), frozenBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
    }

    func testRepeatedAppendsToDifferentSourcesDoNotDependOnReplayAllocationOrder() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        // Production allocated IDs in B→A→B order. The verifier visits paths
        // in A→B order and must prove the real bindings instead of reallocating.
        for (file, tokens, second) in [(1, 19, 3), (0, 17, 4), (1, 23, 5)] {
            try append(tokens, second: second, to: f.files[file])
            XCTAssertEqual(try synchronize(f).incrementallyParsedFiles, 1)
        }
        let raw = SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true)
        let incoming = try typedRows(raw, table: "events")
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: URL(fileURLWithPath: receipt.normalizedPath), module: "exact.swift"))
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        XCTAssertEqual(try typedRows(SQLiteDatabaseDriver(url: f.source), table: "events"), incoming)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: f.source).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 524)
    }

    func testLegacyWriterCanAddARealNewRolloutBeforeUnfinishedImportResumes() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        let third = f.root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789aaa.jsonl")
        try Data(line(41, second: 3).utf8).write(to: third)
        _ = try f.index.synchronize(files: f.files + [third], sessionID: f.analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try f.analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: URL(fileURLWithPath: receipt.normalizedPath), module: "exact.swift"))
        let incoming = try typedRows(SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true), table: "events")
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        let active = SQLiteDatabaseDriver(url: f.source)
        XCTAssertEqual(try typedRows(active, table: "events"), incoming)
        XCTAssertEqual(try active.readRows("SELECT COUNT(*) FROM sources") { $0.int(0) }.first!, 3)
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 506)
    }

    func testRecognizedPreCompactionReceiptAndAbsentEmptyCheckpointFieldCanResumeOrdinaryAppend() throws {
        let f = try fixture()
        let raw = SQLiteDatabaseDriver(url: f.source, bypassBusinessRoutes: true)
        let priorRevision = "token-event-v3-codex-components-v1-paginated-owned-turn-v6"
        func recordPreCompactionCheckpoint() throws {
            let rows = try raw.readRows("SELECT source_id,accounting_state FROM sources") { ($0.int64(0)!, $0.text(1)) }
            for (source, encoded) in rows {
                var state = try UsageAccountingState.decode(encoded)
                XCTAssertTrue(state.compaction == nil || state.compaction == CodexCompactionAccounting())
                state.compaction = nil
                try raw.execute("UPDATE sources SET accounting_state=? WHERE source_id=?", bindings: [.text(state.encoded), .int64(source)])
            }
            try raw.execute("UPDATE event_enrichment_sources SET parser_revision=?", bindings: [.text(priorRevision)])
        }
        try recordPreCompactionCheckpoint()
        let receipt = try freeze(f)
        // The genuine released-tag subprocess gate independently produces this
        // state with its original v3 writer. Here a real current append supplies
        // the same legacy token_count result and we retain the v3 serialization.
        try raw.execute("UPDATE event_enrichment_sources SET parser_revision=?",
            bindings: [.text(CodexUsageHistoryIndex.persistentSnapshotCompatibility.parserRevision)])
        try append(17, second: 3, to: f.files[0])
        XCTAssertEqual(try synchronize(f).incrementallyParsedFiles, 1)
        try recordPreCompactionCheckpoint()
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: URL(fileURLWithPath: receipt.normalizedPath), module: "exact.swift"))
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        let active = SQLiteDatabaseDriver(url: f.source)
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 482)
        XCTAssertEqual(try active.readRows("SELECT DISTINCT parser_revision FROM event_enrichment_sources") { $0.text(0) }, [priorRevision],
            "A successful continuity proof must not label v3 history as already reparsed by v4")
    }

    func testAppendProofRejectsLostHistoryOmittedNewEventsAndForgedCheckpointsOrProjections() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        try append(17, second: 3, to: f.files[0])
        XCTAssertEqual(try synchronize(f).incrementallyParsedFiles, 1)
        let frozen = URL(fileURLWithPath: receipt.normalizedPath)
        let mutations = [
            "DELETE FROM events WHERE source_offset=(SELECT MAX(source_offset) FROM events)",
            "UPDATE events SET tokens=tokens+1,input_tokens=input_tokens+1 WHERE tokens=120; UPDATE events SET tokens=tokens-1,input_tokens=input_tokens-1 WHERE tokens=35",
            "UPDATE sources SET current_model='forged-checkpoint' WHERE source_id=1",
            "UPDATE sources SET resume_offset=0 WHERE source_id=1",
            "UPDATE source_chunks SET sha256=printf('%064d',0) WHERE source_id=1",
            "UPDATE dashboard_source_totals SET total_tokens=total_tokens+1 WHERE source_id=1",
            "UPDATE attribution_source_buckets SET total_tokens=total_tokens+1",
            "DELETE FROM usage_ledger_identities WHERE event_id=(SELECT MIN(source_offset) FROM events)",
            "INSERT INTO usage_ledger_identities SELECT source_id,X'010203',source_offset FROM events LIMIT 1",
            "UPDATE schema_meta SET value='forged-epoch' WHERE key='provenance_epoch'",
            "UPDATE event_enrichment_sources SET parser_revision='unknown-future-parser' WHERE source_id=1"
        ]
        for (number, mutation) in mutations.enumerated() {
            let url = f.root.appendingPathComponent("mutated-\(number).sqlite")
            let db = SQLiteDatabaseDriver(url: url, enableWAL: false, bypassBusinessRoutes: true)
            try db.withConnection { try $0.restoreDatabase(from: f.source) }
            try db.execute(mutation)
            let before = try Data(contentsOf: url)
            do {
                XCTAssertFalse(try CodexBusinessDatabase.snapshot(url, covers: frozen, module: "exact.swift"), mutation)
            } catch {
                // A malformed checkpoint or absent emitted binding is a
                // rejecting proof too; it must never authorize replacement.
                XCTAssertFalse(error is CancellationError)
            }
            XCTAssertEqual(try Data(contentsOf: url), before, "The rejecting proof is read-only: \(mutation)")
        }
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: f.source).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 482)
    }

    func testRawRewriteAfterLegacyAppendDoesNotAuthorizeDroppingFrozenDestination() throws {
        let f = try fixture()
        let receipt = try freeze(f)
        try append(17, second: 3, to: f.files[0])
        _ = try synchronize(f)
        let priorRaw = try Data(contentsOf: f.files[0])
        let rewritten = String(decoding: priorRaw, as: UTF8.self).replacingOccurrences(of: "retained turn", with: "replaced turn")
        try Data(rewritten.utf8).write(to: f.files[0])
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
        let store = try XCTUnwrap(f.configuration.specification(for: f.source))
        let pending = SQLiteDatabaseDriver(url: f.configuration.support.appendingPathComponent(".codex-ledger-migrating.sqlite"),
            readOnly: true, bypassBusinessRoutes: true)
        let count = try pending.readRows("SELECT SUM(tokens) FROM \(SQLiteStoreNamespace.quote(store.prefix + "events"))") { $0.int(0) }.first!
        XCTAssertEqual(count, 465)
        try priorRaw.write(to: f.files[0])
        try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: f.source).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 482)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.normalizedPath))
    }

    func testOneRetryLogsEveryIndependentChangedSourceProofFailure() throws {
        let f = try fixture()
        _ = try freeze(f)
        try append(17, second: 3, to: f.files[0])
        try append(19, second: 3, to: f.files[1])
        XCTAssertEqual(try synchronize(f).incrementallyParsedFiles, 2)
        for file in f.files {
            let text = try String(contentsOf: file, encoding: .utf8)
                .replacingOccurrences(of: "retained turn", with: "damaged turn")
            try Data(text.utf8).write(to: file)
        }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 1 << 33))
        let directory = f.configuration.container.deletingLastPathComponent().appendingPathComponent("migration-diagnostics")
        var events: [BusinessMigrationDiagnostics.Event] = []
        for file in try BusinessMigrationDiagnostics.files(at: directory) {
            events += try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data($0.utf8)) }
        }
        let failed = events.filter { $0.stage == "retry-exact-source-proof" && $0.status == "failed" }
        XCTAssertEqual(Set(failed.compactMap { $0.details["source"] }), Set(f.files.map(\.path)))
        XCTAssertEqual(failed.count, 2)
        XCTAssertTrue(events.contains { $0.stage == "retry-exact-projections" && $0.status == "started" },
            "Independent read-only projection diagnostics still run when a raw prefix is invalid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
    }

    func testOnlyTheKnownRetainedCompactionQueryIndexMayBeAddedToAFrozenSchema() throws {
        let f = try fixture()
        let previous = f.root.appendingPathComponent("released-before-compaction-index.sqlite")
        let retained = SQLiteDatabaseDriver(url: previous, enableWAL: false, bypassBusinessRoutes: true)
        try retained.withConnection { try $0.restoreDatabase(from: f.source) }
        try retained.execute("DROP INDEX retained_unreported_compactions")
        let original = try Data(contentsOf: previous)
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(f.source, covers: previous))
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: previous, module: "exact.swift"))
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(previous, covers: f.source, module: "exact.swift"),
            "Removing the known index is not the recognized additive transition")
        try append(17, second: 3, to: f.files[0])
        _ = try synchronize(f)
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(f.source, covers: previous, module: "exact.swift"),
            "The same proof must compose the known schema addition with real legacy append")
        let mutations = [
            "DROP INDEX retained_unreported_compactions; CREATE INDEX retained_unreported_compactions ON retained_usage_events(position) WHERE accounting_kind=4",
            "CREATE INDEX unrecognized_retry_index ON events(tokens)",
            "DROP TRIGGER retain_usage_before_event_delete",
            "CREATE UNIQUE INDEX unrecognized_unique_index ON events(source_id,source_offset)"
        ]
        for (number, mutation) in mutations.enumerated() {
            let candidate = f.root.appendingPathComponent("schema-conflict-\(number).sqlite")
            let db = SQLiteDatabaseDriver(url: candidate, enableWAL: false, bypassBusinessRoutes: true)
            try db.withConnection { try $0.restoreDatabase(from: f.source) }
            try db.execute(mutation)
            XCTAssertFalse(try CodexBusinessDatabase.snapshot(candidate, covers: previous, module: "exact.swift"), mutation)
        }
        XCTAssertEqual(try Data(contentsOf: previous), original)
    }
}
