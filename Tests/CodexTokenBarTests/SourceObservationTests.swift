import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class SourceObservationTests: XCTestCase {
    func testAtomicReplacementAndInPlaceRewritePreservingMetadataAreDetectedAfterReopen() throws {
        for atomic in [false, true] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try fixture.sync()
            var before = stat()
            XCTAssertEqual(lstat(fixture.file.path, &before), 0)
            let changed = try fixture.line(900)
            XCTAssertEqual(changed.count, Int(before.st_size))
            try changed.write(to: fixture.file, options: atomic ? .atomic : [])
            var times = [before.st_atimespec, before.st_mtimespec]
            XCTAssertEqual(utimensat(AT_FDCWD, fixture.file.path, &times, 0), 0)
            var after = stat()
            XCTAssertEqual(lstat(fixture.file.path, &after), 0)
            XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
            XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
            if atomic { XCTAssertNotEqual(before.st_ino, after.st_ino) }
            else { XCTAssertEqual(before.st_ino, after.st_ino) }
            let updated = try fixture.sync()
            XCTAssertGreaterThan(updated.changedFiles, 0)
            XCTAssertEqual(try fixture.scalar("SELECT SUM(tokens) FROM events"), 100)
            XCTAssertGreaterThan(try fixture.scalar("SELECT COUNT(*) FROM usage_ledger_unresolved"), 0)
            CodexUsageHistoryIndex.resetSourceContentProbeCountForTesting()
            CodexUsageHistoryIndex.resetFullContentHashCountForTesting()
            XCTAssertEqual(try fixture.sync().changedFiles, 0)
            XCTAssertEqual(CodexUsageHistoryIndex.sourceContentProbeCountForTesting, 0)
            XCTAssertEqual(CodexUsageHistoryIndex.fullContentHashCountForTesting, 0)
        }
    }

    func testOldObservationBaselineAdoptionAndWarmReopenNeverReadBodies() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.sync()
        try fixture.database.execute("DROP TABLE source_observations;")
        CodexUsageHistoryIndex.resetSourceContentProbeCountForTesting()
        CodexUsageHistoryIndex.resetFullContentHashCountForTesting()
        XCTAssertEqual(try fixture.sync().changedFiles, 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM source_observations"), 1)
        XCTAssertEqual(try fixture.sync().changedFiles, 0)
        XCTAssertEqual(CodexUsageHistoryIndex.sourceContentProbeCountForTesting, 0)
        XCTAssertEqual(CodexUsageHistoryIndex.fullContentHashCountForTesting, 0)
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let database: SQLiteDatabaseDriver
        let analyzer: CodexUsageAnalyzer
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("source-observation-\(UUID())")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            file = root.appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
            database = SQLiteDatabaseDriver(url: root.appendingPathComponent("index.sqlite"))
            analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
            try line(100).write(to: file)
        }
        func line(_ tokens: Int) throws -> Data {
            let payload: [String: Any] = ["timestamp":"2026-07-20T01:00:00Z", "type":"event_msg",
                "payload":["type":"token_count", "info":["last_token_usage":["input_tokens":tokens,
                    "cached_input_tokens":0, "output_tokens":0, "total_tokens":tokens]]]]
            var data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            data.append(10)
            return data
        }
        func scalar(_ sql: String) throws -> Int64 { try XCTUnwrap(database.readRows(sql) { $0.int64(0) }.first ?? nil) }
        func sync() throws -> CodexUsageHistoryIndex.SynchronizationResult {
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: database.url)
            return try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprints, emit in
                try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                    insertFingerprint: fingerprints, emit: emit)
            }
        }
    }
}
