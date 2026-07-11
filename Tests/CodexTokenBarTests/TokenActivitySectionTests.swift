import AppKit
import XCTest
@testable import CodexTokenBar

final class TokenActivitySectionTests: XCTestCase {
    func testModeAccessibilityPresentationsAreDistinctAndStateful() {
        let presentations = ActivityMode.allCases.map { mode in
            ActivityModeOptionPresentation(mode: mode, isSelected: mode == .weekly)
        }

        XCTAssertEqual(presentations.map(\.visibleTitle), ["每日", "每周", "累计", "命中率", "额度"])
        XCTAssertEqual(
            presentations.map(\.accessibilityLabel),
            [
                "Token 活动模式 每日",
                "Token 活动模式 每周",
                "Token 活动模式 累计",
                "Token 活动模式 命中率",
                "Token 活动模式 额度",
            ]
        )
        XCTAssertEqual(
            presentations.map(\.accessibilityValue),
            ["未选择", "已选择", "未选择", "未选择", "未选择"]
        )
        XCTAssertEqual(Set(presentations.map(\.accessibilityLabel)).count, ActivityMode.allCases.count)
    }

    @MainActor
    func testNativeModeAccessibilityRepresentationsExposeSemanticAX() {
        for mode in ActivityMode.allCases {
            let presentation = ActivityModeOptionPresentation(
                mode: mode,
                isSelected: mode == .cacheHitRate
            )
            let button = RecentChartAccessibilityButtonRepresentation.makeButton(
                presentation: presentation.accessibilityButton
            )

            XCTAssertEqual(button.accessibilityLabel(), "Token 活动模式 \(mode.rawValue)")
            XCTAssertEqual(
                button.accessibilityValue() as? String,
                mode == .cacheHitRate ? "已选择" : "未选择"
            )
            XCTAssertNotEqual(button.accessibilityLabel(), mode.rawValue)
            XCTAssertTrue(button.isEnabled)
        }
    }
}
