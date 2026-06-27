import XCTest

final class StartupPresentationTests: XCTestCase {
    func testStartupKeepsDockIconVisibleWhileDashboardCanHide() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let startupPresentation = projectRoot.appendingPathComponent("Sources/CodexTokenBar/StartupPresentation.swift")
        let source = try String(contentsOf: startupPresentation, encoding: .utf8)

        XCTAssertTrue(source.contains("NSApplication.shared.setActivationPolicy(.regular)"))
        XCTAssertFalse(source.contains("setActivationPolicy(.accessory)"))
        XCTAssertTrue(source.contains("dashboardWindows().forEach { $0.orderOut(nil) }"))
    }
}
