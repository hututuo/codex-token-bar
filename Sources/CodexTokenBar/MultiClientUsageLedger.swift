import Foundation

struct ClientUsageSummary: Identifiable, Equatable, Sendable {
    var id: String { client.rawValue + ":" + model }
    let client: UsageClient
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let reasoningTokens: Int64?
    let requests: Int
    let lastSeen: Date
    let incompleteFields: Bool
}

struct MultiClientFileCheckpoint: Sendable {
    let offset: Int64
    let size: Int64
    let modified: Double
    let identity: String
}

/// An additive ledger in its own file. Never opens or migrates the Codex accounting database.
final class MultiClientUsageLedger: @unchecked Sendable {
    static let schemaVersion = 1
    let database: SQLiteDatabaseDriver
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        database = SQLiteDatabaseDriver(url: url, enableWAL: true)
        let version = try database.readRows("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
        guard version <= Self.schemaVersion else { throw LedgerError.newerSchema(version) }
        if version < Self.schemaVersion {
            // A preexisting unversioned database is backed up too; VACUUM INTO includes committed WAL data.
            let tables = try database.readRows("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) ?? "" }
            if !tables.isEmpty { _ = try backup() }
            try database.transaction { connection in
                try connection.execute("""
                CREATE TABLE IF NOT EXISTS client_usage_events (
                    client TEXT NOT NULL, event_id TEXT NOT NULL, session_id TEXT NOT NULL,
                    model TEXT NOT NULL, timestamp REAL NOT NULL,
                    input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER,
                    payload TEXT NOT NULL, PRIMARY KEY(client,event_id));
                """)
                try connection.execute("""
                CREATE TABLE IF NOT EXISTS client_usage_revisions (
                    revision INTEGER PRIMARY KEY AUTOINCREMENT, client TEXT NOT NULL,
                    event_id TEXT NOT NULL, captured_at REAL NOT NULL, payload TEXT NOT NULL);
                """)
                try connection.execute("""
                CREATE TABLE IF NOT EXISTS client_file_checkpoints (
                    client TEXT NOT NULL, source_key TEXT NOT NULL, offset INTEGER NOT NULL,
                    size INTEGER NOT NULL, modified REAL NOT NULL, identity TEXT NOT NULL,
                    PRIMARY KEY(client,source_key));
                """)
                try connection.execute("CREATE INDEX IF NOT EXISTS client_usage_by_model ON client_usage_events(client,model,timestamp)")
                try connection.execute("PRAGMA user_version=1")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    enum LedgerError: LocalizedError {
        case newerSchema(Int), invalidEvent
        var errorDescription: String? {
            switch self {
            case .newerSchema(let version): "多客户端账本版本 \(version) 比当前软件新，已停止写入"
            case .invalidEvent: "日志包含无效 Token 计数，未写入账本"
            }
        }
    }

    @discardableResult func backup() throws -> URL {
        let folder = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent("multi-client-usage-\(UUID().uuidString).sqlite")
        try database.execute("VACUUM INTO ?", bindings: [.text(target.path)])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    /// The latest request record is the projection; every changed record remains in the revision ledger.
    /// Checkpoint and data commit together so a crash cannot skip uncommitted usage.
    @discardableResult func ingest(_ events: [ClientUsageEvent], client: UsageClient? = nil,
                                  sourceKey: String? = nil, checkpoint: MultiClientFileCheckpoint? = nil) throws -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try events.map { event -> (ClientUsageEvent, String) in
            let counts = [event.inputTokens, event.outputTokens] + [event.cacheReadTokens, event.cacheWriteTokens, event.reasoningTokens].compactMap { $0 }
            guard !event.eventID.isEmpty, event.timestamp.timeIntervalSince1970.isFinite,
                  counts.allSatisfy({ $0 >= 0 && $0 <= 10_000_000_000_000 }) else { throw LedgerError.invalidEvent }
            return (event, String(decoding: try encoder.encode(event), as: UTF8.self))
        }
        return try database.transaction { connection in
            var changed = 0
            for (incoming, originalPayload) in encoded {
                var event = incoming
                var payload = originalPayload
                let key: [SQLiteBinding] = [.text(event.client.rawValue), .text(event.eventID)]
                let previous = try connection.readRows("SELECT payload FROM client_usage_events WHERE client=? AND event_id=?", bindings: key) { $0.text(0) }.first ?? nil
                if let previous, let old = try? Self.decode(previous), old.sessionID == event.sessionID {
                    event = old.mergingUpdate(event)
                    payload = String(decoding: try encoder.encode(event), as: UTF8.self)
                }
                guard previous != payload else { continue }
                try connection.execute("INSERT INTO client_usage_revisions(client,event_id,captured_at,payload) VALUES(?,?,?,?)",
                                       bindings: key + [.date(Date()), .text(originalPayload)])
                try connection.execute("""
                INSERT INTO client_usage_events VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(client,event_id) DO UPDATE SET session_id=excluded.session_id,model=excluded.model,
                timestamp=excluded.timestamp,input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,
                cache_read_tokens=excluded.cache_read_tokens,cache_write_tokens=excluded.cache_write_tokens,
                reasoning_tokens=excluded.reasoning_tokens,payload=excluded.payload
                """, bindings: key + [.text(event.sessionID), .text(event.model), .date(event.timestamp),
                    .int64(event.inputTokens), .int64(event.outputTokens),
                    event.cacheReadTokens.map(SQLiteBinding.int64) ?? .null,
                    event.cacheWriteTokens.map(SQLiteBinding.int64) ?? .null,
                    event.reasoningTokens.map(SQLiteBinding.int64) ?? .null, .text(payload)])
                changed += 1
            }
            if let client, let sourceKey, let checkpoint {
                try connection.execute("""
                INSERT INTO client_file_checkpoints VALUES(?,?,?,?,?,?) ON CONFLICT(client,source_key)
                DO UPDATE SET offset=excluded.offset,size=excluded.size,modified=excluded.modified,identity=excluded.identity
                """, bindings: [.text(client.rawValue), .text(sourceKey), .int64(checkpoint.offset), .int64(checkpoint.size),
                                  .double(checkpoint.modified), .text(checkpoint.identity)])
            }
            return changed
        }
    }

    private static func decode(_ payload: String) throws -> ClientUsageEvent {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(ClientUsageEvent.self, from: Data(payload.utf8))
    }

    func checkpoint(client: UsageClient, sourceKey: String) throws -> MultiClientFileCheckpoint? {
        try database.readRows("SELECT offset,size,modified,identity FROM client_file_checkpoints WHERE client=? AND source_key=?",
                              bindings: [.text(client.rawValue), .text(sourceKey)]) {
            MultiClientFileCheckpoint(offset: $0.int64(0) ?? 0, size: $0.int64(1) ?? 0, modified: $0.double(2) ?? 0, identity: $0.text(3) ?? "")
        }.first
    }

    func summaries(since: Date? = nil) throws -> [ClientUsageSummary] {
        try database.readRows("""
        SELECT client,model,SUM(input_tokens),SUM(output_tokens),SUM(cache_read_tokens),SUM(cache_write_tokens),
        SUM(reasoning_tokens),COUNT(*),MAX(timestamp),SUM(cache_read_tokens IS NULL OR cache_write_tokens IS NULL OR reasoning_tokens IS NULL)
        FROM client_usage_events WHERE timestamp >= ? GROUP BY client,model ORDER BY MAX(timestamp) DESC
        """, bindings: [.date(since ?? Date(timeIntervalSince1970: 0))]) { row in
            guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil as ClientUsageSummary? }
            return ClientUsageSummary(client: client, model: row.text(1) ?? "unknown", inputTokens: row.int64(2) ?? 0,
                outputTokens: row.int64(3) ?? 0, cacheReadTokens: row.int64(4), cacheWriteTokens: row.int64(5),
                reasoningTokens: row.int64(6), requests: row.int(7) ?? 0, lastSeen: row.date(8) ?? .distantPast,
                incompleteFields: (row.int(9) ?? 0) > 0)
        }.compactMap { $0 }
    }
}
