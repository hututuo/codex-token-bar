import AppKit
import XCTest
import SwiftUI
@testable import CodexTokenBar

final class FloatingDetailsDrawerTests: XCTestCase {
    @MainActor
    func testRenderedCardsShareWidthGapAndOuterMargins() async throws {
        for placement in [FloatingRunningModelDetailsPlacement.below, .above] {
            let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
            let normal = FloatingTokenPanelLayout(scale: scale, visibility: .default)
            let expanded = FloatingTokenPanelLayout(scale: scale, visibility: .default,
                runningModelDetailsPresented: true, runningModelDetailsRowUnits: 3,
                runningModelDetailsPlacement: placement)
            let state = FloatingRunningModelDetailsSessionState()
            state.updateLayout(expanded)
            let dock = FloatingEdgeDockPresentation()
            let marker = NSView(frame: .zero), detail = NSView(frame: .zero)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: expanded.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.contentViewController = nil; panel.close() }
            dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
            let host = FloatingPanelHostingController(rootView: DrawerHostProbe(state: state, dock: dock,
                marker: marker, normal: normal, expanded: expanded, close: {}, detailMarker: detail))
            panel.contentViewController = host
            resizePanel(panel, layout: expanded, surfaceSize: normal.size,
                baseFrame: NSRect(origin: .zero, size: normal.size))
            dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
            for _ in 0..<5 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let mainFrame = marker.convert(marker.bounds, to: nil)
            let detailFrame = detail.convert(detail.bounds, to: nil)
            XCTAssertEqual(mainFrame.width, detailFrame.width, accuracy: 0.01)
            XCTAssertEqual(mainFrame.minX, detailFrame.minX, accuracy: 0.01)
            let bottom = min(mainFrame.minY, detailFrame.minY)
            let top = max(mainFrame.maxY, detailFrame.maxY)
            // NSHostingView rounds individual placements to device pixels.
            XCTAssertEqual(bottom, expanded.size.height - top, accuracy: 0.5)
            XCTAssertEqual(bottom, mainFrame.minX, accuracy: 0.5)
            XCTAssertEqual(max(mainFrame.minY, detailFrame.minY) - min(mainFrame.maxY, detailFrame.maxY), 8, accuracy: 0.5)
            XCTAssertEqual(mainFrame.width / mainFrame.height, 258.0 / 120, accuracy: 0.001)
        }
    }

    @MainActor
    func testDetailRequestsDoNotPublishAnUnresolvedDirection() {
        let state = FloatingRunningModelDetailsSessionState()
        var requests: [Bool] = []
        state.requestPresentation = { requests.append($0) }
        state.toggle()
        XCTAssertEqual(requests, [true])
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.drawerLayout)
        let layout = FloatingTokenPanelLayout(scale: FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1),
            visibility: .default, runningModelDetailsPresented: true, runningModelDetailsRowUnits: 3,
            runningModelDetailsPlacement: .above)
        state.updateLayout(layout)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.drawerLayout?.runningModelDetailsPlacement, .above)
        state.dismiss()
        XCTAssertEqual(requests, [true, false])
        XCTAssertTrue(state.isPresented) // The controller has not committed the close frame yet.
        state.updateLayout(nil)
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.drawerLayout)
    }

    @MainActor
    func testRepeatedDrawerCyclesKeepManualWindowConstraintsAndMainPosition() async throws {
        let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
        let normal = FloatingTokenPanelLayout(scale: scale, visibility: .default)
        for placement in [FloatingRunningModelDetailsPlacement.below, .above] {
            let expanded = FloatingTokenPanelLayout(scale: scale, visibility: .default,
                runningModelDetailsPresented: true, runningModelDetailsRowUnits: 3,
                runningModelDetailsPlacement: placement)
            let state = FloatingRunningModelDetailsSessionState()
            let dock = FloatingEdgeDockPresentation()
            let marker = NSView(frame: .zero)
            let base = NSRect(x: 80, y: 300, width: normal.size.width, height: normal.size.height)
            let panel = NSPanel(contentRect: base, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.contentViewController = nil; panel.close() }
            let host = FloatingPanelHostingController(rootView: DrawerHostProbe(state: state, dock: dock, marker: marker,
                normal: normal, expanded: expanded, close: {}))
            XCTAssertTrue(host.hostingController.sizingOptions.isEmpty)
            panel.contentViewController = host
            resizePanel(panel, layout: normal, surfaceSize: normal.size, baseFrame: base)
            dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
            state.requestPresentation = { presented in
                if presented { state.updateLayout(expanded) }
                resizePanel(panel, layout: presented ? expanded : normal, surfaceSize: normal.size, baseFrame: base)
                if !presented { state.updateLayout(nil) }
                dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
            }
            for _ in 0..<4 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let original = panel.convertToScreen(marker.convert(marker.bounds, to: nil))
            for cycle in 0..<10 {
                for presented in [true, false] {
                    state.toggle()
                    for sample in 0..<5 {
                        host.view.layoutSubtreeIfNeeded()
                        let actual = panel.convertToScreen(marker.convert(marker.bounds, to: nil))
                        XCTAssertEqual(actual.minY, original.minY, accuracy: 0.5, "\(placement) cycle \(cycle) opened \(presented) sample \(sample)")
                        XCTAssertEqual(actual.height, original.height, accuracy: 0.5)
                        XCTAssertEqual(panel.contentMinSize, presented ? expanded.size : normal.size)
                        XCTAssertEqual(panel.contentMaxSize, presented ? expanded.size : normal.size)
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        }
    }

    @MainActor
    func testPreparingAlreadyOpenDockDoesNotPublishAnExpansionAnimation() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 100, width: 258, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let dock = FloatingEdgeDockController(pointerLocation: { NSPoint(x: 100, y: 150) }, pressedMouseButtons: { 0 })
        dock.bind(panel: panel, enabled: { true }, persist: { _ in })
        dock.presentation.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
        var publications = 0
        let subscription = dock.presentation.objectWillChange.sink { publications += 1 }
        dock.holdOpen(true)
        dock.prepareForResize()
        XCTAssertEqual(publications, 0)
        subscription.cancel(); dock.dispose(); panel.close()
    }

    @MainActor
    func testSideDockContentsTranslateWithoutChangingHeightOrVerticalPosition() async throws {
        let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
        let normal = FloatingTokenPanelLayout(scale: scale, visibility: .default)
        for edge in [FloatingDockEdge.left, .right] {
            let state = FloatingRunningModelDetailsSessionState()
            let dock = FloatingEdgeDockPresentation()
            let marker = NSView(frame: .zero)
            let panel = NSPanel(contentRect: NSRect(x: 100, y: 300, width: normal.size.width, height: normal.size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.contentViewController = nil; panel.close() }
            let host = FloatingPanelHostingController(rootView: DrawerHostProbe(state: state, dock: dock, marker: marker,
                normal: normal, expanded: normal, close: {}))
            panel.contentViewController = host
            host.view.frame = NSRect(origin: .zero, size: normal.size)
            dock.anchor = FloatingEdgeDockAnchor(edge: edge, expandedFrame: panel.frame)
            for _ in 0..<4 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let expandedFrame = marker.convert(marker.bounds, to: nil)
            dock.collapsed = true
            for _ in 0..<4 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let collapsedFrame = marker.convert(marker.bounds, to: nil)
            XCTAssertEqual(collapsedFrame.minY, expandedFrame.minY, accuracy: 0.001)
            XCTAssertEqual(collapsedFrame.height, expandedFrame.height, accuracy: 0.001)
            XCTAssertEqual(collapsedFrame.width, expandedFrame.width, accuracy: 0.001)
            XCTAssertEqual(abs(collapsedFrame.minX - expandedFrame.minX), normal.size.width, accuracy: 0.001)
            XCTAssertEqual(expandedFrame.width / expandedFrame.height, normal.size.width / (normal.size.height - 2 * FloatingTokenPanelMetrics.shellPadding), accuracy: 0.001)
        }
    }

    @MainActor
    func testHiddenHostKeepsMainCardScreenPositionWhileClosing() async throws {
        let scale = FloatingTokenPanelScale(baseScale: 1, interfaceScale: 1)
        let normal = FloatingTokenPanelLayout(scale: scale, visibility: .default)
        let expanded = FloatingTokenPanelLayout(scale: scale, visibility: .default,
            runningModelDetailsPresented: true, runningModelDetailsRowUnits: 3)
        let state = FloatingRunningModelDetailsSessionState()
        let dock = FloatingEdgeDockPresentation()
        let marker = NSView(frame: .zero)
        let base = NSRect(x: 80, y: 300, width: normal.size.width, height: normal.size.height)
        let panel = NSPanel(contentRect: base, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentViewController = nil; panel.close() }
        state.toggle(); state.updateLayout(expanded)
        let host = FloatingPanelHostingController(rootView: DrawerHostProbe(state: state, dock: dock, marker: marker,
            normal: normal, expanded: expanded, close: {
                resizePanel(panel, layout: normal, surfaceSize: normal.size, baseFrame: base)
                state.updateLayout(nil)
                dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
            }))
        panel.contentViewController = host
        resizePanel(panel, layout: expanded, surfaceSize: normal.size, baseFrame: base)
        dock.anchor = FloatingEdgeDockAnchor(edge: .left, expandedFrame: panel.frame)
        for _ in 0..<10 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func markerScreenFrame() -> NSRect { panel.convertToScreen(marker.convert(marker.bounds, to: nil)) }
        let before = markerScreenFrame()
        XCTAssertEqual(before.width / before.height, normal.size.width / (normal.size.height - 2 * FloatingTokenPanelMetrics.shellPadding), accuracy: 0.001)
        state.dismiss()
        var frames: [NSRect] = []
        for _ in 0..<20 {
            host.view.layoutSubtreeIfNeeded()
            frames.append(markerScreenFrame())
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(frames.allSatisfy { abs($0.minY - before.minY) < 1 && abs($0.maxY - before.maxY) < 1 })
    }

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

private struct DrawerMarker: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
private struct DrawerHostProbe: View {
    @ObservedObject var state: FloatingRunningModelDetailsSessionState
    @ObservedObject var dock: FloatingEdgeDockPresentation
    let marker: NSView
    let normal: FloatingTokenPanelLayout
    let expanded: FloatingTokenPanelLayout
    let close: () -> Void
    var detailMarker: NSView? = nil
    var body: some View {
        let size = state.drawerLayout?.size ?? (state.isPresented ? expanded.size : normal.size)
        let above = state.drawerLayout?.runningModelDetailsPlacement == .above
        let factor = dock.anchor == nil ? 1 : max(0.8, (normal.size.width - 10) / normal.size.width)
        let padding = FloatingTokenPanelMetrics.shellPadding * normal.effectiveScale
        let surface = NSSize(width: normal.size.width, height: normal.size.height - 2 * padding)
        let contentHeight = surface.height + (size.height - normal.size.height) / factor
        ZStack(alignment: .topLeading) {
            DrawerMarker(view: marker).frame(width: surface.width, height: surface.height)
                .offset(y: above ? contentHeight - surface.height : 0)
            if state.isPresented, let detailMarker {
                DrawerMarker(view: detailMarker)
                    .frame(width: surface.width, height: max(0, contentHeight - surface.height - 8 * normal.effectiveScale / factor))
                    .offset(y: above ? 0 : surface.height + 8 * normal.effectiveScale / factor)
            }
        }
        .frame(width: size.width, height: contentHeight, alignment: .topLeading)
        .modifier(FloatingEdgeDockModifier(presentation: dock, size: size, surfaceSize: surface, detailsAbove: above, shellPadding: padding, quota: .empty, quotaColorStyle: .default))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: above ? .bottomLeading : .topLeading)
        .animation(nil, value: size)
        .animation(nil, value: state.isPresented)
        .onChange(of: state.isPresented) { _, presented in if !presented { close() } }
    }
}
