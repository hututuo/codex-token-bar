import Foundation

/// Whether a floating orb's sources can show anything (DESIGN 2b, "Unavailable sources").
public enum SubsetState: Equatable, Sendable {
    /// At least one source is available.
    case available
    /// Every source is disabled.
    case allDisabled
    /// Every source is disabled or not detected, and at least one is not detected.
    case allNotFound
}

/// What a floating orb tracking a source set shows for one snapshot (METRICS 6.8).
public struct SubsetReading: Equatable, Sendable {
    /// Sum of the available sources' live rates.
    public var live: Rate
    /// Estimated share of `live.output` (0 when it is 0).
    public var estimatedShare: Double
    /// The agents list filtered to the available sources, in snapshot order; a parent outside the set is cleared.
    public var agents: [AgentStatus]
    /// The source of each generating agent, in `agents` order (the orb's agent dots).
    public var generatingSources: [SourceKind]
    /// Sum of the available sources' today totals.
    public var today: TokenTotals
    /// Today's measured output peak of the set; nil while the snapshot does not report it yet.
    public var measuredPeakOutput: Double?
    /// Members that are disabled or not detected, in source order.
    public var unavailable: [SourceKind]
    public var state: SubsetState

    public init(
        live: Rate = .zero,
        estimatedShare: Double = 0,
        agents: [AgentStatus] = [],
        generatingSources: [SourceKind] = [],
        today: TokenTotals = .zero,
        measuredPeakOutput: Double? = nil,
        unavailable: [SourceKind] = [],
        state: SubsetState = .available
    ) {
        self.live = live
        self.estimatedShare = estimatedShare
        self.agents = agents
        self.generatingSources = generatingSources
        self.today = today
        self.measuredPeakOutput = measuredPeakOutput
        self.unavailable = unavailable
        self.state = state
    }
}

/// What a surface shows in the money unit for a source set (METRICS 6.8, 9.4, 9.5; DESIGN 9). Only the *billable*
/// sources count: the available members not marked as subscriptions (unless subscriptions are included).
public struct CostReading: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Every live token has a known price (an idle 0 included).
        case priced
        /// Part of the live value is missing: `liveCostKnownShare < 0.995` and the value is not 0 (`≥`).
        case partial
        /// Live output without any known price (`–`).
        case nothingPriced
        /// Every available source is a subscription and excluded (value 0).
        case subscriptionOnly
    }

    public static let partialThreshold = 0.995

    /// micro-USD per second.
    public var microUsdPerSecond: Double
    public var knownShare: Double
    /// Live output (tok/s) of the billable sources.
    public var liveOutput: Double
    /// Today's cost of the billable sources and their request count.
    public var today: CostTally
    public var todayRequests: Int
    /// Today's unpriced models of the billable sources, most unpriced first.
    public var unpricedModels: [String]
    /// Available members left out as subscriptions, in source order.
    public var excluded: [SourceKind]
    public var state: State

    public init(
        microUsdPerSecond: Double = 0,
        knownShare: Double = 1,
        liveOutput: Double = 0,
        today: CostTally = .zero,
        todayRequests: Int = 0,
        unpricedModels: [String] = [],
        excluded: [SourceKind] = [],
        state: State = .priced
    ) {
        self.microUsdPerSecond = microUsdPerSecond
        self.knownShare = knownShare
        self.liveOutput = liveOutput
        self.today = today
        self.todayRequests = todayRequests
        self.unpricedModels = unpricedModels
        self.excluded = excluded
        self.state = state
    }

    public static let zero = CostReading()
}

/// Per-orb views of a snapshot (METRICS 6.8, DESIGN 2b).
public enum OrbSubset {
    /// The money-unit reading of `sources` (nil = every source) counting only `billable` sources (METRICS 9.4).
    public static func cost(_ snapshot: SpeedSnapshot, sources: SourceSet?, billable: SourceSet) -> CostReading {
        let members = sources ?? .everything
        var reading = CostReading()
        var known = 0.0
        var available = 0
        var unpriced: [String: Int] = [:]
        var order: [String] = []
        for status in snapshot.sources where members.contains(status.kind) && !isUnavailable(status) {
            available += 1
            guard billable.contains(status.kind) else {
                reading.excluded.append(status.kind)
                continue
            }
            reading.microUsdPerSecond += status.liveCost.microUsdPerSecond
            known += status.liveCost.knownOutput
            reading.liveOutput += status.live.output
            reading.today.add(status.todayCost)
            reading.todayRequests += status.today.requests
            for (rank, model) in status.unpricedModels.enumerated() {
                if unpriced[model] == nil { order.append(model) }
                unpriced[model] = min(unpriced[model] ?? .max, rank)
            }
        }
        reading.unpricedModels = order.enumerated()
            .sorted { (unpriced[$0.element]!, $0.offset) < (unpriced[$1.element]!, $1.offset) }
            .map(\.element)
        reading.knownShare = LiveCost(microUsdPerSecond: reading.microUsdPerSecond, knownOutput: known)
            .knownShare(liveOutput: reading.liveOutput)
        reading.state = if available > 0, reading.excluded.count == available {
            .subscriptionOnly
        } else if reading.liveOutput > 0, known <= 0 {
            .nothingPriced
        } else if reading.knownShare < CostReading.partialThreshold, reading.microUsdPerSecond > 0 {
            .partial
        } else {
            .priced
        }
        return reading
    }

    /// The reading of an orb tracking `sources`; nil (all sources) returns exactly the snapshot's own values.
    /// A member the snapshot does not list yet counts as available without data; a set without any known source is
    /// `.allNotFound`.
    public static func reading(_ snapshot: SpeedSnapshot, sources: SourceSet?) -> SubsetReading {
        guard let sources else {
            return SubsetReading(
                live: snapshot.live,
                estimatedShare: snapshot.liveEstimatedShare,
                agents: snapshot.agents,
                generatingSources: generatingSources(of: snapshot.agents),
                today: snapshot.today,
                measuredPeakOutput: snapshot.peakToday.output,
                unavailable: [],
                state: .available
            )
        }
        var included = sources.intersection(.everything)
        var unavailable: [SourceKind] = []
        var anyEnabled = false
        var live = Rate.zero
        var estimated = 0.0
        var today = TokenTotals()
        for status in snapshot.sources where sources.contains(status.kind) {
            if status.enabled { anyEnabled = true }
            guard !isUnavailable(status) else {
                unavailable.append(status.kind)
                included.remove(SourceSet(status.kind))
                continue
            }
            live.add(status.live)
            estimated += status.liveEstimated.output
            today.add(status.today)
        }
        let agents = filtered(snapshot.agents, to: included)
        let state: SubsetState = if !included.isEmpty {
            .available
        } else if anyEnabled || unavailable.isEmpty {
            .allNotFound
        } else {
            .allDisabled
        }
        return SubsetReading(
            live: live,
            estimatedShare: live.output > 0 ? estimated / live.output : 0,
            agents: agents,
            generatingSources: generatingSources(of: agents),
            today: today,
            measuredPeakOutput: snapshot.subsetPeaks[sources],
            unavailable: SourceKind.allCases.filter { unavailable.contains($0) },
            state: state
        )
    }

    /// Whether an orb tracking `sources` receives `event`: completions of its own sources (all for nil), and the
    /// all-sources `newPeak` only for an all-sources orb (subset orbs use `SubsetPeakTracker`).
    public static func accepts(_ event: SpeedEvent, sources: SourceSet?) -> Bool {
        switch event {
        case .responseCompleted(let summary):
            sources?.contains(summary.source) ?? true
        case .newPeak:
            sources == nil
        }
    }

    /// Disabled, or not detected: no readable root and no data today.
    public static func isUnavailable(_ status: SourceStatus) -> Bool {
        !status.enabled || (!status.available && status.today.requests == 0 && status.live == .zero)
    }

    private static func filtered(_ agents: [AgentStatus], to sources: SourceSet) -> [AgentStatus] {
        var kept = agents.filter { sources.contains($0.source) }
        let ids = Set(kept.map(\.id))
        for index in kept.indices where kept[index].parentId.map({ !ids.contains($0) }) ?? false {
            kept[index].parentId = nil
        }
        return kept
    }

    private static func generatingSources(of agents: [AgentStatus]) -> [SourceKind] {
        agents.filter { $0.phase == .generating }.map(\.source)
    }
}

extension TokenTotals {
    mutating func add(_ other: TokenTotals) {
        requests += other.requests
        input += other.input
        cachedInput += other.cachedInput
        cacheWriteInput += other.cacheWriteInput
        output += other.output
        reasoning += other.reasoning
    }
}
