import AppKit
import XCTest
@testable import CodexTokenBar

@MainActor
final class FloatingTokenPanelLifecycleTests: XCTestCase {
    func testFloatingPanelCannotBecomeKeyOrMain() {
        let panel = makePanel()
        defer { panel.close() }

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.isMovableByWindowBackground)
    }

    func testPanelMousePolicySeparatesDragDoubleClickAndControls() {
        let panel = makePanel()
        defer { panel.close() }
        panel.allowsBackgroundDrag = true
        panel.controlExclusionSize = 24

        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 120, y: 40)),
            .dragPanel
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 120, y: 40)),
            .openDashboard
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 8, y: 88)),
            .passThrough
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 250, y: 88)),
            .passThrough
        )

        panel.allowsBackgroundDrag = false
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 1, location: NSPoint(x: 120, y: 40)),
            .passThrough
        )
        XCTAssertEqual(
            panel.mouseDownAction(clickCount: 2, location: NSPoint(x: 120, y: 40)),
            .openDashboard
        )
    }

    func testProductionPanelEventOnlyOpensDashboardOnDoubleClick() throws {
        let panel = makePanel()
        defer { panel.close() }
        var openCount = 0
        panel.onOpenDashboard = { openCount += 1 }
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 120, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))

        panel.sendEvent(doubleClick)

        XCTAssertEqual(openCount, 1)
    }

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

    private func makePanel() -> FloatingTokenPanelWindow {
        FloatingTokenPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 258, height: 97),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}
