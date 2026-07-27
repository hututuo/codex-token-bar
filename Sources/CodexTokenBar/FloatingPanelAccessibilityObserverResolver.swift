import ApplicationServices
import Foundation

final class FloatingPanelAccessibilityObserverContext: @unchecked Sendable {
    private let eventHandler: @MainActor @Sendable () -> Void

    init(eventHandler: @escaping @MainActor @Sendable () -> Void) {
        self.eventHandler = eventHandler
    }

    func notify() {
        Task { @MainActor [eventHandler] in
            eventHandler()
        }
    }
}

struct FloatingPanelAccessibilityObserverRequest: @unchecked Sendable {
    let ownerPID: pid_t
    let window: AXUIElement
    let context: FloatingPanelAccessibilityObserverContext
}

struct FloatingPanelAccessibilityObserverRegistration: @unchecked Sendable {
    let observer: AXObserver
    let window: AXUIElement
    let context: FloatingPanelAccessibilityObserverContext
}

final class FloatingPanelAccessibilityObserverResolver: @unchecked Sendable {
    typealias InstallOperation = @Sendable (
        FloatingPanelAccessibilityObserverRequest
    ) -> FloatingPanelAccessibilityObserverRegistration?
    typealias RemoveOperation = @Sendable (
        FloatingPanelAccessibilityObserverRegistration
    ) -> Void

    private let queue: DispatchQueue
    private let installOperation: InstallOperation
    private let removeOperation: RemoveOperation

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.huyiyang.codex-token-bar.floating-panel-accessibility.observer",
            qos: .userInteractive
        ),
        installOperation: @escaping InstallOperation = FloatingPanelAccessibilityObserverIPC.install,
        removeOperation: @escaping RemoveOperation = FloatingPanelAccessibilityObserverIPC.remove
    ) {
        self.queue = queue
        self.installOperation = installOperation
        self.removeOperation = removeOperation
    }

    func install(
        _ request: FloatingPanelAccessibilityObserverRequest,
        completion: @escaping @MainActor @Sendable (
            FloatingPanelAccessibilityObserverRegistration?
        ) -> Void
    ) {
        queue.async { [installOperation] in
            let registration = installOperation(request)
            Task { @MainActor in
                completion(registration)
            }
        }
    }

    func remove(_ registration: FloatingPanelAccessibilityObserverRegistration) {
        queue.async { [removeOperation] in
            removeOperation(registration)
        }
    }
}

enum FloatingPanelAccessibilityObserverIPC {
    static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let context = Unmanaged<FloatingPanelAccessibilityObserverContext>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        context.notify()
    }

    static func install(
        _ request: FloatingPanelAccessibilityObserverRequest
    ) -> FloatingPanelAccessibilityObserverRegistration? {
        FloatingPanelAccessibilityIPC.configure(request.window)
        var observer: AXObserver?
        guard AXObserverCreate(request.ownerPID, callback, &observer) == .success,
              let observer
        else {
            return nil
        }

        let refcon = Unmanaged.passUnretained(request.context).toOpaque()
        let moved = AXObserverAddNotification(
            observer,
            request.window,
            kAXMovedNotification as CFString,
            refcon
        )
        let resized = AXObserverAddNotification(
            observer,
            request.window,
            kAXResizedNotification as CFString,
            refcon
        )
        guard moved == .success || resized == .success else { return nil }
        return FloatingPanelAccessibilityObserverRegistration(
            observer: observer,
            window: request.window,
            context: request.context
        )
    }

    static func remove(_ registration: FloatingPanelAccessibilityObserverRegistration) {
        FloatingPanelAccessibilityIPC.configure(registration.window)
        AXObserverRemoveNotification(
            registration.observer,
            registration.window,
            kAXMovedNotification as CFString
        )
        AXObserverRemoveNotification(
            registration.observer,
            registration.window,
            kAXResizedNotification as CFString
        )
    }
}
