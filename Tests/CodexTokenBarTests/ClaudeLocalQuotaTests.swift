import XCTest
@testable import CodexTokenBar

final class ClaudeLocalQuotaTests: XCTestCase {
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
}
