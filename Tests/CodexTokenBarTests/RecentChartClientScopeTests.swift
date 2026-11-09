import Foundation
import XCTest
@testable import CodexTokenBar

final class RecentChartClientScopeTests: XCTestCase {
    func testChartClientSelectionIsIndependentAndUnavailableChoiceFollowsPage() {
        let page: Set<String> = ["codex", "claudeCode"]
        let available = ["claudeCode", "antigravity"]
        XCTAssertEqual(RecentChartClientScope.resolved("dashboard", page: page, available: available), page)
        XCTAssertEqual(RecentChartClientScope.resolved("antigravity", page: page, available: available), ["antigravity"])
        XCTAssertEqual(RecentChartClientScope.resolved("codex", page: page, available: available), ["codex"])
        XCTAssertEqual(RecentChartClientScope.resolved("all", page: page, available: available), ["codex", "claudeCode", "antigravity"])
        XCTAssertEqual(RecentChartClientScope.resolved("removed-client", page: page, available: available), page)
        XCTAssertEqual(page, ["codex", "claudeCode"])
    }

    func testChartClientProjectionKeepsTokenSourcesSeparateAcrossAllRanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets: [ClientTrendBucket] = [
            .init(client: .claudeCode, startUnix: Int64(now.timeIntervalSince1970),
                  inputTokens: 100, outputTokens: 20, cacheReadTokens: 60, cacheWriteTokens: nil, reasoningTokens: nil, requests: 2),
            .init(client: .antigravity, startUnix: Int64(now.timeIntervalSince1970),
                  inputTokens: 50, outputTokens: 20, cacheReadTokens: nil, cacheWriteTokens: nil, reasoningTokens: nil, requests: 1)
        ]
        for (client, tokens) in [("claudeCode", 120), ("antigravity", 70)] {
            let allowed = RecentChartClientScope.resolved(client, page: ["codex"], available: [client])
            let value = ClientDashboardProjection.snapshot(codex: .empty, rows: [], trend: buckets, daily: [], allowed: allowed, now: now)
            XCTAssertEqual(value.recentBins.reduce(0) { $0 + $1.tokens }, tokens)
            XCTAssertEqual(value.hourlyUsage.reduce(0) { $0 + $1.tokens }, tokens)
            XCTAssertFalse(value.cacheUsage.attributionEventsComplete)
            XCTAssertTrue(value.cacheUsage.attributionEvents.isEmpty)
        }
    }
}
