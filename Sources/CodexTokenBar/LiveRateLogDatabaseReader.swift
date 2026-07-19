import Foundation

final class LiveRateLogDatabaseReader: LiveRateLogReading, @unchecked Sendable {
    private static let rowLimit = 2_000
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
        try globalLogBatch(afterID: afterID).rows
    }

    func globalLogBatch(afterID: Int) throws -> LiveRateLogReadBatch {
        try database.withConnection { connection in
            let maxID = try connection.readRows(
                "SELECT coalesce(max(id), ?) FROM logs WHERE id > ?;",
                bindings: [.int(afterID), .int(afterID)]
            ) { statement in
                statement.int(0) ?? afterID
            }.first ?? afterID
            guard maxID > afterID else {
                return LiveRateLogReadBatch(rows: [], scannedThroughID: afterID)
            }

            let rows = try logRows(
                connection: connection,
                sql: Self.globalLogRowsSQL,
                bindings: [.int(afterID), .int(maxID)]
            )
            let scannedThroughID = rows.count < Self.rowLimit
                ? maxID
                : max(afterID, rows.last?.id ?? afterID)
            return LiveRateLogReadBatch(rows: rows, scannedThroughID: scannedThroughID)
        }
    }

    func globalLogRows(since timestamp: TimeInterval) throws -> [LiveRateMonitor.LogRow] {
        try logRows(sql: Self.globalLogRowsSQL(since: timestamp))
    }

    private func logRows(
        connection: SQLiteDatabaseConnection? = nil,
        sql: String,
        bindings: [SQLiteBinding] = []
    ) throws -> [LiveRateMonitor.LogRow] {
        let map: (SQLiteStatement) -> LiveRateMonitor.LogRow = { statement in
            LiveRateMonitor.LogRow(
                id: statement.int(0) ?? 0,
                threadID: statement.text(1),
                ts: statement.int(2) ?? 0,
                tsNanos: statement.int(3) ?? 0,
                target: statement.text(4) ?? "",
                feedbackLogBody: statement.text(5) ?? ""
            )
        }
        if let connection {
            return try connection.readRows(sql, bindings: bindings, map: map)
        }
        return try database.readRows(sql, bindings: bindings, map: map)
    }

    private static var globalLogRowsSQL: String {
        """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE id > ?
          AND id <= ?
          AND \(usableStreamRowsPredicate)
        ORDER BY id ASC
        LIMIT \(rowLimit);
        """
    }

    private static func globalLogRowsSQL(since timestamp: TimeInterval) -> String {
        let sinceSeconds = Int(timestamp.rounded(.down))
        return """
        SELECT id, thread_id, ts, ts_nanos, target, feedback_log_body
        FROM logs
        WHERE ts >= \(sinceSeconds)
          AND \(usableStreamRowsPredicate)
        ORDER BY id ASC
        LIMIT 2000;
        """
    }

    private static var usableStreamRowsPredicate: String {
        let usefulTypes = """
        (
          feedback_log_body LIKE '%"type":"response.output_text.delta"%'
          OR feedback_log_body LIKE '%"type":"response.function_call_arguments.delta"%'
          OR feedback_log_body LIKE '%"type":"response.custom_tool_call_input.delta"%'
          OR feedback_log_body LIKE '%"type":"response.output_item.added"%'
        )
        """
        return """
        (
          (
            target = 'codex_api::sse::responses'
            AND feedback_log_body LIKE 'SSE event:%'
            AND \(usefulTypes)
          )
          OR (
            target = 'codex_api::endpoint::responses_websocket'
            AND feedback_log_body LIKE '%websocket event:%'
            AND \(usefulTypes)
          )
          OR (
            target = 'log'
            AND feedback_log_body LIKE 'Received message %'
            AND \(usefulTypes)
          )
        )
        """
    }
}
