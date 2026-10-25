import Foundation
import os

/// Keeps the daily history (METRICS 8) up to date in the background and publishes it to a `HistoryStore`.
///
/// Analysis runs on a private utility-QoS queue and never touches the live monitor: at `start()`, every 10 minutes,
/// shortly after local midnight, on `refresh()` and after `clear()`. When `liveStore` is given, the live monitor's
/// `peakToday` is recorded as the day's peak.
@MainActor
public final class HistoryService {
    public nonisolated static let refreshInterval: TimeInterval = 600
    static let peakSampleInterval: TimeInterval = 10

    public private(set) var configuration: MonitorConfiguration
    public let storeURL: URL
    /// Shared with the live engine (METRICS 9.7).
    public let pricing: PriceBook
    private let store: HistoryStore
    private weak var liveStore: SpeedStore?
    private var worker: HistoryWorker?
    private var peakTimer: Timer?
    private var recordedPeak: (day: String, value: Double)?

    public init(
        store: HistoryStore,
        configuration: MonitorConfiguration = MonitorConfiguration(),
        liveStore: SpeedStore? = nil,
        storeURL: URL = HistoryService.defaultStoreURL,
        pricing: PriceBook = PriceBook()
    ) {
        self.store = store
        self.configuration = configuration
        self.liveStore = liveStore
        self.storeURL = storeURL
        self.pricing = pricing
    }

    /// `~/Library/Application Support/AgentSpeed/history.sqlite`. Debug builds use `history.sqlite` in the folder
    /// named by `AGENT_SPEED_SUPPORT_DIR` instead when it is set and not empty; release builds ignore it.
    public nonisolated static var defaultStoreURL: URL {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["AGENT_SPEED_SUPPORT_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("history.sqlite")
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("AgentSpeed", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    /// True between `start()` and `stop()`.
    public var isRunning: Bool { worker != nil }

    /// Loads the day bindings and table copies of the store into `book` (a quick read that never changes the store),
    /// before the live engine prices anything (METRICS 9.7).
    public nonisolated static func restorePricing(into book: PriceBook, storeURL: URL = defaultStoreURL) {
        let stored = HistoryDatabase.storedPricing(at: storeURL.path)
        let repaired = book.restore(bindings: stored.bindings, tables: stored.tables)
        if !repaired.isEmpty {
            PricingLog.logger.notice("Price bindings without a valid table rebound to the current table: \(repaired.count, privacy: .public)")
        }
    }

    public func start() {
        guard worker == nil else { return }
        let worker = HistoryWorker(storePath: storeURL.path, configuration: configuration, pricing: pricing) { [weak store] state, days in
            store?.publish(state: state, days: days)
        }
        self.worker = worker
        store.refreshHandler = { [weak self] showsProgress in self?.refresh(showsProgress: showsProgress) }
        store.clearHandler = { [weak self] in self?.clear() }
        worker.start()
        if liveStore != nil {
            let timer = Timer(timeInterval: Self.peakSampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.samplePeak() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            peakTimer = timer
        }
    }

    public func stop() {
        samplePeak()
        peakTimer?.invalidate()
        peakTimer = nil
        pricing.setBindingObserver(nil)
        worker?.stop()
        worker = nil
    }

    /// Applies new settings; the logs are analysed again when the roots or the enabled sources change.
    public func update(configuration: MonitorConfiguration) {
        let changed = configuration.requiresRescan(comparedTo: self.configuration)
        self.configuration = configuration
        guard changed else { return }
        worker?.update(configuration: configuration)
    }

    /// Analyses new and changed logs now; without `showsProgress`, only a large run reports `.analyzing`.
    public func refresh(showsProgress: Bool = true) {
        worker?.requestRun(visible: showsProgress)
    }

    /// Deletes the store and analyses the current logs from scratch.
    public func clear() {
        recordedPeak = nil
        worker?.clear()
    }

    /// Records the live monitor's `peakToday` for its local day when it rose.
    func samplePeak() {
        guard let worker, let snapshot = liveStore?.liveSnapshot, snapshot.state == .running else { return }
        let peak = snapshot.peakToday.output
        guard peak > 0, peak.isFinite else { return }
        let day = DayLabeler(timeZone: .current).label(for: snapshot.timestamp)
        if let recordedPeak, recordedPeak.day == day, peak <= recordedPeak.value { return }
        recordedPeak = (day, peak)
        worker.recordPeak(peak, day: day)
    }
}

/// The history service's background half. Everything mutable is confined to `queue`, except the run request and
/// generation, which are locked.
final class HistoryWorker: @unchecked Sendable {
    typealias Publisher = @MainActor @Sendable (HistoryState, [DailyUsage]?) -> Void

    /// Runs touching at least this much are shown as `.analyzing` even when they were not asked for.
    static let visibleRunBytes: Int64 = 256 << 20
    static let visibleRunFiles = 64
    static let progressIntervalNs: UInt64 = 250_000_000
    static let daysIntervalNs: UInt64 = 1_000_000_000
    static let midnightDelay: TimeInterval = 5

    private struct Control {
        var stopped = false
        /// Bumped by `clear()`; a run of an older generation stops at the next file.
        var generation = 0
        /// `clear()` calls whose queue block has not run yet; runs queued before them are skipped.
        var pendingClears = 0
        /// A queued run, and whether it shows progress.
        var requested: Bool?
    }

    private let storePath: String
    private let pricing: PriceBook
    private let publisher: Publisher
    /// A binding save is queued (bindings arrive in bursts while a day's responses are priced).
    private let bindingSaveQueued = OSAllocatedUnfairLock(initialState: false)
    private let queue = DispatchQueue(label: "app.agentspeed.history", qos: .utility)
    private let control = OSAllocatedUnfairLock(initialState: Control())

    private var configuration: MonitorConfiguration
    private var analyzer: HistoryAnalyzer?
    private var periodicTimer: DispatchSourceTimer?
    private var midnightTimer: DispatchSourceTimer?
    private var lastState: HistoryState = .notLoaded

    init(storePath: String, configuration: MonitorConfiguration, pricing: PriceBook, publisher: @escaping Publisher) {
        self.storePath = storePath
        self.configuration = configuration
        self.pricing = pricing
        self.publisher = publisher
    }

    deinit {
        periodicTimer?.cancel()
        midnightTimer?.cancel()
    }

    func start() {
        pricing.setBindingObserver { [weak self] in self?.requestBindingSave() }
        queue.async { [self] in
            guard openAnalyzer() != nil else { return }
            post(.analyzing(progress: 0, filesDone: 0, filesTotal: 0), days: true)
            scheduleTimers()
        }
        requestRun(visible: true)
    }

    /// Saves new day bindings (the live engine binds today) soon, once per burst.
    private func requestBindingSave() {
        let enqueue = bindingSaveQueued.withLock { queued -> Bool in
            defer { queued = true }
            return !queued
        }
        guard enqueue else { return }
        queue.async { [self] in
            bindingSaveQueued.withLock { $0 = false }
            try? analyzer?.saveBindings()
        }
    }

    func stop() {
        control.withLock { $0.stopped = true }
        queue.async { [self] in
            periodicTimer?.cancel()
            midnightTimer?.cancel()
            periodicTimer = nil
            midnightTimer = nil
            analyzer = nil
        }
    }

    func update(configuration: MonitorConfiguration) {
        queue.async { [self] in
            self.configuration = configuration
            if analyzer != nil { post(lastState, days: true) }
        }
        requestRun(visible: true)
    }

    func clear() {
        control.withLock { control in
            control.generation += 1
            control.pendingClears += 1
        }
        queue.async { [self] in
            control.withLock { $0.pendingClears -= 1 }
            analyzer = nil
            pricing.clearBindings()
            HistoryDatabase.delete(at: storePath)
            guard openAnalyzer() != nil else { return }
            post(.analyzing(progress: 0, filesDone: 0, filesTotal: 0), days: true)
            perform(visible: true)
        }
    }

    func recordPeak(_ peak: Double, day: String) {
        queue.async { [self] in
            guard let analyzer, (try? analyzer.recordPeak(peak, day: day)) == true else { return }
            post(lastState, days: true)
        }
    }

    /// Coalesces requests: at most one run is queued behind the current one.
    func requestRun(visible: Bool) {
        let enqueue = control.withLock { control -> Bool in
            guard !control.stopped else { return false }
            let alreadyQueued = control.requested != nil
            control.requested = (control.requested ?? false) || visible
            return !alreadyQueued
        }
        guard enqueue else { return }
        queue.async { [self] in
            let visible = control.withLock { control -> Bool? in
                defer { control.requested = nil }
                return control.requested
            }
            guard let visible else { return }
            perform(visible: visible)
        }
    }

    // MARK: - Queue

    private var isStopped: Bool { control.withLock { $0.stopped } }

    @discardableResult
    private func openAnalyzer() -> HistoryAnalyzer? {
        if let analyzer { return analyzer }
        guard !isStopped else { return nil }
        do {
            analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: storePath), pricing: pricing)
        } catch {
            // An unreadable or newer store is left untouched; this launch keeps its history in memory.
            analyzer = try? HistoryAnalyzer(database: HistoryDatabase.inMemory(), pricing: pricing)
        }
        if analyzer == nil { post(.failed("The history store could not be opened."), days: false) }
        return analyzer
    }

    private func perform(visible: Bool) {
        let (stopped, clearing, generation) = control.withLock { ($0.stopped, $0.pendingClears > 0, $0.generation) }
        guard !stopped, !clearing, let analyzer = openAnalyzer() else { return }
        let isCancelled = { [control] in control.withLock { $0.stopped || $0.generation != generation } }
        var announced = visible
        var lastProgress: UInt64 = 0
        var lastDays: UInt64 = 0
        do {
            let report = try analyzer.run(configuration: configuration, isCancelled: isCancelled) { progress in
                if !announced, progress.bytesTotal >= Self.visibleRunBytes || progress.filesTotal >= Self.visibleRunFiles {
                    announced = true
                }
                guard announced else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                guard progress.filesDone == 0 || now - lastProgress >= Self.progressIntervalNs else { return }
                lastProgress = now
                let withDays = progress.filesDone > 0 && now - lastDays >= Self.daysIntervalNs
                if withDays { lastDays = now }
                post(.analyzing(progress: progress.fraction, filesDone: progress.filesDone, filesTotal: progress.filesTotal),
                     days: withDays)
            }
            guard !report.cancelled else { return }
            post(.ready(updatedAt: Date()), days: true)
            if report.bytesAnalyzed >= Self.visibleRunBytes { malloc_zone_pressure_relief(nil, 0) }
        } catch {
            post(.failed("The usage history could not be updated."), days: true)
        }
    }

    private func post(_ state: HistoryState, days includeDays: Bool) {
        lastState = state
        let days = includeDays ? analyzer?.days(sources: configuration.enabledSources) : nil
        let publisher = self.publisher
        let control = self.control
        DispatchQueue.main.async {
            guard !control.withLock({ $0.stopped }) else { return }
            MainActor.assumeIsolated { publisher(state, days) }
        }
    }

    private func scheduleTimers() {
        let periodic = DispatchSource.makeTimerSource(queue: queue)
        periodic.schedule(wallDeadline: .now() + HistoryService.refreshInterval, repeating: HistoryService.refreshInterval,
                          leeway: .seconds(30))
        periodic.setEventHandler { [weak self] in self?.requestRun(visible: false) }
        periodic.resume()
        periodicTimer = periodic
        scheduleMidnight()
    }

    /// A one-shot wall-clock timer shortly after the next local midnight; it re-arms itself.
    private func scheduleMidnight() {
        midnightTimer?.cancel()
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let delay = max(1, tomorrow.timeIntervalSince(now) + Self.midnightDelay)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now() + delay, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, !isStopped else { return }
            requestRun(visible: false)
            scheduleMidnight()
        }
        timer.resume()
        midnightTimer = timer
    }
}
