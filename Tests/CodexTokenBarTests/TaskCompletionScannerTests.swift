import XCTest
@testable import CodexTokenBar

final class TaskCompletionScannerTests: XCTestCase {
    func testMissingOrMalformedTimestampCompletionRowsDoNotProduceEvents() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionBadTimestamp")
        try writeSession(
            under: sessionsRoot,
            named: "bad",
            lines: [
                sessionMetaLine(id: "bad-session"),
                eventLine(timestamp: nil, payload: ["type": "task_complete", "turn_id": "missing"]),
                eventLine(timestamp: "not-a-date", payload: ["type": "task_complete", "turn_id": "malformed"])
            ]
        )

        let result = TaskCompletionScanner.scan(
            sessionsRoot: sessionsRoot,
            previousStates: [:],
            seedMode: false,
            seedCutoff: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.events.count, 0)
    }

    func testValidISOTimestampCompletionRowProducesEvent() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionISO")
        try writeSession(
            under: sessionsRoot,
            named: "valid-iso",
            lines: [
                sessionMetaLine(id: "iso-session", cwd: "/tmp/project"),
                eventLine(timestamp: "2026-06-24T13:00:00.000Z", payload: [
                    "type": "task_complete",
                    "turn_id": "turn-1",
                    "last_agent_message": "完成"
                ])
            ]
        )

        let result = TaskCompletionScanner.scan(
            sessionsRoot: sessionsRoot,
            previousStates: [:],
            seedMode: false,
            seedCutoff: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.threadID, "iso-session")
        XCTAssertEqual(result.events.first?.body, "耗时 0秒 · 完成")
    }

    func testPayloadNumericCompletionTimeWorksWhenTopLevelTimestampIsMalformed() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionNumeric")
        try writeSession(
            under: sessionsRoot,
            named: "valid-numeric",
            lines: [
                sessionMetaLine(id: "numeric-session"),
                eventLine(timestamp: "not-a-date", payload: [
                    "type": "task_complete",
                    "turn_id": "turn-1",
                    "completed_at": 1_782_306_000,
                    "duration_ms": 2_500
                ])
            ]
        )

        let result = TaskCompletionScanner.scan(
            sessionsRoot: sessionsRoot,
            previousStates: [:],
            seedMode: false,
            seedCutoff: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.body, "耗时 3秒 · 已完成回复")
    }

    private func makeSessionsRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(under root: URL, named name: String, lines: [String]) throws {
        let file = root.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func sessionMetaLine(id: String, cwd: String = "/tmp") -> String {
        jsonLine(type: "session_meta", timestamp: "2026-06-24T12:59:00.000Z", payload: [
            "id": id,
            "cwd": cwd
        ])
    }

    private func eventLine(timestamp: String?, payload: [String: Any]) -> String {
        jsonLine(type: "event_msg", timestamp: timestamp, payload: payload)
    }

    private func jsonLine(type: String, timestamp: String?, payload: [String: Any]) -> String {
        var object: [String: Any] = [
            "type": type,
            "payload": payload
        ]
        if let timestamp {
            object["timestamp"] = timestamp
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
