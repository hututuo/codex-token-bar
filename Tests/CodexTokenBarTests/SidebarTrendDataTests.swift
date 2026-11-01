import XCTest
@testable import CodexTokenBar

final class SidebarTrendDataTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func bin(_ tokens: Int) -> BinUsage { .init(start: start, tokens: tokens, calls: 1) }
    private var history: [QuotaHistoryRecentBucket] {
        [.init(start: start.addingTimeInterval(12), fiveHourRemainingPercent: nil, sevenDayRemainingPercent: 48)]
    }
    func testAggregateTokensKeepCodexQuotaInsteadOfDiscardingProjectedHistory() {
        let data = SidebarTrendData(codexBins: [bin(10)], projectedBins: [bin(30)], quota: history,
                                   clients: ClientDisplayScope.clients("all", available: ["claudeCode"]))
        XCTAssertEqual(data.bins.first?.tokens, 30)
        XCTAssertEqual(data.alignedQuota.first??.sevenDayRemainingPercent, 48)
        XCTAssertTrue(data.includesCodex)
    }
    func testCodexOnlyKeepsQuotaAndDoesNotInventUnavailableFiveHourWindow() {
        let data = SidebarTrendData(codexBins: [bin(10)], projectedBins: nil, quota: history, clients: ["codex"])
        XCTAssertEqual(data.bins.first?.tokens, 10)
        XCTAssertEqual(data.alignedQuota.first??.sevenDayRemainingPercent, 48)
        XCTAssertNil(data.alignedQuota.first??.fiveHourRemainingPercent)
    }
    func testClaudeOnlyDoesNotUseCodexQuota() {
        let data = SidebarTrendData(codexBins: [bin(10)], projectedBins: [bin(20)], quota: history, clients: ["claudeCode"])
        XCTAssertEqual(data.bins.first?.tokens, 20)
        XCTAssertFalse(data.includesCodex)
        XCTAssertTrue(data.quota.isEmpty)
        XCTAssertNil(data.alignedQuota.first!)
    }
    func testIsolatedQuotaSamplesAreVisibleWithoutInventingLinesThroughGaps() {
        XCTAssertEqual(SidebarTrendData.isolatedIndices([nil, 48, nil]), [1])
        XCTAssertEqual(SidebarTrendData.isolatedIndices([48, 47, nil, 46]), [3])
        XCTAssertEqual(SidebarTrendData.isolatedIndices([.nan, 0, .infinity]), [1])
    }
}
