import AppKit
import SwiftUI

/// One-shot hover/settlement timers only. Window geometry changes happen at
/// transition boundaries; SwiftUI interpolates the shell and content in between.
@MainActor
final class FloatingEdgeDockController {
    let presentation = FloatingEdgeDockPresentation()
    private weak var panel: NSPanel?
    private var enabled: () -> Bool = { false }
    private var persist: (NSPoint) -> Void = { _ in }
    private var pending: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var menuDepth = 0
    private var dragging = false
    private var resumeAfterLayout = false
    private var undockedCornerRadius: CGFloat = 14
    private var observers: [NSObjectProtocol] = []
    private(set) var isApplyingGeometry = false
    var expandedFrame: NSRect? { presentation.anchor?.expandedFrame }
    var isAttached: Bool { presentation.anchor != nil }

    init() {
        presentation.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        presentation.onReveal = { [weak self] in self?.reveal() }
    }

    func bind(panel: NSPanel, enabled: @escaping () -> Bool, persist: @escaping (NSPoint) -> Void) {
        self.panel = panel
        self.enabled = enabled
        self.persist = persist
        guard observers.isEmpty else { return }
        for (name, begins) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth + (begins ? 1 : -1))
                    if begins { self.cancelPending() } else { self.scheduleCollapseIfOutside() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    func dispose() {
        cancelPending()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        presentation.anchor = nil
        presentation.collapsed = false
        presentation.compactWindow = false
        panel = nil
        enabled = { false }
        persist = { _ in }
        dragging = false
        menuDepth = 0
    }

    @discardableResult
    func detach() -> Bool {
        resumeAfterLayout = false
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

    func prepareForResize() {
        let shouldResume = isAttached || resumeAfterLayout
        detach()
        resumeAfterLayout = shouldResume
    }

    func resumeAfterResize() {
        guard resumeAfterLayout, enabled() else { return }
        snapIfNearEdge()
        if isAttached { resumeAfterLayout = false }
    }

    func beginDrag() {
        dragging = true
        detach()
    }

    func endDrag() {
        dragging = false
        snapIfNearEdge()
    }

    func interactionEnded() { scheduleCollapseIfOutside() }

    func snapIfNearEdge() {
        guard !dragging, enabled(), let panel, !isApplyingGeometry, !isAttached else { return }
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
        persist(anchor.expandedFrame.origin)
        scheduleCollapseIfOutside()
    }

    func hoverChanged(_ inside: Bool) {
        guard isAttached else { return }
        if inside {
            if presentation.collapsed {
                schedule(after: 0.10) { [weak self] in self?.reveal() }
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
        let wasCompact = presentation.compactWindow
        if wasCompact {
            // Expand the input window once, then animate within its fixed frame.
            setFrame(anchor.expandedFrame)
            presentation.compactWindow = false
            schedule(after: 0.02) { [weak self] in self?.animateReveal() }
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
        guard isAttached, !dragging, menuDepth == 0, !presentation.compactWindow,
              let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        schedule(after: 0.45) { [weak self] in self?.collapse() }
    }

    private func collapse() {
        guard enabled(), !dragging, menuDepth == 0,
              let panel, let anchor = presentation.anchor,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        if NSEvent.pressedMouseButtons != 0 {
            schedule(after: 0.10) { [weak self] in self?.collapse() }
            return
        }
        withAnimation(motion(expanding: false)) { presentation.collapsed = true }
        schedule(after: reducedMotion ? 0.02 : 0.34) { [weak self] in
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
        return expanding ? .spring(response: 0.38, dampingFraction: 0.78)
                         : .timingCurve(0.65, 0, 0.35, 1, duration: 0.30)
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
        var frame = anchor.expandedFrame
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        setFrame(frame)
        persist(panel.frame.origin)
        snapIfNearEdge()
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
