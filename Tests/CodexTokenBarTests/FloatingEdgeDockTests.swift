import AppKit
import XCTest
@testable import CodexTokenBar

final class FloatingEdgeDockTests: XCTestCase {
    private let area = NSRect(x: 0, y: 24, width: 1200, height: 800)

    func testAllEdgesSnapAndLeaveOnlySixPointNativeHandle() throws {
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
            XCTAssertEqual(edge == .left || edge == .right ? lip.width : lip.height, 6)
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
            NSRect(x: 40, y: 150, width: 300, height: 120),
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

}
