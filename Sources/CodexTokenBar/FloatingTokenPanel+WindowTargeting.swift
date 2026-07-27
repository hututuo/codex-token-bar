import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
extension FloatingTokenPanelController {
    func findTargetWindow(near panelFrame: NSRect) -> FloatingPanelTargetWindow? {
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

    func targetWindowAtRecentExternalClick() -> FloatingPanelTargetWindow? {
        guard let location = lastExternalClickLocation,
              let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval
        else {
            return nil
        }

        let windows = externalClickVisibleWindowsProvider?() ?? visibleWindows(relaxed: true, forceRefresh: true)
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

    func targetAccessibilityWindowAtRecentExternalClick() -> FloatingPanelAccessibilityTarget? {
        guard let location = lastExternalClickLocation,
              let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval
        else {
            return nil
        }
        if let lastExternalClickAccessibilityTarget {
            return lastExternalClickAccessibilityTarget
        }
        if let externalClickAccessibilityTargetProvider {
            return externalClickAccessibilityTargetProvider(location)
        }
        return nil
    }

    func windowContainsClick(_ location: NSPoint, window: FloatingPanelTargetWindow) -> Bool {
        if window.frame.contains(location) {
            return true
        }

        let quartzLocation = NSPoint(x: location.x, y: FloatingPanelScreenGeometry.displayMaxY - location.y)
        return window.rawFrame.contains(quartzLocation)
    }

    func targetDistanceScore(_ window: FloatingPanelTargetWindow, near panelFrame: NSRect) -> CGFloat {
        let dx = window.frame.midX - panelFrame.midX
        let dy = window.frame.midY - panelFrame.midY
        return -((dx * dx) + (dy * dy))
    }

    func targetWindow(_ window: FloatingPanelTargetWindow, matches anchor: FloatingPanelWindowAnchor) -> Bool {
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

    func accessibilityTarget(_ target: FloatingPanelAccessibilityTarget, matches anchor: FloatingPanelWindowAnchor) -> Bool {
        guard target.ownerPID == anchor.ownerPID else { return false }
        if !anchor.windowTitle.isEmpty {
            return target.title == anchor.windowTitle
        }
        if let bundleID = anchor.ownerBundleID {
            return target.ownerBundleID == bundleID
        }
        return true
    }

    func overlapArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    func visibleScreenFrame(for rect: NSRect, fallback panel: NSPanel) -> NSRect? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen.visibleFrame
        }

        let overlappingScreen = NSScreen.screens.max { lhs, rhs in
            overlapArea(lhs.frame, rect) < overlapArea(rhs.frame, rect)
        }
        return overlappingScreen?.visibleFrame ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    func targetFrame(matching anchor: FloatingPanelWindowAnchor) -> FloatingPanelFollowTarget? {
        if lockedAnchor?.hasSameIdentity(as: anchor) == true {
            requestFollowTargetResolutionIfNeeded()
        }
        if let cachedFollowAccessibilityFrame,
           cachedFollowAccessibilityFrame.matches(anchor) {
            return FloatingPanelFollowTarget(
                frame: cachedFollowAccessibilityFrame.frame,
                targetDescription: anchor.targetDescription
            )
        }
        if let targetWindow = findWindow(matching: anchor) {
            return FloatingPanelFollowTarget(frame: targetWindow.frame, targetDescription: targetWindow.displayName)
        }
        return nil
    }

    func findWindow(matching anchor: FloatingPanelWindowAnchor) -> FloatingPanelTargetWindow? {
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

    func refreshLockedAnchorOffsetForCurrentFrame() {
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

    func refreshFloatingPanelLockStatus() {
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

    func visibleWindows(relaxed: Bool = false, forceRefresh: Bool = false) -> [FloatingPanelTargetWindow] {
        let now = Date()
        if !forceRefresh {
            let cache = relaxed ? relaxedVisibleWindowCache : strictVisibleWindowCache
            if let cache, now.timeIntervalSince(cache.createdAt) < visibleWindowListRefreshInterval {
                return cache.windows
            }
        }

        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let windows = rawWindows.compactMap { targetWindow(from: $0, relaxed: relaxed) }
        let cache = FloatingPanelWindowListCache(createdAt: now, windows: windows)
        if relaxed {
            relaxedVisibleWindowCache = cache
        } else {
            strictVisibleWindowCache = cache
        }
        return windows
    }

    func windowDescription(for windowNumber: Int, relaxed: Bool) -> FloatingPanelTargetWindow? {
        let windowIDs = [CGWindowID(windowNumber)] as CFArray
        guard let rawWindows = CGWindowListCreateDescriptionFromArray(windowIDs) as? [[String: Any]] else {
            return nil
        }
        return rawWindows.compactMap { targetWindow(from: $0, relaxed: relaxed) }.first
    }

    func targetWindow(from info: [String: Any], relaxed: Bool) -> FloatingPanelTargetWindow? {
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

    func isLockCandidateWindow(layer: Int, ownerName: String, bundleID: String?, relaxed: Bool) -> Bool {
        let maximumLayer = relaxed ? 2_000 : 25
        guard layer >= 0, layer <= maximumLayer else {
            return false
        }
        return !isBlockedWindowOwner(ownerName: ownerName, bundleID: bundleID)
    }

    func isBlockedWindowOwner(ownerName: String, bundleID: String?) -> Bool {
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

    func accessibilityTarget(
        from snapshot: FloatingPanelAccessibilitySnapshot
    ) -> FloatingPanelAccessibilityTarget? {
        let ownerPID = snapshot.ownerPID
        guard ownerPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = NSRunningApplication(processIdentifier: ownerPID)
        let ownerName = app?.localizedName ?? ""
        guard !isBlockedWindowOwner(ownerName: ownerName, bundleID: app?.bundleIdentifier) else {
            return nil
        }
        return FloatingPanelAccessibilityTarget(
            window: snapshot.window,
            ownerPID: ownerPID,
            ownerBundleID: app?.bundleIdentifier,
            ownerName: ownerName,
            title: snapshot.title,
            frame: snapshot.frame
        )
    }

    func requestFollowTargetResolutionIfNeeded() {
        guard let anchor = lockedAnchor else { return }
        if anchor.accessibilityWindow == nil {
            requestAnchorAccessibilityResolution(anchor)
        } else {
            requestAccessibilityFrameResolution(anchor)
        }
    }

    func requestAccessibilityFrameResolution(_ anchor: FloatingPanelWindowAnchor) {
        guard !followFrameResolutionInFlight,
              let accessibilityWindow = anchor.accessibilityWindow
        else {
            return
        }
        let generation = followResolutionGeneration
        followFrameResolutionInFlight = true
        let request = FloatingPanelAccessibilityFrameRequest(
            window: accessibilityWindow,
            ownerPID: anchor.ownerPID,
            displayMaxY: FloatingPanelScreenGeometry.displayMaxY
        )
        accessibilityResolver.resolveFrame(request) { [weak self] frame in
            guard let self,
                  generation == self.followResolutionGeneration,
                  let currentAnchor = self.lockedAnchor,
                  currentAnchor.hasSameIdentity(as: anchor)
            else {
                return
            }
            self.followFrameResolutionInFlight = false
            guard let frame,
                  let currentWindow = currentAnchor.accessibilityWindow,
                  CFEqual(currentWindow, accessibilityWindow)
            else {
                return
            }
            self.cachedFollowAccessibilityFrame = FloatingPanelAccessibilityFrameCache(
                window: accessibilityWindow,
                ownerPID: anchor.ownerPID,
                frame: frame
            )
        }
    }

    func requestAnchorAccessibilityResolution(_ anchor: FloatingPanelWindowAnchor) {
        guard !anchorAccessibilityResolutionInFlight,
              let targetWindow = findWindow(matching: anchor)
        else {
            return
        }
        let generation = followResolutionGeneration
        anchorAccessibilityResolutionInFlight = true
        let request = FloatingPanelAccessibilityWindowRequest(
            window: targetWindow,
            displayMaxY: FloatingPanelScreenGeometry.displayMaxY
        )
        accessibilityResolver.resolveTarget(matching: request) { [weak self] snapshot in
            guard let self,
                  generation == self.followResolutionGeneration,
                  let currentAnchor = self.lockedAnchor,
                  currentAnchor.hasSameIdentity(as: anchor)
            else {
                return
            }
            self.anchorAccessibilityResolutionInFlight = false
            guard let snapshot,
                  let target = self.accessibilityTarget(from: snapshot),
                  self.accessibilityTarget(target, matches: currentAnchor)
            else {
                return
            }
            self.attachAccessibilityTargetToLockedAnchorIfMatching(target)
        }
    }

    func attachAccessibilityTargetToLockedAnchorIfMatching(
        _ target: FloatingPanelAccessibilityTarget
    ) {
        guard let anchor = lockedAnchor,
              accessibilityTarget(target, matches: anchor)
        else {
            return
        }
        lockedAnchor = FloatingPanelWindowAnchor(
            windowNumber: anchor.windowNumber,
            ownerPID: anchor.ownerPID,
            ownerBundleID: anchor.ownerBundleID,
            windowTitle: anchor.windowTitle,
            targetDescription: anchor.targetDescription,
            offset: anchor.offset,
            accessibilityWindow: target.window
        )
        cachedFollowAccessibilityFrame = FloatingPanelAccessibilityFrameCache(
            window: target.window,
            ownerPID: target.ownerPID,
            frame: target.frame
        )
        installAccessibilityObserverForLockedAnchor()
    }
}
