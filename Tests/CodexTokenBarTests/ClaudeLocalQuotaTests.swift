import XCTest
@testable import CodexTokenBar

final class ClaudeLocalQuotaTests: XCTestCase {
    func testApiSettingsSuppressOldSubscriptionCacheAndSwitchBackRestoresIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeAPI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Application Support/CodexTokenBar/claude-local-statusline/latest.json")
        let config = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try record().write(to: cache)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://relay.invalid"}}"#.utf8).write(to: config)
        let api = ClaudeLocalQuota.read(home: home, now: now, environment: [:])
        XCTAssertEqual(api.state, "api"); XCTAssertNil(api.fiveHour)
        XCTAssertEqual(ClaudeCapturedQuotaProvider(snapshot: api).reading().state, "api")
        try Data("{}".utf8).write(to: config)
        XCTAssertEqual(ClaudeLocalQuota.read(home: home, now: now, environment: [:]).fiveHour?.usedPercent, 25)
        XCTAssertTrue(ClaudeLocalQuota.usesAPI(home: home, environment: ["CLAUDE_CODE_USE_BEDROCK": "1"]))
        XCTAssertFalse(ClaudeLocalQuota.usesAPI(home: home, environment: ["CLAUDE_CODE_USE_BEDROCK": "0"]))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func record(captured: Double = 1_800_000_000, used: Double = 25, reset: Double = 1_800_003_600) -> Data {
        Data("{\"captured_at_epoch\":\(captured),\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(used),\"resets_at\":\(reset)}}}".utf8)
    }
    func testFreshProviderWindowAndAbsentSevenDay() {
        let quota = ClaudeLocalQuota.decode(record(), now: now)
        XCTAssertEqual(quota.state, "available"); XCTAssertEqual(quota.fiveHour?.usedPercent, 25)
        XCTAssertNil(quota.sevenDay)
    }
    func testStaleFutureExpiredAndImpossiblePercentAreNotPresented() {
        XCTAssertEqual(ClaudeLocalQuota.decode(record(captured: 1_799_999_399), now: now).state, "stale")
        XCTAssertEqual(ClaudeLocalQuota.decode(record(captured: 1_800_000_061), now: now).state, "invalid")
        XCTAssertNil(ClaudeLocalQuota.decode(record(reset: now.timeIntervalSince1970), now: now).fiveHour)
        XCTAssertNil(ClaudeLocalQuota.decode(record(used: 101), now: now).fiveHour)
    }
    func testNullTombstoneAndMissingCaptureDoNotEstimateFromTokens() {
        XCTAssertEqual(ClaudeLocalQuota.decode(Data("{\"captured_at_epoch\":1800000000,\"rate_limits\":null,\"tokens\":100000}".utf8), now: now).state, "missing")
        XCTAssertEqual(ClaudeLocalQuota.decode(Data("{}".utf8), now: now).state, "invalid")
    }
    func testLocalFileReaderRejectsOversizedQuotaCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Application Support/CodexTokenBar/claude-local-statusline/latest.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 65_537).write(to: cache)

        XCTAssertEqual(ClaudeLocalQuota.read(home: home, now: now).state, "invalid")
    }
}
