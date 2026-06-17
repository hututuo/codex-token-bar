import XCTest
@testable import CodexTokenBar

final class LiveRateMonitorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testLogRowsFilterThreadIDWithQuotesUsingBindings() throws {
        let databaseURL = try makeDatabaseURL()
        let driver = SQLiteDatabaseDriver(url: databaseURL)
        try driver.execute("""
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY,
            thread_id TEXT,
            ts INTEGER,
            ts_nanos INTEGER,
            target TEXT,
            feedback_log_body TEXT
        );
        """)

        let quotedThreadID = "thread-' OR 1=1 --"
        try insertLog(driver: driver, id: 1, threadID: quotedThreadID, body: "websocket event: first")
        try insertLog(driver: driver, id: 2, threadID: quotedThreadID, body: "websocket event: second")
        try insertLog(driver: driver, id: 99, threadID: "other-thread", body: "websocket event: other")

        let maxID = try LiveRateMonitor.testMaxLogID(logsDB: databaseURL.path, threadID: quotedThreadID)
        let rows = try LiveRateMonitor.testLogRows(logsDB: databaseURL.path, threadID: quotedThreadID, afterID: 0)

        XCTAssertEqual(maxID, 2)
        XCTAssertEqual(rows.map(\.id), [1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.threadID == quotedThreadID })
    }

    func testRecentFingerprintSetKeepsOnlyNewestValues() {
        var fingerprints = RecentFingerprintSet(limit: 3)

        XCTAssertTrue(fingerprints.insertIfNew("a"))
        XCTAssertTrue(fingerprints.insertIfNew("b"))
        XCTAssertTrue(fingerprints.insertIfNew("c"))
        XCTAssertFalse(fingerprints.insertIfNew("b"))

        XCTAssertTrue(fingerprints.insertIfNew("d"))

        XCTAssertEqual(fingerprints.count, 3)
        XCTAssertFalse(fingerprints.contains("a"))
        XCTAssertTrue(fingerprints.contains("b"))
        XCTAssertTrue(fingerprints.contains("c"))
        XCTAssertTrue(fingerprints.contains("d"))
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRateMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("logs.sqlite")
    }

    private func insertLog(driver: SQLiteDatabaseDriver, id: Int, threadID: String, body: String) throws {
        try driver.execute(
            """
            INSERT INTO logs (id, thread_id, ts, ts_nanos, target, feedback_log_body)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int(id),
                .text(threadID),
                .int(1_000 + id),
                .int(0),
                .text("codex_api::endpoint::responses_websocket"),
                .text(body)
            ]
        )
    }
}
