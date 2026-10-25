import Darwin
import Foundation
import os

/// Runs traffic sampling on a private serial queue (METRICS 10): a 1 Hz tick reads the machine counters, refreshes the
/// process table, applies the newest nettop sample, publishes a snapshot and keeps the stored days.
///
/// `@unchecked Sendable`: every mutable property is only touched on `queue`.
final class TrafficCore: @unchecked Sendable {
    typealias SnapshotPublisher = @MainActor @Sendable (TrafficSnapshot) -> Void
    typealias DaysPublisher = @MainActor @Sendable ([TrafficDay], String?) -> Void

    static let tickInterval: DispatchTimeInterval = .seconds(1)
    /// While nettop is stopped the table is only needed to notice agent processes (METRICS 10.10).
    static let standbyTableRefreshMs: Int64 = 2000
    /// A tick this late (sleep, a stalled queue) restarts nettop's stall clock instead of counting as a failure.
    static let resumeGapMs: Int64 = 5000

    let queue = DispatchQueue(label: "app.agentspeed.traffic", qos: .utility)
    private let platform: TrafficPlatform
    private let mailbox: TrafficMailbox
    private let daysPublisher: DaysPublisher

    private var enabled = false
    private var timer: DispatchSourceTimer?
    private var engine: TrafficEngine
    private let processReader = ProcessReader()
    private let machineReader = MachineCounterReader()
    private lazy var interfaceList = CountedInterfaceList(queue: queue)
    private lazy var sampler = NettopSampler(queue: queue, clock: Self.monotonicMs)
    private var history: TrafficHistoryKeeper

    private var agents: [TrafficAgent] = []
    private var detailDemand = false
    private var forcedInterval: Int?
    private var stream = 0
    private var streamStartUs: Int64 = 0
    private var lastTableRefreshMs: Int64?
    private var lastIntervalChangeMs: Int64?
    private var lastTickMs: Int64?
    private var lastActiveWallMs: Int64?
    private var standby = false
    /// A sample arrived since sampling began or since the last failure: a cadence restart still reads as running.
    private var hasSampled = false
    private var lastDay: String?
    /// Diagnostics.
    private var ticks = 0
    private var firstTickNanos: UInt64 = 0
    private var tickNanos: UInt64 = 0

    init(storePath: String, platform: TrafficPlatform = .current, publish: @escaping SnapshotPublisher,
         publishDays: @escaping DaysPublisher) {
        self.platform = platform
        mailbox = TrafficMailbox(delivery: publish)
        daysPublisher = publishDays
        engine = TrafficEngine(platform: platform)
        history = TrafficHistoryKeeper(storePath: storePath)
    }

    deinit {
        timer?.cancel()
    }

    static func monotonicMs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }

    static func wallMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    // MARK: - Commands (any thread)

    func start(enabled: Bool) {
        queue.async { [self] in
            history.load()
            history.deferWrites(nowMs: Self.monotonicMs())
            publishDays(force: true)
            setEnabledOnQueue(enabled)
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in setEnabledOnQueue(enabled) }
    }

    func update(agents list: [AgentStatus]) {
        let converted = list.map(TrafficAgent.init)
        queue.async { [self] in
            guard converted != agents else { return }
            agents = converted
            engine.setAgents(converted)
        }
    }

    func setDetailDemand(_ shown: Bool) {
        queue.async { [self] in detailDemand = shown }
    }

    /// Diagnostics: a fixed nettop interval (0 forces standby); nil restores the adaptive cadence.
    func setForcedInterval(_ interval: Int?) {
        queue.async { [self] in forcedInterval = interval }
    }

    func retry() {
        queue.async { [self] in
            sampler.retry()
            stream += 1
            streamStartUs = Self.wallMs() * 1000
            hasSampled = false
        }
    }

    /// Synchronous: no write is in flight when it returns and today starts over.
    func clearHistory() {
        queue.sync {
            let now = Self.monotonicMs()
            engine.resetToday()
            if let day = engine.currentDay { engine.dropDays(except: [day]) }
            history.clear(nowMs: now)
            publishDays(force: true)
        }
    }

    /// Synchronous write of today's totals (before sleep).
    func flush() {
        queue.sync { writeToday() }
    }

    /// Synchronous: final write, child killed and reaped, timer stopped.
    func stop() {
        queue.sync {
            if enabled { writeToday() }
            enabled = false
            timer?.cancel()
            timer = nil
            sampler.stop()
            mailbox.close()
        }
    }

    // MARK: - Queue

    private func setEnabledOnQueue(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            begin()
        } else {
            writeToday()
            timer?.cancel()
            timer = nil
            sampler.stop()
            mailbox.post(.off)
        }
    }

    /// A fresh engine and a new stream; today's totals come back from the store (METRICS 10.4.3, 10.8).
    private func begin() {
        engine = TrafficEngine(platform: platform)
        engine.setAgents(agents)
        let wall = Self.wallMs()
        var ledger = engine.ledger
        let today = ledger.label(forMs: wall)
        engine.restore(day: today, rows: history.storedRows(of: today))
        lastDay = today
        stream += 1
        streamStartUs = wall * 1000
        lastTableRefreshMs = nil
        lastIntervalChangeMs = nil
        lastTickMs = nil
        lastActiveWallMs = wall
        standby = false
        hasSampled = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard enabled else { return }
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let t = Self.monotonicMs()
        let wall = Self.wallMs()
        if let lastTickMs, t - lastTickMs > Self.resumeGapMs { sampler.resumeAfterGap() }
        lastTickMs = t

        let refreshTable = !standby || lastTableRefreshMs.map { t - $0 >= Self.standbyTableRefreshMs } ?? true
        if refreshTable {
            engine.table.refresh(processReader.list(nowMs: t), inspector: processReader, nowMs: t)
            lastTableRefreshMs = t
        }
        applyCadence(t: t, wall: wall)
        sampler.poll()
        if sampler.takeStreamBreak() {
            stream += 1
            streamStartUs = wall * 1000
            hasSampled = false
        }

        var counters: CounterSample?
        if standby {
            counters = CounterSample(stream: stream, streamStartUs: streamStartUs, rows: [], isStandby: true)
        } else if let rows = sampler.takeSample() {
            hasSampled = true
            let mapped = rows.compactMap { row -> CounterSample.Row? in
                guard let identity = engine.table.identity(forPid: row.pid) else { return nil }
                return CounterSample.Row(identity: identity, counter: TrafficCounter(rx: row.rx, tx: row.tx))
            }
            counters = CounterSample(stream: stream, streamStartUs: streamStartUs, rows: mapped)
        }
        let interfaces = machineReader.read(counted: interfaceList.current(nowMs: t))
        engine.tick(TrafficSample(t: t, wallMs: wall, processes: nil, interfaces: interfaces, counters: counters),
                    inspector: processReader)

        persist(t: t)
        mailbox.post(TrafficSnapshotBuilder.snapshot(engine: engine, wallMs: wall, state: processState))
        let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started
        if ticks == 0 { firstTickNanos = spent } else { tickNanos += spent }
        ticks += 1
    }

    private func applyCadence(t: Int64, wall: Int64) {
        if let active = TrafficCadence.lastActive(agents, nowWallMs: wall), active > (lastActiveWallMs ?? .min) {
            lastActiveWallMs = active
        }
        let desired = TrafficCadence.desiredInterval(
            hasAgentProcess: engine.table.hasAgentProcess, lastActiveWallMs: lastActiveWallMs, nowWallMs: wall,
            detailDemand: detailDemand, forced: forcedInterval)
        guard let desired else {
            if !standby {
                standby = true
                sampler.stop()
            }
            return
        }
        standby = false
        let running = sampler.status == .idle ? nil : sampler.interval
        guard TrafficCadence.shouldApply(desired: desired, current: running, lastChangeMs: lastIntervalChangeMs, nowMs: t,
                                         forced: forcedInterval != nil) else { return }
        lastIntervalChangeMs = t
        sampler.run(interval: desired)
    }

    private var processState: ProcessTrafficState {
        if sampler.status == .unavailable { return .unavailable(.sampler) }
        if standby { return .standby }
        let interval = sampler.interval ?? TrafficCadence.fastInterval
        switch sampler.status {
        case .sampling: return .running(interval: interval)
        case .starting where hasSampled: return .running(interval: interval)
        default: return .starting
        }
    }

    // MARK: - Days

    private func persist(t: Int64) {
        guard let day = engine.currentDay else { return }
        if let lastDay, lastDay != day {
            // The finished day's final rows, then today's (METRICS 10.9 writes at the day change).
            var rows = engine.ledger.totals(lastDay)?.rows(day: lastDay) ?? []
            rows += todayRows()
            history.write(rows, nowMs: t)
            engine.dropDays(except: [day])
            self.lastDay = day
            publishDays(force: true)
            return
        }
        lastDay = day
        if history.isWriteDue(nowMs: t) { writeToday() }
        publishDays(force: false)
    }

    private func todayRows() -> [TrafficDay] {
        guard let day = engine.currentDay, let totals = engine.ledger.totals(day) else { return [] }
        return totals.rows(day: day)
    }

    private func writeToday() {
        history.write(todayRows(), nowMs: Self.monotonicMs())
    }

    private func publishDays(force: Bool) {
        var ledger = engine.ledger
        let today = engine.currentDay ?? ledger.label(forMs: Self.wallMs())
        guard let published = history.daysToPublish(today: today, rows: todayRows(), nowMs: Self.monotonicMs(), force: force)
        else { return }
        let publisher = daysPublisher
        DispatchQueue.main.async { MainActor.assumeIsolated { publisher(published.0, published.1) } }
    }

    // MARK: - Diagnostics

    func diagnostics() -> TrafficDiagnostics {
        queue.sync {
            let records = engine.table.records.values.filter { $0.processClass != nil }.sorted { $0.entry.identity < $1.entry.identity }
            let processes = records.map { record in
                TrafficDiagnostics.Process(
                    pid: record.entry.pid, executable: record.executable,
                    source: record.processClass!.source, role: record.processClass!.role.rawValue,
                    rootPid: record.processClass!.root.pid, alive: record.alive)
            }
            let roots = engine.rootTotals.sorted { $0.key < $1.key }.map { identity, totals in
                TrafficDiagnostics.Root(
                    pid: identity.pid, source: engine.table.processClass(of: identity)?.source,
                    workingDirectory: engine.table.workingDirectory(of: identity, inspector: processReader),
                    own: totals.split.own, tools: totals.split.tools,
                    assigned: totals.assigned.mapValues { $0.own + $0.tools })
            }
            return TrafficDiagnostics(
                processes: processes, roots: roots, tableSize: engine.table.records.count,
                countedInterfaces: interfaceList.names.sorted(), interfaceListReads: interfaceList.refreshes, nettopPid: sampler.childPid,
                nettopInterval: sampler.interval, nettopLaunches: sampler.launches, samples: sampler.samplesCompleted,
                ticks: ticks, firstTickMicros: Double(firstTickNanos) / 1000,
                averageTickMicros: ticks > 1 ? Double(tickNanos) / Double(ticks - 1) / 1000 : 0,
                nettopReadMicros: Double(sampler.readNanos) / 1000)
        }
    }
}

/// What the probe prints about attribution and cost.
public struct TrafficDiagnostics: Sendable {
    public struct Process: Sendable {
        public var pid: Int32
        public var executable: String
        public var source: SourceKind
        /// `agent`, `self` or `tool`.
        public var role: String
        public var rootPid: Int32
        public var alive: Bool
    }

    /// Bytes of one root agent process since sampling started and the agent trees they went to ("" = unassigned).
    public struct Root: Sendable {
        public var pid: Int32
        public var source: SourceKind?
        public var workingDirectory: String?
        public var own: TrafficBytes
        public var tools: TrafficBytes
        public var assigned: [String: TrafficBytes]
    }

    public var processes: [Process]
    public var roots: [Root]
    public var tableSize: Int
    /// BSD names whose bytes are machine traffic (METRICS 10.2).
    public var countedInterfaces: [String]
    public var interfaceListReads: Int
    public var nettopPid: Int32?
    public var nettopInterval: Int?
    public var nettopLaunches: Int
    public var samples: Int
    public var ticks: Int
    /// Thread CPU time of the first tick (every process's path is read once).
    public var firstTickMicros: Double
    /// Thread CPU time per later tick.
    public var averageTickMicros: Double
    /// Thread CPU time spent reading and parsing nettop's output in total.
    public var nettopReadMicros: Double
}

/// Hands snapshots to the main actor, newest wins.
final class TrafficMailbox: Sendable {
    typealias Delivery = @MainActor @Sendable (TrafficSnapshot) -> Void

    private struct State: Sendable {
        var snapshot: TrafficSnapshot?
        var scheduled = false
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let delivery: Delivery

    init(delivery: @escaping Delivery) {
        self.delivery = delivery
    }

    func post(_ snapshot: TrafficSnapshot) {
        let schedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.snapshot = snapshot
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { drain() } }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.snapshot = nil
        }
    }

    @MainActor
    private func drain() {
        let snapshot = state.withLock { state -> TrafficSnapshot? in
            defer {
                state.snapshot = nil
                state.scheduled = false
            }
            return state.closed ? nil : state.snapshot
        }
        if let snapshot { delivery(snapshot) }
    }
}
