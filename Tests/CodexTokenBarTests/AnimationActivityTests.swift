import AppKit
import XCTest
import SwiftUI
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
    func testGuidePausesThroughScrollAndResumesAfterIdleWithoutDuplicateUpdates() async throws {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: .init(x: 0, y: 0, width: 200, height: 800))
        let probe = AnimationVisibilityView(frame: .init(x: 0, y: 0, width: 200, height: 800))
        probe.pausesDuringScroll = true
        // A loaded host may resume a 60ms sleep after the real 180ms idle
        // deadline. Drive event time separately from run-loop delivery time.
        var scrollTime: TimeInterval = 0
        probe.scrollClock = { scrollTime }
        var states: [Bool] = []
        probe.changed = { states.append($0) }
        document.addSubview(probe); scroll.documentView = document
        let window = VisibilityTestWindow(contentRect: .init(x: 140, y: 140, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { probe.changed = nil; probe.stop(); window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(states.last, true)
        for offset in [20, 40, 60, 80, 100] {
            scrollTime += 0.06
            scroll.contentView.scroll(to: .init(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(states.last, false, "Pause must cover continuous wheel/trackpad or programmatic scrolling")
        }
        XCTAssertEqual(states.filter { !$0 }.count, 1, "Do not invalidate the guide once per scroll frame")
        scrollTime += 0.25
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(states.last, true, "Resume after scrolling settles")
        let count = states.count
        // A duplicate bounds notification with no position change is not scrolling.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(states.count, count)
        probe.changed = nil; probe.stop()
        scroll.contentView.scroll(to: .init(x: 0, y: 120))
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(states.count, count, "Detached probe must not publish delayed animation updates")
    }

    @MainActor
    func testUnscaledDashboardContainerKeepsOffscreenSectionsLazy() async throws {
        var appeared: Set<Int> = []
        let content = ScrollView {
            InterfaceScaledContainer(scale: 1, visualWidth: 300) {
                LazyVStack(spacing: 18) {
                    ForEach(0..<100) { index in
                        Text("Section \(index)").frame(height: 160)
                            .onAppear { appeared.insert(index) }
                    }
                }
            }
        }
        let window = VisibilityTestWindow(contentRect: .init(x: 150, y: 150, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(appeared.contains(0))
        XCTAssertLessThan(appeared.count, 10, "100% scaling must not eagerly lay out all historical sections")
    }

    @MainActor
    func testProbeInsideProductionSwiftUIScrollViewClipsOffscreenContent() async throws {
        var topStates: [Bool] = [], bottomStates: [Bool] = []
        let content = ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 100)
                    .background(AnimationVisibilityProbe { topStates.append($0) })
                Color.clear.frame(height: 800)
                Color.clear.frame(height: 100)
                    .background(AnimationVisibilityProbe { bottomStates.append($0) })
            }.frame(width: 300)
        }
        let window = VisibilityTestWindow(contentRect: .init(x: 150, y: 150, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(topStates.last, true)
        XCTAssertEqual(bottomStates.last, false, "Production SwiftUI clipping must pause offscreen guides")
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
