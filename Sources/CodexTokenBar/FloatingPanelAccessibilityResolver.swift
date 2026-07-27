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

private final class FloatingPanelLatestRequestLane<Request: Sendable, Output: Sendable>: @unchecked Sendable {
    typealias Query = @Sendable (Request) -> Output
    typealias Completion = @MainActor @Sendable (Output) -> Void

    private struct Work: Sendable {
        let generation: UInt64
        let request: Request
        let completion: Completion
    }

    private let queue: DispatchQueue
    private let query: Query
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingWork: Work?
    private var workerScheduled = false

    init(queue: DispatchQueue, query: @escaping Query) {
        self.queue = queue
        self.query = query
    }

    func submit(_ request: Request, completion: @escaping Completion) {
        let shouldScheduleWorker = lock.withLock {
            generation &+= 1
            pendingWork = Work(
                generation: generation,
                request: request,
                completion: completion
            )
            guard !workerScheduled else { return false }
            workerScheduled = true
            return true
        }
        guard shouldScheduleWorker else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while let work = lock.withLock({ () -> Work? in
            guard let pendingWork else {
                workerScheduled = false
                return nil
            }
            self.pendingWork = nil
            return pendingWork
        }) {
            let result = query(work.request)
            guard isCurrent(work.generation) else { continue }
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(work.generation) else { return }
                work.completion(result)
            }
        }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { generation == candidate }
    }
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

    private let pointLane: FloatingPanelLatestRequestLane<
        FloatingPanelAccessibilityPointRequest,
        FloatingPanelAccessibilitySnapshot?
    >
    private let windowLane: FloatingPanelLatestRequestLane<
        FloatingPanelAccessibilityWindowRequest,
        FloatingPanelAccessibilitySnapshot?
    >
    private let frameQueue: DispatchQueue
    private let frameQuery: FrameQuery

    init(
        pointQueue: DispatchQueue = DispatchQueue(
            label: "com.huyiyang.codex-token-bar.floating-panel-accessibility.point",
            qos: .userInteractive
        ),
        windowQueue: DispatchQueue = DispatchQueue(
            label: "com.huyiyang.codex-token-bar.floating-panel-accessibility.window",
            qos: .userInitiated
        ),
        frameQueue: DispatchQueue = DispatchQueue(
            label: "com.huyiyang.codex-token-bar.floating-panel-accessibility.frame",
            qos: .userInteractive
        ),
        pointQuery: @escaping PointQuery = FloatingPanelAccessibilityIPC.target,
        windowQuery: @escaping WindowQuery = FloatingPanelAccessibilityIPC.target,
        frameQuery: @escaping FrameQuery = FloatingPanelAccessibilityIPC.frame
    ) {
        pointLane = FloatingPanelLatestRequestLane(
            queue: pointQueue,
            query: pointQuery
        )
        windowLane = FloatingPanelLatestRequestLane(
            queue: windowQueue,
            query: windowQuery
        )
        self.frameQueue = frameQueue
        self.frameQuery = frameQuery
    }

    func resolveTarget(
        at request: FloatingPanelAccessibilityPointRequest,
        completion: @escaping @MainActor @Sendable (FloatingPanelAccessibilitySnapshot?) -> Void
    ) {
        pointLane.submit(request, completion: completion)
    }

    func resolveTarget(
        matching request: FloatingPanelAccessibilityWindowRequest,
        completion: @escaping @MainActor @Sendable (FloatingPanelAccessibilitySnapshot?) -> Void
    ) {
        windowLane.submit(request, completion: completion)
    }

    func resolveFrame(
        _ request: FloatingPanelAccessibilityFrameRequest,
        completion: @escaping @MainActor @Sendable (CGRect?) -> Void
    ) {
        frameQueue.async { [frameQuery] in
            let result = frameQuery(request)
            Task { @MainActor in
                completion(result)
            }
        }
    }
}

enum FloatingPanelAccessibilityIPC {
    static let messagingTimeout: Float = 0.25
    static let windowResolutionBudget: TimeInterval = 0.75

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

        let deadline = ProcessInfo.processInfo.systemUptime + windowResolutionBudget
        var best: (target: FloatingPanelAccessibilitySnapshot, score: CGFloat)?
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let target = snapshot(from: window, displayMaxY: request.displayMaxY),
                  target.ownerPID == request.window.ownerPID
            else {
                continue
            }
            let frameDelta = abs(target.frame.minX - request.window.frame.minX)
                + abs(target.frame.minY - request.window.frame.minY)
                + abs(target.frame.width - request.window.frame.width)
                + abs(target.frame.height - request.window.frame.height)
            let titleBonus: CGFloat = (
                !request.window.title.isEmpty && target.title == request.window.title
            ) ? 2_000 : 0
            let candidate = (target, titleBonus - frameDelta)
            if let currentBest = best, candidate.1 <= currentBest.score { continue }
            best = candidate
        }
        guard let best else { return nil }
        let titleMatches = !request.window.title.isEmpty && best.target.title == request.window.title
        let frameLooksClose = best.score > -90
        return titleMatches || frameLooksClose ? best.target : nil
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
