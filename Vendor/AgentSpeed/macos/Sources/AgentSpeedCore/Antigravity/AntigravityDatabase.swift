import Foundation

/// One read-only connection to an Antigravity conversation database (METRICS 4.8, 5.4). Never writes and never
/// creates a file: a closed WAL database (header says WAL, no `-wal`) is opened `immutable=1`; otherwise `mode=ro`,
/// falling back to `immutable=1` only when no `-wal` exists.
///
/// Used by one thread at a time; it moves with the reader that owns it.
final class AntigravityDatabase: @unchecked Sendable {
    /// Blobs larger than this are never loaded; `gen_metadata` rows embed whole prompts.
    static let maxBlobBytes = 1 << 20
    static let requiredStepColumns: Set<String> = ["idx", "step_type", "status", "metadata"]

    enum OpenError: Error, Equatable {
        case missing
        case unreadable
        /// No `steps` table with the columns of METRICS 4.8.
        case unsupported
    }

    /// Highest `idx` read so far per table (-1 before the first read).
    struct Cursors: Equatable, Sendable {
        var steps: Int64 = -1
        var generations: Int64 = -1
        var executors: Int64 = -1
        var trajectoryFound = false

        static let complete = Cursors()
    }

    let path: String
    let isImmutable: Bool
    /// A `-wal` existed when the connection opened (a running server).
    private let openedWithWAL: Bool
    private let openedStat: FileStat
    private let connection: SQLiteConnection
    private let stepsStatement: SQLiteStatement
    private let generationsStatement: SQLiteStatement?
    private let executorsStatement: SQLiteStatement?
    private let trajectoryStatement: SQLiteStatement?

    private static let stepColumns = "idx, step_type, status, CASE WHEN length(metadata) <= \(maxBlobBytes) THEN metadata END"

    init(path: String) throws(OpenError) {
        guard let stat = FileStat.lstat(path), stat.isRegularFile else { throw .missing }
        self.path = path
        openedStat = stat
        let hasWAL = FileStat.lstat(path + "-wal") != nil
        var immutable = !hasWAL && Self.headerSaysWAL(path)
        var opened: SQLiteConnection
        do {
            opened = try Self.connect(path, mode: immutable ? .immutable : .readOnly)
        } catch where !immutable && FileStat.lstat(path + "-wal") == nil {
            opened = try Self.connect(path, mode: .immutable)
            immutable = true
        }
        isImmutable = immutable
        openedWithWAL = hasWAL
        connection = opened
        guard let columns = try? Self.columns(of: "steps", in: opened) else { throw .unreadable }
        guard Self.requiredStepColumns.isSubset(of: columns) else { throw .unsupported }
        do {
            stepsStatement = try opened.prepare("SELECT \(Self.stepColumns) FROM steps WHERE idx > ?1 ORDER BY idx, rowid")
        } catch {
            throw .unreadable
        }
        // Missing optional tables only mean those rows never exist.
        generationsStatement = try? opened.prepare("""
            SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= \(Self.maxBlobBytes) AND length(data) <= \(Self.maxBlobBytes) \
            THEN data END FROM gen_metadata WHERE idx > ?1 ORDER BY idx, rowid
            """)
        executorsStatement = try? opened.prepare("""
            SELECT idx, CASE WHEN length(data) <= \(Self.maxBlobBytes) THEN data END FROM executor_metadata \
            WHERE idx > ?1 ORDER BY idx, rowid
            """)
        trajectoryStatement = try? opened.prepare("""
            SELECT CASE WHEN length(data) <= \(Self.maxBlobBytes) THEN data END FROM trajectory_metadata_blob \
            ORDER BY rowid LIMIT 1
            """)
    }

    /// Opens and checks that the file can be queried at all (a `mode=ro` open of a closed WAL database fails here).
    private static func connect(_ path: String, mode: SQLiteConnection.Mode) throws(OpenError) -> SQLiteConnection {
        do {
            let connection = try SQLiteConnection(path: path, mode: mode)
            try connection.execute("SELECT 1 FROM sqlite_master LIMIT 1")
            return connection
        } catch {
            throw .unreadable
        }
    }

    private static func columns(of table: String, in connection: SQLiteConnection) throws -> Set<String> {
        let statement = try connection.prepare("SELECT name FROM pragma_table_info('\(table)')")
        var names: Set<String> = []
        try statement.forEachRow { row in
            if let name = row.string(0) { names.insert(name) }
        }
        return names
    }

    static func headerSaysWAL(_ path: String) -> Bool {
        OpencodeDatabase.headerSaysWAL(path)
    }

    /// An immutable connection is valid only while the database file is unchanged and no `-wal` exists. A `mode=ro`
    /// connection opened beside a `-wal` is stale once that `-wal` is gone: the server exited and checkpointed, and
    /// keeping the connection would hold its deleted `-shm` and trip the server's next start.
    var isStale: Bool {
        guard isImmutable else { return openedWithWAL && FileStat.lstat(path + "-wal") == nil }
        if FileStat.lstat(path + "-wal") != nil { return true }
        guard let stat = FileStat.lstat(path) else { return true }
        return stat.size != openedStat.size || stat.modifiedNs != openedStat.modifiedNs || stat.identity != openedStat.identity
    }

    /// Reads the rows above the cursors plus the current versions of `openSteps`, in one short read transaction.
    func read(after cursors: Cursors, openSteps: Set<Int64>) throws -> AntigravityBatch {
        try connection.execute("BEGIN")
        defer { try? connection.execute("COMMIT") }
        var batch = AntigravityBatch()
        if !cursors.trajectoryFound, let trajectoryStatement {
            try trajectoryStatement.forEachRow { row in
                guard !row.isNull(0) else { return }
                batch.trajectory = row.withBlob(0) { AntigravityBlobs.trajectory($0) }
            }
        }
        if let generationsStatement {
            generationsStatement.bind(1, cursors.generations)
            try generationsStatement.forEachRow { row in
                batch.generations.append(AntigravityIndexedRow(
                    idx: row.int64(0), value: row.isNull(1) ? nil : row.withBlob(1) { AntigravityBlobs.generation($0) }))
            }
        }
        if let executorsStatement {
            executorsStatement.bind(1, cursors.executors)
            try executorsStatement.forEachRow { row in
                batch.executors.append(AntigravityIndexedRow(
                    idx: row.int64(0), value: row.isNull(1) ? nil : row.withBlob(1) { AntigravityBlobs.executor($0) }))
            }
        }
        let reread = openSteps.filter { $0 <= cursors.steps }.sorted()
        if !reread.isEmpty {
            for chunk in stride(from: 0, to: reread.count, by: 200).map({ reread[$0..<min(reread.count, $0 + 200)] }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let statement = try connection.prepare(
                    "SELECT \(Self.stepColumns) FROM steps WHERE idx IN (\(placeholders)) ORDER BY idx, rowid")
                for (offset, idx) in chunk.enumerated() { statement.bind(Int32(offset + 1), idx) }
                try statement.forEachRow { batch.steps.append(Self.step($0)) }
            }
        }
        stepsStatement.bind(1, cursors.steps)
        try stepsStatement.forEachRow { batch.steps.append(Self.step($0)) }
        return batch
    }

    private static func step(_ row: SQLiteStatement) -> AntigravityStepRow {
        AntigravityStepRow(
            idx: row.int64(0),
            stepType: row.int64(1),
            status: row.int64(2),
            metadata: row.isNull(3) ? nil : row.withBlob(3) { AntigravityBlobs.stepMetadata($0) }
        )
    }
}
