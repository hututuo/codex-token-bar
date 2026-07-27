import ApplicationServices
import CoreGraphics
import Foundation

struct FloatingPanelAccessibilitySnapshot: @unchecked Sendable {
    let window: AXUIElement
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
}

struct FloatingPanelAccessibilityPointRequest: Sendable {
    let location: CGPoint
    let displayMaxY: CGFloat
}

struct FloatingPanelAccessibilityWindowRequest: Sendable {
    let window: FloatingPanelTargetWindow
    let displayMaxY: CGFloat
}

struct FloatingPanelAccessibilityFrameRequest: @unchecked Sendable {
    let window: AXUIElement
    let ownerPID: pid_t
    let displayMaxY: CGFloat
}

final class FloatingPanelAccessibilityResolver: @unchecked Sendable {
    typealias PointQuery = @Sendable (
        FloatingPanelAccessibilityPointRequest
    ) -> FloatingPanelAccessibilitySnapshot?
    typealias WindowQuery = @Sendable (
        FloatingPanelAccessibilityWindowRequest
    ) -> FloatingPanelAccessibilitySnapshot?
    typealias FrameQuery = @Sendable (
        FloatingPanelAccessibilityFrameRequest
    ) -> CGRect?

    private let queue: DispatchQueue
    private let pointQuery: PointQuery
    private let windowQuery: WindowQuery
    private let frameQuery: FrameQuery

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.huyiyang.codex-token-bar.floating-panel-accessibility",
            qos: .userInteractive
        ),
        pointQuery: @escaping PointQuery = FloatingPanelAccessibilityIPC.target,
        windowQuery: @escaping WindowQuery = FloatingPanelAccessibilityIPC.target,
        frameQuery: @escaping FrameQuery = FloatingPanelAccessibilityIPC.frame
    ) {
        self.queue = queue
        self.pointQuery = pointQuery
        self.windowQuery = windowQuery
        self.frameQuery = frameQuery
    }

    func resolveTarget(
        at request: FloatingPanelAccessibilityPointRequest,
        completion: @escaping @MainActor @Sendable (FloatingPanelAccessibilitySnapshot?) -> Void
    ) {
        queue.async { [pointQuery] in
            let result = pointQuery(request)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func resolveTarget(
        matching request: FloatingPanelAccessibilityWindowRequest,
        completion: @escaping @MainActor @Sendable (FloatingPanelAccessibilitySnapshot?) -> Void
    ) {
        queue.async { [windowQuery] in
            let result = windowQuery(request)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func resolveFrame(
        _ request: FloatingPanelAccessibilityFrameRequest,
        completion: @escaping @MainActor @Sendable (CGRect?) -> Void
    ) {
        queue.async { [frameQuery] in
            let result = frameQuery(request)
            Task { @MainActor in
                completion(result)
            }
        }
    }
}

enum FloatingPanelAccessibilityIPC {
    static let messagingTimeout: Float = 0.25

    static func target(
        _ request: FloatingPanelAccessibilityPointRequest
    ) -> FloatingPanelAccessibilitySnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        configure(systemWide)
        var element: AXUIElement?
        let quartzLocation = CGPoint(
            x: request.location.x,
            y: request.displayMaxY - request.location.y
        )
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(quartzLocation.x),
            Float(quartzLocation.y),
            &element
        ) == .success,
              let element,
              let window = window(from: element)
        else {
            return nil
        }
        return snapshot(from: window, displayMaxY: request.displayMaxY)
    }

    static func target(
        _ request: FloatingPanelAccessibilityWindowRequest
    ) -> FloatingPanelAccessibilitySnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(request.window.ownerPID)
        configure(appElement)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }

        let candidates = windows.compactMap {
            snapshot(from: $0, displayMaxY: request.displayMaxY)
        }
        .filter { $0.ownerPID == request.window.ownerPID }
        let scored = candidates.map { target -> (FloatingPanelAccessibilitySnapshot, CGFloat) in
            let frameDelta = abs(target.frame.minX - request.window.frame.minX)
                + abs(target.frame.minY - request.window.frame.minY)
                + abs(target.frame.width - request.window.frame.width)
                + abs(target.frame.height - request.window.frame.height)
            let titleBonus: CGFloat = (
                !request.window.title.isEmpty && target.title == request.window.title
            ) ? 2_000 : 0
            return (target, titleBonus - frameDelta)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let titleMatches = !request.window.title.isEmpty && best.0.title == request.window.title
        let frameLooksClose = best.1 > -90
        return titleMatches || frameLooksClose ? best.0 : nil
    }

    static func frame(_ request: FloatingPanelAccessibilityFrameRequest) -> CGRect? {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(request.window, &ownerPID) == .success,
              ownerPID == request.ownerPID
        else {
            return nil
        }
        return frame(of: request.window, displayMaxY: request.displayMaxY)
    }

    private static func snapshot(
        from window: AXUIElement,
        displayMaxY: CGFloat
    ) -> FloatingPanelAccessibilitySnapshot? {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(window, &ownerPID) == .success,
              let frame = frame(of: window, displayMaxY: displayMaxY)
        else {
            return nil
        }
        return FloatingPanelAccessibilitySnapshot(
            window: window,
            ownerPID: ownerPID,
            title: stringAttribute(window, kAXTitleAttribute as CFString) ?? "",
            frame: frame
        )
    }

    private static func window(from element: AXUIElement) -> AXUIElement? {
        if stringAttribute(element, kAXRoleAttribute as CFString) == (kAXWindowRole as String) {
            return element
        }
        configure(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func frame(of window: AXUIElement, displayMaxY: CGFloat) -> CGRect? {
        configure(window)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                  window,
                  kAXSizeAttribute as CFString,
                  &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAXValue = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue, to: AXValue.self)
        var topLeft = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &topLeft),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              size.width > 1,
              size.height > 1
        else {
            return nil
        }
        return CGRect(
            x: topLeft.x,
            y: displayMaxY - topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        configure(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func configure(_ element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }
}
