import AppKit
import XCTest
@testable import CodexTokenBar

final class StartupPresentationTests: XCTestCase {
    @MainActor
    func testInitialWindowIsRequestedOnlyOnce() {
        let coordinator = DashboardReopenCoordinator()
        var count = 0
        coordinator.ensureInitialWindow { count += 1 }
        coordinator.ensureInitialWindow { count += 1 }
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testClosingLastDashboardWindowKeepsMenuBarAppRunning() {
        let delegate = CodexTokenBarApplicationDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        )
    }

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
    func testDockReopenAlwaysTargetsDashboardEvenWithVisibleFloatingPanel() {
        let coordinator = DashboardReopenCoordinator()
        var reopenCount = 0

        XCTAssertFalse(coordinator.handleApplicationReopen(hasVisibleWindows: false))

        coordinator.install {
            reopenCount += 1
        }

        XCTAssertTrue(coordinator.handleApplicationReopen(hasVisibleWindows: true))
        XCTAssertEqual(reopenCount, 1)
        XCTAssertTrue(coordinator.handleApplicationReopen(hasVisibleWindows: false))
        XCTAssertEqual(reopenCount, 2)
    }

    @MainActor
    func testStartupHideIsConsumedOnceAndCannotHideExplicitReopen() {
        let visibility = DashboardStartupVisibility()
        XCTAssertTrue(visibility.consumeInitialHide(shouldHide: true))
        visibility.requestOpen()
        XCTAssertTrue(visibility.explicitlyOpened)
        XCTAssertFalse(visibility.consumeInitialHide(shouldHide: true))

        let reopenedBeforeAppearance = DashboardStartupVisibility()
        reopenedBeforeAppearance.requestOpen()
        XCTAssertFalse(reopenedBeforeAppearance.consumeInitialHide(shouldHide: true))

        let manualLaunch = DashboardStartupVisibility()
        XCTAssertFalse(manualLaunch.consumeInitialHide(shouldHide: false))
        XCTAssertFalse(manualLaunch.consumeInitialHide(shouldHide: true))
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
        XCTAssertTrue(presentationSource.contains("applicationShouldTerminateAfterLastWindowClosed"))
        XCTAssertTrue(presentationSource.contains("applicationShouldHandleReopen"))
        XCTAssertTrue(presentationSource.contains("DashboardReopenCoordinator.shared.handleApplicationReopen"))
    }
}
