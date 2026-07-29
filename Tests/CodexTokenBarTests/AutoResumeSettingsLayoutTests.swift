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

    func testTaskDisclosureProgressiveHistoryAndContinuationControlsAreExplicit() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = projectRoot
            .appendingPathComponent("Sources/CodexTokenBar/AutoResumeSettingsView.swift")
        let source = try String(contentsOf: settingsView, encoding: .utf8)

        XCTAssertTrue(source.contains("\"chevron.up\" : \"chevron.down\""))
        XCTAssertTrue(source.contains("toggleTaskDisclosure(task)"))
        XCTAssertTrue(source.contains("visibleThreadLimit"))
        XCTAssertTrue(source.contains("revealMoreThreadsIfNeeded"))
        XCTAssertTrue(source.contains("继续下滑，加载后续会话"))
        XCTAssertFalse(source.contains("最多列出最近"))
        XCTAssertTrue(source.contains("\"无痕续跑\""))
        XCTAssertTrue(source.contains("turn/start + input: []"))
        XCTAssertTrue(source.contains("旧版不接受空输入时才回退发送可见的“继续”"))
        XCTAssertTrue(source.contains(".disabled(invisibleResumeEnabled)"))
        XCTAssertTrue(source.contains("\"定时续跑\""))
        XCTAssertTrue(source.contains("\"额度恢复续跑\""))
        XCTAssertTrue(source.contains("\"失败 / 中断续跑\""))
        XCTAssertTrue(source.contains("\"开始等待刷新\""))
        XCTAssertTrue(source.contains("\"刷新后续跑\""))
        XCTAssertTrue(source.contains("不按报错文案猜测"))
        XCTAssertTrue(source.contains("不会再次触发失败续跑"))
        XCTAssertTrue(source.contains("setAllFailureRecoveryReasons"))
        XCTAssertTrue(source.contains("Group {"))
        XCTAssertTrue(source.contains(".disabled(task.isRunning)"))
        XCTAssertFalse(
            source.contains(".disabled(task.isRunning && !task.configuration.enabled)"),
            "paused tasks started manually must keep the stop action available"
        )
    }
}
