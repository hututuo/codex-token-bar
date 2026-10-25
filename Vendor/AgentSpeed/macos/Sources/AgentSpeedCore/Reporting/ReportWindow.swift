import Foundation

/// The instantaneous values of one tick (METRICS 11.2), read from a speed snapshot and the latest traffic snapshot.
public struct ReportSample: Equatable, Sendable {
    public struct Source: Equatable, Sendable {
        public var live: Rate
        public var liveEstimated: Rate
        public var liveCost: LiveCost

        public init(live: Rate = .zero, liveEstimated: Rate = .zero, liveCost: LiveCost = .zero) {
            self.live = live
            self.liveEstimated = liveEstimated
            self.liveCost = liveCost
        }
    }

    public var live: Rate
    public var estimatedShare: Double
    public var liveCost: LiveCost
    public var sources: [SourceKind: Source]
    public var facts: ReportLiveFacts
    public var traffic: ReportTrafficSample

    public init(
        live: Rate = .zero, estimatedShare: Double = 0, liveCost: LiveCost = .zero, sources: [SourceKind: Source] = [:],
        facts: ReportLiveFacts = .empty, traffic: ReportTrafficSample = .off
    ) {
        self.live = live
        self.estimatedShare = estimatedShare
        self.liveCost = liveCost
        self.sources = sources
        self.facts = facts
        self.traffic = traffic
    }

    /// From the app's snapshots: every enabled source together, never an orb's subset (METRICS 11.1).
    public init(snapshot: SpeedSnapshot, traffic: ReportTrafficSample) {
        var sources: [SourceKind: Source] = [:]
        for status in snapshot.sources where status.enabled {
            sources[status.kind] = Source(live: status.live, liveEstimated: status.liveEstimated, liveCost: status.liveCost)
        }
        self.init(live: snapshot.live, estimatedShare: snapshot.liveEstimatedShare, liveCost: snapshot.liveCost,
                  sources: sources, facts: snapshot.report, traffic: traffic)
    }

    /// The live value the title follows (`title.metric`).
    public func value(for metric: SpeedMetric) -> Double { live.value(for: metric) }

    var generating: Int { facts.agents.values.reduce(0) { $0 + $1.generating } }
    var tools: Int { facts.agents.values.reduce(0) { $0 + $1.tools } }
}

/// Traffic as live reporting reads it (METRICS 11.2): rates of the latest sample and cumulative bytes.
public struct ReportTrafficSample: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable { case ok, off, unavailable }

    public var status: Status
    public var includesTools: Bool
    /// Σ over sources of own (+ tools); nil while the series has fewer than two samples.
    public var rate: TrafficRate?
    public var sourceRates: [SourceKind: TrafficRate]
    /// Cumulative bytes of every source, disabled ones included, so a baseline stays valid across a toggle.
    public var totals: TrafficReportTotals
    /// The sources whose bytes are reported (METRICS 11.4: a disabled source reports no traffic).
    public var enabled: SourceSet

    public init(
        status: Status, includesTools: Bool = true, rate: TrafficRate? = nil, sourceRates: [SourceKind: TrafficRate] = [:],
        totals: TrafficReportTotals = .zero, enabled: SourceSet = .everything
    ) {
        self.status = status
        self.includesTools = includesTools
        self.rate = rate
        self.sourceRates = sourceRates
        self.totals = totals
        self.enabled = enabled
    }

    public static let off = ReportTrafficSample(status: .off)

    /// From the traffic snapshot and the `includeTools` setting, leaving out sources outside `enabled`.
    public init(snapshot: TrafficSnapshot, includeTools: Bool, enabled: SourceSet = .everything) {
        guard snapshot.enabled else {
            self = .off
            return
        }
        let processOK = snapshot.processState.isAvailable
        var rates: [SourceKind: TrafficRate] = [:]
        if processOK {
            for (kind, traffic) in snapshot.sources where enabled.contains(kind) {
                if let rate = traffic.live(includeTools: includeTools) { rates[kind] = rate }
            }
        }
        self.init(
            status: processOK ? .ok : .unavailable, includesTools: includeTools,
            rate: processOK ? snapshot.live(of: enabled, includeTools: includeTools) : nil, sourceRates: rates,
            totals: snapshot.reportTotals, enabled: enabled
        )
    }

    /// Agent bytes of the window: own plus tools of every source (own only without tools).
    func agentBytes(since baseline: TrafficReportTotals) -> [SourceKind: TrafficBytes] {
        var out: [SourceKind: TrafficBytes] = [:]
        for (kind, split) in totals.sources where enabled.contains(kind) {
            let before = baseline.sources[kind] ?? .zero
            let now = split.total(includeTools: includesTools)
            let then = before.total(includeTools: includesTools)
            let delta = TrafficBytes(rx: max(0, now.rx - then.rx), tx: max(0, now.tx - then.tx))
            if !delta.isZero { out[kind] = delta }
        }
        return out
    }
}

/// What a built report takes from its window (METRICS 11.4, 11.5): the deltas since the last build or discard and
/// the peaks of the ticks inside it.
public struct ReportWindowContent: Equatable, Sendable {
    public var usage: ReportCounters
    public var agentBytes: [SourceKind: TrafficBytes]
    public var peak: Rate
    public var peakCost: Double
    public var peakRate: TrafficRate?
}

/// The open window of a run: a baseline of the cumulative counters and the peaks since the window started.
public struct ReportWindow: Equatable, Sendable {
    private var baseline: ReportCounters
    private var trafficBaseline: TrafficReportTotals
    private var lastCounters: ReportCounters
    private var lastTraffic: TrafficReportTotals
    private var peak = Rate.zero
    private var peakCost = 0.0
    private var peakRate: TrafficRate?

    public init(_ sample: ReportSample) {
        baseline = sample.facts.counters
        trafficBaseline = sample.traffic.totals
        lastCounters = baseline
        lastTraffic = trafficBaseline
    }

    /// The ledger received a token increment since the previous tick (the activity rule of METRICS 11.5).
    public func hasTokenIncrement(_ sample: ReportSample) -> Bool {
        sample.facts.counters.since(lastCounters).byModel.values.contains { $0.hasTokens }
    }

    /// Empties the window. `keepingTick` keeps this tick's increments (the gap rule, METRICS 11.1).
    public mutating func discard(_ sample: ReportSample, keepingTick: Bool) {
        baseline = keepingTick ? lastCounters : sample.facts.counters
        trafficBaseline = keepingTick ? lastTraffic : sample.traffic.totals
        peak = .zero
        peakCost = 0
        peakRate = nil
    }

    /// Ends a tick: its values join the peaks unless the window started at this tick (`peaks` false), and it becomes
    /// the previous tick of the gap and activity rules.
    public mutating func observe(_ sample: ReportSample, peaks: Bool = true) {
        defer {
            lastCounters = sample.facts.counters
            lastTraffic = sample.traffic.totals
        }
        guard peaks else { return }
        peak.output = max(peak.output, sample.live.output)
        peak.total = max(peak.total, sample.live.total)
        peakCost = max(peakCost, sample.liveCost.microUsdPerSecond)
        peakRate = Self.larger(peakRate, sample.traffic.status == .ok ? sample.traffic.rate : nil)
    }

    /// The window's content as of `sample` (which it includes), without emptying it (the preview).
    public func content(_ sample: ReportSample) -> ReportWindowContent {
        var copy = self
        copy.observe(sample)
        return ReportWindowContent(
            usage: sample.facts.counters.since(baseline),
            agentBytes: sample.traffic.agentBytes(since: trafficBaseline),
            peak: copy.peak, peakCost: copy.peakCost, peakRate: copy.peakRate
        )
    }

    /// Builds: the content, then an empty window starting at `sample`.
    public mutating func take(_ sample: ReportSample) -> ReportWindowContent {
        let taken = content(sample)
        discard(sample, keepingTick: false)
        observe(sample, peaks: false)
        return taken
    }

    private static func larger(_ a: TrafficRate?, _ b: TrafficRate?) -> TrafficRate? {
        guard let b else { return a }
        guard let a else { return b }
        return TrafficRate(rx: Swift.max(a.rx, b.rx), tx: Swift.max(a.tx, b.tx))
    }
}
