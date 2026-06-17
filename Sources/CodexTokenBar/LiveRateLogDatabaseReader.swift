import Foundation

final class LiveRateLogDatabaseReader: LiveRateLogReading, @unchecked Sendable {
    let path: String
    private let database: SQLitePersistentDatabaseReader

    init(path: String) {
        self.path = path
        self.database = SQLitePersistentDatabaseReader(
            url: URL(fileURLWithPath: path),
            busyTimeoutMilliseconds: 100
        )
    }

    func globalLogRows(afterID: Int) throws -> [LiveRateMonitor.LogRow] {
        try logRows(sql: Self.globalLogRowsSQL(afterID: afterID))
    }

    func globalLogRows(since timestamp: TimeInterval) throws -> [LiveRateMonitor.LogRow] {
        try logRows(sql: Self.globalLogRowsSQL(since: timestamp))
    }

    private func logRows(sql: String) throws -> [LiveRateMonitor.LogRow] {
        try database.readRows(sql) { statement in
            LiveRateMonitor.LogRow(
                id: statement.int(0) ?? 0,
                threadID: statement.text(1),
                ts: statement.int(2) ?? 0,
                tsNanos: statement.int(3) ?? 0,
                target: statement.text(4) ?? "",
                feedbackLogBody: statement.text(5) ?? ""
            )
        }
    }

    private static func globalLogRowsSQL(afterID: Int) -> String {
        """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE id > \(afterID)
          AND (
            (
              target = 'codex_api::sse::responses'
              AND (
                feedback_log_body LIKE 'SSE event:%'
                OR feedback_log_body LIKE '%thread.id=%'
                OR feedback_log_body LIKE '%thread_id=%'
                OR feedback_log_body LIKE '%conversation.id=%'
              )
            )
            OR (
              target = 'codex_api::endpoint::responses_websocket'
              AND feedback_log_body LIKE '%websocket event:%'
            )
          )
        ORDER BY id ASC
        LIMIT 2000;
        """
    }

    private static func globalLogRowsSQL(since timestamp: TimeInterval) -> String {
        let sinceSeconds = Int(timestamp.rounded(.down))
        return """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE ts >= \(sinceSeconds)
          AND (
            (
              target = 'codex_api::sse::responses'
              AND (
                feedback_log_body LIKE 'SSE event:%'
                OR feedback_log_body LIKE '%thread.id=%'
                OR feedback_log_body LIKE '%thread_id=%'
                OR feedback_log_body LIKE '%conversation.id=%'
              )
            )
            OR (
              target = 'codex_api::endpoint::responses_websocket'
              AND feedback_log_body LIKE '%websocket event:%'
            )
          )
        ORDER BY id ASC
        LIMIT 2000;
        """
    }
}
