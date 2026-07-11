import XCTest
@testable import CodexTokenBar

final class StatusBarTokenPanelTests: XCTestCase {
    func testClosedStatusItemRefreshUsesOneSecondCadence() {
        XCTAssertEqual(StatusBarRefreshCadence.statusItem, 1.0)
    }

    func testClosedPopoverDetachesContentAndReattachesLatestPresentationOnOpen() {
        let lifecycle = StatusBarPopoverContentLifecycle()

        XCTAssertFalse(lifecycle.isContentAttached)
        XCTAssertTrue(lifecycle.prepareToPresent())
        XCTAssertTrue(lifecycle.isContentAttached)
        XCTAssertFalse(lifecycle.prepareToPresent())
        XCTAssertTrue(lifecycle.didClose())
        XCTAssertFalse(lifecycle.isContentAttached)
        XCTAssertFalse(lifecycle.didClose())
        XCTAssertTrue(lifecycle.prepareToPresent())
    }

    func testStatusBarLifecycleKeepsTimerAndRootStableForSameOwnersAndTicks() {
        let owners = [NSObject(), NSObject(), NSObject(), NSObject()]
        let identity = StatusBarOwnerIdentity(
            store: owners[0],
            monitor: owners[1],
            quota: owners[2],
            taskCompletionMonitor: owners[3]
        )
        let lifecycle = StatusBarLifecycleState()

        XCTAssertEqual(lifecycle.bind(identity), .init(assignRoot: true, startTimer: true))
        XCTAssertEqual(lifecycle.bind(identity), .init(assignRoot: false, startTimer: false))
        let presentation = StatusBarTokenItemPresentation(title: "  42.4/s  ", accessibilityValue: "42.4")
        XCTAssertEqual(
            lifecycle.changes(for: presentation),
            .init(titleChanged: true, accessibilityChanged: true)
        )
        for _ in 0..<100 {
            XCTAssertEqual(
                lifecycle.changes(for: presentation),
                .init(titleChanged: false, accessibilityChanged: false)
            )
        }

        let replacement = NSObject()
        let changed = StatusBarOwnerIdentity(
            store: replacement,
            monitor: owners[1],
            quota: owners[2],
            taskCompletionMonitor: owners[3]
        )
        XCTAssertEqual(lifecycle.bind(changed), .init(assignRoot: true, startTimer: false))
        XCTAssertTrue(lifecycle.close())
    }

    func testStatusBarTitleAlwaysUsesOneDecimalForSafeRates() {
        for rate in [10.1, 42.4, 80.0, 100.0, 123.4] {
            let snapshot = TokenDisplaySnapshot(
                title: "全会话实时",
                status: "等待输出",
                rate: rate,
                consumedTokens: 0,
                todayTokens: 0,
                todayRequests: 0,
                quota: .empty,
                updatedAt: .distantPast
            )
            XCTAssertEqual(snapshot.statusBarTitle, String(format: "%.1f/s", rate))
        }
        for rate in [-1.0, .nan, .infinity] {
            let snapshot = TokenDisplaySnapshot(
                title: "全会话实时",
                status: "等待输出",
                rate: rate,
                consumedTokens: 0,
                todayTokens: 0,
                todayRequests: 0,
                quota: .empty,
                updatedAt: .distantPast
            )
            XCTAssertEqual(snapshot.statusBarTitle, "0.0/s")
        }
    }

    func testStatusItemPresentationUpdatesWhenOnlyUnreadAccessibilityChanges() {
        let previous = StatusBarTokenItemPresentation(
            title: "    0.0/s    ",
            accessibilityValue: "实时速率 0.0 token 每秒"
        )
        let next = StatusBarTokenItemPresentation(
            title: "    0.0/s    ",
            accessibilityValue: "实时速率 0.0 token 每秒；未读会话 1 个"
        )

        XCTAssertEqual(
            next.changes(previous: previous),
            .init(titleChanged: false, accessibilityChanged: true)
        )
    }

    func testStatusItemPresentationSkipsAllWritesWhenVisibleAndAccessibilityTextAreStable() {
        let presentation = StatusBarTokenItemPresentation(
            title: "    42.4/s    ",
            accessibilityValue: "实时速率 42.4 token 每秒"
        )

        XCTAssertEqual(
            presentation.changes(previous: presentation),
            .init(titleChanged: false, accessibilityChanged: false)
        )
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

    func testStatusBarAccessibilitySeparatesUsageFailureFromMetadataPending() throws {
        let failedSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            usagePrecision: .metadataOnly,
            usageReadStatus: "读取失败：会话目录遍历失败",
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let pendingSnapshot = TokenDisplaySnapshot(
            title: "全会话实时",
            status: "等待输出",
            rate: 0,
            consumedTokens: 0,
            todayTokens: 0,
            todayRequests: 0,
            usagePrecision: .metadataOnly,
            quota: .empty,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(failedSnapshot.compactUsageStatus, "用量读取失败")
        XCTAssertEqual(failedSnapshot.metadataOnlyStatusText, "用量读取失败")
        XCTAssertEqual(pendingSnapshot.metadataOnlyStatusText, "仅会话元数据")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexTokenBar/StatusBarTokenPanel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(#"if snapshot.metadataOnlyStatusText == "仅会话元数据""#))
        XCTAssertFalse(source.contains("if !snapshot.hasPreciseTokenUsage {"))
    }
}
