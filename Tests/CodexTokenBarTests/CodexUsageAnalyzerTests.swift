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

    func testCurrentStreakUsesTodayWithOneDayGraceTable() throws {
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: try makeCodexHome()))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        let now = today.addingTimeInterval(12 * 60 * 60)
        let cases: [(name: String, days: [(offset: Int, tokens: Int)], expected: Int)] = [
            ("today active", [(-2, 10), (-1, 20), (0, 30)], 3),
            ("yesterday grace", [(-2, 10), (-1, 20), (0, 0)], 2),
            ("today and yesterday empty", [(-2, 10), (-1, 0), (0, 0)], 0),
            ("missing yesterday truncates", [(-2, 10), (0, 20)], 1),
            ("same local day merges", [(0, 10), (0, 20)], 1),
            ("stale only", [(-2, 10)], 0),
            ("future ignored", [(0, 10), (1, 20)], 1),
            ("empty precise series", [], 0)
        ]

        for testCase in cases {
            let daily = testCase.days.map { day in
                DayUsage(
                    date: calendar.date(byAdding: .day, value: day.offset, to: today)!,
                    tokens: day.tokens,
                    calls: day.tokens > 0 ? 1 : 0
                )
            }
            XCTAssertEqual(
                analyzer.currentStreakDays(from: daily, now: now, calendar: calendar),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testCurrentStreakUsesInjectedLocalDayBoundary() throws {
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: try makeCodexHome()))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11
        ))!
        let now = today.addingTimeInterval(60)
        let events = [
            tokenEvent(timestamp: today.addingTimeInterval(-60), sessionID: "yesterday"),
            tokenEvent(timestamp: today.addingTimeInterval(60), sessionID: "today")
        ]

        let daily = analyzer.dailyUsage(from: events, now: now, calendar: calendar)

        XCTAssertEqual(daily.suffix(2).map(\.tokens), [1, 1])
        XCTAssertEqual(analyzer.currentStreakDays(from: daily, now: now, calendar: calendar), 2)
    }

    func testCurrentStreakProductionWrapperAnchorsToRealToday() throws {
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: try makeCodexHome()))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let stale = [DayUsage(date: twoDaysAgo, tokens: 10, calls: 1)]
        let missingYesterday = stale + [DayUsage(date: today, tokens: 20, calls: 1)]
        let duplicateToday = [
            DayUsage(date: today, tokens: 10, calls: 1),
            DayUsage(date: today.addingTimeInterval(60), tokens: 20, calls: 1)
        ]

        XCTAssertEqual(analyzer.currentStreakDays(from: stale), 0)
        XCTAssertEqual(analyzer.currentStreakDays(from: missingYesterday), 1)
        XCTAssertEqual(analyzer.currentStreakDays(from: duplicateToday), 1)
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

    func testInterleavedCumulativeStreamsUseUniqueLastUsageSnapshots() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019faaaa-bbbb-cccc-dddd-interleaved"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-\(sessionID).jsonl")
        let now = Date()
        let streamATotal = Usage(
            input: 2_718_279_305,
            cachedInput: 0,
            output: 0,
            reasoning: 0,
            total: 2_718_279_305
        )
        let streamALast = Usage(input: 157_910, cachedInput: 0, output: 0, reasoning: 0, total: 157_910)
        let lines = [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: streamATotal,
                last: streamALast
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-50),
                total: Usage(input: 2_583_955_090, cachedInput: 0, output: 0, reasoning: 0, total: 2_583_955_090),
                last: Usage(input: 113_621, cachedInput: 0, output: 0, reasoning: 0, total: 113_621)
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-40),
                total: streamATotal,
                last: streamALast
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-30),
                total: Usage(input: 2_584_078_056, cachedInput: 0, output: 0, reasoning: 0, total: 2_584_078_056),
                last: Usage(input: 122_966, cachedInput: 0, output: 0, reasoning: 0, total: 122_966)
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-20),
                total: Usage(input: 2_718_437_623, cachedInput: 0, output: 0, reasoning: 0, total: 2_718_437_623),
                last: Usage(input: 158_318, cachedInput: 0, output: 0, reasoning: 0, total: 158_318)
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 2_718_437_623, cachedInput: 0, output: 0, reasoning: 0, total: 2_718_437_623),
                last: Usage(input: 77_777, cachedInput: 0, output: 0, reasoning: 0, total: 77_777)
            )
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 630_592)
        XCTAssertEqual(snapshot.stats.totalCalls, 5)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 630_592)
    }

    func testPersistentCacheKeepsInterleavedSnapshotDedupeAcrossRestart() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageInterleavedRestart")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019faaaa-bbbb-cccc-dddd-interleaved-cache"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-\(sessionID).jsonl")
        let now = Date()
        let streamAUsage = Usage(input: 100, cachedInput: 0, output: 0, reasoning: 0, total: 100)
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-40),
                total: Usage(input: 1_000, cachedInput: 0, output: 0, reasoning: 0, total: 1_000),
                last: streamAUsage
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-30),
                total: Usage(input: 900, cachedInput: 0, output: 0, reasoning: 0, total: 900),
                last: Usage(input: 90, cachedInput: 0, output: 0, reasoning: 0, total: 90)
            )
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load().stats.totalTokens,
            190
        )
        CodexUsageAnalyzer.clearUsageCachesForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()

        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-20),
                total: Usage(input: 1_000, cachedInput: 0, output: 0, reasoning: 0, total: 1_000),
                last: streamAUsage
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 990, cachedInput: 0, output: 0, reasoning: 0, total: 990),
                last: Usage(input: 90, cachedInput: 0, output: 0, reasoning: 0, total: 90)
            )
        ], to: sessionFile)

        let reloaded = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(reloaded.stats.totalTokens, 280)
        XCTAssertEqual(reloaded.stats.totalCalls, 3)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 1)
    }

    func testRecentBinsKeepFiveMinuteHistoryForThirtyDays() throws {
        let codexHome = try makeCodexHome()
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let now = Date()
        let included = TokenEvent(
            timestamp: now.addingTimeInterval(-29 * 24 * 60 * 60),
            sessionID: "included",
            tokens: 100,
            inputTokens: 80,
            cachedInputTokens: 0,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            userPrompt: "",
            assistantResponse: ""
        )
        let excluded = TokenEvent(
            timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
            sessionID: "excluded",
            tokens: 1_000,
            inputTokens: 800,
            cachedInputTokens: 0,
            outputTokens: 200,
            reasoningOutputTokens: 0,
            userPrompt: "",
            assistantResponse: ""
        )

        let bins = analyzer.recentBins(from: [included, excluded])

        XCTAssertEqual(bins.count, 30 * 24 * 12)
        XCTAssertEqual(bins.reduce(0) { $0 + $1.tokens }, 100)
        XCTAssertEqual(bins.reduce(0) { $0 + $1.calls }, 1)
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
        let legacyCaches = try [2, 3, 4, 5].map { version in
            let url = cacheDirectory.appendingPathComponent("session-token-events-v\(version).json")
            try #"{"userPrompt":"legacy secret question","assistantResponse":"legacy secret answer"}"#
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }

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

        let cacheDirectoryV9 = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
        let cacheText = try cacheTextContents(under: cacheDirectoryV9)
        XCTAssertFalse(cacheText.contains(secretQuestion))
        XCTAssertFalse(cacheText.contains(secretAnswer))
        XCTAssertFalse(cacheText.contains("legacy secret question"))
        XCTAssertFalse(cacheText.contains("legacy secret answer"))
        XCTAssertFalse(cacheText.contains(#""userPrompt":"#))
        XCTAssertFalse(cacheText.contains(#""assistantResponse":"#))
        XCTAssertTrue(cacheText.contains("userPromptDigest"))
        XCTAssertTrue(cacheText.contains("assistantResponseDigest"))
        XCTAssertTrue(legacyCaches.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFastSnapshotDoesNotUseSQLiteTokenTotals() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).loadFastSnapshot()

        XCTAssertEqual(snapshot.usagePrecision, .metadataOnly)
        XCTAssertFalse(snapshot.hasPreciseTokenUsage)
        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.peakThreadTokens, 0)
        XCTAssertEqual(snapshot.stats.currentStreakDays, 0)
        XCTAssertEqual(snapshot.stats.longestStreakDays, 0)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertTrue(snapshot.dailyUsage.isEmpty)
        XCTAssertTrue(snapshot.recentBins.isEmpty)
        XCTAssertTrue(snapshot.hourlyUsage.isEmpty)
    }

    func testPreciseJSONLScanIncludesActiveStateRolloutPathsInsideSelectedHome() throws {
        let codexHome = try makeCodexHome()
        let rolloutRoot = codexHome.appendingPathComponent("active-rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutRoot, withIntermediateDirectories: true)
        let sessionID = "019eaaaa-bbbb-cccc-dddd-activepath"
        let rolloutFile = rolloutRoot.appendingPathComponent("2026-06-17-\(sessionID).jsonl")
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

    func testPreciseJSONLScanRejectsAbsoluteActiveRolloutOutsideSelectedHome() throws {
        let codexHome = try makeCodexHome()
        let trustedFile = try writeTokenCountRollout(
            in: codexHome.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "019eaaaa-bbbb-cccc-dddd-trustedrollout",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 10
        )
        let externalRoot = try makeTemporaryDirectory(named: "CodexExternalActiveRollout")
        let externalFile = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-externalrollout",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 700
        )
        try seedStateDatabase(
            at: codexHome,
            rolloutPaths: [externalFile.path],
            archived: [0],
            threadSources: ["user"]
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = try analyzer.usageJSONLFiles()
        let snapshot = try analyzer.load()

        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [trustedFile.resolvingSymlinksInPath().path])
        XCTAssertEqual(snapshot.stats.totalTokens, 10)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testPreciseJSONLScanRejectsDirectorySymlinkCyclePromptly() throws {
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let trustedFile = try writeTokenCountRollout(
            in: sessionsRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-trustedcycle",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 10
        )
        try FileManager.default.createSymbolicLink(
            at: sessionsRoot.appendingPathComponent("cycle.jsonl"),
            withDestinationURL: sessionsRoot
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let startedAt = Date()
        let files = try analyzer.usageJSONLFiles()
        let elapsed = Date().timeIntervalSince(startedAt)
        let snapshot = try analyzer.load()

        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [trustedFile.resolvingSymlinksInPath().path])
        XCTAssertEqual(snapshot.stats.totalTokens, 10)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testPreciseJSONLScanRejectsDirectorySymlinkEscape() throws {
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let trustedFile = try writeTokenCountRollout(
            in: sessionsRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-trusteddirlink",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 10
        )
        let externalRoot = try makeTemporaryDirectory(named: "CodexDirectorySymlinkEscape")
        _ = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-externaldirlink",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 700
        )
        try FileManager.default.createSymbolicLink(
            at: sessionsRoot.appendingPathComponent("escaped-directory.jsonl"),
            withDestinationURL: externalRoot
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = try analyzer.usageJSONLFiles()
        let snapshot = try analyzer.load()

        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [trustedFile.resolvingSymlinksInPath().path])
        XCTAssertEqual(snapshot.stats.totalTokens, 10)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testPreciseJSONLScanRejectsFileSymlinkEscape() throws {
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let trustedFile = try writeTokenCountRollout(
            in: sessionsRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-trustedfilelink",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 10
        )
        let externalRoot = try makeTemporaryDirectory(named: "CodexFileSymlinkEscape")
        let externalFile = try writeTokenCountRollout(
            in: externalRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-externalfilelink",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 700
        )
        try FileManager.default.createSymbolicLink(
            at: sessionsRoot.appendingPathComponent("linked-external.jsonl"),
            withDestinationURL: externalFile
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = try analyzer.usageJSONLFiles()
        let snapshot = try analyzer.load()

        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [trustedFile.resolvingSymlinksInPath().path])
        XCTAssertEqual(snapshot.stats.totalTokens, 10)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testPreciseJSONLScanIncludesOrdinaryNestedSessions() throws {
        let codexHome = try makeCodexHome()
        let nestedRoot = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026/07/11", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        let nestedFile = try writeTokenCountRollout(
            in: nestedRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-nestedsession",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 120
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = try analyzer.usageJSONLFiles()
        let snapshot = try analyzer.load()

        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [nestedFile.resolvingSymlinksInPath().path])
        XCTAssertEqual(snapshot.stats.totalTokens, 120)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testSelectedHomeReplacementWithExternalSymlinkFailsClosed() throws {
        let codexHome = try makeCodexHome()
        let source = dataSource(for: codexHome)
        let externalHome = try makeCodexHome()
        _ = try writeTokenCountRollout(
            in: externalHome.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "019eaaaa-bbbb-cccc-dddd-retargetedhome",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 700
        )
        _ = try replaceDirectoryWithSymlink(at: codexHome, destination: externalHome)

        XCTAssertThrowsError(try CodexUsageAnalyzer(dataSource: source).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("身份"), error.localizedDescription)
        }
    }

    func testPersistedSelectedHomeIdentityRejectsLaterPathRetarget() throws {
        let codexHome = try makeCodexHome()
        let externalHome = try makeCodexHome()
        _ = try writeTokenCountRollout(
            in: externalHome.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "019eaaaa-bbbb-cccc-dddd-persistedhome",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 700
        )
        let suiteName = "CodexUsageAnalyzerSelectedHome-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bookmarkKey = "CodexUsageAnalyzerSelectedHomeBookmark-\(UUID().uuidString)"
        let resolver = CodexDataSourceResolver(
            defaults: defaults,
            scopedAccess: SecurityScopedCodexDirectoryAccess(defaults: defaults, bookmarkKey: bookmarkKey)
        )
        _ = try XCTUnwrap(resolver.saveSelectedDirectory(codexHome))
        defaults.removeObject(forKey: bookmarkKey)
        _ = try replaceDirectoryWithSymlink(at: codexHome, destination: externalHome)

        let resolved = try XCTUnwrap(resolver.resolve())

        XCTAssertThrowsError(try CodexUsageAnalyzer(dataSource: resolved).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("身份"), error.localizedDescription)
        }
    }

    func testInitialSelectedHomeSymlinkCanonicalizesToItsRealDirectory() throws {
        let realHome = try makeCodexHome()
        _ = try writeTokenCountRollout(
            in: realHome.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "019eaaaa-bbbb-cccc-dddd-initialsymlink",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 120
        )
        let linkParent = try makeTemporaryDirectory(named: "CodexInitialHomeSymlink")
        let selectedLink = linkParent.appendingPathComponent("selected-home")
        try FileManager.default.createSymbolicLink(at: selectedLink, withDestinationURL: realHome)
        let suiteName = "CodexUsageAnalyzerInitialSymlink-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = CodexDataSourceResolver(
            defaults: defaults,
            scopedAccess: SecurityScopedCodexDirectoryAccess(
                defaults: defaults,
                bookmarkKey: "CodexUsageAnalyzerInitialSymlinkBookmark-\(UUID().uuidString)"
            )
        )

        let selected = try XCTUnwrap(resolver.saveSelectedDirectory(selectedLink))
        let snapshot = try CodexUsageAnalyzer(dataSource: selected).load()

        XCTAssertEqual(selected.codexHome.path, realHome.resolvingSymlinksInPath().path)
        XCTAssertEqual(snapshot.stats.totalTokens, 120)
        XCTAssertTrue(snapshot.hasPreciseTokenUsage)
    }

    func testUnreadableSessionDirectoryThrowsDiscoveryFailure() throws {
        let codexHome = try makeCodexHome()
        let blockedDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedDirectory.path)
        }

        XCTAssertThrowsError(
            try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).usageJSONLFiles()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("遍历"), error.localizedDescription)
        }
    }

    func testTraversalDepthLimitThrowsDiscoveryFailure() throws {
        let codexHome = try makeCodexHome()
        var directory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        for index in 0..<65 {
            directory.appendPathComponent("level-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(
            try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).usageJSONLFiles()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("上限"), error.localizedDescription)
        }
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
        let rolloutRoot = codexHome.appendingPathComponent("filtered-rollouts", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutRoot, withIntermediateDirectories: true)
        let now = Date()
        let activeFile = try writeTokenCountRollout(
            in: rolloutRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-activeok",
            timestamp: now.addingTimeInterval(-60),
            totalTokens: 100
        )
        let archivedFile = try writeTokenCountRollout(
            in: rolloutRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-archived",
            timestamp: now.addingTimeInterval(-50),
            totalTokens: 200
        )
        let subagentFile = try writeTokenCountRollout(
            in: rolloutRoot,
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
        let files = try analyzer.usageJSONLFiles()

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

    func testForkedSessionKeepsSkippingReplayMessagesWithinGraceWindow() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)
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

        XCTAssertEqual(snapshot.stats.totalTokens, 0)
        XCTAssertEqual(snapshot.stats.totalCalls, 0)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 0)
        XCTAssertEqual(snapshot.cacheUsage.total.cachedInputTokens, 0)
    }

    func testForkedSessionSkipsDenseReplayBeforeDelayedNewPrompt() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-forkdense"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-09-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(0.001), type: "user_message", message: "Replayed parent prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.002),
                total: Usage(input: 20_000, cachedInput: 2_000, output: 300, reasoning: 0, total: 23_517),
                last: Usage(input: 20_000, cachedInput: 2_000, output: 300, reasoning: 0, total: 23_517)
            ),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(0.003), type: "user_message", message: "Another replayed parent prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.004),
                total: Usage(input: 313_456_376, cachedInput: 293_677_696, output: 1_296_446, reasoning: 452_984, total: 314_752_822),
                last: Usage(input: 0, cachedInput: 0, output: 0, reasoning: 0, total: 26608)
            ),
            spacedMessageLine(timestamp: forkedAt.addingTimeInterval(27), type: "user_message", message: "New branch prompt"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(36),
                total: Usage(input: 313_484_657, cachedInput: 293_682_688, output: 1_296_671, reasoning: 453_181, total: 314_781_328),
                last: Usage(input: 28_281, cachedInput: 4_992, output: 225, reasoning: 197, total: 28_506)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 28_506)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.total.inputTokens, 28_281)
        XCTAssertEqual(snapshot.cacheUsage.total.cachedInputTokens, 4_992)
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
            lastSkippedForkReplayTokenAt: nil
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

    func testPersistentV9SessionCacheDoesNotStoreConversationText() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV9Cache")
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
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
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
                    .appendingPathComponent("session-token-snapshots-v9.json")
                    .path
            )
        )

        CodexUsageAnalyzer.clearUsageCachesForTesting()
        let reloaded = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(reloaded.stats.totalTokens, 140)
        XCTAssertEqual(reloaded.stats.totalCalls, 1)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
    }

    func testPersistentV9SessionCacheAppendsOnlyNewEventsAndSkipsNoOpWrites() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV9Append")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v9append"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)

        let cacheDirectory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        let eventURL = try XCTUnwrap(cacheFiles.first { $0.lastPathComponent.hasSuffix(".events.jsonl") })
        let metadataURL = try XCTUnwrap(cacheFiles.first { $0.lastPathComponent.hasSuffix(".meta.json") })
        let initialEvents = try Data(contentsOf: eventURL)
        let initialEventAttributes = try FileManager.default.attributesOfItem(atPath: eventURL.path)
        let initialEventFileNumber = try XCTUnwrap(
            (initialEventAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        let initialMetadata = try Data(contentsOf: metadataURL)
        let initialMetadataAttributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)

        _ = try analyzer.load()

        XCTAssertEqual(try Data(contentsOf: eventURL), initialEvents)
        XCTAssertEqual(try Data(contentsOf: metadataURL), initialMetadata)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: eventURL.path)[.systemFileNumber] as? NSNumber,
            initialEventAttributes[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.systemFileNumber] as? NSNumber,
            initialMetadataAttributes[.systemFileNumber] as? NSNumber
        )

        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 190, cachedInput: 50, output: 40, reasoning: 0, total: 230),
                last: Usage(input: 90, cachedInput: 20, output: 20, reasoning: 0, total: 110)
            )
        ], to: sessionFile)

        let fullParses = CodexUsageAnalyzer.fullSessionParseCountForTesting
        let incrementalParses = CodexUsageAnalyzer.incrementalSessionParseCountForTesting
        let updated = try analyzer.load()
        let updatedEvents = try Data(contentsOf: eventURL)
        let updatedEventAttributes = try FileManager.default.attributesOfItem(atPath: eventURL.path)

        XCTAssertEqual(updated.stats.totalTokens, 230)
        XCTAssertEqual(updated.stats.totalCalls, 2)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, fullParses)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, incrementalParses + 1)
        XCTAssertEqual(
            try XCTUnwrap((updatedEventAttributes[.systemFileNumber] as? NSNumber)?.uint64Value),
            initialEventFileNumber,
            "append-only persistence must not atomically replace the full event shard"
        )
        XCTAssertTrue(updatedEvents.starts(with: initialEvents))
        XCTAssertGreaterThan(updatedEvents.count, initialEvents.count)
        XCTAssertLessThan(updatedEvents.count - initialEvents.count, 2_048)
        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual((metadataObject["eventCount"] as? NSNumber)?.intValue, 2)

        let stableEventAttributes = try FileManager.default.attributesOfItem(atPath: eventURL.path)
        let stableMetadataAttributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
        let stableEvents = try Data(contentsOf: eventURL)
        let stableMetadata = try Data(contentsOf: metadataURL)
        _ = try analyzer.load()
        XCTAssertEqual(try Data(contentsOf: eventURL), stableEvents)
        XCTAssertEqual(try Data(contentsOf: metadataURL), stableMetadata)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: eventURL.path)[.systemFileNumber] as? NSNumber,
            stableEventAttributes[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.systemFileNumber] as? NSNumber,
            stableMetadataAttributes[.systemFileNumber] as? NSNumber
        )
    }

    func testPersistentCacheRebuildsPreviousNamespaceAfterCountingRuleChange() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV9Migration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v9migration"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let eventDate = Date().addingTimeInterval(-60)
        try [
            try tokenCountLine(
                timestamp: eventDate,
                total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let size = try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value)
        let modifiedAt = try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970

        let legacyNamespace = cacheRoot
            .appendingPathComponent(UsageCacheLifecycle.appDirectoryName, isDirectory: true)
            .appendingPathComponent("swift-usage-cache-2026-07-v3", isDirectory: true)
        let legacyDirectory = legacyNamespace
            .appendingPathComponent("session-token-events-v6", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyPayload: [String: Any] = [
            "version": 8,
            "entry": [
                "path": sessionFile.resolvingSymlinksInPath().path,
                "size": size,
                "modifiedAt": modifiedAt,
                "lastOffset": size,
                "endedWithNewline": true,
                "previousTotalTokens": 120,
                "canIncrementFromOffset": true,
                "forkReplayActive": false,
                "events": [[
                    "timestamp": eventDate.timeIntervalSince1970,
                    "sessionID": sessionID,
                    "tokens": 120,
                    "inputTokens": 100,
                    "cachedInputTokens": 20,
                    "outputTokens": 20,
                    "reasoningOutputTokens": 0,
                    "userPromptDigest": "legacy-prompt-digest",
                    "assistantResponseDigest": "legacy-response-digest"
                ]]
            ]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload, options: [.sortedKeys])
        try legacyData.write(to: legacyDirectory.appendingPathComponent("legacy-session.json"), options: [.atomic])

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 120)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        let v9Directory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
        let rebuiltCache = try cacheTextContents(under: v9Directory)
        XCTAssertTrue(rebuiltCache.contains(#""eventCount":1"#))
        XCTAssertFalse(rebuiltCache.contains("legacy-prompt-digest"))

        UsageCacheLifecycle.markCurrentCachePrepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyNamespace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v9Directory.path))
    }

    func testPersistentV9SessionCacheRebuildsAfterEventLogCorruption() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV9Corrupt")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v9corrupt"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try [
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)
        let cacheDirectory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        let eventURL = try XCTUnwrap(cacheFiles.first { $0.lastPathComponent.hasSuffix(".events.jsonl") })
        try Data("corrupt-cache-line\n".utf8).write(to: eventURL, options: [.atomic])

        CodexUsageAnalyzer.clearUsageCachesForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let rebuilt = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(rebuilt.stats.totalTokens, 120)
        XCTAssertEqual(rebuilt.stats.totalCalls, 1)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        XCTAssertFalse(try String(contentsOf: eventURL, encoding: .utf8).contains("corrupt-cache-line"))
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
        let v9Directory = swiftUsageCacheRoot(in: cacheRoot)
            .appendingPathComponent("session-token-events-v9", isDirectory: true)
        let rebuiltText = try cacheTextContents(under: v9Directory)
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

    @discardableResult
    private func replaceDirectoryWithSymlink(at directory: URL, destination: URL) throws -> URL {
        let preservedDirectory = directory
            .deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)-preserved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: preservedDirectory)
        temporaryDirectories.append(preservedDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
        return preservedDirectory
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

    private func tokenEvent(timestamp: Date, sessionID: String) -> TokenEvent {
        TokenEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            tokens: 1,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            userPrompt: "",
            assistantResponse: ""
        )
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
