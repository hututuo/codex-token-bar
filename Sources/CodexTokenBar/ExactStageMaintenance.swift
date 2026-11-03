import Foundation

/// One utility timer for A, independent of a window or Home refresh. Durable
/// publication receipts supply the queue; idle checks back off to 30 seconds.
/// Constructed only by the ready application runtime, never by a reader.
final class ExactStageMaintenance: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tokenbar.exact-stage-maintenance", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pool: ExactStagePool?
    private var lastError: String?

    #if DEBUG
    private let firstTickDelayForTesting: TimeInterval?
    private let onTickForTesting: (@Sendable () -> Void)?

    init(firstTickDelayForTesting: TimeInterval? = nil,
         onTickForTesting: (@Sendable () -> Void)? = nil) {
        self.firstTickDelayForTesting = firstTickDelayForTesting
        self.onTickForTesting = onTickForTesting
    }
    #endif

    @MainActor func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        // DispatchSource's handler overload does not require @Sendable. An
        // unannotated closure here inherits start()'s MainActor isolation and
        // traps when the utility queue invokes it for the first time.
        timer.setEventHandler { @Sendable [weak self] in self?.tick() }
        #if DEBUG
        let firstTickDelay = firstTickDelayForTesting ?? 30
        #else
        let firstTickDelay: TimeInterval = 30
        #endif
        timer.schedule(deadline: .now() + firstTickDelay, leeway: .seconds(2))
        timer.resume()
    }

    private func tick() {
        #if DEBUG
        onTickForTesting?()
        #endif
        let started = Date()
        var delay: TimeInterval = 30
        defer { timer?.schedule(deadline: .now() + max(delay, Date().timeIntervalSince(started) * 4), leeway: .milliseconds(250)) }
        // Recovery owns all structural decisions until its operation finishes.
        guard !BusinessSQLiteRoutes.hasPublishedAdmission else { return }
        do {
            if pool == nil, let target = BusinessSQLiteRoutes.registeredStores(module: "exact.swift")
                .sorted(by: { $0.id < $1.id }).first {
                pool = try ExactStagePool.existingOrNeededForLegacy(for: target)
            }
            guard let pool else { return }
            let count = try pool.reclaimPublished()
            lastError = nil
            if count > 0 { delay = 2 }
        } catch {
            delay = 60
            let message = String(error.localizedDescription.prefix(1024))
            if message != lastError { NSLog("Exact stage maintenance deferred: %@", message); lastError = message }
        }
    }

    deinit { timer?.cancel() }
}
