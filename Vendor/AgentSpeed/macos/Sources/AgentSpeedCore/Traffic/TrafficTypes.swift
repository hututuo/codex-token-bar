import Foundation

/// Bytes per second, download (`rx`) and upload (`tx`) (METRICS 10.1, 10.7).
public struct TrafficRate: Equatable, Sendable {
    public var rx: Double
    public var tx: Double

    public init(rx: Double = 0, tx: Double = 0) {
        self.rx = rx
        self.tx = tx
    }

    public var sum: Double { rx + tx }

    public static let zero = TrafficRate()

    public static func + (lhs: TrafficRate, rhs: TrafficRate) -> TrafficRate {
        TrafficRate(rx: lhs.rx + rhs.rx, tx: lhs.tx + rhs.tx)
    }
}

/// Bytes, download (`rx`) and upload (`tx`).
public struct TrafficBytes: Equatable, Hashable, Sendable {
    public var rx: Int64
    public var tx: Int64

    public init(rx: Int64 = 0, tx: Int64 = 0) {
        self.rx = rx
        self.tx = tx
    }

    public var sum: Int64 { rx + tx }
    public var isZero: Bool { rx == 0 && tx == 0 }

    public static let zero = TrafficBytes()

    public static func + (lhs: TrafficBytes, rhs: TrafficBytes) -> TrafficBytes {
        TrafficBytes(rx: lhs.rx + rhs.rx, tx: lhs.tx + rhs.tx)
    }

    public static func += (lhs: inout TrafficBytes, rhs: TrafficBytes) {
        lhs = lhs + rhs
    }
}

/// Bytes of a source or agent, split into its own agent processes (`own`) and the tool processes they run (`tools`)
/// (METRICS 10.1, 10.5).
public struct TrafficSplit: Equatable, Sendable {
    public var own: TrafficBytes
    public var tools: TrafficBytes

    public init(own: TrafficBytes = .zero, tools: TrafficBytes = .zero) {
        self.own = own
        self.tools = tools
    }

    /// The displayed value: tools only when `includeTools` (DESIGN 10).
    public func total(includeTools: Bool) -> TrafficBytes {
        includeTools ? own + tools : own
    }

    public static let zero = TrafficSplit()
}

/// One source's traffic (METRICS 10.7, 10.8).
public struct SourceTraffic: Equatable, Sendable {
    public var source: SourceKind
    /// Today's bytes.
    public var today: TrafficSplit
    /// The part of today's bytes (own and tools) not attributed to an agent tree (METRICS 10.6).
    public var unassigned: TrafficBytes
    /// Live rates with and without tools; nil before two samples exist (METRICS 10.7).
    public var liveWithTools: TrafficRate?
    public var liveOwn: TrafficRate?

    public init(source: SourceKind, today: TrafficSplit = .zero, unassigned: TrafficBytes = .zero,
                liveWithTools: TrafficRate? = nil, liveOwn: TrafficRate? = nil) {
        self.source = source
        self.today = today
        self.unassigned = unassigned
        self.liveWithTools = liveWithTools
        self.liveOwn = liveOwn
    }

    public func live(includeTools: Bool) -> TrafficRate? {
        includeTools ? liveWithTools : liveOwn
    }
}

/// One agent tree's traffic (METRICS 10.6, 10.8), keyed by the root agent's id (`AgentStatus.id`). Memory only.
public struct AgentTraffic: Equatable, Sendable {
    public var agentId: String
    public var today: TrafficSplit
    public var liveWithTools: TrafficRate?
    public var liveOwn: TrafficRate?

    public init(agentId: String, today: TrafficSplit = .zero, liveWithTools: TrafficRate? = nil, liveOwn: TrafficRate? = nil) {
        self.agentId = agentId
        self.today = today
        self.liveWithTools = liveWithTools
        self.liveOwn = liveOwn
    }

    public func live(includeTools: Bool) -> TrafficRate? {
        includeTools ? liveWithTools : liveOwn
    }
}

/// One second of traffic for sparklines (METRICS 10.7, history buffer): bytes per second of the sample whose interval
/// ends in the bucket.
public struct TrafficPoint: Equatable, Sendable {
    /// Start of the one-second bucket.
    public var time: Date
    public var rate: TrafficRate

    public init(time: Date, rate: TrafficRate) {
        self.time = time
        self.rate = rate
    }
}

/// Why per-process traffic cannot be measured (METRICS 10.3; DESIGN 10 `traffic.unavailable.*`).
public enum TrafficUnavailableReason: String, Equatable, Sendable {
    /// macOS: nettop is missing, or failed five times within 10 minutes.
    case sampler
    /// Windows helper states (never produced on macOS).
    case helperMissing, helperStopped, helperOutdated, denied
}

/// The per-process sampler's state (METRICS 10.3, 10.10).
public enum ProcessTrafficState: Equatable, Sendable {
    /// Measuring is off.
    case off
    /// Started; the first sample has not arrived yet.
    case starting
    /// No agent process is running, so the sampler is stopped (METRICS 10.10); values are real zeros.
    case standby
    /// Sampling every `interval` seconds.
    case running(interval: Int)
    case unavailable(TrafficUnavailableReason)

    /// Per-source and per-agent values can be shown (as opposed to `–` with a reason).
    public var isAvailable: Bool {
        switch self {
        case .starting, .standby, .running: true
        case .off, .unavailable: false
        }
    }

    public var unavailableReason: TrafficUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Bytes counted since the traffic engine started, without the deltas of gap samples (METRICS 11.4): each source's
/// own and tool processes (the machine series is never reported). Live reporting takes differences of it.
public struct TrafficReportTotals: Equatable, Sendable {
    public var sources: [SourceKind: TrafficSplit]

    public init(sources: [SourceKind: TrafficSplit] = [:]) {
        self.sources = sources
    }

    public static let zero = TrafficReportTotals()
}

/// Everything the UI shows about network traffic (METRICS 10.7, 10.8), published once per tick.
public struct TrafficSnapshot: Equatable, Sendable {
    public var timestamp: Date
    /// `trafficEnabled` (DESIGN 10); everything else is empty while off.
    public var enabled: Bool
    /// This computer's live rate; nil before two samples exist.
    public var machineLive: TrafficRate?
    public var machineToday: TrafficBytes
    /// Sum of machine sample intervals ≤ 15 s today (METRICS 10.8).
    public var machineSampledMs: Int64
    /// The last 300 one-second buckets of this computer's traffic, oldest first.
    public var machineHistory: [TrafficPoint]
    /// The last 300 one-second buckets per source (own + tools), oldest first.
    public var sourceHistory: [SourceKind: [TrafficPoint]]
    public var processState: ProcessTrafficState
    /// Sum of process sample intervals ≤ 15 s today (METRICS 10.8).
    public var processSampledMs: Int64
    /// Every source with traffic today or now.
    public var sources: [SourceKind: SourceTraffic]
    /// Agent trees with attributed traffic today, by root agent id.
    public var agents: [String: AgentTraffic]
    /// Local midnight at which "today" starts.
    public var dayStart: Date
    /// Live reporting's cumulative bytes (METRICS 11.4).
    public var reportTotals: TrafficReportTotals
    /// A counted interface was up at the latest sample (METRICS 10.2).
    public var machineAvailable: Bool

    public init(
        timestamp: Date,
        enabled: Bool,
        machineLive: TrafficRate? = nil,
        machineToday: TrafficBytes = .zero,
        machineSampledMs: Int64 = 0,
        machineHistory: [TrafficPoint] = [],
        sourceHistory: [SourceKind: [TrafficPoint]] = [:],
        processState: ProcessTrafficState,
        processSampledMs: Int64 = 0,
        sources: [SourceKind: SourceTraffic] = [:],
        agents: [String: AgentTraffic] = [:],
        dayStart: Date = .distantPast,
        reportTotals: TrafficReportTotals = .zero,
        machineAvailable: Bool = true
    ) {
        self.timestamp = timestamp
        self.enabled = enabled
        self.machineLive = machineLive
        self.machineToday = machineToday
        self.machineSampledMs = machineSampledMs
        self.machineHistory = machineHistory
        self.sourceHistory = sourceHistory
        self.processState = processState
        self.processSampledMs = processSampledMs
        self.sources = sources
        self.agents = agents
        self.dayStart = dayStart
        self.reportTotals = reportTotals
        self.machineAvailable = machineAvailable
    }

    public static let off = TrafficSnapshot(timestamp: .distantPast, enabled: false, processState: .off)

    /// The summed live rate of `sources` (all sources when nil); nil when per-process data is unavailable or no
    /// sample pair exists yet.
    public func live(of sources: SourceSet?, includeTools: Bool) -> TrafficRate? {
        guard processState.isAvailable else { return nil }
        var total: TrafficRate?
        for (kind, traffic) in self.sources where sources?.contains(kind) ?? true {
            guard let rate = traffic.live(includeTools: includeTools) else { continue }
            total = (total ?? .zero) + rate
        }
        if total == nil, processState.isAvailable, machineLive != nil { return .zero }
        return total
    }

    /// Today's bytes of `sources` (all sources when nil).
    public func today(of sources: SourceSet?, includeTools: Bool) -> TrafficBytes {
        self.sources.reduce(into: TrafficBytes.zero) { sum, entry in
            if sources?.contains(entry.key) ?? true { sum += entry.value.today.total(includeTools: includeTools) }
        }
    }
}

/// One stored day of traffic (METRICS 10.9 `day_traffic`): `key` is `machine` or a source raw value.
public struct TrafficDay: Equatable, Hashable, Sendable {
    public static let machineKey = "machine"

    /// Local date `yyyy-MM-dd`.
    public var day: String
    public var key: String
    /// Own bytes for a source, all bytes for `machine`.
    public var rx: Int64
    public var tx: Int64
    /// Tool bytes (0 for `machine`).
    public var rxTools: Int64
    public var txTools: Int64
    /// Machine `sampledMs` on the machine row, `processSampledMs` on source rows.
    public var sampledMs: Int64

    public init(day: String, key: String, rx: Int64, tx: Int64, rxTools: Int64 = 0, txTools: Int64 = 0, sampledMs: Int64) {
        self.day = day
        self.key = key
        self.rx = rx
        self.tx = tx
        self.rxTools = rxTools
        self.txTools = txTools
        self.sampledMs = sampledMs
    }

    public var source: SourceKind? { SourceKind(rawValue: key) }
    public var isMachine: Bool { key == Self.machineKey }

    public func total(includeTools: Bool) -> TrafficBytes {
        includeTools ? TrafficBytes(rx: rx + rxTools, tx: tx + txTools) : TrafficBytes(rx: rx, tx: tx)
    }
}
