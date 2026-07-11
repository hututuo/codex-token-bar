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

    func testExternalMouseRelevanceSeparatesRecordingFromInspection() {
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldRecordClick(
                isPresented: false
            )
        )
        XCTAssertTrue(
            FloatingPanelExternalEventRelevance.shouldRecordClick(
                isPresented: true
            )
        )
        XCTAssertFalse(
            FloatingPanelExternalEventRelevance.shouldInspectWindow(
                isPresented: true,
                isLocked: false,
                hasLockedAnchor: false,
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

    func testUnlockedClickRecordsLocationAndDefersWindowResolutionUntilLock() {
        let controller = FloatingTokenPanelController()
        var isLocked = false
        controller.externalEventStateProvider = { (isPresented: true, isLocked: isLocked) }
        var accessibilityCalls = 0
        var windowCalls = 0
        let clickedLocation = NSPoint(x: 240, y: 180)
        let targetFrame = NSRect(x: 100, y: 100, width: 400, height: 300)
        controller.externalClickAccessibilityTargetProvider = { location in
            accessibilityCalls += 1
            XCTAssertEqual(location, clickedLocation)
            return FloatingPanelAccessibilityTarget(
                window: AXUIElementCreateApplication(4242),
                ownerPID: 4242,
                ownerBundleID: "test.target",
                ownerName: "Target",
                title: "Document",
                frame: targetFrame
            )
        }
        controller.externalClickVisibleWindowsProvider = {
            windowCalls += 1
            return []
        }

        controller.recordExternalMouseClick(at: clickedLocation)

        XCTAssertEqual(controller.lastExternalClickLocation, clickedLocation)
        XCTAssertNotNil(controller.lastExternalClickAt)
        XCTAssertEqual(accessibilityCalls, 0)
        XCTAssertEqual(windowCalls, 0)

        isLocked = true
        let panel = NSPanel(contentRect: NSRect(x: 500, y: 400, width: 120, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = controller.currentAnchor(for: panel)

        XCTAssertEqual(accessibilityCalls, 1)
        XCTAssertEqual(windowCalls, 0)
        XCTAssertEqual(anchor?.ownerPID, 4242)
        XCTAssertEqual(anchor?.windowTitle, "Document")
    }

    func testQueuedClickAfterCloseDoesNotMutateRecentClickState() {
        let controller = FloatingTokenPanelController()
        let originalLocation = NSPoint(x: 12, y: 34)
        let originalDate = Date(timeIntervalSince1970: 123)
        controller.lastExternalClickLocation = originalLocation
        controller.lastExternalClickAt = originalDate

        controller.recordExternalMouseClick(at: NSPoint(x: 800, y: 600))

        XCTAssertEqual(controller.lastExternalClickLocation, originalLocation)
        XCTAssertEqual(controller.lastExternalClickAt, originalDate)
    }
}
