import Foundation
import AgentSpeedCore

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
    var apiCostUSD: Double? = nil
    var unpricedRequests: Int = 0
    var cacheReadComplete: Bool = false
}

private struct ClientPriceKey: Hashable {
    let client: String
    let model: String
}

private struct ClientSummaryCacheKey: Hashable {
    let revision: Int64
    let since: Date?
}

private struct ClientSummaryReadResult {
    let summaries: [ClientUsageSummary]
    let pendingPriceCache: (revision: Int64, totals: [ClientPriceKey: ClientPriceTally])?
    let pendingSummaryCache: (key: ClientSummaryCacheKey, summaries: [ClientUsageSummary])?
}

private struct ClientCacheSessionKey: Hashable {
    let client: UsageClient
    let sessionID: String
}

private struct ClientPriceTally: Sendable {
    var knownCostMicroUSD: Int64?
    var unpricedRequests: Int = 0
    var hasKnownRequest = false
    var overflowed = false

    mutating func add(_ cost: Int64?) {
        guard let cost else {
            unpricedRequests = unpricedRequests == .max ? .max : unpricedRequests + 1
            return
        }
        hasKnownRequest = true
        guard !overflowed else { return }
        let (sum, overflow) = (knownCostMicroUSD ?? 0).addingReportingOverflow(cost)
        if overflow {
            overflowed = true
            knownCostMicroUSD = nil
        }
        else { knownCostMicroUSD = sum }
    }
}

private enum ExactBundledPriceEntry {
    case unique(PriceModel)
    case ambiguous
}

struct MultiClientFileCheckpoint: Sendable {
    let offset: Int64
    let size: Int64
    let modified: Double
    let identity: String
}

/// An additive ledger in its own file. Never opens or migrates the Codex accounting database.
final class MultiClientUsageLedger: @unchecked Sendable {
    static let schemaVersion = 2
    let database: SQLiteDatabaseDriver
    let url: URL
    private let pricingCacheLock = NSLock()
    private var cachedPricingRevision: Int64?
    private var cachedPricingTotals: [ClientPriceKey: ClientPriceTally] = [:]
    private let summaryCacheLock = NSLock()
    private var cachedSummaryRows: [ClientSummaryCacheKey: [ClientUsageSummary]] = [:]
    private var summaryCacheOrder: [ClientSummaryCacheKey] = []
    private let summaryCacheLimit = 8

    private static let exactBundledPriceEntries: [String: ExactBundledPriceEntry] = {
        var entries: [String: ExactBundledPriceEntry] = [:]
        for priceModel in PriceBook.bundled.models {
            for identifier in [priceModel.id] + priceModel.aliases {
                let key = identifier.lowercased()
                guard !key.isEmpty else { continue }
                switch entries[key] {
                case nil:
                    entries[key] = .unique(priceModel)
                case .some(.unique(let previous)) where previous.id == priceModel.id:
                    break
                default:
                    entries[key] = .ambiguous
                }
            }
        }
        return entries
    }()

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
                try connection.execute("CREATE INDEX IF NOT EXISTS client_usage_by_time ON client_usage_events(timestamp,client)")
                try connection.execute("PRAGMA user_version=2")
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

    /// Reads bounded per-request rankings and complete per-session numeric aggregates from the
    /// existing event table. This projection does not create indexes, mutate checkpoints, or
    /// rewrite events/revisions. Requests with unknown cache-read fields remain visible with a
    /// nil rate and are never counted as zero-hit or low-hit.
    func cacheRankingProjection(
        clients: Set<UsageClient>? = nil,
        since: Date? = nil,
        order: ClientCacheRankingOrder = .lowestHit,
        requestLimit requestedLimit: Int = 500
    ) throws -> ClientCacheRankingProjection {
        try Self.cacheRankingProjection(
            in: database,
            clients: clients,
            since: since,
            order: order,
            requestLimit: requestedLimit
        )
    }

    /// Opens only an existing database with read-only flags. A query cannot create or upgrade the ledger.
    static func readOnlyCacheRankingProjection(
        url: URL,
        clients: Set<UsageClient>? = nil,
        since: Date? = nil,
        order: ClientCacheRankingOrder = .lowestHit,
        requestLimit: Int = 500
    ) throws -> ClientCacheRankingProjection {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, busyTimeoutMilliseconds: 500)
        return try cacheRankingProjection(
            in: database,
            clients: clients,
            since: since,
            order: order,
            requestLimit: requestLimit
        )
    }

    private static func cacheRankingProjection(
        in database: SQLiteDatabaseDriver,
        clients: Set<UsageClient>?,
        since: Date?,
        order: ClientCacheRankingOrder,
        requestLimit requestedLimit: Int
    ) throws -> ClientCacheRankingProjection {
        if let clients, clients.isEmpty { return .empty }
        let requestLimit = min(max(requestedLimit, 0), 5_000)
        var predicates: [String] = []
        var bindings: [SQLiteBinding] = []
        if let since {
            predicates.append("timestamp >= ?")
            bindings.append(.date(since))
        }
        if let clients {
            let identifiers = clients.map(\.rawValue).sorted()
            predicates.append("client IN (\(Array(repeating: "?", count: identifiers.count).joined(separator: ",")))")
            bindings.append(contentsOf: identifiers.map(SQLiteBinding.text))
        }
        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        let requestSort: String
        switch order {
        case .lowestHit:
            requestSort = """
                CASE WHEN cache_read_tokens IS NULL OR input_tokens <= 0 THEN 1 ELSE 0 END ASC,
                CASE WHEN cache_read_tokens IS NOT NULL AND input_tokens > 0
                     THEN CAST(MIN(MAX(cache_read_tokens,0),input_tokens) AS REAL) / input_tokens ELSE 2 END ASC,
                CASE WHEN cache_read_tokens IS NOT NULL
                     THEN MAX(input_tokens-MIN(MAX(cache_read_tokens,0),input_tokens),0) ELSE 0 END DESC,
                timestamp DESC, client COLLATE BINARY, event_id COLLATE BINARY
                """
        case .latest:
            requestSort = "timestamp DESC, client COLLATE BINARY, event_id COLLATE BINARY"
        }

        return try database.withConnection { connection in
            try connection.readTransaction { snapshot in
                let matchingRequestCount = try snapshot.readRows(
                    "SELECT COUNT(*) FROM client_usage_events \(whereClause)\(whereClause.isEmpty ? "WHERE " : " AND ")input_tokens >= ?",
                    bindings: bindings + [.int64(ClientCacheRankingPolicy.minimumInputTokens)]
                ) { $0.int(0) ?? 0 }.first ?? 0

                let requests = try snapshot.readRows("""
                    SELECT client,event_id,session_id,model,timestamp,input_tokens,output_tokens,
                           cache_read_tokens,cache_write_tokens
                    FROM client_usage_events \(whereClause)\(whereClause.isEmpty ? "WHERE " : " AND ")input_tokens >= ?
                    ORDER BY \(requestSort) LIMIT ?
                    """, bindings: bindings + [
                        .int64(ClientCacheRankingPolicy.minimumInputTokens), .int64(Int64(requestLimit))
                    ]) { row -> ClientCacheRankingRequest? in
                    guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil }
                    let inputTokens = row.int64(5) ?? 0
                    let cacheReadTokens = row.int64(7).map { min(max($0, 0), inputTokens) }
                    return ClientCacheRankingRequest(
                        client: client,
                        eventID: row.text(1) ?? "",
                        sessionID: row.text(2) ?? "",
                        model: row.text(3) ?? "unknown",
                        timestamp: row.date(4) ?? .distantPast,
                        inputTokens: inputTokens,
                        outputTokens: row.int64(6) ?? 0,
                        cacheReadTokens: cacheReadTokens,
                        cacheWriteTokens: row.int64(8)
                    )
                }.compactMap { $0 }

                let rawSessions = try snapshot.readRows("""
                    SELECT client,session_id,SUM(input_tokens),SUM(output_tokens),
                           SUM(CASE WHEN cache_read_tokens IS NOT NULL THEN MIN(MAX(cache_read_tokens,0),input_tokens) END),
                           SUM(cache_write_tokens),COUNT(*),MIN(timestamp),MAX(timestamp),
                           SUM(cache_read_tokens IS NULL),SUM(cache_write_tokens IS NULL),
                           SUM(CASE WHEN input_tokens >= ? AND cache_read_tokens IS NOT NULL
                                    AND CAST(MIN(MAX(cache_read_tokens,0),input_tokens) AS REAL) / NULLIF(input_tokens,0) < ? THEN 1 ELSE 0 END),
                           SUM(CASE WHEN input_tokens > 0 AND cache_read_tokens = 0 THEN 1 ELSE 0 END)
                    FROM client_usage_events \(whereClause)
                    GROUP BY client,session_id HAVING SUM(input_tokens) >= ?
                    ORDER BY MAX(timestamp) DESC,client COLLATE BINARY,session_id COLLATE BINARY
                    """, bindings: [
                        .int64(ClientCacheRankingPolicy.lowHitMinimumInputTokens),
                        .double(ClientCacheRankingPolicy.lowHitRate)
                    ] + bindings + [.int64(ClientCacheRankingPolicy.minimumInputTokens)]) { row -> ClientCacheRankingSession? in
                    guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil }
                    let unknownRead = row.int(9) ?? 0
                    let unknownWrite = row.int(10) ?? 0
                    return ClientCacheRankingSession(
                        client: client,
                        sessionID: row.text(1) ?? "",
                        inputTokens: row.int64(2) ?? 0,
                        outputTokens: row.int64(3) ?? 0,
                        cacheReadTokens: unknownRead == 0 ? row.int64(4) : nil,
                        cacheWriteTokens: unknownWrite == 0 ? row.int64(5) : nil,
                        requests: row.int(6) ?? 0,
                        firstSeen: row.date(7) ?? .distantPast,
                        lastSeen: row.date(8) ?? .distantPast,
                        unknownCacheReadRequests: unknownRead,
                        unknownCacheWriteRequests: unknownWrite,
                        lowHitRequests: row.int(11) ?? 0,
                        zeroHitRequests: row.int(12) ?? 0,
                        modelIDs: []
                    )
                }.compactMap { $0 }

                let modelRows = try snapshot.readRows("""
                    SELECT client,session_id,model FROM client_usage_events \(whereClause)
                    GROUP BY client,session_id,model ORDER BY client COLLATE BINARY,session_id COLLATE BINARY,model COLLATE BINARY
                    """, bindings: bindings) { row -> (ClientCacheSessionKey, String)? in
                    guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil }
                    return (ClientCacheSessionKey(client: client, sessionID: row.text(1) ?? ""), row.text(2) ?? "unknown")
                }.compactMap { $0 }
                var modelsBySession: [ClientCacheSessionKey: [String]] = [:]
                for (key, model) in modelRows { modelsBySession[key, default: []].append(model) }
                let sessions = rawSessions.map { session in
                    ClientCacheRankingSession(
                        client: session.client,
                        sessionID: session.sessionID,
                        inputTokens: session.inputTokens,
                        outputTokens: session.outputTokens,
                        cacheReadTokens: session.cacheReadTokens,
                        cacheWriteTokens: session.cacheWriteTokens,
                        requests: session.requests,
                        firstSeen: session.firstSeen,
                        lastSeen: session.lastSeen,
                        unknownCacheReadRequests: session.unknownCacheReadRequests,
                        unknownCacheWriteRequests: session.unknownCacheWriteRequests,
                        lowHitRequests: session.lowHitRequests,
                        zeroHitRequests: session.zeroHitRequests,
                        modelIDs: modelsBySession[ClientCacheSessionKey(client: session.client, sessionID: session.sessionID)] ?? []
                    )
                }
                return ClientCacheRankingProjection(
                    requests: requests,
                    sessions: sessions,
                    matchingRequestCount: matchingRequestCount,
                    requestLimit: requestLimit
                )
            }
        }
    }

    func trendBuckets(now: Date = Date()) throws -> [ClientTrendBucket] {
        let start = now.timeIntervalSince1970 - 30 * 86400
        return try database.readRows("""
        SELECT client,CAST(timestamp/300 AS INTEGER)*300,SUM(input_tokens),SUM(output_tokens),
        SUM(cache_read_tokens),SUM(cache_write_tokens),SUM(reasoning_tokens),COUNT(*)
        FROM client_usage_events WHERE timestamp >= ? AND timestamp <= ?
        GROUP BY client,CAST(timestamp/300 AS INTEGER) ORDER BY 2,1
        """, bindings: [.double(start), .date(now)]) { row in
            guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil as ClientTrendBucket? }
            return ClientTrendBucket(client: client, startUnix: row.int64(1) ?? 0, inputTokens: row.int64(2) ?? 0,
                outputTokens: row.int64(3) ?? 0, cacheReadTokens: row.int64(4), cacheWriteTokens: row.int64(5),
                reasoningTokens: row.int64(6), requests: row.int(7) ?? 0)
        }.compactMap { $0 }
    }

    /// Daily event totals for the last 365 local calendar dates. SQLite's
    /// localtime modifier follows the same system timezone as Calendar.current;
    /// local midnight is converted back to Unix seconds for the shared model.
    func dailyBuckets(now: Date = Date()) throws -> [ClientTrendBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        return try database.readRows("""
        SELECT client,
        CAST(strftime('%s',date(timestamp,'unixepoch','localtime'),'utc') AS INTEGER),
        SUM(input_tokens),SUM(output_tokens),SUM(cache_read_tokens),SUM(cache_write_tokens),
        SUM(reasoning_tokens),COUNT(*)
        FROM client_usage_events WHERE timestamp >= ? AND timestamp <= ?
        GROUP BY client,date(timestamp,'unixepoch','localtime') ORDER BY 2,1
        """, bindings: [.date(firstDay), .date(now)]) { row in
            guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil as ClientTrendBucket? }
            return ClientTrendBucket(client: client, startUnix: row.int64(1) ?? 0, inputTokens: row.int64(2) ?? 0,
                outputTokens: row.int64(3) ?? 0, cacheReadTokens: row.int64(4), cacheWriteTokens: row.int64(5),
                reasoningTokens: row.int64(6), requests: row.int(7) ?? 0)
        }.compactMap { $0 }
    }

    func summaries(since: Date? = nil) throws -> [ClientUsageSummary] {
        try database.withConnection { connection in
            let result = try connection.readTransaction { snapshot -> ClientSummaryReadResult in
                let revision = try snapshot.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") {
                    $0.int64(0) ?? 0
                }.first ?? 0
                let summaryKey = ClientSummaryCacheKey(revision: revision, since: since)
                if let cached = cachedSummaries(for: summaryKey) {
                    return ClientSummaryReadResult(summaries: cached, pendingPriceCache: nil, pendingSummaryCache: nil)
                }
                let (priceTallies, computedForRevision) = try pricingTotals(
                    in: snapshot,
                    since: since,
                    revision: since == nil ? revision : nil
                )
                let summaries = try snapshot.readRows("""
                SELECT client,model,SUM(input_tokens),SUM(output_tokens),SUM(cache_read_tokens),SUM(cache_write_tokens),
                SUM(reasoning_tokens),COUNT(*),MAX(timestamp),SUM(cache_read_tokens IS NULL OR cache_write_tokens IS NULL OR reasoning_tokens IS NULL),
                SUM(cache_read_tokens IS NULL)=0
                FROM client_usage_events WHERE timestamp >= ? GROUP BY client,model ORDER BY MAX(timestamp) DESC
                """, bindings: [.date(since ?? Date(timeIntervalSince1970: 0))]) { row in
                    guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return nil as ClientUsageSummary? }
                    let model = row.text(1) ?? "unknown"
                    let tally = priceTallies[ClientPriceKey(client: client.rawValue, model: model)]
                    let apiCostUSD: Double?
                    if let tally, tally.hasKnownRequest, !tally.overflowed, let knownCost = tally.knownCostMicroUSD {
                        apiCostUSD = Double(knownCost) / 1_000_000
                    } else {
                        apiCostUSD = nil
                    }
                    return ClientUsageSummary(client: client, model: model, inputTokens: row.int64(2) ?? 0,
                        outputTokens: row.int64(3) ?? 0, cacheReadTokens: row.int64(4), cacheWriteTokens: row.int64(5),
                        reasoningTokens: row.int64(6), requests: row.int(7) ?? 0, lastSeen: row.date(8) ?? .distantPast,
                        incompleteFields: (row.int(9) ?? 0) > 0, apiCostUSD: apiCostUSD,
                        unpricedRequests: tally?.unpricedRequests ?? 0, cacheReadComplete: row.int(10) == 1)
                }.compactMap { $0 }
                let pendingPriceCache = computedForRevision ? (revision, priceTallies) : nil
                return ClientSummaryReadResult(
                    summaries: summaries,
                    pendingPriceCache: pendingPriceCache,
                    pendingSummaryCache: (summaryKey, summaries)
                )
            }

            if let (revision, priceTallies) = result.pendingPriceCache {
                pricingCacheLock.lock()
                cachedPricingRevision = revision
                cachedPricingTotals = priceTallies
                pricingCacheLock.unlock()
            }
            if let (key, summaries) = result.pendingSummaryCache {
                cacheSummaries(summaries, for: key)
            }
            return result.summaries
        }
    }

    private func cachedSummaries(for key: ClientSummaryCacheKey) -> [ClientUsageSummary]? {
        summaryCacheLock.lock()
        defer { summaryCacheLock.unlock() }
        guard let summaries = cachedSummaryRows[key] else { return nil }
        summaryCacheOrder.removeAll { $0 == key }
        summaryCacheOrder.append(key)
        return summaries
    }

    private func cacheSummaries(_ summaries: [ClientUsageSummary], for key: ClientSummaryCacheKey) {
        summaryCacheLock.lock()
        defer { summaryCacheLock.unlock() }
        cachedSummaryRows[key] = summaries
        summaryCacheOrder.removeAll { $0 == key }
        summaryCacheOrder.append(key)
        while summaryCacheOrder.count > summaryCacheLimit {
            cachedSummaryRows.removeValue(forKey: summaryCacheOrder.removeFirst())
        }
    }

    private func pricingTotals(
        in connection: SQLiteDatabaseConnection,
        since: Date?,
        revision: Int64?
    ) throws -> ([ClientPriceKey: ClientPriceTally], Bool) {
        if let revision {
            pricingCacheLock.lock()
            let cached = cachedPricingRevision == revision ? cachedPricingTotals : nil
            pricingCacheLock.unlock()
            if let cached { return (cached, false) }
        }

        var totals: [ClientPriceKey: ClientPriceTally] = [:]
        try connection.forEachRow("""
        SELECT client,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,timestamp
        FROM client_usage_events WHERE timestamp >= ?
        """, bindings: [.date(since ?? Date(timeIntervalSince1970: 0))]) { row in
            guard let client = UsageClient(rawValue: row.text(0) ?? "") else { return }
            let model = row.text(1) ?? "unknown"
            let key = ClientPriceKey(client: client.rawValue, model: model)
            let cost = Self.apiCostMicroUSD(
                model: model,
                input: row.int64(2) ?? 0,
                output: row.int64(3) ?? 0,
                cacheRead: row.int64(4),
                cacheWrite: row.int64(5),
                timestamp: row.double(6)
            )
            var tally = totals[key] ?? ClientPriceTally(knownCostMicroUSD: nil)
            tally.add(cost)
            totals[key] = tally
        }
        return (totals, revision != nil)
    }

    private static func apiCostMicroUSD(
        model rawModel: String,
        input: Int64,
        output: Int64,
        cacheRead: Int64?,
        cacheWrite: Int64?,
        timestamp: Double? = nil
    ) -> Int64? {
        var identifier = rawModel.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !identifier.isEmpty else { return nil }

        var explicitFast = false
        var entry = exactBundledPriceEntries[identifier]
        if entry == nil, identifier.hasSuffix("-fast") {
            identifier.removeLast("-fast".count)
            entry = exactBundledPriceEntries[identifier]
            explicitFast = true
        }
        guard case .unique(let priceModel)? = entry else { return nil }
        if priceModel.isFree { return 0 }
        let endMs = timestamp.flatMap { value -> Int64? in
            guard value.isFinite, abs(value) < Double(Int64.max) / 1_000 - 1 else { return nil }
            return Int64((value * 1_000).rounded(.down))
        }
        let timeDependent = !priceModel.periods.isEmpty || priceModel.pricing?.offPeak != nil
        guard !timeDependent || explicitFast || endMs != nil,
              let pricing = priceModel.pricing(endMs: endMs, fast: explicitFast) else { return nil }

        let rates = pricing.select(inputTokens: input).prices
        let resolvedCacheWrite: Int64? = cacheWrite
            ?? (rates.cacheWrite == rates.input && rates.cacheWrite1h == rates.input ? 0 : nil)
        guard input >= 0, output >= 0,
              let cacheRead, let cacheWrite = resolvedCacheWrite,
              cacheRead >= 0, cacheWrite >= 0,
              cacheRead <= input, cacheWrite <= input - cacheRead,
              cacheWrite == 0 || rates.cacheWrite == rates.cacheWrite1h else { return nil }
        let uncachedInput = input - cacheRead - cacheWrite
        let maxClass = ResponseCost.maxClassTokens
        guard uncachedInput <= maxClass, cacheRead <= maxClass, cacheWrite <= maxClass, output <= maxClass else { return nil }

        // Keep Token Bar's exact-model, period, lifetime and size admission
        // rules above; reuse the upstream integer classes, tier and rounding.
        // Do not call the broader fuzzy model resolver for historical billing.
        let usage = AgentSpeedCore.TokenUsage(input: Int(input), cachedInput: Int(cacheRead),
            cacheWriteInput: Int(cacheWrite), output: Int(output))
        return ResponseCost.microUsd(ResponseCost.picoUsd(usage: usage, pricing: pricing).pico)
    }
}
