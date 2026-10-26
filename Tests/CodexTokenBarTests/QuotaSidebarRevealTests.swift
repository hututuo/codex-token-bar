import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
private final class SidebarTestDisplayPulse: NSObject {
    private(set) var ticks = 0
    @objc func tick() { ticks += 1 }
}

final class QuotaSidebarRevealTests: XCTestCase {
    @MainActor
    func testRevealClipsAndHitTestsOnlyTheVisibleCanvasOnBothEdges() {
        for edge in [QuotaSidebarEdge.left, .right] {
            let host = NSView()
            let canvas = QuotaSidebarCanvasView(host: host, edge: edge)
            let reveal = QuotaSidebarRevealView(canvas: canvas)
            reveal.frame = CGRect(x: 0, y: 0, width: 88, height: 680)
            for width in [16.0, 43.0, 88.0] {
                let visible = CGRect(x: edge == .right ? 88 - width : 0,
                                     y: 240, width: width, height: 200)
                reveal.present(visible)
                XCTAssertEqual(canvas.frame, visible)
                XCTAssertEqual(host.frame.size, CGSize(width: 88, height: 680))
                XCTAssertEqual(canvas.frame.minX + host.frame.minX, 0)
                XCTAssertEqual(canvas.frame.minY + host.frame.minY, 0)
                XCTAssertNotNil(reveal.hitTest(CGPoint(x: visible.midX, y: visible.midY)))
                XCTAssertNil(reveal.hitTest(CGPoint(x: visible.midX, y: 100)))
                if width < 88 {
                    XCTAssertNil(reveal.hitTest(CGPoint(x: edge == .right ? 1 : 87, y: visible.midY)))
                }
            }
            reveal.present(nil)
            reveal.setFrameSize(CGSize(width: 16, height: 192))
            XCTAssertEqual(canvas.frame, reveal.bounds)
        }
    }

    @MainActor
    func testRadarGateKeepsFixedHostingSizeThroughoutReveal() {
        let surface = QuotaSidebarSignalSurface { _ in Color.clear }
        surface.glow.isHidden = false
        let canvas = QuotaSidebarCanvasView(host: NSView(), edge: .left, signal: surface)
        let gateSize = surface.stateHost.frame.size
        for index in 0...60 {
            let amount = Double(index) / 60
            canvas.setFrameSize(CGSize(width: 16 + 72 * amount, height: 182 + 398 * amount))
            surface.layout()
            XCTAssertEqual(surface.stateHost.frame.size, gateSize,
                           "Only the native stroke may resize, never its SwiftUI state gate")
            XCTAssertEqual(surface.glow.frame, surface.bounds)
        }
        surface.glow.stopObserving()
    }

    @MainActor
    func testCompositorRevealDoesNotRelayoutViewsDuringDisplayTicks() {
        for edge in [QuotaSidebarEdge.left, .right] {
            let host = NSView(); host.wantsLayer = true
            let canvas = QuotaSidebarCanvasView(host: host, edge: edge)
            let reveal = QuotaSidebarRevealView(canvas: canvas)
            reveal.frame = CGRect(x: 0, y: 0, width: 88, height: 580)
            let start = reveal.bounds
            let end = CGRect(x: edge == .left ? 0 : 72, y: 199, width: 16, height: 182)
            reveal.animate(frames: [start, end], keyTimes: [0, 1], duration: 0.3)
            XCTAssertTrue(reveal.isAnimatingPresentation)
            XCTAssertNotNil(canvas.layer?.animation(forKey: "sidebarRevealBounds"))
            XCTAssertNotNil(host.layer?.animation(forKey: "sidebarRevealPosition"))
            let nativeFrame = canvas.frame, hostFrame = host.frame
            for index in 0...60 {
                reveal.updateInputBounds(CGRect(x: 0, y: 0, width: 16 + Double(index), height: 300))
                reveal.layout()
                XCTAssertEqual(canvas.frame, nativeFrame)
                XCTAssertEqual(host.frame, hostFrame)
            }
            reveal.present(nil)
            XCTAssertFalse(reveal.isAnimatingPresentation)
            XCTAssertNil(canvas.layer?.animation(forKey: "sidebarRevealBounds"))
            XCTAssertNil(host.layer?.animation(forKey: "sidebarRevealPosition"))
        }
    }

    @MainActor
    func testNativeRevealDoesNotResizeTheWindowOnEachVisualFrameAndReversesContinuously() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Animated transition contract; system Reduce Motion is enabled")
        }
        // Probe AppKit independently of the production animation. Command-line
        // test hosts can expose NSScreen while delivering no display-link ticks.
        // That is not evidence that the controller's lost-mouse-up path froze.
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let pulse = SidebarTestDisplayPulse()
        let link = screen.displayLink(target: pulse, selector: #selector(SidebarTestDisplayPulse.tick))
        link.add(to: .main, forMode: .common)
        let pulseDeadline = Date().addingTimeInterval(0.25)
        while pulse.ticks == 0 && Date() < pulseDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        link.invalidate()
        guard pulse.ticks > 0 else {
            throw XCTSkip("AppKit display-link callbacks unavailable in this test host; native animation requires live validation")
        }
        let suite = "SidebarReveal-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuotaSidebarController(settings: defaults)
        controller.show(store: CodexUsageStore(autoStart: false, continuityDefaults: defaults),
            monitor: LiveRateMonitor(preciseTokenCountingEnabled: false, monitoringEnabled: false),
            quota: AccountQuotaStore(userDefaults: defaults, observesUserDefaults: false),
            tasks: TaskCompletionMonitor(defaults: defaults), radar: CodexRadarStore(detailRefreshDefaults: defaults),
            history: QuotaHistoryStore(), edge: .left)
        defer { controller.close() }
        let panel = try XCTUnwrap(controller.railPanel)
        let reveal = try XCTUnwrap(panel.contentView as? QuotaSidebarRevealView)
        func wait(until condition: () -> Bool, timeout: Double = 1) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        }
        // Warm up content measurement before observing native geometry.
        let warmUntil = Date().addingTimeInterval(0.3)
        wait(until: { Date() >= warmUntil })
        controller.enter()
        controller.togglePin() // Real pointer movement must not cancel this controlled transition.
        wait(until: { (controller.presentedRailFrame?.width ?? 0) > 28 })
        let visual = try XCTUnwrap(controller.presentedRailFrame)
        XCTAssertTrue(reveal.isAnimatingPresentation)
        XCTAssertNotNil(reveal.animatedVisualFrame)
        let fixedCanvas = reveal.canvas.frame
        let envelope = panel.frame
        wait(until: { (controller.presentedRailFrame?.width ?? 0) > visual.width + 8 })
        XCTAssertEqual(panel.frame, envelope, "Visual ticks must not call NSWindow.setFrame")
        XCTAssertEqual(reveal.canvas.frame, fixedCanvas, "Visual ticks must not call NSView.setFrame either")

        // Invoke only this test panel's handler, with no system mouse injection
        // and no mouse-up. Its bounded polling must resume the frozen reveal.
        guard NSEvent.pressedMouseButtons == 0 else { throw XCTSkip("A physical mouse button is held") }
        let beforePress = try XCTUnwrap(controller.presentedRailFrame)
        let pointer = NSEvent.mouseLocation
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: beforePress.midX - panel.frame.minX,
                              y: beforePress.maxY - panel.frame.minY - 6),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(try XCTUnwrap(panel.trackPrimaryPress)(down))
        guard hypot(NSEvent.mouseLocation.x - pointer.x, NSEvent.mouseLocation.y - pointer.y) < QuotaSidebarDragSession.threshold,
              NSEvent.pressedMouseButtons == 0 else { throw XCTSkip("Physical mouse movement interrupted the controlled press") }
        wait(until: { (controller.presentedRailFrame ?? panel.frame).width > beforePress.width })
        XCTAssertGreaterThan((controller.presentedRailFrame ?? panel.frame).width, beforePress.width,
                             "A missing mouse-up must not leave the reveal frozen")
        let beforeReverse = try XCTUnwrap(reveal.animatedVisualFrame).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        controller.dismiss()
        let reversed = try XCTUnwrap(controller.presentedRailFrame)
        XCTAssertEqual(reversed.width, beforeReverse.width, accuracy: 4, "Reverse from the compositor pose, not the model endpoint")
        XCTAssertEqual(reversed.midY, beforeReverse.midY, accuracy: 4)
        wait(until: { controller.presentedRailFrame == nil && panel.frame.width == 16 })
        XCTAssertNil(controller.presentedRailFrame)
        XCTAssertEqual(panel.frame.width, 16)
        XCTAssertEqual(reveal.canvas.frame, reveal.bounds)
        XCTAssertFalse(panel.ignoresMouseEvents, "Settled compact strip must accept hover/click again")
    }
}
