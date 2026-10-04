import Foundation
import XCTest
@testable import CodexTokenBar

final class CompressedHistoryIndexTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let file: URL
        let db: SQLiteDatabaseDriver
        let analyzer: CodexUsageAnalyzer
        let index: CodexUsageHistoryIndex
        func synchronize() throws -> CodexUsageHistoryIndex.SynchronizationResult {
            try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) {
                file, id, request, fingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id,
                    request: request, insertFingerprint: fingerprint, emit: emit)
            }
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        let db = SQLiteDatabaseDriver(url: root.appendingPathComponent("index.sqlite"))
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: db.url)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        try Data(line(120).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: file.path)
        return Fixture(root: root, file: file, db: db, analyzer: analyzer, index: index)
    }
    private func line(_ input: Int, second: Int = 0) -> String {
        """
        {"timestamp":"2026-10-01T00:00:\(String(format: "%02d", second))Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\(input)}}}}

        """
    }
    // Standard single zstd frame containing uncompressed blocks; no external compressor.
    private func frame(_ bytes: Data) -> Data {
        var output = Data([0x28,0xb5,0x2f,0xfd,0xa0])
        var size = UInt32(bytes.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        var offset = 0
        repeat {
            let count = min(128 * 1024, bytes.count - offset)
            let header = UInt32(count << 3) | (offset + count == bytes.count ? 1 : 0)
            output.append(contentsOf: [UInt8(header & 255), UInt8((header >> 8) & 255), UInt8((header >> 16) & 255)])
            output.append(bytes.subdata(in: offset..<(offset + count)))
            offset += count
        } while offset < bytes.count
        return output
    }
    private func compress(_ f: Fixture) throws -> URL {
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.file.path)[.modificationDate] as? Date)
        let zst = URL(fileURLWithPath: f.file.path + ".zst")
        try frame(Data(contentsOf: f.file)).write(to: zst)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: zst.path)
        try FileManager.default.removeItem(at: f.file)
        return zst
    }
    private func scalar(_ db: SQLiteDatabaseDriver, _ sql: String) throws -> Int64 {
        try XCTUnwrap(db.readRows(sql) { $0.int64(0) }.first ?? nil)
    }
    func testCompleteCompressedSourceReusesLedgerAndMissingIdentityWithoutParser() throws {
        let f = try fixture()
        _ = try f.synchronize()
        let source = try scalar(f.db, "SELECT source_id FROM sources")
        let events = try scalar(f.db, "SELECT COUNT(*) FROM events")
        XCTAssertEqual(try scalar(f.db, "SELECT resume_offset=size_bytes FROM sources"), 1)
        try f.db.execute("UPDATE usage_ledger_sources SET missing=1; UPDATE usage_ledger_bindings SET available=0;")
        _ = try compress(f)
        let reused = try f.index.synchronize(files: [f.file], sessionID: f.analyzer.sessionID(from:)) { _,_,_,_,_ in
            XCTFail("complete compressed history must not be reparsed")
            throw CocoaError(.fileReadUnknown)
        }
        XCTAssertEqual(reused.unchangedFiles, 1)
        XCTAssertEqual(try scalar(f.db, "SELECT source_id FROM sources"), source)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM events"), events)
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        XCTAssertEqual(try scalar(f.db, "SELECT missing FROM usage_ledger_sources"), 0)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM source_representations"), 1)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
    }
    func testColdCompressedSourceCountsOnceAndMaterializedAppendAddsOnlyNewRequest() throws {
        let f = try fixture()
        _ = try compress(f)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM events"), 1)
        try Data((line(120) + line(7, second: 1)).utf8).write(to: f.file)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 127)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 127)
    }
    func testCorruptCompressedSourceKeepsNumericHistory() throws {
        let f = try fixture()
        _ = try f.synchronize()
        let zst = try compress(f)
        try Data([0x28,0xb5,0x2f,0xfd]).write(to: zst)
        XCTAssertThrowsError(try f.synchronize())
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
    }
    func testCompressedCatalogRetainsLogicalSizeAndSkipsWarmFirstLine() throws {
        let f = try fixture()
        _ = try compress(f)
        let metadata = CodexUsageHistoryIndex.SessionCatalogMetadata(threadID: "thread",
            cwd: "/synthetic", sessionID: nil, forkedFromID: nil, parentThreadID: nil, source: "cli")
        let cold = try f.index.synchronizeSessionCatalog(candidates: [.init(file: f.file, archived: false)]) { file in
            let reader = try CodexRolloutReader(forReadingFrom: file)
            defer { try? reader.close() }
            XCTAssertFalse((try reader.read(upToCount: 1024) ?? Data()).isEmpty)
            return metadata
        }
        XCTAssertEqual(cold.entries.first?.sizeBytes, Int64(line(120).utf8.count))
        let warm = try f.index.synchronizeSessionCatalog(candidates: [.init(file: f.file, archived: false)]) { _ in
            XCTFail("warm compressed catalog must not reparse its first line")
            return metadata
        }
        XCTAssertEqual(warm.parsedFirstLines, 0)
    }
    func testRestoredCompressedTextOffsetsRequireOldChunkProof() throws {
        let f = try fixture()
        let prompt = """
        {"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"synthetic prompt"}}

        """
        try Data((prompt + line(120)).utf8).write(to: f.file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: f.file.path)
        _ = try f.synchronize()
        var ids: [String] = []
        try f.index.forEachStoredEvent { ids.append($0.stableID) }
        _ = try compress(f)
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), 0)
        XCTAssertEqual(try f.index.turnSourceReferences(for: ids).count, ids.count)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), Int64(ids.count))
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
    }
    private func promptFixture() throws -> Fixture {
        let f = try fixture()
        let prompt = """
        {"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"synthetic prompt"}}

        """
        try Data((prompt + line(120)).utf8).write(to: f.file)
        _ = try f.synchronize()
        return f
    }
    private func eventIDs(_ f: Fixture) throws -> [String] {
        var ids: [String] = []
        try f.index.forEachStoredEvent { ids.append($0.stableID) }
        return ids
    }
    private func markMissing(_ f: Fixture) throws {
        _ = try f.index.synchronize(files: [], sessionID: f.analyzer.sessionID(from:)) { _,_,_,_,_ in
            XCTFail("missing-source observation must not parse")
            throw CocoaError(.fileReadUnknown)
        }
        XCTAssertEqual(try scalar(f.db, "SELECT missing FROM usage_ledger_sources"), 1)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), 0)
    }
    func testVerifiedTextReappearingUnchangedRestoresLinksWithoutRecounting() throws {
        for compressed in [false, true] {
            let f = try promptFixture()
            let ids = try eventIDs(f)
            let source = try scalar(f.db, "SELECT source_id FROM sources")
            let resume = try scalar(f.db, "SELECT resume_offset FROM sources")
            if compressed {
                _ = try compress(f)
                _ = try f.synchronize()
            }
            XCTAssertEqual(try f.index.turnSourceReferences(for: ids).count, ids.count)
            try markMissing(f)
            _ = try f.synchronize()
            XCTAssertEqual(try scalar(f.db, "SELECT missing FROM usage_ledger_sources"), 0)
            XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), 0)
            XCTAssertEqual(try f.index.turnSourceReferences(for: ids).count, ids.count)
            XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), Int64(ids.count))
            _ = try f.synchronize()
            XCTAssertEqual(try eventIDs(f), ids)
            XCTAssertEqual(try scalar(f.db, "SELECT source_id FROM sources"), source)
            XCTAssertEqual(try scalar(f.db, "SELECT resume_offset FROM sources"), resume)
            XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        }
    }
    func testRestoredTextChangedBeforeProofKeepsLinksUnavailableAndNumbersIntact() throws {
        for compressed in [false, true] {
            let f = try promptFixture()
            let ids = try eventIDs(f)
            let original = try Data(contentsOf: f.file)
            let physical = try (compressed ? compress(f) : f.file)
            _ = try f.synchronize()
            XCTAssertEqual(try f.index.turnSourceReferences(for: ids).count, ids.count)
            try markMissing(f)
            _ = try f.synchronize()
            let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: physical.path)[.modificationDate] as? Date)
            let changed = Data(String(decoding: original, as: UTF8.self)
                .replacingOccurrences(of: "synthetic prompt", with: "different prompt").utf8)
            XCTAssertEqual(changed.count, original.count)
            try (compressed ? frame(changed) : changed).write(to: physical)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: physical.path)
            XCTAssertTrue(try f.index.turnSourceReferences(for: ids).isEmpty)
            XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1"), 0)
            XCTAssertEqual(try eventIDs(f), ids)
            XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        }
    }
    func testBadZeroOutputTrailingFrameRollsBackAppendAndValidMultiFrameRetriesOnce() throws {
        let f = try fixture()
        _ = try f.synchronize()
        let ids = try eventIDs(f)
        let resume = try scalar(f.db, "SELECT resume_offset FROM sources")
        let fingerprints = try scalar(f.db, "SELECT COUNT(*) FROM source_fingerprints")
        let bytes = Data((line(120) + line(7, second: 1)).utf8)
        let zst = URL(fileURLWithPath: f.file.path + ".zst")
        // Empty final frame with a deliberately wrong checksum. Its FCS is
        // zero, so the parser's logical byte bound does not consume it.
        let badTail = Data([0x28,0xb5,0x2f,0xfd,0x24,0,1,0,0,0,0,0,0])
        try (frame(bytes) + badTail).write(to: zst)
        try FileManager.default.removeItem(at: f.file)
        var usedAppend = false
        XCTAssertThrowsError(try f.index.synchronize(files: [f.file], sessionID: f.analyzer.sessionID(from:)) {
            file, id, request, fingerprint, emit in
            usedAppend = request.parsingStartOffset == UInt64(resume)
            return try f.analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id,
                request: request, insertFingerprint: fingerprint, emit: emit)
        })
        XCTAssertTrue(usedAppend)
        XCTAssertEqual(try eventIDs(f), ids)
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        XCTAssertEqual(try scalar(f.db, "SELECT resume_offset FROM sources"), resume)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM source_fingerprints"), fingerprints)
        try (frame(bytes) + frame(Data())).write(to: zst)
        _ = try f.synchronize()
        _ = try f.synchronize()
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 127)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM events"), 2)
    }
    func testThirteenToFourteenIsAdditiveAndHasConsistentBackup() throws {
        let f = try fixture()
        _ = try f.synchronize()
        try f.db.execute("""
            DROP TABLE source_representations;
            DELETE FROM schema_meta WHERE key IN ('representation_revision','representation_upgrade_backup');
            UPDATE schema_meta SET value='13' WHERE key='schema_version';
            CREATE TABLE expected_events AS SELECT * FROM events;
            CREATE TABLE expected_sources AS SELECT * FROM sources;
            """)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: f.db.url)
        XCTAssertEqual(try scalar(f.db, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 14)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM (SELECT * FROM expected_events EXCEPT SELECT * FROM events)"), 0)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM (SELECT * FROM expected_sources EXCEPT SELECT * FROM sources)"), 0)
        let backup = try XCTUnwrap(f.db.readRows("SELECT value FROM schema_meta WHERE key='representation_upgrade_backup'") { $0.text(0) }.first ?? nil)
        let saved = SQLiteDatabaseDriver(url: URL(fileURLWithPath: backup), readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try scalar(saved, "SELECT SUM(tokens) FROM events"), 120)
        XCTAssertEqual(try scalar(saved, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 13)
    }
    func testInterruptedStorageTransactionKeepsThirteenAndReusesOneBackup() throws {
        let f = try fixture()
        _ = try f.synchronize()
        try f.db.execute("""
            DROP TABLE source_representations;
            DELETE FROM schema_meta WHERE key IN ('representation_revision','representation_upgrade_backup');
            UPDATE schema_meta SET value='13' WHERE key='schema_version';
            CREATE TRIGGER stop_storage_upgrade BEFORE UPDATE ON schema_meta
            WHEN NEW.key='schema_version' AND NEW.value='14'
            BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END;
            """)
        XCTAssertThrowsError(try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: f.db.url))
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
        XCTAssertEqual(try scalar(f.db, "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key='schema_version'"), 13)
        XCTAssertEqual(try scalar(f.db, "SELECT COUNT(*) FROM sqlite_master WHERE name='source_representations'"), 0)
        try f.db.execute("DROP TRIGGER stop_storage_upgrade")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: f.db.url)
        let backups = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
            .filter { $0.hasSuffix(".schema13-before-representations.sqlite") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try scalar(f.db, "SELECT SUM(tokens) FROM events"), 120)
    }

}
