import AppKit
import ApplicationServices
import CoreGraphics
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
