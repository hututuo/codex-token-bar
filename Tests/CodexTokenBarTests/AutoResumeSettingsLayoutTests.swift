import XCTest
@testable import CodexTokenBar

final class AutoResumeSettingsLayoutTests: XCTestCase {
    func testAsyncPickerOptionsCannotExpandSettingsWindow() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot
            .appendingPathComponent("Sources/CodexTokenBar/AutoResumeSettingsView.swift")
        let source = try String(contentsOf: settingsView, encoding: .utf8)

        XCTAssertTrue(source.contains("private let menuPickerWidth: CGFloat = 240"))
        XCTAssertEqual(
            source.components(separatedBy: ".frame(width: menuPickerWidth, alignment: .trailing)").count - 1,
            2
        )
        XCTAssertFalse(source.contains(".fixedSize(horizontal: true, vertical: false)"))
    }

    func testContinuationModeExplanationMatchesInvisibleDefaultBehavior() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot
            .appendingPathComponent("Sources/CodexTokenBar/AutoResumeSettingsView.swift")
        let source = try String(contentsOf: settingsView, encoding: .utf8)

        XCTAssertTrue(source.contains("默认“继续”优先无痕续跑"))
        XCTAssertTrue(source.contains("默认用空输入启动后续轮"))
        XCTAssertTrue(source.contains("旧版不支持时才发送可见的“继续”"))
        XCTAssertTrue(source.contains("每个容量中断最多续跑一次"))
        XCTAssertTrue(source.contains("自动启动的后续轮若仍容量不足"))
        XCTAssertFalse(source.contains("每个容量中断最多发送一次“继续”"))
    }
}
