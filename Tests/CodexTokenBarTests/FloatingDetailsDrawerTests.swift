import AppKit
import XCTest
@testable import CodexTokenBar

final class FloatingDetailsDrawerTests: XCTestCase {
    @MainActor
    func testClosingDrawerRestoresExactScreenEdgeWithoutOrdinaryWindowMargin() throws {
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
        let layout = FloatingTokenPanelLayout(scale: scale, visibility: .default)
        for x in [screen.minX, screen.maxX - layout.size.width] {
            let base = NSRect(x: x, y: screen.minY + 150, width: layout.size.width, height: layout.size.height)
            let panel = NSPanel(contentRect: base, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            let appliedBase = panel.frame
            panel.setFrame(NSRect(x: base.minX, y: base.minY - 100, width: base.width, height: base.height + 100), display: false)
            resizePanel(panel, layout: layout, surfaceSize: layout.size, baseFrame: appliedBase)
            XCTAssertEqual(panel.frame, appliedBase)
            let edge: FloatingDockEdge = x == screen.minX ? .left : .right
            let anchor = FloatingEdgeDockAnchor(edge: edge, expandedFrame: panel.frame)
            if edge == .left { XCTAssertEqual(anchor.collapsedFrame.minX, screen.minX) }
            else { XCTAssertEqual(anchor.collapsedFrame.maxX, screen.maxX) }
        }
    }

    func testLongDrawerKeepsWidthAndCapsToAvailableVerticalSpace() {
        let base = NSRect(x: -800, y: 140, width: 258, height: 120)
        let screen = NSRect(x: -800, y: 0, width: 800, height: 400)
        let size = FloatingTokenPanelMetrics.size(effectiveScale: 1, visibility: .default,
            runningModelDetailsPresented: true, runningModelDetailsRowUnits: 100)
        XCTAssertEqual(size.width, base.width)
        XCTAssertEqual(FloatingTokenPanelMetrics.runningModelDetailsHeight(rowCount: 100), 320)
        let limited = FloatingTokenPanelResizePolicy.constrainedHeight(baseFrame: base, expandedHeight: size.height, screenFrame: screen, scale: 1)
        let placement = FloatingTokenPanelResizePolicy.runningModelDetailsPlacement(panelFrame: base, surfaceSize: base.size,
            expandedSize: NSSize(width: size.width, height: limited), screenFrame: screen)
        let frame = FloatingTokenPanelResizePolicy.expandedFrame(baseFrame: base,
            expandedSize: NSSize(width: size.width, height: limited), surfaceSize: base.size, placement: placement, screenFrame: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.width, base.width)
        XCTAssertLessThan(frame.height, size.height)
        XCTAssertEqual(FloatingTokenPanelResizePolicy.baseFrame(for: frame, surfaceSize: base.size, placement: placement), base)
    }

    func testDrawerAndTriggerHitFramesMatchBothVerticalPlacements() {
        let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
        let normal = FloatingTokenPanelLayout(scale: scale, visibility: .default)
        let normalTrigger = runningThreadControlFrames(layout: normal, visibility: .default)[0]
        for placement in [FloatingRunningModelDetailsPlacement.above, .below] {
            let layout = FloatingTokenPanelLayout(scale: scale, visibility: .default,
                runningModelDetailsPresented: true, runningModelDetailsRowUnits: 3, runningModelDetailsPlacement: placement)
            let trigger = runningThreadControlFrames(layout: layout, visibility: .default)[0]
            let card = runningModelDetailsCardFrame(layout: layout, surfaceSize: normal.size)
            XCTAssertEqual(trigger.minX, normalTrigger.minX)
            XCTAssertEqual(trigger.minY, normalTrigger.minY + (placement == .below ? layout.size.height - normal.size.height : 0))
            XCTAssertFalse(card.intersects(trigger))
            XCTAssertTrue(NSRect(origin: .zero, size: layout.size).contains(card))
        }
    }

    @MainActor
    func testEscDismissesDetailsAndNormalPanelDoesNotTakeKeyboardFocus() throws {
        let panel = FloatingTokenPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 258, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        panel.runningModelDetailsPresented = true
        XCTAssertTrue(panel.canBecomeKey)
        var closes = 0
        panel.onDismissRunningModelDetails = { closes += 1; panel.runningModelDetailsPresented = false }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(event)
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(panel.canBecomeKey)
    }

    @MainActor
    func testDrawerResizingKeepsBlackDockAndRestoresNormalCollapseAfterClosing() async throws {
        let original = NSRect(x: 0, y: 150, width: 258, height: 120)
        let panel = NSPanel(contentRect: original, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: 900, y: 500) }, pressedMouseButtons: { 0 })
        var saved: [NSPoint] = []
        dock.bind(panel: panel, enabled: { true }, persist: { saved.append($0) })
        dock.presentation.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: original)
        dock.holdOpen(true)
        dock.prepareForResize()
        XCTAssertTrue(dock.isAttached)
        panel.setFrame(NSRect(x: 0, y: 150, width: 258, height: 320), display: false)
        dock.resumeAfterResize()
        dock.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(dock.presentation.collapsed)
        XCTAssertEqual(dock.expandedFrame?.height, 320)
        dock.prepareForResize(); panel.setFrame(original, display: false); dock.resumeAfterResize()
        dock.holdOpen(false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(dock.presentation.compactWindow)
        XCTAssertEqual(dock.expandedFrame, original)
        XCTAssertTrue(saved.isEmpty)
        dock.dispose(); panel.close()
    }
}
