import Foundation

/// Keeps an expensive, reconstructible resource warm across a burst of work,
/// without making its lifetime equal to the application's lifetime. Callers
/// borrow strong references, so expiry cannot invalidate an active operation.
final class IdleResourceCache<Value: AnyObject & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let idleSeconds: TimeInterval
    private let make: @Sendable () throws -> Value
    private let now: @Sendable () -> TimeInterval
    private var value: Value?
    private weak var borrowedValue: Value?
    private var lastUse: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private let automaticallyExpires: Bool

    init(idleSeconds: TimeInterval, automaticallyExpires: Bool = true,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         make: @escaping @Sendable () throws -> Value) {
        self.idleSeconds = max(0.01, idleSeconds)
        self.automaticallyExpires = automaticallyExpires
        self.now = now
        self.make = make
    }

    func get() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        let resource: Value
        if let existing = value ?? borrowedValue { resource = existing }
        else {
            resource = try make()
        }
        value = resource
        borrowedValue = resource
        lastUse = now()
        if automaticallyExpires, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            self.timer = timer
            timer.setEventHandler { @Sendable [weak self] in self?.expireIfIdle() }
            timer.schedule(deadline: .now() + idleSeconds, leeway: .seconds(1))
            timer.resume()
        }
        return resource
    }

    func expireIfIdle() {
        lock.lock()
        let remaining = idleSeconds - (now() - lastUse)
        if remaining > 0 {
            timer?.schedule(deadline: .now() + remaining, leeway: .seconds(1))
            lock.unlock()
            return
        }
        let expired = value
        value = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        // Native tokenizers can own a large allocation tree. Destroy outside
        // the lock, after any in-flight caller has finished with its borrow.
        withExtendedLifetime(expired) {}
    }

    deinit { timer?.cancel() }
}
