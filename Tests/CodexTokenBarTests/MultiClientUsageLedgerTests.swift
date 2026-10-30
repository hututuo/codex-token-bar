import XCTest
@testable import CodexTokenBar

final class MultiClientUsageLedgerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-client-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func event(_ output: Int64 = 20, client: UsageClient = .claudeCode) -> ClientUsageEvent {
        ClientUsageEvent(client: client, eventID: "s:msg1", sessionID: "s", model: "test-model", timestamp: Date(timeIntervalSince1970: 1800000000), inputTokens: 100, outputTokens: output, cacheReadTokens: 60, cacheWriteTokens: 10, reasoningTokens: nil)
    }
    func testReplayUpdatesAndOtherClientAreIndependentWithoutCodexMutation() throws {
        let codex = root.appendingPathComponent("codex-token-index.sqlite")
        let sentinel = Data("existing Codex raw accounting".utf8); try sentinel.write(to: codex)
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("multi-client-usage.sqlite"))
        XCTAssertEqual(try ledger.ingest([event()]), 1)
        XCTAssertEqual(try ledger.ingest([event()]), 0)
        XCTAssertEqual(try ledger.ingest([event(40)]), 1)
        XCTAssertEqual(try ledger.ingest([event(10)]), 0, "copied/rotated earlier streaming records cannot reduce final counts")
        XCTAssertEqual(try ledger.ingest([event(5, client: .deepseek)]), 1)
        let summaries = try ledger.summaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.outputTokens, 40)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.requests, 1)
        XCTAssertNil(summaries.first?.reasoningTokens)
        XCTAssertEqual(try Data(contentsOf: codex), sentinel)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 3)
    }
    func testCheckpointAndEventsRollbackTogether() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let checkpoint = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "inode")
        _ = try ledger.ingest([event()], client: .claudeCode, sourceKey: "file", checkpoint: checkpoint)
        var invalid = event(30); invalid.inputTokens = -1
        XCTAssertThrowsError(try ledger.ingest([invalid], client: .claudeCode, sourceKey: "file", checkpoint: .init(offset: 200, size: 200, modified: 11, identity: "inode")))
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "file")?.offset, 100)
        XCTAssertEqual(try ledger.summaries().first?.outputTokens, 20)
    }
    func testBackupIncludesCommittedWALAndFutureSchemaIsNotDowngraded() throws {
        let url = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([event()])
        let backup = try ledger.backup()
        let copy = SQLiteDatabaseDriver(url: backup, readOnly: true)
        XCTAssertEqual(try copy.readRows("SELECT SUM(output_tokens) FROM client_usage_events") { $0.int64(0) }.first!, 20)
        try ledger.database.execute("PRAGMA user_version=99")
        XCTAssertThrowsError(try MultiClientUsageLedger(url: url))
        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, 99)
    }
    func testTrendBucketsUseFiveMinuteUTCWindowsAndConserveRawEvents() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now: Int64 = 1_800_000_600
        let cutoff = now - 30 * 24 * 60 * 60
        func sample(_ id: String, _ timestamp: Int64, _ input: Int64, _ output: Int64,
                    client: UsageClient = .claudeCode, cacheRead: Int64? = nil,
                    cacheWrite: Int64? = nil, reasoning: Int64? = nil) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: "fixture",
                timestamp: Date(timeIntervalSince1970: Double(timestamp)), inputTokens: input,
                outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                reasoningTokens: reasoning)
        }
        _ = try ledger.ingest([
            sample("before-cutoff", cutoff - 1, 100, 100),
            sample("at-cutoff", cutoff, 10, 1, cacheWrite: 2),
            sample("same-bucket", cutoff + 299, 3, 4, cacheRead: 5, reasoning: 7),
            sample("next-bucket", cutoff + 300, 2, 3),
            sample("last-client", now - 1, 8, 9, client: .deepseek, cacheRead: 10,
                   cacheWrite: 11, reasoning: 12),
            sample("at-upper-bound", now, 100, 100),
            sample("after-upper-bound", now + 1, 100, 100)
        ])

        let buckets = try ledger.trendBuckets(now: Date(timeIntervalSince1970: Double(now)))
        XCTAssertEqual(buckets.count, 4)
        XCTAssertTrue(buckets.allSatisfy { $0.startUnix % 300 == 0 })
        XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.inputTokens + $1.outputTokens }, 240)

        let first = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == cutoff })
        XCTAssertEqual(first.inputTokens, 13)
        XCTAssertEqual(first.outputTokens, 5)
        XCTAssertEqual(first.cacheReadTokens, 5)
        XCTAssertEqual(first.cacheWriteTokens, 2)
        XCTAssertEqual(first.reasoningTokens, 7)
        XCTAssertEqual(first.requests, 2)

        let next = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == cutoff + 300 })
        XCTAssertNil(next.cacheReadTokens)
        XCTAssertNil(next.cacheWriteTokens)
        XCTAssertNil(next.reasoningTokens)
        XCTAssertEqual(next.requests, 1)

        let latest = try XCTUnwrap(buckets.first { $0.client == .deepseek })
        XCTAssertEqual(latest.startUnix, now - 300)
        let upper = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == now })
        XCTAssertEqual(upper.requests, 1)
    }
    func testDailyBucketsUseLocalCalendarDaysAndConserveRawEvents() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_800_000_600)
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -364, to: today)!
        let nextDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: firstDay)!)
        func sample(_ id: String, _ timestamp: Date, _ input: Int64, _ output: Int64,
                    client: UsageClient = .claudeCode, cacheRead: Int64? = nil,
                    cacheWrite: Int64? = nil, reasoning: Int64? = nil) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: "fixture",
                timestamp: timestamp, inputTokens: input, outputTokens: output,
                cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, reasoningTokens: reasoning)
        }
        _ = try ledger.ingest([
            sample("before-window", firstDay.addingTimeInterval(-1), 100, 100),
            sample("at-window", firstDay, 10, 1, cacheWrite: 2),
            sample("same-day", firstDay.addingTimeInterval(299), 3, 4, cacheRead: 5, reasoning: 7),
            sample("next-day", nextDay, 2, 3),
            sample("last-client", now.addingTimeInterval(-1), 8, 9, client: .deepseek,
                   cacheRead: 10, cacheWrite: 11, reasoning: 12),
            sample("at-upper-bound", now, 100, 100),
            sample("after-upper-bound", now.addingTimeInterval(1), 100, 100)
        ])

        let buckets = try ledger.dailyBuckets(now: now)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.inputTokens + $1.outputTokens }, 240)
        XCTAssertTrue(buckets.allSatisfy {
            let start = Date(timeIntervalSince1970: Double($0.startUnix))
            return calendar.startOfDay(for: start).timeIntervalSince1970 == Double($0.startUnix)
        })

        let first = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(firstDay.timeIntervalSince1970) })
        XCTAssertEqual(first.inputTokens, 13)
        XCTAssertEqual(first.outputTokens, 5)
        XCTAssertEqual(first.cacheReadTokens, 5)
        XCTAssertEqual(first.cacheWriteTokens, 2)
        XCTAssertEqual(first.reasoningTokens, 7)
        XCTAssertEqual(first.requests, 2)

        let next = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(nextDay.timeIntervalSince1970) })
        XCTAssertEqual(next.requests, 1)
        XCTAssertNil(next.cacheReadTokens)
        XCTAssertNil(next.cacheWriteTokens)
        XCTAssertNil(next.reasoningTokens)
        let current = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(today.timeIntervalSince1970) })
        XCTAssertEqual(current.requests, 1)
        let otherClient = try XCTUnwrap(buckets.first { $0.client == .deepseek && $0.startUnix == Int64(today.timeIntervalSince1970) })
        XCTAssertEqual(otherClient.requests, 1)
    }
    func testSummariesPriceEachKnownRequestAndKeepUnpricedRowsVisible() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        func pricedEvent(_ id: String, client: UsageClient = .claudeCode, model: String,
                         input: Int64, output: Int64, cacheRead: Int64? = 0,
                         cacheWrite: Int64? = 0) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: model,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: input,
                outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite)
        }
        _ = try ledger.ingest([
            pricedEvent("standard", model: "gpt-6.1-sol", input: 100, output: 10),
            pricedEvent("unknown-cache-read", model: "gpt-6.1-sol", input: 100, output: 10,
                        cacheRead: nil),
            pricedEvent("small-a", client: .claudeDesktop, model: "gpt-6.1-sol", input: 140_000, output: 0),
            pricedEvent("small-b", client: .claudeDesktop, model: "gpt-6.1-sol", input: 140_000, output: 0),
            pricedEvent("long", client: .deepseek, model: "gpt-6.1-sol", input: 280_000, output: 0),
            pricedEvent("unknown-model", model: "unlisted-provider-model", input: 100, output: 10),
            pricedEvent("unknown-write-lifetime", model: "claude-opus-5-5", input: 100, output: 0, cacheWrite: 1),
            pricedEvent("time-dependent-price", client: .deepseek, model: "deepseek-reasoner", input: 100, output: 10),
            pricedEvent("namespace-alias", client: .opencode, model: "openai/gpt-5.5-2026-04-23", input: 100, output: 10),
            pricedEvent("explicit-fast", client: .gemini, model: "gpt-6.1-sol-fast", input: 100, output: 10),
            pricedEvent("half-up", client: .claudeDesktop, model: "gpt-5.5", input: 1, output: 0, cacheRead: 1),
            pricedEvent("free", client: .opencode, model: "glm-4.7-flash", input: 0, output: 0,
                        cacheRead: nil, cacheWrite: nil)
        ])

        let summaries = try ledger.summaries()
        let standard = try XCTUnwrap(summaries.first { $0.client == .claudeCode && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(standard.apiCostUSD), 0.0003, accuracy: 0.000000001)
        XCTAssertEqual(standard.unpricedRequests, 1)
        XCTAssertFalse(standard.cacheReadComplete)

        let twoSmall = try XCTUnwrap(summaries.first { $0.client == .claudeDesktop && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(twoSmall.apiCostUSD), 0.56, accuracy: 0.000000001,
                       "Two 140k requests each use the base tier even though their combined input exceeds the threshold")
        XCTAssertEqual(twoSmall.unpricedRequests, 0)
        XCTAssertTrue(twoSmall.cacheReadComplete)
        let long = try XCTUnwrap(summaries.first { $0.client == .deepseek && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(long.apiCostUSD), 1.12, accuracy: 0.000000001)

        let unknown = try XCTUnwrap(summaries.first { $0.model == "unlisted-provider-model" })
        XCTAssertNil(unknown.apiCostUSD)
        XCTAssertEqual(unknown.unpricedRequests, 1)
        let lifetime = try XCTUnwrap(summaries.first { $0.model == "claude-opus-5-5" })
        XCTAssertNil(lifetime.apiCostUSD)
        XCTAssertEqual(lifetime.unpricedRequests, 1)
        let timeDependent = try XCTUnwrap(summaries.first { $0.model == "deepseek-reasoner" })
        XCTAssertEqual(try XCTUnwrap(timeDependent.apiCostUSD), 0.000017, accuracy: 0.000000001)
        XCTAssertEqual(timeDependent.unpricedRequests, 0)
        let alias = try XCTUnwrap(summaries.first { $0.model == "openai/gpt-5.5-2026-04-23" })
        XCTAssertEqual(alias.apiCostUSD, 0.0008)
        let fast = try XCTUnwrap(summaries.first { $0.model == "gpt-6.1-sol-fast" })
        XCTAssertEqual(fast.apiCostUSD, 0.0006)
        let halfUp = try XCTUnwrap(summaries.first { $0.client == .claudeDesktop && $0.model == "gpt-5.5" })
        XCTAssertEqual(halfUp.apiCostUSD, 0.000001)
        let free = try XCTUnwrap(summaries.first { $0.model == "glm-4.7-flash" })
        XCTAssertEqual(free.apiCostUSD, 0)
        XCTAssertEqual(free.unpricedRequests, 0)
    }

    func testSharedPriceBookUsesEventTimeForDeepSeekPeakHolidayAndHistoricalRates() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("timed-prices.sqlite"))
        let cases: [(String, String, Double)] = [
            ("peak", "2026-10-30T01:00:00Z", 1.4412),
            ("before-boundary", "2026-10-30T03:59:59Z", 1.4412),
            ("offpeak", "2026-10-30T04:00:00Z", 0.7206),
            ("second-peak", "2026-10-30T06:00:00Z", 1.4412),
            ("second-end", "2026-10-30T10:00:00Z", 0.7206),
            ("weekend", "2026-10-31T02:00:00Z", 0.7206),
            ("holiday", "2026-10-01T02:00:00Z", 0.7206),
            ("historical", "2026-08-10T02:00:00Z", 0.39256),
            ("older-peak", "2026-08-17T02:00:00Z", 1.6748)
        ]
        let formatter = ISO8601DateFormatter()
        for (id, time, _) in cases {
            _ = try ledger.ingest([ClientUsageEvent(client: .deepseek, eventID: id, sessionID: id,
                model: "\(id)/deepseek-v4-flash", timestamp: try XCTUnwrap(formatter.date(from: time)),
                inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 200_000,
                cacheWriteTokens: nil)])
        }
        let summaries = try ledger.summaries()
        for (id, _, expected) in cases {
            let row = try XCTUnwrap(summaries.first { $0.model == "\(id)/deepseek-v4-flash" })
            XCTAssertEqual(try XCTUnwrap(row.apiCostUSD), expected, accuracy: 0.000000001, id)
            XCTAssertEqual(row.unpricedRequests, 0, id)
        }
    }

    func testPriceAggregateCacheInvalidatesWhenLedgerRevisionChanges() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        func request(_ id: String) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 100,
                outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([request("first")])
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.0003)
        _ = try ledger.ingest([request("second")])
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.0006)
        XCTAssertEqual(try ledger.summaries().first?.requests, 2)
    }

    func testSinceSummariesIncludeExactCutoffAndPriceEachPeriodIndependently() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todayStart = Calendar.current.startOfDay(for: now)
        let sevenDayStart = Date(timeIntervalSince1970:
            floor((now.timeIntervalSince1970 - 7 * 24 * 60 * 60) / 300) * 300)
        func request(_ id: String, at timestamp: Date) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: timestamp, inputTokens: 100, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([
            request("before-seven-days", at: sevenDayStart.addingTimeInterval(-1)),
            request("at-seven-day-cutoff", at: sevenDayStart),
            request("before-today", at: todayStart.addingTimeInterval(-1)),
            request("at-today-cutoff", at: todayStart),
            request("current", at: now)
        ])

        let allTime = try XCTUnwrap(ledger.summaries().first)
        let sevenDays = try XCTUnwrap(ledger.summaries(since: sevenDayStart).first)
        let today = try XCTUnwrap(ledger.summaries(since: todayStart).first)
        XCTAssertEqual(allTime.requests, 5)
        XCTAssertEqual(allTime.apiCostUSD, 0.0015)
        XCTAssertEqual(sevenDays.requests, 4, "The exact lower boundary is included")
        XCTAssertEqual(sevenDays.apiCostUSD, 0.0012)
        XCTAssertEqual(today.requests, 2, "Local midnight is included and the prior second is excluded")
        XCTAssertEqual(today.apiCostUSD, 0.0006)
        XCTAssertTrue(today.cacheReadComplete)
        XCTAssertEqual(today.unpricedRequests, 0)
    }

    func testSinceSummaryCacheSeparatesCutoffsAndInvalidatesOnRevision() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        func request(_ id: String, at offset: TimeInterval) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: anchor.addingTimeInterval(offset), inputTokens: 100, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([request("old", at: -1_000), request("new", at: -500)])
        let broadCutoff = anchor.addingTimeInterval(-1_000)
        let narrowCutoff = anchor.addingTimeInterval(-500)
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.requests, 2)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.requests, 1)
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.apiCostUSD, 0.0006)

        _ = try ledger.ingest([request("newer", at: -250)])
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.requests, 3)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.requests, 2)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.apiCostUSD, 0.0006)
    }

    func testScannerReturnsAllTimeTodayAndSevenDayModelSummaries() async throws {
        let database = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: database)
        _ = try ledger.ingest([
            ClientUsageEvent(client: .claudeCode, eventID: "now", sessionID: "now", model: "gpt-6.1-sol",
                timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        ])
        let scanner = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
        let result = try await scanner.scan([])
        XCTAssertEqual(result.summaries.first?.requests, 1)
        XCTAssertEqual(result.todaySummaries.first?.requests, 1)
        XCTAssertEqual(result.sevenDaySummaries.first?.requests, 1)
        XCTAssertEqual(result.todaySummaries.first?.apiCostUSD, 0.0003)
        XCTAssertEqual(result.sevenDaySummaries.first?.apiCostUSD, 0.0003)
    }

    func testPricingRowsAndSummaryStayOnOneSQLiteReadSnapshot() throws {
        let url = root.appendingPathComponent("usage.sqlite")
        let reader = try MultiClientUsageLedger(url: url)
        let writer = try MultiClientUsageLedger(url: url)
        func pricedEvent(_ id: String) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 100,
                outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try writer.ingest([pricedEvent("first")])

        try reader.database.withConnection { connection in
            try connection.readTransaction { snapshot in
                let revisionBefore = try snapshot.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first!
                let countBefore = try snapshot.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) ?? 0 }.first!
                _ = try writer.ingest([pricedEvent("second")])
                let revisionAfter = try snapshot.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first!
                let countAfter = try snapshot.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) ?? 0 }.first!
                XCTAssertEqual(revisionAfter, revisionBefore)
                XCTAssertEqual(countAfter, countBefore)
            }
        }

        let summaries = try reader.summaries()
        XCTAssertEqual(summaries.first?.requests, 2)
        XCTAssertEqual(summaries.first?.apiCostUSD, 0.0006)
    }
    func testDeletionKeepsLedgerAndPartialTailIsNotSkipped() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        let line = "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}"
        try Data(line.dropLast(4).utf8).write(to: path)
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        let partial = try await scanner.scan([preference]); XCTAssertTrue(partial.summaries.isEmpty)
        try Data((line + "\n").utf8).write(to: path)
        let complete = try await scanner.scan([preference]); XCTAssertEqual(complete.summaries.first?.outputTokens, 20)
        try FileManager.default.removeItem(at: path)
        let deleted = try await scanner.scan([preference]); XCTAssertEqual(deleted.summaries.first?.outputTokens, 20)
    }
    func testPrefixRewriteInGrowingFileIsRescannedAndAppendDoesNotDoubleCount() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        func line(_ id: String, _ output: Int) -> String {
            "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":\(output)}}}\n"
        }
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        try Data(line("m1", 20).utf8).write(to: path)
        _ = try await scanner.scan([preference])
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line("m2", 30).utf8)); try handle.close()
        let appended = try await scanner.scan([preference])
        XCTAssertEqual(appended.summaries.first?.outputTokens, 50)
        let rewrite = try FileHandle(forWritingTo: path)
        try rewrite.write(contentsOf: Data((line("m1", 40) + line("m2", 30) + line("m3", 50)).utf8)); try rewrite.close()
        let rewritten = try await scanner.scan([preference])
        XCTAssertEqual(rewritten.summaries.first?.outputTokens, 120)
        XCTAssertEqual(rewritten.summaries.first?.requests, 3)
    }
    @MainActor func testPreferencesArePersistentAndDefaultsDoNotChangeCodexDisplay() {
        let name = "multi-client-prefs-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertFalse(store.preferences.contains { $0.enabled || $0.showMenuBar || $0.showSidebar })
        var value = store.preferences[0]; value.color = "#123456"; value.showSidebar = true
        store.update(value)
        let next = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertEqual(next.preferences[0].color, "#123456"); XCTAssertTrue(next.preferences[0].showSidebar)
        XCTAssertNil(defaults.object(forKey: "quotaSidebarEnabled"))
    }
}
