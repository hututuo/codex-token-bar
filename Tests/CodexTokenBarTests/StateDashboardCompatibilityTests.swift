import SQLite3
import XCTest
@testable import CodexTokenBar

final class StateDashboardCompatibilityTests: XCTestCase {
    private func withState(_ sql: String, body: (CodexUsageAnalyzer) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StateDashboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Explicit sqlite_home prevents a machine's external setting from
        // redirecting this fixture into a real Codex database.
        let escaped = root.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try "sqlite_home = \"\(escaped)\"\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(database)
        guard status == SQLITE_OK else { XCTFail("Fixture failed: \(message)"); return }
        let before = try Data(contentsOf: path)
        try body(CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected)))
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testLegacyMetadataAndDashboardAllKeepExistingFields() throws {
        for mask in 0..<16 {
            var sql = """
            CREATE TABLE threads(id TEXT, title TEXT, updated_at INTEGER);
            INSERT INTO threads VALUES('saved','Use @browser',200);
            INSERT INTO threads VALUES('earlier','Earlier',100);
            """
            for (bit, column, type) in [(1, "first_user_message", "TEXT"), (2, "preview", "TEXT"),
                                         (4, "reasoning_effort", "TEXT"), (8, "updated_at_ms", "INTEGER")] {
                if mask & bit != 0 { sql += "ALTER TABLE threads ADD COLUMN \(column) \(type);" }
            }
            try withState(sql) { analyzer in
                let refresh = analyzer.loadStateRefreshSnapshot()
                XCTAssertEqual(refresh.officialSummary?.totalThreads, 2, "mask \(mask)")
                XCTAssertEqual(refresh.threadInfo["saved"]?.title, "Use @browser")
                XCTAssertEqual(refresh.threadInfo["saved"]?.updatedAt?.timeIntervalSince1970, 200)
                XCTAssertEqual(refresh.metadata.plugins.first?.name, "@browser")
                XCTAssertEqual(refresh.metadata.reasoning, "未知")
                let dashboard = try analyzer.loadFromStateSQLite()
                XCTAssertEqual(dashboard.stats.totalThreads, 2)
                XCTAssertEqual(dashboard.stats.totalTokens, 0)
                XCTAssertEqual(dashboard.usagePrecision, .metadataOnly)
                XCTAssertNil(dashboard.dataUpdatedAt)
                XCTAssertEqual(analyzer.loadThreadInfo()["saved"]?.title, "Use @browser")
                XCTAssertEqual(analyzer.loadThreadMetadata().plugins.first?.name, "@browser")
            }
        }
    }

    func testMillisecondsOnlyAndBlankTitleFallbackRemainReadable() throws {
        try withState("""
            CREATE TABLE threads(id TEXT, title TEXT, first_user_message TEXT,
              preview TEXT, reasoning_effort TEXT, updated_at_ms INTEGER);
            INSERT INTO threads VALUES('fallback','',NULL,'Use @documents','high',2000000000000);
            """) { analyzer in
            let refresh = analyzer.loadStateRefreshSnapshot()
            XCTAssertEqual(refresh.threadInfo["fallback"]?.title, "Use @documents")
            XCTAssertEqual(refresh.threadInfo["fallback"]?.updatedAt?.timeIntervalSince1970, 2_000_000_000)
            XCTAssertEqual(refresh.metadata.reasoning, "高 · 1")
            XCTAssertEqual(try analyzer.loadFromStateSQLite().pluginUsage.first?.name, "@documents")
            XCTAssertEqual(analyzer.loadThreadInfo()["fallback"]?.updatedAt?.timeIntervalSince1970, 2_000_000_000)
        }
    }

    func testMissingRequiredTimestampDoesNotProduceSuccessfulMetadataSnapshot() throws {
        try withState("CREATE TABLE threads(id TEXT, title TEXT); INSERT INTO threads VALUES('a','Saved');") { analyzer in
            XCTAssertThrowsError(try analyzer.loadFromStateSQLite())
            XCTAssertNil(analyzer.loadStateRefreshSnapshot().officialSummary)
        }
    }
}
