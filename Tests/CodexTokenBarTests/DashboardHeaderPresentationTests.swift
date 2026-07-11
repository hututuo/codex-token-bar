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
}
