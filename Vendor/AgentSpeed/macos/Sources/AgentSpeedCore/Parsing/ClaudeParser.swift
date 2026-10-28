import Foundation

/// Per-file Claude Code / Claude Desktop state machine (METRICS 4.1).
struct ClaudeParser: Sendable {
    static let syntheticModel = "<synthetic>"
    /// Repeated lines of one message are adjacent, so a short memory of recent keys is enough to merge them.
    static let mergeMemory = 1024

    let agentId: String
    let fileID: FileID
    private(set) var state: AgentState

    private var sourceDecided = false
    private var pendingStartMs: Int64?
    private var preciseStart = false
    private var responses: [String: ResponseRecord] = [:]
    private var responseOrder: [String] = []

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
        let components = agentId.split(separator: "/", omittingEmptySubsequences: true)
        state = AgentState(source: .claudeCode, isSubagent: components.dropLast().contains("subagents"))
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(
        _ extraction: LineExtraction<ClaudeLine>,
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

    private mutating func consume(_ line: ClaudeLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        guard let timestamp = line.timestampMs else {
            if line.localDisplayStop { state.localDisplayStopped = true }
            return
        }
        state.noteLine(at: timestamp)
        if !sourceDecided, let source = line.entrypointSource {
            state.source = source
            sourceDecided = true
        }
        if let cwd = line.cwd { state.setProject(fromWorkingDirectory: cwd) }
        if line.isSidechain { state.isSubagent = true }

        if line.localDisplayStop { state.localDisplayStopped = true }
        switch line.type {
        case .apiRequest:
            pendingStartMs = timestamp
            preciseStart = true
            state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)

        case .user:
            if line.isInterrupt {
                state.setPhase(.idle, at: timestamp)
                pendingStartMs = nil
                preciseStart = false
            } else {
                if !preciseStart { pendingStartMs = timestamp }
                state.setPhase(.generating, at: timestamp, inFlightStartMs: pendingStartMs)
            }

        case .assistant:
            consumeAssistant(line, at: timestamp, deduper: &deduper, emit: emit)
            if line.localDisplayStop { state.localDisplayStopped = true }

        case .other:
            break
        }
    }

    private mutating func consumeAssistant(
        _ line: ClaudeLine,
        at timestamp: Int64,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        guard line.model != Self.syntheticModel else { return }
        guard let key = line.messageId ?? line.requestId ?? line.uuid else { return }
        let claim = deduper.claim(key, for: fileID)
        guard claim != .otherFile else { return }

        let hasStopReason = line.stopReason != .none
        let record: ResponseRecord
        if claim == .sameFile, var existing = responses[key] {
            existing.endMs = max(existing.endMs, timestamp)
            existing.usage = existing.usage.merged(with: line.usage)
            if let model = line.model { existing.model = model }
            existing.fast = existing.fast || line.fast
            existing.modes = existing.modes.merging(line.modes)
            existing.isFinal = existing.isFinal || hasStopReason
            record = existing
        } else {
            record = ResponseRecord(
                key: key,
                source: state.source,
                agentId: agentId,
                model: line.model,
                startMs: pendingStartMs,
                endMs: timestamp,
                usage: line.usage,
                isFinal: hasStopReason,
                fast: line.fast,
                modes: line.modes
            )
            pendingStartMs = nil
            preciseStart = false
            remember(key)
        }
        responses[key] = record
        state.modes = record.modes
        if let model = line.model { state.model = model }

        switch line.stopReason {
        case .toolUse:
            state.setPhase(.tools, at: timestamp)
        case .none where line.hasToolUse:
            state.setPhase(.tools, at: timestamp)
        case .none, .pauseTurn:
            state.setPhase(.generating, at: timestamp, inFlightStartMs: record.startMs ?? timestamp)
        case .other:
            state.setPhase(.idle, at: timestamp)
        }
        emit(ResponseUpsert(record: record, isCompletion: claim == .new))
    }

    private mutating func remember(_ key: String) {
        responseOrder.append(key)
        guard responseOrder.count > Self.mergeMemory * 2 else { return }
        let evicted = responseOrder.prefix(responseOrder.count - Self.mergeMemory)
        for old in evicted { responses[old] = nil }
        responseOrder.removeFirst(evicted.count)
    }
}
