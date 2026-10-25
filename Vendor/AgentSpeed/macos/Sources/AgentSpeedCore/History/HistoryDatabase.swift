import Foundation

/// The persistent daily-history store (METRICS 8): file identities, the 64-bit hashes of the response keys each file
/// owns, per-file per-day contributions and day peaks. Only aggregates are stored — never keys in plain text or content.
final class HistoryDatabase {
    /// 2: per-model `measured_output` and `measured_ms`. 3: cost per contribution and model, day bindings of the
    /// price tables and their copies (METRICS 9.7).
    static let schemaVersion: Int64 = 3

    enum Failure: Error, Equatable {
        /// Written by a newer version of the app; left untouched.
        case newerSchema
    }

    /// A file (or OpenCode session) with its identity and contributions.
    struct Entry: Equatable, Sendable {
        var id: Int64?
        /// `TranscriptFamily` raw value, or `opencode`.
        var family: String
        var size: Int64
        var modified: Int64
        var version: Int64
        var days: [UsageKey: DayAggregate]

        /// Some response has no known price (METRICS 9.7 re-analysis).
        var hasUnpriced: Bool {
            days.values.contains { ($0.cost?.unpricedRequests ?? 0) > 0 }
        }
    }

    let path: String
    let connection: SQLiteConnection

    /// Opens (creating when needed) the store at `path`; `:memory:` keeps it in memory.
    convenience init(path: String) throws {
        try self.init(path: path, migrating: true)
    }

    /// Without `migrating`, a store of an older schema keeps its version and only gets `meta` and `day_traffic`;
    /// a new store always gets the full schema. A newer store throws before anything is changed.
    private init(path: String, migrating: Bool) throws {
        self.path = path
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        connection = try SQLiteConnection(path: path, mode: .readWriteCreate)
        let version = try scalar("PRAGMA user_version") ?? 0
        guard version <= Self.schemaVersion else { throw Failure.newerSchema }
        if path != ":memory:" { try connection.execute("PRAGMA journal_mode = WAL") }
        try connection.execute("PRAGMA synchronous = NORMAL")
        if migrating || version == 0 {
            try migrate()
        } else {
            try connection.execute(Self.metaTableSQL)
        }
        try connection.execute(Self.trafficTableSQL)
        if migrating || version == 0 { try connection.execute(Self.modeTableSQL) }
    }

    static func inMemory() throws -> HistoryDatabase {
        try HistoryDatabase(path: ":memory:")
    }

    /// Removes a store and its WAL files.
    static func delete(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func migrate() throws {
        let version = try scalar("PRAGMA user_version") ?? 0
        guard version <= Self.schemaVersion else { throw Failure.newerSchema }
        guard version < Self.schemaVersion else { return }
        if version >= 1 {
            // The analysis version moved with each step, so every file is analysed again and fills the new columns;
            // contributions of files that are gone keep NULL costs (METRICS 8).
            try connection.transaction {
                if version == 1 {
                    try connection.execute("""
                        ALTER TABLE contribution_models ADD COLUMN measured_output INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE contribution_models ADD COLUMN measured_ms INTEGER NOT NULL DEFAULT 0;
                        """)
                }
                try connection.execute("""
                    ALTER TABLE contributions ADD COLUMN cost_micro_usd INTEGER;
                    ALTER TABLE contributions ADD COLUMN unpriced_requests INTEGER;
                    ALTER TABLE contribution_models ADD COLUMN cost_micro_usd INTEGER;
                    ALTER TABLE contribution_models ADD COLUMN unpriced_requests INTEGER;
                    \(Self.priceTablesSQL)
                    PRAGMA user_version = \(Self.schemaVersion);
                    """)
            }
            return
        }
        try connection.transaction {
            try connection.execute("""
                \(Self.metaTableSQL)
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    family TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    modified INTEGER NOT NULL,
                    version INTEGER NOT NULL,
                    keys BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS contributions (
                    file_id INTEGER NOT NULL,
                    day TEXT NOT NULL,
                    source TEXT NOT NULL,
                    requests INTEGER NOT NULL,
                    input INTEGER NOT NULL,
                    cached_input INTEGER NOT NULL,
                    cache_write_input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    reasoning INTEGER NOT NULL,
                    measured_output INTEGER NOT NULL,
                    measured_ms INTEGER NOT NULL,
                    unfinalized INTEGER NOT NULL,
                    agents INTEGER NOT NULL,
                    cost_micro_usd INTEGER,
                    unpriced_requests INTEGER,
                    PRIMARY KEY (file_id, day, source)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS contribution_models (
                    file_id INTEGER NOT NULL,
                    day TEXT NOT NULL,
                    source TEXT NOT NULL,
                    model TEXT NOT NULL,
                    requests INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    measured_output INTEGER NOT NULL,
                    measured_ms INTEGER NOT NULL,
                    cost_micro_usd INTEGER,
                    unpriced_requests INTEGER,
                    PRIMARY KEY (file_id, day, source, model)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS day_peaks (day TEXT PRIMARY KEY, peak REAL NOT NULL) WITHOUT ROWID;
                \(Self.priceTablesSQL)
                PRAGMA user_version = \(Self.schemaVersion);
                """)
        }
    }

    private static let metaTableSQL = """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        """

    /// Day → price table version, and a copy of every version a binding references (METRICS 9.7).
    private static let priceTablesSQL = """
        CREATE TABLE IF NOT EXISTS price_bindings (day TEXT PRIMARY KEY, version INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS price_tables (version INTEGER PRIMARY KEY, body BLOB NOT NULL);
        """

    /// Observed traffic per day and key (METRICS 10.9). Created on every open rather than by a schema version step:
    /// older builds refuse a newer `user_version`, and they must keep using the store and ignore this table.
    private static let trafficTableSQL = """
        CREATE TABLE IF NOT EXISTS day_traffic (
            day TEXT NOT NULL,
            key TEXT NOT NULL,
            rx INTEGER NOT NULL,
            tx INTEGER NOT NULL,
            rx_tools INTEGER NOT NULL,
            tx_tools INTEGER NOT NULL,
            sampled_ms INTEGER NOT NULL,
            PRIMARY KEY (day, key)
        ) WITHOUT ROWID;
        """

    private func scalar(_ sql: String) throws -> Int64? {
        let statement = try connection.prepare(sql)
        var value: Int64?
        try statement.forEachRow { value = $0.optionalInt64(0) }
        return value
    }

    // MARK: - Meta

    func meta(_ key: String) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM meta WHERE key = ?1")
        statement.bind(1, key)
        var value: String?
        try statement.forEachRow { value = $0.string(0) }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        let statement = try connection.prepare(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        statement.bind(1, key)
        statement.bind(2, value)
        try statement.run()
    }

    // MARK: - Files

    /// Every stored file with its contributions, by path.
    func loadEntries() throws -> [String: Entry] {
        var paths: [Int64: String] = [:]
        var entries: [String: Entry] = [:]
        let files = try connection.prepare("SELECT id, path, family, size, modified, version FROM files")
        try files.forEachRow { row in
            guard let path = row.string(1) else { return }
            let id = row.int64(0)
            paths[id] = path
            entries[path] = Entry(id: id, family: row.string(2) ?? "", size: row.int64(3), modified: row.int64(4),
                                  version: row.int64(5), days: [:])
        }
        let contributions = try connection.prepare("""
            SELECT file_id, day, source, requests, input, cached_input, cache_write_input, output, reasoning,
                   measured_output, measured_ms, unfinalized, agents, cost_micro_usd, unpriced_requests FROM contributions
            """)
        try contributions.forEachRow { row in
            guard let path = paths[row.int64(0)], let day = row.string(1),
                  let source = row.string(2).flatMap(SourceKind.init(rawValue:)) else { return }
            var aggregate = DayAggregate()
            aggregate.totals = TokenTotals(
                requests: Int(row.int64(3)), input: Int(row.int64(4)), cachedInput: Int(row.int64(5)),
                cacheWriteInput: Int(row.int64(6)), output: Int(row.int64(7)), reasoning: Int(row.int64(8)))
            aggregate.measuredOutput = Int(row.int64(9))
            aggregate.measuredMs = row.int64(10)
            aggregate.unfinalized = Int(row.int64(11))
            aggregate.agents = Int(row.int64(12))
            aggregate.cost = Self.cost(row, 13)
            entries[path]?.days[UsageKey(day: day, source: source)] = aggregate
        }
        let models = try connection.prepare("""
            SELECT file_id, day, source, model, requests, output, measured_output, measured_ms, cost_micro_usd,
                   unpriced_requests FROM contribution_models
            """)
        try models.forEachRow { row in
            guard let path = paths[row.int64(0)], let day = row.string(1),
                  let source = row.string(2).flatMap(SourceKind.init(rawValue:)), let model = row.string(3) else { return }
            let key = UsageKey(day: day, source: source)
            guard entries[path]?.days[key] != nil else { return }
            entries[path]?.days[key]?.models[model] = ModelTally(
                requests: Int(row.int64(4)), output: Int(row.int64(5)), measuredOutput: Int(row.int64(6)), measuredMs: row.int64(7),
                cost: Self.cost(row, 8))
        }
        try loadModes(into: &entries, paths: paths)
        return entries
    }

    /// A cost pair stored at `column` and `column + 1`; nil when it was stored before costs existed.
    private static func cost(_ row: SQLiteStatement, _ column: Int32) -> CostTally? {
        guard let micro = row.optionalInt64(column), let unpriced = row.optionalInt64(column + 1) else { return nil }
        return CostTally(costMicroUsd: micro, unpricedRequests: Int(unpriced))
    }

    /// Adds the key hashes owned by every stored file except `excluded` to a hashed deduper.
    func loadKeys(excluding excluded: Set<Int64>, into deduper: inout Deduper) throws {
        let statement = try connection.prepare("SELECT id, keys FROM files")
        var buffer: [UInt64] = []
        try statement.forEachRow { row in
            guard !excluded.contains(row.int64(0)) else { return }
            buffer.removeAll(keepingCapacity: true)
            row.withBlob(1) { Self.unpack($0, into: &buffer) }
            deduper.insertSettled(buffer)
        }
    }

    /// The key hashes one stored file owns.
    func keys(ofFile id: Int64) throws -> [UInt64] {
        let statement = try connection.prepare("SELECT keys FROM files WHERE id = ?1")
        statement.bind(1, id)
        var keys: [UInt64] = []
        try statement.forEachRow { row in row.withBlob(0) { Self.unpack($0, into: &keys) } }
        return keys
    }

    func storedKeyCount() throws -> Int64 {
        try scalar("SELECT coalesce(sum(length(keys)), 0) / 8 FROM files") ?? 0
    }

    /// Saves files with their owned keys and contributions in one transaction; returns their row ids by path.
    @discardableResult
    func save(_ files: [(path: String, entry: Entry, keys: [UInt64])]) throws -> [String: Int64] {
        guard !files.isEmpty else { return [:] }
        return try connection.transaction {
            let upsert = try connection.prepare("""
                INSERT INTO files (path, family, size, modified, version, keys) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(path) DO UPDATE SET family = excluded.family, size = excluded.size,
                    modified = excluded.modified, version = excluded.version, keys = excluded.keys
                RETURNING id
                """)
            let clearDays = try connection.prepare("DELETE FROM contributions WHERE file_id = ?1")
            let clearModels = try connection.prepare("DELETE FROM contribution_models WHERE file_id = ?1")
            let insertDay = try connection.prepare("""
                INSERT INTO contributions (file_id, day, source, requests, input, cached_input, cache_write_input,
                    output, reasoning, measured_output, measured_ms, unfinalized, agents, cost_micro_usd, unpriced_requests)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                """)
            let insertModel = try connection.prepare("""
                INSERT INTO contribution_models (file_id, day, source, model, requests, output, measured_output, measured_ms,
                    cost_micro_usd, unpriced_requests)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                """)
            var ids: [String: Int64] = [:]
            for (path, entry, keys) in files {
                upsert.bind(1, path)
                upsert.bind(2, entry.family)
                upsert.bind(3, entry.size)
                upsert.bind(4, entry.modified)
                upsert.bind(5, entry.version)
                Self.pack(keys) { upsert.bind(6, blob: $0) }
                var id: Int64?
                try upsert.forEachRow { id = $0.int64(0) }
                guard let id else { continue }
                ids[path] = id
                clearDays.bind(1, id)
                try clearDays.run()
                clearModels.bind(1, id)
                try clearModels.run()
                try deleteModes(fileId: id)
                for (key, day) in entry.days {
                    try saveModes(day.modes.values.sorted { $0.id < $1.id }, fileId: id, day: key.day, source: key.source)
                    insertDay.bind(1, id)
                    insertDay.bind(2, key.day)
                    insertDay.bind(3, key.source.rawValue)
                    insertDay.bind(4, day.totals.requests)
                    insertDay.bind(5, day.totals.input)
                    insertDay.bind(6, day.totals.cachedInput)
                    insertDay.bind(7, day.totals.cacheWriteInput)
                    insertDay.bind(8, day.totals.output)
                    insertDay.bind(9, day.totals.reasoning)
                    insertDay.bind(10, day.measuredOutput)
                    insertDay.bind(11, day.measuredMs)
                    insertDay.bind(12, day.unfinalized)
                    insertDay.bind(13, day.agents)
                    insertDay.bind(14, day.cost?.costMicroUsd)
                    insertDay.bind(15, day.cost.map { Int64($0.unpricedRequests) })
                    try insertDay.run()
                    for (model, tally) in day.models {
                        insertModel.bind(1, id)
                        insertModel.bind(2, key.day)
                        insertModel.bind(3, key.source.rawValue)
                        insertModel.bind(4, model)
                        insertModel.bind(5, tally.requests)
                        insertModel.bind(6, tally.output)
                        insertModel.bind(7, tally.measuredOutput)
                        insertModel.bind(8, tally.measuredMs)
                        insertModel.bind(9, tally.cost?.costMicroUsd)
                        insertModel.bind(10, tally.cost.map { Int64($0.unpricedRequests) })
                        try insertModel.run()
                    }
                }
            }
            return ids
        }
    }

    // MARK: - Price bindings (METRICS 9.7)

    func priceBindings() throws -> [String: Int] {
        let statement = try connection.prepare("SELECT day, version FROM price_bindings")
        var bindings: [String: Int] = [:]
        try statement.forEachRow { row in
            if let day = row.string(0) { bindings[day] = Int(row.int64(1)) }
        }
        return bindings
    }

    /// The stored table copies, by version.
    func priceTables() throws -> [Int: Data] {
        let statement = try connection.prepare("SELECT version, body FROM price_tables")
        var tables: [Int: Data] = [:]
        try statement.forEachRow { row in
            tables[Int(row.int64(0))] = row.withBlob(1) { Data($0) }
        }
        return tables
    }

    /// Saves bindings, a copy of every table they reference that is not stored yet (`tables` supplies them), and
    /// deletes the copies no binding references any more.
    func savePriceBindings(_ bindings: [String: Int], tables: (Int) -> Data?) throws {
        guard !bindings.isEmpty else { return }
        try connection.transaction {
            let upsert = try connection.prepare("""
                INSERT INTO price_bindings (day, version) VALUES (?1, ?2)
                ON CONFLICT(day) DO UPDATE SET version = excluded.version
                """)
            for (day, version) in bindings.sorted(by: { $0.key < $1.key }) {
                upsert.bind(1, day)
                upsert.bind(2, version)
                try upsert.run()
            }
            var stored: Set<Int> = []
            try connection.prepare("SELECT version FROM price_tables").forEachRow { stored.insert(Int($0.int64(0))) }
            let insert = try connection.prepare("INSERT INTO price_tables (version, body) VALUES (?1, ?2)")
            for version in Set(bindings.values).subtracting(stored).sorted() {
                guard let body = tables(version) else { continue }
                insert.bind(1, version)
                body.withUnsafeBytes { insert.bind(2, blob: $0) }
                try insert.run()
            }
            try connection.execute("DELETE FROM price_tables WHERE version NOT IN (SELECT DISTINCT version FROM price_bindings)")
        }
    }

    /// Bindings and table copies of the store at `path`, read without changing it; empty when the store does not
    /// exist yet or predates costs. The app reads them before the live engine prices anything (METRICS 9.7).
    static func storedPricing(at path: String) -> (bindings: [String: Int], tables: [Int: Data]) {
        guard FileManager.default.fileExists(atPath: path),
              let connection = try? SQLiteConnection(path: path, mode: .readOnly) else { return ([:], [:]) }
        defer { connection.close() }
        var bindings: [String: Int] = [:]
        var tables: [Int: Data] = [:]
        do {
            try connection.prepare("SELECT day, version FROM price_bindings").forEachRow { row in
                if let day = row.string(0) { bindings[day] = Int(row.int64(1)) }
            }
            try connection.prepare("SELECT version, body FROM price_tables").forEachRow { row in
                tables[Int(row.int64(0))] = row.withBlob(1) { Data($0) }
            }
        } catch {
            return ([:], [:])
        }
        return (bindings, tables)
    }

    // MARK: - Peaks

    func peaks() throws -> [String: Double] {
        let statement = try connection.prepare("SELECT day, peak FROM day_peaks")
        var peaks: [String: Double] = [:]
        try statement.forEachRow { row in
            if let day = row.string(0) { peaks[day] = row.double(1) }
        }
        return peaks
    }

    /// Keeps the larger of the stored and the given peak.
    func recordPeak(_ peak: Double, day: String) throws {
        let statement = try connection.prepare("""
            INSERT INTO day_peaks (day, peak) VALUES (?1, ?2)
            ON CONFLICT(day) DO UPDATE SET peak = max(peak, excluded.peak)
            """)
        statement.bind(1, day)
        statement.bind(2, peak)
        try statement.run()
    }

    // MARK: - Traffic (METRICS 10.9)

    static let trafficSinceKey = "trafficSince"

    /// Every `day_traffic` row (sorted by day, then key) and `trafficSince` of the store at `path`, read without
    /// creating, migrating or changing anything; empty/nil when the store or the table does not exist or cannot be read.
    static func storedTraffic(at path: String) -> (days: [TrafficDay], since: String?) {
        guard FileManager.default.fileExists(atPath: path),
              let connection = try? SQLiteConnection(path: path, mode: .readOnly) else { return ([], nil) }
        defer { connection.close() }
        var days: [TrafficDay] = []
        var since: String?
        do {
            try connection.prepare("""
                SELECT day, key, rx, tx, rx_tools, tx_tools, sampled_ms FROM day_traffic ORDER BY day, key
                """).forEachRow { row in
                guard let day = row.string(0), let key = row.string(1) else { return }
                days.append(TrafficDay(day: day, key: key, rx: row.int64(2), tx: row.int64(3), rxTools: row.int64(4),
                                       txTools: row.int64(5), sampledMs: row.int64(6)))
            }
            let statement = try connection.prepare("SELECT value FROM meta WHERE key = ?1")
            statement.bind(1, trafficSinceKey)
            try statement.forEachRow { since = $0.string(0) }
        } catch {
            return ([], nil)
        }
        return (days, since)
    }

    /// Upserts `rows` (by day and key) in one transaction and sets `trafficSince` to the smallest row day when it is
    /// absent or later. A missing store is created with the full current schema (as `init(path:)` does). An existing
    /// store of an older or the current schema only gets `day_traffic` (and `meta` if somehow missing) created when
    /// needed — it is never migrated here (the history worker migrates; two connections migrating at once would
    /// collide). A store with a newer `user_version` throws `Failure.newerSchema` and is left untouched. Empty `rows`
    /// is a no-op. Opens and closes its own connection, so it may run beside the history worker's.
    static func saveTraffic(_ rows: [TrafficDay], at path: String) throws {
        guard let first = rows.map(\.day).min() else { return }
        let database = try HistoryDatabase(path: path, migrating: false)
        defer { database.connection.close() }
        try database.connection.transaction {
            let upsert = try database.connection.prepare("""
                INSERT INTO day_traffic (day, key, rx, tx, rx_tools, tx_tools, sampled_ms)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(day, key) DO UPDATE SET rx = excluded.rx, tx = excluded.tx, rx_tools = excluded.rx_tools,
                    tx_tools = excluded.tx_tools, sampled_ms = excluded.sampled_ms
                """)
            for row in rows {
                upsert.bind(1, row.day)
                upsert.bind(2, row.key)
                upsert.bind(3, row.rx)
                upsert.bind(4, row.tx)
                upsert.bind(5, row.rxTools)
                upsert.bind(6, row.txTools)
                upsert.bind(7, row.sampledMs)
                try upsert.run()
            }
            let since = try database.connection.prepare("""
                INSERT INTO meta (key, value) VALUES (?1, ?2)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value WHERE excluded.value < meta.value
                """)
            since.bind(1, trafficSinceKey)
            since.bind(2, first)
            try since.run()
        }
    }

    // MARK: - Key packing

    /// Little-endian 8-byte hashes.
    private static func pack<T>(_ keys: [UInt64], _ body: (UnsafeRawBufferPointer) -> T) -> T {
        let little = keys.map(\.littleEndian)
        return little.withUnsafeBytes(body)
    }

    private static func unpack(_ bytes: UnsafeRawBufferPointer, into keys: inout [UInt64]) {
        let count = bytes.count / 8
        keys.reserveCapacity(keys.count + count)
        for index in 0..<count {
            keys.append(UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)))
        }
    }
}
