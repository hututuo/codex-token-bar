import AppKit
import XCTest
@testable import CodexTokenBar

@MainActor
final class FloatingTokenPanelLifecycleTests: XCTestCase {
    func testEventSourcesInstallOncePerPresentationAndAreRemovedOnClose() {
        var installs = 0
        var removals = 0
        let lifecycle = FloatingPanelEventSourceLifecycle(
            install: { installs += 1 },
            remove: { removals += 1 }
        )

        XCTAssertEqual(installs, 0)
        XCTAssertEqual(removals, 0)

        lifecycle.activate()
        lifecycle.activate()
        XCTAssertEqual(installs, 1)

        lifecycle.deactivate()
        lifecycle.deactivate()
        XCTAssertEqual(removals, 1)

        lifecycle.activate()
        XCTAssertEqual(installs, 2)
        XCTAssertEqual(removals, 1)
    }

    func testClosedOrUnlockedPanelRejectsExternalMouseWork() {
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldProcess(
                isPresented: false,
                isLocked: true,
                hasLockedAnchor: true,
                hasActiveDrag: false
            )
        )
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldProcess(
                isPresented: true,
                isLocked: false,
                hasLockedAnchor: false,
                hasActiveDrag: false
            )
        )
        XCTAssertTrue(
            FloatingPanelExternalEventRelevance.shouldProcess(
                isPresented: true,
                isLocked: true,
                hasLockedAnchor: true,
                hasActiveDrag: false
            )
        )
    }

    func testClosedControllerClickDoesNotCallAccessibilityOrWindowProviders() {
        let controller = FloatingTokenPanelController()
        var accessibilityCalls = 0
        var windowCalls = 0
        controller.externalClickAccessibilityTargetProvider = { _ in
            accessibilityCalls += 1
            return nil
        }
        controller.externalClickVisibleWindowsProvider = {
            windowCalls += 1
            return []
        }

        controller.recordExternalMouseClick(at: .zero)

        XCTAssertEqual(accessibilityCalls, 0)
        XCTAssertEqual(windowCalls, 0)
    }
}
