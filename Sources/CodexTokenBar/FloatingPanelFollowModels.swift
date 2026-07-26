import AppKit
import ApplicationServices

struct FloatingPanelTargetWindow {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    let frame: NSRect
    let rawFrame: NSRect

    var displayName: String {
        if !title.isEmpty, title != ownerName {
            return "\(ownerName) · \(title)"
        }
        return ownerName.isEmpty ? "目标窗口" : ownerName
    }
}

struct FloatingPanelAccessibilityTarget {
    let window: AXUIElement
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    let frame: NSRect

    var displayName: String {
        if !title.isEmpty, title != ownerName {
            return "\(ownerName) · \(title)"
        }
        return ownerName.isEmpty ? "目标窗口" : ownerName
    }
}

struct FloatingPanelFollowTarget {
    let frame: NSRect
    let targetDescription: String
}

struct FloatingPanelWindowListCache {
    let createdAt: Date
    let windows: [FloatingPanelTargetWindow]
}

struct FloatingPanelWindowAnchor {
    let windowNumber: Int?
    let ownerPID: pid_t
    let ownerBundleID: String?
    let windowTitle: String
    let targetDescription: String
    let offset: NSPoint
    let accessibilityWindow: AXUIElement?
}

struct FloatingPanelLockedTargetDrag {
    let windowNumber: Int?
    let ownerPID: pid_t
    let ownerBundleID: String?
    let windowTitle: String
    let mouseStart: NSPoint
    let panelOriginStart: NSPoint
    let clickOffsetInTarget: NSPoint

    init(anchor: FloatingPanelWindowAnchor, mouseStart: NSPoint, panelOriginStart: NSPoint, targetFrameStart: NSRect) {
        self.windowNumber = anchor.windowNumber
        self.ownerPID = anchor.ownerPID
        self.ownerBundleID = anchor.ownerBundleID
        self.windowTitle = anchor.windowTitle
        self.mouseStart = mouseStart
        self.panelOriginStart = panelOriginStart
        self.clickOffsetInTarget = NSPoint(
            x: min(max(mouseStart.x - targetFrameStart.minX, 0), targetFrameStart.width),
            y: min(max(mouseStart.y - targetFrameStart.minY, 0), targetFrameStart.height)
        )
    }

    func matches(_ anchor: FloatingPanelWindowAnchor) -> Bool {
        if windowNumber != anchor.windowNumber {
            return false
        }
        if ownerPID != anchor.ownerPID {
            return false
        }
        if ownerBundleID != anchor.ownerBundleID {
            return false
        }
        return windowTitle == anchor.windowTitle
    }
}

enum FloatingPanelScreenGeometry {
    // Cocoa↔Quartz 翻转基准必须是主屏（screens.first，Cocoa 原点所在屏）的
    // maxY：Quartz 全局坐标以主屏左上角为原点。取所有屏的最大 maxY 会在副屏
    // 位于主屏上方时把窗口定位/AX 命中/跟随整体偏移一个副屏高度。
    static var displayMaxY: CGFloat {
        conversionBaseline(
            orderedScreenFrames: NSScreen.screens.map(\.frame),
            mainScreenFrame: NSScreen.main?.frame
        )
    }

    static func conversionBaseline(
        orderedScreenFrames: [NSRect],
        mainScreenFrame: NSRect?
    ) -> CGFloat {
        orderedScreenFrames.first?.maxY ?? mainScreenFrame?.maxY ?? 0
    }
}
