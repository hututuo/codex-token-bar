import SQLite3
import XCTest
@testable import CodexTokenBar

final class LiveRateStateCompatibilityTests: XCTestCase {
    private func withState(_ sql: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state_5.sqlite")
        defer {
            CodexStateDatabaseReadPool.shared.close(url: url)
            try? FileManager.default.removeItem(at: root)
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(database)
        guard status == SQLITE_OK else {
            XCTFail("Fixture failed: \(message)")
            return
        }
        let before = try Data(contentsOf: url)
        try body(url)
        XCTAssertEqual(try Data(contentsOf: url), before, "A metadata read must not migrate the client database")
    }

    // Upstream added these four fields independently after the original schema.
    func testLegacyOptionalColumnCombinationsStayReadableAndUnchanged() throws {
        for mask in 0..<16 {
            var sql = """
            CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, rollout_path TEXT,
              updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES('recent','Recent','/recent',200,0);
            INSERT INTO threads VALUES('older','Older','/older',100,0);
            INSERT INTO threads VALUES('archived','Hidden','/hidden',300,1);
            """
            for (bit, column, type) in [(1, "first_user_message", "TEXT"), (2, "name", "TEXT"),
                                         (4, "updated_at_ms", "INTEGER"), (8, "thread_source", "TEXT")] {
                if mask & bit != 0 { sql += "ALTER TABLE threads ADD COLUMN \(column) \(type);" }
            }
            try withState(sql) { url in
                let rows = try LiveRateMonitor.recentThreads(stateDB: url.path)
                XCTAssertEqual(rows.map(\.id), ["recent", "older"], "mask \(mask)")
                let recent = try XCTUnwrap(rows.first { $0.id == "recent" })
                XCTAssertEqual(recent.title, "Recent")
                XCTAssertEqual(recent.updatedAtMS, 200_000)
                XCTAssertEqual(recent.threadSource, "user")
            }
        }
    }

    func testNullableFieldsPreserveExplicitNamePromptSuppressionAndSubagents() throws {
        try withState("""
            CREATE TABLE threads(id TEXT, title TEXT, name TEXT, first_user_message TEXT,
              rollout_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, archived INTEGER, thread_source TEXT);
            INSERT INTO threads VALUES('named','prompt','Explicit','prompt','/named',200,NULL,NULL,NULL);
            INSERT INTO threads VALUES('prompt','prompt',NULL,'prompt','/prompt',100,NULL,0,'user');
            INSERT INTO threads VALUES('agent',NULL,NULL,NULL,'/agent',300,NULL,0,'subagent');
            INSERT INTO threads VALUES('archived','Hidden',NULL,NULL,'/hidden',400,NULL,1,'user');
            """) { url in
            let rows = try LiveRateMonitor.recentThreads(stateDB: url.path)
            XCTAssertEqual(rows.map(\.id), ["agent", "named", "prompt"])
            XCTAssertEqual(rows.first { $0.id == "agent" }?.threadSource, "subagent")
            XCTAssertEqual(rows.first { $0.id == "agent" }?.title, "")
            XCTAssertEqual(rows.first { $0.id == "named" }?.title, "Explicit")
            XCTAssertEqual(rows.first { $0.id == "prompt" }?.title, "")
        }
    }

    func testTimestampShapesNormalizeAndOrderWithoutMissingOptionalColumns() throws {
        for (columns, recent, older) in [
            ("updated_at INTEGER", "2000000000", "1000000000"),
            ("updated_at INTEGER", "2000000000000", "1000000000000"),
            ("updated_at_ms INTEGER", "2000000000000", "1000000000000"),
            ("updated_at INTEGER, updated_at_ms INTEGER", "1,2000000000000", "1000000000,NULL")
        ] {
            try withState("""
                CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, \(columns));
                INSERT INTO threads VALUES('recent','Recent','/recent',\(recent));
                INSERT INTO threads VALUES('older','Older','/older',\(older));
                """) { url in
                let rows = try LiveRateMonitor.recentThreads(stateDB: url.path)
                XCTAssertEqual(rows.map(\.id), ["recent", "older"])
                XCTAssertEqual(rows.first { $0.id == "recent" }?.updatedAtMS, 2_000_000_000_000)
                XCTAssertEqual(rows.first { $0.id == "older" }?.updatedAtMS, 1_000_000_000_000)
            }
        }
    }

    func testMissingRequiredTimestampRemainsAnError() throws {
        try withState("CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT);") { url in
            XCTAssertThrowsError(try LiveRateMonitor.recentThreads(stateDB: url.path))
        }
    }
}
