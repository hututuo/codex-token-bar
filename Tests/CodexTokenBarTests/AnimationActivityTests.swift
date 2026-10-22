import AppKit
import XCTest
@testable import CodexTokenBar

final class AnimationActivityTests: XCTestCase {
    func testDecorativeMotionOnlyRunsWhenExposedAndPermitted() {
        for visible in [true, false] {
            for reduce in [true, false] {
                for lowPower in [true, false] {
                    XCTAssertEqual(AnimationActivity.runs(visible: visible, reducedMotion: reduce, lowPower: lowPower),
                                   visible && !reduce && !lowPower)
                }
            }
        }
    }
    func testClippedAndHiddenOrMinimizedWindowsStopAnimation() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        func check(_ rect: CGRect = .init(x: 0, y: 0, width: 200, height: 100),
                   visible: Bool = true, mini: Bool = false, occluded: Bool = false, hidden: Bool = false) -> Bool {
            AnimationActivity.visible(bounds: bounds, visibleRect: rect, windowVisible: visible,
                                      miniaturized: mini, occluded: occluded, hidden: hidden)
        }
        XCTAssertTrue(check())
        XCTAssertTrue(check(.init(x: 199, y: 0, width: 10, height: 10)))
        XCTAssertFalse(check(.init(x: 200, y: 0, width: 10, height: 10)))
        XCTAssertFalse(check(.zero))
        XCTAssertFalse(check(visible: false))
        XCTAssertFalse(check(mini: true))
        XCTAssertFalse(check(occluded: true))
        XCTAssertFalse(check(hidden: true))
    }
    @MainActor
    func testNativeProbeTracksScrollClippingAndStopsAfterTeardown() async throws {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: .init(x: 0, y: 0, width: 200, height: 500))
        let probe = AnimationVisibilityView(frame: .init(x: 0, y: 0, width: 200, height: 50))
        var states: [Bool] = []
        probe.changed = { states.append($0) }
        document.addSubview(probe); scroll.documentView = document
        let window = VisibilityTestWindow(contentRect: .init(x: 140, y: 140, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { probe.stop(); window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
        window.orderFrontRegardless()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        probe.scheduleCheck(); try await settle()
        XCTAssertEqual(states.last, true)
        scroll.contentView.scroll(to: .init(x: 0, y: 250)); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(states.last, false)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(states.last, true)
        window.orderOut(nil); probe.scheduleCheck(); try await settle()
        XCTAssertEqual(states.last, false)
        let count = states.count
        probe.scheduleCheck(); probe.scheduleCheck(); try await settle()
        XCTAssertEqual(states.count, count, "No repeated publication for unchanged exposure")
    }
}

// XCTest windows can be behind another app's fullscreen Space. Test clipping
// deterministically; occlusion semantics themselves are covered in the policy test.
@MainActor
private final class VisibilityTestWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
