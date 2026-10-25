import Foundation

struct ZcodeBatch: Sendable {
    struct Session: Sendable {
        var id: String
        var parentId: String?
        var directory: String?
        var createdMs: Int64
        var updatedMs: Int64
    }
    struct Usage: Sendable {
        var id: String
        var sessionId: String
        var model: String?
        var provider: String?
        var status: String
        var startMs: Int64
        var endMs: Int64?
        var durationMs: Int64?
        var usage: TokenUsage
        var modes: ExecutionModes = .empty
    }
    var sessions: [Session]
    var rows: [Usage]
    var messageStates: [String: AgentState]
}

final class ZcodeDatabase {
    let path: String
    private let connection: SQLiteConnection

    init(path: String) throws {
        guard FileStat.stat(path)?.isRegularFile == true else {
            throw OpencodeDatabase.OpenError.missing
        }
        self.path = path
        let mode: SQLiteConnection.Mode = FileStat.stat(path + "-wal") == nil && OpencodeDatabase.headerSaysWAL(path)
            ? .immutable : .readOnly
        connection = try SQLiteConnection(path: path, mode: mode)
        _ = try connection.prepare("SELECT id, session_id, model_id, provider_id, status, started_at, completed_at, input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens, duration_ms FROM model_usage LIMIT 0")
        _ = try connection.prepare("SELECT id, parent_id, directory, time_created, time_updated FROM session LIMIT 0")
    }

    static func databasePath(forRoot root: String) -> String {
        if FileStat.stat(root)?.isRegularFile == true || root.hasSuffix(".sqlite") { return root }
        let candidates = ["db.sqlite", "db/db.sqlite", "cli/db/db.sqlite", ".zcode/cli/db/db.sqlite"]
        for candidate in candidates {
            let path = (root as NSString).appendingPathComponent(candidate)
            if FileStat.stat(path)?.isRegularFile == true { return path }
        }
        return (root as NSString).appendingPathComponent("db.sqlite")
    }

    func read(sinceMs: Int64? = nil) throws -> ZcodeBatch {
        let sessionRows = try connection.prepare("SELECT id, parent_id, directory, time_created, time_updated FROM session")
        var sessions: [ZcodeBatch.Session] = []
        try sessionRows.forEachRow { row in
            guard let id = row.string(0) else { return }
            sessions.append(.init(id: id, parentId: row.string(1), directory: row.string(2), createdMs: DayLabeler.hasDay(row.int64(3)) ? row.int64(3) : 0, updatedMs: DayLabeler.hasDay(row.int64(4)) ? row.int64(4) : 0))
        }
        let suffix = sinceMs == nil ? "" : " WHERE coalesce(completed_at, started_at) >= ?1 OR status = 'running'"
        let query = try connection.prepare("""
            SELECT id, session_id, model_id, provider_id, status, started_at, completed_at,
                   input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens, duration_ms
            FROM model_usage\(suffix) ORDER BY started_at, id
            """)
        if let sinceMs { query.bind(1, sinceMs) }
        let modeFacts = usageModes(sinceMs: sinceMs)
        var rows: [ZcodeBatch.Usage] = []
        try query.forEachRow { row in
            guard let id = row.string(0), let sessionId = row.string(1), let status = row.string(4) else { return }
            let start = row.int64(5), end = row.optionalInt64(6)
            guard DayLabeler.hasDay(start), end.map(DayLabeler.hasDay) ?? true else { return }
            let input = TokenCount.clamp(row.optionalInt64(7))
            let cacheRead = min(input, TokenCount.clamp(row.optionalInt64(11)))
            let output = TokenCount.clamp(row.optionalInt64(8))
            rows.append(.init(id: id, sessionId: sessionId, model: row.string(2), provider: row.string(3), status: status,
                              startMs: start, endMs: end, durationMs: row.optionalInt64(12),
                              usage: TokenUsage(input: input, cachedInput: cacheRead,
                                                cacheWriteInput: min(input, TokenCount.clamp(row.optionalInt64(10))),
                                                output: output, reasoning: min(output, TokenCount.clamp(row.optionalInt64(9)))),
                              modes: modeFacts[id] ?? .empty))
        }
        return ZcodeBatch(sessions: sessions, rows: rows, messageStates: try messageStates(sinceMs: nil))
    }

    func record(_ row: ZcodeBatch.Usage) -> ResponseRecord? {
        guard row.status != "running", let end = row.endMs else { return nil }
        let durationStart = row.durationMs.flatMap { $0 > 0 && $0 <= ResponseTiming.maxIntervalMs ? end - $0 : nil }
        return ResponseRecord(key: "zcode:" + row.id, source: .zcode, agentId: agentId(row.sessionId), model: row.model,
                              startMs: row.startMs > 0 ? row.startMs : durationStart, endMs: end, usage: row.usage, provider: row.provider, modes: row.modes)
    }

    private func usageModes(sinceMs: Int64?) -> [String: ExecutionModes] {
        let suffix = sinceMs == nil ? "" : " WHERE coalesce(u.completed_at,u.started_at)>=?1 OR u.status='running'"
        guard let query = try? connection.prepare("""
            SELECT u.id,u.provider_id,u.model_id,u.started_at,
                   CASE WHEN length(CAST(m.data AS BLOB))<=1048576 THEN m.data END
            FROM model_usage u LEFT JOIN message m ON m.id=u.parent_user_message_id AND m.session_id=u.session_id
            \(suffix)
            """) else { return [:] }
        if let sinceMs { query.bind(1, sinceMs) }
        var result: [String: ExecutionModes] = [:]
        try? query.forEachRow { row in
            guard let id = row.string(0), let json = row.withText(4, { try? JSONParser.parse(Data($0)) }),
                  json["role"]?.string == "user" else { return }
            result[id] = Self.highspeedModes(json["metadata"]?["highspeed"], provider: row.string(1),
                                              model: row.string(2), startedMs: row.int64(3))
        }
        return result
    }

    static func highspeedModes(_ metadata: JSONValue?, provider: String?, model: String?, startedMs: Int64) -> ExecutionModes {
        guard metadata?["schemaVersion"]?.int64 == 1,
              let card = metadata?["cardId"]?.string, !card.isEmpty,
              let selectedModel = metadata?["model"]?.string else { return .empty }
        var modes = ExecutionModeAdapters.fact(kind: .accelerator, raw: "highspeed", evidence: .selected,
                                                provider: "zcode", scope: .turn)
        guard !card.hasPrefix("hsc_mock_"), let provider else { return modes }
        if ["account:zai-highspeed-card", "account:bigmodel-highspeed-card"].contains(provider), model == selectedModel {
            modes = modes.merging(ExecutionModeAdapters.fact(kind: .accelerator, raw: "highspeed", evidence: .recorded,
                                                              provider: "zcode", scope: .request))
        } else if let fallback = metadata?["fallbackAt"]?.int64, startedMs >= fallback,
                  let native = ExecutionModeAdapters.fact(kind: .accelerator, raw: "fallback", evidence: .recorded,
                                                            provider: "zcode", scope: .request).facts.first {
            modes.insert(native.withCanonicalValue("standard"))
        }
        return modes
    }

    private func messageStates(sinceMs: Int64?) throws -> [String: AgentState] {
        guard let messages = try? connection.prepare("""
            SELECT m.id,m.session_id,m.time_created,m.time_updated,
                   CASE WHEN length(CAST(m.data AS BLOB)) <= 1048576 THEN m.data END
            FROM session s JOIN message m ON m.id=(
                SELECT id FROM message WHERE session_id=s.id ORDER BY time_created DESC,id DESC LIMIT 1)
            WHERE m.time_updated >= ?1
            """) else { return [:] }
        messages.bind(1, sinceMs ?? 0)
        var states: [String: AgentState] = [:]
        try messages.forEachRow { row in
            guard let message = row.string(0), let session = row.string(1),
                  let json = row.withText(4, { try? JSONParser.parse(Data($0)) }),
                  let role = json["role"]?.string, role == "user" || role == "assistant" else { return }
            let created = json["time"]?["created"]?.int64 ?? row.int64(2)
            let completed = json["time"]?["completed"]?.int64
            guard DayLabeler.hasDay(created), DayLabeler.hasDay(row.int64(3)), completed.map(DayLabeler.hasDay) ?? true else { return }
            let hasError = json["error"] != nil && json["error"] != .null
            let runningTool = role == "assistant" ? try hasRunningTool(message: message) : false
            let phase: AgentPhase = runningTool ? .tools
                : role == "user" || (completed == nil && !hasError) ? .generating : .idle
            var state = AgentState(source: .zcode)
            state.model = json["modelId"]?.string ?? json["modelID"]?.string
            state.modes = Self.highspeedModes(json["metadata"]?["highspeed"], provider: nil, model: nil, startedMs: created)
            state.noteLine(at: max(row.int64(3), completed ?? created))
            state.setPhase(phase, at: created, inFlightStartMs: phase == .generating ? created : nil)
            states[session] = state
        }
        return states
    }

    private func hasRunningTool(message: String) throws -> Bool {
        guard let parts = try? connection.prepare("SELECT CASE WHEN length(CAST(data AS BLOB)) <= 1048576 THEN data END FROM part WHERE message_id = ?1") else { return false }
        parts.bind(1, message)
        var running = false
        try parts.forEachRow { row in
            guard let json = row.withText(0, { try? JSONParser.parse(Data($0)) }), json["type"]?.string == "tool" else { return }
            let status = json["state"]?["status"]?.string
            if status == "pending" || status == "running" { running = true }
        }
        return running
    }

    func agentId(_ sessionId: String) -> String { path + "#" + sessionId }
}
