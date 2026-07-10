import XCTest
@testable import CodexTokenBar

final class StatusBarTokenPanelTests: XCTestCase {
    func testStatusItemPresentationUpdatesWhenOnlyUnreadAccessibilityChanges() {
        let previous = StatusBarTokenItemPresentation(
            title: "    0.0/s    ",
            accessibilityValue: "实时速率 0.0 token 每秒"
        )
        let next = StatusBarTokenItemPresentation(
            title: "    0.0/s    ",
            accessibilityValue: "实时速率 0.0 token 每秒；未读会话 1 个"
        )

        XCTAssertTrue(next.needsApply(previous: previous))
    }

    func testStatusBarUsageMetricsUsePendingLabelsForMetadataOnlySnapshot() {
        let snapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            usagePrecision: .metadataOnly,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let presentation = StatusBarUsageMetricsPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.totalTokens, "待读取")
        XCTAssertEqual(presentation.todayTokens, "待读取")
        XCTAssertEqual(presentation.todayRequests, "待读取")
    }

    func testStatusBarUsageMetricsUsePreciseLabelsWhenAvailable() {
        let snapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 123_456,
            todayTokens: 7_890,
            todayRequests: 42,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let presentation = StatusBarUsageMetricsPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.totalTokens, snapshot.consumedTokensText)
        XCTAssertEqual(presentation.todayTokens, snapshot.todayTokensText)
        XCTAssertEqual(presentation.todayRequests, snapshot.todayRequestsText)
    }
}
