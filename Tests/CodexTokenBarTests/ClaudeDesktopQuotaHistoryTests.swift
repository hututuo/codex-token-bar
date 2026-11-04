import XCTest
@testable import CodexTokenBar

final class ClaudeDesktopQuotaHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func bytes(_ samples: [[String: Any]], version: Any = 2) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "samples": samples])
    }
    func testLatestSampleKeepsSourceTimeWithoutInventingResetOrMixingOrganizations() throws {
        let data = try bytes([
            ["t": 1_799_999_999_000.0, "org": "old-org", "u": ["fh": 90, "sd": 80]],
            ["t": 1_800_000_000_000.0, "org": "new-org", "u": ["sd": 16]],
            ["t": 1_799_999_990_000.0, "org": "old-org", "u": ["fh": 99]]
        ])
        let quota = ClaudeLocalQuota.decodeDesktopHistory(data, now: now)
        XCTAssertEqual(quota.state, "available"); XCTAssertEqual(quota.capturedAt, now)
        XCTAssertNil(quota.fiveHour); XCTAssertEqual(quota.sevenDay?.usedPercent, 16)
        XCTAssertNil(quota.sevenDay?.resetsAt)
        let reading = ClaudeCapturedQuotaProvider(snapshot: quota, client: .claudeDesktop).reading()
        XCTAssertEqual(reading.client, "claudeDesktop"); XCTAssertEqual(reading.source, "local-desktop-history")
        XCTAssertEqual(reading.capturedAt, now); XCTAssertNil(reading.windows.first?.resetsAt)
        XCTAssertFalse(reading.notice.contains("old-org")); XCTAssertFalse(reading.notice.contains("new-org"))
        let tied = try bytes([["t": 1_800_000_000_000.0, "u": ["fh": 70, "sd": 80]], ["t": 1_800_000_000_000.0, "u": ["fh": 13]]])
        let last = ClaudeLocalQuota.decodeDesktopHistory(tied, now: now)
        XCTAssertEqual(last.fiveHour?.usedPercent, 13); XCTAssertNil(last.sevenDay)
    }
    func testNormalFifteenMinutePollIsFreshButTwentyMinuteGapExpires() throws {
        for (age, state) in [(900.0, "available"), (1_200.0, "available"), (1_201.0, "stale")] {
            let data = try bytes([["t": (now.timeIntervalSince1970-age)*1_000, "u": ["fh": 13, "sd": 29]]])
            let quota = ClaudeLocalQuota.decodeDesktopHistory(data, now: now)
            XCTAssertEqual(quota.state, state)
            XCTAssertEqual(quota.capturedAt?.timeIntervalSince1970, now.timeIntervalSince1970-age)
            if state == "stale" {
                XCTAssertNil(quota.fiveHour)
                let reading = ClaudeCapturedQuotaProvider(snapshot: quota, client: .claudeDesktop).reading()
                XCTAssertEqual(reading.state, "stale"); XCTAssertTrue(reading.windows.isEmpty)
            }
        }
    }
    func testNewestEmptyOrFutureSampleDoesNotResurrectOlderQuota() throws {
        let old: [String: Any] = ["t": 1_799_999_999_000.0, "u": ["fh": 55]]
        let empty = try bytes([old, ["t": 1_800_000_000_000.0, "u": [:]]])
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(empty, now: now).state, "missing")
        let future = try bytes([old, ["t": 1_800_000_061_000.0, "u": ["fh": 1]]])
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(future, now: now).state, "invalid")
    }
    func testLegacyVersionAndPartialCountersAreLocalObservationsOnly() throws {
        let legacy = try bytes([["t": 1_800_000_000_000.0, "fh": 0, "sd": 100]], version: 1)
        let quota = ClaudeLocalQuota.decodeDesktopHistory(legacy, now: now)
        XCTAssertEqual(quota.fiveHour?.usedPercent, 0); XCTAssertEqual(quota.sevenDay?.usedPercent, 100)
        let partial = try bytes([["t": 1_800_000_000_000.0, "u": ["fh": true, "sd": 25]]])
        let good = ClaudeLocalQuota.decodeDesktopHistory(partial, now: now)
        XCTAssertNil(good.fiveHour); XCTAssertEqual(good.sevenDay?.usedPercent, 25)
        for bad in [-1, 101] {
            XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(try bytes([["t": 1_800_000_000_000.0, "u": ["fh": bad]]]), now: now).state, "missing")
        }
    }
    func testInvalidSchemaCorruptionAndBoundsFailWithoutFallback() throws {
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(try bytes([], version: true), now: now).state, "invalid")
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(try bytes([], version: 3), now: now).state, "invalid")
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(Data("{\"samples\":[]}".utf8), now: now).state, "invalid")
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(Data("{".utf8), now: now).state, "invalid")
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(Data(repeating: 32, count: ClaudeLocalQuota.desktopHistoryMaximumBytes+1), now: now).state, "invalid")
        XCTAssertEqual(ClaudeLocalQuota.decodeDesktopHistory(try bytes(Array(repeating: ["t": 0], count: 50_001)), now: now).state, "invalid")
    }
    func testKnownPathReadDoesNotWriteAndRejectsSymlinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        XCTAssertEqual(ClaudeLocalQuota.readDesktopHistory(home: home, now: now).state, "missing")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try bytes([["t": 1_800_000_000_000.0, "org": "fixture-only", "u": ["fh": 13, "sd": 29]]])
        try raw.write(to: file)
        XCTAssertEqual(ClaudeLocalQuota.readDesktopHistory(home: home, now: now).fiveHour?.usedPercent, 13)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        let target = home.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(ClaudeLocalQuota.readDesktopHistory(home: home, now: now).state, "invalid")
        XCTAssertEqual(try Data(contentsOf: target), raw)
    }
}
