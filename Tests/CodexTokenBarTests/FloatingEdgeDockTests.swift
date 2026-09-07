import AppKit
import XCTest
@testable import CodexTokenBar

final class FloatingEdgeDockTests: XCTestCase {
    private let area = NSRect(x: 0, y: 24, width: 1200, height: 800)

    func testAllEdgesSnapAndLeaveOnlyTwelvePointQuotaHandle() throws {
        for (edge, frame) in [
            (FloatingDockEdge.left, NSRect(x: 10, y: 150, width: 300, height: 120)),
            (.right, NSRect(x: 890, y: 150, width: 300, height: 120)),
            (.bottom, NSRect(x: 400, y: 30, width: 300, height: 120)),
            (.top, NSRect(x: 400, y: 695, width: 300, height: 120)),
        ] {
            let anchor = try XCTUnwrap(FloatingEdgeDockAnchor.resolve(frame: frame, workArea: area))
            XCTAssertEqual(anchor.edge, edge)
            let lip = anchor.collapsedFrame
            XCTAssertTrue(anchor.expandedFrame.contains(lip))
            XCTAssertEqual(edge == .left || edge == .right ? lip.width : lip.height, 12)
            XCTAssertEqual(edge == .left || edge == .right ? lip.midY : lip.midX,
                           edge == .left || edge == .right ? anchor.expandedFrame.midY : anchor.expandedFrame.midX)
        }
    }

    func testNegativeDisplayCoordinatesAndCornerPriority() throws {
        let negative = NSRect(x: -1600, y: -200, width: 1600, height: 900)
        let anchor = try XCTUnwrap(FloatingEdgeDockAnchor.resolve(
            frame: NSRect(x: -1592, y: 100, width: 258, height: 120), workArea: negative))
        XCTAssertEqual(anchor.expandedFrame.minX, -1600)
        XCTAssertEqual(anchor.edge, .left)
        XCTAssertEqual(FloatingEdgeDockAnchor.resolve(
            frame: NSRect(x: 0, y: 24, width: 300, height: 120), workArea: area)?.edge, .left)
    }

    func testDistantOversizedNonfiniteAndTinyWindowsDoNotDock() {
        for frame in [
            NSRect(x: 70, y: 150, width: 300, height: 120),
            NSRect(x: 0, y: 24, width: 1300, height: 120),
            NSRect(x: CGFloat.nan, y: 24, width: 300, height: 120),
            NSRect(x: 0, y: 24, width: 6, height: 120),
            NSRect(x: 0, y: 900, width: 300, height: 120),
        ] {
            XCTAssertNil(FloatingEdgeDockAnchor.resolve(frame: frame, workArea: area))
        }
    }

    @MainActor
    func testDetachRestoresExpandedFrameWithoutPersistingTheHandle() {
        let frame = NSRect(x: 0, y: 150, width: 300, height: 120)
        let anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: frame)
        let panel = NSPanel(contentRect: anchor.collapsedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController()
        var saved: [NSPoint] = []
        dock.bind(panel: panel, enabled: { true }, persist: { saved.append($0) })
        dock.presentation.anchor = anchor
        dock.presentation.collapsed = true
        dock.presentation.compactWindow = true
        XCTAssertTrue(dock.detach())
        XCTAssertEqual(panel.frame, frame)
        XCTAssertNil(dock.expandedFrame)
        XCTAssertFalse(dock.presentation.compactWindow)
        XCTAssertFalse(dock.presentation.collapsed)
        XCTAssertTrue(saved.isEmpty)
        dock.dispose()
        panel.close()
    }

    @MainActor
    func testLockedOrGuidedPanelNeverAcquiresADock() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 150, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController()
        dock.bind(panel: panel, enabled: { false }, persist: { _ in XCTFail("Unexpected persistence") })
        dock.snapIfNearEdge()
        XCTAssertFalse(dock.isAttached)
        dock.dispose()
        panel.close()
    }
    @MainActor
    func testResizeIntentSurvivesDetailsSuspension() throws {
        let area = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let original = NSRect(x: area.minX, y: area.midY - 60, width: 300, height: 120)
        let panel = NSPanel(contentRect: original, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController()
        var eligible = true
        dock.bind(panel: panel, enabled: { eligible }, persist: { _ in })
        dock.snapIfNearEdge()
        XCTAssertTrue(dock.isAttached)
        eligible = false
        dock.prepareForResize()
        dock.resumeAfterResize()
        XCTAssertFalse(dock.isAttached)
        eligible = true
        dock.prepareForResize()
        panel.setFrame(NSRect(x: original.minX, y: original.minY, width: 300, height: 136), display: false)
        dock.resumeAfterResize()
        XCTAssertEqual(dock.expandedFrame?.height, 136)
        dock.dispose()
        panel.close()
    }

    func testNearEdgesAndPartialOvershootDockWithoutExactAlignment() throws {
        for frame in [NSRect(x: 36, y: 150, width: 300, height: 120),
                      NSRect(x: -90, y: 150, width: 300, height: 120),
                      NSRect(x: 864, y: 150, width: 300, height: 120),
                      NSRect(x: 990, y: 150, width: 300, height: 120)] {
            let anchor = try XCTUnwrap(FloatingEdgeDockAnchor.resolve(frame: frame, workArea: area))
            XCTAssertTrue(area.contains(anchor.expandedFrame))
            XCTAssertEqual(anchor.collapsedFrame.height, frame.height)
            XCTAssertEqual(anchor.collapsedFrame.width, 12)
        }
        XCTAssertNil(FloatingEdgeDockAnchor.resolve(frame: NSRect(x: 1201, y: 150, width: 300, height: 120), workArea: area))
    }

    @MainActor
    func testHoverImmediatelyRevealsWithoutWaitingForATimer() {
        let anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: NSRect(x: 0, y: 150, width: 300, height: 120))
        let panel = NSPanel(contentRect: anchor.collapsedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: 2, y: 210) })
        dock.bind(panel: panel, enabled: { true }, persist: { _ in })
        dock.presentation.anchor = anchor
        dock.presentation.collapsed = true
        dock.presentation.compactWindow = true
        dock.hoverChanged(true)
        XCTAssertFalse(dock.presentation.collapsed)
        XCTAssertFalse(dock.presentation.compactWindow)
        XCTAssertEqual(panel.frame, anchor.expandedFrame)
        dock.dispose(); panel.close()
    }

    @MainActor
    func testStaleHoverAndRepeatedExitCannotInterruptNativeCollapse() async throws {
        let anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: NSRect(x: 0, y: 150, width: 300, height: 120))
        let panel = NSPanel(contentRect: anchor.expandedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: 800, y: 500) }, pressedMouseButtons: { 0 })
        dock.bind(panel: panel, enabled: { true }, persist: { _ in })
        XCTAssertTrue(panel.contentView?.subviews.contains(where: { $0 is FloatingEdgeTrackingView }) == true)
        dock.presentation.anchor = anchor
        dock.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(510))
        XCTAssertTrue(dock.presentation.collapsed)
        dock.hoverChanged(false)
        dock.hoverChanged(true) // stale tracking event, actual pointer remains outside
        try await Task.sleep(for: .milliseconds(370))
        XCTAssertTrue(dock.presentation.compactWindow)
        XCTAssertEqual(panel.frame, anchor.collapsedFrame)
        dock.dispose()
        XCTAssertFalse(panel.contentView?.subviews.contains(where: { $0 is FloatingEdgeTrackingView }) == true)
        panel.close()
    }

    @MainActor
    func testNativeDragReturnDoesNotReattachBeforeMouseRelease() async throws {
        let workArea = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let frame = NSRect(x: workArea.minX, y: workArea.midY - 60, width: 300, height: 120)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        var buttons = 1
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: workArea.midX, y: workArea.midY) }, pressedMouseButtons: { buttons })
        dock.bind(panel: panel, enabled: { true }, persist: { _ in })
        dock.presentation.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: frame)
        dock.beginDrag()
        dock.endDrag() // native command returns, but the user is still holding the mouse
        XCTAssertFalse(dock.isAttached)
        dock.prepareForResize() // ordinary data/layout refresh must not cancel release tracking
        let dragged = NSRect(x: workArea.midX - 150, y: workArea.midY - 60, width: 300, height: 120)
        panel.setFrame(dragged, display: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(dock.isAttached)
        buttons = 0
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(dock.isAttached)
        XCTAssertEqual(panel.frame, dragged)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(panel.frame, dragged)
        dock.dispose(); panel.close()
    }

}
