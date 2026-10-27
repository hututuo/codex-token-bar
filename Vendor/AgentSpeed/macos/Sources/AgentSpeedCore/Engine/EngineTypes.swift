import Foundation

/// The engine's view of one agent (one transcript file).
struct EngineAgent: Equatable, Sendable {
    var id: String
    var source: SourceKind
    var project: String
    /// The transcript's full working directory (METRICS 10.6); nil when it names none.
    var cwdPath: String?
    var model: String?
    var modes: ExecutionModes = .empty
    var isSubagent: Bool
    var phase: AgentPhase
    var inFlightStartMs: Int64?
    var lastLineMs: Int64?
    /// Resolved parent agent (METRICS 6.7), which may be outside the list.
    var parentId: String?

    init(
        id: String,
        source: SourceKind,
        project: String,
        model: String? = nil,
        isSubagent: Bool = false,
        phase: AgentPhase = .idle,
        inFlightStartMs: Int64? = nil,
        lastLineMs: Int64? = nil,
        parentId: String? = nil,
        cwdPath: String? = nil,
        modes: ExecutionModes = .empty
    ) {
        self.id = id
        self.source = source
        self.project = project
        self.cwdPath = cwdPath
        self.model = model
        self.modes = modes
        self.isSubagent = isSubagent
        self.phase = phase
        self.inFlightStartMs = inFlightStartMs
        self.lastLineMs = lastLineMs
        self.parentId = parentId
    }

    init(id: String, state: AgentState, parentId: String? = nil) {
        self.init(
            id: id,
            source: state.source,
            project: state.project ?? Self.fallbackProject(for: id),
            model: state.model,
            isSubagent: state.isSubagent,
            phase: state.phase,
            inFlightStartMs: state.inFlightStartMs,
            lastLineMs: state.lastLineMs,
            parentId: parentId,
            cwdPath: state.cwdPath,
            modes: state.modes
        )
    }

    /// Project name from the transcript location when the transcript never named a working directory. Gemini CLI
    /// sessions (`<project>/chats/[<dir>/]<file>`) use the project folder, Antigravity conversations without a
    /// workspace (`<store>/conversations/<id>.db`) their store.
    static func fallbackProject(for path: String) -> String {
        if let project = GeminiProjects.projectDirectory(ofSessionAt: path) {
            let name = (project as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let parent = (path as NSString).deletingLastPathComponent
        if TranscriptNames.isConversationDatabase((path as NSString).lastPathComponent),
           (parent as NSString).lastPathComponent == "conversations" {
            let store = ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !store.isEmpty { return store }
        }
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty ? (path as NSString).lastPathComponent : name
    }
}

/// One row of the agents list (METRICS 6.7).
struct EngineAgentStatus: Equatable, Sendable {
    var agent: EngineAgent
    /// Phase after the 300-second staleness rule.
    var phase: AgentPhase
    var live: Rate
    var recentSpeed: Double?
    /// The parent's id when the parent is listed too; nil for a root.
    var parentId: String?
    /// The agent's live cost rate (METRICS 9.5).
    var liveCost: LiveCost = .zero
}

/// Everything the engine computes for one instant.
struct EngineOutput: Sendable {
    var nowMs: Int64
    var live: Rate
    var liveEstimatedShare: Double
    var sourceLive: [SourceKind: Rate]
    /// The estimated part of `sourceLive`.
    var sourceLiveEstimated: [SourceKind: Rate]
    var liveModels: [SourceModelRate] = []
    /// The live cost rate (METRICS 9.5), in total and per source.
    var liveCost: LiveCost = .zero
    var sourceLiveCost: [SourceKind: LiveCost] = [:]
    var agents: [EngineAgentStatus]
    var history: [HistoryPoint]
    var today: TokenTotals
    var todayBySource: [SourceKind: TokenTotals]
    var averageToday: Double?
    /// Today's responses whose final usage was never written.
    var unfinalizedToday: Int
    /// Today's cost (METRICS 9.6): in total, per source and per source and model.
    var todayCost: CostTally = .zero
    var todayCostBySource: [SourceKind: CostTally] = [:]
    var todayCostByModel: [SourceKind: [String: CostTally]] = [:]
    var peakToday: Rate
    var peakTodayAtMs: Int64?
    /// Today's measured output peak of every requested source set (METRICS 6.8).
    var subsetPeaks: [SourceSet: Double]
    /// The local midnight the output's "today" starts at.
    var todayStartMs: Int64
    var lastResponse: ResponseSummary?
    var events: [SpeedEvent]
    /// Live reporting's view of this instant (METRICS 11.2, 11.4).
    var report: ReportLiveFacts = .empty
}
