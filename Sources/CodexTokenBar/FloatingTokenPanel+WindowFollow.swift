import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
extension FloatingTokenPanelController {
    func recordExternalMouseClick(at location: NSPoint) {
        guard shouldProcessExternalMouseEvents else { return }
        if let panel, panel.frame.contains(location) {
            activeLockedTargetDrag = nil
            return
        }
        lastExternalClickLocation = location
        lastExternalClickAt = Date()
        let clickedAXTarget: FloatingPanelAccessibilityTarget?
        if let externalClickAccessibilityTargetProvider {
            clickedAXTarget = externalClickAccessibilityTargetProvider(location)
        } else {
            clickedAXTarget = accessibilityTarget(at: location)
        }
        if let target = clickedAXTarget {
            lastExternalClickAXWindow = target.window
            lastExternalClickOwnerPID = target.ownerPID
            lastExternalActivePID = target.ownerPID
        } else {
            lastExternalClickAXWindow = nil
        }
        let visibleTargets = externalClickVisibleWindowsProvider?() ?? visibleWindows(relaxed: true, forceRefresh: true)
        let clickedWindow = visibleTargets.first(where: { windowContainsClick(location, window: $0) })
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

    func recordExternalMouseDrag(at location: NSPoint) {
        guard shouldProcessExternalMouseEvents else { return }
        guard activeLockedTargetDrag != nil else { return }
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followLockedTargetDrag(at: location)
    }

    func finishExternalMouseDrag(at location: NSPoint) {
        guard shouldProcessExternalMouseEvents else { return }
        guard activeLockedTargetDrag != nil else { return }
        followLockedTargetDrag(at: location)
        activeLockedTargetDrag = nil
        refreshLockedAnchorOffsetForCurrentFrame()
    }

    private var shouldProcessExternalMouseEvents: Bool {
        FloatingPanelExternalEventRelevance.shouldProcess(
            isPresented: isPresented,
            isLocked: appliedLockState,
            hasLockedAnchor: lockedAnchor != nil,
            hasActiveDrag: activeLockedTargetDrag != nil
        )
    }

    func beginLockedTargetDragIfNeeded(
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
    func followLockedTargetDrag(at location: NSPoint) -> Bool {
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

    func boundedDragSlip(
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

    func position(_ panel: NSPanel) {
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

    func updateLockState(_ isLocked: Bool, force: Bool = false) {
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

    func currentAnchor(for panel: NSPanel) -> FloatingPanelWindowAnchor? {
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

    func startFollowingAnchor() {
        guard lockedAnchor != nil else { return }
        installAccessibilityObserverForLockedAnchor()
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followAnchorIfNeeded()
    }

    func scheduleFollowTimer(interval: TimeInterval) {
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

    func stopFollowingAnchor() {
        activeLockedTargetDrag = nil
        followTimer?.invalidate()
        followTimer = nil
        followTimerInterval = nil
        fastFollowUntil = nil
        flushPendingLockedOriginSave()
        uninstallAccessibilityObserver()
    }

    func tickFollowTimer() {
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

    func installAccessibilityObserverForLockedAnchor() {
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

    func uninstallAccessibilityObserver() {
        if let observer = accessibilityObserver, let observedAccessibilityWindow {
            AXObserverRemoveNotification(observer, observedAccessibilityWindow, kAXMovedNotification as CFString)
            AXObserverRemoveNotification(observer, observedAccessibilityWindow, kAXResizedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        accessibilityObserver = nil
        observedAccessibilityWindow = nil
    }

    func handleAccessibilityWindowEvent() {
        fastFollowUntil = Date().addingTimeInterval(fastFollowGracePeriod)
        scheduleFollowTimer(interval: fastFollowInterval)
        followAnchorIfNeeded()
    }

    @discardableResult
    func followAnchorIfNeeded() -> Bool {
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
    func movePanelIfNeeded(_ panel: NSPanel, to origin: NSPoint, persist: Bool) -> Bool {
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


}
