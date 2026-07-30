import SwiftUI
import XCTest
@testable import CodexTokenBar

final class StatusBarTokenPanelTests: XCTestCase {
    @MainActor
    func testHostedPopoverKeepsConfigurableSummaryInsideStableFrame() {
        let defaults = UserDefaults.standard
        let previousAuto = defaults.object(forKey: InterfaceScaleSettings.autoEnabledKey)
        let previousManual = defaults.object(forKey: InterfaceScaleSettings.manualMultiplierKey)
        defaults.set(false, forKey: InterfaceScaleSettings.autoEnabledKey)
        defaults.set(1.0, forKey: InterfaceScaleSettings.manualMultiplierKey)
        defer {
            restore(previousAuto, key: InterfaceScaleSettings.autoEnabledKey, defaults: defaults)
            restore(previousManual, key: InterfaceScaleSettings.manualMultiplierKey, defaults: defaults)
        }

        let host = NSHostingView(rootView: StatusBarTokenPopoverView(
            store: CodexUsageStore(),
            monitor: LiveRateMonitor(),
            quota: AccountQuotaStore(),
            radar: CodexRadarStore(),
            taskCompletionMonitor: TaskCompletionMonitor(),
            configuration: .default,
            onOpenDashboard: {},
            onOpenSettings: {},
            onClose: {}
        ))
        host.frame = CGRect(
            x: 0,
            y: 0,
            width: StatusBarPopoverMetrics.width,
            height: StatusBarPopoverMetrics.height
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.fittingSize.width, StatusBarPopoverMetrics.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, StatusBarPopoverMetrics.height, accuracy: 1)
    }

    func testStatusBarQuotaPresentationShowsOnlySevenDayWhenFiveHourIsAbsent() {
        let quota = AccountQuotaSnapshot(
            fiveHour: nil,
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 0,
                resetsAt: Date(timeIntervalSince1970: 20_000)
            ),
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let items = StatusBarQuotaPresentation.items(for: quota)

        XCTAssertEqual(items.map(\.title), ["7d"])
        XCTAssertEqual(items.first?.window.usedPercent, 0)
    }

    func testClosedStatusItemRefreshUsesOneSecondCadence() {
        XCTAssertEqual(StatusBarRefreshCadence.statusItem, 1.0)
        XCTAssertEqual(StatusBarPopoverMetrics.width, 390)
        XCTAssertEqual(StatusBarPopoverMetrics.height, 440)
    }

    func testPopoverFrameScalesWithConfiguredInterfaceSize() {
        XCTAssertEqual(StatusBarPopoverMetrics.size(scale: 0.9).width, 351, accuracy: 0.01)
        XCTAssertEqual(StatusBarPopoverMetrics.size(scale: 1.0).height, 440, accuracy: 0.01)
        XCTAssertEqual(StatusBarPopoverMetrics.size(scale: 1.18).width, 460.2, accuracy: 0.01)
        XCTAssertEqual(StatusBarPopoverMetrics.size(scale: 1.38).height, 607.2, accuracy: 0.01)
    }

    func testPopoverActivityLeaseChangesOnlyOnRealPresentationTransitions() {
        var activity = StatusBarPopoverActivityState()

        XCTAssertFalse(activity.isPresented)
        XCTAssertTrue(activity.transition(to: true))
        XCTAssertTrue(activity.isPresented)
        XCTAssertFalse(activity.transition(to: true))
        XCTAssertTrue(activity.transition(to: false))
        XCTAssertFalse(activity.isPresented)
        XCTAssertFalse(activity.transition(to: false))
    }

    func testStatusBarLifecycleKeepsTimerAndRootStableForSameOwnersAndTicks() {
        let owners = [NSObject(), NSObject(), NSObject(), NSObject(), NSObject()]
        let identity = StatusBarOwnerIdentity(
            store: owners[0],
            monitor: owners[1],
            quota: owners[2],
            radar: owners[3],
            taskCompletionMonitor: owners[4]
        )
        let lifecycle = StatusBarLifecycleState()

        XCTAssertEqual(lifecycle.bind(identity), .init(assignRoot: true, startTimer: true))
        XCTAssertEqual(lifecycle.bind(identity), .init(assignRoot: false, startTimer: false))
        let presentation = StatusBarTokenItemPresentation(title: "42.4/s", accessibilityValue: "42.4")
        XCTAssertEqual(
            lifecycle.changes(for: presentation),
            .init(titleChanged: true, accessibilityChanged: true, imageChanged: true)
        )
        for _ in 0..<100 {
            XCTAssertEqual(
                lifecycle.changes(for: presentation),
                .init(titleChanged: false, accessibilityChanged: false)
            )
        }

        let radarReplacement = NSObject()
        let radarChanged = StatusBarOwnerIdentity(
            store: owners[0],
            monitor: owners[1],
            quota: owners[2],
            radar: radarReplacement,
            taskCompletionMonitor: owners[4]
        )
        XCTAssertEqual(lifecycle.bind(radarChanged), .init(assignRoot: true, startTimer: false))

        let replacement = NSObject()
        let changed = StatusBarOwnerIdentity(
            store: replacement,
            monitor: owners[1],
            quota: owners[2],
            radar: radarReplacement,
            taskCompletionMonitor: owners[4]
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
            title: "0.0/s",
            accessibilityValue: "实时速率 0.0 token 每秒"
        )
        let next = StatusBarTokenItemPresentation(
            title: "0.0/s",
            accessibilityValue: "实时速率 0.0 token 每秒；未读会话 1 个"
        )

        XCTAssertEqual(
            next.changes(previous: previous),
            .init(titleChanged: false, accessibilityChanged: true)
        )
    }

    func testStatusItemPresentationSkipsAllWritesWhenVisibleAndAccessibilityTextAreStable() {
        let presentation = StatusBarTokenItemPresentation(
            title: "42.4/s",
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

    func testStatusBarAccessibilitySeparatesUsageFailureFromMetadataPending() {
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

        let values = StatusBarMetricValues(
            snapshot: failedSnapshot,
            radar: CodexRadarPresentationState(),
            unreadThreadCount: 0
        )
        let presentation = StatusBarMetricsPresentation.make(
            values: values,
            configuration: StatusBarMetricConfiguration(
                orderedMetricIDs: [.today, .total, .requests],
                selectedMetricIDs: [.today, .total, .requests],
                showsIcon: true
            )
        )
        XCTAssertEqual(presentation.text, "今— · 总— · 次—")
        XCTAssertTrue(presentation.accessibilityValue.contains("暂不可用"))
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
