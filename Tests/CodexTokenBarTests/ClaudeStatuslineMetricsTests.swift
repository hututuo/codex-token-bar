import XCTest
@testable import CodexTokenBar

final class ClaudeStatuslineMetricsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testAPIDeltaIsSessionAndModelBoundAndRejectsRollback() {
        let old = ClaudeStatuslineMetrics(session: "a", model: "claude-sonnet", capturedAt: now, output: 100, apiMilliseconds: 1000, contextUsed: nil, contextSize: nil)
        let new = ClaudeStatuslineMetrics(session: "a", model: "claude-sonnet", capturedAt: now.addingTimeInterval(5), output: 300, apiMilliseconds: 5000, contextUsed: nil, contextSize: nil)
        let sample = new.sample(after: old)
        XCTAssertEqual(sample?.tps, 50)
        XCTAssertEqual(sample?.duration, 4)
        XCTAssertEqual(sample?.session.count, 64)
        XCTAssertTrue(sample?.qualified == true)
        XCTAssertNil(old.sample(after: new))
        XCTAssertNil(new.sample(after: .init(session: "other", model: old.model, capturedAt: old.capturedAt, output: 100, apiMilliseconds: 1000, contextUsed: nil, contextSize: nil)))
        XCTAssertNil(new.sample(after: .init(session: old.session, model: "other", capturedAt: old.capturedAt, output: 100, apiMilliseconds: 1000, contextUsed: nil, contextSize: nil)))
    }
    func testStatuslineRejectsStaleAndImpossibleCountsWithoutReadingTranscript() throws {
        let input: [String: Any] = ["schema_version": 1, "captured_at_epoch": now.timeIntervalSince1970,
            "session_id": "session", "model": ["id": "claude-sonnet"], "cost": ["total_api_duration_ms": 12000],
            "context_window": ["total_output_tokens": 300, "context_window_size": 200000,
                "current_usage": ["input_tokens": 100, "cache_read_input_tokens": 200]],
            "prompt": "never exposed", "api_key": "never exposed"]
        let data = try JSONSerialization.data(withJSONObject: input)
        let parsed = ClaudeStatuslineMetrics.decode(data, now: now)
        XCTAssertEqual(parsed?.contextUsed, 300)
        XCTAssertEqual(parsed?.contextSize, 200000)
        XCTAssertNil(ClaudeStatuslineMetrics.decode(data, now: now.addingTimeInterval(601)))
        XCTAssertNil(ClaudeStatuslineMetrics.decode(Data(repeating: 32, count: 65537), now: now))
        var invalid = input
        invalid["context_window"] = ["total_output_tokens": true]
        XCTAssertNil(ClaudeStatuslineMetrics.decode(try JSONSerialization.data(withJSONObject: invalid), now: now))
    }
    func testSeparateSQLiteRetainsSevenDaysAndDeduplicatesWithoutTouchingUsageLedger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = ClaudeLocalSpeedLedger(url: root.appendingPathComponent("speed.sqlite"))
        let sample = ClaudeAPISpeedSample(id: "same", session: "opaque", model: "c", endedAt: now, outputTokens: 200, duration: 4)
        _ = try await db.records(adding: sample, now: now)
        let rows = try await db.records(adding: sample, now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].qualified)
        let pruned = try await db.records(now: now.addingTimeInterval(7 * 86400 + 1))
        XCTAssertTrue(pruned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("multi-client-usage.sqlite").path))
    }
    func testRollingAPIAveragesUseTokenAndDurationWeightsAndExcludeUntrustedSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = ClaudeLocalSpeedLedger(url: root.appendingPathComponent("speed.sqlite"))
        _ = try await db.records(adding: .init(id: "one", session: "s", model: "c", endedAt: now.addingTimeInterval(-600), outputTokens: 400, duration: 4), now: now)
        _ = try await db.records(adding: .init(id: "two", session: "s", model: "c", endedAt: now, outputTokens: 50, duration: 1), now: now)
        _ = try await db.records(adding: .init(id: "bad", session: "s", model: "c", endedAt: now, outputTokens: 500, duration: 0.008), now: now)
        let (windows, buckets) = try await db.aggregates(now: now)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.five, 50)
        XCTAssertEqual(windows.first?.fifteen, 90)
        XCTAssertEqual(windows.first?.thirty, 90)
        XCTAssertEqual(windows.first?.latest, 50)
        XCTAssertEqual(buckets.count, 2)
    }

    func testSelectedScopeCannotLeakCodexRatesOrTasks() {
        let codex = RunningThreadSummary(main: 3, subagents: 2, updatedAt: now, freshness: .fresh)
        let claude = RunningThreadSummary(main: 1, subagents: 4, updatedAt: now, freshness: .fresh)
        XCTAssertEqual(ClientLocalRuntimePresentation.running(codex: codex, claude: claude, allowed: ["claudeCode"]).total, 5)
        XCTAssertEqual(ClientLocalRuntimePresentation.running(codex: codex, claude: claude, allowed: ["codex", "claudeCode"]).total, 10)
        let rates = ClientLocalRuntimePresentation.rates(codex: [.init(model: "gpt", tokensPerSecond: 80)], claude: [.init(model: "claude", tokensPerSecond: 40)], allowed: ["claudeCode"])
        XCTAssertEqual(rates, [.init(model: "claude", tokensPerSecond: 40)])
    }

    func testNewLocalCaptureDoesNotFallBackToAnotherOlderAccountCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let current = home.appendingPathComponent("Library/Application Support/CodexTokenBar/claude-local-statusline/latest.json")
        let legacy = home.appendingPathComponent(".claude-monitor/statusline/latest.json")
        func write(_ url: URL, time: Date, used: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let object: [String: Any] = ["captured_at_epoch": time.timeIntervalSince1970, "rate_limits": ["seven_day": ["used_percentage": used, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        try write(legacy, time: now, used: 15)
        XCTAssertEqual(ClaudeLocalQuota.read(home: home, now: now).sevenDay?.usedPercent, 15)
        try write(current, time: now, used: 75)
        XCTAssertEqual(ClaudeLocalQuota.read(home: home, now: now).sevenDay?.usedPercent, 75)
        try write(current, time: now.addingTimeInterval(-601), used: 75)
        let stale = ClaudeLocalQuota.read(home: home, now: now)
        XCTAssertEqual(stale.state, "stale")
        XCTAssertNil(stale.sevenDay)
    }
}
