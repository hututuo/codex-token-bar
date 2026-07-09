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
}
