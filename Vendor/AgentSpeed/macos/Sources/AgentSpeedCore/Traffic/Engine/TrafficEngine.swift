import Foundation

/// One process-counter sample (METRICS 10.3, 10.4).
struct CounterSample: Sendable {
    struct Row: Equatable, Sendable {
        var identity: ProcessIdentity
        var counter: TrafficCounter
    }

    /// A different stream starts over (every process a baseline) unless `continues` (an interval restart, 10.4.7).
    var stream: Int
    var continues = false
    /// When sampling of this stream began; in its first sample only processes started by then are baselines, later
    /// ones are new. Nil: the sample's own time.
    var streamStartUs: Int64?
    var rows: [Row]
    /// No agent process exists, so the sampler is stopped and every source's traffic is a real zero (METRICS 10.10):
    /// the interval counts as sampled and the series get zeros, but baselines are neither used nor aged.
    var isStandby = false
}

/// One tick (METRICS 10.4.1). `t` is monotonic (deltas, rates, gaps); `wallMs` names the local date, the history
/// buckets and the agent activity window.
struct TrafficSample: Sendable {
    var t: Int64
    var wallMs: Int64
    /// Nil when the process table was not refreshed this tick.
    var processes: [ProcessEntry]?
    /// Counted interfaces' cumulative counters; nil when they were not read.
    var interfaces: [String: TrafficCounter]?
    var counters: CounterSample?
}

/// The sampler-independent traffic core (METRICS 10.4–10.9): deltas, attribution, live rates, history buckets, today.
final class TrafficEngine {
    static let gapMs: Int64 = 15_000

    let platform: TrafficPlatform
    let table: ProcessTable
    private(set) var trees = AgentTrees()
    private(set) var ledger: TrafficLedger
    private(set) var currentDay: String?

    private var previousT: Int64?
    private var interfaces: [String: TrafficCounter] = [:]
    private var stream: Int?
    private var streamStartUs: Int64 = 0
    private var awaitingFirstSample = false
    private var baselines = CounterBaselines()
    private var previousCounterT: Int64?
    private(set) var machineSeries = TrafficSeries()
    private(set) var machineBuckets = TrafficBuckets()
    private(set) var sourceSeries: [SourceKind: TrafficSeriesPair] = [:]
    private(set) var sourceBuckets: [SourceKind: TrafficBuckets] = [:]
    private(set) var agentSeries: [String: TrafficSeriesPair] = [:]
    /// Bytes for live reporting since the engine started, without gap samples (METRICS 11.4).
    private(set) var reportTotals = TrafficReportTotals()
    /// Counted interfaces that were up at the latest machine sample (METRICS 11.2: none → `unavailable`).
    private(set) var machineInterfaceCount = 0
    /// Diagnostics: bytes per root agent process since the engine started, and the trees they went to ("" = none).
    private(set) var rootTotals: [ProcessIdentity: (split: TrafficSplit, assigned: [String: TrafficSplit])] = [:]

    init(platform: TrafficPlatform, timeZone: TimeZone = .current) {
        self.platform = platform
        table = ProcessTable(platform: platform)
        ledger = TrafficLedger(timeZone: timeZone)
    }

    func setAgents(_ agents: [TrafficAgent]) {
        trees.replace(agents)
        let roots = Set(trees.roots)
        agentSeries = agentSeries.filter { roots.contains($0.key) }
    }

    /// Today's restored totals (METRICS 10.8), before the first tick.
    func restore(day: String, rows: [TrafficDay]) {
        ledger.restore(day, rows: rows)
    }

    /// "Clear history": today starts over at zero.
    func resetToday() {
        if let currentDay { ledger.reset(currentDay) }
    }

    /// Keeps only today in memory once older days are stored.
    func dropDays(except keep: Set<String>) {
        ledger.drop(except: keep)
    }

    func tick(_ sample: TrafficSample, inspector: ProcessInspector) {
        let t = sample.t
        let dt = previousT.map { t - $0 }
        let gap = dt.map { $0 > Self.gapMs } ?? true
        previousT = t
        if let processes = sample.processes {
            table.refresh(processes, inspector: inspector, nowMs: t)
        }
        let day = ledger.label(forMs: sample.wallMs)
        currentDay = day
        ledger.modify(day) { _ in }

        if let current = sample.interfaces {
            var sum = TrafficBytes.zero
            for (name, counter) in current {
                if let previous = interfaces[name] { sum += CounterDelta.delta(from: previous, to: counter, intervalMs: dt) }
            }
            interfaces = current
            machineInterfaceCount = current.count
            ledger.modify(day) { totals in
                totals.machine += sum
                if let dt, dt <= Self.gapMs { totals.machineSampledMs += dt }
            }
            machineSeries.add(t: t, bytes: sum, gap: gap)
            if !gap, let dt { machineBuckets.add(wallMs: sample.wallMs, intervalMs: dt, bytes: sum) }
        }

        if let counters = sample.counters {
            apply(counters, t: t, wallMs: sample.wallMs, day: day, inspector: inspector)
        }
    }

    private func apply(_ counters: CounterSample, t: Int64, wallMs: Int64, day: String, inspector: ProcessInspector) {
        let dt = previousCounterT.map { t - $0 }
        let gap = dt.map { $0 > Self.gapMs } ?? true
        previousCounterT = t
        let newStream = counters.stream != stream && !counters.continues
        stream = counters.stream
        if newStream {
            baselines.reset()
            awaitingFirstSample = true
            streamStartUs = counters.streamStartUs ?? t * 1000
        }
        if let dt, dt <= Self.gapMs, !newStream {
            ledger.modify(day) { $0.processSampledMs += dt }
        }
        guard !counters.isStandby else {
            record(sources: [:], agents: [:], t: t, wallMs: wallMs, dt: dt, gap: gap)
            return
        }
        let firstSample = awaitingFirstSample
        awaitingFirstSample = false

        var perRoot: [ProcessIdentity: (source: SourceKind, split: TrafficSplit)] = [:]
        var seen: Set<ProcessIdentity> = []
        seen.reserveCapacity(counters.rows.count)
        for row in counters.rows {
            guard let record = table.record(row.identity) else { continue }
            seen.insert(row.identity)
            let delta: TrafficBytes
            if let previous = baselines.value(row.identity) {
                delta = CounterDelta.delta(from: previous, to: row.counter, intervalMs: dt)
            } else if firstSample, record.entry.startUs <= streamStartUs {
                delta = .zero
            } else {
                delta = TrafficBytes(rx: row.counter.rx, tx: row.counter.tx)
            }
            baselines.set(row.identity, row.counter)
            guard let processClass = record.processClass, !delta.isZero else { continue }
            var entry = perRoot[processClass.root] ?? (processClass.source, .zero)
            if processClass.role == .tool { entry.split.tools += delta } else { entry.split.own += delta }
            perRoot[processClass.root] = entry
        }
        baselines.age(seen: seen)

        let startMs = wallMs - (dt ?? 0)
        var sourceTotals: [SourceKind: TrafficSplit] = [:]
        var agentTotals: [String: TrafficSplit] = [:]
        for (root, entry) in perRoot {
            let split = entry.split
            sourceTotals[entry.source, default: .zero].add(split)
            if !gap { reportTotals.sources[entry.source, default: .zero].add(split) }
            let candidates = trees.candidates(
                source: entry.source, startMs: startMs, endMs: wallMs, platform: platform,
                openFiles: { self.openFiles(ofRoot: root, inspector: inspector, nowMs: t) },
                workingDirectory: { self.table.workingDirectory(of: root, inspector: inspector) })
            ledger.modify(day) { totals in
                totals.sources[entry.source, default: SourceDayTraffic()].split.add(split)
                if candidates.count == 1 {
                    totals.agents[candidates[0], default: .zero].add(split)
                } else {
                    totals.sources[entry.source]?.unassigned += split.own + split.tools
                }
            }
            if candidates.count == 1 { agentTotals[candidates[0], default: .zero].add(split) }
            var totals = rootTotals[root] ?? (.zero, [:])
            totals.split.add(split)
            totals.assigned[candidates.count == 1 ? candidates[0] : "", default: .zero].add(split)
            rootTotals[root] = totals
        }
        record(sources: sourceTotals, agents: agentTotals, t: t, wallMs: wallMs, dt: dt, gap: gap)
    }

    private func record(sources: [SourceKind: TrafficSplit], agents: [String: TrafficSplit], t: Int64, wallMs: Int64,
                        dt: Int64?, gap: Bool) {
        for source in SourceKind.allCases {
            let split = sources[source] ?? .zero
            sourceSeries[source, default: TrafficSeriesPair()].add(t: t, split: split, gap: gap)
            if !gap, let dt {
                sourceBuckets[source, default: TrafficBuckets()].add(wallMs: wallMs, intervalMs: dt, bytes: split.own + split.tools)
            }
        }
        for root in trees.roots {
            agentSeries[root, default: TrafficSeriesPair()].add(t: t, split: agents[root] ?? .zero, gap: gap)
        }
    }

    private func openFiles(ofRoot root: ProcessIdentity, inspector: ProcessInspector, nowMs: Int64) -> Set<String> {
        var files: Set<String> = []
        for member in table.members[root] ?? [] {
            guard let record = table.record(member), record.alive else { continue }
            for path in inspector.openFiles(of: record.entry, nowMs: nowMs) { files.insert(platform.normalize(path)) }
        }
        return files
    }

    // MARK: - Reading

    var machineRate: TrafficRate? { machineSeries.rate }

    func today() -> TrafficDayTotals {
        currentDay.flatMap { ledger.totals($0) } ?? TrafficDayTotals()
    }
}

extension TrafficSplit {
    mutating func add(_ other: TrafficSplit) {
        own += other.own
        tools += other.tools
    }
}
