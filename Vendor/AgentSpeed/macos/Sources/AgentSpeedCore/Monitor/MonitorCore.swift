import Foundation
import os

/// Runs a `TranscriptSession` on a private serial queue: seeding, FSEvents, the fallback stat loop,
/// rediscovery and periodic publishing.
///
/// `@unchecked Sendable`: every mutable property is only touched on `queue`; the cancellation flag and the requested
/// source sets are locked.
final class MonitorCore: @unchecked Sendable {
    static let publishInterval: DispatchTimeInterval = .milliseconds(500)
    static let pollInterval: DispatchTimeInterval = .seconds(1)
    static let rediscoveryInterval: DispatchTimeInterval = .seconds(10)
    static let changeDebounce: DispatchTimeInterval = .milliseconds(80)
    static let watcherLatency: TimeInterval = 0.1

    private let configuration: MonitorConfiguration
    private let pricing: PriceBook?
    private let mailbox: SnapshotMailbox
    private let queue = DispatchQueue(label: "app.agentspeed.monitor", qos: .utility)
    /// Whole-file reads (METRICS 5.3), one at a time, off the live loop.
    private let wholeFileQueue = DispatchQueue(label: "app.agentspeed.monitor.whole-file", qos: .utility)
    /// Runs before each whole-file read on its queue; tests use it to make a read slow.
    private let wholeFileReadHook: (@Sendable (String) -> Void)?
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Source sets whose measured peak each snapshot reports (METRICS 6.8).
    private let subsets: OSAllocatedUnfairLock<Set<SourceSet>>

    private var session: TranscriptSession?
    private var watcher: DirectoryWatcher?
    private var watchedPaths: [String] = []
    private var timers: [DispatchSourceTimer] = []
    private var isLive = false
    private var dirtyPaths: Set<String> = []
    private var needsRescan = false
    private var flushScheduled = false

    init(
        configuration: MonitorConfiguration,
        mailbox: SnapshotMailbox,
        subsets: Set<SourceSet> = [],
        pricing: PriceBook? = nil,
        wholeFileReadHook: (@Sendable (String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.pricing = pricing
        self.mailbox = mailbox
        self.subsets = OSAllocatedUnfairLock(initialState: subsets)
        self.wholeFileReadHook = wholeFileReadHook
    }

    /// An abandoned core (its owner released it without `stop()`) still releases its timers and stream.
    deinit {
        for timer in timers { timer.cancel() }
        watcher?.stop()
    }

    func start() {
        queue.async { [self] in bootstrap() }
    }

    /// Stops asynchronously; seeding in progress is abandoned at the next file boundary.
    func stop() {
        cancelled.withLock { $0 = true }
        queue.async { [self] in teardown() }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Replaces the requested source sets from any thread; a running monitor publishes them promptly.
    func setSubsets(_ sets: Set<SourceSet>) {
        let changed = subsets.withLock { current in
            guard current != sets else { return false }
            current = sets
            return true
        }
        guard changed else { return }
        queue.async { [weak self] in self?.publish() }
    }

    // MARK: - Lifecycle

    private func bootstrap() {
        guard !isCancelled else { return }
        let session = TranscriptSession(configuration: configuration, pricing: pricing)
        session.wholeFileReads = { [weak self] job in self?.scheduleWholeFileRead(job) }
        self.session = session
        guard session.hasAvailableRoot else {
            publishPlaceholder(.noSources, session: session)
            timers = [makeTimer(every: Self.rediscoveryInterval) { [weak self] in self?.retryBootstrap() }]
            return
        }
        seedAndGoLive(session)
    }

    private func retryBootstrap() {
        guard let session, !isLive else { return }
        session.refreshAvailability()
        guard session.hasAvailableRoot else { return }
        cancelTimers()
        seedAndGoLive(session)
    }

    private func seedAndGoLive(_ session: TranscriptSession) {
        let now = Date()
        let todayStartMs = Self.todayStartMs(for: now)
        let context = SnapshotContext(session: session, todayStartMs: todayStartMs)
        let mailbox = self.mailbox
        let gate = ProgressGate()
        mailbox.post(SnapshotBuilder.placeholder(state: .starting(progress: 0), context: context, now: now))

        let cancelled = self.cancelled
        _ = session.seed(
            todayStartMs: todayStartMs,
            progress: { value in
                guard gate.admit(value) else { return }
                mailbox.post(SnapshotBuilder.placeholder(state: .starting(progress: value), context: context, now: Date()))
            },
            isCancelled: { cancelled.withLock { $0 } }
        )
        guard !isCancelled else { return }
        // Seeding decodes hundreds of megabytes in parallel; hand the freed pages back instead of keeping them dirty.
        malloc_zone_pressure_relief(nil, 0)

        // Establish today's peak from the backlog so the first live tick cannot announce a stale record.
        let seededNow = Date()
        _ = session.advance(
            nowMs: Clock.milliseconds(seededNow), todayStartMs: Self.todayStartMs(for: seededNow), emitsEvents: false,
            subsets: subsets.withLock { $0 }
        )
        isLive = true
        updateWatcher()
        timers = [
            makeTimer(every: Self.publishInterval, leeway: .milliseconds(50)) { [weak self] in self?.publish() },
            makeTimer(every: Self.pollInterval, leeway: .milliseconds(100)) { [weak self] in self?.poll() },
            makeTimer(every: Self.rediscoveryInterval, leeway: .seconds(1)) { [weak self] in self?.rediscover() },
        ]
        publish()
    }

    private func teardown() {
        cancelTimers()
        watcher?.stop()
        watcher = nil
        watchedPaths = []
        session = nil
        isLive = false
    }

    // MARK: - Change handling

    private func handle(_ events: [DirectoryWatcher.Event]) {
        guard isLive else { return }
        for event in events {
            if event.needsRescan {
                needsRescan = true
            } else {
                dirtyPaths.insert(event.path)
            }
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.changeDebounce) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard let session, isLive else { return }
        var changed = false
        if needsRescan {
            needsRescan = false
            changed = session.rediscover(todayStartMs: Self.todayStartMs(for: Date()))
            updateWatcher()
        }
        let paths = dirtyPaths
        dirtyPaths.removeAll()
        changed = session.handleChanges(atCanonicalPaths: paths) || changed
        if changed { publish() }
    }

    private func scheduleWholeFileRead(_ job: WholeFileRead) {
        let hook = wholeFileReadHook
        wholeFileQueue.async { [weak self] in
            guard let self, !isCancelled else { return }
            hook?(job.path)
            let result = job.perform()
            queue.async { [weak self] in self?.finishWholeFileRead(result) }
        }
    }

    private func finishWholeFileRead(_ result: WholeFileResult) {
        guard let session, isLive else { return }
        if session.completeWholeFileRead(result) { publish() }
    }

    private func poll() {
        guard let session, isLive else { return }
        if session.pollRecentFiles(nowMs: Clock.milliseconds(Date())) { publish() }
    }

    private func rediscover() {
        guard let session, isLive else { return }
        let changed = session.rediscover(todayStartMs: Self.todayStartMs(for: Date()))
        updateWatcher()
        if changed { publish() }
    }

    private func publish() {
        guard let session, isLive else { return }
        session.readDirtyDatabases()
        let now = Date()
        let todayStartMs = Self.todayStartMs(for: now)
        let requested = subsets.withLock { $0 }
        let (output, events) = session.advance(
            nowMs: Clock.milliseconds(now), todayStartMs: todayStartMs, emitsEvents: true, subsets: requested
        )
        let context = SnapshotContext(session: session, todayStartMs: todayStartMs)
        mailbox.post(SnapshotBuilder.running(output, context: context), events: events)
    }

    private func publishPlaceholder(_ state: MonitorState, session: TranscriptSession) {
        let now = Date()
        let context = SnapshotContext(session: session, todayStartMs: Self.todayStartMs(for: now))
        mailbox.post(SnapshotBuilder.placeholder(state: state, context: context, now: now))
    }

    // MARK: - Helpers

    private func updateWatcher() {
        guard let session else { return }
        let paths = session.watchedPaths
        guard paths != watchedPaths || watcher == nil else { return }
        watcher?.stop()
        watcher = DirectoryWatcher(paths: paths, queue: queue, latency: Self.watcherLatency) { [weak self] events in
            self?.handle(events)
        }
        watchedPaths = watcher == nil ? [] : paths
    }

    private func makeTimer(
        every interval: DispatchTimeInterval,
        leeway: DispatchTimeInterval = .milliseconds(250),
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func cancelTimers() {
        for timer in timers { timer.cancel() }
        timers = []
    }

    /// Local midnight from the user's current calendar and time zone.
    static func todayStartMs(for date: Date) -> Int64 {
        Clock.milliseconds(Calendar.current.startOfDay(for: date))
    }
}

/// Lets seeding progress through in steps of at least 2 %.
private final class ProgressGate: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: 0.0)

    func admit(_ value: Double) -> Bool {
        last.withLock { last in
            guard value >= 1 || value - last >= 0.02 else { return false }
            last = value
            return true
        }
    }
}
