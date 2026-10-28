import Foundation

/// Per-file DeepSeek Harness (dsh) state machine (METRICS 4.3).
struct DshParser: Sendable {
    /// Events older than the session's creation minus this tolerance are inherited from a forked parent.
    static let inheritedHistoryToleranceMs: Int64 = 2000

    let agentId: String
    let fileID: FileID
    private(set) var state = AgentState(source: .deepseek)

    private var pendingStartMs: Int64?
    /// The latest `request/header` `config.provider` (METRICS 3.2).
    private var provider: String?

    init(agentId: String, fileID: FileID) {
        self.agentId = agentId
        self.fileID = fileID
    }

    mutating func consume(
        _ extraction: LineExtraction<DshLine>,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        switch extraction {
        case .blank:
            return
        case .malformed:
            noteMalformedLine()
        case .line(let line):
            for record in line.records { consume(record, deduper: &deduper, emit: emit) }
        }
    }

    mutating func noteMalformedLine() {
        state.malformedLines += 1
    }

    private mutating func consume(_ record: DshRecord, deduper: inout Deduper, emit: (ResponseUpsert) -> Void) {
        switch record {
        case .header(let header):
            // Only the first header names the session.
            guard state.thread == nil else { return }
            state.thread = SessionThread(id: header.id, parentId: header.parentSession, createdMs: header.createdMs)
            if let cwd = header.cwd { state.setProject(fromWorkingDirectory: cwd) }
            state.isSubagent = header.isSubagent

        case .event(let timestamp, let kind):
            if let created = state.thread?.createdMs, timestamp < created - Self.inheritedHistoryToleranceMs { return }
            state.noteLine(at: timestamp)
            switch kind {
            case .requestHeader(let model, let provider):
                if let model { state.model = model }
                if let provider { self.provider = provider }
            case .stepStart:
                pendingStartMs = timestamp
                state.setPhase(.generating, at: timestamp, inFlightStartMs: timestamp)
            case .assistantMessage(let message):
                consumeMessage(message, at: timestamp, deduper: &deduper, emit: emit)
            case .turnEnd:
                state.setPhase(.idle, at: timestamp)
                pendingStartMs = nil
            case .localDisplayStop:
                state.localDisplayStopped = true
            case .other:
                break
            }
        }
    }

    private mutating func consumeMessage(
        _ message: DshAssistantMessage,
        at timestamp: Int64,
        deduper: inout Deduper,
        emit: (ResponseUpsert) -> Void
    ) {
        // Missing parts of the fallback key read "None", as in the reference implementation.
        let key = message.id ?? "dsh:\(state.thread?.id ?? "None"):\(message.seq.map { String($0) } ?? "None")"
        guard deduper.claim(key, for: fileID) == .new else { return }
        if let usage = message.usage {
            let model = message.model ?? state.model
            let record = ResponseRecord(
                key: key,
                source: .deepseek,
                agentId: agentId,
                model: model,
                startMs: pendingStartMs,
                endMs: timestamp,
                usage: usage,
                provider: message.provider ?? provider
            )
            if let model { state.model = model }
            emit(ResponseUpsert(record: record, isCompletion: true))
        }
        pendingStartMs = nil
        state.setPhase(message.hasToolCall ? .tools : .idle, at: timestamp)
    }
}
