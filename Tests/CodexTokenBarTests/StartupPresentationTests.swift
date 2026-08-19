import XCTest
@testable import CodexTokenBar

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

    @MainActor
    func testDockReopenUsesInstalledDashboardWindowActionOnlyWhenNeeded() {
        let coordinator = DashboardReopenCoordinator()
        var reopenCount = 0

        XCTAssertFalse(coordinator.handleApplicationReopen(hasVisibleWindows: false))

        coordinator.install {
            reopenCount += 1
        }

        XCTAssertTrue(coordinator.handleApplicationReopen(hasVisibleWindows: true))
        XCTAssertEqual(reopenCount, 0)
        XCTAssertTrue(coordinator.handleApplicationReopen(hasVisibleWindows: false))
        XCTAssertEqual(reopenCount, 1)
    }

    func testAppRegistersNativeDockReopenDelegate() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/CodexTokenBarApp.swift"),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/CodexTokenBar/StartupPresentation.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("@NSApplicationDelegateAdaptor(CodexTokenBarApplicationDelegate.self)"))
        XCTAssertTrue(appSource.contains("Window(\"Codex Token Bar\", id: \"dashboard\")"))
        XCTAssertFalse(appSource.contains("WindowGroup(id: \"dashboard\")"))
        XCTAssertTrue(presentationSource.contains("applicationShouldHandleReopen"))
        XCTAssertTrue(presentationSource.contains("DashboardReopenCoordinator.shared.handleApplicationReopen"))
    }
}
