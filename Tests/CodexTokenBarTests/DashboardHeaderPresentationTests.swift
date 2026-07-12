import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardHeaderPresentationTests: XCTestCase {
    func testMarkAllReadRemainsVisibleWithIdleToneAtZeroUnread() {
        let presentation = DashboardMarkAllReadPresentation(unreadCount: 0, isBusy: false)

        XCTAssertEqual(presentation.tone, .idle)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertEqual(presentation.accessibilityLabel, "全部已读")
        XCTAssertEqual(presentation.accessibilityValue, "当前没有未读会话，可重新建立已读基线")
    }

    func testMarkAllReadUsesActiveToneWithUnreadAndDisablesOnlyWhileBusy() {
        let active = DashboardMarkAllReadPresentation(unreadCount: 2, isBusy: false)
        let busy = DashboardMarkAllReadPresentation(unreadCount: 2, isBusy: true)

        XCTAssertEqual(active.tone, .active)
        XCTAssertTrue(active.isEnabled)
        XCTAssertEqual(active.accessibilityValue, "2 个未读会话")
        XCTAssertFalse(busy.isEnabled)
        XCTAssertEqual(busy.accessibilityHint, "正在更新已读基线")
    }

    func testDashboardModeProducesMarkAllReadActionAtZeroUnreadWhileExportProducesNone() {
        XCTAssertTrue(DashboardHeaderPresentationMode.dashboard.showsActions)
        XCTAssertEqual(
            DashboardHeaderPresentationMode.dashboard.actions(unreadCount: 0),
            [.markAllRead, .refresh, .changeDirectory, .providerRepair]
        )
        XCTAssertFalse(DashboardHeaderPresentationMode.export.showsActions)
        XCTAssertTrue(DashboardHeaderPresentationMode.export.actions(unreadCount: 3).isEmpty)
    }

    func testMarkAllReadControllerCoalescesBusyClicksAndCanTriggerAgainAfterCompletion() {
        var controller = DashboardMarkAllReadController()
        var calls = 0

        XCTAssertTrue(controller.trigger { calls += 1 })
        XCTAssertFalse(controller.trigger { calls += 1 })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.isBusy)

        controller.complete()
        XCTAssertTrue(controller.trigger { calls += 1 })
        XCTAssertEqual(calls, 2)
    }

    func testHeaderLayoutReservesReadableWidthForCommonAutomaticSource() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let originWidth = ("自动发现" as NSString).size(withAttributes: [.font: font]).width
        let pathWidth = ("~/.codex" as NSString).size(withAttributes: [.font: font]).width
        let requiredWidth = DashboardHeaderContextLayout.badgeHorizontalPadding * 2
            + DashboardHeaderContextLayout.iconWidth
            + DashboardHeaderContextLayout.badgeSpacing * 2
            + ceil(originWidth)
            + ceil(pathWidth)

        XCTAssertGreaterThanOrEqual(DashboardHeaderContextLayout.dataSourceWidth, requiredWidth)
        XCTAssertEqual(DashboardHeaderContextLayout.contextRowCount, 2)
    }

    @MainActor
    func testHostedAutomaticSourceBadgeKeepsStableSingleLineFrame() {
        let hostingView = NSHostingView(
            rootView: DataSourceBadge(path: "~/.codex", origin: "自动发现")
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hostingView.fittingSize.width,
            DashboardHeaderContextLayout.dataSourceWidth,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 28)
    }
}
