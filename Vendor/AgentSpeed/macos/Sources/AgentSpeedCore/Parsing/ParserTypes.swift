import Foundation

/// One model response as produced by a transcript parser (METRICS 4).
public struct ResponseRecord: Equatable, Hashable, Sendable {
    public var key: String
    public var source: SourceKind
    /// Absolute transcript path.
    public var agentId: String
    public var model: String?
    /// When the request was sent; nil when unknown.
    public var startMs: Int64?
    public var endMs: Int64
    public var usage: TokenUsage
    public var requestCount: Int
    public var modes: ExecutionModes
    /// False while only a streaming snapshot of the usage was written (METRICS 3.3). Codex usage is always final.
    public var isFinal: Bool
    /// The API provider the agent says it used, only for pricing (METRICS 3.2); never empty.
    public var provider: String?
    /// The request ran in a provider's fast mode (METRICS 3.2).
    public var fast: Bool
    /// Integer micro-USD (METRICS 9.3), set by pricing; nil while unpriced or when the price is unknown.
    public var costMicroUsd: Int64?

    /// A final response with a valid interval contributes measured speed.
    public var isMeasured: Bool { isFinal && ResponseTiming.effectiveStart(startMs: startMs, endMs: endMs) != nil }

    public init(
        key: String,
        source: SourceKind,
        agentId: String,
        model: String?,
        startMs: Int64?,
        endMs: Int64,
        usage: TokenUsage,
        isFinal: Bool = true,
        provider: String? = nil,
        fast: Bool = false,
        costMicroUsd: Int64? = nil,
        requestCount: Int = 1,
        modes: ExecutionModes = .empty
    ) {
        self.key = key
        self.source = source
        self.agentId = agentId
        self.model = model
        self.startMs = startMs
        self.endMs = endMs
        self.usage = usage
        self.modes = modes
        self.requestCount = min(100_000, max(1, requestCount))
        self.isFinal = isFinal
        self.provider = provider.flatMap { $0.isEmpty ? nil : $0 }
        self.fast = fast
        self.costMicroUsd = costMicroUsd
    }
}

/// A parser emission. The first emission of a key is a completion; later ones are updates (METRICS 4.3).
struct ResponseUpsert: Equatable, Sendable {
    var record: ResponseRecord
    var isCompletion: Bool
}

/// A Codex thread or a DeepSeek Harness session as named by the first `session_meta` or header of its file
/// (METRICS 4.2, 4.3, 6.7).
struct SessionThread: Equatable, Sendable {
    var id: String?
    var parentId: String?
    var createdMs: Int64
}

/// Per-file agent state maintained by a parser.
struct AgentState: Equatable, Sendable {
    var source: SourceKind
    var project: String?
    /// The full working directory the transcript names (METRICS 4, 10.6); metadata only.
    var cwdPath: String?
    var model: String?
    var modes: ExecutionModes = .empty
    var isSubagent: Bool
    /// Codex and DeepSeek only; set once by the first `session_meta` or header.
    var thread: SessionThread?
    var phase: AgentPhase = .idle
    var phaseSinceMs: Int64?
    var inFlightStartMs: Int64?
    var lastLineMs: Int64?
    var malformedLines = 0

    init(source: SourceKind, isSubagent: Bool = false) {
        self.source = source
        self.isSubagent = isSubagent
    }

    mutating func setPhase(_ newPhase: AgentPhase, at timestampMs: Int64, inFlightStartMs start: Int64? = nil) {
        if phase != newPhase {
            phase = newPhase
            phaseSinceMs = timestampMs
        }
        inFlightStartMs = newPhase == .generating ? start : nil
    }

    mutating func noteLine(at timestampMs: Int64) {
        lastLineMs = max(lastLineMs ?? timestampMs, timestampMs)
    }

    mutating func setProject(fromWorkingDirectory cwd: String) {
        let name = (cwd as NSString).lastPathComponent
        if !name.isEmpty { project = name }
        if !cwd.isEmpty { cwdPath = cwd }
    }
}
