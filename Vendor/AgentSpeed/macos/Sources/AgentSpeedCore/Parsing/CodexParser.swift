import Foundation

/// Per-file Codex state machine (METRICS 4.2).
struct CodexParser: Sendable {
    static let copiedHistoryToleranceMs: Int64 = 2000
    static let defaultAgentPath = "/root"

    let agentId: String
    let fileID: FileID
    private(set) var state = AgentState(source: .codex)

    private var myAgentPath = CodexParser.defaultAgentPath
    private var pendingStartMs: Int64?
    private var streaming = false
    private var sawModernUsage = false
    private var previousLegacyTotals: CodexRawUsage?
    /// `model_provider` of the first `session_meta` (METRICS 3.2).
    private var provider: String?

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(
        _ extraction: LineExtraction<CodexLine>,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        switch extraction {
        case .blank:
            return
        case .malformed:
            state.malformedLines += 1
            return
        case .line(let line):
            consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: CodexLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let timestamp = line.timestampMs else {
            if line.localDisplayStop { state.localDisplayStopped = true }
            return
        }
        if case .sessionMeta(let meta) = line.kind {
            // Only the first session_meta applies; sub-agent files copy their parent's right after their own.
            guard state.thread == nil else { return }
            state.noteLine(at: timestamp)
            state.thread = SessionThread(id: meta.id, parentId: meta.parentThreadId, createdMs: timestamp)
            if let cwd = meta.cwd { state.setProject(fromWorkingDirectory: cwd) }
            myAgentPath = meta.agentPath ?? Self.defaultAgentPath
            state.isSubagent = meta.isSubagent
            provider = meta.modelProvider
            return
        }
        if let created = state.thread?.createdMs, timestamp < created - Self.copiedHistoryToleranceMs {
            return
        }
        state.noteLine(at: timestamp)
        if line.localDisplayStop { state.localDisplayStopped = true }
        if line.hasModeSelection { state.modes = line.modes }
        else if !line.modes.facts.isEmpty { state.modes = state.modes.merging(line.modes) }

        switch line.kind {
        case .sessionMeta:
            return

        case .turnContext(let model, let cwd):
            if let model { state.model = model }
            if let cwd { state.setProject(fromWorkingDirectory: cwd) }

        case .input:
            markInput(at: timestamp)

        case .agentMessage(let recipient):
            // A mailbox input marks a possible request start; an orchestrator may receive it while blocked.
            if recipient == myAgentPath, !streaming { pendingStartMs = timestamp }

        case .output:
            streaming = true
            state.setPhase(.generating, at: timestamp, inFlightStartMs: pendingStartMs ?? timestamp)

        case .modernUsage(let responseId, let threadId, let usage):
            sawModernUsage = true
            let key = responseId ?? "codex:\(threadId ?? state.thread?.id ?? agentId):\(timestamp)"
            guard deduper.claim(key, for: fileID) == .new else { return }
            complete(key: key, usage: usage.normalized, at: timestamp, emit: emit)

        case .legacyUsage(let threadId, let info):
            if sawModernUsage {
                // A response that ended without a usage record (seen when an orchestrator starts waiting).
                if streaming { finishWithoutUsage(at: timestamp) }
                return
            }
            guard let info, let total = info.total else { return }
            let tokens: CodexRawUsage
            if let previous = previousLegacyTotals {
                let (delta, hasNegative) = total.delta(since: previous)
                if delta.total == 0 { return }
                tokens = hasNegative ? (info.last ?? .zero) : delta
            } else {
                tokens = info.last ?? total
            }
            previousLegacyTotals = total
            let key = "codex-legacy:\(threadId ?? state.thread?.id ?? agentId):\(total.total)"
            guard deduper.claim(key, for: fileID) == .new else { return }
            complete(key: key, usage: tokens.normalized, at: timestamp, emit: emit)

        case .turnEnded:
            state.setPhase(.idle, at: timestamp)
            pendingStartMs = nil
            streaming = false

        case .other:
            break
        }
    }

    private mutating func markInput(at timestamp: Int64) {
        guard !streaming else { return }
        pendingStartMs = timestamp
        state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
    }

    private mutating func finishWithoutUsage(at timestamp: Int64) {
        pendingStartMs = timestamp
        streaming = false
        state.setPhase(.tools, at: timestamp)
    }

    private mutating func complete(key: String, usage: TokenUsage, at timestamp: Int64, emit: (ResponseUpsert) -> Void) {
        let record = ResponseRecord(
            key: key,
            source: .codex,
            agentId: agentId,
            model: state.model,
            startMs: pendingStartMs,
            endMs: timestamp,
            usage: usage,
            provider: provider,
            modes: state.modes
        )
        finishWithoutUsage(at: timestamp)
        state.modes = ExecutionModes(state.modes.facts.filter { $0.evidence == .selected })
        emit(ResponseUpsert(record: record, isCompletion: true))
    }
}
