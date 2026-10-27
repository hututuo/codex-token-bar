import Foundation
import SQLite3
import XCTest
@testable import CodexTokenBar

final class MultiClientUsageParserTests: XCTestCase {
    func testDeepSeekNativeSessionHeaderNamesLaterLines() throws {
        let data = Data((#"{"type":"session","id":"native-session","version":4}"# + "\n" + #"{"type":"assistant/message","seq":2,"time":1797000000000,"data":{"usage":{"inputTokens":10,"outputTokens":2}}}"# + "\n").utf8)
        let events = try MultiClientUsageParsers.parse(data: data, client: .deepseek, sessionHint: "directory")
        XCTAssertEqual(events.first?.sessionID, "native-session")
    }

    func testClaudeStreamingUpdatesMergeCountsAndKeepReasoningAsOutputSubset() throws {
        let first = claudeLine(
            session: "claude-session",
            entrypoint: "cli",
            id: "message-1",
            timestamp: "2026-10-20T10:00:00.000Z",
            usage: [
                "input_tokens": 2,
                "cache_creation_input_tokens": 1_000,
                "cache_read_input_tokens": 20_000,
                "output_tokens": 150,
                "output_tokens_details": ["thinking_tokens": 60],
            ]
        )
        let update = claudeLine(
            session: "claude-session",
            entrypoint: "cli",
            id: "message-1",
            timestamp: "2026-10-20T10:00:02.000Z",
            usage: [
                "input_tokens": 2,
                "cache_creation_input_tokens": 1_000,
                "cache_read_input_tokens": 20_000,
                "output_tokens": 300,
                "output_tokens_details": ["thinking_tokens": 60],
            ]
        )

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([first, update]), client: .claudeCode, sessionHint: "claude-file"
        )

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "claude-session")
        XCTAssertEqual(event.model, "claude-opus")
        XCTAssertEqual(event.inputTokens, 21_002)
        XCTAssertEqual(event.outputTokens, 300)
        XCTAssertEqual(event.reasoningTokens, 60)
        XCTAssertEqual(event.cacheReadTokens, 20_000)
        XCTAssertEqual(event.cacheWriteTokens, 1_000)
        XCTAssertEqual(event.quality, "recorded")
    }

    func testClaudeDesktopLocalTranscriptIsClassifiedByItsEntryPoint() throws {
        let desktopLine = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-message",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 11, "output_tokens": 7]
        )
        let data = jsonl([desktopLine])

        XCTAssertTrue(try MultiClientUsageParsers.parse(data: data, client: .claudeCode, sessionHint: "file").isEmpty)
        let desktop = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .claudeDesktop, sessionHint: "file").first
        )
        XCTAssertEqual(desktop.client, .claudeDesktop)
        XCTAssertEqual(desktop.inputTokens, 11)
        XCTAssertEqual(desktop.outputTokens, 7)
    }

    func testClaudeClassificationFromEarlierEntryPointAppliesToLaterRecordsWithoutIt() throws {
        let desktopHeader = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-first",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 1, "output_tokens": 1]
        )
        var laterDesktop = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-later",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 7, "output_tokens": 4]
        )
        laterDesktop.removeValue(forKey: "entrypoint")

        let desktopEvents = try MultiClientUsageParsers.parse(
            data: jsonl([desktopHeader, laterDesktop]), client: .claudeDesktop, sessionHint: "desktop-file"
        )
        XCTAssertEqual(desktopEvents.count, 2)
        XCTAssertEqual(desktopEvents.last?.inputTokens, 7)

        let codeEvents = try MultiClientUsageParsers.parse(
            data: jsonl([laterDesktop]), client: .claudeCode, sessionHint: "code-file"
        )
        XCTAssertEqual(codeEvents.count, 1)
    }

    func testSyntheticClaudeAssistantDoesNotCountAsProviderUsage() throws {
        let line = #"{"type":"assistant","timestamp":"2026-10-25T01:00:00Z","sessionId":"s","message":{"id":"local-status","model":"<synthetic>","usage":{"input_tokens":100,"output_tokens":20}}}"# + "\n"
        XCTAssertTrue(try MultiClientUsageParsers.parse(data: Data(line.utf8), client: .claudeCode, sessionHint: "s").isEmpty)
    }

    func testDeepSeekHarnessUnwrapsEventsAndAddsCacheFieldsToTotalInput() throws {
        let first = deepSeekRecord(sequence: 9, output: 5, cacheRead: 4, cacheWrite: 2, timestamp: 1_797_000_000_000)
        let update = deepSeekRecord(sequence: 9, output: 12, cacheRead: 4, cacheWrite: 2, timestamp: 1_797_000_001_000)

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([first, update]), client: .deepseek, sessionHint: "dsh-session"
        )

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "dsh-session")
        XCTAssertEqual(event.model, "deepseek-v4")
        XCTAssertEqual(event.inputTokens, 106)
        XCTAssertEqual(event.outputTokens, 12)
        XCTAssertEqual(event.cacheReadTokens, 4)
        XCTAssertEqual(event.cacheWriteTokens, 2)
        XCTAssertNil(event.reasoningTokens)
    }

    func testGeminiDocumentUsesInputAndToolCountsAndAddsThoughtsOnce() throws {
        let document: [String: Any] = [
            "sessionId": "gemini-native-session",
            "messages": [
                geminiMessage(id: "gemini-message", timestamp: "2026-10-20T10:00:00Z", input: 10, output: 5, cached: 4, thoughts: 2, tool: 3),
                geminiMessage(id: "gemini-message", timestamp: "2026-10-20T10:00:02Z", input: 10, output: 9, cached: 5, thoughts: 1, tool: 3),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])

        let event = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .gemini, sessionHint: "gemini-file").first
        )

        XCTAssertEqual(event.sessionID, "gemini-native-session")
        XCTAssertEqual(event.inputTokens, 13)
        XCTAssertEqual(event.cacheReadTokens, 5)
        XCTAssertEqual(event.outputTokens, 10)
        XCTAssertEqual(event.reasoningTokens, 2)
    }

    func testOpenCodeJSONAddsCacheAndReasoningFieldsAndMergesStreamingRows() throws {
        let first = openCodeMessage(id: "opencode-message", session: "opencode-session", streamed: 1_797_000_000_000, input: 10, output: 20, reasoning: 5, cacheRead: 4, cacheWrite: 2)
        let update = openCodeMessage(id: "opencode-message", session: "opencode-session", streamed: 1_797_000_001_000, input: 10, output: 25, reasoning: 6, cacheRead: 4, cacheWrite: 2)
        let data = try JSONSerialization.data(withJSONObject: [first, update], options: [.sortedKeys])

        let events = try MultiClientUsageParsers.parse(data: data, client: .opencode, sessionHint: "file")
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "opencode-session")
        XCTAssertEqual(event.model, "gpt-test")
        XCTAssertEqual(event.inputTokens, 16)
        XCTAssertEqual(event.outputTokens, 31)
        XCTAssertEqual(event.reasoningTokens, 6)
        XCTAssertEqual(event.cacheReadTokens, 4)
        XCTAssertEqual(event.cacheWriteTokens, 2)
    }

    func testOpenCodeSQLitePagesThroughCompletedRowsAndNormalizesUsage() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createOpenCodeFixture(at: databaseURL)

        let first = try MultiClientUsageParsers.readOpenCodeDatabase(url: databaseURL, limit: 1)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        let second = try MultiClientUsageParsers.readOpenCodeDatabase(
            url: databaseURL, after: firstCursor, limit: 1
        )
        let event = try XCTUnwrap(first.events.first)

        XCTAssertFalse(first.isComplete)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.events.count, 0) // The next database row is still in flight.
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(event.client, .opencode)
        XCTAssertEqual(event.sessionID, "session-a")
        XCTAssertEqual(event.inputTokens, 20)
        XCTAssertEqual(event.outputTokens, 13)
        XCTAssertEqual(event.reasoningTokens, 3)
        XCTAssertEqual(
            first.events,
            try MultiClientUsageParsers.readOpenCodeDatabase(url: databaseURL, limit: 1).events
        )
    }

    func testOpenCodeLegacyStorageMessageJSONUsesCompletedUsage() throws {
        let record: [String: Any] = [
            "id": "legacy-message",
            "sessionID": "legacy-session",
            "role": "assistant",
            "time": ["created": 1_797_000_000_000, "completed": 1_797_000_001_000],
            "modelID": "legacy-model",
            "tokens": [
                "input": 10,
                "output": 20,
                "reasoning": 5,
                "cache": ["read": 4, "write": 2],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])

        let event = try XCTUnwrap(
            MultiClientUsageParsers.parse(data: data, client: .opencode, sessionHint: "legacy-file").first
        )
        XCTAssertEqual(event.sessionID, "legacy-session")
        XCTAssertEqual(event.model, "legacy-model")
        XCTAssertEqual(event.inputTokens, 16)
        XCTAssertEqual(event.outputTokens, 25)
    }

    func testInvalidCountsAreSkippedButMissingAndNullCountsStayUnknownOrZero() throws {
        let invalid = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: "invalid",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": "4", "output_tokens": 2]
        )
        let partial = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: "partial",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 4, "output_tokens": NSNull(), "cache_read_input_tokens": NSNull()]
        )

        let events = try MultiClientUsageParsers.parse(
            data: jsonl([invalid, partial]), client: .claudeCode, sessionHint: "file"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].inputTokens, 4)
        XCTAssertEqual(events[0].outputTokens, 0)
        XCTAssertNil(events[0].cacheReadTokens)
    }

    func testPartialJSONLTailIsIgnoredAndMetadataFallbackIsMarked() throws {
        let valid = claudeLine(
            session: "session",
            entrypoint: "cli",
            id: nil,
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 2, "output_tokens": 3]
        )
        var data = jsonl([valid])
        data.append(Data("{\"type\":\"assistant\",\"message\":{\"usage\":".utf8))

        let events = try MultiClientUsageParsers.parse(data: data, client: .claudeCode, sessionHint: "session-file")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.quality, "fallback_identity")
        XCTAssertFalse(event.eventID.contains("session-file"))
    }

    func testDiscoveryUsesClientSpecificLocalRootsAndFileShapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let claude = home.appendingPathComponent(".claude/projects/project/session.jsonl")
        let claudeDesktop = home.appendingPathComponent(".claude/projects/project/desktop-session.jsonl")
        let dsh = home.appendingPathComponent(".dsh/sessions/session/session.v4.jsonl")
        let invalidDsh = home.appendingPathComponent(".dsh/sessions/session/session.jsonl")
        let gemini = home.appendingPathComponent(".gemini/tmp/project/chats/session.json")
        let geminiSubagent = home.appendingPathComponent(".gemini/tmp/project/chats/agent/session.jsonl")
        let invalidGemini = home.appendingPathComponent(".gemini/tmp/project/logs/session.jsonl")
        let opencode = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let opencodeLegacy = home.appendingPathComponent(
            ".local/share/opencode/storage/message/session-a/message-a.json"
        )
        for file in [
            claude, claudeDesktop, dsh, invalidDsh, gemini, geminiSubagent, invalidGemini, opencode, opencodeLegacy,
        ] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: file)
        }
        try jsonl([claudeLine(
            session: "code-session",
            entrypoint: "cli",
            id: "code-message",
            timestamp: "2026-10-20T10:00:00Z",
            usage: ["input_tokens": 3, "output_tokens": 1]
        )]).write(to: claude)
        var desktopEntrypoint = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: nil,
            timestamp: "2026-10-20T10:00:00Z",
            usage: [:]
        )
        desktopEntrypoint["type"] = "user"
        var desktopMessage = claudeLine(
            session: "desktop-session",
            entrypoint: "claude-desktop-3p",
            id: "desktop-message",
            timestamp: "2026-10-20T10:00:01Z",
            usage: ["input_tokens": 5, "output_tokens": 2]
        )
        desktopMessage.removeValue(forKey: "entrypoint")
        try jsonl([desktopEntrypoint, desktopMessage]).write(to: claudeDesktop)

        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .claudeCode, home: home, environment: [:])),
            Set([claude])
        )
        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .claudeDesktop, home: home, environment: [:])),
            Set([claudeDesktop])
        )
        let desktopEvents = try MultiClientUsageParsers.parse(
            data: Data(contentsOf: claudeDesktop), client: .claudeDesktop, sessionHint: "desktop-file"
        )
        XCTAssertEqual(desktopEvents.count, 1)
        XCTAssertEqual(desktopEvents[0].outputTokens, 2)
        XCTAssertEqual(
            MultiClientUsageDiscovery.files(client: .deepseek, home: home, environment: [:]), [dsh]
        )
        XCTAssertEqual(
            Set(MultiClientUsageDiscovery.files(client: .gemini, home: home, environment: [:])),
            Set([gemini, geminiSubagent])
        )
        XCTAssertEqual(
            MultiClientUsageDiscovery.files(client: .opencode, home: home, environment: [:]),
            [opencode, opencodeLegacy]
        )
    }

    private func claudeLine(
        session: String,
        entrypoint: String,
        id: String?,
        timestamp: String,
        usage: [String: Any]
    ) -> [String: Any] {
        var message: [String: Any] = ["model": "claude-opus", "usage": usage]
        if let id { message["id"] = id }
        var object: [String: Any] = [
            "type": "assistant",
            "entrypoint": entrypoint,
            "sessionId": session,
            "timestamp": timestamp,
            "message": message,
        ]
        if let id { object["requestId"] = "request-\(id)" }
        return object
    }

    private func deepSeekRecord(
        sequence: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        timestamp: Int64
    ) -> [String: Any] {
        [
            "type": "event",
            "event": [
                "type": "assistant/message",
                "time": timestamp,
                "seq": sequence,
                "data": [
                    "message": ["id": "deepseek-message", "source": ["model": "deepseek-v4"]],
                    "usage": [
                        "inputTokens": 100,
                        "outputTokens": output,
                        "cacheReadTokens": cacheRead,
                        "cacheWriteTokens": cacheWrite,
                    ],
                ],
            ],
        ]
    }

    private func geminiMessage(
        id: String,
        timestamp: String,
        input: Int,
        output: Int,
        cached: Int,
        thoughts: Int,
        tool: Int
    ) -> [String: Any] {
        [
            "id": id,
            "type": "gemini",
            "timestamp": timestamp,
            "model": "gemini-3-pro",
            "tokens": [
                "input": input,
                "output": output,
                "cached": cached,
                "thoughts": thoughts,
                "tool": tool,
                "total": input + output + tool,
            ],
        ]
    }

    private func openCodeMessage(
        id: String,
        session: String,
        streamed: Int64,
        input: Int,
        output: Int,
        reasoning: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> [String: Any] {
        [
            "id": id,
            "session_id": session,
            "type": "assistant",
            "data": [
                "time": ["created": streamed - 1_000, "streamed": streamed],
                "model": ["id": "gpt-test", "providerID": "openai"],
                "tokens": [
                    "input": input,
                    "output": output,
                    "reasoning": reasoning,
                    "cache": ["read": cacheRead, "write": cacheWrite],
                ],
            ],
        ]
    }

    private func jsonl(_ objects: [[String: Any]]) -> Data {
        var result = Data()
        for object in objects {
            result.append(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
        return result
    }

    private func createOpenCodeFixture(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let row = #"{"time":{"created":1797000000000,"streamed":1797000001000},"model":{"id":"gpt-test"},"tokens":{"input":10,"output":10,"reasoning":3,"cache":{"read":7,"write":3}}}"#
        let sql = """
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, time_created INTEGER NOT NULL);
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            );
            INSERT INTO session_v2 VALUES ('session-a', 1796999999000);
            INSERT INTO session_message VALUES (
                'message-a', 'session-a', 'assistant', 1, 1797000000000, 1797000001000, '\(row)'
            );
            INSERT INTO session_message VALUES (
                'message-inflight', 'session-a', 'assistant', 2, 1797000001000, 1797000002000,
                '{"time":{"created":1797000001000},"tokens":{"input":999,"output":999}}'
            );
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
