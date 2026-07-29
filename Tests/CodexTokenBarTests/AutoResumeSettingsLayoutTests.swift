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
        XCTAssertTrue(source.contains("失败 / 中断续跑条件"))
        XCTAssertTrue(source.contains("逐项匹配 Codex app-server 终态/错误码"))
        XCTAssertTrue(source.contains("不按报错文案猜测"))
        XCTAssertTrue(source.contains("不会再次触发失败续跑"))
        XCTAssertTrue(source.contains("setAllRecoveryConditions"))
        XCTAssertTrue(source.contains("Group {"))
        XCTAssertTrue(source.contains(".disabled(task.isRunning)"))
        XCTAssertFalse(
            source.contains(".disabled(task.isRunning && !task.configuration.enabled)"),
            "paused tasks started manually must keep the stop action available"
        )
    }
}
