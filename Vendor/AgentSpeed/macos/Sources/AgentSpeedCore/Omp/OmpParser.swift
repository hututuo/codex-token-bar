import Foundation

/// Per-file omp state machine (METRICS 4.7).
struct OmpParser: Sendable {
    /// Entries older than the header by more than this are copied history.
    static let copiedHistoryMs: Int64 = 2000

    let agentId: String
    let fileID: FileID
    private(set) var state: AgentState

    private var headerSeen = false
    private var headerMs: Int64?
    private var pendingToolCalls: Set<String> = []
    private var branchModes: [String: ExecutionModes] = [:]

    /// `root` is the sessions root the file was found under.
    init(agentId: String, fileID: FileID, root: String?) {
        self.agentId = agentId
        self.fileID = fileID
        let isSubagent = Self.isSubagent(path: agentId, root: root)
        state = AgentState(source: .omp, isSubagent: isSubagent)
        // A sub-agent belongs to the session `<dir>.jsonl` that owns its folder (METRICS 6.7).
        let parentId = isSubagent ? (agentId as NSString).deletingLastPathComponent + ".jsonl" : nil
        state.thread = SessionThread(id: nil, parentId: parentId, createdMs: 0)
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    mutating func consume(_ extraction: LineExtraction<OmpLine>, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch extraction {
        case .blank:
            return
        case .malformed:
            state.malformedLines += 1
        case .line(let line):
            consume(line, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(_ line: OmpLine, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch line {
        case .ignored:
            return
        case .header(let header):
            guard !headerSeen else { return }
            headerSeen = true
            headerMs = header.timestampMs
            state.project = header.cwd.flatMap(Self.basename)
            state.cwdPath = header.cwd.flatMap { $0.isEmpty ? nil : $0 }
            state.thread?.id = header.id
            state.thread?.createdMs = header.timestampMs ?? 0
            if let timestamp = header.timestampMs { state.noteLine(at: timestamp) }
        case .entry(let id, let timestamp, let record, let parentId):
            guard headerSeen else { return }
            if let headerMs, timestamp < headerMs - Self.copiedHistoryMs { return }
            state.noteLine(at: timestamp)
            state.modes = parentId.flatMap { branchModes[$0] } ?? .empty
            if case .modeChange(let tiers) = record {
                state.modes = ExecutionModes(tiers.flatMap { provider, tier in
                    ExecutionModeAdapters.omp(tier, provider: provider, evidence: .selected, scope: .session).facts
                })
            }
            branchModes[id] = state.modes
            if branchModes.count > 16_384 { branchModes = [id: state.modes] }
            consume(record, id: id, at: timestamp, deduper: &deduper, emit: emit)
        }
    }

    private mutating func consume(
        _ record: OmpRecord,
        id: String,
        at timestamp: Int64,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        switch record {
        case .input:
            state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
            pendingToolCalls.removeAll()
        case .assistant(let assistant):
            consume(assistant, id: id, at: timestamp, deduper: &deduper, emit: emit)
        case .toolResult(let callId, let isFinalYield):
            if let callId { pendingToolCalls.remove(callId) }
            if isFinalYield {
                // A sub-agent's final yield ends its run.
                state.setPhase(.idle, at: timestamp)
            } else if state.phase == .tools, pendingToolCalls.isEmpty {
                state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
            }
        case .modelUsage(let call):
            let key = "omp:\(id):\(timestamp)"
            guard !deduper.isOwnedByOtherFile(key, for: fileID), call.hasUsage else { return }
            emitResponse(key: key, startMs: nil, endMs: timestamp, call: call, deduper: &deduper, emit: emit)
        case .sessionExit:
            state.setPhase(.idle, at: timestamp)
            pendingToolCalls.removeAll()
        case .other, .modeChange:
            break
        }
    }

    private mutating func consume(
        _ assistant: OmpAssistant,
        id: String,
        at timestamp: Int64,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        let key = "omp:\(id):\(assistant.startedMs ?? timestamp)"
        guard !deduper.isOwnedByOtherFile(key, for: fileID) else { return }
        let endMs: Int64
        if let started = assistant.startedMs, let duration = assistant.durationMs {
            let (sum, overflow) = started.addingReportingOverflow(duration)
            endMs = overflow ? .max : sum
        } else {
            endMs = assistant.completedAtMs ?? timestamp
        }
        if assistant.call.hasUsage {
            // Failed and interrupted requests count in totals only.
            let startMs = assistant.stop.isFailure ? nil : assistant.startedMs
            emitResponse(key: key, startMs: startMs, endMs: endMs, call: assistant.call, deduper: &deduper, emit: emit)
            state.model = assistant.call.model
            state.modes = state.modes.merging(assistant.call.modes)
        }
        let continues = assistant.stop == .toolUse || assistant.stop == .stop || assistant.stop == .length
        if assistant.stop.isFailure {
            state.setPhase(.idle, at: timestamp)
            pendingToolCalls.removeAll()
        } else if !assistant.toolCallIds.isEmpty, continues {
            state.setPhase(.tools, at: timestamp)
            pendingToolCalls = assistant.toolCallIds
        } else if assistant.stop == .stop, assistant.pausesTurn {
            // omp samples again right away.
            state.setPhase(.generating, at: timestamp, inFlightStartMs: endMs)
        } else {
            state.setPhase(.idle, at: timestamp)
        }
    }

    private func emitResponse(
        key: String,
        startMs: Int64?,
        endMs: Int64,
        call: OmpCall,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        let claim = deduper.claim(key, for: fileID)
        let record = ResponseRecord(key: key, source: .omp, agentId: agentId, model: call.model, startMs: startMs,
                                    endMs: endMs, usage: call.tokens, isFinal: true, provider: call.provider,
                                    modes: ExecutionModes(state.modes.facts.filter { $0.provider == ExecutionModeAdapters.ompProvider(call.provider) }).merging(call.modes))
        // A repeat in the same file (a rewrite read again) is an update (METRICS 4.4).
        emit(ResponseUpsert(record: record, isCompletion: claim == .new))
    }

    // MARK: - Paths

    /// The last component of `cwd`, split on `/` and `\`.
    static func basename(_ path: String) -> String? {
        path.utf8.split(whereSeparator: { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "\\") })
            .last.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The path relative to `root` (as `os.path.relpath` gives it, split on `/` and `\`) has three or more components:
    /// the file lives inside a session's artifacts folder.
    static func isSubagent(path: String, root: String?) -> Bool {
        guard let root, !root.isEmpty else { return false }
        let slash = UInt8(ascii: "/")
        let rootParts = root.utf8.split(separator: slash)
        let pathParts = path.utf8.split(separator: slash)
        var common = 0
        while common < rootParts.count, common < pathParts.count, rootParts[common].elementsEqual(pathParts[common]) {
            common += 1
        }
        var count = rootParts.count - common
        for part in pathParts[common...] {
            count += part.split(separator: UInt8(ascii: "\\")).count
        }
        return count >= 3
    }
}
