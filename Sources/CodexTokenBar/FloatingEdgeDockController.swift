import AppKit
import SwiftUI

/// One-shot hover/settlement timers only. Window geometry changes happen at
/// transition boundaries; SwiftUI interpolates the shell and content in between.
@MainActor
final class FloatingEdgeDockController {
    let presentation = FloatingEdgeDockPresentation()
    private weak var panel: NSPanel?
    private var trackingView: FloatingEdgeTrackingView?
    private let pointerLocation: () -> NSPoint
    private let pressedMouseButtons: () -> Int
    private var enabled: () -> Bool = { false }
    private var persist: (NSPoint) -> Void = { _ in }
    private var pending: DispatchWorkItem?
    private var dragCompletion: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var menuDepth = 0
    private var dragging = false
    private var resumeAfterLayout = false
    private var resizingAnchor: FloatingEdgeDockAnchor?
    private var heldOpen = false
    private(set) var isGuiding = false
    private var guidePointer: NSPoint?
    private var effectivePointer: NSPoint { guidePointer ?? pointerLocation() }
    private var effectiveButtons: Int { isGuiding ? 0 : pressedMouseButtons() }
    private var undockedCornerRadius: CGFloat = 14
    private var observers: [NSObjectProtocol] = []
    private(set) var isApplyingGeometry = false
    var expandedFrame: NSRect? { presentation.anchor?.expandedFrame }
    var isAttached: Bool { presentation.anchor != nil }

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         pressedMouseButtons: @escaping () -> Int = { NSEvent.pressedMouseButtons }) {
        self.pointerLocation = pointerLocation
        self.pressedMouseButtons = pressedMouseButtons
        presentation.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        presentation.onReveal = { [weak self] in self?.reveal() }
    }

    func bind(panel: NSPanel, enabled: @escaping () -> Bool, persist: @escaping (NSPoint) -> Void) {
        self.panel = panel
        self.enabled = enabled
        self.persist = persist
        trackingView?.removeFromSuperview()
        if let content = panel.contentView {
            let view = FloatingEdgeTrackingView(frame: content.bounds) { [weak self] in self?.hoverChanged($0) }
            content.addSubview(view)
            view.updateTrackingAreas()
            trackingView = view
        }
        guard observers.isEmpty else { return }
        for (name, begins) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth + (begins ? 1 : -1))
                    if begins { self.reveal() } else { self.scheduleCollapseIfOutside() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    func dispose() {
        dragCompletion?.cancel()
        dragCompletion = nil
        cancelPending()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        trackingView?.removeFromSuperview()
        trackingView = nil
        presentation.anchor = nil
        presentation.collapsed = false
        presentation.compactWindow = false
        panel = nil
        enabled = { false }
        persist = { _ in }
        dragging = false
        isGuiding = false
        guidePointer = nil
        heldOpen = false
        resizingAnchor = nil
        menuDepth = 0
    }

    @discardableResult
    func detach() -> Bool {
        resumeAfterLayout = false
        resizingAnchor = nil
        cancelPending()
        guard let anchor = presentation.anchor else { return false }
        // Restore before handing geometry back to drag, lock-follow or a details
        // card. Neither the narrow handle nor animation coordinates are saved.
        setFrame(anchor.expandedFrame)
        presentation.compactWindow = false
        presentation.collapsed = false
        presentation.anchor = nil
        panel?.contentView?.layer?.cornerRadius = undockedCornerRadius
        return true
    }

    func beginGuide(pointer: NSPoint) {
        isGuiding = true
        guidePointer = pointer
        heldOpen = false
        detach()
    }

    func guideHover(at point: NSPoint) {
        guard isGuiding else { return }
        guidePointer = point
        if let panel { applyHover(panel.frame.contains(point)) }
    }

    func endGuide() {
        cancelPending()
        dragging = false
        guidePointer = nil
        isGuiding = false
    }

    func holdOpen(_ value: Bool) {
        heldOpen = value
        if value { reveal(); cancelPending() }
        else { scheduleCollapseIfOutside() }
    }

    func prepareForResize() {
        if let anchor = presentation.anchor, enabled() {
            resizingAnchor = anchor
            reveal()
            cancelPending()
            return
        }
        let shouldResume = isAttached || resumeAfterLayout
        detach()
        resumeAfterLayout = shouldResume
    }

    func resumeAfterResize() {
        if let previous = resizingAnchor, let panel, enabled() {
            resizingAnchor = nil
            presentation.anchor = FloatingEdgeDockAnchor(edge: previous.edge, expandedFrame: panel.frame)
            panel.contentView?.layer?.cornerRadius = 0
            scheduleCollapseIfOutside()
            return
        }
        guard resumeAfterLayout, enabled() else { return }
        snapIfNearEdge()
        if isAttached { resumeAfterLayout = false }
    }

    func beginDrag() {
        dragCompletion?.cancel()
        dragCompletion = nil
        dragging = true
        detach()
    }

    func endDrag() {
        guard dragging else { return }
        // performDrag(with:) can return before the OS-owned mouse gesture ends.
        // Keep the old dock detached until release, then inspect the final frame.
        if effectiveButtons & 1 != 0 {
            dragCompletion?.cancel()
            let completion = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.endDrag() }
            }
            dragCompletion = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: completion)
            return
        }
        dragCompletion?.cancel()
        dragCompletion = nil
        cancelPending()
        dragging = false
        snapIfNearEdge()
    }

    func interactionEnded() {
        if dragging { endDrag() } else { scheduleCollapseIfOutside() }
    }

    func snapIfNearEdge() {
        guard !heldOpen, !dragging, enabled(), let panel, !isApplyingGeometry, !isAttached else { return }
        let frame = panel.frame
        guard let screen = NSScreen.screens.max(by: {
            Self.intersectionArea(frame, $0.visibleFrame) < Self.intersectionArea(frame, $1.visibleFrame)
        }), let anchor = FloatingEdgeDockAnchor.resolve(frame: frame, workArea: screen.visibleFrame) else { return }
        cancelPending()
        setFrame(anchor.expandedFrame)
        undockedCornerRadius = panel.contentView?.layer?.cornerRadius ?? 14
        panel.contentView?.layer?.cornerRadius = 0
        presentation.compactWindow = false
        presentation.collapsed = false
        withAnimation(motion(expanding: true)) { presentation.anchor = anchor }
        if !isGuiding { persist(anchor.expandedFrame.origin) }
        scheduleCollapseIfOutside()
    }

    func hoverChanged(_ inside: Bool) {
        guard !isGuiding else { return }
        applyHover(inside)
    }

    private func applyHover(_ inside: Bool) {
        guard isAttached, !isApplyingGeometry, let panel else { return }
        // AppKit can deliver stale enter/exit events as a tracking area resizes.
        // They must neither reveal an off-pointer panel nor restart its collapse.
        guard inside == panel.frame.contains(effectivePointer) else { return }
        if inside {
            if presentation.collapsed {
                reveal()
            } else {
                cancelPending()
            }
        } else {
            scheduleCollapseIfOutside()
        }
    }

    func reveal() {
        guard let anchor = presentation.anchor else { return }
        cancelPending()
        // Resizing an already-open drawer must not publish a redundant spring
        // transaction that animates the following hosting-view geometry change.
        guard presentation.collapsed || presentation.compactWindow else { return }
        let wasCompact = presentation.compactWindow
        if wasCompact {
            // Expand the input window once, then animate within its fixed frame.
            setFrame(anchor.expandedFrame)
            presentation.compactWindow = false
            animateReveal()
        } else {
            animateReveal()
        }
    }

    private func animateReveal() {
        guard isAttached else { return }
        withAnimation(motion(expanding: true)) { presentation.collapsed = false }
        scheduleCollapseIfOutside()
    }

    private func scheduleCollapseIfOutside() {
        guard isAttached, !heldOpen, !dragging, menuDepth == 0, !presentation.compactWindow, !presentation.collapsed,
              let panel, !panel.frame.contains(effectivePointer) else { return }
        schedule(after: 0.45) { [weak self] in self?.collapse() }
    }

    private func collapse() {
        guard enabled(), !heldOpen, !dragging, menuDepth == 0, !presentation.collapsed,
              let panel, let anchor = presentation.anchor,
              !panel.frame.contains(effectivePointer) else { return }
        if effectiveButtons != 0 {
            schedule(after: 0.10) { [weak self] in self?.collapse() }
            return
        }
        withAnimation(motion(expanding: false)) { presentation.collapsed = true }
        schedule(after: reducedMotion ? 0.02 : 0.17) { [weak self] in
            guard let self, self.presentation.collapsed else { return }
            // Shrink native hit bounds too: no transparent rectangle remains
            // over neighbouring applications after the animation has settled.
            self.presentation.compactWindow = true
            self.setFrame(anchor.collapsedFrame)
        }
    }

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func motion(expanding: Bool) -> Animation? {
        guard !reducedMotion else { return nil }
        return expanding ? .spring(response: 0.26, dampingFraction: 0.88)
                         : .timingCurve(0.65, 0, 0.35, 1, duration: 0.15)
    }

    private func setFrame(_ frame: NSRect) {
        isApplyingGeometry = true
        panel?.setFrame(frame, display: true)
        isApplyingGeometry = false
    }

    private func cancelPending() {
        generation &+= 1
        pending?.cancel()
        pending = nil
    }

    private func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancelPending()
        let expected = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else { return }
                self.pending = nil
                action()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func screensChanged() {
        guard let anchor = presentation.anchor, let panel else { return }
        detach()
        guard let screen = NSScreen.screens.max(by: {
            Self.intersectionArea(anchor.expandedFrame, $0.visibleFrame) < Self.intersectionArea(anchor.expandedFrame, $1.visibleFrame)
        }) else { return }
        let area = screen.visibleFrame
        let frame = Self.restoredFrame(anchor.expandedFrame, in: area)
        setFrame(frame)
        persist(panel.frame.origin)
        snapIfNearEdge()
    }

    static func restoredFrame(_ original: NSRect, in area: NSRect) -> NSRect {
        var frame = original
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
