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
}
