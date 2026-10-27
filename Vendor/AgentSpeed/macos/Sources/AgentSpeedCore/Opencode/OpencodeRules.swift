import Foundation

/// OpenCode rules of METRICS 4.5, shared by the live source and the daily history.
enum OpencodeRules {
    /// Assistant rows created this long before their session are copies made by a fork.
    static let forkToleranceMs: Int64 = 2000
    static let agentPrefix = "opencode:"

    static func agentId(session id: String) -> String { agentPrefix + id }

    static func isForkCopy(_ data: OpencodeMessageData, session: OpencodeSessionInfo) -> Bool {
        guard let created = data.created else { return false }
        return created < session.createdMs - forkToleranceMs
    }

    /// The response a row stands for, before deduplication. Nil when the row is not (yet) a response.
    static func response(for row: OpencodeRow, session: OpencodeSessionInfo) -> ResponseRecord? {
        guard let data = row.data, let tokens = data.tokens else { return nil }
        let startMs: Int64?
        let endMs: Int64
        switch row.kind {
        case .assistant:
            guard !isForkCopy(data, session: session), let streamed = data.streamed else { return nil }
            startMs = data.created
            endMs = streamed
        case .compaction:
            startMs = data.created
            endMs = data.completed ?? row.timeUpdated
        case .idle, .other:
            return nil
        }
        return ResponseRecord(
            key: row.id,
            source: .opencode,
            agentId: agentId(session: session.id),
            model: data.model,
            startMs: startMs,
            endMs: endMs,
            usage: tokens,
            isFinal: true,
            provider: data.provider,
            modes: data.modes
        )
    }

    /// Agent state after replaying a session's rows in `seq` order.
    static func state<Rows: Sequence>(of session: OpencodeSessionInfo, rows: Rows) -> AgentState where Rows.Element == OpencodeRow {
        var state = AgentState(source: .opencode, isSubagent: session.parentId != nil)
        state.thread = SessionThread(id: session.id, parentId: session.parentId, createdMs: session.createdMs)
        if let directory = session.directory { state.setProject(fromWorkingDirectory: directory) }
        for row in rows {
            guard let data = row.data else {
                state.malformedLines += 1
                continue
            }
            switch row.kind {
            case .assistant:
                if isForkCopy(data, session: session) { continue }
                state.noteLine(at: row.timeUpdated)
                state.modes = data.modes
                if let model = data.model, !model.isEmpty { state.model = model }
                if data.streamed == nil {
                    state.setPhase(.generating, at: row.timeUpdated, inFlightStartMs: data.created)
                } else {
                    state.setPhase(data.finishedWithToolCalls ? .tools : .idle, at: row.timeUpdated)
                }
            case .idle:
                state.noteLine(at: row.timeUpdated)
                state.setPhase(.idle, at: row.timeUpdated)
            case .compaction, .other:
                state.noteLine(at: row.timeUpdated)
            }
        }
        return state
    }
}
