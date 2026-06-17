import Foundation

extension LiveRateMonitor {
    nonisolated static func recentThreads(stateDB: String) throws -> [ThreadRow] {
        let sql = """
        SELECT id, title, rollout_path, coalesce(updated_at_ms, updated_at * 1000) AS updated_at_ms
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at_ms DESC, updated_at DESC
        LIMIT 20;
        """
        return try sqliteRows(db: stateDB, sql: sql) { statement in
            ThreadRow(
                id: sqliteText(statement, 0) ?? "",
                title: sqliteText(statement, 1) ?? "",
                updatedAtMS: sqliteInt(statement, 3),
                rolloutPath: sqliteText(statement, 2) ?? ""
            )
        }
    }

    nonisolated static func maxLogID(logsDB: String, threadID: String) throws -> Int {
        let sql = "SELECT coalesce(max(id), 0) AS maxID FROM logs WHERE thread_id = ?;"
        return try sqliteScalarInt(db: logsDB, sql: sql, bindings: [.text(threadID)])
    }

    nonisolated static func maxGlobalLogID(logsDB: String) throws -> Int {
        let sql = "SELECT coalesce(max(id), 0) AS maxID FROM logs;"
        return try sqliteScalarInt(db: logsDB, sql: sql)
    }

    nonisolated static func logRows(logsDB: String, threadID: String, afterID: Int) throws -> [LogRow] {
        let sql = """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE thread_id = ?
          AND id > ?
          AND target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket event:%'
        ORDER BY id ASC
        LIMIT 500;
        """
        return try sqliteRows(db: logsDB, sql: sql, bindings: [.text(threadID), .int(afterID)]) { statement in
            LogRow(
                id: sqliteInt(statement, 0),
                threadID: sqliteText(statement, 1),
                ts: sqliteInt(statement, 2),
                tsNanos: sqliteInt(statement, 3),
                target: sqliteText(statement, 4) ?? "",
                feedbackLogBody: sqliteText(statement, 5) ?? ""
            )
        }
    }
}
