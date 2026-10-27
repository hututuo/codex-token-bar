import Foundation

/// Usage counted for live reporting (METRICS 11.4): token fields, measured output and time, cost and unpriced requests.
public struct ReportUsage: Equatable, Hashable, Sendable {
    public var requests: Int64 = 0
    public var output: Int64 = 0
    public var input: Int64 = 0
    public var cachedInput: Int64 = 0
    public var cacheWriteInput: Int64 = 0
    public var reasoning: Int64 = 0
    public var measuredOutput: Int64 = 0
    public var measuredMs: Int64 = 0
    public var costMicroUsd: Int64 = 0
    public var unpricedRequests: Int64 = 0

    public init(
        requests: Int64 = 0, output: Int64 = 0, input: Int64 = 0, cachedInput: Int64 = 0, cacheWriteInput: Int64 = 0,
        reasoning: Int64 = 0, measuredOutput: Int64 = 0, measuredMs: Int64 = 0, costMicroUsd: Int64 = 0,
        unpricedRequests: Int64 = 0
    ) {
        self.requests = requests
        self.output = output
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.reasoning = reasoning
        self.measuredOutput = measuredOutput
        self.measuredMs = measuredMs
        self.costMicroUsd = costMicroUsd
        self.unpricedRequests = unpricedRequests
    }

    public static let zero = ReportUsage()

    public var isZero: Bool { self == .zero }

    /// Any token field changed (the activity rule of METRICS 11.5).
    public var hasTokens: Bool {
        requests != 0 || output != 0 || input != 0 || cachedInput != 0 || cacheWriteInput != 0 || reasoning != 0
    }

    public static func + (lhs: ReportUsage, rhs: ReportUsage) -> ReportUsage {
        ReportUsage(
            requests: lhs.requests + rhs.requests, output: lhs.output + rhs.output, input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput, cacheWriteInput: lhs.cacheWriteInput + rhs.cacheWriteInput,
            reasoning: lhs.reasoning + rhs.reasoning, measuredOutput: lhs.measuredOutput + rhs.measuredOutput,
            measuredMs: lhs.measuredMs + rhs.measuredMs, costMicroUsd: lhs.costMicroUsd + rhs.costMicroUsd,
            unpricedRequests: lhs.unpricedRequests + rhs.unpricedRequests
        )
    }

    /// Field-wise difference of two cumulative values, never negative.
    public static func - (lhs: ReportUsage, rhs: ReportUsage) -> ReportUsage {
        ReportUsage(
            requests: max(0, lhs.requests - rhs.requests), output: max(0, lhs.output - rhs.output),
            input: max(0, lhs.input - rhs.input), cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            cacheWriteInput: max(0, lhs.cacheWriteInput - rhs.cacheWriteInput),
            reasoning: max(0, lhs.reasoning - rhs.reasoning),
            measuredOutput: max(0, lhs.measuredOutput - rhs.measuredOutput),
            measuredMs: max(0, lhs.measuredMs - rhs.measuredMs),
            costMicroUsd: max(0, lhs.costMicroUsd - rhs.costMicroUsd),
            unpricedRequests: max(0, lhs.unpricedRequests - rhs.unpricedRequests)
        )
    }

    public static func += (lhs: inout ReportUsage, rhs: ReportUsage) {
        lhs = lhs + rhs
    }
}

/// A resolved model id (METRICS 11.3) used by one source.
public struct ReportModelKey: Equatable, Hashable, Sendable {
    public var modelId: String
    public var source: SourceKind

    public init(modelId: String, source: SourceKind) {
        self.modelId = modelId
        self.source = source
    }
}

/// Cumulative report increments since the engine started (METRICS 11.4). A report window is the difference of two
/// values, so every increment lands in exactly one window however snapshots are coalesced.
public struct ReportCounters: Equatable, Sendable {
    public var byModel: [ReportModelKey: ReportUsage]
    public var byMode: [ReportModeKey: ReportUsage]

    public init(byModel: [ReportModelKey: ReportUsage] = [:], byMode: [ReportModeKey: ReportUsage] = [:]) {
        self.byModel = byModel
        self.byMode = byMode
    }

    public static let zero = ReportCounters()

    public var total: ReportUsage {
        byModel.values.reduce(into: ReportUsage()) { $0 += $1 }
    }

    /// The increments since `baseline`, per model and source; zero entries are left out.
    public func since(_ baseline: ReportCounters) -> ReportCounters {
        var delta: [ReportModelKey: ReportUsage] = [:]
        for (key, value) in byModel {
            let change = value - (baseline.byModel[key] ?? .zero)
            if !change.isZero { delta[key] = change }
        }
        var modes: [ReportModeKey: ReportUsage] = [:]
        for (key, value) in byMode {
            let change = value - (baseline.byMode[key] ?? .zero)
            if !change.isZero { modes[key] = change }
        }
        return ReportCounters(byModel: delta, byMode: modes)
    }

    public mutating func add(_ usage: ReportUsage, to key: ReportModelKey, modes: [ExecutionModeAttribution] = []) {
        guard !usage.isZero else { return }
        byModel[key, default: .zero] += usage
        for attribution in modes {
            byMode[ReportModeKey(model: key, attribution: attribution), default: .zero] += usage
        }
    }
}

/// Agents of the base set of METRICS 6.7 (staleness applied, no ancestor closure) of one source.
public struct ReportAgentCounts: Equatable, Sendable {
    public var generating: Int
    public var tools: Int
    public var active: Int

    public init(generating: Int = 0, tools: Int = 0, active: Int = 0) {
        self.generating = generating
        self.tools = tools
        self.active = active
    }

    public static let zero = ReportAgentCounts()
}

/// What each snapshot carries for live reporting (METRICS 11.2, 11.4).
public struct ReportLiveFacts: Equatable, Sendable {
    public var agents: [SourceKind: ReportAgentCounts]
    /// Generating agents by the resolved id of their current model and their source.
    public var generatingModels: [ReportModelKey: Int]
    public var counters: ReportCounters

    public init(
        agents: [SourceKind: ReportAgentCounts] = [:],
        generatingModels: [ReportModelKey: Int] = [:],
        counters: ReportCounters = .zero
    ) {
        self.agents = agents
        self.generatingModels = generatingModels
        self.counters = counters
    }

    public static let empty = ReportLiveFacts()
}
