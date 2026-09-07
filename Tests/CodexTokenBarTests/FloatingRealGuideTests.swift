import AppKit
import XCTest
@testable import CodexTokenBar

final class FloatingRealGuideTests: XCTestCase {
    @MainActor
    func testRestorationFitsAnOversizedWindowOnASmallerDisplay() {
        let area = NSRect(x: -800, y: 0, width: 800, height: 600)
        let restored = FloatingEdgeDockController.restoredFrame(NSRect(x: 1200, y: -200, width: 1200, height: 900), in: area)
        XCTAssertEqual(restored, area)
    }

    @MainActor
    func testInterruptedGuideDismissesWithoutCompletingRevision() throws {
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController()
        var outcomes: [Bool] = []
        let guide = FloatingRealWindowGuide(panel: panel, dock: dock) { outcomes.append($0) }
        guide.finish(markComplete: false)
        guide.finish()
        XCTAssertEqual(outcomes, [false])
        panel.close()
    }

    @MainActor
    func testRehearsalUsesRealDockWithoutSavingOrFollowingPhysicalPointer() async throws {
        let area = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let panel = NSPanel(contentRect: NSRect(x: area.minX + 5, y: area.midY, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: -10000, y: -10000) }, pressedMouseButtons: { 1 })
        var persisted: [NSPoint] = []
        dock.bind(panel: panel, enabled: { true }, persist: { persisted.append($0) })
        defer { dock.dispose(); panel.close() }
        dock.beginGuide(pointer: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        dock.beginDrag(); dock.endDrag()
        XCTAssertTrue(dock.isAttached)
        XCTAssertTrue(persisted.isEmpty)
        dock.guideHover(at: NSPoint(x: area.midX, y: area.minY + 30))
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(dock.presentation.compactWindow)
        dock.hoverChanged(true)
        XCTAssertTrue(dock.presentation.compactWindow)
        dock.guideHover(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        XCTAssertFalse(dock.presentation.compactWindow)
        dock.beginDrag()
        panel.setFrameOrigin(NSPoint(x: area.midX - 150, y: area.midY))
        dock.endDrag()
        XCTAssertFalse(dock.isAttached)
        XCTAssertTrue(persisted.isEmpty)
        dock.endGuide()
        XCTAssertFalse(dock.isGuiding)
    }
}
