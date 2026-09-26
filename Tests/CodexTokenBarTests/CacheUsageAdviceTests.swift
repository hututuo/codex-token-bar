import SQLite3
import XCTest
@testable import CodexTokenBar

final class CacheUsageAdviceTests: XCTestCase {
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
                    total: (row["total"] as? NSNumber)?.uint64Value),
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
