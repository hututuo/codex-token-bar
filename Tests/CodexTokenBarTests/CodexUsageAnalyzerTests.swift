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
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let codexHome = try makeCodexHome()
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerCache")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
        }
        let sessionID = "019eaaaa-bbbb-cccc-dddd-eeeeffffffff"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()

        let lines = [
            turnContextLine(timestamp: now.addingTimeInterval(-140), model: "gpt-5.6-sol"),
            messageLine(timestamp: now.addingTimeInterval(-130), type: "user_message", message: "First question"),
            messageLine(timestamp: now.addingTimeInterval(-120), type: "agent_message", message: "First answer"),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-110),
                total: Usage(input: 100, cachedInput: 40, output: 20, reasoning: 5, total: 120),
                last: Usage(input: 100, cachedInput: 40, output: 20, reasoning: 5, total: 120)
            ),
            turnContextLine(timestamp: now.addingTimeInterval(-90), model: "gpt-5.6-terra"),
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
        let exactDatabase = SQLiteDatabaseDriver(
            url: try exactUsageDatabaseURL(in: cacheRoot)
        )

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
        XCTAssertEqual(
            Set(snapshot.cacheUsage.modelBreakdowns.compactMap(\.model)),
            ["gpt-5.6-sol", "gpt-5.6-terra"]
        )
        XCTAssertEqual(
            snapshot.cacheUsage.modelBreakdowns.reduce(0) { $0 + $1.breakdown.calls },
            2
        )
        XCTAssertTrue(snapshot.cacheUsage.attributionEventsComplete)
        XCTAssertEqual(
            snapshot.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.calls
            },
            2
        )
        XCTAssertEqual(
            Set(snapshot.cacheUsage.attributionEvents.compactMap(\.model)),
            ["gpt-5.6-sol", "gpt-5.6-terra"]
        )
        XCTAssertEqual(
            Set(try exactDatabase.readRows(
                "SELECT DISTINCT model FROM events WHERE model IS NOT NULL ORDER BY model;"
            ) { $0.text(0) }.compactMap { $0 }),
            ["gpt-5.6-sol", "gpt-5.6-terra"]
        )
        XCTAssertEqual(
            Set(try exactDatabase.readRows(
                "SELECT DISTINCT model FROM attribution_source_buckets WHERE model <> '' ORDER BY model;"
            ) { $0.text(0) }.compactMap { $0 }),
            ["gpt-5.6-sol", "gpt-5.6-terra"]
        )
        XCTAssertNotNil(snapshot.cacheUsage.attributionProvenanceEpoch)
        XCTAssertFalse(snapshot.cacheUsage.attributionSourceMutationDetected)
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

    func testExactHistoryIndexKeepsInterleavedSnapshotDedupeAcrossWarmRestart() throws {
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
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()

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

    func testRecentBinStartsStayOnEpochFiveMinuteBoundariesAcrossRefreshTimes() throws {
        let codexHome = try makeCodexHome()
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let alignedNow = Date(timeIntervalSince1970: 1_785_462_000)
        let event = TokenEvent(
            timestamp: alignedNow.addingTimeInterval(-60),
            sessionID: "stable-bin",
            tokens: 100,
            inputTokens: 80,
            cachedInputTokens: 20,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            userPrompt: "",
            assistantResponse: ""
        )

        let first = analyzer.recentBins(
            from: [event],
            now: alignedNow.addingTimeInterval(123)
        )
        let second = analyzer.recentBins(
            from: [event],
            now: alignedNow.addingTimeInterval(183)
        )
        let firstStart = try XCTUnwrap(first.first(where: { $0.calls > 0 })?.start)
        let secondStart = try XCTUnwrap(second.first(where: { $0.calls > 0 })?.start)

        XCTAssertEqual(firstStart, secondStart)
        XCTAssertEqual(firstStart.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
    }

    func testStreamingAggregationUsesTheSameStableRecentBucketKeysAcrossRefreshes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let alignedNow = Date(timeIntervalSince1970: 1_785_462_000)
        let event = TokenEvent(
            timestamp: alignedNow.addingTimeInterval(-60),
            sessionID: "stable-streaming-bin",
            tokens: 100,
            inputTokens: 80,
            cachedInputTokens: 20,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            userPrompt: "",
            assistantResponse: ""
        )

        var first = CodexUsageAnalyzer.UsageAggregationBuilder(
            calendar: calendar,
            now: alignedNow.addingTimeInterval(123)
        )
        first.consume(event, stableID: "first", turnIndexInSession: 1)
        let firstBins = first.recentBins()
        let firstStart = try XCTUnwrap(firstBins.first(where: { $0.calls > 0 })?.start)
        let firstCacheStart = try XCTUnwrap(
            first.cacheUsage(recentBins: firstBins, threadInfo: [:])
                .recentBins.first(where: { $0.breakdown.calls > 0 })?.start
        )

        var second = CodexUsageAnalyzer.UsageAggregationBuilder(
            calendar: calendar,
            now: alignedNow.addingTimeInterval(183)
        )
        second.consume(event, stableID: "second", turnIndexInSession: 1)
        let secondBins = second.recentBins()
        let secondStart = try XCTUnwrap(secondBins.first(where: { $0.calls > 0 })?.start)
        let secondCacheStart = try XCTUnwrap(
            second.cacheUsage(recentBins: secondBins, threadInfo: [:])
                .recentBins.first(where: { $0.breakdown.calls > 0 })?.start
        )

        XCTAssertEqual(firstStart, secondStart)
        XCTAssertEqual(firstCacheStart, firstStart)
        XCTAssertEqual(secondCacheStart, secondStart)
        XCTAssertEqual(firstStart.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
    }

    func testExactHistoryIndexIgnoresAndRemovesLegacyConversationCaches() throws {
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

        let cacheBytes = try cacheDataContents(under: swiftUsageCacheRoot(in: cacheRoot))
        XCTAssertNil(cacheBytes.range(of: Data(secretQuestion.utf8)))
        XCTAssertNil(cacheBytes.range(of: Data(secretAnswer.utf8)))
        XCTAssertNil(cacheBytes.range(of: Data("legacy secret question".utf8)))
        XCTAssertNil(cacheBytes.range(of: Data("legacy secret answer".utf8)))

        UsageCacheLifecycle.markCurrentCachePrepared()
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

    func testPreciseJSONLScanIncludesArchivedSessionsOutsideActiveState() throws {
        let codexHome = try makeCodexHome()
        let activeFile = try writeTokenCountRollout(
            in: codexHome.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "019eaaaa-bbbb-cccc-dddd-activehistory",
            timestamp: Date().addingTimeInterval(-60),
            totalTokens: 120
        )
        let archivedRoot = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        let archivedFile = try writeTokenCountRollout(
            in: archivedRoot,
            sessionID: "019eaaaa-bbbb-cccc-dddd-archivedhistory",
            timestamp: Date().addingTimeInterval(-30),
            totalTokens: 30
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let files = try analyzer.usageJSONLFiles()
        let snapshot = try analyzer.load()

        XCTAssertEqual(
            files.map { $0.resolvingSymlinksInPath().path },
            [activeFile, archivedFile].map { $0.resolvingSymlinksInPath().path }.sorted()
        )
        XCTAssertEqual(snapshot.stats.totalTokens, 150)
        XCTAssertEqual(snapshot.stats.totalCalls, 2)
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

    func testDeepSessionHistoryIsDiscoveredWithoutATraversalDepthCeiling() throws {
        let codexHome = try makeCodexHome()
        var directory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        for index in 0..<80 {
            directory.appendPathComponent("level-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let sessionID = "019faaaa-bbbb-cccc-dddd-deep-history"
        let sessionFile = directory.appendingPathComponent("2026-07-24-\(sessionID).jsonl")
        try tokenCountLine(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            total: Usage(input: 321, cachedInput: 0, output: 0, reasoning: 0, total: 321),
            last: Usage(input: 321, cachedInput: 0, output: 0, reasoning: 0, total: 321)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertTrue(try analyzer.usageJSONLFiles().contains(sessionFile))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 321)
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
            attributionProvenanceEpoch: "test-epoch",
            attributionGeneration: 1,
            now: Date(timeIntervalSince1970: 1_782_000_000),
            timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!
        )
        let after = analyzer.sessionTreeSignature(
            for: files,
            attributionProvenanceEpoch: "test-epoch",
            attributionGeneration: 1,
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

    func testExplicitSubagentForkCountsAfterChildTurnContextAndKeepsModel() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-subagent-boundary"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            explicitSubagentSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            explicitSubagentSessionMetaLine(
                timestamp: forkedAt.addingTimeInterval(0.2),
                sessionID: "inherited-parent-meta-1"
            ),
            explicitSubagentSessionMetaLine(
                timestamp: forkedAt.addingTimeInterval(0.3),
                sessionID: "inherited-parent-meta-2"
            ),
            spacedMessageLine(timestamp: forkedAt, type: "user_message", message: "Child task"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.5),
                total: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120)
            ),
            // Inherited parent turn_context rows are replayed too and must not
            // end the fork filter.
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            turnContextLine(timestamp: forkedAt.addingTimeInterval(0.8), model: "gpt-5.6-sol"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(1.1),
                total: Usage(input: 130, cachedInput: 85, output: 25, reasoning: 0, total: 150),
                last: Usage(input: 30, cachedInput: 5, output: 5, reasoning: 0, total: 30)
            ),
            turnContextLine(timestamp: forkedAt.addingTimeInterval(1.2), model: "gpt-5.6-sol"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(1.5),
                total: Usage(input: 160, cachedInput: 90, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            ),
            turnContextLine(timestamp: forkedAt.addingTimeInterval(5.6), model: "gpt-5.6-luna"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(6),
                total: Usage(input: 200, cachedInput: 100, output: 40, reasoning: 0, total: 260),
                last: Usage(input: 40, cachedInput: 10, output: 10, reasoning: 0, total: 60)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let synchronize: () throws -> CodexUsageHistoryIndex.SynchronizationResult = {
            try index.synchronize(
                files: [sessionFile],
                sessionID: analyzer.sessionID(from:)
            ) { file, parsedSessionID, request, insertFingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: parsedSessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
        }
        _ = try synchronize()
        var firstEvents: [TokenEvent] = []
        try index.forEachStoredEvent { firstEvents.append($0.event) }
        XCTAssertEqual(firstEvents.map(\.tokens), [60])
        XCTAssertEqual(firstEvents.first?.model, "gpt-5.6-luna")

        try appendLines([
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(7),
                total: Usage(input: 250, cachedInput: 110, output: 50, reasoning: 0, total: 320),
                last: Usage(input: 50, cachedInput: 10, output: 10, reasoning: 0, total: 60)
            )
        ], to: sessionFile)

        _ = try synchronize()
        var secondEvents: [TokenEvent] = []
        try index.forEachStoredEvent { secondEvents.append($0.event) }
        XCTAssertEqual(secondEvents.map(\.tokens), [60, 60])
        XCTAssertEqual(secondEvents.map(\.model), ["gpt-5.6-luna", "gpt-5.6-luna"])
    }

    func testExplicitSubagentForkPersistsReplayIdentityAcrossIncrementalAppend() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-subagent-incremental"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let forkedAt = Date()
        try [
            explicitSubagentSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.5),
                total: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(
            to: sessionFile,
            atomically: true,
            encoding: .utf8
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let synchronize: () throws -> CodexUsageHistoryIndex.SynchronizationResult = {
            try index.synchronize(
                files: [sessionFile],
                sessionID: analyzer.sessionID(from:)
            ) { file, parsedSessionID, request, insertFingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: parsedSessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
        }

        let first = try synchronize()
        XCTAssertEqual(first.indexedEvents, 0)
        XCTAssertEqual(first.incrementallyParsedFiles, 0)

        try appendLines([
            explicitSubagentSessionMetaLine(
                timestamp: forkedAt.addingTimeInterval(0.8),
                sessionID: "inherited-parent-meta-1"
            ),
            explicitSubagentSessionMetaLine(
                timestamp: forkedAt.addingTimeInterval(0.9),
                sessionID: "inherited-parent-meta-2"
            ),
            turnContextLine(
                timestamp: forkedAt.addingTimeInterval(1),
                model: "gpt-5.6-sol"
            ),
            turnContextLine(
                timestamp: forkedAt.addingTimeInterval(1.2),
                model: "gpt-5.6-sol"
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(1.5),
                total: Usage(input: 130, cachedInput: 85, output: 25, reasoning: 0, total: 150),
                last: Usage(input: 30, cachedInput: 5, output: 5, reasoning: 0, total: 30)
            ),
            turnContextLine(
                timestamp: forkedAt.addingTimeInterval(5),
                model: "gpt-5.6-luna"
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(6),
                total: Usage(input: 190, cachedInput: 95, output: 35, reasoning: 0, total: 230),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ], to: sessionFile)

        let second = try synchronize()
        XCTAssertEqual(second.incrementallyParsedFiles, 1)
        var events: [TokenEvent] = []
        try index.forEachStoredEvent { events.append($0.event) }
        XCTAssertEqual(events.map(\.tokens), [80])
        XCTAssertEqual(events.first?.model, "gpt-5.6-luna")
    }

    func testOrdinaryForkTurnContextDoesNotEndReplay() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)
        let sessionID = "019eaaaa-bbbb-cccc-dddd-ordinary-fork-boundary"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let forkedAt = Date()

        let lines = [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.5),
                total: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120)
            ),
            turnContextLine(timestamp: forkedAt.addingTimeInterval(1), model: "gpt-5.6-sol"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(1.5),
                total: Usage(input: 160, cachedInput: 90, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            ),
            spacedMessageLine(
                timestamp: forkedAt.addingTimeInterval(5.6),
                type: "user_message",
                message: "Actual prompt"
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(5.7),
                total: Usage(input: 210, cachedInput: 100, output: 50, reasoning: 0, total: 250),
                last: Usage(input: 30, cachedInput: 10, output: 10, reasoning: 0, total: 50)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let snapshot = try analyzer.load()

        XCTAssertEqual(snapshot.stats.totalTokens, 50)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
        XCTAssertEqual(snapshot.cacheUsage.modelBreakdowns.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.cacheUsage.modelBreakdowns.first?.breakdown.totalTokens, 50)
    }

    func testOrdinaryForkDoesNotPersistAnExplicitReplayBoundaryAcrossIncrementalAppend() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-ordinary-incremental"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let forkedAt = Date()
        try [
            spacedSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.5),
                total: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(
            to: sessionFile,
            atomically: true,
            encoding: .utf8
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let synchronize: () throws -> CodexUsageHistoryIndex.SynchronizationResult = {
            try index.synchronize(
                files: [sessionFile],
                sessionID: analyzer.sessionID(from:)
            ) { file, parsedSessionID, request, insertFingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: parsedSessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
        }

        _ = try synchronize()
        try appendLines([
            turnContextLine(
                timestamp: forkedAt.addingTimeInterval(1),
                model: "gpt-5.6-sol"
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(1.5),
                total: Usage(input: 160, cachedInput: 90, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ], to: sessionFile)

        let second = try synchronize()
        XCTAssertEqual(second.incrementallyParsedFiles, 1)
        var events: [TokenEvent] = []
        try index.forEachStoredEvent { events.append($0.event) }
        XCTAssertTrue(events.isEmpty)
    }

    func testForkedSessionReplayExitGraceBoundaryIsStrictlyGreaterThanTwoSeconds() throws {
        // 跨端契约（review §3.10 4b）：恰好等于 2s 宽限的 user_message 仍视为重放，
        // 严格大于 2s 才退出——与 Rust FORK_REPLAY_EXIT_GRACE 的 `>` 语义一致。
        let atBoundaryHome = try makeCodexHome()
        try seedStateDatabase(at: atBoundaryHome)
        let atID = "019eaaaa-bbbb-cccc-dddd-forkgraceat"
        let atFile = atBoundaryHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(atID).jsonl")
        let atLines = [
            rawForkedSessionMetaLine(timestamp: "2026-06-18T01:00:00Z", sessionID: atID),
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:10Z",
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            rawMessageLine(timestamp: "2026-06-18T01:00:12Z", type: "user_message", message: "Boundary prompt"),
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:13Z",
                total: Usage(input: 160, cachedInput: 10, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ]
        try atLines.joined(separator: "\n").appending("\n").write(to: atFile, atomically: true, encoding: .utf8)

        let atSnapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: atBoundaryHome)).load()
        XCTAssertEqual(atSnapshot.stats.totalTokens, 0, "恰好 2s 仍在宽限内，必须继续按重放跳过")
        XCTAssertEqual(atSnapshot.stats.totalCalls, 0)

        let pastBoundaryHome = try makeCodexHome()
        try seedStateDatabase(at: pastBoundaryHome)
        let pastID = "019eaaaa-bbbb-cccc-dddd-forkgracepast"
        let pastFile = pastBoundaryHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(pastID).jsonl")
        let pastLines = [
            rawForkedSessionMetaLine(timestamp: "2026-06-18T01:00:00Z", sessionID: pastID),
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:10Z",
                total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
            ),
            rawMessageLine(timestamp: "2026-06-18T01:00:12.001Z", type: "user_message", message: "Just past boundary prompt"),
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:13Z",
                total: Usage(input: 160, cachedInput: 10, output: 30, reasoning: 0, total: 200),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 80)
            )
        ]
        try pastLines.joined(separator: "\n").appending("\n").write(to: pastFile, atomically: true, encoding: .utf8)

        let pastSnapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: pastBoundaryHome)).load()
        XCTAssertEqual(pastSnapshot.stats.totalTokens, 80, "超过 2s 必须退出重放并正常计费")
        XCTAssertEqual(pastSnapshot.stats.totalCalls, 1)
    }

    func testSnapshotsDifferingOnlyInReasoningTokensAreDistinctEvents() throws {
        // 跨端契约（review §3.10 4a）：与 Rust 统一为 11 字段指纹，仅 reasoning
        // 不同的两条 snapshot 是两次独立计费，不得判为重放丢弃。
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-reasonfp"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let lines = [
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:00Z",
                total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
            ),
            rawTokenCountLine(
                timestamp: "2026-06-18T01:00:05Z",
                total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 7, total: 120),
                last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 7, total: 120)
            )
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalTokens, 240)
        XCTAssertEqual(snapshot.stats.totalCalls, 2)
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

    func testPreciseJSONLScanRebuildsAChangedSourceExactly() throws {
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
    }

    func testExactHistoryIndexRollsBackWhenSourceIsRewrittenDuringStreamingScan() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-changing"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        _ = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        try tokenCountLine(
            timestamp: now.addingTimeInterval(-30),
            total: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        let replacementDuringParse = try tokenCountLine(
            timestamp: now.addingTimeInterval(-5),
            total: Usage(input: 80, cachedInput: 0, output: 10, reasoning: 0, total: 90),
            last: Usage(input: 80, cachedInput: 0, output: 10, reasoning: 0, total: 90)
        ).appending("\n")

        XCTAssertThrowsError(
            try index.synchronize(
                files: [sessionFile],
                sessionID: analyzer.sessionID(from:)
            ) { file, parsedSessionID, request, insertFingerprint, emit in
                let result = try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: parsedSessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
                try replacementDuringParse.write(
                    to: file,
                    atomically: true,
                    encoding: .utf8
                )
                return result
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("发生变化"), error.localizedDescription)
        }

        var retainedTotal = 0
        try index.forEachStoredEvent { retainedTotal += $0.event.tokens }
        XCTAssertEqual(retainedTotal, 120)
    }

    func testExactHistoryIndexCommitsObservedPrefixWhenActiveSourceAppendsDuringScan() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-appending"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let appendedLine = try tokenCountLine(
            timestamp: now.addingTimeInterval(-10),
            total: Usage(input: 190, cachedInput: 20, output: 40, reasoning: 0, total: 230),
            last: Usage(input: 90, cachedInput: 20, output: 20, reasoning: 0, total: 110)
        )

        _ = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            let result = try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(appendedLine.appending("\n").utf8))
            try handle.close()
            return result
        }

        var observedPrefixTotal = 0
        try index.forEachStoredEvent { observedPrefixTotal += $0.event.tokens }
        XCTAssertEqual(observedPrefixTotal, 120)

        _ = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        var refreshedTotal = 0
        try index.forEachStoredEvent { refreshedTotal += $0.event.tokens }
        XCTAssertEqual(refreshedTotal, 230)
    }

    func testExactHistoryIndexAppendReadsOnlyTailChunkAndSuffix() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-byteappend"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        var source = Data(#"{"padding":""#.utf8)
        let mebibyte = Data(repeating: UInt8(ascii: "x"), count: 1_024 * 1_024)
        for _ in 0..<12 {
            source.append(mebibyte)
        }
        source.append(Data("\"}\n".utf8))
        source.append(
            Data(
                try tokenCountLine(
                    timestamp: now.addingTimeInterval(-60),
                    total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
                    last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
                ).appending("\n").utf8
            )
        )
        try source.write(to: sessionFile)
        let originalSize = UInt64(source.count)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        var coldRequests: [CodexUsageAnalyzer.IndexedSessionParseRequest] = []
        let cold = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            coldRequests.append(request)
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(cold.changedFiles, 1)
        XCTAssertEqual(cold.incrementallyParsedFiles, 0)
        XCTAssertEqual(coldRequests.map(\.hashingStartOffset), [0])
        XCTAssertEqual(coldRequests.map(\.endOffset), [originalSize])

        let appendedLine = try tokenCountLine(
            timestamp: now.addingTimeInterval(-10),
            total: Usage(input: 120, cachedInput: 25, output: 25, reasoning: 0, total: 150),
            last: Usage(input: 20, cachedInput: 5, output: 5, reasoning: 0, total: 30)
        )
        try appendLines([appendedLine], to: sessionFile)
        let refreshedSize = UInt64(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size] as? NSNumber
            ).uint64Value
        )

        var appendRequests: [CodexUsageAnalyzer.IndexedSessionParseRequest] = []
        let refreshed = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            appendRequests.append(request)
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        XCTAssertEqual(refreshed.incrementallyParsedFiles, 1)
        let request = try XCTUnwrap(appendRequests.first)
        XCTAssertEqual(request.parsingStartOffset, originalSize)
        XCTAssertLessThanOrEqual(
            request.endOffset - request.hashingStartOffset,
            4 * 1_024 * 1_024 + refreshedSize - originalSize
        )
        var total = 0
        try index.forEachStoredEvent { total += $0.event.tokens }
        XCTAssertEqual(total, 150)

        // 同一个增量事件再次出现在尾部时，持久指纹主键直接承担查重；
        // 不需要把该 source 的全部历史指纹复制到临时表。
        try appendLines([appendedLine], to: sessionFile)
        let duplicateRefresh = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(duplicateRefresh.incrementallyParsedFiles, 1)
        var deduplicatedTotal = 0
        try index.forEachStoredEvent { deduplicatedTotal += $0.event.tokens }
        XCTAssertEqual(deduplicatedTotal, 150)
    }

    func testExactHistoryIndexFallsBackToFullRebuildWhenOpenLineCrossesChunkBoundary() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-crossbound"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let firstLine = try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        )
        let secondLine = try tokenCountLine(
            timestamp: now.addingTimeInterval(-10),
            total: Usage(input: 120, cachedInput: 25, output: 25, reasoning: 0, total: 150),
            last: Usage(input: 20, cachedInput: 5, output: 5, reasoning: 0, total: 30)
        )
        let chunkSize = 4 * 1_024 * 1_024
        // 未完成的第二条 token 行行首落在首块内、行尾越过 4 MiB 块边界：
        // 检查点的续扫位置（行首）< 尾块起点，续扫不变量无法满足。
        var source = Data((firstLine + "\n").utf8)
        let openLineStart = chunkSize - 100
        let padPrefix = Data(#"{"padding":""#.utf8)
        let padSuffix = Data("\"}\n".utf8)
        let padBody = openLineStart - source.count - padPrefix.count - padSuffix.count
        source.append(padPrefix)
        source.append(Data(repeating: UInt8(ascii: "x"), count: padBody))
        source.append(padSuffix)
        let secondData = Data(secondLine.utf8)
        let split = 150
        source.append(secondData.prefix(split))
        try source.write(to: sessionFile)
        XCTAssertGreaterThan(source.count, chunkSize)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let cold = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(cold.changedFiles, 1)

        // 补完该行：修复前第二轮同步在这里抛错且每轮复现，精确统计永久停摆。
        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: secondData.suffix(secondData.count - split))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        var appendRequests: [CodexUsageAnalyzer.IndexedSessionParseRequest] = []
        let refreshed = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            appendRequests.append(request)
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(
            refreshed.incrementallyParsedFiles,
            0,
            "跨块未完成行必须回退全量重建，不能走追加路径"
        )
        XCTAssertEqual(refreshed.changedFiles, 1)
        XCTAssertEqual(
            appendRequests.map(\.hashingStartOffset),
            [0],
            "全量重建必须从文件头重新 hash"
        )
        var total = 0
        try index.forEachStoredEvent { total += $0.event.tokens }
        XCTAssertEqual(total, 150)
    }

    func testExactHistoryIndexRollingAuditRebuildsAfterMiddleRewriteAndAppend() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-auditappend"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let originalLine = try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        )
        var source = Data(originalLine.appending("\n").utf8)
        source.append(Data(#"{"padding":""#.utf8))
        let mebibyte = Data(repeating: UInt8(ascii: "z"), count: 1_024 * 1_024)
        for _ in 0..<9 {
            source.append(mebibyte)
        }
        source.append(Data("\"}\n".utf8))
        try source.write(to: sessionFile)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        XCTAssertFalse(initial.cacheUsage.attributionSourceMutationDetected)
        let initialProvenanceEpoch = try XCTUnwrap(
            initial.cacheUsage.attributionProvenanceEpoch
        )
        let before = try String(contentsOf: sessionFile, encoding: .utf8)
        let rewritten = before.replacingOccurrences(
            of: "\"total_tokens\":120",
            with: "\"total_tokens\":121"
        )
        XCTAssertEqual(before.utf8.count, rewritten.utf8.count)
        try rewritten.write(to: sessionFile, atomically: false, encoding: .utf8)
        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 120, cachedInput: 25, output: 25, reasoning: 0, total: 151),
                last: Usage(input: 20, cachedInput: 5, output: 5, reasoning: 0, total: 30)
            )
        ], to: sessionFile)

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let refreshed = try analyzer.load()

        XCTAssertEqual(refreshed.stats.totalTokens, 151)
        XCTAssertEqual(refreshed.stats.totalCalls, 2)
        XCTAssertTrue(refreshed.cacheUsage.attributionSourceMutationDetected)
        XCTAssertNotEqual(
            refreshed.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 0)
    }

    func testExactHistoryIndexColdBuildParsesMultipleFilesConcurrently() throws {
        let codexHome = try makeCodexHome()
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        var files: [URL] = []
        for index in 0..<4 {
            let sessionID = "019eaaaa-bbbb-cccc-dddd-parallel\(index)"
            let file = sessions.appendingPathComponent(
                "2026-06-17-\(sessionID).jsonl"
            )
            try tokenCountLine(
                timestamp: Date().addingTimeInterval(TimeInterval(index)),
                total: Usage(
                    input: 100 + index,
                    cachedInput: 0,
                    output: 20,
                    reasoning: 0,
                    total: 120 + index
                ),
                last: Usage(
                    input: 100 + index,
                    cachedInput: 0,
                    output: 20,
                    reasoning: 0,
                    total: 120 + index
                )
            ).appending("\n").write(
                to: file,
                atomically: true,
                encoding: .utf8
            )
            files.append(file)
        }
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let probe = ConcurrentParserProbe()

        let result = try index.synchronize(
            files: files,
            sessionID: analyzer.sessionID(from:)
        ) { file, sessionID, request, insertFingerprint, emit in
            probe.enter()
            defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.05)
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: sessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        XCTAssertEqual(result.changedFiles, 4)
        XCTAssertGreaterThanOrEqual(probe.peak, 2)
        var total = 0
        try index.forEachStoredEvent { total += $0.event.tokens }
        XCTAssertEqual(total, 120 + 121 + 122 + 123)
    }

    func testExactHistoryIndexReusesCompletedStagingAfterInterruptedImport() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerStageRecovery")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-stagerecover"
        let file = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let secretPrompt = "staging secret prompt 314159"
        let secretAnswer = "staging secret answer 271828"
        try [
            messageLine(
                timestamp: now.addingTimeInterval(-80),
                type: "user_message",
                message: secretPrompt
            ),
            messageLine(
                timestamp: now.addingTimeInterval(-70),
                type: "agent_message",
                message: secretAnswer
            ),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
            )
        ].joined(separator: "\n").appending("\n").write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let parseCount = ThreadSafeCounter()
        let parser: CodexUsageHistoryIndex.SessionParser = {
            file, parsedSessionID, request, insertFingerprint, emit in
            parseCount.increment()
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        let interrupted = try CodexUsageHistoryIndex(codexHome: codexHome)
        CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()

        XCTAssertThrowsError(
            try interrupted.synchronize(
                files: [file],
                sessionID: analyzer.sessionID(from:),
                parser: parser
            )
        )
        XCTAssertEqual(parseCount.value, 1)
        let stagedCache = try cacheDataContents(under: swiftUsageCacheRoot(in: cacheRoot))
        XCTAssertNil(stagedCache.range(of: Data(secretPrompt.utf8)))
        XCTAssertNil(stagedCache.range(of: Data(secretAnswer.utf8)))

        let resumed = try CodexUsageHistoryIndex(codexHome: codexHome)
        let result = try resumed.synchronize(
            files: [file],
            sessionID: analyzer.sessionID(from:),
            parser: parser
        )

        XCTAssertEqual(result.changedFiles, 1)
        XCTAssertEqual(parseCount.value, 1)
        var total = 0
        try resumed.forEachStoredEvent { total += $0.event.tokens }
        XCTAssertEqual(total, 120)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: swiftUsageCacheRoot(in: cacheRoot)
                    .appendingPathComponent("staging", isDirectory: true)
                    .path
            )
        )
    }

    func testExactHistoryIndexKeepsInterruptedStagesIsolatedAcrossCodexHomes() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerStageIsolation")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let firstHome = try makeCodexHome()
        let secondHome = try makeCodexHome()
        let firstSessionID = "019eaaaa-bbbb-cccc-dddd-stagehomeone"
        let secondSessionID = "019eaaaa-bbbb-cccc-dddd-stagehometwo"
        let firstFile = firstHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(firstSessionID).jsonl")
        let secondFile = secondHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(secondSessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-30),
            total: Usage(input: 50, cachedInput: 10, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 10, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: secondFile, atomically: true, encoding: .utf8)

        let firstAnalyzer = CodexUsageAnalyzer(dataSource: dataSource(for: firstHome))
        let secondAnalyzer = CodexUsageAnalyzer(dataSource: dataSource(for: secondHome))
        let firstParseCount = ThreadSafeCounter()
        let firstParser: CodexUsageHistoryIndex.SessionParser = {
            file, parsedSessionID, request, insertFingerprint, emit in
            firstParseCount.increment()
            return try firstAnalyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        let secondParser: CodexUsageHistoryIndex.SessionParser = {
            file, parsedSessionID, request, insertFingerprint, emit in
            try secondAnalyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        let interruptedFirst = try CodexUsageHistoryIndex(codexHome: firstHome)
        CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()
        XCTAssertThrowsError(
            try interruptedFirst.synchronize(
                files: [firstFile],
                sessionID: firstAnalyzer.sessionID(from:),
                parser: firstParser
            )
        )
        XCTAssertEqual(firstParseCount.value, 1)

        let completedSecond = try CodexUsageHistoryIndex(codexHome: secondHome)
        _ = try completedSecond.synchronize(
            files: [secondFile],
            sessionID: secondAnalyzer.sessionID(from:),
            parser: secondParser
        )

        let resumedFirst = try CodexUsageHistoryIndex(codexHome: firstHome)
        let resumedResult = try resumedFirst.synchronize(
            files: [firstFile],
            sessionID: firstAnalyzer.sessionID(from:),
            parser: firstParser
        )

        XCTAssertEqual(resumedResult.changedFiles, 1)
        XCTAssertEqual(
            firstParseCount.value,
            1,
            "Cleaning another Codex Home must not discard this index's durable stage"
        )
        var total = 0
        try resumedFirst.forEachStoredEvent { total += $0.event.tokens }
        XCTAssertEqual(total, 120)
    }

    func testExactHistoryIndexReleasesUnusedOperationGates() throws {
        let baseline = CodexUsageHistoryIndex.liveOperationGateCountForTesting()
        let codexHome = try makeCodexHome()

        let countWhileRetained = try autoreleasepool {
            let index = try CodexUsageHistoryIndex(codexHome: codexHome)
            return withExtendedLifetime(index) {
                CodexUsageHistoryIndex.liveOperationGateCountForTesting()
            }
        }

        XCTAssertEqual(countWhileRetained, baseline + 1)
        XCTAssertEqual(
            CodexUsageHistoryIndex.liveOperationGateCountForTesting(),
            baseline
        )
    }

    func testExactHistoryIndexSerializesConcurrentGenerationThroughAggregationAndRefreshesActiveAppend() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerConcurrentGeneration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let firstSessionID = "019eaaaa-bbbb-cccc-dddd-concurrent1"
        let secondSessionID = "019eaaaa-bbbb-cccc-dddd-concurrent2"
        let firstFile = sessionsRoot.appendingPathComponent("2026-06-17-\(firstSessionID).jsonl")
        let secondFile = sessionsRoot.appendingPathComponent("2026-06-17-\(secondSessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-50),
            total: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 0, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: secondFile, atomically: true, encoding: .utf8)

        let files = [firstFile, secondFile]
        let firstWorker = try ConcurrentUsageIndexWorker(codexHome: codexHome, files: files)
        let secondWorker = try ConcurrentUsageIndexWorker(codexHome: codexHome, files: files)
        let parserReachedSecondFile = DispatchSemaphore(value: 0)
        let releaseParser = DispatchSemaphore(value: 0)
        let firstSynchronizationFinished = DispatchSemaphore(value: 0)
        let releaseFirstAggregation = DispatchSemaphore(value: 0)
        let secondAttemptedExclusiveAccess = DispatchSemaphore(value: 0)
        let secondEnteredExclusiveAccess = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let firstResult = ConcurrentUsageIndexResultBox()
        let secondResult = ConcurrentUsageIndexResultBox()
        defer {
            releaseParser.signal()
            releaseFirstAggregation.signal()
        }

        DispatchQueue(label: "CodexUsageAnalyzerTests.concurrentGeneration.first").async {
            firstResult.set(Result {
                try firstWorker.synchronizeAndReadTotal(
                    parserGateFile: secondFile,
                    parserReachedGate: parserReachedSecondFile,
                    releaseParser: releaseParser,
                    synchronizationFinished: firstSynchronizationFinished,
                    releaseAggregation: releaseFirstAggregation
                )
            })
            firstCompleted.signal()
        }

        XCTAssertEqual(parserReachedSecondFile.wait(timeout: .now() + 5), .success)
        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 190, cachedInput: 20, output: 40, reasoning: 0, total: 230),
                last: Usage(input: 90, cachedInput: 20, output: 20, reasoning: 0, total: 110)
            )
        ], to: firstFile)
        releaseParser.signal()
        XCTAssertEqual(firstSynchronizationFinished.wait(timeout: .now() + 5), .success)

        DispatchQueue(label: "CodexUsageAnalyzerTests.concurrentGeneration.second").async {
            secondAttemptedExclusiveAccess.signal()
            secondResult.set(Result {
                try secondWorker.synchronizeAndReadTotal(
                    exclusiveAccessEntered: secondEnteredExclusiveAccess
                )
            })
            secondCompleted.signal()
        }

        XCTAssertEqual(secondAttemptedExclusiveAccess.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(
            CodexUsageHistoryIndex.waitForExclusiveAccessWaiterForTesting(
                codexHome: codexHome,
                timeout: 5
            ),
            "The second refresh never reached the per-index single-flight gate"
        )
        XCTAssertEqual(secondEnteredExclusiveAccess.wait(timeout: .now()), .timedOut)

        releaseFirstAggregation.signal()
        XCTAssertEqual(firstCompleted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondEnteredExclusiveAccess.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 5), .success)

        let firstObservation = try XCTUnwrap(firstResult.get()).get()
        let secondObservation = try XCTUnwrap(secondResult.get()).get()
        XCTAssertEqual(firstObservation.totalTokens, 180)
        XCTAssertEqual(firstObservation.synchronization.changedFiles, 2)
        XCTAssertEqual(secondObservation.totalTokens, 290)
        XCTAssertEqual(secondObservation.synchronization.changedFiles, 1)
        XCTAssertEqual(secondObservation.synchronization.unchangedFiles, 1)

        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let finalState = try XCTUnwrap(
            database.readRows(
                """
                SELECT
                    COUNT(*),
                    COUNT(DISTINCT last_seen_generation),
                    (SELECT COUNT(*) FROM events),
                    (SELECT SUM(tokens) FROM events)
                FROM sources;
                """
            ) {
                (
                    sourceCount: $0.int(0),
                    generationCount: $0.int(1),
                    eventCount: $0.int(2),
                    totalTokens: $0.int(3)
                )
            }.first
        )
        XCTAssertEqual(finalState.sourceCount, 2)
        XCTAssertEqual(finalState.generationCount, 1)
        XCTAssertEqual(finalState.eventCount, 3)
        XCTAssertEqual(finalState.totalTokens, 290)
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
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let initialProvenanceEpoch = try XCTUnwrap(
            initial.cacheUsage.attributionProvenanceEpoch
        )

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
        XCTAssertFalse(afterDelete.cacheUsage.attributionSourceMutationDetected)
        XCTAssertEqual(
            afterDelete.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
    }

    func testDeletedSourceIdentityIsNeverReusedWithinAProvenanceEpoch() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerSourceSequence")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let firstFile = sessionsRoot.appendingPathComponent("first-source.jsonl")
        let secondFile = sessionsRoot.appendingPathComponent("second-source.jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 0, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let firstSnapshot = try analyzer.load()
        let firstEpoch = try XCTUnwrap(firstSnapshot.cacheUsage.attributionProvenanceEpoch)
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let firstSourceID = try XCTUnwrap(
            database.readRows("SELECT source_id FROM sources LIMIT 1;") {
                $0.int64(0)
            }.compactMap { $0 }.first
        )

        try FileManager.default.removeItem(at: firstFile)
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-30),
            total: Usage(input: 200, cachedInput: 0, output: 40, reasoning: 0, total: 240),
            last: Usage(input: 200, cachedInput: 0, output: 40, reasoning: 0, total: 240)
        ).appending("\n").write(to: secondFile, atomically: true, encoding: .utf8)
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        let secondSnapshot = try analyzer.load()
        let secondSourceID = try XCTUnwrap(
            database.readRows("SELECT source_id FROM sources LIMIT 1;") {
                $0.int64(0)
            }.compactMap { $0 }.first
        )

        XCTAssertGreaterThan(secondSourceID, firstSourceID)
        XCTAssertEqual(secondSnapshot.cacheUsage.attributionProvenanceEpoch, firstEpoch)
        XCTAssertFalse(secondSnapshot.cacheUsage.attributionSourceMutationDetected)
        XCTAssertEqual(
            secondSnapshot.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.totalTokens
            },
            360
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(DISTINCT source_lineage) FROM attribution_source_buckets;",
                in: database
            ),
            2
        )
    }

    func testCompactSynchronizationPersistsSourceBucketsBeforeSourceDeletion() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerCompactLedger")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000001"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let first = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        try FileManager.default.removeItem(at: sessionFile)
        let removed = try index.synchronize(
            files: [],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        let retained = try index.attributionSourceBuckets(
            provenanceEpoch: removed.provenanceEpoch,
            from: now.addingTimeInterval(-3_600),
            before: now.addingTimeInterval(300)
        )

        XCTAssertEqual(removed.removedFiles, 1)
        XCTAssertEqual(removed.provenanceEpoch, first.provenanceEpoch)
        XCTAssertGreaterThan(removed.attributionGeneration, first.attributionGeneration)
        XCTAssertEqual(retained.reduce(0) { $0 + $1.breakdown.totalTokens }, 120)
        XCTAssertEqual(retained.reduce(0) { $0 + $1.breakdown.calls }, 1)
    }

    func testExactHistoryCrossProcessContentionFailsBeforeSynchronizationWrites() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerCrossProcessLock")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-00000000000b"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let databaseURL = try exactUsageDatabaseURL(in: cacheRoot)
        let database = SQLiteDatabaseDriver(url: databaseURL)
        let generationBefore = try scalarInt(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
            in: database
        )
        let externalLock = try CodexCrossProcessFileLock(
            url: databaseURL.appendingPathExtension("operation.lock"),
            label: "测试精确历史索引"
        )

        XCTAssertThrowsError(
            try index.synchronize(
                files: [sessionFile],
                sessionID: analyzer.sessionID(from:)
            ) { file, parsedSessionID, request, insertFingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: parsedSessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
        ) { error in
            XCTAssertTrue(CodexCrossProcessFileLock.isContention(error))
        }
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), 0)
        XCTAssertEqual(
            try scalarInt(
                "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
                in: database
            ),
            generationBefore
        )

        externalLock.release()
        let retry = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(retry.changedFiles, 1)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), 1)
    }

    func testAttributionRevisionMigrationKeepsTombstonedLedgerUnsafeUntilAcknowledged() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerTombstoneMigration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000008"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        _ = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        try FileManager.default.removeItem(at: sessionFile)
        _ = try index.synchronize(
            files: [],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), 0)
        XCTAssertEqual(
            try scalarInt("SELECT COUNT(*) FROM attribution_source_buckets;", in: database),
            1
        )
        try database.execute(
            "UPDATE schema_meta SET value = 'legacy-ledger-v1' WHERE key = 'provenance_revision';"
        )

        let migrated = try CodexUsageHistoryIndex(codexHome: codexHome)
        let state = try migrated.attributionState()

        XCTAssertTrue(state.requiresSyntheticCutover)
        XCTAssertEqual(state.unsafeProvenanceEpoch, state.provenanceEpoch)
        XCTAssertNotNil(state.unsafeSinceGeneration)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), 0)
        XCTAssertEqual(
            try scalarInt("SELECT COUNT(*) FROM attribution_source_buckets;", in: database),
            0
        )
    }

    func testFutureSchemaFailsClosedWithoutRewritingTheIndex() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerFutureSchemaEvidence")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-00000000000a"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        _ = try index.synchronize(
            files: [sessionFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        try FileManager.default.removeItem(at: sessionFile)
        _ = try index.synchronize(
            files: [],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), 0)
        XCTAssertEqual(
            try scalarInt("SELECT COUNT(*) FROM attribution_source_buckets;", in: database),
            1
        )
        try database.execute(
            "UPDATE schema_meta SET value = '999' WHERE key = 'schema_version';"
        )

        let beforeEventCount = try scalarInt("SELECT COUNT(*) FROM events;", in: database)
        let beforeSourceCount = try scalarInt("SELECT COUNT(*) FROM sources;", in: database)
        let beforeLedgerCount = try scalarInt(
            "SELECT COUNT(*) FROM attribution_source_buckets;",
            in: database
        )
        let beforePublishedGeneration = try scalarInt(
            "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'published_generation'), 0);",
            in: database
        )
        XCTAssertThrowsError(try CodexUsageHistoryIndex(codexHome: codexHome)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("newer or unknown")
                    || error.localizedDescription.contains("schema")
            )
        }

        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), beforeEventCount)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM sources;", in: database), beforeSourceCount)
        XCTAssertEqual(
            try scalarInt("SELECT COUNT(*) FROM attribution_source_buckets;", in: database),
            beforeLedgerCount
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'schema_version';",
                in: database
            ),
            999
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'published_generation'), 0);",
                in: database
            ),
            beforePublishedGeneration
        )
    }

    func testDifferentCanonicalSessionReappearancePreservesTombstoneMaximumAndTurnsUnsafe() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerTombstoneReappearance")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000009"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let eventTimestamp = now.addingTimeInterval(-60)
        try tokenCountLine(
            timestamp: eventTimestamp,
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        let initialEpoch = try XCTUnwrap(initial.cacheUsage.attributionProvenanceEpoch)
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        try FileManager.default.removeItem(at: sessionFile)
        _ = try index.synchronize(
            files: [],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        try tokenCountLine(
            timestamp: eventTimestamp,
            total: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()

        let reappeared = try analyzer.load()

        XCTAssertEqual(reappeared.stats.totalTokens, 60)
        XCTAssertNotEqual(reappeared.cacheUsage.attributionProvenanceEpoch, initialEpoch)
        XCTAssertTrue(reappeared.cacheUsage.attributionSourceMutationDetected)
        XCTAssertNotNil(reappeared.cacheUsage.attributionUnsafeSinceGeneration)
        XCTAssertNotNil(reappeared.cacheUsage.attributionGeneration)
        XCTAssertEqual(
            reappeared.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.totalTokens
            },
            120
        )
        XCTAssertEqual(
            reappeared.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.calls
            },
            1
        )
    }

    func testFullSnapshotCacheGenerationSurvivesSessionTreeABA() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerTreeABA")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let originalID = "019eaaaa-bbbb-4ccc-8ddd-000000000002"
        let transientID = "019eaaaa-bbbb-4ccc-8ddd-000000000003"
        let originalFile = sessionsRoot.appendingPathComponent("2026-06-17-\(originalID).jsonl")
        let transientFile = sessionsRoot.appendingPathComponent("2026-06-17-\(transientID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-90),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: originalFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let initialGeneration = try scalarInt(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
            in: database
        )

        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: transientFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try analyzer.loadCompactSummary()?.totalTokens, 180)
        let seenGeneration = try scalarInt(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
            in: database
        )
        XCTAssertGreaterThan(seenGeneration, initialGeneration)

        try FileManager.default.removeItem(at: transientFile)
        XCTAssertEqual(try analyzer.loadCompactSummary()?.totalTokens, 120)
        let returnedGeneration = try scalarInt(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
            in: database
        )
        XCTAssertGreaterThan(returnedGeneration, seenGeneration)

        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let afterABA = try analyzer.load()
        XCTAssertEqual(afterABA.stats.totalTokens, 120)
        XCTAssertEqual(CodexUsageAnalyzer.preciseSnapshotBuildCountForTesting, 1)
        XCTAssertEqual(
            afterABA.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.totalTokens
            },
            180
        )
        XCTAssertEqual(
            afterABA.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.calls
            },
            2
        )
    }

    func testCanonicalSessionLineageReusesSourceAcrossExactPathMove() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerLineageMove")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let archiveRoot = sessionsRoot.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000004"
        let fileName = "2026-06-17-\(sessionID).jsonl"
        let originalFile = sessionsRoot.appendingPathComponent(fileName)
        let movedFile = archiveRoot.appendingPathComponent(fileName)
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: originalFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let initialSourceID = try XCTUnwrap(
            database.readRows("SELECT source_id FROM sources LIMIT 1;") {
                $0.int64(0)
            }.compactMap { $0 }.first
        )
        let initialEpoch = try XCTUnwrap(initial.cacheUsage.attributionProvenanceEpoch)

        try FileManager.default.moveItem(at: originalFile, to: movedFile)
        let moved = try analyzer.load()
        let movedSourceID = try XCTUnwrap(
            database.readRows("SELECT source_id FROM sources LIMIT 1;") {
                $0.int64(0)
            }.compactMap { $0 }.first
        )

        XCTAssertEqual(moved.stats.totalTokens, 120)
        XCTAssertEqual(movedSourceID, initialSourceID)
        XCTAssertEqual(moved.cacheUsage.attributionProvenanceEpoch, initialEpoch)
        XCTAssertFalse(moved.cacheUsage.attributionSourceMutationDetected)
        XCTAssertEqual(moved.cacheUsage.attributionEvents.count, 1)
        XCTAssertEqual(moved.cacheUsage.attributionEvents[0].breakdown.totalTokens, 120)
    }

    func testDuplicateCanonicalLineageRotatesEpochAndDoesNotDoubleLedger() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerDuplicateLineage")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let duplicateRoot = sessionsRoot.appendingPathComponent("duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateRoot, withIntermediateDirectories: true)
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000005"
        let fileName = "2026-06-17-\(sessionID).jsonl"
        let originalFile = sessionsRoot.appendingPathComponent(fileName)
        let duplicateFile = duplicateRoot.appendingPathComponent(fileName)
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: originalFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        let initialEpoch = try XCTUnwrap(initial.cacheUsage.attributionProvenanceEpoch)
        try FileManager.default.copyItem(at: originalFile, to: duplicateFile)

        let duplicate = try analyzer.load()

        XCTAssertNotEqual(duplicate.cacheUsage.attributionProvenanceEpoch, initialEpoch)
        XCTAssertTrue(duplicate.cacheUsage.attributionSourceMutationDetected)
        XCTAssertTrue(duplicate.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
        XCTAssertEqual(duplicate.cacheUsage.attributionEvents.count, 1)
        XCTAssertEqual(duplicate.cacheUsage.attributionEvents[0].breakdown.totalTokens, 120)
        XCTAssertEqual(duplicate.cacheUsage.attributionEvents[0].breakdown.calls, 1)

        let duplicateEpoch = try XCTUnwrap(
            duplicate.cacheUsage.attributionProvenanceEpoch
        )
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let repeated = try index.synchronize(
            files: [originalFile, duplicateFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(repeated.provenanceEpoch, duplicateEpoch)
        XCTAssertTrue(repeated.lineageAmbiguityDetected)
        XCTAssertTrue(repeated.attributionUnsafe)
        XCTAssertFalse(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: repeated.provenanceEpoch,
                throughGeneration: repeated.attributionGeneration
            ),
            "a persistent duplicate must stay pending instead of entering an ack/full-scan loop"
        )

        try FileManager.default.removeItem(at: duplicateFile)
        let recovered = try analyzer.load()
        XCTAssertEqual(recovered.cacheUsage.attributionProvenanceEpoch, duplicateEpoch)
        XCTAssertTrue(recovered.cacheUsage.attributionSourceMutationDetected)
        XCTAssertFalse(recovered.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
        XCTAssertTrue(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: duplicateEpoch,
                throughGeneration: try XCTUnwrap(
                    recovered.cacheUsage.attributionGeneration
                )
            )
        )
        let acknowledged = try analyzer.load()
        XCTAssertFalse(acknowledged.cacheUsage.attributionSourceMutationDetected)
        XCTAssertFalse(acknowledged.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
    }

    func testPersistentRewriteStaysPendingWithoutRotatingOrSelfTriggering() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerPersistentRewrite")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-000000000055"
        let sessionFile = sessionsRoot.appendingPathComponent(
            "2026-06-17-\(sessionID).jsonl"
        )
        let now = Date()

        func write(total: Int) throws {
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-60),
                total: Usage(
                    input: total - 20,
                    cachedInput: 10,
                    output: 20,
                    reasoning: 0,
                    total: total
                ),
                last: Usage(
                    input: total - 20,
                    cachedInput: 10,
                    output: 20,
                    reasoning: 0,
                    total: total
                )
            ).appending("\n").write(
                to: sessionFile,
                atomically: true,
                encoding: .utf8
            )
        }

        try write(total: 120)
        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        let initialEpoch = try XCTUnwrap(initial.cacheUsage.attributionProvenanceEpoch)

        try write(total: 140)
        let firstRewrite = try analyzer.load()
        let unsafeEpoch = try XCTUnwrap(
            firstRewrite.cacheUsage.attributionProvenanceEpoch
        )
        XCTAssertNotEqual(unsafeEpoch, initialEpoch)
        XCTAssertTrue(firstRewrite.cacheUsage.attributionCurrentScanUnsafeCauseDetected)

        try write(total: 160)
        let secondRewrite = try analyzer.load()
        XCTAssertEqual(secondRewrite.cacheUsage.attributionProvenanceEpoch, unsafeEpoch)
        XCTAssertTrue(secondRewrite.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
        XCTAssertFalse(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: unsafeEpoch,
                throughGeneration: try XCTUnwrap(
                    secondRewrite.cacheUsage.attributionGeneration
                )
            )
        )

        // No immediate ack-triggered scan is required. The next normal probe
        // sees the now-stable file, clears only the current-cause marker, and
        // leaves sticky unsafe state for the durable cutover acknowledgement.
        let stableProbe = try analyzer.load()
        XCTAssertEqual(stableProbe.cacheUsage.attributionProvenanceEpoch, unsafeEpoch)
        XCTAssertFalse(stableProbe.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
        XCTAssertTrue(stableProbe.cacheUsage.attributionSourceMutationDetected)
        let firstEpisodeGeneration = try XCTUnwrap(
            stableProbe.cacheUsage.attributionUnsafeSinceGeneration
        )

        // A later rewrite after a clean probe is a distinct unsafe episode in
        // the same sticky epoch. Its token must advance so an older pending or
        // ready recovery baseline cannot survive an A→clean→B ABA sequence.
        try write(total: 180)
        let secondEpisode = try analyzer.load()
        XCTAssertEqual(secondEpisode.cacheUsage.attributionProvenanceEpoch, unsafeEpoch)
        XCTAssertTrue(secondEpisode.cacheUsage.attributionCurrentScanUnsafeCauseDetected)
        let secondEpisodeGeneration = try XCTUnwrap(
            secondEpisode.cacheUsage.attributionUnsafeSinceGeneration
        )
        XCTAssertGreaterThan(secondEpisodeGeneration, firstEpisodeGeneration)
        let secondStableProbe = try analyzer.load()
        XCTAssertFalse(
            secondStableProbe.cacheUsage.attributionCurrentScanUnsafeCauseDetected
        )
        XCTAssertEqual(
            secondStableProbe.cacheUsage.attributionUnsafeSinceGeneration,
            secondEpisodeGeneration
        )
        XCTAssertTrue(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: unsafeEpoch,
                throughGeneration: try XCTUnwrap(
                    secondStableProbe.cacheUsage.attributionGeneration
                )
            )
        )
    }

    func testRewriteRotatesEpochRebuildsLineageAndCleansOldEpoch() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerRewriteEpoch")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let firstID = "019eaaaa-bbbb-4ccc-8ddd-000000000006"
        let secondID = "019eaaaa-bbbb-4ccc-8ddd-000000000007"
        let firstFile = sessionsRoot.appendingPathComponent("2026-06-17-\(firstID).jsonl")
        let secondFile = sessionsRoot.appendingPathComponent("2026-06-17-\(secondID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-90),
            total: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 10, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60),
            last: Usage(input: 50, cachedInput: 5, output: 10, reasoning: 0, total: 60)
        ).appending("\n").write(to: secondFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        let initialEpoch = try XCTUnwrap(initial.cacheUsage.attributionProvenanceEpoch)
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-30),
            total: Usage(input: 70, cachedInput: 5, output: 10, reasoning: 0, total: 80),
            last: Usage(input: 70, cachedInput: 5, output: 10, reasoning: 0, total: 80)
        ).appending("\n").write(to: firstFile, atomically: true, encoding: .utf8)

        let rewritten = try analyzer.load()
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))

        XCTAssertEqual(rewritten.stats.totalTokens, 140)
        XCTAssertNotEqual(rewritten.cacheUsage.attributionProvenanceEpoch, initialEpoch)
        XCTAssertTrue(rewritten.cacheUsage.attributionSourceMutationDetected)
        XCTAssertEqual(
            rewritten.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.totalTokens
            },
            140
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(DISTINCT provenance_epoch) FROM attribution_source_buckets;",
                in: database
            ),
            1
        )

        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        let unsafeState = try index.attributionState()
        XCTAssertTrue(unsafeState.requiresSyntheticCutover)
        XCTAssertEqual(
            rewritten.cacheUsage.attributionGeneration,
            unsafeState.generation
        )
        XCTAssertEqual(
            rewritten.cacheUsage.attributionUnsafeSinceGeneration,
            unsafeState.unsafeSinceGeneration
        )
        XCTAssertFalse(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: unsafeState.provenanceEpoch,
                throughGeneration: try XCTUnwrap(unsafeState.unsafeSinceGeneration) - 1
            )
        )
        let cachedWhileUnsafe = try analyzer.load()
        XCTAssertTrue(cachedWhileUnsafe.cacheUsage.attributionSourceMutationDetected)

        _ = try index.synchronize(
            files: [firstFile, secondFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        let advancedUnsafeState = try index.attributionState()
        XCTAssertEqual(advancedUnsafeState.provenanceEpoch, unsafeState.provenanceEpoch)
        XCTAssertGreaterThan(advancedUnsafeState.generation, unsafeState.generation)
        XCTAssertFalse(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: try XCTUnwrap(
                    rewritten.cacheUsage.attributionProvenanceEpoch
                ),
                throughGeneration: try XCTUnwrap(
                    rewritten.cacheUsage.attributionGeneration
                )
            )
        )

        XCTAssertTrue(
            try analyzer.acknowledgeAttributionSafety(
                provenanceEpoch: advancedUnsafeState.provenanceEpoch,
                throughGeneration: advancedUnsafeState.generation
            )
        )
        XCTAssertFalse(try index.attributionState().requiresSyntheticCutover)
        let afterAcknowledgement = try analyzer.load()
        XCTAssertFalse(afterAcknowledgement.cacheUsage.attributionSourceMutationDetected)
    }

    func testPersistentExactHistoryIndexDoesNotStoreConversationTextAndReusesUnchangedSources() throws {
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
        let sessionID = "019eaaaa-bbbb-cccc-dddd-indexprivacy"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let secretQuestion = "index secret prompt 821219"
        let secretAnswer = "index secret answer 197705"
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
        let cacheBytes = try cacheDataContents(under: cacheDirectory)
        XCTAssertNil(cacheBytes.range(of: Data(secretQuestion.utf8)))
        XCTAssertNil(cacheBytes.range(of: Data(secretAnswer.utf8)))
        XCTAssertNotNil(cacheBytes.range(of: Data("CREATE TABLE".utf8)))

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let reloaded = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(reloaded.stats.totalTokens, 140)
        XCTAssertEqual(reloaded.stats.totalCalls, 1)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
    }

    func testPersistentExactHistoryIndexRebuildsChangedSourceAndSkipsUnchangedSource() throws {
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
        let sessionID = "019eaaaa-bbbb-cccc-dddd-indexupdate"
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
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let initialProvenanceEpoch = try XCTUnwrap(
            initial.cacheUsage.attributionProvenanceEpoch
        )

        let databaseURL = try exactUsageDatabaseURL(in: cacheRoot)
        let database = SQLiteDatabaseDriver(url: databaseURL)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 1)

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let migrated = try analyzer.load()
        XCTAssertEqual(migrated.stats.totalTokens, 120)
        XCTAssertEqual(
            migrated.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)

        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 190, cachedInput: 50, output: 40, reasoning: 0, total: 230),
                last: Usage(input: 90, cachedInput: 20, output: 20, reasoning: 0, total: 110)
            )
        ], to: sessionFile)

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let updated = try analyzer.load()

        XCTAssertEqual(updated.stats.totalTokens, 230)
        XCTAssertEqual(updated.stats.totalCalls, 2)
        XCTAssertEqual(
            updated.cacheUsage.attributionEvents.reduce(0) {
                $0 + $1.breakdown.calls
            },
            2
        )
        XCTAssertEqual(updated.cacheUsage.attributionProvenanceEpoch, initialProvenanceEpoch)
        XCTAssertFalse(updated.cacheUsage.attributionSourceMutationDetected)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 1)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 2)

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 230)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 0)
    }

    func testPersistentExactHistoryIndexMigratesV2WithoutDiscardingEvents() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerV2Migration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-v2migration"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let initialProvenanceEpoch = try XCTUnwrap(
            initial.cacheUsage.attributionProvenanceEpoch
        )
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        try database.execute(
            "UPDATE schema_meta SET value = '2' WHERE key = 'schema_version';"
        )
        try database.execute(
            "UPDATE sources SET append_ready = 0, resume_offset = NULL;"
        )
        try database.execute("DROP TABLE source_chunks;")
        try database.execute("DROP TABLE source_fingerprints;")

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let migratedV2 = try analyzer.load()
        XCTAssertEqual(migratedV2.stats.totalTokens, 120)
        XCTAssertEqual(
            migratedV2.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 1)
        let schemaVersion = try XCTUnwrap(
            database.readRows(
                "SELECT value FROM schema_meta WHERE key = 'schema_version';"
            ) { $0.text(0) }.compactMap { $0 }.first
        )
        XCTAssertEqual(schemaVersion, "5")

        try appendLines([
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-10),
                total: Usage(input: 120, cachedInput: 25, output: 25, reasoning: 0, total: 150),
                last: Usage(input: 20, cachedInput: 5, output: 5, reasoning: 0, total: 30)
            )
        ], to: sessionFile)
        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 150)
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        XCTAssertEqual(CodexUsageAnalyzer.incrementalSessionParseCountForTesting, 0)
    }

    func testAttributionBackfillUsesCaseInsensitiveSourceIndexWithoutScanningEvents() throws {
        let sessionID = "019eaaaa-bbbb-4ccc-8ddd-0000000000ab"
        let canonicalLineage = "session:\(sessionID)"

        // GitHub's published schema v3 and the current schema v5 both migrate
        // in place. Dropping the new index before each reopen proves that the
        // normal schema path recreates it before attribution backfill runs.
        for schemaVersion in ["3", "5"] {
            let cacheRoot = try makeTemporaryDirectory(
                named: "CodexUsageAnalyzerAttributionIndex-\(schemaVersion)"
            )
            let databaseURL = cacheRoot.appendingPathComponent("usage-index.sqlite")
            do {
                _ = try CodexUsageHistoryIndex(
                    sessionCatalogTestingDatabaseURL: databaseURL
                )
            }
            let database = SQLiteDatabaseDriver(url: databaseURL)
            XCTAssertEqual(
                try scalarInt(
                    "SELECT COUNT(*) FROM pragma_index_list('sources') WHERE name = 'sources_session_nocase';",
                    in: database
                ),
                1,
                "fresh schema \(schemaVersion) must create the case-insensitive source index"
            )

            let uppercaseSessionID = sessionID.uppercased()
            try database.execute(
                """
                INSERT INTO sources(
                    source_id,
                    path,
                    session_id,
                    size_bytes,
                    modified_at,
                    content_probe,
                    device_id,
                    inode,
                    status_changed_seconds,
                    status_changed_nanoseconds,
                    last_seen_generation
                ) VALUES (?, ?, ?, 0, 0, '', '0', '0', 0, 0, 'attribution-index-test');
                """,
                bindings: [
                    .int64(1),
                    .text(cacheRoot.appendingPathComponent("uppercase.jsonl").path),
                    .text(uppercaseSessionID)
                ]
            )
            try database.execute(
                """
                INSERT INTO events(
                    source_id,
                    source_offset,
                    timestamp,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    model
                ) VALUES (?, 0, ?, 120, 100, 20, 20, 0, ?);
                """,
                bindings: [
                    .int64(1),
                    .double(1_700_000_000),
                    .text("gpt-5.6-sol")
                ]
            )

            try database.execute("DROP INDEX sources_session_nocase;")
            try database.execute(
                "UPDATE schema_meta SET value = ? WHERE key = 'schema_version';",
                bindings: [.text(schemaVersion)]
            )
            try database.execute(
                """
                UPDATE schema_meta SET value = 'legacy-attribution-index-test'
                    WHERE key = 'provenance_revision';
                """
            )

            _ = try CodexUsageHistoryIndex(
                sessionCatalogTestingDatabaseURL: databaseURL
            )

            XCTAssertEqual(
                try scalarInt(
                    "SELECT COUNT(*) FROM pragma_index_list('sources') WHERE name = 'sources_session_nocase';",
                    in: database
                ),
                1,
                "schema \(schemaVersion) migration must recreate the case-insensitive source index"
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    database.readRows(
                        "SELECT value FROM schema_meta WHERE key = 'schema_version';"
                    ) { $0.text(0) }.compactMap { $0 }.first
                ),
                "5"
            )

            let planDetails = try database.readRows(
                """
                EXPLAIN QUERY PLAN
                WITH per_source AS (
                    SELECT
                        e.source_id,
                        CAST(e.timestamp / 300 AS INTEGER) * 300 AS bucket_start,
                        COALESCE(e.model, '') AS model,
                        SUM(e.input_tokens) AS input_tokens,
                        SUM(e.cached_input_tokens) AS cached_input_tokens,
                        SUM(e.output_tokens) AS output_tokens,
                        SUM(e.reasoning_output_tokens) AS reasoning_output_tokens,
                        SUM(e.tokens) AS total_tokens,
                        COUNT(*) AS calls
                    FROM events e
                    JOIN sources s ON s.source_id = e.source_id
                    WHERE s.session_id COLLATE NOCASE = ?
                    GROUP BY
                        e.source_id,
                        CAST(e.timestamp / 300 AS INTEGER),
                        COALESCE(e.model, '')
                )
                SELECT * FROM per_source;
                """,
                bindings: [.text(sessionID)]
            ) { $0.text(3) }.compactMap { $0 }
            let sourceSearchIndex = try XCTUnwrap(
                planDetails.firstIndex {
                    $0.contains("SEARCH s USING")
                        && $0.contains("sources_session_nocase")
                },
                "backfill plan must locate sources with sources_session_nocase: \(planDetails)"
            )
            let eventSearchIndex = try XCTUnwrap(
                planDetails.firstIndex { $0.contains("SEARCH e USING") },
                "backfill plan must look up events by source_id: \(planDetails)"
            )
            XCTAssertLessThan(sourceSearchIndex, eventSearchIndex, planDetails.joined(separator: " | "))
            XCTAssertFalse(
                planDetails.contains { $0.contains("SCAN e") },
                "backfill must not scan events: \(planDetails)"
            )
            XCTAssertFalse(
                planDetails.contains {
                    $0.contains("SCAN e USING INDEX events_source_timestamp")
                },
                planDetails.joined(separator: " | ")
            )

            let ledgerRows = try database.readRows(
                """
                SELECT source_lineage, SUM(total_tokens), SUM(calls)
                FROM attribution_source_buckets
                GROUP BY source_lineage;
                """
            ) { row -> (String, Int64, Int64)? in
                guard let lineage = row.text(0),
                      let totalTokens = row.int64(1),
                      let calls = row.int64(2) else {
                    return nil
                }
                return (lineage, totalTokens, calls)
            }.compactMap { $0 }
            XCTAssertEqual(ledgerRows.count, 1)
            XCTAssertEqual(ledgerRows.first?.0, canonicalLineage)
            XCTAssertEqual(ledgerRows.first?.1, 120)
            XCTAssertEqual(ledgerRows.first?.2, 1)
        }
    }

    func testPersistentExactHistoryIndexMigratesLegacyV3AndV4ColumnsInPlace() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerLegacyColumnMigration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-legacy-columns"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let before = try XCTUnwrap(
            database.readRows(
                """
                SELECT
                    (SELECT COUNT(*) FROM events),
                    (SELECT COALESCE(SUM(tokens), 0) FROM events),
                    (SELECT COUNT(*) FROM sources),
                    (SELECT COUNT(*) FROM source_fingerprints),
                    (SELECT COUNT(*) FROM source_chunks),
                    (SELECT CAST(value AS INTEGER) FROM schema_meta
                        WHERE key = 'attribution_generation');
                """
            ) { row in
                (
                    eventCount: row.int(0),
                    eventTokens: row.int(1),
                    sourceCount: row.int(2),
                    fingerprintCount: row.int(3),
                    chunkCount: row.int(4),
                    attributionGeneration: row.int64(5)
                )
            }.first
        )

        let legacyFixtures: [(String, [(String, String)])] = [
            (
                "3",
                [
                    ("sources", "current_model"),
                    ("sources", "is_explicit_subagent_fork"),
                    ("events", "model")
                ]
            ),
            ("4", [("sources", "is_explicit_subagent_fork")])
        ]
        var expectedAttributionGeneration = before.attributionGeneration
        for (schemaVersion, missingColumns) in legacyFixtures {
            for (table, column) in missingColumns {
                try database.execute("ALTER TABLE \(table) DROP COLUMN \(column);")
            }
            if schemaVersion == "3" {
                let legacyLedgerRows: [(String, String, Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = try database.readRows(
                    """
                    SELECT
                        provenance_epoch,
                        source_lineage,
                        bucket_start,
                        input_tokens,
                        cached_input_tokens,
                        output_tokens,
                        reasoning_output_tokens,
                        total_tokens,
                        calls
                    FROM attribution_source_buckets;
                    """
                ) { row -> (String, String, Int64, Int64, Int64, Int64, Int64, Int64, Int64)? in
                    guard let provenanceEpoch = row.text(0),
                          let sourceLineage = row.text(1),
                          let bucketStart = row.int64(2),
                          let inputTokens = row.int64(3),
                          let cachedInputTokens = row.int64(4),
                          let outputTokens = row.int64(5),
                          let reasoningOutputTokens = row.int64(6),
                          let totalTokens = row.int64(7),
                          let calls = row.int64(8) else {
                        return nil
                    }
                    return (
                        provenanceEpoch,
                        sourceLineage,
                        bucketStart,
                        inputTokens,
                        cachedInputTokens,
                        outputTokens,
                        reasoningOutputTokens,
                        totalTokens,
                        calls
                    )
                }.compactMap { $0 }
                XCTAssertFalse(legacyLedgerRows.isEmpty)
                try database.execute(
                    """
                    DROP INDEX IF EXISTS attribution_source_buckets_time;
                    DROP TABLE attribution_source_buckets;
                    CREATE TABLE attribution_source_buckets (
                        provenance_epoch TEXT NOT NULL,
                        source_lineage TEXT NOT NULL,
                        bucket_start INTEGER NOT NULL,
                        input_tokens INTEGER NOT NULL,
                        cached_input_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL,
                        reasoning_output_tokens INTEGER NOT NULL,
                        total_tokens INTEGER NOT NULL,
                        calls INTEGER NOT NULL,
                        PRIMARY KEY(provenance_epoch, source_lineage, bucket_start)
                    ) WITHOUT ROWID;
                    """
                )
                for row in legacyLedgerRows {
                    try database.execute(
                        """
                        INSERT INTO attribution_source_buckets(
                            provenance_epoch,
                            source_lineage,
                            bucket_start,
                            input_tokens,
                            cached_input_tokens,
                            output_tokens,
                            reasoning_output_tokens,
                            total_tokens,
                            calls
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            .text(row.0),
                            .text(row.1),
                            .int64(row.2),
                            .int64(row.3),
                            .int64(row.4),
                            .int64(row.5),
                            .int64(row.6),
                            .int64(row.7),
                            .int64(row.8)
                        ]
                    )
                }
                try database.execute(
                    "CREATE INDEX attribution_source_buckets_time ON attribution_source_buckets(provenance_epoch, bucket_start);"
                )
                try database.execute(
                    "UPDATE schema_meta SET value = 'source-bucket-v2-incremental-parser-v1' WHERE key = 'provenance_revision';"
                )
            }
            try database.execute(
                "UPDATE schema_meta SET value = '\(schemaVersion)' WHERE key = 'schema_version';"
            )

            CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
            let migratedIndex = try CodexUsageHistoryIndex(codexHome: codexHome)
            XCTAssertEqual(
                try migratedIndex.compactTotals(todayStart: Date(timeIntervalSince1970: 0)).totalTokens,
                120
            )
            var migratedTokens: [Int] = []
            try migratedIndex.forEachStoredEvent { migratedTokens.append($0.event.tokens) }
            XCTAssertEqual(migratedTokens, [120])
            XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 0)

            let after = try XCTUnwrap(
                database.readRows(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM events),
                        (SELECT COALESCE(SUM(tokens), 0) FROM events),
                        (SELECT COUNT(*) FROM sources),
                        (SELECT COUNT(*) FROM source_fingerprints),
                        (SELECT COUNT(*) FROM source_chunks),
                        (SELECT CAST(value AS INTEGER) FROM schema_meta
                            WHERE key = 'attribution_generation');
                    """
                ) { row in
                    (
                        eventCount: row.int(0),
                        eventTokens: row.int(1),
                        sourceCount: row.int(2),
                        fingerprintCount: row.int(3),
                        chunkCount: row.int(4),
                        attributionGeneration: row.int64(5)
                    )
                }.first
            )
            XCTAssertEqual(after.eventCount, before.eventCount)
            XCTAssertEqual(after.eventTokens, before.eventTokens)
            XCTAssertEqual(after.sourceCount, before.sourceCount)
            XCTAssertEqual(after.fingerprintCount, before.fingerprintCount)
            XCTAssertEqual(after.chunkCount, before.chunkCount)
            if schemaVersion == "3" {
                expectedAttributionGeneration = try XCTUnwrap(after.attributionGeneration)
                XCTAssertEqual(
                    try scalarInt(
                        "SELECT COUNT(*) FROM pragma_table_info('attribution_source_buckets') WHERE name = 'model';",
                        in: database
                    ),
                    1
                )
                XCTAssertGreaterThan(
                    try scalarInt("SELECT COUNT(*) FROM attribution_source_buckets;", in: database),
                    0
                )
                XCTAssertEqual(
                    try database.readRows(
                        "SELECT model FROM attribution_source_buckets LIMIT 1;"
                    ) { _ in true }.count,
                    1
                )
            } else {
                XCTAssertEqual(after.attributionGeneration, expectedAttributionGeneration)
            }
            XCTAssertEqual(
                try XCTUnwrap(
                    database.readRows(
                        "SELECT value FROM schema_meta WHERE key = 'schema_version';"
                    ) { $0.text(0) }.compactMap { $0 }.first
                ),
                "5"
            )
            for (table, column) in [
                ("sources", "current_model"),
                ("sources", "is_explicit_subagent_fork"),
                ("events", "model")
            ] {
                XCTAssertEqual(
                    try scalarInt(
                        "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)';",
                        in: database
                    ),
                    1,
                    "v\(schemaVersion) migration must restore \(table).\(column)"
                )
            }
        }
    }

    func testPersistentExactHistoryIndexRetriesUnresolvedReplayCandidateOnNextOpen() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerReplayMigrationRetry")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-replay-retry"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let forkedAt = Date()
        try tokenCountLine(
            timestamp: forkedAt.addingTimeInterval(1),
            total: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120),
            last: Usage(input: 100, cachedInput: 20, output: 20, reasoning: 0, total: 120)
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        XCTAssertEqual(try analyzer.load().stats.totalTokens, 120)
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        try database.execute("UPDATE schema_meta SET value = '4' WHERE key = 'schema_version';")
        try database.execute(
            "UPDATE sources SET is_skipping_fork_replay = 1, is_explicit_subagent_fork = 0, fork_replay_started_at = ?;",
            bindings: [.date(forkedAt)]
        )

        let oversizedFirstLine = "{\"type\":\"session_meta\",\"payload\":{\"forked_from_id\":\"origin-session\",\"agent_path\":\""
            + String(repeating: "x", count: 256 * 1_024)
            + "\"}"
        try oversizedFirstLine.write(to: sessionFile, atomically: true, encoding: .utf8)

        let unresolvedIndex = try CodexUsageHistoryIndex(codexHome: codexHome)
        XCTAssertEqual(
            try unresolvedIndex.compactTotals(todayStart: Date(timeIntervalSince1970: 0)).totalTokens,
            120
        )
        let unresolvedMarkerCount = try scalarInt(
            "SELECT COUNT(*) FROM schema_meta WHERE key = 'fork_replay_boundary_revision';",
            in: database
        )
        XCTAssertEqual(unresolvedMarkerCount, 0)
        XCTAssertEqual(
            try scalarInt(
                "SELECT is_explicit_subagent_fork FROM sources LIMIT 1;",
                in: database
            ),
            0
        )

        try explicitSubagentSessionMetaLine(
            timestamp: forkedAt,
            sessionID: sessionID
        ).appending("\n").write(to: sessionFile, atomically: true, encoding: .utf8)
        let retriedIndex = try CodexUsageHistoryIndex(codexHome: codexHome)
        XCTAssertEqual(
            try retriedIndex.compactTotals(todayStart: Date(timeIntervalSince1970: 0)).totalTokens,
            120
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT is_explicit_subagent_fork FROM sources LIMIT 1;",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM schema_meta WHERE key = 'fork_replay_boundary_revision' AND value = 'explicit-subagent-delayed-context-v3';",
                in: database
            ),
            1
        )
    }

    func testPersistentExactHistoryIndexTargetsOnlyExplicitReplayDuringMigration() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerTargetedReplayMigration")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-targeted-replay"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(sessionID).jsonl")
        let unrelatedSessionID = "019eaaaa-bbbb-cccc-dddd-targeted-unrelated"
        let unrelatedFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-18-\(unrelatedSessionID).jsonl")
        let forkedAt = Date()
        try [
            explicitSubagentSessionMetaLine(timestamp: forkedAt, sessionID: sessionID),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(0.5),
                total: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120),
                last: Usage(input: 100, cachedInput: 80, output: 20, reasoning: 0, total: 120)
            ),
            turnContextLine(timestamp: forkedAt.addingTimeInterval(1), model: "gpt-5.6-sol"),
            turnContextLine(timestamp: forkedAt.addingTimeInterval(5.6), model: "gpt-5.6-luna"),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(6),
                total: Usage(input: 160, cachedInput: 90, output: 30, reasoning: 0, total: 180),
                last: Usage(input: 60, cachedInput: 10, output: 10, reasoning: 0, total: 60)
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(7),
                total: Usage(input: 240, cachedInput: 120, output: 50, reasoning: 0, total: 260),
                last: Usage(input: 80, cachedInput: 30, output: 20, reasoning: 0, total: 80)
            )
        ].joined(separator: "\n").appending("\n").write(
            to: sessionFile,
            atomically: true,
            encoding: .utf8
        )
        try [
            #"{"timestamp":"2026-06-18T01:00:00Z","type":"session_meta","payload":{"id":"019eaaaa-bbbb-cccc-dddd-targeted-unrelated","forked_from_id":"origin-session","source":{"subagent":{"thread_spawn":"malformed-shape"}}}}"#,
            messageLine(
                timestamp: forkedAt.addingTimeInterval(3.5),
                type: "user_message",
                message: "ordinary child"
            ),
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(4),
                total: Usage(input: 20, cachedInput: 0, output: 5, reasoning: 0, total: 25),
                last: Usage(input: 20, cachedInput: 0, output: 5, reasoning: 0, total: 25)
            )
        ].joined(separator: "\n").appending("\n").write(
            to: unrelatedFile,
            atomically: true,
            encoding: .utf8
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        var index: CodexUsageHistoryIndex? = try CodexUsageHistoryIndex(codexHome: codexHome)
        _ = try index!.synchronize(
            files: [sessionFile, unrelatedFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 3)
        try database.execute(
            """
            DELETE FROM events
            WHERE source_id = (SELECT source_id FROM sources WHERE path = ?)
              AND tokens = 60;
            """,
            bindings: [.text(sessionFile.path)]
        )
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 2)
        let beforeFingerprintCount = try scalarInt("SELECT COUNT(*) FROM source_fingerprints;", in: database)
        let beforeChunkCount = try scalarInt("SELECT COUNT(*) FROM source_chunks;", in: database)
        let beforeGeneration = try scalarInt(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
            in: database
        )
        try database.execute("UPDATE schema_meta SET value = '4' WHERE key = 'schema_version';")
        try database.execute(
            "UPDATE sources SET is_skipping_fork_replay = 1, is_explicit_subagent_fork = 0, fork_replay_started_at = ? WHERE path = ?;",
            bindings: [.date(forkedAt), .text(sessionFile.path)]
        )
        try database.execute(
            "UPDATE sources SET is_skipping_fork_replay = 1 WHERE path = ?;",
            bindings: [.text(unrelatedFile.path)]
        )
        let unrelatedCheckpointBeforeMigration = try XCTUnwrap(
            database.readRows(
                "SELECT append_ready, resume_offset FROM sources WHERE path = ?;",
                bindings: [.text(unrelatedFile.path)]
            ) { ($0.int(0), $0.int64(1)) }.first
        )
        index = nil

        let migrated = try CodexUsageHistoryIndex(codexHome: codexHome)
        var publishedEvents: [TokenEvent] = []
        try migrated.forEachStoredEvent { publishedEvents.append($0.event) }
        XCTAssertEqual(publishedEvents.map(\.tokens), [80, 25])
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: database), 2)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM source_fingerprints;", in: database), beforeFingerprintCount)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM source_chunks;", in: database), beforeChunkCount)
        XCTAssertEqual(
            try scalarInt(
                "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'attribution_generation';",
                in: database
            ),
            beforeGeneration
        )
        let marker = try XCTUnwrap(
            database.readRows(
                "SELECT is_explicit_subagent_fork, append_ready, resume_offset, content_probe FROM sources WHERE path = ?;",
                bindings: [.text(sessionFile.path)]
            ) { ($0.int(0), $0.int(1), $0.int64(2), $0.text(3)) }.first
        )
        XCTAssertEqual(marker.0, 1)
        XCTAssertEqual(marker.1, 0)
        XCTAssertNil(marker.2)
        XCTAssertTrue(marker.3?.hasPrefix("migration:") == true)
        let unrelatedCheckpointAfterMigration = try XCTUnwrap(
            database.readRows(
                "SELECT append_ready, resume_offset FROM sources WHERE path = ?;",
                bindings: [.text(unrelatedFile.path)]
            ) { ($0.int(0), $0.int64(1)) }.first
        )
        XCTAssertEqual(unrelatedCheckpointAfterMigration.0, unrelatedCheckpointBeforeMigration.0)
        XCTAssertEqual(unrelatedCheckpointAfterMigration.1, unrelatedCheckpointBeforeMigration.1)

        var publishedBeforeAppend: [Int] = []
        try migrated.forEachStoredEvent { publishedBeforeAppend.append($0.event.tokens) }
        XCTAssertEqual(publishedBeforeAppend, [80, 25])

        try appendLines([
            try tokenCountLine(
                timestamp: forkedAt.addingTimeInterval(8),
                total: Usage(input: 280, cachedInput: 140, output: 60, reasoning: 0, total: 300),
                last: Usage(input: 40, cachedInput: 20, output: 10, reasoning: 0, total: 40)
            )
        ], to: sessionFile)

        var publishedAfterAppendBeforeSync: [Int] = []
        try migrated.forEachStoredEvent { publishedAfterAppendBeforeSync.append($0.event.tokens) }
        XCTAssertEqual(publishedAfterAppendBeforeSync, [80, 25])

        let finalSynchronization = try migrated.synchronize(
            files: [sessionFile, unrelatedFile],
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
        XCTAssertEqual(finalSynchronization.rewrittenFiles, 1)
        XCTAssertEqual(finalSynchronization.incrementallyParsedFiles, 0)
        XCTAssertEqual(
            try database.readRows(
                """
                SELECT events.tokens
                FROM events
                JOIN sources ON sources.source_id = events.source_id
                WHERE sources.path = ?
                ORDER BY events.source_offset;
                """,
                bindings: [.text(sessionFile.path)]
            ) { $0.int(0) }.compactMap { $0 },
            [60, 80, 40]
        )
        XCTAssertEqual(
            try database.readRows(
                """
                SELECT events.tokens
                FROM events
                JOIN sources ON sources.source_id = events.source_id
                WHERE sources.path = ?
                ORDER BY events.source_offset;
                """,
                bindings: [.text(unrelatedFile.path)]
            ) { $0.int(0) }.compactMap { $0 },
            [25]
        )
        let unrelatedCheckpointAfter = try XCTUnwrap(
            database.readRows(
                "SELECT append_ready, resume_offset FROM sources WHERE path = ?;",
                bindings: [.text(unrelatedFile.path)]
            ) { ($0.int(0), $0.int64(1)) }.first
        )
        XCTAssertEqual(unrelatedCheckpointAfter.0, unrelatedCheckpointBeforeMigration.0)
        XCTAssertEqual(unrelatedCheckpointAfter.1, unrelatedCheckpointBeforeMigration.1)
    }

    func testExactHistoryIndexDetectsSameSizeMiddleRewriteWithRestoredModificationDate() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageAnalyzerExactIdentity")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }

        let codexHome = try makeCodexHome()
        let sessionID = "019eaaaa-bbbb-cccc-dddd-samesize"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-06-17-\(sessionID).jsonl")
        let now = Date()
        let prefix = #"{"padding":""# + String(repeating: "a", count: 6_000) + #""}"#
        let suffix = #"{"padding":""# + String(repeating: "z", count: 6_000) + #""}"#
        let initial = Data(
            try [
                prefix,
                tokenCountLine(
                    timestamp: now.addingTimeInterval(-60),
                    total: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120),
                    last: Usage(input: 100, cachedInput: 30, output: 20, reasoning: 0, total: 120)
                ),
                suffix
            ].joined(separator: "\n").appending("\n").utf8
        )
        try initial.write(to: sessionFile)
        let originalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionFile.path)[.modificationDate] as? Date
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initialSnapshot = try analyzer.load()
        XCTAssertEqual(initialSnapshot.stats.totalTokens, 120)
        let initialProvenanceEpoch = try XCTUnwrap(
            initialSnapshot.cacheUsage.attributionProvenanceEpoch
        )

        let database = SQLiteDatabaseDriver(url: try exactUsageDatabaseURL(in: cacheRoot))
        let identityBefore = try XCTUnwrap(
            database.readRows(
                """
                SELECT modified_at, content_probe, status_changed_seconds, status_changed_nanoseconds
                FROM sources
                LIMIT 1;
                """
            ) {
                (
                    modifiedAt: $0.double(0),
                    contentProbe: $0.text(1),
                    changedSeconds: $0.int64(2),
                    changedNanoseconds: $0.int64(3)
                )
            }.first
        )

        let replacement = Data(
            try [
                prefix,
                tokenCountLine(
                    timestamp: now.addingTimeInterval(-60),
                    total: Usage(input: 110, cachedInput: 30, output: 20, reasoning: 0, total: 130),
                    last: Usage(input: 110, cachedInput: 30, output: 20, reasoning: 0, total: 130)
                ),
                suffix
            ].joined(separator: "\n").appending("\n").utf8
        )
        XCTAssertEqual(replacement.count, initial.count)
        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.truncate(atOffset: UInt64(replacement.count))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: sessionFile.path
        )

        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let updated = try analyzer.load()

        XCTAssertEqual(updated.stats.totalTokens, 130)
        XCTAssertNotEqual(
            updated.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        let identityAfter = try XCTUnwrap(
            database.readRows(
                """
                SELECT modified_at, content_probe, status_changed_seconds, status_changed_nanoseconds
                FROM sources
                LIMIT 1;
                """
            ) {
                (
                    modifiedAt: $0.double(0),
                    contentProbe: $0.text(1),
                    changedSeconds: $0.int64(2),
                    changedNanoseconds: $0.int64(3)
                )
            }.first
        )
        XCTAssertEqual(
            try XCTUnwrap(identityAfter.modifiedAt),
            try XCTUnwrap(identityBefore.modifiedAt),
            accuracy: 0.000_001
        )
        XCTAssertEqual(identityAfter.contentProbe, identityBefore.contentProbe)
        XCTAssertNotEqual(
            [identityAfter.changedSeconds, identityAfter.changedNanoseconds],
            [identityBefore.changedSeconds, identityBefore.changedNanoseconds]
        )
    }

    func testExactHistoryIndexIgnoresAndCleansThePreviousBoundedCacheNamespace() throws {
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
        let sessionID = "019eaaaa-bbbb-cccc-dddd-exactmigration"
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
            .appendingPathComponent(
                CodexUsageAnalyzer.SessionEventCache.previousCacheNamespace,
                isDirectory: true
            )
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
        let exactDirectory = swiftUsageCacheRoot(in: cacheRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try exactUsageDatabaseURL(in: cacheRoot).path))
        XCTAssertNil(
            try cacheDataContents(under: exactDirectory)
                .range(of: Data("legacy-prompt-digest".utf8))
        )

        UsageCacheLifecycle.markCurrentCachePrepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyNamespace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactDirectory.path))
    }

    func testPersistentExactHistoryIndexRebuildsFromRawHistoryAfterDatabaseCorruption() throws {
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
        let sessionID = "019eaaaa-bbbb-cccc-dddd-indexcorrupt"
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
        let initial = try analyzer.load()
        XCTAssertEqual(initial.stats.totalTokens, 120)
        let initialProvenanceEpoch = try XCTUnwrap(
            initial.cacheUsage.attributionProvenanceEpoch
        )
        let databaseURL = try exactUsageDatabaseURL(in: cacheRoot)
        try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        try Data("corrupt exact history index\n".utf8).write(to: databaseURL, options: [.atomic])

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        CodexUsageAnalyzer.resetPreciseSnapshotBuildCountForTesting()
        let rebuilt = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(rebuilt.stats.totalTokens, 120)
        XCTAssertEqual(rebuilt.stats.totalCalls, 1)
        XCTAssertNotEqual(
            rebuilt.cacheUsage.attributionProvenanceEpoch,
            initialProvenanceEpoch
        )
        XCTAssertEqual(CodexUsageAnalyzer.fullSessionParseCountForTesting, 1)
        XCTAssertEqual(
            try scalarInt("SELECT COUNT(*) FROM events;", in: SQLiteDatabaseDriver(url: databaseURL)),
            1
        )
    }

    func testOldDiscardableSessionCacheCannotOverrideTheExactRawHistoryIndex() throws {
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
                    "tokens": 999_999,
                    "inputTokens": 999_999,
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: try exactUsageDatabaseURL(in: cacheRoot).path))

        UsageCacheLifecycle.markCurrentCachePrepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCache.path))
    }

    func testSQLiteReasoningUsesExactReasoningEffortColumn() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabaseWithReasoningNoise(at: codexHome)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).loadFastSnapshot()

        XCTAssertEqual(snapshot.stats.mostUsedReasoning, "中 · 1")
    }

    func testPreciseScanCountsEveryEventAndDeduplicatesReplayBeyondFormerFingerprintWindow() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-019faaaa-bbbb-cccc-dddd-unbounded.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventCount = 5_000
        var lines = try (0..<eventCount).map { index in
            try tokenCountLine(
                timestamp: now.addingTimeInterval(TimeInterval(index)),
                total: Usage(
                    input: index + 1,
                    cachedInput: 0,
                    output: 0,
                    reasoning: 0,
                    total: index + 1
                ),
                last: Usage(input: 1, cachedInput: 0, output: 0, reasoning: 0, total: 1)
            )
        }
        lines.append(
            try tokenCountLine(
                timestamp: now.addingTimeInterval(TimeInterval(eventCount + 1)),
                total: Usage(input: 1, cachedInput: 0, output: 0, reasoning: 0, total: 1),
                last: Usage(input: 1, cachedInput: 0, output: 0, reasoning: 0, total: 1)
            )
        )
        try lines.joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.usagePrecision, .precise)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertEqual(snapshot.stats.totalTokens, eventCount)
        XCTAssertEqual(snapshot.stats.totalCalls, eventCount)
    }

    func testPreciseScanParsesJSONLLineBeyondFormerSixteenMiBLimitExactly() throws {
        let codexHome = try makeCodexHome()
        try seedStateDatabase(at: codexHome)
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-019faaaa-bbbb-cccc-dddd-large-line.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oversizedLine = encodeLine([
            "timestamp": iso8601String(from: now),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "padding": String(repeating: "x", count: 17 * 1_024 * 1_024),
                "info": [
                    "total_token_usage": usageObject(
                        Usage(input: 1_200, cachedInput: 400, output: 120, reasoning: 0, total: 1_320)
                    ),
                    "last_token_usage": usageObject(
                        Usage(input: 1_200, cachedInput: 400, output: 120, reasoning: 0, total: 1_320)
                    )
                ]
            ]
        ])
        XCTAssertGreaterThan(oversizedLine.utf8.count, 16 * 1_024 * 1_024)
        try oversizedLine.appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.usagePrecision, .precise)
        XCTAssertEqual(snapshot.stats.totalThreads, 2)
        XCTAssertEqual(snapshot.stats.totalTokens, 1_320)
        XCTAssertEqual(snapshot.stats.totalCalls, 1)
    }

    func testStreamingAggregationBoundsRetainedTurnCandidates() throws {
        let codexHome = try makeCodexHome()
        let sessionID = "019faaaa-bbbb-cccc-dddd-candidatebound"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-\(sessionID).jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventCount = 200
        let lines = try (0..<eventCount).map { index in
            let calls = index + 1
            return try tokenCountLine(
                timestamp: now.addingTimeInterval(TimeInterval(index - eventCount)),
                total: Usage(
                    input: 1_200 * calls,
                    cachedInput: index.isMultiple(of: 2) ? 1_000 * calls : 0,
                    output: 100 * calls,
                    reasoning: 0,
                    total: 1_300 * calls
                ),
                last: Usage(
                    input: 1_200,
                    cachedInput: index.isMultiple(of: 2) ? 1_000 : 0,
                    output: 100,
                    reasoning: 0,
                    total: 1_300
                )
            )
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageAnalyzer(dataSource: dataSource(for: codexHome)).load()

        XCTAssertEqual(snapshot.stats.totalCalls, eventCount)
        XCTAssertLessThan(snapshot.cacheUsage.turns.count, eventCount)
        XCTAssertTrue(snapshot.cacheUsage.turns.contains { turn in
            turn.turnIndexInSession == eventCount
                && turn.timestamp == now.addingTimeInterval(-1)
        })
    }

    func testExactHistoryIndexStoresOffsetsButNotConversationText() throws {
        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        let cacheRoot = try makeTemporaryDirectory(named: "CodexUsageExactIndexPrivacy")
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR", cacheRoot.path, 1)
        setenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR", cacheRoot.path, 1)
        defer {
            setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1)
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_DIR")
            unsetenv("CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR")
        }
        let codexHome = try makeCodexHome()
        let sessionID = "019faaaa-bbbb-cccc-dddd-livecacheprivacy"
        let sessionFile = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026-07-22-\(sessionID).jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secretPrompt = "in-memory prompt must not stay cached"
        let secretResponse = "in-memory response must not stay cached"
        try [
            messageLine(timestamp: now.addingTimeInterval(-3), type: "user_message", message: secretPrompt),
            messageLine(timestamp: now.addingTimeInterval(-2), type: "agent_message", message: secretResponse),
            try tokenCountLine(
                timestamp: now.addingTimeInterval(-1),
                total: Usage(input: 1_200, cachedInput: 200, output: 100, reasoning: 0, total: 1_300),
                last: Usage(input: 1_200, cachedInput: 200, output: 100, reasoning: 0, total: 1_300)
            )
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let initial = try analyzer.load()
        XCTAssertTrue(initial.cacheUsage.turns.contains { $0.userPrompt == secretPrompt })
        XCTAssertTrue(initial.cacheUsage.turns.contains { $0.assistantResponse == secretResponse })

        let cacheBytes = try cacheDataContents(under: swiftUsageCacheRoot(in: cacheRoot))
        XCTAssertNil(cacheBytes.range(of: Data(secretPrompt.utf8)))
        XCTAssertNil(cacheBytes.range(of: Data(secretResponse.utf8)))
        XCTAssertNotNil(cacheBytes.range(of: Data("user_prompt_offset".utf8)))
        XCTAssertNotNil(cacheBytes.range(of: Data("assistant_start_offset".utf8)))
    }

    func testUsageSnapshotFingerprintDecodesTheExistingArrayCacheShape() throws {
        let fingerprint = try JSONDecoder().decode(
            CodexUsageAnalyzer.UsageSnapshotFingerprint.self,
            from: Data("[1200,400,120,10,1320,1,300,100,30,2,330]".utf8)
        )

        XCTAssertEqual(fingerprint.totalInputTokens, 1_200)
        XCTAssertEqual(fingerprint.totalCachedInputTokens, 400)
        XCTAssertEqual(fingerprint.totalTokens, 1_320)
        XCTAssertTrue(fingerprint.hasLastUsage)
        XCTAssertEqual(fingerprint.lastInputTokens, 300)
        XCTAssertEqual(fingerprint.lastTokens, 330)
    }

    func testLiveExactHistoryColdAndWarmScansWhenExplicitlyEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_TOKEN_BAR_RUN_LIVE_EXACT_HISTORY_TEST=1 for the local full-history scan")
        }
        let codexHomePath = environment["CODEX_TOKEN_BAR_LIVE_CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .path
        let codexHome = URL(fileURLWithPath: codexHomePath, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: codexHome.path),
            "Live Codex Home does not exist: \(codexHome.path)"
        )

        unsetenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE")
        defer { setenv("CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "1", 1) }
        let dataSource = dataSource(for: codexHome)

        let coldStartedAt = Date()
        let coldSnapshot = try CodexUsageAnalyzer(dataSource: dataSource).load()
        let coldElapsed = Date().timeIntervalSince(coldStartedAt)
        let coldFullParseCount = CodexUsageAnalyzer.fullSessionParseCountForTesting

        XCTAssertEqual(coldSnapshot.usagePrecision, .precise)
        XCTAssertGreaterThan(coldSnapshot.stats.totalTokens, 0)
        XCTAssertGreaterThan(coldSnapshot.stats.totalCalls, 0)
        // A previous opt-in run may already have built the durable index. Zero
        // full parses is then the expected first-observation result, not a
        // reason to destroy the real cache merely to manufacture a cold scan.
        print(
            "LIVE_EXACT_HISTORY_COLD_RESULT"
                + " elapsed_seconds=\(String(format: "%.3f", coldElapsed))"
                + " full_parse_count=\(coldFullParseCount)"
                + " total_tokens=\(coldSnapshot.stats.totalTokens)"
                + " total_calls=\(coldSnapshot.stats.totalCalls)"
                + " total_threads=\(coldSnapshot.stats.totalThreads)"
        )

        CodexUsageAnalyzer.clearInMemoryUsageSnapshotsForTesting()
        let warmStartedAt = Date()
        let warmSnapshot = try CodexUsageAnalyzer(dataSource: dataSource).load()
        let warmElapsed = Date().timeIntervalSince(warmStartedAt)

        XCTAssertEqual(warmSnapshot.usagePrecision, .precise)
        XCTAssertGreaterThan(warmSnapshot.stats.totalTokens, 0)
        XCTAssertGreaterThan(warmSnapshot.stats.totalCalls, 0)
        // The real Codex Home remains active while this opt-in test runs. New
        // token_count rows, session creation, archive, or deletion between the
        // cold and warm observations legitimately change totals. The warm-path
        // invariant is therefore source reuse, not point-in-time equality.
        let warmFullParseCount = CodexUsageAnalyzer.fullSessionParseCountForTesting
        let additionalFullParseCount = warmFullParseCount - coldFullParseCount
        XCTAssertGreaterThanOrEqual(additionalFullParseCount, 0)
        // Deterministic fixture tests above prove unchanged-source reuse. A
        // live Home may create a new session or legitimately rewrite a source
        // between observations, so its additional full parses are evidence to
        // report rather than a false failure.
        let tokenDelta = warmSnapshot.stats.totalTokens - coldSnapshot.stats.totalTokens
        let callDelta = warmSnapshot.stats.totalCalls - coldSnapshot.stats.totalCalls
        let threadDelta = warmSnapshot.stats.totalThreads - coldSnapshot.stats.totalThreads
        print(
            "LIVE_EXACT_HISTORY_WARM_RESULT"
                + " elapsed_seconds=\(String(format: "%.3f", warmElapsed))"
                + " additional_full_parse_count=\(additionalFullParseCount)"
                + " total_tokens=\(warmSnapshot.stats.totalTokens)"
                + " total_calls=\(warmSnapshot.stats.totalCalls)"
                + " total_threads=\(warmSnapshot.stats.totalThreads)"
                + " token_delta=\(tokenDelta)"
                + " call_delta=\(callDelta)"
                + " thread_delta=\(threadDelta)"
        )
    }

    private struct Usage {
        let input: Int
        let cachedInput: Int
        let output: Int
        let reasoning: Int
        let total: Int
    }

    private final class ColdBuildScheduleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [String: Date] = [:]
        private var spans: [(path: String, start: Date, end: Date)] = []

        func recordStart(path: String) {
            lock.lock()
            starts[path] = Date()
            lock.unlock()
        }

        func recordEnd(path: String) {
            lock.lock()
            if let start = starts[path] {
                spans.append((path, start, Date()))
            }
            lock.unlock()
        }

        func snapshot() -> [(path: String, start: Date, end: Date)] {
            lock.lock()
            defer { lock.unlock() }
            return spans
        }
    }

    func testColdBuildHeavyFilesRunOnADedicatedSerialLaneWithoutStarvingLightFiles() throws {
        let codexHome = try makeCodexHome()
        let sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()

        // 4 个 heavy（≥ 注入阈值）盖过冷建并发上限（≤4）+ 1 个 light：
        // 旧的单队列 + 互斥锁实现里 heavy 会占满全部并发槽阻塞在锁上，
        // light 直到首个 heavy 完成腾出槽位后才能开跑。
        var files: [URL] = []
        var heavyPaths: Set<String> = []
        for heavyIndex in 0..<4 {
            let sessionID = "019eaaaa-bbbb-cccc-dddd-heavy00000\(heavyIndex)"
            let file = sessionsDirectory.appendingPathComponent("2026-06-17-\(sessionID).jsonl")
            var lines: [String] = []
            for line in 0..<25 {
                let tokens = 120 + heavyIndex * 100 + line
                lines.append(try tokenCountLine(
                    timestamp: now.addingTimeInterval(TimeInterval(-3_600 + heavyIndex * 100 + line)),
                    total: Usage(input: tokens - 20, cachedInput: 0, output: 20, reasoning: 0, total: tokens),
                    last: Usage(input: tokens - 20, cachedInput: 0, output: 20, reasoning: 0, total: tokens)
                ))
            }
            try lines.joined(separator: "\n").appending("\n")
                .write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
            heavyPaths.insert(file.resolvingSymlinksInPath().path)
        }
        let lightSessionID = "019eaaaa-bbbb-cccc-dddd-light000000"
        let lightFile = sessionsDirectory.appendingPathComponent("2026-06-17-\(lightSessionID).jsonl")
        try tokenCountLine(
            timestamp: now.addingTimeInterval(-60),
            total: Usage(input: 10, cachedInput: 0, output: 2, reasoning: 0, total: 12),
            last: Usage(input: 10, cachedInput: 0, output: 2, reasoning: 0, total: 12)
        ).appending("\n").write(to: lightFile, atomically: true, encoding: .utf8)
        files.append(lightFile)

        let lightSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lightFile.path)[.size] as? UInt64
        )

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let index = try CodexUsageHistoryIndex(codexHome: codexHome)
        index.coldBuildHeavyFileThreshold = lightSize + 1

        let recorder = ColdBuildScheduleRecorder()
        _ = try index.synchronize(
            files: files,
            sessionID: analyzer.sessionID(from:)
        ) { file, parsedSessionID, request, insertFingerprint, emit in
            let path = file.resolvingSymlinksInPath().path
            recorder.recordStart(path: path)
            if heavyPaths.contains(path) {
                Thread.sleep(forTimeInterval: 0.5)
            }
            defer { recorder.recordEnd(path: path) }
            return try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: parsedSessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }

        let spans = recorder.snapshot()
        let heavySpans = spans.filter { heavyPaths.contains($0.path) }
        let lightSpans = spans.filter { !heavyPaths.contains($0.path) }
        XCTAssertEqual(heavySpans.count, 4)
        XCTAssertEqual(lightSpans.count, 1)

        // heavy 专用通道必须串行：任意两个 heavy 解析时间段不得重叠。
        for left in heavySpans {
            for right in heavySpans where left.path < right.path {
                XCTAssertFalse(
                    left.start < right.end && right.start < left.end,
                    "heavy 文件 \(left.path) 与 \(right.path) 并发解析"
                )
            }
        }
        // light 通道不得被 heavy 饿死：light 必须在首个 heavy 完成前开跑。
        let firstHeavyEnd = try XCTUnwrap(heavySpans.map(\.end).min())
        let lightStart = try XCTUnwrap(lightSpans.first).start
        XCTAssertLessThan(lightStart, firstHeavyEnd)
    }

    func testCompactSummaryReturnsSumTotalsWithoutBuildingDerivedSeries() throws {
        let codexHome = try makeCodexHome()
        let sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()

        let entries: [(suffix: String, offset: TimeInterval, total: Int)] = [
            ("yesterday1", -26 * 60 * 60, 100),
            ("yesterday2", -25 * 60 * 60, 60),
            ("today00000", -1, 40),
        ]
        var files: [URL] = []
        for entry in entries {
            let sessionID = "019eaaaa-bbbb-cccc-dddd-\(entry.suffix)"
            let file = sessionsDirectory.appendingPathComponent("2026-06-17-\(sessionID).jsonl")
            try tokenCountLine(
                timestamp: now.addingTimeInterval(entry.offset),
                total: Usage(input: entry.total, cachedInput: 0, output: 0, reasoning: 0, total: entry.total),
                last: Usage(input: entry.total, cachedInput: 0, output: 0, reasoning: 0, total: entry.total)
            ).appending("\n").write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
        }

        let analyzer = CodexUsageAnalyzer(dataSource: dataSource(for: codexHome))
        let summary = try XCTUnwrap(analyzer.loadCompactSummary())

        XCTAssertEqual(summary.totalTokens, 200)
        XCTAssertEqual(summary.todayTokens, 40)
        XCTAssertEqual(summary.todayCalls, 1)
    }

    func testIntegrityQuickCheckRunsOncePerProcessPerPath() throws {
        let codexHome = try makeCodexHome()
        let baseline = CodexUsageHistoryIndex.integrityCheckRunCountForTesting
        _ = try CodexUsageHistoryIndex(codexHome: codexHome)
        XCTAssertEqual(CodexUsageHistoryIndex.integrityCheckRunCountForTesting, baseline + 1)
        // 同进程同路径再次建索引：不得再跑 PRAGMA quick_check 全库扫描。
        _ = try CodexUsageHistoryIndex(codexHome: codexHome)
        XCTAssertEqual(CodexUsageHistoryIndex.integrityCheckRunCountForTesting, baseline + 1)
        // 新路径首次建索引仍要校验。
        let otherHome = try makeCodexHome()
        _ = try CodexUsageHistoryIndex(codexHome: otherHome)
        XCTAssertEqual(CodexUsageHistoryIndex.integrityCheckRunCountForTesting, baseline + 2)
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

    private func turnContextLine(timestamp: Date, model: String) -> String {
        encodeLine([
            "timestamp": iso8601String(from: timestamp),
            "type": "turn_context",
            "payload": ["model": model]
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

    private func explicitSubagentSessionMetaLine(timestamp: Date, sessionID: String) -> String {
        encodeLine([
            "timestamp": iso8601String(from: timestamp),
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "forked_from_id": "origin-session",
                "thread_source": "subagent",
                "agent_role": "luna_worker",
                "agent_path": "/root/luna_worker",
                "source": [
                    "subagent": [
                        "thread_spawn": [
                            "parent_thread_id": "origin-session",
                            "agent_role": "luna_worker"
                        ]
                    ]
                ]
            ]
        ])
    }

    private func parentThreadSessionMetaLine(timestamp: Date, sessionID: String, parentID: String) -> String {
        "{ \"timestamp\" : \"\(iso8601String(from: timestamp))\", \"type\" : \"session_meta\", \"payload\" : { \"id\" : \"\(sessionID)\", \"parent_thread_id\" : \"\(parentID)\", \"thread_source\" : \"subagent\" } }"
    }

    private func spacedMessageLine(timestamp: Date, type: String, message: String) -> String {
        "{ \"timestamp\" : \"\(iso8601String(from: timestamp))\", \"type\" : \"event_msg\", \"payload\" : { \"type\" : \"\(type)\", \"message\" : \"\(message)\" } }"
    }

    // raw* 变体接受字面时间戳：ISO8601DateFormatter 会截掉毫秒且 Date 运算受
    // 浮点误差影响，重放宽限的 2.000s/2.001s 边界用例必须用精确字符串构造。
    private func rawForkedSessionMetaLine(timestamp: String, sessionID: String) -> String {
        "{ \"timestamp\" : \"\(timestamp)\", \"type\" : \"session_meta\", \"payload\" : { \"id\" : \"\(sessionID)\", \"forked_from_id\" : \"origin-session\" } }"
    }

    private func rawMessageLine(timestamp: String, type: String, message: String) -> String {
        "{ \"timestamp\" : \"\(timestamp)\", \"type\" : \"event_msg\", \"payload\" : { \"type\" : \"\(type)\", \"message\" : \"\(message)\" } }"
    }

    private func rawTokenCountLine(timestamp: String, total: Usage, last: Usage) -> String {
        encodeLine([
            "timestamp": timestamp,
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

    private func exactUsageDatabaseURL(in cacheRoot: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: swiftUsageCacheRoot(in: cacheRoot),
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try XCTUnwrap(files.first { $0.pathExtension == "sqlite" })
    }

    private func scalarInt(_ sql: String, in database: SQLiteDatabaseDriver) throws -> Int {
        try XCTUnwrap(
            database.readRows(sql) { $0.int(0) }.compactMap { $0 }.first
        )
    }

    private func cacheDataContents(under directory: URL) throws -> Data {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Data()
        }
        return try enumerator.reduce(into: Data()) { partial, item in
            guard let url = item as? URL else { return }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return }
            partial.append(try Data(contentsOf: url))
        }
    }

    private func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private struct ConcurrentUsageIndexObservation {
    let synchronization: CodexUsageHistoryIndex.SynchronizationResult
    let totalTokens: Int
}

private final class ConcurrentParserProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ConcurrentUsageIndexWorker: @unchecked Sendable {
    private let index: CodexUsageHistoryIndex
    private let analyzer: CodexUsageAnalyzer
    private let files: [URL]

    init(codexHome: URL, files: [URL]) throws {
        index = try CodexUsageHistoryIndex(codexHome: codexHome)
        analyzer = CodexUsageAnalyzer(
            dataSource: CodexDataSource(codexHome: codexHome, origin: .userSelected)
        )
        self.files = files
    }

    func synchronizeAndReadTotal(
        exclusiveAccessEntered: DispatchSemaphore? = nil,
        parserGateFile: URL? = nil,
        parserReachedGate: DispatchSemaphore? = nil,
        releaseParser: DispatchSemaphore? = nil,
        synchronizationFinished: DispatchSemaphore? = nil,
        releaseAggregation: DispatchSemaphore? = nil
    ) throws -> ConcurrentUsageIndexObservation {
        try index.withExclusiveAccess {
            exclusiveAccessEntered?.signal()
            let parserGate = ConcurrentParserGate(target: parserGateFile)
            let synchronization = try index.synchronize(
                files: files,
                sessionID: analyzer.sessionID(from:)
            ) { [analyzer] file, sessionID, request, insertFingerprint, emit in
                if parserGate.claimIfTarget(file) {
                    parserReachedGate?.signal()
                    guard releaseParser?.wait(timeout: .now() + 5) != .timedOut else {
                        throw NSError(
                            domain: "CodexUsageAnalyzerTests.ConcurrentUsageIndexWorker",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting to release parser gate"]
                        )
                    }
                }
                return try analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
            synchronizationFinished?.signal()
            if let releaseAggregation,
               releaseAggregation.wait(timeout: .now() + 5) == .timedOut {
                throw NSError(
                    domain: "CodexUsageAnalyzerTests.ConcurrentUsageIndexWorker",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting to release aggregation gate"]
                )
            }
            var totalTokens = 0
            try index.forEachStoredEvent { totalTokens += $0.event.tokens }
            return ConcurrentUsageIndexObservation(
                synchronization: synchronization,
                totalTokens: totalTokens
            )
        }
    }
}

private final class ConcurrentParserGate: @unchecked Sendable {
    private let lock = NSLock()
    private let targetPath: String?
    private var claimed = false

    init(target: URL?) {
        targetPath = target?.resolvingSymlinksInPath().path
    }

    func claimIfTarget(_ file: URL) -> Bool {
        guard let targetPath,
              file.resolvingSymlinksInPath().path == targetPath else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private final class ConcurrentUsageIndexResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ConcurrentUsageIndexObservation, Error>?

    func set(_ result: Result<ConcurrentUsageIndexObservation, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<ConcurrentUsageIndexObservation, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
