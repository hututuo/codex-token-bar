import Foundation

public enum SourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claudeCode
    case claudeDesktop
    case deepseek
    case opencode
    case gemini
    /// omp (oh-my-pi).
    case omp
    /// Google Antigravity (CLI, desktop app, IDE).
    case antigravity
    /// Tencent WorkBuddy, China edition (desktop app).
    case workbuddy
    /// WorkBuddy AI, international edition (desktop app).
    case workbuddyAi
    case zcode
    case kimi
    case grokBuild

    public var id: String { rawValue }
}

public enum AgentPhase: String, Codable, Sendable {
    case generating
    case tools
    case idle
}

public enum SpeedMetric: String, CaseIterable, Codable, Sendable {
    case output
    case total
}

public struct TokenTotals: Codable, Equatable, Sendable {
    public var requests: Int
    public var input: Int
    public var cachedInput: Int
    public var cacheWriteInput: Int
    public var output: Int
    public var reasoning: Int

    public var total: Int { input + output }

    public init(
        requests: Int = 0,
        input: Int = 0,
        cachedInput: Int = 0,
        cacheWriteInput: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) {
        self.requests = requests
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = TokenTotals()
}

public struct Rate: Equatable, Sendable {
    public var output: Double
    public var total: Double

    public init(output: Double = 0, total: Double = 0) {
        self.output = output
        self.total = total
    }

    public func value(for metric: SpeedMetric) -> Double {
        metric == .output ? output : total
    }

    public static let zero = Rate()
}

public struct HistoryPoint: Equatable, Sendable {
    /// Start of the one-second bucket.
    public var time: Date
    public var measured: Rate
    public var estimated: Rate

    public init(time: Date, measured: Rate, estimated: Rate) {
        self.time = time
        self.measured = measured
        self.estimated = estimated
    }
}

public struct AgentStatus: Identifiable, Equatable, Sendable {
    /// Absolute transcript path.
    public var id: String
    public var source: SourceKind
    public var project: String
    public var model: String?
    public var modes: ExecutionModes
    public var phase: AgentPhase
    public var isSubagent: Bool
    public var live: Rate
    /// Output tok/s of the agent's recent responses (METRICS 6.2).
    public var recentSpeed: Double?
    public var lastActivity: Date
    /// The parent agent's id when the parent is also in the list (METRICS 6.7).
    public var parentId: String?
    /// The agent's live cost rate (METRICS 9.5).
    public var liveCost: LiveCost
    /// The full working directory the transcript names (METRICS 10.6); nil when it names none.
    public var cwdPath: String?

    public init(
        id: String,
        source: SourceKind,
        project: String,
        model: String?,
        phase: AgentPhase,
        isSubagent: Bool,
        live: Rate,
        recentSpeed: Double?,
        lastActivity: Date,
        parentId: String? = nil,
        liveCost: LiveCost = .zero,
        cwdPath: String? = nil,
        modes: ExecutionModes = .empty
    ) {
        self.id = id
        self.source = source
        self.project = project
        self.model = model
        self.modes = modes
        self.phase = phase
        self.isSubagent = isSubagent
        self.live = live
        self.recentSpeed = recentSpeed
        self.lastActivity = lastActivity
        self.parentId = parentId
        self.liveCost = liveCost
        self.cwdPath = cwdPath
    }
}

public struct SourceStatus: Identifiable, Equatable, Sendable {
    public var id: SourceKind { kind }
    public var kind: SourceKind
    public var configuredModes: ExecutionModes = .empty
    public var enabled: Bool
    public var rootPath: String
    /// The source is detected: its root folder (WorkBuddy: the data folder) exists and is readable (METRICS 2).
    public var available: Bool
    public var sessionCount: Int
    public var live: Rate
    public var today: TokenTotals
    public var activeAgents: Int
    /// The estimated part of `live` (unmeasured responses and in-flight requests, METRICS 6.3), in the same units.
    public var liveEstimated: Rate
    /// The live cost rate (METRICS 9.5).
    public var liveCost: LiveCost
    /// Today's cost (METRICS 9.6).
    public var todayCost: CostTally
    /// Models of today's responses without a known price, most unpriced requests first.
    public var unpricedModels: [String]

    public init(
        kind: SourceKind,
        enabled: Bool,
        rootPath: String,
        available: Bool,
        sessionCount: Int,
        live: Rate,
        today: TokenTotals,
        activeAgents: Int,
        liveEstimated: Rate = .zero,
        liveCost: LiveCost = .zero,
        todayCost: CostTally = .zero,
        unpricedModels: [String] = [],
        configuredModes: ExecutionModes = .empty
    ) {
        self.kind = kind
        self.enabled = enabled
        self.rootPath = rootPath
        self.available = available
        self.sessionCount = sessionCount
        self.live = live
        self.today = today
        self.activeAgents = activeAgents
        self.liveEstimated = liveEstimated
        self.liveCost = liveCost
        self.todayCost = todayCost
        self.unpricedModels = unpricedModels
        self.configuredModes = configuredModes
    }

    /// Listed on the dashboard (DESIGN 4.3): the source produced output tokens today or is generating right now (its
    /// first response may still be in flight).
    public var producedToday: Bool { today.output > 0 || live.output > 0 }
}

public struct ResponseSummary: Equatable, Sendable {
    public var source: SourceKind
    public var project: String
    public var model: String?
    public var outputTokens: Int
    public var totalTokens: Int
    /// Nil when the request start is unknown.
    public var duration: TimeInterval?
    /// Output tok/s, nil when the duration is unknown.
    public var speed: Double?
    public var endedAt: Date

    public init(
        source: SourceKind,
        project: String,
        model: String?,
        outputTokens: Int,
        totalTokens: Int,
        duration: TimeInterval?,
        speed: Double?,
        endedAt: Date
    ) {
        self.source = source
        self.project = project
        self.model = model
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.duration = duration
        self.speed = speed
        self.endedAt = endedAt
    }
}

public enum MonitorState: Equatable, Sendable {
    case starting(progress: Double)
    case running
    case noSources
}

public enum MonitorWarning: Equatable, Sendable {
    case partialHistory
    case unreadableFiles(Int)
    case malformedLines(Int)
    /// Claude responses whose final usage was never written (METRICS 3.3); today's output is a lower bound.
    case unfinalizedUsage(Int)
    /// The source's data uses a format this version cannot read (METRICS 4.5, 4.8); it contributes nothing.
    case unsupportedFormat(SourceKind)
}

/// Additive live attribution. Response tails retain the model recorded on that response,
/// independently of the agent's current model. Nil means no model was recorded.
public struct SourceModelRate: Equatable, Sendable {
    public var source: SourceKind
    public var model: String?
    public var rate: Rate
    public init(source: SourceKind, model: String?, rate: Rate) {
        self.source = source; self.model = model; self.rate = rate
    }
}

public struct SpeedSnapshot: Equatable, Sendable {
    public var liveModels: [SourceModelRate]
    public var timestamp: Date
    public var state: MonitorState
    public var live: Rate
    /// Share of `live` (0...1) that is an in-flight estimate.
    public var liveEstimatedShare: Double
    public var peakToday: Rate
    public var peakTodayAt: Date?
    /// Output tok/s over today's valid responses.
    public var averageToday: Double?
    public var today: TokenTotals
    public var sources: [SourceStatus]
    public var agents: [AgentStatus]
    public var generatingCount: Int
    public var toolsCount: Int
    /// Last 300 one-second buckets, oldest first.
    public var history: [HistoryPoint]
    public var lastResponse: ResponseSummary?
    public var warnings: [MonitorWarning]
    /// Today's measured output peak of every source set requested with `LiveMonitor.setSubsets` (METRICS 6.8): the
    /// maximum 3-bucket trailing average of the members' summed measured buckets, without the observed live part.
    public var subsetPeaks: [SourceSet: Double]
    /// Local midnight at which this snapshot's "today" starts; `.distantPast` before the monitor reported one.
    public var dayStart: Date
    /// The live cost rate of every source (METRICS 9.5); subscription marks apply in the UI (9.4).
    public var liveCost: LiveCost
    /// Today's cost of every source (METRICS 9.6).
    public var todayCost: CostTally
    /// Live reporting's agent counts and cumulative ledger (METRICS 11.2, 11.4).
    public var report: ReportLiveFacts

    public init(
        timestamp: Date,
        state: MonitorState,
        live: Rate,
        liveEstimatedShare: Double,
        peakToday: Rate,
        peakTodayAt: Date?,
        averageToday: Double?,
        today: TokenTotals,
        sources: [SourceStatus],
        agents: [AgentStatus],
        generatingCount: Int,
        toolsCount: Int,
        history: [HistoryPoint],
        lastResponse: ResponseSummary?,
        warnings: [MonitorWarning],
        subsetPeaks: [SourceSet: Double] = [:],
        dayStart: Date = .distantPast,
        liveCost: LiveCost = .zero,
        todayCost: CostTally = .zero,
        report: ReportLiveFacts = .empty,
        liveModels: [SourceModelRate] = []
    ) {
        self.timestamp = timestamp
        self.state = state
        self.live = live
        self.liveEstimatedShare = liveEstimatedShare
        self.peakToday = peakToday
        self.peakTodayAt = peakTodayAt
        self.averageToday = averageToday
        self.today = today
        self.sources = sources
        self.agents = agents
        self.generatingCount = generatingCount
        self.toolsCount = toolsCount
        self.history = history
        self.lastResponse = lastResponse
        self.warnings = warnings
        self.subsetPeaks = subsetPeaks
        self.dayStart = dayStart
        self.liveCost = liveCost
        self.todayCost = todayCost
        self.report = report
        self.liveModels = liveModels
    }

    public static let empty = SpeedSnapshot(
        timestamp: .distantPast,
        state: .starting(progress: 0),
        live: .zero,
        liveEstimatedShare: 0,
        peakToday: .zero,
        peakTodayAt: nil,
        averageToday: nil,
        today: .zero,
        sources: [],
        agents: [],
        generatingCount: 0,
        toolsCount: 0,
        history: [],
        lastResponse: nil,
        warnings: [],
        subsetPeaks: [:],
        dayStart: .distantPast
    )
}

public enum SpeedEvent: Equatable, Sendable {
    case responseCompleted(ResponseSummary)
    case newPeak(Double)
}

public struct MonitorConfiguration: Equatable, Sendable {
    public var enabledSources: Set<SourceKind>
    /// Nil uses the default Codex sessions folder.
    public var codexRoot: URL?
    /// Nil uses the default Claude projects folder (shared by Claude Code and Claude Desktop).
    public var claudeRoot: URL?
    /// Nil uses the default DeepSeek Harness sessions folder.
    public var dshRoot: URL?
    /// Nil uses the default OpenCode data folder (the one that contains `opencode.db`).
    public var opencodeRoot: URL?
    /// Nil uses the default Gemini CLI home folder.
    public var geminiRoot: URL?
    /// One omp `sessions` folder; nil reads the default root and every named profile (METRICS 2, 4.7).
    public var ompRoot: URL?
    /// One Antigravity store folder (or its `conversations` folder); nil reads the three default stores (METRICS 4.8).
    public var antigravityRoot: URL?
    /// WorkBuddy's data folder (or its `projects` folder); nil reads `~/.workbuddy` (METRICS 4.9).
    public var workbuddyRoot: URL?
    /// WorkBuddy AI's data folder (or its `projects` folder); nil reads `~/.workbuddy-ai` (METRICS 4.9).
    public var workbuddyAiRoot: URL?
    public var zcodeRoot: URL?
    public var kimiRoot: URL?
    public var grokBuildRoot: URL?
    /// Tests: replaces the automatic roots of a family that are otherwise derived from the environment and the home
    /// folder (omp `sessions` roots, Antigravity store folders, WorkBuddy data folders).
    var automaticRoots: [TranscriptFamily: [URL]] = [:]

    public init(
        enabledSources: Set<SourceKind> = Set(SourceKind.allCases),
        codexRoot: URL? = nil,
        claudeRoot: URL? = nil,
        dshRoot: URL? = nil,
        opencodeRoot: URL? = nil,
        geminiRoot: URL? = nil,
        ompRoot: URL? = nil,
        antigravityRoot: URL? = nil,
        workbuddyRoot: URL? = nil,
        workbuddyAiRoot: URL? = nil,
        zcodeRoot: URL? = nil,
        kimiRoot: URL? = nil,
        grokBuildRoot: URL? = nil
    ) {
        self.enabledSources = enabledSources
        self.codexRoot = codexRoot
        self.claudeRoot = claudeRoot
        self.dshRoot = dshRoot
        self.opencodeRoot = opencodeRoot
        self.geminiRoot = geminiRoot
        self.ompRoot = ompRoot
        self.antigravityRoot = antigravityRoot
        self.workbuddyRoot = workbuddyRoot
        self.workbuddyAiRoot = workbuddyAiRoot
        self.zcodeRoot = zcodeRoot
        self.kimiRoot = kimiRoot
        self.grokBuildRoot = grokBuildRoot
    }
}
