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

    func testPollReadsRolloutJsonlWhenSqliteStreamHasNoNewRows() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSourceURL = projectRoot.appendingPathComponent("Sources/CodexTokenBar/LiveRateMonitor.swift")
        let monitorSource = try String(contentsOf: monitorSourceURL, encoding: .utf8)

        XCTAssertTrue(monitorSource.contains("await readRolloutUpdates(now:"))
    }

    func testRolloutParserDoesNotCountAgentMessageDuplicateAsInstantRollingOutput() {
        let text = String(repeating: "streamed answer ", count: 200)
        let lines = [
            rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: text),
            rolloutAssistantResponseItemLine(timestamp: "2026-06-24T13:00:00.010Z", id: "msg-1", text: text)
        ]

        let events = LiveRateMonitor.rolloutEvents(fromLines: lines)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, text)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertEqual(events.first?.rollingOnly, false)
    }

    func testRolloutParserCountsCompleteAgentMessageWhileAssistantItemIsStillBuffered() {
        let text = "可以，先按这个修。"
        let events = LiveRateMonitor.rolloutEvents(fromLines: [
            rolloutAgentMessageLine(timestamp: "2026-06-24T13:00:00.000Z", message: text)
        ])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, text)
        XCTAssertEqual(events.first?.category, .visibleText)
        XCTAssertEqual(events.first?.rollingOnly, false)
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

    private func rolloutAgentMessageLine(timestamp: String, message: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "message": message
            ]
        ])
    }

    private func rolloutAssistantResponseItemLine(timestamp: String, id: String, text: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": id,
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": text
                    ]
                ]
            ]
        ])
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
