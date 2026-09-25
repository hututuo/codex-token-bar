import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class SourceObservationTests: XCTestCase {
    func testLegacySnapshotKeyRemainsDecodableButCannotMatchUnobservedPhysicalIdentity() throws {
        let old = Data(#"{"path":"/fixture/rollout.jsonl","size":100,"modifiedAt":42}"#.utf8)
        let legacy = try JSONDecoder().decode(CodexUsageAnalyzer.SessionCacheKey.self, from: old)
        XCTAssertNil(legacy.physicalStamp)
        let current = CodexUsageAnalyzer.SessionCacheKey(path: legacy.path, size: legacy.size,
            modifiedAt: legacy.modifiedAt, physicalStamp: "1:2:3:4")
        XCTAssertNotEqual(legacy, current)
        XCTAssertEqual(try JSONDecoder().decode(CodexUsageAnalyzer.SessionCacheKey.self,
            from: JSONEncoder().encode(current)), current)
    }

    func testFullSnapshotWarmCacheDetectsPreservedMetadataRewrites() throws {
        for atomic in [false, true] {
            try withFullSnapshotFixture { analyzer, file, database, body in
                let initial = try analyzer.load()
                XCTAssertEqual(initial.stats.totalTokens, 100)
                _ = try analyzer.load()
                var before = stat()
                XCTAssertEqual(lstat(file.path, &before), 0)
                let replacement = try body(900)
                XCTAssertEqual(replacement.count, Int(before.st_size))
                try replacement.write(to: file, options: atomic ? .atomic : [])
                var times = [before.st_atimespec, before.st_mtimespec]
                XCTAssertEqual(utimensat(AT_FDCWD, file.path, &times, 0), 0)
                var after = stat()
                XCTAssertEqual(lstat(file.path, &after), 0)
                XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
                XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
                if atomic { XCTAssertNotEqual(before.st_ino, after.st_ino) }
                else { XCTAssertEqual(before.st_ino, after.st_ino) }

                // Exercise the public full loader, not a direct index sync or
                // a compact refresh that would conceal a stale upper cache.
                let updated = try analyzer.load()
                XCTAssertEqual(updated.stats.totalTokens, 100, "Keep the proven historical ledger")
                let conflicts = try database().readRows("SELECT COUNT(*) FROM usage_ledger_unresolved") { $0.int64(0)! }.first!
                XCTAssertGreaterThan(conflicts, 0, "The full warm cache must observe the rewrite")
            }
        }
    }

    func testFullSnapshotUnchangedRefreshAndCacheReloadDoNotHashBodies() throws {
        try withFullSnapshotFixture { analyzer, _, _, _ in
            XCTAssertEqual(try analyzer.load().stats.totalTokens, 100)
            _ = try analyzer.load()
            CodexUsageHistoryIndex.resetSourceContentProbeCountForTesting()
            CodexUsageHistoryIndex.resetFullContentHashCountForTesting()
            CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
            for _ in 0..<3 { XCTAssertEqual(try analyzer.load().stats.totalTokens, 100) }
            CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
            XCTAssertEqual(try analyzer.load().stats.totalTokens, 100)
            XCTAssertEqual(CodexUsageHistoryIndex.sourceContentProbeCountForTesting, 0)
            XCTAssertEqual(CodexUsageHistoryIndex.fullContentHashCountForTesting, 0)
            XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
            XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 0)
        }
    }

    private func withFullSnapshotFixture(
        _ run: (CodexUsageAnalyzer, URL, () throws -> SQLiteDatabaseDriver, (Int) throws -> Data) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("full-source-observation-\(UUID())")
        let home = root.appendingPathComponent("home")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let keys = ["CODEX_TOKEN_BAR_USAGE_CACHE_DIR", "CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", "CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"]
        let previous = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        setenv(keys[0], cache.path, 1)
        setenv(keys[1], cache.path, 1)
        unsetenv(keys[2])
        let file = home.appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        func body(_ tokens: Int) throws -> Data {
            let usage = ["input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0, "total_tokens": tokens]
            let row: [String: Any] = ["timestamp": timestamp, "type": "event_msg",
                "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]
            var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            data.append(10)
            return data
        }
        func database() throws -> SQLiteDatabaseDriver {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            return SQLiteDatabaseDriver(url: try XCTUnwrap(files.first { $0.pathExtension == "sqlite" }))
        }
        try body(100).write(to: file)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
        try run(analyzer, file, database, body)
    }

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
