import Foundation
import XCTest
@testable import CodexTokenBar

final class ConfirmedMissingRolloutTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfirmedMissingRollout-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cache.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cache.path, 1)
        CodexUsageAnalyzer.clearUsageCachesForTesting()
        CodexUsageAnalyzer.resetPersistentExactSnapshotStateForTesting()
    }

    override func tearDownWithError() throws {
        CodexUsageAnalyzer.clearUsageCachesForTesting()
        CodexUsageAnalyzer.resetPersistentExactSnapshotStateForTesting()
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testDanglingStatePathKeepsIndexedUsageAndAcceptsForkOwnedAppendsAndRestoration() throws {
        let parentID = "019ff8b8-0000-7000-8000-000000000000"
        let parentFile = home.appendingPathComponent("sessions/rollout-\(parentID).jsonl")
        try writeLines([standaloneTokenLine(total: 120)], to: parentFile)
        try makeStateDatabase(rows: [("parent", parentFile.path, 99_999)])

        let analyzer = makeAnalyzer()
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)
        let database = try historyDatabase()
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)

        // The indexed source has physically left the selected Home while the
        // Codex-owned state database still points at its former active path.
        let heldParent = root.appendingPathComponent("held-parent.jsonl")
        try FileManager.default.moveItem(at: parentFile, to: heldParent)
        XCTAssertTrue(try analyzer.usageJSONLFiles().isEmpty)
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 120)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing = 1", in: database),
            1
        )

        // The child rollout replays its parent's turn, which must stay excluded.
        // Its own turn is appended after the child-created boundary and must be
        // counted even while the parent's indexed source is absent.
        let childID = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a"
        let ownTurnID = "019ff8b9-0ace-7c02-9f89-4358b15cceda"
        let childFile = home.appendingPathComponent("sessions/rollout-\(childID).jsonl")
        let replay = [
            forkRecord(0, "session_meta", [
                "id": childID,
                "history_mode": "paginated",
                "thread_source": "user",
                "forked_from_id": parentID,
            ]),
            forkRecord(1, "event_msg", ["type": "task_started", "turn_id": parentID]),
            forkRecord(2, "turn_context", ["model": "gpt-6-sol", "turn_id": parentID]),
            forkTokenRecord(3, tokens: 120),
            forkRecord(4, "event_msg", ["type": "task_started", "turn_id": ownTurnID]),
        ]
        try writeLines(replay, to: childFile)
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)

        try appendLines([
            forkRecord(5, "turn_context", ["model": "gpt-6-sol", "turn_id": ownTurnID]),
            forkTokenRecord(6, tokens: 20),
        ], to: childFile)
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 140)

        try appendLines([forkTokenRecord(7, tokens: 30)], to: childFile)
        let afterSecondAppend = try analyzer.load()
        XCTAssertEqual(afterSecondAppend.stats.totalTokens, 170)
        XCTAssertEqual(afterSecondAppend.stats.totalCalls, 3)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 170)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events", in: database), 3)

        try FileManager.default.moveItem(at: heldParent, to: parentFile)
        let restored = try analyzer.load()
        XCTAssertEqual(restored.stats.totalTokens, 170)
        XCTAssertEqual(restored.stats.totalCalls, 3)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", in: database), 170)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events", in: database), 3)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM usage_ledger_sources WHERE missing = 1", in: database),
            0
        )
    }

    func testNewIndexSkipsDanglingStatePathWithoutFabricatingTokenUsage() throws {
        let missingPath = home.appendingPathComponent("sessions/rollout-never-created.jsonl")
        try makeStateDatabase(rows: [("dangling", missingPath.path, 987_654)])

        let analyzer = makeAnalyzer()
        XCTAssertTrue(try analyzer.usageJSONLFiles().isEmpty)
        let snapshot = try analyzer.load()

        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.totalCalls, 0)
        XCTAssertEqual(snapshot.stats.totalThreads, 1)
        XCTAssertEqual(snapshot.usagePrecision, .metadataOnly)
        XCTAssertNil(try CodexUsageHistoryIndex.openExisting(codexHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerDirectory.path))
    }

    private func makeAnalyzer() -> CodexUsageAnalyzer {
        CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
    }

    private func makeStateDatabase(rows: [(id: String, rolloutPath: String, tokensUsed: Int)]) throws {
        let database = SQLiteDatabaseDriver(url: home.appendingPathComponent("state_5.sqlite"))
        try database.execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                first_user_message TEXT,
                preview TEXT,
                reasoning_effort TEXT,
                updated_at_ms INTEGER,
                updated_at INTEGER,
                tokens_used INTEGER NOT NULL,
                rollout_path TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            """)
        for row in rows {
            try database.execute(
                """
                INSERT INTO threads (
                    id, title, first_user_message, preview, reasoning_effort,
                    updated_at_ms, updated_at, tokens_used, rollout_path, archived
                ) VALUES (?, 'Synthetic thread', 'first message', 'preview', 'high', ?, ?, ?, ?, 0);
                """,
                bindings: [
                    .text(row.id),
                    .int(Int(Date().timeIntervalSince1970 * 1000)),
                    .int(Int(Date().timeIntervalSince1970)),
                    .int(row.tokensUsed),
                    .text(row.rolloutPath),
                ]
            )
        }
    }

    private func standaloneTokenLine(total: Int) -> String {
        let usage = [
            "input_tokens": total,
            "cached_input_tokens": 0,
            "output_tokens": 0,
            "reasoning_output_tokens": 0,
            "total_tokens": total,
        ]
        return encodeLine([
            "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": usage, "last_token_usage": usage],
            ],
        ])
    }

    private func forkRecord(_ ordinal: Int, _ type: String, _ payload: [String: Any]) -> String {
        encodeLine([
            "ordinal": ordinal,
            "timestamp": "2026-08-13T01:25:04.725Z",
            "type": type,
            "payload": payload,
        ])
    }

    private func forkTokenRecord(_ ordinal: Int, tokens: Int) -> String {
        forkRecord(ordinal, "event_msg", [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": tokens,
                    "output_tokens": 0,
                    "total_tokens": tokens,
                ],
            ],
        ])
    }

    private func encodeLine(_ object: [String: Any]) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeLines(_ lines: [String], to file: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }

    private func appendLines(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private var ledgerDirectory: URL {
        cache.appendingPathComponent("CodexTokenBarSwift/exact-usage-history-v1", isDirectory: true)
    }

    private func historyDatabase() throws -> SQLiteDatabaseDriver {
        let files = try FileManager.default.contentsOfDirectory(at: ledgerDirectory, includingPropertiesForKeys: nil)
        let url = try XCTUnwrap(files.first {
            $0.pathExtension == "sqlite" && $0.deletingPathExtension().lastPathComponent.count == 64
        })
        return SQLiteDatabaseDriver(url: url)
    }

    private func scalar(_ sql: String, in database: SQLiteDatabaseDriver) throws -> Int {
        try XCTUnwrap(database.readRows(sql) { $0.int(0) }.first ?? nil)
    }
}
