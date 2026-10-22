import SQLite3
import XCTest
@testable import CodexTokenBar

final class CacheUsageAdviceTests: XCTestCase {
    func testEffortChangeCanAlertFromReportedUncachedTokens() throws {
        var tracker = CacheUsageAdviceTracker()
        for (at, effort, total, cached) in [(100.0, "low", UInt64(20_000), UInt64(19_000)), (101.0, "max", UInt64(40_000), UInt64(0))] {
            let context = try XCTUnwrap(CacheUsageSample.parse(object: ["type": "turn_context"],
                payload: ["model": "same-model", "effort": effort, "reasoning_effort": effort], timestamp: at))
            tracker.consume(context, threadID: "a", now: at)
            tracker.consume(sample(at, total: total, cached: cached), threadID: "a", now: at)
        }
        XCTAssertEqual(tracker.latest(now: 101)?.hitRate, 0)
        XCTAssertEqual(tracker.latest(now: 101)?.low, true)
    }

    func testReminderIgnoresTaskTimingEvents() {
        for kind in ["task_started", "task_complete"] {
            XCTAssertNil(CacheUsageSample.parse(object: ["type": "event_msg"],
                payload: ["type": kind, "turn_id": "a", "started_at": "2026-10-15T00:00:00Z"], timestamp: 1))
        }
    }

    func testStateReaderUsesExplicitNameAndReviewSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-advice-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE threads (id TEXT, title TEXT, name TEXT, first_user_message TEXT,
          thread_source TEXT, rollout_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('named', 'first prompt text', '正式会话标题', 'first prompt text',
          'user', '/named', 1, 1000, 0);
        INSERT INTO threads VALUES ('review', 'Guardian review', 'Guardian review', '',
          'guardian_review', '/review', 2, 2000, 0);
        INSERT INTO threads VALUES ('untitled', 'first prompt only', '', 'first prompt only',
          'user', '/untitled', 3, 3000, 0);
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        let threads = try LiveRateMonitor.recentThreads(stateDB: path)
        XCTAssertEqual(threads.first { $0.id == "named" }?.title, "正式会话标题")
        XCTAssertEqual(threads.first { $0.id == "review" }?.threadSource, "guardian_review")
        XCTAssertEqual(threads.first { $0.id == "untitled" }?.title, "")
    }
    func testReminderPresentationRequiresFreshValidRequestAndDismissesOnlyThatRequest() {
        var advice = CacheUsageAdvice(threadID: "private-id", hitRate: 0, low: true, timestamp: 100, threadTitle: "  修复\n 金额显示  ")
        XCTAssertEqual(advice.displayTitle, "修复 金额显示")
        XCTAssertTrue(advice.shouldRemind(enabled: true, now: 100))
        XCTAssertFalse(advice.shouldRemind(enabled: false, now: 100))
        let dismissedID = advice.presentationID
        XCTAssertFalse(advice.shouldRemind(enabled: true, dismissedID: dismissedID, now: 100))
        advice.timestamp = 101
        XCTAssertTrue(advice.shouldRemind(enabled: true, dismissedID: dismissedID, now: 101))
        XCTAssertFalse(advice.shouldRemind(enabled: true, now: 100))
        XCTAssertFalse(advice.shouldRemind(enabled: true, now: 222))
        advice.threadTitle = "  \n "
        XCTAssertEqual(advice.displayTitle, "无标题会话")
        advice.threadTitle = nil
        XCTAssertEqual(advice.displayTitle, "无标题会话")
        for rate in [Double.nan, .infinity, -1, 2] {
            advice.hitRate = rate
            XCTAssertFalse(advice.shouldRemind(enabled: true, now: 101))
        }
    }

    @MainActor
    func testReminderTitleBelongsToAffectedThreadNotSelectedThread() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "selected", threadOptions: [
            LiveThreadOption(id: "selected", title: "当前选中任务", updatedAtMS: 1, rolloutPath: "/selected"),
            LiveThreadOption(id: "low", title: "缓存偏低任务", updatedAtMS: 1, rolloutPath: "/low")
        ])
        monitor.testProcessPollInputs(streamRows: [], rolloutReads: [
            LiveRateMonitor.RolloutRead(threadID: "low", path: "/low", newOffset: 100, events: [],
                cacheSamples: [sample(100, total: 20_000), sample(101, total: 40_000)])
        ], now: 102)
        XCTAssertEqual(monitor.totalSnapshot.cacheAdvice?.threadTitle, "缓存偏低任务")
        XCTAssertNil(monitor.snapshot.cacheAdvice)
        XCTAssertEqual(monitor.totalSnapshot.outputTokens, 0)
    }

    func testSharedCrossPlatformFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/cache-usage-advice.json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for fixture in cases {
            var tracker = CacheUsageAdviceTracker()
            for row in try XCTUnwrap(fixture["steps"] as? [[String: Any]]) {
                let at = try XCTUnwrap(row["at"] as? Double)
                tracker.consume(CacheUsageSample(timestamp: at,
                    input: (row["input"] as? NSNumber)?.uint64Value,
                    cached: (row["cached"] as? NSNumber)?.uint64Value,
                    total: (row["total"] as? NSNumber)?.uint64Value,
                    requestTotal: (row["requestTotal"] as? NSNumber)?.uint64Value),
                    threadID: row["thread"] as? String ?? "a", now: at, monotonic: at)
                XCTAssertEqual(tracker.latest(now: at)?.low, row["low"] as? Bool, "\(fixture["name"] ?? "") at \(at)")
            }
        }
    }

    @MainActor
    func testAdvicePublishesWithoutAnyRateEventAndClearsOnSourceChange() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "a")
        monitor.testProcessPollInputs(streamRows: [], rolloutReads: [
            LiveRateMonitor.RolloutRead(threadID: "a", path: "/test", newOffset: 100, events: [],
                cacheSamples: [sample(100, total: 20_000), sample(101, total: 40_000)])
        ], now: 102)
        XCTAssertEqual(monitor.snapshot.cacheAdvice?.low, true)
        XCTAssertEqual(monitor.snapshot.outputTokens, 0)
        XCTAssertEqual(monitor.snapshot.rollingTokensPerSecond, 0)
        monitor.testActivatePollingWithoutScheduling()
        monitor.setMonitoringEnabled(false)
        XCTAssertNil(monitor.snapshot.cacheAdvice)
        XCTAssertNil(monitor.totalSnapshot.cacheAdvice)
        monitor.resetSourceLocalState(for: nil)
        XCTAssertNil(monitor.snapshot.cacheAdvice)
        XCTAssertNil(monitor.totalSnapshot.cacheAdvice)
    }

    func testIncrementalReadDoesNotReplayOnRewriteOrRevisit() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data().write(to: path)
        let initial = LiveRateMonitor.initialRolloutReadState(path: path.path)
        let line = "{\"timestamp\":\"2026-09-16T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":20000,\"cached_input_tokens\":100}}}}\n"
        try Data(line.utf8).write(to: path)
        let first = try LiveRateMonitor.rolloutEvents(path: path.path, state: initial)
        XCTAssertEqual(first.cacheSamples.count, 1)
        let second = try LiveRateMonitor.rolloutEvents(path: path.path, state: first.state)
        XCTAssertTrue(second.cacheSamples.isEmpty)
        // Atomic replacement has a new inode even if the file grows.
        try Data((line + line).utf8).write(to: path, options: .atomic)
        let rewritten = try LiveRateMonitor.rolloutEvents(path: path.path, state: second.state)
        XCTAssertTrue(rewritten.cacheReset)
        XCTAssertTrue(rewritten.cacheSamples.isEmpty)
    }

    @MainActor
    func testExistingTailEstablishesHistoryWithoutReplayingAndWorksWithLegacyUsage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let old = #"{"timestamp":"1970-01-01T00:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20000,"cached_input_tokens":0}}}}"# + "\n"
        try Data(old.utf8).write(to: path)
        let option = LiveThreadOption(id: "old", title: "old", updatedAtMS: 0, rolloutPath: path.path)
        let initial = LiveRateMonitor.initialRolloutReadState(path: path.path)
        XCTAssertTrue(initial.initialCacheContextEstablished)
        let initialReads = try LiveRateMonitor.rolloutReads(options: [option], states: [path.path: initial])
        XCTAssertTrue(initialReads[0].events.isEmpty)
        XCTAssertEqual(initialReads[0].cacheSamples.count, 1)
        XCTAssertTrue(initialReads[0].cacheSamples[0].establishedContext)
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "old")
        monitor.testProcessPollInputs(streamRows: [], rolloutReads: initialReads, now: 100)
        XCTAssertNil(monitor.totalSnapshot.cacheAdvice, "Historical low requests must not publish a warning")
        monitor.testProcessPollInputs(streamRows: [], rolloutReads: [
            LiveRateMonitor.RolloutRead(threadID: "old", path: path.path, newOffset: initial.offset,
                events: [], cacheSamples: [sample(101, cached: 0)])
        ], now: 101)
        XCTAssertEqual(monitor.totalSnapshot.cacheAdvice?.low, true,
                       "A known old context must not depend on new cumulative fields")
        XCTAssertEqual(monitor.totalSnapshot.outputTokens, 0)
    }

    private func settledRequest(at: Double, total: UInt64 = 29_374_965) -> CacheUsageSample {
        CacheUsageSample(timestamp: at, input: 153_566, cached: 0,
                         total: total, requestTotal: 154_786)
    }

    func testResumedOldLunaRequestAlertsOnFirstFreshObservation() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(settledRequest(at: 100), threadID: "old-luna", now: 100)
        XCTAssertEqual(tracker.latest(now: 100)?.hitRate, 0)
        XCTAssertEqual(tracker.latest(now: 100)?.low, true)
        XCTAssertEqual(tracker.latest(now: 100)?.shouldRemind(enabled: true, now: 100), true)
        // Structural loss of monitor state is not a new Codex context.
        tracker.reset(threadID: "old-luna")
        tracker.consume(settledRequest(at: 101, total: 29_529_751), threadID: "old-luna", now: 101)
        XCTAssertEqual(tracker.latest(now: 101)?.low, true)
    }

    func testExplicitCompactionSuppressesOnlyFirstValidRequestDespiteHistoricalTotals() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(CacheUsageSample(timestamp: 90, reset: true), threadID: "a", now: 90)
        tracker.consume(CacheUsageSample(timestamp: 91, model: "luna", context: true), threadID: "a", now: 91)
        tracker.consume(CacheUsageSample(timestamp: 99, input: 0, cached: 0,
                                         total: 29_374_965, requestTotal: 46_632), threadID: "a", now: 99)
        XCTAssertNil(tracker.latest(now: 99))
        tracker.consume(settledRequest(at: 200), threadID: "a", now: 200)
        XCTAssertEqual(tracker.latest(now: 200)?.low, false)
        tracker.consume(settledRequest(at: 201, total: 29_529_751), threadID: "a", now: 201)
        XCTAssertEqual(tracker.latest(now: 201)?.low, true)
    }

    func testParserPreservesServerRequestTotalForColdStartRecovery() throws {
        let line = #"{"timestamp":"2026-10-22T06:21:01.406Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":153566,"cached_input_tokens":0,"output_tokens":1220,"total_tokens":154786},"total_token_usage":{"total_tokens":29374965}}}}"#
        let parsed = LiveRateMonitor.rolloutEvents(fromLines: [line], previousTurnID: nil)
        let sample = try XCTUnwrap(parsed.cacheSamples.first)
        XCTAssertEqual(sample.requestTotal, 154_786)
        XCTAssertTrue(parsed.events.isEmpty, "Input cache observations must not become TPS output")
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(sample, threadID: "luna", now: sample.timestamp)
        XCTAssertEqual(tracker.latest(now: sample.timestamp)?.low, true)
    }

    @MainActor
    func testSourceReinitializationStillAlertsOnFirstOldSessionRequest() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        for at in [100.0, 101.0] {
            monitor.testPrepareForLiveRateProcessing(selectedThreadID: "old")
            monitor.testProcessPollInputs(streamRows: [], rolloutReads: [
                LiveRateMonitor.RolloutRead(threadID: "old", path: "/old", newOffset: UInt64(at), events: [],
                    cacheSamples: [settledRequest(at: at)])
            ], now: at)
            XCTAssertEqual(monitor.totalSnapshot.cacheAdvice?.low, true)
            XCTAssertEqual(monitor.totalSnapshot.outputTokens, 0)
        }
    }

    @MainActor
    func testStartupTailPreservesCompactionAndNeverReplaysOldUsage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let context = #"{"type":"turn_context","payload":{"turn_id":"old-turn","model":"gpt-6-luna"}}"# + "\n"
        let compacted = #"{"type":"compacted","payload":{}}"# + "\n"
        func request(_ at: Int, total: Int) -> String {
            "{\"timestamp\":\"1970-01-01T00:01:\(at)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":153566,\"cached_input_tokens\":0,\"total_tokens\":154786},\"total_token_usage\":{\"total_tokens\":\(total)}}}}\n"
        }
        try Data((request(20, total: 29_374_965) + compacted + context).utf8).write(to: path)
        let initial = LiveRateMonitor.initialRolloutReadState(path: path.path)
        XCTAssertTrue(initial.initialCacheContextReset)
        XCTAssertEqual(initial.currentTurnID, "old-turn")
        let option = LiveThreadOption(id: "a", title: "old", updatedAtMS: 0, rolloutPath: path.path)
        let reads = try LiveRateMonitor.rolloutReads(options: [option], states: [path.path: initial])
        XCTAssertTrue(reads[0].events.isEmpty)
        XCTAssertEqual(reads[0].cacheSamples.count, 1)
        XCTAssertTrue(reads[0].cacheSamples[0].reset)
        // A partially written following line does not invalidate a complete reset.
        let partialHandle = try FileHandle(forWritingTo: path)
        try partialHandle.seekToEnd(); try partialHandle.write(contentsOf: Data("{\"type\":\"event_msg\"".utf8)); try partialHandle.close()
        XCTAssertTrue(LiveRateMonitor.initialRolloutReadState(path: path.path).initialCacheContextReset)
        try Data((request(20, total: 29_374_965) + compacted + context).utf8).write(to: path)
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(reads[0].cacheSamples[0], threadID: "a", now: 100)
        XCTAssertNil(tracker.latest(now: 100), "Historical markers never publish a warning")
        tracker.consume(settledRequest(at: 100), threadID: "a", now: 100)
        XCTAssertEqual(tracker.latest(now: 100)?.low, false)
        let noReplay = try LiveRateMonitor.rolloutReads(options: [option], states: [path.path: reads[0].state])
        XCTAssertTrue(noReplay[0].cacheSamples.isEmpty, "Startup seed is consumed once")
        // Once a valid request follows compaction, the context is established.
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(request(40, total: 29_529_751).utf8)); try handle.close()
        XCTAssertFalse(LiveRateMonitor.initialRolloutReadState(path: path.path).initialCacheContextReset)
        // An atomic rewrite is structural: recover its explicit marker without
        // replaying any historical request in the rewrite batch.
        try Data((compacted + context).utf8).write(to: path, options: .atomic)
        let rewritten = try LiveRateMonitor.rolloutReads(options: [option], states: [path.path: noReplay[0].state])
        XCTAssertTrue(rewritten[0].cacheReset)
        XCTAssertTrue(rewritten[0].cacheSamples.isEmpty)
        XCTAssertTrue(rewritten[0].state.initialCacheContextReset)
        let afterRewrite = try LiveRateMonitor.rolloutReads(options: [option], states: [path.path: rewritten[0].state])
        XCTAssertEqual(afterRewrite[0].cacheSamples.count, 1)
        XCTAssertTrue(afterRewrite[0].cacheSamples[0].reset)
    }

    func testStartupResetBackscanIgnoresTruncatedMarkerOutsideExistingByteLimit() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let compacted = #"{"type":"compacted","payload":{}}"# + "\n"
        let largeLine = #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: 70_000) + #""}}"# + "\n"
        let context = #"{"type":"turn_context","payload":{"turn_id":"latest","model":"gpt-6-luna"}}"# + "\n"
        try Data((compacted + largeLine + context).utf8).write(to: path)
        let state = LiveRateMonitor.initialRolloutReadState(path: path.path)
        XCTAssertFalse(state.initialCacheContextReset, "Do not extend the bounded tail search or guess unseen markers")
        XCTAssertEqual(state.currentTurnID, "latest")
        XCTAssertEqual(state.offset, UInt64(try Data(contentsOf: path).count))
    }

    private func sample(_ at: Double, total: UInt64? = nil, cached: UInt64 = 100,
                        input: UInt64 = 20_000) -> CacheUsageSample {
        CacheUsageSample(timestamp: at, input: input, cached: cached, total: total)
    }

    func testColdFirstRequestDoesNotAlertAndDuplicateDoesNotRepublish() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(sample(100, total: 20_000), threadID: "a", now: 100, monotonic: 100)
        XCTAssertEqual(tracker.latest(now: 100)?.low, false)
        tracker.consume(sample(101, total: 20_000), threadID: "a", now: 101, monotonic: 101)
        XCTAssertEqual(tracker.latest(now: 101)?.low, false)
        XCTAssertEqual(tracker.latest(now: 101)?.timestamp, 100)
        tracker.consume(CacheUsageSample(timestamp: 102, context: true), threadID: "a", now: 102)
        tracker.consume(sample(103, total: 40_000), threadID: "a", now: 103, monotonic: 103)
        XCTAssertEqual(tracker.latest(now: 103)?.low, true)
    }

    func testCompactionReestablishesBaselineBeforeAlerting() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(sample(100, total: 20_000), threadID: "a", now: 100)
        tracker.consume(sample(101, total: 40_000), threadID: "a", now: 101)
        XCTAssertEqual(tracker.latest(now: 101)?.low, true)
        tracker.consume(CacheUsageSample(timestamp: 102, reset: true), threadID: "a", now: 102)
        tracker.consume(sample(103, total: 20_000), threadID: "a", now: 103)
        XCTAssertEqual(tracker.latest(now: 103)?.low, false)
        tracker.consume(sample(104, total: 40_000), threadID: "a", now: 104)
        XCTAssertEqual(tracker.latest(now: 104)?.low, true)
    }

    @MainActor
    func testGuardianReviewDoesNotPublishCacheWarning() {
        let monitor = LiveRateMonitor(monitoringEnabled: false)
        monitor.testPrepareForLiveRateProcessing(selectedThreadID: "review", threadOptions: [
            LiveThreadOption(id: "review", title: "Review", updatedAtMS: 1, rolloutPath: "/review", threadSource: "guardian_review")
        ])
        monitor.testProcessPollInputs(streamRows: [], rolloutReads: [
            LiveRateMonitor.RolloutRead(threadID: "review", path: "/review", newOffset: 100, events: [],
                cacheSamples: [sample(100, total: 20_000), sample(101, total: 40_000)])
        ], now: 102)
        XCTAssertNil(monitor.totalSnapshot.cacheAdvice)
    }

    func testUnknownAndTinyInputDoNotDelayNextLowRequest() {
        for interruption in [CacheUsageSample(timestamp: 101), sample(101, total: 25_000, input: 200)] {
            var tracker = CacheUsageAdviceTracker()
            tracker.consume(sample(100, total: 20_000), threadID: "a", now: 100)
            tracker.consume(interruption, threadID: "a", now: 101)
            tracker.consume(sample(102, total: 40_000), threadID: "a", now: 102)
            XCTAssertEqual(tracker.latest(now: 102)?.low, true)
        }
    }

    func testIndependentSessionsModelResetAndExpiry() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(sample(100, total: 20_000), threadID: "a", now: 100)
        tracker.consume(sample(101, total: 40_000), threadID: "b", now: 101)
        XCTAssertEqual(tracker.latest(now: 101)?.low, false)
        tracker.consume(CacheUsageSample(timestamp: 102, model: "new-model", context: true), threadID: "a", now: 102)
        tracker.consume(sample(103, total: 60_000), threadID: "a", now: 103)
        XCTAssertEqual(tracker.latest(now: 103)?.low, true)
        XCTAssertNil(tracker.latest(now: 224))
    }

    func testValidLastUsageDoesNotWaitForRequestIdentity() {
        var tracker = CacheUsageAdviceTracker()
        for at in [100.0, 101.0, 102.0] { tracker.consume(sample(at), threadID: "a", now: at) }
        XCTAssertEqual(tracker.latest(now: 102)?.low, true)
        XCTAssertEqual(tracker.latest(now: 102)?.hitRate, 0.005)
    }

    func testRecoveryDoesNotDelayNextLowRequest() {
        var tracker = CacheUsageAdviceTracker()
        for (at, total, cached) in [(100.0, 20_000, 100), (101, 40_000, 100), (102, 60_000, 19_000), (103, 80_000, 100), (104, 100_000, 100)] {
            tracker.consume(sample(at, total: UInt64(total), cached: UInt64(cached)), threadID: "a", now: at, monotonic: at)
        }
        XCTAssertEqual(tracker.latest(now: 104)?.low, true)
        tracker.consume(sample(702, total: 120_000), threadID: "a", now: 702, monotonic: 702)
        tracker.consume(sample(703, total: 140_000), threadID: "a", now: 703, monotonic: 703)
        XCTAssertEqual(tracker.latest(now: 703)?.low, true)
    }

    func testFutureStaleAndRegressionCannotAlert() {
        var tracker = CacheUsageAdviceTracker()
        tracker.consume(sample(200, total: 20_000), threadID: "a", now: 100)
        XCTAssertNil(tracker.latest(now: 100))
        tracker.consume(sample(100, total: 20_000), threadID: "a", now: 221)
        XCTAssertNil(tracker.latest(now: 221))
        tracker.consume(sample(300, total: 20_000), threadID: "a", now: 300)
        tracker.consume(sample(301, total: 10_000), threadID: "a", now: 301)
        XCTAssertNil(tracker.latest(now: 301))
        tracker.consume(sample(302, total: 30_000), threadID: "a", now: 302)
        XCTAssertEqual(tracker.latest(now: 302)?.low, true)
    }

    func testParserHandlesZeroReasoningAndRejectsInvalidNumbers() throws {
        for input in ["true", "-1", "2.5", "null", "\"20000\""] {
            let parsed = try parse(input: input, cached: "0")
            XCTAssertNil(parsed.input)
        }
        let parsed = try parse(input: "20000", cached: "0")
        XCTAssertEqual(parsed.input, 20_000)
        XCTAssertEqual(parsed.cached, 0)
    }

    private func parse(input: String, cached: String) throws -> CacheUsageSample {
        let line = "{\"timestamp\":\"2026-09-16T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"reasoning_output_tokens\":0}}}}"
        let result = LiveRateMonitor.rolloutEvents(fromLines: [line], previousTurnID: nil)
        XCTAssertTrue(result.events.isEmpty, "Cache input must never enter rate accounting")
        return try XCTUnwrap(result.cacheSamples.first)
    }
}
