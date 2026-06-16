import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import SwiftUI

@MainActor
final class FloatingTokenPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    @Published private(set) var lockTargetDescription: String?

    private var panel: NSPanel?
    private var onClose: (() -> Void)?
    private var onToggleLock: (() -> Void)?
    private var lastExternalActivePID: pid_t?
    private var lastExternalClickLocation: NSPoint?
    private var lastExternalClickAt: Date?
    private var lastExternalClickWindowNumber: Int?
    private var lastExternalClickOwnerPID: pid_t?
    private var lastExternalClickAXWindow: AXUIElement?
    private var lockedAnchor: FloatingPanelWindowAnchor?
    private var followTimer: Timer?
    private var followTimerInterval: TimeInterval?
    private var fastFollowUntil: Date?
    private var accessibilityObserver: AXObserver?
    private var observedAccessibilityWindow: AXUIElement?
    private var activeLockedTargetDrag: FloatingPanelLockedTargetDrag?
    private var pendingLockedOriginToPersist: NSPoint?
    private var lockedOriginPersistTimer: Timer?
    private var lastLockedOriginPersistAt = Date.distantPast
    nonisolated(unsafe) private var globalMouseMonitor: Any?
    private var isProgrammaticPanelMove = false
    private var appliedLockState = false
    private let recentExternalClickTargetInterval: TimeInterval = 5 * 60
    private let fastFollowInterval: TimeInterval = 1.0 / 60.0
    private let idleFollowInterval: TimeInterval = 0.5
    private let fastFollowGracePeriod: TimeInterval = 1.2
    private let lockedOriginPersistInterval: TimeInterval = 0.45
    private let screenPositionLockDescription = "屏幕位置"
    private let lockTargetDescriptionKey = "floatingPanelLockTargetDescription"
    private let lockedOriginXKey = "floatingPanelLockedOriginX"
    private let lockedOriginYKey = "floatingPanelLockedOriginY"

    nonisolated private static let accessibilityObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<FloatingTokenPanelController>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in
            controller.handleAccessibilityWindowEvent()
        }
    }

    override init() {
        super.init()
        lastExternalActivePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                switch event.type {
                case .leftMouseDown:
                    self?.recordExternalMouseClick(at: location)
                case .leftMouseDragged:
                    self?.recordExternalMouseDrag(at: location)
                case .leftMouseUp:
                    self?.finishExternalMouseDrag(at: location)
                default:
                    break
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    func show(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        taskCompletionMonitor: TaskCompletionMonitor,
        scale: Double,
        isLocked: Bool,
        onToggleLock: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.onToggleLock = onToggleLock

        if panel == nil {
            let hostingController = NSHostingController(
                rootView: FloatingTokenPanelView(
                    store: store,
                    monitor: monitor,
                    quota: quota,
                    taskCompletionMonitor: taskCompletionMonitor,
                    isLocked: isLocked,
                    lockTargetDescription: lockTargetDescription,
                    onToggleLock: { [weak self] in
                        self?.onToggleLock?()
                    },
                    onClose: { [weak self] in
                        self?.onClose?()
                    }
                )
            )
            let initialSize = FloatingTokenPanelMetrics.size(scale: scale)
            hostingController.view.frame = NSRect(origin: .zero, size: initialSize)
            hostingController.view.autoresizingMask = [.width, .height]

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = !isLocked
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.delegate = self
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: scale)
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
            position(panel)
            self.panel = panel
        }

        if let hostingController = panel?.contentViewController as? NSHostingController<FloatingTokenPanelView> {
            hostingController.rootView = FloatingTokenPanelView(
                store: store,
                monitor: monitor,
                quota: quota,
                taskCompletionMonitor: taskCompletionMonitor,
                isLocked: isLocked,
                lockTargetDescription: lockTargetDescription,
                onToggleLock: { [weak self] in
                    self?.onToggleLock?()
                },
                onClose: { [weak self] in
                    self?.onClose?()
                }
            )
        }

        let wasPresented = isPresented
        updateSize(scale: scale)
        updateLockState(isLocked, force: !wasPresented)
        panel?.orderFrontRegardless()
        isPresented = true
    }

    func updateSize(scale: Double) {
        guard let panel else { return }
        isProgrammaticPanelMove = true
        resizePanel(panel, scale: scale)
        panel.contentView?.layer?.cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: scale)
        saveLockedOrigin(panel.frame.origin)
        refreshLockedAnchorOffsetForCurrentFrame()
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticPanelMove = false
        }
    }

    func close() {
        panel?.orderOut(nil)
        stopFollowingAnchor()
        isPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        stopFollowingAnchor()
        isPresented = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        guard !isProgrammaticPanelMove else { return }
        saveLockedOrigin(panel.frame.origin)
        if lockedAnchor != nil {
            lockedAnchor = currentAnchor(for: panel)
            lockTargetDescription = lockedAnchor?.targetDescription
            refreshFloatingPanelLockStatus()
        }
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalActivePID = app.processIdentifier
    }

    private func recordExternalMouseClick(at location: NSPoint) {
        if let panel, panel.frame.contains(location) {
            activeLockedTargetDrag = nil
            return
        }
        lastExternalClickLocation = location
        lastExternalClickAt = Date()
        let clickedAXTarget = accessibilityTarget(at: location)
        if let target = clickedAXTarget {
            lastExternalClickAXWindow = target.window
            lastExternalClickOwnerPID = target.ownerPID
            lastExternalActivePID = target.ownerPID
        } else {
            lastExternalClickAXWindow = nil
        }
        let clickedWindow = visibleWindows(relaxed: true).first(where: { windowContainsClick(location, window: $0) })
        if let window = clickedWindow {
            lastExternalClickWindowNumber = window.windowNumber
            lastExternalClickOwnerPID = window.ownerPID
            lastExternalActivePID = window.ownerPID
        } else {
            lastExternalClickWindowNumber = nil
            if lastExternalClickAXWindow == nil {
                lastExternalClickOwnerPID = nil
            }
        }
        beginLockedTargetDragIfNeeded(
            at: location,
            clickedWindow: clickedWindow,
            clickedAXTarget: clickedAXTarget
        )
    }

    private func recordExternalMouseDrag(at location: NSPoint) {
        guard activeLockedTargetDrag != nil else { return }
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followLockedTargetDrag(at: location)
    }

    private func finishExternalMouseDrag(at location: NSPoint) {
        guard activeLockedTargetDrag != nil else { return }
        followLockedTargetDrag(at: location)
        activeLockedTargetDrag = nil
        refreshLockedAnchorOffsetForCurrentFrame()
    }

    private func beginLockedTargetDragIfNeeded(
        at location: NSPoint,
        clickedWindow: FloatingPanelTargetWindow?,
        clickedAXTarget: FloatingPanelAccessibilityTarget?
    ) {
        activeLockedTargetDrag = nil
        guard let panel, let anchor = lockedAnchor else { return }
        let clickedLockedTarget =
            (clickedWindow.map { targetWindow($0, matches: anchor) } ?? false) ||
            (clickedAXTarget.map { accessibilityTarget($0, matches: anchor) } ?? false)
        guard clickedLockedTarget, let followTarget = targetFrame(matching: anchor) else { return }

        activeLockedTargetDrag = FloatingPanelLockedTargetDrag(
            anchor: anchor,
            mouseStart: location,
            panelOriginStart: panel.frame.origin,
            targetFrameStart: followTarget.frame
        )
    }

    @discardableResult
    private func followLockedTargetDrag(at location: NSPoint) -> Bool {
        guard let panel, let drag = activeLockedTargetDrag, let anchor = lockedAnchor else { return false }
        guard drag.matches(anchor) else {
            activeLockedTargetDrag = nil
            return false
        }
        guard let followTarget = targetFrame(matching: anchor) else {
            activeLockedTargetDrag = nil
            return false
        }

        let delta = NSPoint(
            x: location.x - drag.mouseStart.x,
            y: location.y - drag.mouseStart.y
        )
        let mouseDrivenOrigin = NSPoint(
            x: drag.panelOriginStart.x + delta.x,
            y: drag.panelOriginStart.y + delta.y
        )
        let targetDrivenOrigin = NSPoint(
            x: followTarget.frame.minX + anchor.offset.x,
            y: followTarget.frame.minY + anchor.offset.y
        )
        let slip = NSPoint(
            x: mouseDrivenOrigin.x - targetDrivenOrigin.x,
            y: mouseDrivenOrigin.y - targetDrivenOrigin.y
        )
        let boundedSlip = boundedDragSlip(
            slip,
            drag: drag,
            targetFrame: followTarget.frame,
            panel: panel
        )
        let proposedOrigin = NSPoint(
            x: targetDrivenOrigin.x + boundedSlip.x,
            y: targetDrivenOrigin.y + boundedSlip.y
        )
        let frame = anchoredPanelFrame(
            for: panel,
            size: panel.frame.size,
            topLeft: NSPoint(x: proposedOrigin.x, y: proposedOrigin.y + panel.frame.height)
        )
        return movePanelIfNeeded(panel, to: frame.origin, persist: true)
    }

    private func boundedDragSlip(
        _ slip: NSPoint,
        drag: FloatingPanelLockedTargetDrag,
        targetFrame: NSRect,
        panel: NSPanel
    ) -> NSPoint {
        guard let screenFrame = visibleScreenFrame(for: targetFrame, fallback: panel) else {
            return slip
        }

        let clickPointInTarget = NSPoint(
            x: targetFrame.minX + drag.clickOffsetInTarget.x,
            y: targetFrame.minY + drag.clickOffsetInTarget.y
        )
        var bounded = slip

        if bounded.x > 0 {
            bounded.x = min(bounded.x, max(0, screenFrame.maxX - clickPointInTarget.x))
        } else if bounded.x < 0 {
            bounded.x = max(bounded.x, min(0, screenFrame.minX - clickPointInTarget.x))
        }

        if bounded.y > 0 {
            bounded.y = min(bounded.y, max(0, screenFrame.maxY - clickPointInTarget.y))
        } else if bounded.y < 0 {
            bounded.y = max(bounded.y, min(0, screenFrame.minY - clickPointInTarget.y))
        }

        return bounded
    }

    private func position(_ panel: NSPanel) {
        if let savedOrigin = savedLockedOrigin() {
            panel.setFrameOrigin(savedOrigin)
            return
        }

        let anchorWindow = NSApp.windows.first {
            $0 !== panel && $0.isVisible && !($0 is NSPanel)
        }
        let screenFrame = anchorWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            panel.center()
            return
        }

        let margin: CGFloat = 22
        let topInset: CGFloat = 210
        let anchorFrame = anchorWindow?.frame ?? screenFrame
        let origin = NSPoint(
            x: min(anchorFrame.minX + margin, screenFrame.maxX - panel.frame.width - margin),
            y: min(anchorFrame.maxY - panel.frame.height - topInset, screenFrame.maxY - panel.frame.height - topInset)
        )
        panel.setFrameOrigin(NSPoint(x: max(screenFrame.minX + margin, origin.x), y: max(screenFrame.minY + margin, origin.y)))
    }

    private func updateLockState(_ isLocked: Bool, force: Bool = false) {
        guard let panel else { return }
        panel.isMovableByWindowBackground = !isLocked

        guard force || appliedLockState != isLocked else {
            if isLocked, lockedAnchor != nil, followTimer == nil {
                startFollowingAnchor()
            }
            return
        }
        appliedLockState = isLocked

        if isLocked {
            saveLockedOrigin(panel.frame.origin)
            if force && lockedAnchor != nil {
                lockTargetDescription = lockedAnchor?.targetDescription ?? screenPositionLockDescription
                startFollowingAnchor()
                refreshFloatingPanelLockStatus()
                return
            }
            lockedAnchor = currentAnchor(for: panel)
            lockTargetDescription = lockedAnchor?.targetDescription ?? screenPositionLockDescription
            startFollowingAnchor()
        } else {
            lockedAnchor = nil
            lockTargetDescription = nil
            activeLockedTargetDrag = nil
            stopFollowingAnchor()
        }
        refreshFloatingPanelLockStatus()
    }

    private func currentAnchor(for panel: NSPanel) -> FloatingPanelWindowAnchor? {
        if let target = targetAccessibilityWindowAtRecentExternalClick() {
            let offset = NSPoint(
                x: panel.frame.minX - target.frame.minX,
                y: panel.frame.minY - target.frame.minY
            )
            return FloatingPanelWindowAnchor(
                windowNumber: lastExternalClickWindowNumber,
                ownerPID: target.ownerPID,
                ownerBundleID: target.ownerBundleID,
                windowTitle: target.title,
                targetDescription: target.displayName,
                offset: offset,
                accessibilityWindow: target.window
            )
        }
        guard let targetWindow = findTargetWindow(near: panel.frame) else { return nil }
        let offset = NSPoint(
            x: panel.frame.minX - targetWindow.frame.minX,
            y: panel.frame.minY - targetWindow.frame.minY
        )
        return FloatingPanelWindowAnchor(
            windowNumber: targetWindow.windowNumber,
            ownerPID: targetWindow.ownerPID,
            ownerBundleID: targetWindow.ownerBundleID,
            windowTitle: targetWindow.title,
            targetDescription: targetWindow.displayName,
            offset: offset,
            accessibilityWindow: accessibilityTarget(matching: targetWindow)?.window
        )
    }

    private func startFollowingAnchor() {
        guard lockedAnchor != nil else { return }
        installAccessibilityObserverForLockedAnchor()
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followAnchorIfNeeded()
    }

    private func scheduleFollowTimer(interval: TimeInterval) {
        guard followTimer == nil || abs((followTimerInterval ?? 0) - interval) > 0.001 else { return }
        followTimer?.invalidate()
        followTimerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickFollowTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowingAnchor() {
        activeLockedTargetDrag = nil
        followTimer?.invalidate()
        followTimer = nil
        followTimerInterval = nil
        fastFollowUntil = nil
        flushPendingLockedOriginSave()
        uninstallAccessibilityObserver()
    }

    private func tickFollowTimer() {
        guard lockedAnchor != nil else {
            stopFollowingAnchor()
            return
        }
        let moved = followAnchorIfNeeded()
        if moved {
            fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
            scheduleFollowTimer(interval: fastFollowInterval)
            return
        }
        if let fastFollowUntil, Date() < fastFollowUntil {
            scheduleFollowTimer(interval: fastFollowInterval)
        } else {
            scheduleFollowTimer(interval: idleFollowInterval)
        }
    }

    private func installAccessibilityObserverForLockedAnchor() {
        uninstallAccessibilityObserver()
        guard let anchor = lockedAnchor,
              let accessibilityWindow = anchor.accessibilityWindow,
              AXIsProcessTrusted()
        else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(anchor.ownerPID, Self.accessibilityObserverCallback, &observer) == .success,
              let observer
        else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let moved = AXObserverAddNotification(observer, accessibilityWindow, kAXMovedNotification as CFString, refcon)
        let resized = AXObserverAddNotification(observer, accessibilityWindow, kAXResizedNotification as CFString, refcon)
        guard moved == .success || resized == .success else {
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        accessibilityObserver = observer
        observedAccessibilityWindow = accessibilityWindow
    }

    private func uninstallAccessibilityObserver() {
        if let observer = accessibilityObserver, let observedAccessibilityWindow {
            AXObserverRemoveNotification(observer, observedAccessibilityWindow, kAXMovedNotification as CFString)
            AXObserverRemoveNotification(observer, observedAccessibilityWindow, kAXResizedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        accessibilityObserver = nil
        observedAccessibilityWindow = nil
    }

    private func handleAccessibilityWindowEvent() {
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followAnchorIfNeeded()
    }

    @discardableResult
    private func followAnchorIfNeeded() -> Bool {
        guard let panel, let anchor = lockedAnchor else { return false }
        if activeLockedTargetDrag != nil {
            return followLockedTargetDrag(at: NSEvent.mouseLocation)
        }
        guard let targetFrame = targetFrame(matching: anchor) else { return false }
        let origin = NSPoint(
            x: targetFrame.frame.minX + anchor.offset.x,
            y: targetFrame.frame.minY + anchor.offset.y
        )
        let frame = anchoredPanelFrame(for: panel, size: panel.frame.size, topLeft: NSPoint(x: origin.x, y: origin.y + panel.frame.height))
        return movePanelIfNeeded(panel, to: frame.origin, persist: true)
    }

    @discardableResult
    private func movePanelIfNeeded(_ panel: NSPanel, to origin: NSPoint, persist: Bool) -> Bool {
        guard abs(origin.x - panel.frame.origin.x) > 0.5 || abs(origin.y - panel.frame.origin.y) > 0.5 else {
            return false
        }
        isProgrammaticPanelMove = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticPanelMove = false
        }
        if persist {
            saveLockedOrigin(origin, throttled: true)
        }
        return true
    }

    private func findTargetWindow(near panelFrame: NSRect) -> FloatingPanelTargetWindow? {
        if let clickedWindow = targetWindowAtRecentExternalClick() {
            return clickedWindow
        }

        let windows = visibleWindows()
        let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        if let topmostContainingCenter = windows.first(where: { $0.frame.contains(panelCenter) }) {
            return topmostContainingCenter
        }
        if let topmostOverlapping = windows.first(where: { overlapArea($0.frame, panelFrame) > 0 }) {
            return topmostOverlapping
        }
        let nearestWindow = windows.max { lhs, rhs in
            targetDistanceScore(lhs, near: panelFrame) < targetDistanceScore(rhs, near: panelFrame)
        }

        let targetPID = lastExternalActivePID
        return windows.first { window in
            if let targetPID, window.ownerPID == targetPID {
                return true
            }
            return false
        } ?? nearestWindow
    }

    private func targetWindowAtRecentExternalClick() -> FloatingPanelTargetWindow? {
        guard let location = lastExternalClickLocation,
              let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval
        else {
            return nil
        }

        let windows = visibleWindows(relaxed: true)
        if let lastExternalClickWindowNumber,
           let clickedWindow = windows.first(where: { $0.windowNumber == lastExternalClickWindowNumber }) {
            return clickedWindow
        }
        if let lastExternalClickOwnerPID,
           let clickedWindow = windows.first(where: { $0.ownerPID == lastExternalClickOwnerPID && windowContainsClick(location, window: $0) }) {
            return clickedWindow
        }

        return windows.first { window in
            windowContainsClick(location, window: window)
        }
    }

    private func targetAccessibilityWindowAtRecentExternalClick() -> FloatingPanelAccessibilityTarget? {
        guard let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval,
              let lastExternalClickAXWindow,
              let target = accessibilityTarget(from: lastExternalClickAXWindow)
        else {
            return nil
        }
        return target
    }

    private func windowContainsClick(_ location: NSPoint, window: FloatingPanelTargetWindow) -> Bool {
        if window.frame.contains(location) {
            return true
        }

        let quartzLocation = NSPoint(x: location.x, y: FloatingPanelScreenGeometry.displayMaxY - location.y)
        return window.rawFrame.contains(quartzLocation)
    }

    private func targetDistanceScore(_ window: FloatingPanelTargetWindow, near panelFrame: NSRect) -> CGFloat {
        let dx = window.frame.midX - panelFrame.midX
        let dy = window.frame.midY - panelFrame.midY
        return -((dx * dx) + (dy * dy))
    }

    private func targetWindow(_ window: FloatingPanelTargetWindow, matches anchor: FloatingPanelWindowAnchor) -> Bool {
        if let windowNumber = anchor.windowNumber {
            return window.windowNumber == windowNumber
        }
        guard window.ownerPID == anchor.ownerPID else { return false }
        if !anchor.windowTitle.isEmpty {
            return window.title == anchor.windowTitle
        }
        if let bundleID = anchor.ownerBundleID {
            return window.ownerBundleID == bundleID
        }
        return true
    }

    private func accessibilityTarget(_ target: FloatingPanelAccessibilityTarget, matches anchor: FloatingPanelWindowAnchor) -> Bool {
        guard target.ownerPID == anchor.ownerPID else { return false }
        if !anchor.windowTitle.isEmpty {
            return target.title == anchor.windowTitle
        }
        if let bundleID = anchor.ownerBundleID {
            return target.ownerBundleID == bundleID
        }
        return true
    }

    private func overlapArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func visibleScreenFrame(for rect: NSRect, fallback panel: NSPanel) -> NSRect? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen.visibleFrame
        }

        let overlappingScreen = NSScreen.screens.max { lhs, rhs in
            overlapArea(lhs.frame, rect) < overlapArea(rhs.frame, rect)
        }
        return overlappingScreen?.visibleFrame ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func targetFrame(matching anchor: FloatingPanelWindowAnchor) -> FloatingPanelFollowTarget? {
        if let accessibilityWindow = anchor.accessibilityWindow,
           AXIsProcessTrusted() {
            var ownerPID: pid_t = 0
            if AXUIElementGetPid(accessibilityWindow, &ownerPID) == .success,
               ownerPID == anchor.ownerPID,
               let frame = accessibilityFrame(of: accessibilityWindow) {
                return FloatingPanelFollowTarget(frame: frame, targetDescription: anchor.targetDescription)
            }
        }
        if let targetWindow = findWindow(matching: anchor) {
            return FloatingPanelFollowTarget(frame: targetWindow.frame, targetDescription: targetWindow.displayName)
        }
        return nil
    }

    private func findWindow(matching anchor: FloatingPanelWindowAnchor) -> FloatingPanelTargetWindow? {
        if let windowNumber = anchor.windowNumber,
           let byNumber = windowDescription(for: windowNumber, relaxed: true) {
            return byNumber
        }

        let windows = visibleWindows(relaxed: true)
        if let windowNumber = anchor.windowNumber,
           let byNumber = windows.first(where: { $0.windowNumber == windowNumber }) {
            return byNumber
        }
        if let byPID = windows.first(where: { $0.ownerPID == anchor.ownerPID && $0.title == anchor.windowTitle }) {
            return byPID
        }
        if let bundleID = anchor.ownerBundleID,
           let byBundle = windows.first(where: { $0.ownerBundleID == bundleID && $0.title == anchor.windowTitle }) {
            return byBundle
        }
        if let bundleID = anchor.ownerBundleID,
           let byBundle = windows.first(where: { $0.ownerBundleID == bundleID }) {
            return byBundle
        }
        return windows.first(where: { $0.ownerPID == anchor.ownerPID })
    }

    private func refreshLockedAnchorOffsetForCurrentFrame() {
        guard let panel, let anchor = lockedAnchor, let targetFrame = targetFrame(matching: anchor) else {
            return
        }
        lockedAnchor = FloatingPanelWindowAnchor(
            windowNumber: anchor.windowNumber,
            ownerPID: anchor.ownerPID,
            ownerBundleID: anchor.ownerBundleID,
            windowTitle: anchor.windowTitle,
            targetDescription: anchor.targetDescription,
            offset: NSPoint(
                x: panel.frame.minX - targetFrame.frame.minX,
                y: panel.frame.minY - targetFrame.frame.minY
            ),
            accessibilityWindow: anchor.accessibilityWindow
        )
        lockTargetDescription = anchor.targetDescription
        refreshFloatingPanelLockStatus()
    }

    private func refreshFloatingPanelLockStatus() {
        if let lockTargetDescription, !lockTargetDescription.isEmpty {
            UserDefaults.standard.set(lockTargetDescription, forKey: lockTargetDescriptionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lockTargetDescriptionKey)
        }
        guard let hostingController = panel?.contentViewController as? NSHostingController<FloatingTokenPanelView> else {
            return
        }
        hostingController.rootView = hostingController.rootView.withLockTarget(lockTargetDescription)
    }

    private func visibleWindows(relaxed: Bool = false) -> [FloatingPanelTargetWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return rawWindows.compactMap { targetWindow(from: $0, relaxed: relaxed) }
    }

    private func windowDescription(for windowNumber: Int, relaxed: Bool) -> FloatingPanelTargetWindow? {
        let windowIDs = [CGWindowID(windowNumber)] as CFArray
        guard let rawWindows = CGWindowListCreateDescriptionFromArray(windowIDs) as? [[String: Any]] else {
            return nil
        }
        return rawWindows.compactMap { targetWindow(from: $0, relaxed: relaxed) }.first
    }

    private func targetWindow(from info: [String: Any], relaxed: Bool) -> FloatingPanelTargetWindow? {
        let minimumWidth: CGFloat = relaxed ? 20 : 60
        let minimumHeight: CGFloat = relaxed ? 16 : 40
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID != currentPID,
              let windowNumber = info[kCGWindowNumber as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat,
              width > minimumWidth,
              height > minimumHeight
        else {
            return nil
        }

        let displayMaxY = FloatingPanelScreenGeometry.displayMaxY
        let app = NSRunningApplication(processIdentifier: ownerPID)
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        guard isLockCandidateWindow(layer: layer, ownerName: ownerName, bundleID: app?.bundleIdentifier, relaxed: relaxed) else {
            return nil
        }
        let title = info[kCGWindowName as String] as? String ?? ""
        let frame = NSRect(x: x, y: displayMaxY - y - height, width: width, height: height)
        let rawFrame = NSRect(x: x, y: y, width: width, height: height)
        return FloatingPanelTargetWindow(
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            ownerBundleID: app?.bundleIdentifier,
            ownerName: ownerName,
            title: title,
            frame: frame,
            rawFrame: rawFrame
        )
    }

    private func isLockCandidateWindow(layer: Int, ownerName: String, bundleID: String?, relaxed: Bool) -> Bool {
        let maximumLayer = relaxed ? 2_000 : 25
        guard layer >= 0, layer <= maximumLayer else {
            return false
        }
        return !isBlockedWindowOwner(ownerName: ownerName, bundleID: bundleID)
    }

    private func isBlockedWindowOwner(ownerName: String, bundleID: String?) -> Bool {
        let blockedBundles: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.loginwindow",
            "com.apple.notificationcenterui",
            "com.apple.screencaptureui",
            "com.apple.Spotlight",
            "com.apple.systemuiserver",
            "com.surteesstudios.Bartender"
        ]
        if let bundleID, blockedBundles.contains(bundleID) {
            return true
        }
        let blockedNames: Set<String> = [
            "Dock",
            "Control Center",
            "Screenshot",
            "Spotlight",
            "SystemUIServer",
            "Window Server",
            "Menubar",
            "截屏",
            "程序坞"
        ]
        return blockedNames.contains(ownerName)
    }

    private func accessibilityTarget(at location: NSPoint) -> FloatingPanelAccessibilityTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let quartzLocation = NSPoint(x: location.x, y: FloatingPanelScreenGeometry.displayMaxY - location.y)
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(quartzLocation.x),
            Float(quartzLocation.y),
            &element
        ) == .success,
              let element,
              let window = accessibilityWindow(from: element)
        else {
            return nil
        }
        return accessibilityTarget(from: window)
    }

    private func accessibilityTarget(matching window: FloatingPanelTargetWindow) -> FloatingPanelAccessibilityTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }

        let candidates = windows.compactMap { accessibilityTarget(from: $0) }
            .filter { $0.ownerPID == window.ownerPID }
        let scored = candidates.map { target -> (FloatingPanelAccessibilityTarget, CGFloat) in
            let frameDelta = abs(target.frame.minX - window.frame.minX)
                + abs(target.frame.minY - window.frame.minY)
                + abs(target.frame.width - window.frame.width)
                + abs(target.frame.height - window.frame.height)
            let titleBonus: CGFloat = (!window.title.isEmpty && target.title == window.title) ? 2_000 : 0
            return (target, titleBonus - frameDelta)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let titleMatches = !window.title.isEmpty && best.0.title == window.title
        let frameLooksClose = best.1 > -90
        return titleMatches || frameLooksClose ? best.0 : nil
    }

    private func accessibilityTarget(from window: AXUIElement) -> FloatingPanelAccessibilityTarget? {
        guard AXIsProcessTrusted() else { return nil }
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(window, &ownerPID) == .success,
              ownerPID != ProcessInfo.processInfo.processIdentifier,
              let frame = accessibilityFrame(of: window)
        else {
            return nil
        }
        let app = NSRunningApplication(processIdentifier: ownerPID)
        let ownerName = app?.localizedName ?? ""
        guard !isBlockedWindowOwner(ownerName: ownerName, bundleID: app?.bundleIdentifier) else {
            return nil
        }
        let title = accessibilityStringAttribute(window, kAXTitleAttribute as CFString) ?? ""
        return FloatingPanelAccessibilityTarget(
            window: window,
            ownerPID: ownerPID,
            ownerBundleID: app?.bundleIdentifier,
            ownerName: ownerName,
            title: title,
            frame: frame
        )
    }

    private func accessibilityWindow(from element: AXUIElement) -> AXUIElement? {
        if accessibilityStringAttribute(element, kAXRoleAttribute as CFString) == (kAXWindowRole as String) {
            return element
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func accessibilityFrame(of window: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var topLeft = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &topLeft),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              size.width > 1,
              size.height > 1
        else {
            return nil
        }
        return NSRect(
            x: topLeft.x,
            y: FloatingPanelScreenGeometry.displayMaxY - topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func accessibilityStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func saveLockedOrigin(_ origin: NSPoint, throttled: Bool = false) {
        guard throttled else {
            persistLockedOrigin(origin)
            return
        }

        pendingLockedOriginToPersist = origin
        let elapsed = Date().timeIntervalSince(lastLockedOriginPersistAt)
        if elapsed >= lockedOriginPersistInterval {
            flushPendingLockedOriginSave()
            return
        }

        guard lockedOriginPersistTimer == nil else { return }
        let timer = Timer(timeInterval: max(0.05, lockedOriginPersistInterval - elapsed), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingLockedOriginSave()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockedOriginPersistTimer = timer
    }

    private func flushPendingLockedOriginSave() {
        lockedOriginPersistTimer?.invalidate()
        lockedOriginPersistTimer = nil
        guard let origin = pendingLockedOriginToPersist else { return }
        pendingLockedOriginToPersist = nil
        persistLockedOrigin(origin)
    }

    private func persistLockedOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: lockedOriginXKey)
        defaults.set(Double(origin.y), forKey: lockedOriginYKey)
        lastLockedOriginPersistAt = Date()
    }

    private func savedLockedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lockedOriginXKey) != nil,
              defaults.object(forKey: lockedOriginYKey) != nil else {
            return nil
        }
        return NSPoint(x: defaults.double(forKey: lockedOriginXKey), y: defaults.double(forKey: lockedOriginYKey))
    }
}

struct FloatingTokenPanelView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var taskCompletionMonitor: TaskCompletionMonitor
    let isLocked: Bool
    var lockTargetDescription: String?
    let onToggleLock: () -> Void
    @AppStorage("floatingPanelOpacity") private var floatingPanelOpacity = 0.88
    @AppStorage("floatingPanelScale") private var floatingPanelScale = FloatingTokenPanelMetrics.defaultScale
    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingPanelAppearance.unreadEffectKey) private var floatingPanelUnreadEffect = FloatingPanelAppearance.defaultUnreadEffect
    @AppStorage(FloatingPanelAppearance.unreadPreviewUntilKey) private var floatingPanelUnreadPreviewUntil = 0.0
    let onClose: () -> Void

    var body: some View {
        let unreadCount = taskCompletionMonitor.unreadThreadCount
        let unreadEffect = FloatingPanelUnreadEffect(rawValue: floatingPanelUnreadEffect) ?? .ripple
        let isPreviewingUnreadEffect = unreadCount == 0
            && unreadEffect != .off
            && floatingPanelUnreadPreviewUntil > Date.timeIntervalSinceReferenceDate
        let shouldShowUnreadEffect = unreadEffect != .off && (unreadCount > 0 || isPreviewingUnreadEffect)
        let scale = FloatingTokenPanelMetrics.clampedScale(floatingPanelScale)
        let size = FloatingTokenPanelMetrics.size(scale: floatingPanelScale)
        let cornerRadius = FloatingTokenPanelMetrics.cornerRadius(scale: floatingPanelScale)
        let appearance = FloatingPanelAppearance(
            startHex: floatingPanelGradientStartHex,
            endHex: floatingPanelGradientEndHex,
            directionRaw: floatingPanelGradientDirection,
            styleRaw: floatingPanelGradientStyle
        )

        return ZStack {
            TokenGlassBackground(
                opacity: floatingPanelOpacity,
                cornerRadius: cornerRadius,
                appearance: appearance
            )
            if shouldShowUnreadEffect {
                FloatingUnreadEffectOverlay(
                    effect: unreadEffect,
                    color: appearance.unreadIndicatorColor,
                    cornerRadius: cornerRadius,
                    scale: scale
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            TokenDisplayCard(
                snapshot: TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota),
                onClose: nil,
                lockState: nil,
                lockTargetDescription: nil,
                onToggleLock: nil
            )
                .environment(\.tokenDisplayScale, scale)
                .padding(.horizontal, FloatingTokenPanelMetrics.horizontalPadding * scale)
                .padding(.vertical, FloatingTokenPanelMetrics.verticalPadding * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .zIndex(2)

            FloatingPanelLockButton(
                state: isLocked ? .locked : .unlocked,
                targetDescription: lockTargetDescription,
                scale: scale,
                action: onToggleLock
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(4)

            FloatingPanelCloseButton(
                scale: scale,
                action: onClose
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(4)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: unreadCount > 0)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func withLockTarget(_ description: String?) -> FloatingTokenPanelView {
        var copy = self
        copy.lockTargetDescription = description
        return copy
    }
}

private struct FloatingUnreadEffectOverlay: View {
    let effect: FloatingPanelUnreadEffect
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    var body: some View {
        switch effect {
        case .off:
            EmptyView()
        case .ripple:
            FloatingUnreadRippleOverlay(color: color, cornerRadius: cornerRadius, scale: scale)
        case .shimmer:
            FloatingUnreadShimmerOverlay(color: color, cornerRadius: cornerRadius, scale: scale)
        }
    }
}

private struct FloatingUnreadShimmerOverlay: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    func makeNSView(context: Context) -> FloatingUnreadShimmerView {
        let view = FloatingUnreadShimmerView()
        view.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
        return view
    }

    func updateNSView(_ nsView: FloatingUnreadShimmerView, context: Context) {
        nsView.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
    }

    private var nsColor: NSColor {
        FloatingPanelColorTools.deviceRGB(NSColor(color))
    }
}

private final class FloatingUnreadShimmerView: NSView {
    private struct RenderRequest {
        let size: CGSize
        let backingScale: CGFloat
        let color: NSColor
        let cornerRadius: CGFloat
        let scale: CGFloat
    }

    private static let animationKey = "floatingUnreadShimmerFrames"

    private let imageLayer = CALayer()
    private var cachedFrames: [CGImage] = []
    private var pendingRenderWorkItem: DispatchWorkItem?
    private var renderGeneration: UInt64 = 0
    private var animationStartLayerTime: CFTimeInterval?
    private var currentColor = NSColor.systemBlue
    private var currentCornerRadius: CGFloat = 14
    private var currentScale: CGFloat = 1
    private var lastBounds: CGRect = .zero
    private var lastBackingScale: CGFloat = 0
    private let cycleDuration: CFTimeInterval = 2.1
    private let targetFramesPerSecond = 30
    private let resizeRenderDebounce: TimeInterval = 0.14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRootLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRootLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
        } else {
            updateLayoutIfNeeded(force: true)
            startAnimations()
        }
    }

    override func layout() {
        super.layout()
        updateLayoutIfNeeded(force: false)
    }

    func configure(color: NSColor, cornerRadius: CGFloat, scale: CGFloat) {
        let nextColor = FloatingPanelColorTools.deviceRGB(color)
        let nextScale = max(scale, 0.1)
        let needsLayout = !sameColor(nextColor, currentColor)
            || abs(currentScale - nextScale) > 0.001
            || abs(currentCornerRadius - cornerRadius) > 0.001
        currentColor = nextColor
        currentCornerRadius = cornerRadius
        currentScale = nextScale
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        updateLayoutIfNeeded(force: needsLayout)
    }

    private func setupRootLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    private func updateLayoutIfNeeded(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let rawBackingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let backingScale = min(max(rawBackingScale, 1), 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = currentCornerRadius
        layer?.cornerCurve = .continuous
        imageLayer.frame = bounds
        imageLayer.contentsScale = backingScale
        CATransaction.commit()

        guard isReasonableRenderableSize(bounds.size) else {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
            return
        }

        guard force || bounds != lastBounds || abs(backingScale - lastBackingScale) > 0.01 else {
            return
        }

        let request = RenderRequest(
            size: bounds.size,
            backingScale: backingScale,
            color: currentColor,
            cornerRadius: currentCornerRadius,
            scale: currentScale
        )
        requestFrameRender(request, immediate: cachedFrames.isEmpty)
    }

    private func isReasonableRenderableSize(_ size: CGSize) -> Bool {
        let maxSize = FloatingTokenPanelMetrics.size(scale: FloatingTokenPanelMetrics.scaleRange.upperBound)
        return size.width <= maxSize.width + 32
            && size.height <= maxSize.height + 32
    }

    private func requestFrameRender(_ request: RenderRequest, immediate: Bool) {
        renderGeneration &+= 1
        let generation = renderGeneration
        cancelPendingRender(advanceGeneration: false)
        let cycleDuration = cycleDuration
        let targetFramesPerSecond = targetFramesPerSecond

        if immediate {
            let frames = Self.renderFrames(
                request: request,
                cycleDuration: cycleDuration,
                targetFramesPerSecond: targetFramesPerSecond
            )
            applyRenderedFrames(frames, request: request, generation: generation)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let frames = Self.renderFrames(
                request: request,
                cycleDuration: cycleDuration,
                targetFramesPerSecond: targetFramesPerSecond
            )
            self.applyRenderedFrames(frames, request: request, generation: generation)
        }
        pendingRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeRenderDebounce, execute: workItem)
    }

    private func applyRenderedFrames(_ frames: [CGImage], request: RenderRequest, generation: UInt64) {
        guard generation == renderGeneration, window != nil, !frames.isEmpty else { return }
        let phaseOffset = currentAnimationPhaseOffset()
        stopAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastBounds = CGRect(origin: .zero, size: request.size)
        lastBackingScale = request.backingScale
        imageLayer.frame = CGRect(origin: .zero, size: request.size)
        imageLayer.contentsScale = request.backingScale
        cachedFrames = frames
        imageLayer.contents = frames.first
        CATransaction.commit()
        startAnimations(phaseOffset: phaseOffset)
    }

    private static nonisolated func renderFrames(
        request: RenderRequest,
        cycleDuration: CFTimeInterval,
        targetFramesPerSecond: Int
    ) -> [CGImage] {
        let pixelWidth = max(1, Int((request.size.width * request.backingScale).rounded(.up)))
        let pixelHeight = max(1, Int((request.size.height * request.backingScale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let frameCount = max(1, Int((cycleDuration * Double(targetFramesPerSecond)).rounded(.up)))

        return (0..<frameCount).compactMap { index in
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.scaleBy(x: request.backingScale, y: request.backingScale)
            Self.drawShimmerFrame(in: context, request: request, phase: Double(index) / Double(frameCount))
            return context.makeImage()
        }
    }

    private static nonisolated func drawShimmerFrame(in context: CGContext, request: RenderRequest, phase: Double) {
        let size = request.size
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: request.cornerRadius,
            cornerHeight: request.cornerRadius,
            transform: nil
        ))
        context.clip()

        let pulse = (sin(phase * .pi * 4) + 1) / 2
        context.setFillColor(request.color.withAlphaComponent(0.026 + 0.020 * pulse).cgColor)
        context.fill(rect)
        context.setBlendMode(.screen)

        let bandWidth = max(size.width * 0.62, 76 * request.scale)
        let bandHeight = size.height * 2.0
        let fromX = -bandWidth * 0.8
        let toX = size.width + bandWidth * 1.15
        let centerX = fromX + (toX - fromX) * CGFloat(phase)
        let centerY = size.height / 2

        Self.drawSweepBand(
            in: context,
            center: CGPoint(x: centerX, y: centerY),
            width: bandWidth,
            height: bandHeight,
            angle: -0.20,
            colors: [
                NSColor.clear,
                request.color.withAlphaComponent(0.28),
                NSColor.white.withAlphaComponent(0.46),
                request.color.withAlphaComponent(0.22),
                NSColor.clear
            ],
            locations: [0.0, 0.30, 0.50, 0.70, 1.0]
        )

        Self.drawSweepBand(
            in: context,
            center: CGPoint(x: centerX + bandWidth * 0.18, y: centerY),
            width: max(12 * request.scale, bandWidth * 0.16),
            height: bandHeight,
            angle: -0.20,
            colors: [
                NSColor.clear,
                NSColor.white.withAlphaComponent(0.00),
                NSColor.white.withAlphaComponent(0.28),
                NSColor.clear
            ],
            locations: [0.0, 0.45, 0.55, 1.0]
        )
        context.restoreGState()
    }

    private static nonisolated func drawSweepBand(
        in context: CGContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat,
        angle: CGFloat,
        colors: [NSColor],
        locations: [CGFloat]
    ) {
        let cgColors = colors.map { $0.cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: locations) else {
            return
        }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.midY),
            end: CGPoint(x: rect.maxX, y: rect.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private func startAnimations(phaseOffset: CFTimeInterval = 0) {
        guard window != nil, cachedFrames.count > 1 else { return }
        guard imageLayer.animation(forKey: Self.animationKey) == nil else { return }
        let loopFrames = cachedFrames + [cachedFrames[0]]
        let lastIndex = max(loopFrames.count - 1, 1)
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let offset = min(max(phaseOffset, 0), cycleDuration)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = loopFrames
        animation.keyTimes = (0..<loopFrames.count).map { NSNumber(value: Double($0) / Double(lastIndex)) }
        animation.duration = cycleDuration
        animation.beginTime = layerTime - offset
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animationStartLayerTime = layerTime - offset
        imageLayer.add(animation, forKey: Self.animationKey)
    }

    private func stopAnimations() {
        imageLayer.removeAnimation(forKey: Self.animationKey)
        animationStartLayerTime = nil
    }

    private func currentAnimationPhaseOffset() -> CFTimeInterval {
        guard let animationStartLayerTime else { return 0 }
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let elapsed = max(0, layerTime - animationStartLayerTime)
        return elapsed.truncatingRemainder(dividingBy: cycleDuration)
    }

    private func clearFrameCache() {
        cachedFrames.removeAll()
        imageLayer.contents = nil
        lastBounds = .zero
        lastBackingScale = 0
    }

    private func cancelPendingRender(advanceGeneration: Bool = true) {
        if advanceGeneration {
            renderGeneration &+= 1
        }
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhs = FloatingPanelColorTools.deviceRGB(lhs)
        let rhs = FloatingPanelColorTools.deviceRGB(rhs)
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }
}

private struct FloatingUnreadRippleOverlay: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let scale: CGFloat

    func makeNSView(context: Context) -> FloatingUnreadSpriteRippleView {
        let view = FloatingUnreadSpriteRippleView()
        view.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
        return view
    }

    func updateNSView(_ nsView: FloatingUnreadSpriteRippleView, context: Context) {
        nsView.configure(color: nsColor, cornerRadius: cornerRadius, scale: scale)
    }

    private var nsColor: NSColor {
        FloatingPanelColorTools.deviceRGB(NSColor(color))
    }
}

private final class FloatingUnreadLayerRippleView: NSView {
    private enum RippleSourceKind: CaseIterable {
        case center
        case top
        case bottom
        case topSecond
        case bottomSecond
        case left
        case right

        var strength: CGFloat {
            switch self {
            case .center:
                return 1.00
            case .top, .bottom:
                return 0.82
            case .topSecond, .bottomSecond:
                return 0.50
            case .left, .right:
                return 0.58
            }
        }

        func point(in bounds: CGRect) -> CGPoint {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            switch self {
            case .center:
                return center
            case .top:
                return CGPoint(x: center.x, y: -center.y)
            case .bottom:
                return CGPoint(x: center.x, y: bounds.height + (bounds.height - center.y))
            case .topSecond:
                return CGPoint(x: center.x, y: center.y - 2 * bounds.height)
            case .bottomSecond:
                return CGPoint(x: center.x, y: center.y + 2 * bounds.height)
            case .left:
                return CGPoint(x: -center.x, y: center.y)
            case .right:
                return CGPoint(x: bounds.width + (bounds.width - center.x), y: center.y)
            }
        }
    }

    private enum EdgeGlowKind: CaseIterable {
        case top
        case bottom
        case left
        case right
        case topSecond
        case bottomSecond

        var peakOpacity: Float {
            switch self {
            case .top, .bottom:
                return 0.42
            case .left, .right:
                return 0.30
            case .topSecond, .bottomSecond:
                return 0.24
            }
        }

        var isSecondary: Bool {
            switch self {
            case .topSecond, .bottomSecond:
                return true
            case .top, .bottom, .left, .right:
                return false
            }
        }

        func arrivalDistance(in bounds: CGRect) -> CGFloat {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            switch self {
            case .top:
                return center.y
            case .bottom:
                return bounds.height - center.y
            case .left:
                return center.x
            case .right:
                return bounds.width - center.x
            case .topSecond:
                return 2 * bounds.height - center.y
            case .bottomSecond:
                return bounds.height + center.y
            }
        }

        func frame(in bounds: CGRect, scale: CGFloat) -> CGRect {
            let primaryThickness = max(1.3, 2.35 * scale)
            let secondaryThickness = max(1.1, 2.05 * scale)
            let sideThickness = max(1.2, 2.2 * scale)
            switch self {
            case .top:
                return CGRect(x: 0, y: 0, width: bounds.width, height: primaryThickness)
            case .bottom:
                return CGRect(x: 0, y: bounds.height - primaryThickness, width: bounds.width, height: primaryThickness)
            case .left:
                return CGRect(x: 0, y: 0, width: sideThickness, height: bounds.height)
            case .right:
                return CGRect(x: bounds.width - sideThickness, y: 0, width: sideThickness, height: bounds.height)
            case .topSecond:
                return CGRect(x: 0, y: 0, width: bounds.width, height: secondaryThickness)
            case .bottomSecond:
                return CGRect(x: 0, y: bounds.height - secondaryThickness, width: bounds.width, height: secondaryThickness)
            }
        }
    }

    private struct RippleLayer {
        let source: RippleSourceKind
        let ringIndex: Int
        let layer: CAShapeLayer
    }

    private struct EdgeGlowLayer {
        let kind: EdgeGlowKind
        let layer: CALayer
    }

    private let tintLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private var rippleLayers: [RippleLayer] = []
    private var edgeGlowLayers: [EdgeGlowLayer] = []
    private var currentColor = NSColor.systemBlue
    private var currentCornerRadius: CGFloat = 14
    private var currentScale: CGFloat = 1
    private var lastBounds: CGRect = .zero
    private var currentMaxRadius: CGFloat = 1
    private let cycleDuration: CFTimeInterval = 3.25

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRootLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRootLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimations()
        } else {
            updateLayoutIfNeeded(force: true)
            startAnimations()
        }
    }

    override func layout() {
        super.layout()
        updateLayoutIfNeeded(force: false)
    }

    func configure(color: NSColor, cornerRadius: CGFloat, scale: CGFloat) {
        currentColor = FloatingPanelColorTools.deviceRGB(color)
        currentCornerRadius = cornerRadius
        currentScale = max(scale, 0.1)
        updateColors()
        updateLayoutIfNeeded(force: true)
    }

    private func setupRootLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.addSublayer(tintLayer)
        layer?.addSublayer(borderLayer)

        rippleLayers = RippleSourceKind.allCases.flatMap { source in
            (0..<5).map { ringIndex in
                let ring = CAShapeLayer()
                ring.fillColor = NSColor.clear.cgColor
                ring.lineJoin = .round
                ring.lineCap = .round
                ring.opacity = 0
                layer?.addSublayer(ring)
                return RippleLayer(source: source, ringIndex: ringIndex, layer: ring)
            }
        }

        edgeGlowLayers = EdgeGlowKind.allCases.map { kind in
            let glow = CALayer()
            glow.opacity = 0
            glow.cornerRadius = 1.4
            glow.cornerCurve = .continuous
            layer?.addSublayer(glow)
            return EdgeGlowLayer(kind: kind, layer: glow)
        }
        updateColors()
    }

    private func updateColors() {
        tintLayer.backgroundColor = currentColor.withAlphaComponent(0.045).cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        borderLayer.fillColor = NSColor.clear.cgColor
        for ripple in rippleLayers {
            let alpha = max(0.11, 0.50 - CGFloat(ripple.ringIndex) * 0.065) * ripple.source.strength
            ripple.layer.strokeColor = currentColor.withAlphaComponent(alpha).cgColor
            ripple.layer.lineWidth = max(0.82, (2.35 - CGFloat(ripple.ringIndex) * 0.19) * currentScale)
        }
        for edge in edgeGlowLayers {
            let alpha: CGFloat = edge.kind.isSecondary ? 0.24 : 0.30
            edge.layer.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
    }

    private func updateLayoutIfNeeded(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard force || bounds != lastBounds else { return }
        lastBounds = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = currentCornerRadius
        tintLayer.frame = bounds
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.2 * currentScale, dy: 1.2 * currentScale),
            cornerWidth: max(1, currentCornerRadius - 1.2 * currentScale),
            cornerHeight: max(1, currentCornerRadius - 1.2 * currentScale),
            transform: nil
        )
        borderLayer.lineWidth = max(0.5, 0.75 * currentScale)

        let maxRadius = max(max(bounds.width, bounds.height) * 0.82, bounds.height * 2.25)
        currentMaxRadius = max(maxRadius, 1)
        let diameter = maxRadius * 2
        let ringBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let path = CGPath(ellipseIn: ringBounds, transform: nil)
        for ripple in rippleLayers {
            ripple.layer.bounds = ringBounds
            ripple.layer.position = ripple.source.point(in: bounds)
            ripple.layer.path = path
            ripple.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        for edge in edgeGlowLayers {
            edge.layer.frame = edge.kind.frame(in: bounds, scale: currentScale)
            edge.layer.cornerRadius = 1.4 * currentScale
        }
        CATransaction.commit()
        startAnimations()
    }

    private func startAnimations() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        startTintAnimation()
        startBorderAnimation()
        for ripple in rippleLayers {
            startRippleAnimation(ripple)
        }
        for edge in edgeGlowLayers {
            startEdgeAnimation(edge)
        }
    }

    private func startTintAnimation() {
        guard tintLayer.animation(forKey: "floatingUnreadTintPulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.16
        pulse.toValue = 0.34
        pulse.duration = 1.35
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tintLayer.add(pulse, forKey: "floatingUnreadTintPulse")
    }

    private func startBorderAnimation() {
        guard borderLayer.animation(forKey: "floatingUnreadBorderPulse") == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0.28, 0.18, 0, 0]
        pulse.keyTimes = [0, 0.26, 0.45, 0.70, 1]
        pulse.duration = cycleDuration
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        borderLayer.add(pulse, forKey: "floatingUnreadBorderPulse")
    }

    private func startRippleAnimation(_ ripple: RippleLayer) {
        guard ripple.layer.animation(forKey: "floatingUnreadRipple") == nil else { return }
        let delay = Double(ripple.ringIndex) * 0.15
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.02, 0.34, 0.76, 1.0, 1.0]
        scale.keyTimes = [0, 0.18, 0.62, 0.86, 1]
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        let peak = max(0.08, (0.48 - CGFloat(ripple.ringIndex) * 0.060) * ripple.source.strength)
        opacity.values = [0, peak, peak * 0.75, 0, 0]
        opacity.keyTimes = [0, 0.10, 0.58, 0.86, 1]
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = cycleDuration
        group.beginTime = CACurrentMediaTime() + delay
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.fillMode = .both
        ripple.layer.add(group, forKey: "floatingUnreadRipple")
    }

    private func startEdgeAnimation(_ edge: EdgeGlowLayer) {
        guard edge.layer.animation(forKey: "floatingUnreadEdgeGlow") == nil else { return }
        let distance = edge.kind.arrivalDistance(in: bounds)
        let phase = phaseForRadiusFraction(distance / currentMaxRadius)
        let spread: CGFloat = edge.kind.isSecondary ? 0.070 : 0.052
        let times = edgeKeyTimes(around: phase, spread: spread)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0, edge.kind.peakOpacity, 0, 0]
        pulse.keyTimes = times.map { NSNumber(value: Double($0)) }
        pulse.duration = cycleDuration
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        edge.layer.add(pulse, forKey: "floatingUnreadEdgeGlow")
    }

    private func stopAnimations() {
        tintLayer.removeAnimation(forKey: "floatingUnreadTintPulse")
        borderLayer.removeAnimation(forKey: "floatingUnreadBorderPulse")
        rippleLayers.forEach { $0.layer.removeAnimation(forKey: "floatingUnreadRipple") }
        edgeGlowLayers.forEach { $0.layer.removeAnimation(forKey: "floatingUnreadEdgeGlow") }
    }

    private func phaseForRadiusFraction(_ fraction: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0.02), 1.0)
        let points: [(time: CGFloat, radius: CGFloat)] = [
            (0.00, 0.02),
            (0.18, 0.34),
            (0.62, 0.76),
            (0.86, 1.00),
            (1.00, 1.00)
        ]
        for index in 1..<points.count {
            let previous = points[index - 1]
            let next = points[index]
            guard clamped <= next.radius || index == points.count - 1 else { continue }
            let span = max(next.radius - previous.radius, 0.001)
            let progress = (clamped - previous.radius) / span
            return previous.time + (next.time - previous.time) * min(max(progress, 0), 1)
        }
        return 0.86
    }

    private func edgeKeyTimes(around phase: CGFloat, spread: CGFloat) -> [CGFloat] {
        let start = max(0.001, phase - spread)
        let peak = min(max(phase, start + 0.001), 0.998)
        let end = min(0.999, max(peak + 0.001, phase + spread))
        return [0, start, peak, end, 1]
    }
}

private final class FloatingUnreadSpriteRippleView: NSView {
    private struct RippleSource {
        let point: CGPoint
        let arrivalDistance: CGFloat
        let strength: CGFloat
        let isDirect: Bool
    }

    private struct RenderRequest {
        let size: CGSize
        let backingScale: CGFloat
        let color: NSColor
        let cornerRadius: CGFloat
        let scale: CGFloat
    }

    private static let animationKey = "floatingUnreadRippleFrames"

    private let imageLayer = CALayer()
    private var cachedFrames: [CGImage] = []
    private var pendingRenderWorkItem: DispatchWorkItem?
    private var renderGeneration: UInt64 = 0
    private var animationStartLayerTime: CFTimeInterval?
    private var currentColor = NSColor.systemBlue
    private var currentCornerRadius: CGFloat = 14
    private var currentScale: CGFloat = 1
    private var lastBounds: CGRect = .zero
    private var lastBackingScale: CGFloat = 0
    private let cycleDuration: CFTimeInterval = 3.25
    private let activeFraction = 0.92
    private let targetFramesPerSecond = 30
    private let resizeRenderDebounce: TimeInterval = 0.14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupRootLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupRootLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
        } else {
            updateLayoutIfNeeded(force: true)
            startAnimations()
        }
    }

    override func layout() {
        super.layout()
        updateLayoutIfNeeded(force: false)
    }

    func configure(color: NSColor, cornerRadius: CGFloat, scale: CGFloat) {
        let nextColor = FloatingPanelColorTools.deviceRGB(color)
        let nextScale = max(scale, 0.1)
        let needsLayout = !sameColor(nextColor, currentColor)
            || abs(currentScale - nextScale) > 0.001
            || abs(currentCornerRadius - cornerRadius) > 0.001
        currentColor = nextColor
        currentCornerRadius = cornerRadius
        currentScale = nextScale
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        updateLayoutIfNeeded(force: needsLayout)
    }

    private func setupRootLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    private func updateLayoutIfNeeded(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let rawBackingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let backingScale = min(max(rawBackingScale, 1), 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = currentCornerRadius
        layer?.cornerCurve = .continuous
        imageLayer.frame = bounds
        imageLayer.contentsScale = backingScale
        CATransaction.commit()

        guard isReasonableRenderableSize(bounds.size) else {
            cancelPendingRender()
            stopAnimations()
            clearFrameCache()
            return
        }
        guard force || bounds != lastBounds || abs(backingScale - lastBackingScale) > 0.01 else {
            return
        }

        let request = RenderRequest(
            size: bounds.size,
            backingScale: backingScale,
            color: currentColor,
            cornerRadius: currentCornerRadius,
            scale: currentScale
        )
        requestFrameRender(request, immediate: cachedFrames.isEmpty)
    }

    private func isReasonableRenderableSize(_ size: CGSize) -> Bool {
        let maxSize = FloatingTokenPanelMetrics.size(scale: FloatingTokenPanelMetrics.scaleRange.upperBound)
        return size.width <= maxSize.width + 32
            && size.height <= maxSize.height + 32
    }

    private func requestFrameRender(_ request: RenderRequest, immediate: Bool) {
        renderGeneration &+= 1
        let generation = renderGeneration
        cancelPendingRender(advanceGeneration: false)
        let cycleDuration = cycleDuration
        let activeFraction = activeFraction
        let targetFramesPerSecond = targetFramesPerSecond

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let frames = Self.renderFrames(
                request: request,
                cycleDuration: cycleDuration,
                activeFraction: activeFraction,
                targetFramesPerSecond: targetFramesPerSecond
            )
            self.applyRenderedFrames(frames, request: request, generation: generation)
        }
        pendingRenderWorkItem = workItem
        if immediate {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + resizeRenderDebounce, execute: workItem)
        }
    }

    private func applyRenderedFrames(_ frames: [CGImage], request: RenderRequest, generation: UInt64) {
        guard generation == renderGeneration, window != nil, !frames.isEmpty else { return }
        let phaseOffset = currentAnimationPhaseOffset()
        stopAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastBounds = CGRect(origin: .zero, size: request.size)
        lastBackingScale = request.backingScale
        imageLayer.frame = CGRect(origin: .zero, size: request.size)
        imageLayer.contentsScale = request.backingScale
        cachedFrames = frames
        imageLayer.contents = frames.first
        CATransaction.commit()
        startAnimations(phaseOffset: phaseOffset)
    }

    private static nonisolated func renderFrames(
        request: RenderRequest,
        cycleDuration: CFTimeInterval,
        activeFraction: Double,
        targetFramesPerSecond: Int
    ) -> [CGImage] {
        let pixelWidth = max(1, Int((request.size.width * request.backingScale).rounded(.up)))
        let pixelHeight = max(1, Int((request.size.height * request.backingScale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let frameCount = Self.frameCount(cycleDuration: cycleDuration, targetFramesPerSecond: targetFramesPerSecond)

        return (0..<frameCount).compactMap { index in
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.scaleBy(x: request.backingScale, y: request.backingScale)
            Self.drawRippleFrame(
                in: context,
                request: request,
                phase: Double(index) / Double(frameCount),
                activeFraction: activeFraction
            )
            return context.makeImage()
        }
    }

    private static nonisolated func frameCount(cycleDuration: CFTimeInterval, targetFramesPerSecond: Int) -> Int {
        max(1, Int((cycleDuration * Double(targetFramesPerSecond)).rounded(.up)))
    }

    private static nonisolated func drawRippleFrame(
        in context: CGContext,
        request: RenderRequest,
        phase: Double,
        activeFraction: Double
    ) {
        let size = request.size
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: request.cornerRadius, cornerHeight: request.cornerRadius, transform: nil))
        context.clip()

        let pulse = (sin(phase * .pi * 2) + 1) / 2
        context.setFillColor(request.color.withAlphaComponent(0.020 + 0.014 * pulse).cgColor)
        context.fill(rect)

        if phase < activeFraction {
            Self.drawCircularRippleReflections(in: context, request: request, phase: phase / activeFraction)
        }
        context.restoreGState()
    }

    private static nonisolated func drawCircularRippleReflections(in context: CGContext, request: RenderRequest, phase: Double) {
        let size = request.size
        let fadeOut = Self.smoothPulseFade(phase)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(max(size.width, size.height) * 0.82, size.height * 2.25)
        let baseRadius = maxRadius * CGFloat(Self.easeOutSine(phase))
        let waveAlpha = CGFloat(fadeOut) * (1.04 - 0.26 * CGFloat(phase))
        let scale = request.scale
        let rings: [(offset: CGFloat, alpha: CGFloat, thickness: CGFloat)] = [
            (0, 1.00, 2.40),
            (-6.2 * scale, 0.66, 2.08),
            (-12.4 * scale, 0.46, 1.82),
            (-18.6 * scale, 0.34, 1.58),
            (-24.8 * scale, 0.24, 1.36)
        ]
        let sources = Self.rippleSources(size: size, center: center)

        for ring in rings {
            let radius = baseRadius + ring.offset
            guard radius > 1.4 * scale else { continue }
            let thickness = ring.thickness * scale

            for source in sources {
                let reflectionFade = source.isDirect
                    ? 1
                    : Self.smoothStep((radius - source.arrivalDistance) / max(12 * scale, 1))
                guard reflectionFade > 0.01 else { continue }
                let alpha = waveAlpha * ring.alpha * source.strength * reflectionFade
                Self.drawCircularRing(
                    in: context,
                    color: request.color,
                    scale: scale,
                    center: source.point,
                    radius: radius,
                    thickness: thickness,
                    alpha: alpha
                )
            }
        }

        Self.drawEdgeContact(in: context, request: request, center: center, radius: baseRadius, intensity: waveAlpha)
    }

    private static nonisolated func drawCircularRing(
        in context: CGContext,
        color: NSColor,
        scale: CGFloat,
        center: CGPoint,
        radius: CGFloat,
        thickness: CGFloat,
        alpha: CGFloat
    ) {
        guard alpha > 0.006 else { return }
        let outerRadius = max(radius + thickness / 2, 0.2)
        let innerRadius = max(radius - thickness / 2, 0.1)

        context.saveGState()
        context.setFillColor(color.withAlphaComponent(alpha * 0.54).cgColor)
        context.addEllipse(in: Self.circleRect(center: center, radius: outerRadius))
        context.addEllipse(in: Self.circleRect(center: center, radius: innerRadius))
        context.drawPath(using: .eoFill)

        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha * 0.17).cgColor)
        context.setLineWidth(max(0.18, 0.24 * scale))
        context.addEllipse(in: Self.circleRect(center: center, radius: radius))
        context.strokePath()
        context.restoreGState()
    }

    private static nonisolated func drawEdgeContact(
        in context: CGContext,
        request: RenderRequest,
        center: CGPoint,
        radius: CGFloat,
        intensity: CGFloat
    ) {
        let size = request.size
        let scale = request.scale
        let top = Self.gaussian(Double(radius), center: Double(center.y), width: Double(6.4 * scale))
        let bottom = Self.gaussian(Double(radius), center: Double(size.height - center.y), width: Double(6.4 * scale))
        let left = Self.gaussian(Double(radius), center: Double(center.x), width: Double(9.0 * scale))
        let right = Self.gaussian(Double(radius), center: Double(size.width - center.x), width: Double(9.0 * scale))
        let topSecond = Self.gaussian(Double(radius), center: Double(2 * size.height - center.y), width: Double(10.5 * scale))
        let bottomSecond = Self.gaussian(Double(radius), center: Double(size.height + center.y), width: Double(10.5 * scale))
        Self.drawEdgeGlow(in: context, rect: CGRect(x: 0, y: 0, width: size.width, height: 2.35 * scale), amount: CGFloat(top) * intensity, scale: scale)
        Self.drawEdgeGlow(in: context, rect: CGRect(x: 0, y: size.height - 2.35 * scale, width: size.width, height: 2.35 * scale), amount: CGFloat(bottom) * intensity, scale: scale)
        Self.drawEdgeGlow(in: context, rect: CGRect(x: 0, y: 0, width: 2.35 * scale, height: size.height), amount: CGFloat(left) * intensity, scale: scale)
        Self.drawEdgeGlow(in: context, rect: CGRect(x: size.width - 2.35 * scale, y: 0, width: 2.35 * scale, height: size.height), amount: CGFloat(right) * intensity, scale: scale)
        Self.drawEdgeGlow(in: context, rect: CGRect(x: 0, y: 0, width: size.width, height: 2.05 * scale), amount: CGFloat(topSecond) * intensity * 0.68, scale: scale)
        Self.drawEdgeGlow(in: context, rect: CGRect(x: 0, y: size.height - 2.05 * scale, width: size.width, height: 2.05 * scale), amount: CGFloat(bottomSecond) * intensity * 0.68, scale: scale)
    }

    private static nonisolated func drawEdgeGlow(in context: CGContext, rect: CGRect, amount: CGFloat, scale: CGFloat) {
        guard amount > 0.02 else { return }
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(amount * 0.27).cgColor)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: 1.4 * scale,
            cornerHeight: 1.4 * scale,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()
    }

    private func startAnimations(phaseOffset: CFTimeInterval = 0) {
        guard window != nil, cachedFrames.count > 1 else { return }
        guard imageLayer.animation(forKey: Self.animationKey) == nil else { return }
        let loopFrames = cachedFrames + [cachedFrames[0]]
        let lastIndex = max(loopFrames.count - 1, 1)
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let offset = min(max(phaseOffset, 0), cycleDuration)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = loopFrames
        animation.keyTimes = (0..<loopFrames.count).map { NSNumber(value: Double($0) / Double(lastIndex)) }
        animation.duration = cycleDuration
        animation.beginTime = layerTime - offset
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animationStartLayerTime = layerTime - offset
        imageLayer.add(animation, forKey: Self.animationKey)
    }

    private func stopAnimations() {
        imageLayer.removeAnimation(forKey: Self.animationKey)
        animationStartLayerTime = nil
    }

    private func currentAnimationPhaseOffset() -> CFTimeInterval {
        guard let animationStartLayerTime else { return 0 }
        let layerTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
        let elapsed = max(0, layerTime - animationStartLayerTime)
        return elapsed.truncatingRemainder(dividingBy: cycleDuration)
    }

    private func clearFrameCache() {
        cachedFrames.removeAll()
        imageLayer.contents = nil
        lastBounds = .zero
        lastBackingScale = 0
    }

    private func cancelPendingRender(advanceGeneration: Bool = true) {
        if advanceGeneration {
            renderGeneration &+= 1
        }
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    private static nonisolated func rippleSources(size: CGSize, center: CGPoint) -> [RippleSource] {
        [
            RippleSource(point: center, arrivalDistance: 0, strength: 1.00, isDirect: true),
            RippleSource(point: CGPoint(x: center.x, y: -center.y), arrivalDistance: center.y, strength: 0.84, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: size.height + (size.height - center.y)), arrivalDistance: size.height - center.y, strength: 0.84, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: center.y - 2 * size.height), arrivalDistance: 2 * size.height - center.y, strength: 0.52, isDirect: false),
            RippleSource(point: CGPoint(x: center.x, y: center.y + 2 * size.height), arrivalDistance: size.height + center.y, strength: 0.52, isDirect: false),
            RippleSource(point: CGPoint(x: -center.x, y: center.y), arrivalDistance: center.x, strength: 0.66, isDirect: false),
            RippleSource(point: CGPoint(x: size.width + (size.width - center.x), y: center.y), arrivalDistance: size.width - center.x, strength: 0.66, isDirect: false)
        ]
    }

    private static nonisolated func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static nonisolated func easeOutSine(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return sin(clamped * .pi / 2)
    }

    private static nonisolated func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static nonisolated func smoothPulseFade(_ value: Double) -> Double {
        let fadeStart = 0.80
        guard value > fadeStart else { return 1 }
        let t = min(max((value - fadeStart) / (1 - fadeStart), 0), 1)
        return Double(1 - Self.smoothStep(CGFloat(t)))
    }

    private static nonisolated func gaussian(_ value: Double, center: Double, width: Double) -> Double {
        let distance = (value - center) / max(width, 0.0001)
        return exp(-(distance * distance))
    }

    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhs = FloatingPanelColorTools.deviceRGB(lhs)
        let rhs = FloatingPanelColorTools.deviceRGB(rhs)
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }
}

@MainActor
private func resizePanel(_ panel: NSPanel, scale: Double) {
    let previousFrame = panel.frame
    let topLeft = NSPoint(x: previousFrame.minX, y: previousFrame.maxY)
    let targetSize = FloatingTokenPanelMetrics.size(scale: scale)
    let targetFrame = anchoredPanelFrame(for: panel, size: targetSize, topLeft: topLeft)
    panel.contentViewController?.view.frame = NSRect(origin: .zero, size: targetSize)
    panel.contentMinSize = targetSize
    panel.contentMaxSize = targetSize
    panel.setFrame(targetFrame, display: true, animate: false)
}

@MainActor
private func anchoredPanelFrame(for panel: NSPanel, size: NSSize, topLeft: NSPoint) -> NSRect {
    let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)

    if let screenFrame {
        let margin: CGFloat = 8
        origin.x = min(max(origin.x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        origin.y = min(max(origin.y, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)
    }

    return NSRect(origin: origin, size: size)
}
