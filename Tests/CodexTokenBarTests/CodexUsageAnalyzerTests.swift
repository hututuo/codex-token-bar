import XCTest
@testable import CodexTokenBar

final class CodexUsageAnalyzerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testPreciseJSONLScanBuildsUsageSeriesAndCacheBreakdown() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-eeeeffffffff"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let lines = [
            messageLine(timestamp: now.addingTimeInterval(-130), type: "user_message", message: "First question"),
            messageLine(timestamp: now.addingTimeInterval(-120), type: "agent_message", message: "First answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-110),
                total: Usage(input: 100, cachedInput: 40, output: 20, reasoning: 5, total: 120),
                last: Usage(input: 100, cachedInput: 40, output: 20, reasoning: 5, total: 120)
            ),
            messageLine(timestamp: now.addingTimeInterval(-80), type: "user_message", message: "Second question"),
            messageLine(timestamp: now.addingTimeInterval(-70), type: "agent_message", message: "Second answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 150, cachedInput: 50, output: 30, reasoning: 7, total: 180),
                last: Usage(input: 50, cachedInput: 10, output: 10, reasoning: 2, total: 60)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 180)
        XCTAssertEqual(snapshot.stats.totalCalls, 2)
        XCTAssertEqual(snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 180)
        XCTAssertEqual(snapshot.recentBins.reduce(0) { $0 + $1.tokens }, 180)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 150)
        XCTAssertEqual(snapshot.cacheUsage.total.cachedInputTokens, 50)
        XCTAssertEqual(snapshot.cacheUsage.total.outputTokens, 30)
        XCTAssertEqual(snapshot.cacheUsage.total.reasoningOutputTokens, 7)
        XCTAssertEqual(snapshot.cacheUsage.total.calls, 2)
        XCTAssertEqual(snapshot.cacheUsage.sessions.first?.id, sessionID)
        XCTAssertEqual(snapshot.cacheUsage.turns.count, 2)
        XCTAssertEqual(Set(snapshot.cacheUsage.turns.map(\.userPrompt)), ["First question", "Second question"])
    }

    func testPersistentSessionCacheDoesNotStoreConversationText() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerCache")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        }

        let cacheDirectory = cacheRoot.appendingPathComponent("CodexTokenBar", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let legacyCache = cacheDirectory.appendingPathComponent("session-token-events-v4.json")
        try #"{"userPrompt":"legacy secret question","assistantResponse":"legacy secret answer"}"#
            .write(to: legacyCache, atomically: true, encoding: .utf8)

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-cacheprivacy"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let secretQuestion = "privacy unique prompt 8E2A2A0D"
        let secretAnswer = "privacy unique answer B03F65A1"

        let lines = [
            messageLine(timestamp: now.addingTimeInterval(-80), type: "user_message", message: secretQuestion),
            messageLine(timestamp: now.addingTimeInterval(-70), type: "agent_message", message: secretAnswer),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 1_200, cachedInput: 300, output: 90, reasoning: 10, total: 1_300),
                last: Usage(input: 1_200, cachedInput: 300, output: 90, reasoning: 10, total: 1_300)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertTrue(snapshot.cacheUsage.turns.contains { $0.userPrompt == secretQuestion })
        XCTAssertTrue(snapshot.cacheUsage.turns.contains { $0.assistantResponse == secretAnswer })

        let cacheFile = cacheDirectory.appendingPathComponent("session-token-events-v5.json")
        let cacheText = try String(contentsOf: cacheFile, encoding: .utf8)
        XCTAssertFalse(cacheText.contains(secretQuestion))
        XCTAssertFalse(cacheText.contains(secretAnswer))
        XCTAssertFalse(cacheText.contains("legacy secret question"))
        XCTAssertFalse(cacheText.contains("legacy secret answer"))
        XCTAssertFalse(cacheText.contains(#""userPrompt":"#))
        XCTAssertFalse(cacheText.contains(#""assistantResponse":"#))
        XCTAssertTrue(cacheText.contains("userPromptDigest"))
        XCTAssertTrue(cacheText.contains("assistantResponseDigest"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCache.path))
    }

    func testFastSnapshotKeepsTimeSeriesEmptyToAvoidTodayMisreporting() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).loadFastSnapshot()

        XCTAssertEqual(snapshot.stats.totalTokens, 300)
        XCTAssertEqual(snapshot.stats.peakThreadTokens, 200)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertEqual(snapshot.dailyUsage.reduce(0) { $0 + $1.tokens }, 0)
        XCTAssertEqual(snapshot.recentBins.reduce(0) { $0 + $1.tokens }, 0)
        XCTAssertEqual(snapshot.hourlyUsage.reduce(0) { $0 + $1.tokens }, 0)
    }

    func testLoadFallsBackToSQLiteWhenPreciseTokenEventsAreMissing() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 300)
        XCTAssertEqual(snapshot.stats.peakThreadTokens, 200)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertEqual(snapshot.cacheUsage.total, .empty)
    }

    func testSQLiteReasoningUsesExactReasoningEffortColumn() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabaseWithReasoningNoise(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).loadFastSnapshot()

        XCTAssertEqual(snapshot.stats.mostUsedReasoning, "中 · 1")
    }

    private struct Usage {
        let input: Int
        let cachedInput: Int
        let output: Int
        let reasoning: Int
        let total: Int
    }

    private func makeCodexHome() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "CodexUsageAnalyzerTests")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func dataSource(for codexHome: URL) -> CodexDataSource {
        CodexDataSource(codexHome: codexHome, origin: .userSelected)
    }

    private func seedStateDatabase(at codexHome: URL) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT,
            first_user_message TEXT,
            preview TEXT,
            reasoning_effort TEXT,
            updated_at_ms INTEGER,
            updated_at INTEGER,
            tokens_used INTEGER NOT NULL
        );
        """)
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1000)
        try driver.execute(
            """
            INSERT INTO threads (id, title, first_user_message, preview, reasoning_effort, updated_at_ms, updated_at, tokens_used)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text("thread-a"), .text("A"), .text("A first"), .text("A preview"), .text("high"), .int(nowMilliseconds), .int(nowMilliseconds), .int(100),
                .text("thread-b"), .text("B"), .text("B first"), .text("B preview"), .text("low"), .int(nowMilliseconds), .int(nowMilliseconds), .int(200)
            ]
        )
    }

    private func seedStateDatabaseWithReasoningNoise(at codexHome: URL) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT,
            first_user_message TEXT,
            preview TEXT,
            reasoning_effort TEXT,
            updated_at_ms INTEGER,
            updated_at INTEGER,
            tokens_used INTEGER NOT NULL
        );
        """)
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1000)
        try driver.execute(
            """
            INSERT INTO threads (id, title, first_user_message, preview, reasoning_effort, updated_at_ms, updated_at, tokens_used)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text("thread-medium"), .text("highlight low memory"), .text("effort high in prompt"), .text("preview low"), .text("medium"), .int(nowMilliseconds), .int(nowMilliseconds), .int(100),
                .text("thread-no-effort"), .text("high effort words only"), .text("low words only"), .text("medium words only"), .null, .int(nowMilliseconds), .int(nowMilliseconds), .int(200)
            ]
        )
    }

    private func messageLine(timestamp: Date, type: String, message: String) -> String {
        encodeLine([
            "timestamp": iso8601String(from: timestamp),
            "type": "event_msg",
            "payload": [
                "type": type,
                "message": message
            ]
        ])
    }

    private func tokenCountLine(timestamp: Date, total: Usage, last: Usage) throws -> String {
        encodeLine([
            "timestamp": iso8601String(from: timestamp),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": usageObject(total),
                    "last_token_usage": usageObject(last)
                ]
            ]
        ])
    }

    private func usageObject(_ usage: Usage) -> [String: Int] {
        [
            "input_tokens": usage.input,
            "cached_input_tokens": usage.cachedInput,
            "output_tokens": usage.output,
            "reasoning_output_tokens": usage.reasoning,
            "total_tokens": usage.total
        ]
    }

    private func encodeLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
