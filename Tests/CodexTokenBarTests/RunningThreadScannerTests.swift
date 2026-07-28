import XCTest
@testable import CodexTokenBar

final class RunningThreadScannerTests: XCTestCase {
    func testCountsMainAndSubagentWithoutTreatingForkMetadataAsSubagent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try writeSession(
            to: fixture.sessions.appendingPathComponent("main.jsonl"),
            id: "main-thread",
            metadata: "\"thread_source\":\"user\",\"source\":{\"forked_from_id\":\"parent\"}",
            events: [event("task_started", turnID: "main-turn")]
        )
        try writeSession(
            to: fixture.sessions.appendingPathComponent("subagent.jsonl"),
            id: "subagent-thread",
            metadata: "\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"main-thread\"}}}",
            events: [event("task_started", turnID: "sub-turn")]
        )
        try writeSession(
            to: fixture.sessions.appendingPathComponent("legacy-main.jsonl"),
            id: "legacy-main-thread",
            metadata: "\"source\":\"vscode\"",
            events: [event("task_started", turnID: "legacy-turn")]
        )
        try writeSession(
            to: fixture.sessions.appendingPathComponent("side-chat.jsonl"),
            id: "side-chat-thread",
            metadata: "\"thread_source\":\"ccpocket_side_chat\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "side-chat-turn")]
        )
        try writeSession(
            to: fixture.sessions.appendingPathComponent("not-subagent-note.jsonl"),
            id: "not-subagent-note",
            metadata: "\"source\":{\"note\":\"not_subagent\"}",
            events: [event("task_started", turnID: "not-subagent-note-turn")]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 5)
        XCTAssertEqual(result.summary.main, 4)
        XCTAssertEqual(result.summary.subagents, 1)
        XCTAssertEqual(result.summary.freshness, .fresh)
    }

    func testLatestLifecycleWinsAcrossForkCopiedStarts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try writeSession(
            to: fixture.sessions.appendingPathComponent("forked-child.jsonl"),
            id: "child-thread",
            metadata: "\"thread_source\":\"subagent\",\"source\":{\"subagent\":{}}",
            events: [
                event("task_started", turnID: "copied-parent-turn"),
                event(
                    "task_started",
                    turnID: "child-turn",
                    timestamp: "2026-07-28T00:30:00.000Z"
                ),
                event(
                    "task_complete",
                    turnID: "child-turn",
                    timestamp: "2026-07-28T01:00:00.000Z"
                ),
            ]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 0)
        XCTAssertEqual(result.states.values.first?.lifecycle, .idle)
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            result.states.values.first?.lifecycleAt,
            timestampFormatter.date(from: "2026-07-28T01:00:00.000Z")
        )
    }

    func testAbortAndRollbackAreTerminalLifecycleEvents() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        for (index, terminal) in ["turn_aborted", "thread_rolled_back"].enumerated() {
            try writeSession(
                to: fixture.sessions.appendingPathComponent("\(terminal).jsonl"),
                id: "terminal-\(index)",
                metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
                events: [
                    event("task_started", turnID: "turn-\(index)"),
                    event(terminal, turnID: "turn-\(index)"),
                ]
            )
        }

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 0)
        XCTAssertEqual(Set(result.states.values.map(\.lifecycle)), [.idle])
    }

    func testInitialScanFindsLifecycleBeyondSixteenMiBWithoutTotalByteCap() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("large-running.jsonl")
        try writeSession(
            to: file,
            id: "large-running",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "long-turn")]
        )

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let padding = String(
            repeating: "x",
            count: 4_000
        )
        let filler = Data(
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"\(padding)\"}}\n".utf8
        )
        for _ in 0..<4_400 {
            try handle.write(contentsOf: filler)
        }
        try handle.close()

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0,
            16 * 1024 * 1024
        )
        XCTAssertEqual(result.summary.main, 1)
        XCTAssertEqual(result.summary.total, 1)
    }

    func testOversizedTaskCompleteLineStillClosesRunningThread() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let oversizedCompletion = """
        {"type":"event_msg","timestamp":"2026-07-28T01:00:00.000Z","payload":{"type":"task_complete","turn_id":"large-complete","last_agent_message":"\(String(repeating: "z", count: 3 * 1024 * 1024))"}}
        """
        try writeSession(
            to: fixture.sessions.appendingPathComponent("oversized-complete.jsonl"),
            id: "oversized-complete",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                event("task_started", turnID: "large-complete"),
                oversizedCompletion,
            ]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 0)
        XCTAssertEqual(result.states.values.first?.lifecycle, .idle)
    }

    func testPartialTailDoesNotAdvanceUntilNewlineArrives() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("partial.jsonl")
        try writeSession(
            to: file,
            id: "partial-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "partial-turn")]
        )
        let partialCompletion = event("task_complete", turnID: "partial-turn")
        try append(partialCompletion, to: file)

        let first = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(first.summary.main, 1)

        try append("\n", to: file)
        let second = try XCTUnwrap(scan(fixture, previousStates: first.states))
        XCTAssertEqual(second.summary.total, 0)
        XCTAssertGreaterThan(
            try XCTUnwrap(second.states.values.first?.offset),
            try XCTUnwrap(first.states.values.first?.offset)
        )
    }

    func testSameInodeRewriteIsDetectedByBoundarySignature() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("rewrite.jsonl")
        try writeSession(
            to: file,
            id: "rewrite-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                event("task_started", turnID: "old-turn"),
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"old-padding\"}}",
            ]
        )
        let first = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(first.summary.main, 1)

        let replacement = sessionText(
            id: "rewrite-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                event("task_started", turnID: "new-turn"),
                event("turn_aborted", turnID: "new-turn"),
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(String(repeating: "new", count: 500))\"}}",
            ]
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()

        let second = try XCTUnwrap(scan(fixture, previousStates: first.states))
        XCTAssertEqual(second.summary.total, 0)
        XCTAssertEqual(second.states.values.first?.lifecycle, .idle)
    }

    func testSameSizeSameTailRewriteDoesNotReuseOldLifecycle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("same-size-rewrite.jsonl")
        let originalFiller = String(repeating: "x", count: 500)
        try writeSession(
            to: file,
            id: "same-size-rewrite",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                event("task_started", turnID: "same-size-turn"),
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(originalFiller)\"}}",
            ]
        )
        let first = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(first.summary.main, 1)

        let replacementFiller = String(repeating: "x", count: 499)
        let replacement = sessionText(
            id: "same-size-rewrite",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                event("task_complete", turnID: "same-size-turn"),
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(replacementFiller)\"}}",
            ]
        )
        let originalSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                .uint64Value
        )
        XCTAssertEqual(UInt64(replacement.utf8.count), originalSize)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(1)],
            ofItemAtPath: file.path
        )

        let second = try XCTUnwrap(scan(fixture, previousStates: first.states))
        XCTAssertEqual(second.summary.total, 0)
        XCTAssertEqual(second.states.values.first?.lifecycle, .idle)
    }

    func testDatabaseCandidateAcceptsRelativeRolloutPathInsideSelectedHome() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("relative.jsonl")
        try writeSession(
            to: file,
            id: "relative-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "relative-turn")]
        )
        let database = SQLiteDatabaseDriver(url: fixture.source.stateDatabase)
        try database.execute(
            """
            CREATE TABLE threads (
                rollout_path TEXT,
                updated_at INTEGER,
                archived INTEGER
            )
            """
        )
        try database.execute(
            """
            INSERT INTO threads (rollout_path, updated_at, archived)
            VALUES (?1, ?2, 0)
            """,
            bindings: [
                .text("sessions/relative.jsonl"),
                .int64(Int64(fixture.now.timeIntervalSince1970)),
            ]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.main, 1)
        XCTAssertEqual(result.summary.total, 1)
    }

    func testColdScanIncludesRecentSessionMissingFromNonemptyDatabase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let registered = fixture.sessions.appendingPathComponent("registered-idle.jsonl")
        let unregistered = fixture.sessions.appendingPathComponent("unregistered-running.jsonl")
        try writeSession(
            to: registered,
            id: "registered-idle",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_complete", turnID: "registered-turn")]
        )
        try writeSession(
            to: unregistered,
            id: "unregistered-running",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "unregistered-turn")]
        )

        let database = SQLiteDatabaseDriver(url: fixture.source.stateDatabase)
        try database.execute(
            """
            CREATE TABLE threads (
                rollout_path TEXT,
                updated_at INTEGER,
                archived INTEGER
            )
            """
        )
        try database.execute(
            """
            INSERT INTO threads (rollout_path, updated_at, archived)
            VALUES (?1, ?2, 0)
            """,
            bindings: [
                .text(registered.path),
                .int64(Int64(fixture.now.timeIntervalSince1970)),
            ]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.main, 1)
        XCTAssertEqual(result.states.count, 2)
    }

    func testUnmatchedStartExpiresAfterLivenessLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.sessions.appendingPathComponent("orphan.jsonl")
        try writeSession(
            to: file,
            id: "orphan-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [event("task_started", turnID: "orphan-turn")]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: file.path
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 0)
        XCTAssertTrue(result.states.isEmpty)
    }

    func testDuplicateSessionIDCountsOnlyNewestLifecycle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writeSession(
            to: fixture.sessions.appendingPathComponent("older-copy.jsonl"),
            id: "duplicate-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                """
                {"type":"event_msg","timestamp":"2026-07-28T02:00:00.000Z","payload":{"type":"task_started","turn_id":"old","started_at":1785204000}}
                """,
            ]
        )
        try writeSession(
            to: fixture.sessions.appendingPathComponent("newer-copy.jsonl"),
            id: "duplicate-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                """
                {"type":"event_msg","timestamp":"2026-07-28T03:00:00.000Z","payload":{"type":"task_complete","turn_id":"new","started_at":1785200400,"completed_at":1785207600}}
                """,
            ]
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.total, 0)
        XCTAssertEqual(result.states.count, 2)
    }

    func testDuplicateSessionWithoutLifecycleCannotHideKnownRunningState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let known = fixture.sessions.appendingPathComponent("known-running.jsonl")
        let unknown = fixture.sessions.appendingPathComponent("newer-without-lifecycle.jsonl")
        try writeSession(
            to: known,
            id: "duplicate-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                """
                {"type":"event_msg","timestamp":"2026-07-28T02:00:00.000Z","payload":{"type":"task_started","turn_id":"known"}}
                """,
            ]
        )
        try writeSession(
            to: unknown,
            id: "duplicate-thread",
            metadata: "\"thread_source\":\"user\",\"source\":\"vscode\"",
            events: [
                """
                {"type":"response_item","payload":{"type":"message","text":"no lifecycle"}}
                """,
            ]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(60)],
            ofItemAtPath: unknown.path
        )

        let result = try XCTUnwrap(scan(fixture))
        XCTAssertEqual(result.summary.main, 1)
        XCTAssertEqual(result.summary.total, 1)
    }

    func testPresentationDoesNotRenderLoadingOrUnavailableAsZero() {
        XCTAssertEqual(
            RunningThreadPresentation(summary: .loading).displayText,
            "运行 -- · 主 -- · 子 --"
        )
        XCTAssertEqual(
            RunningThreadPresentation(summary: .unavailable).displayText,
            "运行 -- · 主 -- · 子 --"
        )
        XCTAssertEqual(
            RunningThreadPresentation(
                summary: RunningThreadSummary(
                    main: 2,
                    subagents: 3,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    freshness: .fresh
                )
            ).displayText,
            "运行 5 · 主 2 · 子 3"
        )
    }

    private struct Fixture {
        let home: URL
        let sessions: URL
        let source: CodexDataSource
        let now: Date
    }

    private func makeFixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunningThreadScanner-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return Fixture(
            home: home,
            sessions: sessions,
            source: CodexDataSource(codexHome: home, origin: .userSelected),
            now: Date()
        )
    }

    private func scan(
        _ fixture: Fixture,
        previousStates: [String: RunningThreadFileState] = [:]
    ) -> RunningThreadScanResult? {
        RunningThreadScanner.scan(
            dataSource: fixture.source,
            previousStates: previousStates,
            now: fixture.now
        )
    }

    private func writeSession(
        to file: URL,
        id: String,
        metadata: String,
        events: [String]
    ) throws {
        try sessionText(id: id, metadata: metadata, events: events)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    private func sessionText(
        id: String,
        metadata: String,
        events: [String]
    ) -> String {
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\(metadata)}}"
        return ([meta] + events).joined(separator: "\n") + "\n"
    }

    private func event(
        _ type: String,
        turnID: String,
        timestamp: String = "2026-07-28T00:00:00.000Z"
    ) -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turnID)\"}}"
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}
