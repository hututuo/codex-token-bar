import Foundation

/// Read-only access to OpenCode's `opencode.db` (METRICS 4.5, 5.2). Every query is its own short read transaction,
/// so OpenCode's checkpoints are never held back.
final class OpencodeDatabase {
    static let fileName = "opencode.db"
    static let requiredTables: Set<String> = ["session_v2", "session_message"]

    enum OpenError: Error, Equatable {
        case missing
        case unreadable
        /// The tables or columns of METRICS 4.5 are absent.
        case unsupported
    }

    struct SessionActivity: Equatable, Sendable {
        var rows: Int64
        var lastUpdatedMs: Int64
    }

    let path: String
    /// Opened with `immutable=1` because OpenCode had closed the database (no `-wal`, METRICS 4.5).
    let isImmutable: Bool
    private let openedStat: FileStat
    private let connection: SQLiteConnection
    private let sessionsStatement: SQLiteStatement
    private let sessionsSinceStatement: SQLiteStatement
    private let sessionRowsStatement: SQLiteStatement
    private let sessionRowsSinceStatement: SQLiteStatement
    private let rowsCreatedSinceStatement: SQLiteStatement
    private let maxCreatedStatement: SQLiteStatement

    private static let sessionColumns = "id, parent_id, directory, time_created, time_updated"
    private static let rowColumns = "id, session_id, type, seq, time_created, time_updated, data"

    private struct Statements {
        var sessions: SQLiteStatement
        var sessionsSince: SQLiteStatement
        var sessionRows: SQLiteStatement
        var sessionRowsSince: SQLiteStatement
        var rowsCreatedSince: SQLiteStatement
        var maxCreated: SQLiteStatement
    }

    /// OpenCode closes a WAL database cleanly by removing its `-wal` and `-shm` files (METRICS 4.5). Then — the
    /// header says WAL and no `-wal` exists — the file is opened `immutable=1`, which creates nothing. Otherwise it is
    /// opened `mode=ro`, falling back to `immutable=1` when that fails while no `-wal` exists.
    init(path: String) throws(OpenError) {
        guard let stat = FileStat.stat(path), stat.isRegularFile else { throw .missing }
        self.path = path
        openedStat = stat
        var opened: (SQLiteConnection, Statements)
        var immutable = false
        if FileStat.stat(path + "-wal") == nil, Self.headerSaysWAL(path) {
            opened = try Self.open(path, mode: .immutable)
            immutable = true
        } else {
            do {
                opened = try Self.open(path, mode: .readOnly)
            } catch .unreadable where FileStat.stat(path + "-wal") == nil {
                opened = try Self.open(path, mode: .immutable)
                immutable = true
            }
        }
        isImmutable = immutable
        connection = opened.0
        sessionsStatement = opened.1.sessions
        sessionsSinceStatement = opened.1.sessionsSince
        sessionRowsStatement = opened.1.sessionRows
        sessionRowsSinceStatement = opened.1.sessionRowsSince
        rowsCreatedSinceStatement = opened.1.rowsCreatedSince
        maxCreatedStatement = opened.1.maxCreated
    }

    private static func open(_ path: String, mode: SQLiteConnection.Mode) throws(OpenError) -> (SQLiteConnection, Statements) {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: path, mode: mode)
        } catch {
            throw .unreadable
        }
        do {
            let tables = try tableNames(connection)
            guard requiredTables.isSubset(of: tables) else { throw OpenError.unsupported }
            let statements = Statements(
                sessions: try connection.prepare("SELECT \(sessionColumns) FROM session_v2"),
                sessionsSince: try connection.prepare("SELECT \(sessionColumns) FROM session_v2 WHERE time_updated >= ?1"),
                sessionRows: try connection.prepare(
                    "SELECT \(rowColumns) FROM session_message WHERE session_id = ?1 ORDER BY seq"),
                sessionRowsSince: try connection.prepare(
                    "SELECT \(rowColumns) FROM session_message WHERE session_id = ?1 AND time_updated >= ?2 ORDER BY seq"),
                rowsCreatedSince: try connection.prepare(
                    "SELECT \(rowColumns) FROM session_message WHERE time_created >= ?1 ORDER BY session_id, seq"),
                maxCreated: try connection.prepare("SELECT max(time_created) FROM session_message")
            )
            return (connection, statements)
        } catch let error as OpenError {
            throw error
        } catch let error as SQLiteError {
            throw classify(error)
        } catch {
            throw .unreadable
        }
    }

    /// Bytes 18 and 19 of the database header (read and write format versions) are both 2 in WAL mode.
    static func headerSaysWAL(_ path: String) -> Bool {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var header = [UInt8](repeating: 0, count: 20)
        let count = header.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, 20, 0) }
        return count == 20 && header[18] == 2 && header[19] == 2
    }

    /// An immutable connection must be dropped as soon as the database changes or a `-wal` appears.
    var isStale: Bool {
        guard isImmutable else { return false }
        if FileStat.stat(path + "-wal") != nil { return true }
        guard let stat = FileStat.stat(path) else { return true }
        return stat.size != openedStat.size || stat.modifiedNs != openedStat.modifiedNs || stat.identity != openedStat.identity
    }

    /// `opencode.db` inside a configured folder; a configured path that names the database file itself also works.
    static func databasePath(forRoot root: String) -> String {
        if let stat = FileStat.stat(root), stat.isRegularFile { return root }
        return (root as NSString).appendingPathComponent(fileName)
    }

    private static func tableNames(_ connection: SQLiteConnection) throws -> Set<String> {
        let statement = try connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        var names: Set<String> = []
        try statement.forEachRow { row in
            if let name = row.string(0) { names.insert(name) }
        }
        return names
    }

    /// A prepare failure on an opened database means the schema differs.
    private static func classify(_ error: SQLiteError) -> OpenError {
        let primary = error.code & 0xFF
        return primary == 1 ? .unsupported : .unreadable
    }

    // MARK: - Sessions

    func sessions() throws -> [OpencodeSessionInfo] {
        try readSessions(sessionsStatement)
    }

    func sessions(updatedSince ms: Int64) throws -> [OpencodeSessionInfo] {
        sessionsSinceStatement.bind(1, ms)
        return try readSessions(sessionsSinceStatement)
    }

    private func readSessions(_ statement: SQLiteStatement) throws -> [OpencodeSessionInfo] {
        var sessions: [OpencodeSessionInfo] = []
        try statement.forEachRow { row in
            guard let id = row.string(0) else { return }
            sessions.append(OpencodeSessionInfo(
                id: id,
                parentId: row.string(1),
                directory: row.string(2),
                createdMs: row.int64(3),
                updatedMs: row.int64(4)
            ))
        }
        return sessions
    }

    /// Rows and the latest `time_updated` of every session (one scan of the table).
    func sessionActivity() throws -> [String: SessionActivity] {
        let statement = try connection.prepare(
            "SELECT session_id, count(*), max(time_updated) FROM session_message GROUP BY session_id")
        var activity: [String: SessionActivity] = [:]
        try statement.forEachRow { row in
            guard let id = row.string(0) else { return }
            activity[id] = SessionActivity(rows: row.int64(1), lastUpdatedMs: row.int64(2))
        }
        return activity
    }

    // MARK: - Rows

    /// Every row of a session in `seq` order. `skip` sees `(id, time_updated)` first and can avoid decoding `data`.
    func rows(session id: String, updatedSince ms: Int64? = nil, skip: (String, Int64) -> Bool = { _, _ in false }) throws -> [OpencodeRow] {
        let statement: SQLiteStatement
        if let ms {
            statement = sessionRowsSinceStatement
            statement.bind(2, ms)
        } else {
            statement = sessionRowsStatement
        }
        statement.bind(1, id)
        var rows: [OpencodeRow] = []
        try statement.forEachRow { row in
            if let decoded = Self.decodeRow(row, skip: skip) { rows.append(decoded.row) }
        }
        return rows
    }

    /// Rows created at or after `ms`, using the `time_created` index, with their session ids.
    func rows(createdSince ms: Int64, skip: (String, Int64) -> Bool = { _, _ in false }) throws -> [(session: String, row: OpencodeRow)] {
        rowsCreatedSinceStatement.bind(1, ms)
        var rows: [(session: String, row: OpencodeRow)] = []
        try rowsCreatedSinceStatement.forEachRow { row in
            if let decoded = Self.decodeRow(row, skip: skip) { rows.append(decoded) }
        }
        return rows
    }

    /// The current versions of the given rows.
    func rows(ids: [String], skip: (String, Int64) -> Bool = { _, _ in false }) throws -> [(session: String, row: OpencodeRow)] {
        guard !ids.isEmpty else { return [] }
        var rows: [(session: String, row: OpencodeRow)] = []
        let batch = 200
        var start = 0
        while start < ids.count {
            let slice = ids[start..<min(ids.count, start + batch)]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let statement = try connection.prepare(
                "SELECT \(Self.rowColumns) FROM session_message WHERE id IN (\(placeholders)) ORDER BY session_id, seq")
            for (offset, id) in slice.enumerated() { statement.bind(Int32(offset + 1), id) }
            try statement.forEachRow { row in
                if let decoded = Self.decodeRow(row, skip: skip) { rows.append(decoded) }
            }
            start += batch
        }
        return rows
    }

    func maxCreatedMs() throws -> Int64? {
        var value: Int64?
        try maxCreatedStatement.forEachRow { row in value = row.optionalInt64(0) }
        return value
    }

    private static func decodeRow(_ row: SQLiteStatement, skip: (String, Int64) -> Bool) -> (session: String, row: OpencodeRow)? {
        guard let id = row.string(0), let session = row.string(1) else { return nil }
        let updated = row.int64(5)
        if skip(id, updated) { return nil }
        let data = row.withText(6) { OpencodeDataExtractor.extract($0) }
        return (session, OpencodeRow(
            id: id,
            seq: row.int64(3),
            kind: OpencodeRow.kind(of: row.string(2)),
            timeCreated: row.int64(4),
            timeUpdated: updated,
            data: data
        ))
    }
}
