import XCTest
@testable import CodexTokenBar

final class TaskCompletionScannerTests: XCTestCase {
    func testPartialCompletionTailWaitsForNewlineThenParsesExactlyOnce() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionPartialTail")
        defer { try? FileManager.default.removeItem(at: sessionsRoot) }
        let file = sessionsRoot.appendingPathComponent("partial.jsonl")
        let metadata = sessionMetaLine(id: "partial-session")
        let completion = eventLine(timestamp: "2026-06-24T13:00:00.000Z", payload: [
            "type": "task_complete",
            "turn_id": "turn-1",
            "last_agent_message": "完成"
        ])
        let splitIndex = completion.index(completion.startIndex, offsetBy: completion.count / 2)
        let completionPrefix = String(completion[..<splitIndex])
        let completionSuffix = String(completion[splitIndex...])
        try (metadata + "\n" + completionPrefix).write(to: file, atomically: true, encoding: .utf8)

        let first = scan(sessionsRoot: sessionsRoot)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(try onlyState(in: first).offset, byteCount(metadata + "\n"))

        try append(completionSuffix + "\n", to: file)
        let second = scan(sessionsRoot: sessionsRoot, previousStates: first.states)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.threadID, "partial-session")
        XCTAssertEqual(second.events.first?.body, "耗时 0秒 · 完成")
        XCTAssertEqual(try onlyState(in: second).offset, try fileSize(file))

        let third = scan(sessionsRoot: sessionsRoot, previousStates: second.states)
        XCTAssertTrue(third.events.isEmpty)
        XCTAssertEqual(try onlyState(in: third).offset, try fileSize(file))
    }

    func testCompleteLinesAdvanceBeforePartialTailAndPreserveTurnState() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionCompleteLinesPartial")
        defer { try? FileManager.default.removeItem(at: sessionsRoot) }
        let file = sessionsRoot.appendingPathComponent("multiple.jsonl")
        let metadata = sessionMetaLine(id: "multiple-session", cwd: "/tmp/project")
        let started = eventLine(timestamp: nil, payload: [
            "type": "task_started",
            "turn_id": "turn-1",
            "started_at": 1_782_306_000
        ])
        let userMessage = eventLine(timestamp: nil, payload: [
            "type": "user_message",
            "message": "保留这段任务标题"
        ])
        let completion = eventLine(timestamp: nil, payload: [
            "type": "task_complete",
            "turn_id": "turn-1",
            "completed_at": 1_782_306_003,
            "last_agent_message": "完成"
        ])
        let splitIndex = completion.index(completion.startIndex, offsetBy: completion.count / 2)
        let completePrefix = [metadata, started, userMessage].joined(separator: "\n") + "\n"
        try (completePrefix + completion[..<splitIndex]).write(to: file, atomically: true, encoding: .utf8)

        let first = scan(sessionsRoot: sessionsRoot)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(try onlyState(in: first).offset, byteCount(completePrefix))
        XCTAssertEqual(try onlyState(in: first).activeTurns["turn-1"]?.lastUserText, "保留这段任务标题")

        try append(String(completion[splitIndex...]) + "\n", to: file)
        let second = scan(sessionsRoot: sessionsRoot, previousStates: first.states)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.title, "保留这段任务标题")
        XCTAssertEqual(second.events.first?.body, "耗时 3秒 · 完成")
    }

    func testSmallerReplacementResetsOffsetAndParsesFromBeginning() throws {
        let sessionsRoot = try makeSessionsRoot(named: "TaskCompletionReplacement")
        defer { try? FileManager.default.removeItem(at: sessionsRoot) }
        let file = sessionsRoot.appendingPathComponent("replacement.jsonl")
        let oldCompletion = eventLine(timestamp: nil, payload: [
            "type": "task_complete",
            "turn_id": "old-turn",
            "completed_at": 1_782_306_000,
            "last_agent_message": String(repeating: "旧", count: 300)
        ])
        try [sessionMetaLine(id: "old-session"), oldCompletion]
            .joined(separator: "\n")
            .appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let first = scan(sessionsRoot: sessionsRoot)
        XCTAssertEqual(first.events.first?.threadID, "old-session")
        let oldOffset = try onlyState(in: first).offset

        let replacement = [
            sessionMetaLine(id: "new-session"),
            eventLine(timestamp: nil, payload: [
                "type": "task_complete",
                "turn_id": "new-turn",
                "completed_at": 1_782_306_001
            ])
        ].joined(separator: "\n").appending("\n")
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertLessThan(try fileSize(file), oldOffset)

        let second = scan(sessionsRoot: sessionsRoot, previousStates: first.states)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.threadID, "new-session")
        XCTAssertEqual(try onlyState(in: second).offset, try fileSize(file))
    }

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

    private func scan(
        sessionsRoot: URL,
        previousStates: [String: TaskCompletionFileState] = [:]
    ) -> TaskCompletionScanResult {
        TaskCompletionScanner.scan(
            sessionsRoot: sessionsRoot,
            previousStates: previousStates,
            seedMode: false,
            seedCutoff: Date(timeIntervalSince1970: 0)
        )
    }

    private func append(_ content: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
    }

    private func byteCount(_ content: String) -> UInt64 {
        UInt64(Data(content.utf8).count)
    }

    private func fileSize(_ file: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
    }

    private func onlyState(in result: TaskCompletionScanResult) throws -> TaskCompletionFileState {
        XCTAssertEqual(result.states.count, 1)
        return try XCTUnwrap(result.states.values.first)
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
