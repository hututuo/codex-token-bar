import AppKit
import SwiftUI

/// Decorative animation follows actual exposure, not app activation (a sidebar
/// stays useful while Codex is frontmost). Data collection is never gated here.
struct AnimationActivity {
    static func runs(visible: Bool, reducedMotion: Bool, lowPower: Bool) -> Bool {
        visible && !reducedMotion && !lowPower
    }
    static func visible(bounds: CGRect, visibleRect: CGRect, windowVisible: Bool,
                        miniaturized: Bool, occluded: Bool, hidden: Bool) -> Bool {
        windowVisible && !miniaturized && !occluded && !hidden
            && bounds.intersection(visibleRect).width > 0
            && bounds.intersection(visibleRect).height > 0
    }
}

/// Reads clipping/window exposure on existing AppKit notifications. No timer,
/// display link, window enumeration or Accessibility permission is required.
struct AnimationVisibilityProbe: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> AnimationVisibilityView {
        let view = AnimationVisibilityView()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: AnimationVisibilityView, context: Context) {
        view.changed = changed
        view.scheduleCheck()
    }
    static func dismantleNSView(_ view: AnimationVisibilityView, coordinator: ()) { view.changed = nil; view.stop() }
}

@MainActor
final class AnimationVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    var includesMotionPolicy = false
    private let notifications = AnimationNotificationBag()
    private var scheduled = false
    private var lastVisible: Bool?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installObservers(); scheduleCheck() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); installObservers(); scheduleCheck() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleCheck() }
    override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); scheduleCheck() }
    private func installObservers() {
        stop()
        func observe(_ name: Notification.Name, _ object: AnyObject?, center: NotificationCenter = .default) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
            notifications.add(token, center: center)
        }
        observe(.NSProcessInfoPowerStateDidChange, nil)
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, nil, center: NSWorkspace.shared.notificationCenter)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification,
                         NSWindow.didMoveNotification] { observe(name, window) }
        }
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, clip)
            }
            ancestor = view.superview
        }
    }
    func stop() {
        notifications.reset()
    }
    func scheduleCheck() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let exposed = AnimationActivity.visible(bounds: self.bounds, visibleRect: self.visibleRect,
                windowVisible: self.window?.isVisible == true, miniaturized: self.window?.isMiniaturized == true,
                occluded: self.window?.occlusionState.contains(.visible) != true, hidden: self.isHiddenOrHasHiddenAncestor)
            let visible = self.includesMotionPolicy
                ? AnimationActivity.runs(visible: exposed,
                    reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                : exposed
            guard visible != self.lastVisible else { return }
            self.lastVisible = visible
            self.changed?(visible)
        }
    }
}

/// Registrations are mutated on the main actor. The bag itself owns their final
/// cancellation, including when an AppKit-owned unread effect is deallocated.
private final class AnimationNotificationBag: @unchecked Sendable {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ token: NSObjectProtocol, center: NotificationCenter) { tokens.append((center, token)) }
    func reset() { tokens.forEach { $0.0.removeObserver($0.1) }; tokens.removeAll() }
    deinit { reset() }
}
