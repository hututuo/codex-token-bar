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

        let windows = visibleWindows(relaxed: true, forceRefresh: true)
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
        guard let clickAt = lastExternalClickAt,
              Date().timeIntervalSince(clickAt) <= recentExternalClickTargetInterval,
              let lastExternalClickAXWindow,
              let target = accessibilityTarget(from: lastExternalClickAXWindow)
        else {
            return nil
        }
        return target
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

    func accessibilityTarget(at location: NSPoint) -> FloatingPanelAccessibilityTarget? {
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

    func accessibilityTarget(matching window: FloatingPanelTargetWindow) -> FloatingPanelAccessibilityTarget? {
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

    func accessibilityTarget(from window: AXUIElement) -> FloatingPanelAccessibilityTarget? {
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

    func accessibilityWindow(from element: AXUIElement) -> AXUIElement? {
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

    func accessibilityFrame(of window: AXUIElement) -> NSRect? {
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

    func accessibilityStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
