import XCTest
@testable import CodexTokenBar

final class CodexUsageAnalyzerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
        CodexUsageAnalyzer.clearUsageCachesForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
    }

    override func tearDownWithError() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
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

        XCTAssertEqual(snapshot.usagePrecision, .precise)
        XCTAssertTrue(snapshot.hasPreciseTokenUsage)
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
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
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

        let cacheDirectoryV6 = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v6", isDirectory: true)
        let cacheText = try cacheTextContents(under: cacheDirectoryV6)
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

    func testFastSnapshotDoesNotUseSQLiteTokenTotals() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).loadFastSnapshot()

        XCTAssertEqual(snapshot.usagePrecision, .metadataOnly)
        XCTAssertFalse(snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.peakThreadTokens, 0)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertTrue(snapshot.dailyUsage.isEmpty)
        XCTAssertTrue(snapshot.recentBins.isEmpty)
        XCTAssertTrue(snapshot.hourlyUsage.isEmpty)
    }

    func testPreciseJSONLScanIncludesActiveStateRolloutPaths() throws {
        let codexHome = try makeCodexHome()
        let externalRoot = try makeTemporaryDirectory(named: "CodexExternalRollouts")
        let sessionID = "019eaaaa-bbbb-cccc-dddd-activepath"
        let rolloutFile = externalRoot.appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 210, cachedInput: 40, output: 30, reasoning: 0, total: 240),
                last: Usage(input: 210, cachedInput: 40, output: 30, reasoning: 0, total: 240)
            )
        ].joined(separator: "\n").appending("\n").write(to: rolloutFile, atomically: true, encoding: .utf8)
        try seedStateDatabase(
            at: codexHome,
            rolloutPaths: [rolloutFile.path],
            archived: [0],
            threadSources: ["user"]
        )

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 240)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.sessions.map(\.id), [sessionID])
    }

    func testPreciseJSONLScanDeduplicatesStateRolloutPathsAlreadyUnderSessions() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-dedupepath"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 90, cachedInput: 10, output: 20, reasoning: 0, total: 110),
                last: Usage(input: 90, cachedInput: 10, output: 20, reasoning: 0, total: 110)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        try seedStateDatabase(
            at: codexHome,
            rolloutPaths: [sessionFile.path],
            archived: [0],
            threadSources: ["user"]
        )

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 110)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.sessions.count, 1)
    }

    func testPreciseJSONLScanIncludesActiveUserAndSubagentStateRolloutPaths() throws {
        let codexHome = try makeCodexHome()
        let externalRoot = try makeTemporaryDirectory(named: "CodexFilteredRollouts")
        let now = Date()
        let activeFile = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-activeok",
            timestamp: now.addingTimeInterval(-60),
            totalTokens: 100
        )
        let archivedFile = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-archived",
            timestamp: now.addingTimeInterval(-50),
            totalTokens: 200
        )
        let subagentFile = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-subonly",
            timestamp: now.addingTimeInterval(-40),
            totalTokens: 300
        )
        try seedStateDatabase(
            at: codexHome,
            rolloutPaths: [activeFile.path, archivedFile.path, subagentFile.path],
            archived: [0, 1, 0],
            threadSources: ["user", "user", "subagent"]
        )

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 400)
        XCTAssertEqual(snapshot.stats.totalCalls, 2)
        XCTAssertEqual(
            snapshot.cacheUsage.sessions.map(\.id).sorted(),
            [
                "019eaaaa-bbbb-cccc-dddd-activeok",
                "019eaaaa-bbbb-cccc-dddd-subonly"
            ]
        )
    }

    func testPreciseSnapshotSignatureChangesWhenLocalDateChanges() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-datesign"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        try [
            try tokenCountLine(
                timestamp: Date(timeIntervalSince1970: 1_782_000_000),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = analyzer.usageJSONLFiles()

        let before = analyzer.sessionTreeSignature(
            for: files,
            now: Date(timeIntervalSince1970: 1_782_000_000),
            timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!
        )
        let after = analyzer.sessionTreeSignature(
            for: files,
            now: Date(timeIntervalSince1970: 1_782_086_400),
            timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!
        )

        XCTAssertNotEqual(before, after)
    }

    func testLoadFallsBackToSQLiteWhenPreciseTokenEventsAreMissing() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.usagePrecision, .metadataOnly)
        XCTAssertFalse(snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.peakThreadTokens, 0)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertEqual(snapshot.cacheUsage.total, .empty)
    }

    func testForkedSessionSkipsReplayUntilNewUserMessageEvenAfterThirtySeconds() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)
        let sessionID = "019eaaaa-bbbb-cccc-dddd-forkreplay"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            spacedMessageLine(timestamp: forkedAt, type: "user_message", message: "Copied parent prompt"),
            spacedMessageLine(timestamp: forkedAt, type: "agent_message", message: "Copied parent answer"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(600),
                total: Usage(input: 300, cachedInput: 50, output: 80, reasoning: 0, total: 380),
                last: Usage(input: 300, cachedInput: 50, output: 80, reasoning: 0, total: 380)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.totalCalls, 0)
    }

    func testForkedSessionCountsTokenUsageAfterNewUserMessage() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-forkedmeta"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            spacedMessageLine(timestamp: forkedAt, type: "user_message", message: "Copied parent prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(10),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(40), type: "user_message", message: "New branch prompt"),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(42), type: "agent_message", message: "New branch answer"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(45),
                total: Usage(input: 180, cachedInput: 10, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 80, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 80)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 80)
        XCTAssertEqual(snapshot.cacheUsage.total.cachedInputTokens, 10)
    }

    func testForkedSessionCountsQuickTokenUsageAfterNewUserMessage() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-forkquick"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            spacedMessageLine(timestamp: forkedAt, type: "user_message", message: "Copied parent prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(10),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(10.5), type: "user_message", message: "Immediate branch prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(11),
                total: Usage(input: 160, cachedInput: 10, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 80)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 60)
        XCTAssertEqual(snapshot.cacheUsage.total.cachedInputTokens, 10)
    }

    func testForkedSessionIncrementalAppendKeepsCountingAfterReplayEnded() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-forkappend"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let forkedAt = Date()

        let firstLines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            spacedMessageLine(timestamp: forkedAt, type: "user_message", message: "Copied parent prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(10),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(40), type: "user_message", message: "New branch prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(45),
                total: Usage(input: 180, cachedInput: 10, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 80, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ]
        try firstLines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let first = try analyzer.load()
        XCTAssertEqual(first.stats.totalTokens, 80)

        try appendLines([
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(70),
                total: Usage(input: 250, cachedInput: 20, output: 50, reasoning: 0, total: 300),
                last: Usage(input: 70, cachedInput: 10, output: 20, reasoning: 0, total: 100)
            )
        ], to: sessionFile)

        let second = try analyzer.load()

        XCTAssertEqual(second.stats.totalTokens, 180)
        XCTAssertEqual(second.stats.totalCalls, 2)
    }

    func testParentThreadSubagentWithoutForkedFromStillCountsUsage() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-subagent"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let lines = [
            parentThreadSessionMetaLine(timestamp: now.addingTimeInterval(-80), sessionID: sessionID, parentID: "parent-thread"),
            spacedMessageLine(timestamp: now.addingTimeInterval(-70), type: "user_message", message: "Subagent prompt"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 20, output: 30, reasoning: 0, total: 130),
                last: Usage(input: 100, cachedInput: 20, output: 30, reasoning: 0, total: 130)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 130)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testMessageExcerptsParseWhitespaceJSONLines() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-spacedmsg"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let lines = [
            spacedMessageLine(timestamp: now.addingTimeInterval(-80), type: "user_message", message: "spaced user prompt"),
            spacedMessageLine(timestamp: now.addingTimeInterval(-70), type: "agent_message", message: "spaced assistant answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 1_100, cachedInput: 200, output: 75, reasoning: 0, total: 1_175),
                last: Usage(input: 1_100, cachedInput: 200, output: 75, reasoning: 0, total: 1_175)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertTrue(snapshot.cacheUsage.turns.contains { turn in
            turn.userPrompt == "spaced user prompt" && turn.assistantResponse == "spaced assistant answer"
        })
    }

    func testPreciseJSONLScanReusesCachedSnapshotWhenInputsAreUnchanged() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-incremental"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let lines = [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let first = try analyzer.load()
        let buildCountAfterFirstLoad = CodexUsageAnalyzer.preciseSnapshotBuildCountForTesting
        let second = try analyzer.load()

        XCTAssertEqual(first.stats.totalTokens, 120)
        XCTAssertEqual(second.stats.totalTokens, 120)
        XCTAssertGreaterThanOrEqual(buildCountAfterFirstLoad, 1)
        XCTAssertEqual(CodexUsageAnalyzer.preciseSnapshotBuildCountForTesting, buildCountAfterFirstLoad)
    }

    func testPreciseJSONLScanParsesOnlyAppendedSessionLines() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-appendonly"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let firstLines = [
            messageLine(timestamp: now.addingTimeInterval(-80), type: "user_message", message: "First prompt"),
            messageLine(timestamp: now.addingTimeInterval(-70), type: "agent_message", message: "First answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120)
            )
        ]
        try firstLines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let first = try analyzer.load()
        XCTAssertEqual(first.stats.totalTokens, 120)
        let fullParsesAfterFirstLoad = CodexUsageAnalyzer.fullSessionParseCountForTesting
        let incrementalParsesAfterFirstLoad = CodexUsageAnalyzer.incrementalSessionParseCountForTesting

        let appendedLines = [
            messageLine(timestamp: now.addingTimeInterval(-30), type: "user_message", message: "Second prompt"),
            messageLine(timestamp: now.addingTimeInterval(-20), type: "agent_message", message: "Second answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 190, cachedInput: 50, output: 40, reasoning: 0, total: 230),
                last: Usage(input: 90, cachedInput: 20, output: 20, reasoning: 0, total: 110)
            )
        ]
        try appendLines(appendedLines, to: sessionFile)

        let second = try analyzer.load()

        XCTAssertEqual(second.stats.totalTokens, 230)
        XCTAssertEqual(second.stats.totalCalls, 2)
        XCTAssertEqual(second.cacheUsage.total.inputTokens, 190)
        XCTAssertEqual(second.cacheUsage.total.cachedInputTokens, 50)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, fullParsesAfterFirstLoad)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, incrementalParsesAfterFirstLoad + 1)
    }

    func testSessionCacheRejectsAppendOffsetBeyondCurrentFileSize() {
        let cache = CodexUsageAnalyzer.SessionEventCache()
        let path = "/tmp/session-offset-beyond-eof.jsonl"
        let staleKey = CodexUsageAnalyzer.SessionCacheKey(path: path, size: 80, modifiedAt: 1_000)
        let currentKey = CodexUsageAnalyzer.SessionCacheKey(path: path, size: 120, modifiedAt: 1_100)
        let cached = CodexUsageAnalyzer.SessionEventCache.CachedSession(
            key: staleKey,
            events: [
                TokenEvent(
                    timestamp: Date(timeIntervalSince1970: 1_000),
                    sessionID: "session-offset-beyond-eof",
                    tokens: 120,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 20,
                    reasoningOutputTokens: 0,
                    userPrompt: "",
                    assistantResponse: ""
                )
            ],
            lastOffset: 240,
            endedWithNewline: true,
            previousTotalTokens: 120,
            canIncrementFromOffset: true,
            forkReplayActive: false,
            lastSkippedForkReplayTokenAt: nil,
            migratedFromLegacyCache: false
        )

        cache.store(cached, for: path)

        XCTAssertNil(cache.appendableSession(for: path, currentKey: currentKey))
    }

    func testPreciseJSONLScanFallsBackToFullParseWhenSessionShrinks() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-shrink"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let originalLines = [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-30),
                total: Usage(input: 160, cachedInput: 0, output: 40, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 0, output: 20, reasoning: 0, total: 80)
            )
        ]
        try originalLines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 200)
        let fullParsesAfterFirstLoad = CodexUsageAnalyzer.fullSessionParseCountForTesting

        let replacementLines = [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-20),
                total: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60),
                last: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60)
            )
        ]
        try replacementLines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let second = try analyzer.load()

        XCTAssertEqual(second.stats.totalTokens, 60)
        XCTAssertEqual(second.stats.totalCalls, 1)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, fullParsesAfterFirstLoad + 1)
    }

    func testPreciseJSONLScanUpdatesTotalsForNewAndDeletedSessions() throws {
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let firstID = "019eaaaa-bbbb-cccc-dddd-firstfile"
        let secondID = "019eaaaa-bbbb-cccc-dddd-secondfile"
        let firstFile = sessionsRoot.appendingPathComponent("2026-06-17-\(firstID).jsonl")
        let secondFile = sessionsRoot.appendingPathComponent("2026-06-17-\(secondID).jsonl")
        let now = Date()

        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)

        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-30),
                total: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60),
                last: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60)
            )
        ].joined(separator: "\n").appending("\n").write(to: secondFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 180)

        try FileManager.default.removeItem(at: firstFile)
        let afterDelete = try analyzer.load()

        XCTAssertEqual(afterDelete.stats.totalTokens, 60)
        XCTAssertEqual(afterDelete.stats.totalCalls, 1)
        XCTAssertEqual(afterDelete.cacheUsage.sessions.map(\.id), [secondID])
    }

    func testPersistentV6SessionCacheDoesNotStoreConversationText() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV6Cache")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v6privacy"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let secretQuestion = "v6 secret prompt 821219"
        let secretAnswer = "v6 secret answer 197705"
        let lines = [
            messageLine(timestamp: now.addingTimeInterval(-80), type: "user_message", message: secretQuestion),
            messageLine(timestamp: now.addingTimeInterval(-70), type: "agent_message", message: secretAnswer),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 120, cachedInput: 30, output: 20, reasoning: 0, total: 140),
                last: Usage(input: 120, cachedInput: 30, output: 20, reasoning: 0, total: 140)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 140)
        let cacheDirectory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v6", isDirectory: true)
        let cacheText = try cacheTextContents(under: cacheDirectory)
        XCTAssertFalse(cacheText.contains(secretQuestion))
        XCTAssertFalse(cacheText.contains(secretAnswer))
        XCTAssertFalse(cacheText.contains(#""userPrompt":"#))
        XCTAssertFalse(cacheText.contains(#""assistantResponse":"#))
        XCTAssertTrue(cacheText.contains("userPromptDigest"))
        XCTAssertTrue(cacheText.contains("assistantResponseDigest"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cacheRoot
                    .appendingPathComponent(UsageCacheLifecycle.appDirectoryName, isDirectory: true)
                    .appendingPathComponent(UsageCacheLifecycle.namespace, isDirectory: true)
                    .appendingPathComponent("session-token-snapshots-v6.json")
                    .path
            )
        )
    }

    func testOldDiscardableSessionCacheIsIgnoredAndRebuilt() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerDiscardLegacy")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v5migrate"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 120, cachedInput: 30, output: 20, reasoning: 0, total: 140),
                last: Usage(input: 120, cachedInput: 30, output: 20, reasoning: 0, total: 140)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let attributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheDirectory = cacheRoot.appendingPathComponent("CodexTokenBar", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let legacyCache = cacheDirectory.appendingPathComponent("session-token-events-v5.json")
        let legacyObject: [String: Any] = [
            "version": 5,
            "entries": [[
                "path": sessionFile.path,
                "size": size,
                "modifiedAt": modifiedAt,
                "events": [[
                    "timestamp": now.addingTimeInterval(-60).timeIntervalSince1970,
                    "sessionID": sessionID,
                    "tokens": 140,
                    "inputTokens": 120,
                    "cachedInputTokens": 30,
                    "outputTokens": 20,
                    "reasoningOutputTokens": 0,
                    "userPromptDigest": "legacy-user",
                    "assistantResponseDigest": "legacy-assistant"
                ]]
            ]],
            "snapshots": []
        ]
        try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
            .write(to: legacyCache, options: [.atomic])

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 140)
        XCTAssertGreaterThanOrEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCache.path))
        let v6Directory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v6", isDirectory: true)
        let rebuiltText = try cacheTextContents(under: v6Directory)
        XCTAssertFalse(rebuiltText.contains("legacy-user"))
        XCTAssertTrue(rebuiltText.contains("canIncrementFromOffset"))
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

    private func swiftUsageCacheRoot(in cacheRoot: URL) -> URL {
        cacheRoot
            .appendingPathComponent(UsageCacheLifecycle.appDirectoryName, isDirectory: true)
            .appendingPathComponent(UsageCacheLifecycle.namespace, isDirectory: true)
    }

    private func dataSource(for codexHome: URL) -> CodexDataSource {
        CodexDataSource(codexHome: codexHome, origin: .userSelected)
    }

    private func writeTokenCountRollout(
        in directory: URL,
        sessionID: String,
        timestamp: Date,
        totalTokens: Int
    ) throws -> URL {
        let file = directory.appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        try [
            try tokenCountLine(
                timestamp: timestamp,
                total: Usage(input: totalTokens, cachedInput: 0, output: 0, reasoning: 0, total: totalTokens),
                last: Usage(input: totalTokens, cachedInput: 0, output: 0, reasoning: 0, total: totalTokens)
            )
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return file
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

    private func seedStateDatabase(
        at codexHome: URL,
        rolloutPaths: [String],
        archived: [Int],
        threadSources: [String]
    ) throws {
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
            tokens_used INTEGER NOT NULL,
            rollout_path TEXT,
            archived INTEGER,
            thread_source TEXT
        );
        """)
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1000)
        for index in rolloutPaths.indices {
            try driver.execute(
                """
                INSERT INTO threads (
                    id, title, first_user_message, preview, reasoning_effort,
                    updated_at_ms, updated_at, tokens_used, rollout_path, archived, thread_source
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text("thread-\(index)"),
                    .text("Thread \(index)"),
                    .text("first"),
                    .text("preview"),
                    .text("high"),
                    .int(nowMilliseconds),
                    .int(nowMilliseconds),
                    .int(0),
                    .text(rolloutPaths[index]),
                    .int(archived[index]),
                    .text(threadSources[index])
                ]
            )
        }
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

    private func spacedSessionMetaLine(timestamp: Date, sessionID: String) -> String {
        "{ \"timestamp\" : \"\(iso8601String(from: timestamp))\", \"type\" : \"session_meta\", \"payload\" : { \"id\" : \"\(sessionID)\", \"forked_from_id\" : \"origin-session\" } }"
    }

    private func parentThreadSessionMetaLine(timestamp: Date, sessionID: String, parentID: String) -> String {
        "{ \"timestamp\" : \"\(iso8601String(from: timestamp))\", \"type\" : \"session_meta\", \"payload\" : { \"id\" : \"\(sessionID)\", \"parent_thread_id\" : \"\(parentID)\", \"thread_source\" : \"subagent\" } }"
    }

    private func spacedMessageLine(timestamp: Date, type: String, message: String) -> String {
        "{ \"timestamp\" : \"\(iso8601String(from: timestamp))\", \"type\" : \"event_msg\", \"payload\" : { \"type\" : \"\(type)\", \"message\" : \"\(message)\" } }"
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

    private func appendLines(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.joined(separator: "\n").appending("\n").utf8))
        try handle.close()
    }

    private func cacheTextContents(under directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }
        return try enumerator.reduce(into: "") { partial, item in
            guard let url = item as? URL else { return }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return }
            partial += try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
