import Foundation

enum CacheRetentionError: LocalizedError {
    case unsupportedVersion, sourceChanged, oversizedLine, budgetExceeded
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "续问建议数据库版本暂不支持，原有用量统计不受影响。"
        case .sourceChanged: "部分日志正在写入，稍后继续更新续问建议。"
        case .oversizedLine: "有日志记录过大，该来源暂未加入续问建议。"
        case .budgetExceeded: "续问建议缓存已达到空间预算，暂停更新。"
        }
    }
}

struct CacheRetentionCheckpoint: Codable, Sendable {
    var generation: String
    var offset: UInt64 = 0
    var prefixDigest: String = ""
    var parser: CacheRetentionParser
    var parserRevision = CacheRetentionParser.revision
}

struct CacheRetentionSourceSummary: Sendable {
    let key: String
    /// An absent source reports an empty fingerprint so a later restoration
    /// republishes it while retaining and reusing its saved checkpoint.
    let fingerprint: String
    let session: String
    let isChild: Bool
    let explicitChild: Bool
}

/// One independent writer. Neither the exact index nor its schema is opened
/// for writing by this feature. Source facts/projection/checkpoint are atomic.
final class CacheRetentionDatabase {
    private static let schemaVersion = 2

    let url: URL
    private let driver: SQLiteDatabaseDriver
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var version = 0
        if FileManager.default.fileExists(atPath: url.path) {
            let ro = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
            version = try ro.readRows("PRAGMA user_version;") { $0.int(0) ?? 0 }.first ?? 0
            guard version <= Self.schemaVersion else { throw CacheRetentionError.unsupportedVersion }
            if version == Self.schemaVersion {
                let names = Set(try ro.readRows("SELECT name FROM sqlite_master WHERE type IN ('table','view')") { $0.text(0) }.compactMap { $0 })
                let required: Set<String> = ["retention_meta","retention_sources","retention_pairs",
                    "retention_own_turns","retention_generation_history","retention_pair_history",
                    "retention_own_turn_history","retention_all_pairs"]
                guard required.isSubset(of:names) else { throw CacheRetentionError.unsupportedVersion }
            }
        }
        let needsProjectionBackfill = version < Self.schemaVersion
        driver = SQLiteDatabaseDriver(url: url, busyTimeoutMilliseconds: 150, enableWAL: true)
        try driver.transaction { c in
            try c.execute("""
                CREATE TABLE IF NOT EXISTS retention_meta(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
                INSERT INTO retention_meta(id,revision) VALUES(1,0) ON CONFLICT(id) DO NOTHING;
                CREATE TABLE IF NOT EXISTS retention_sources(
                  source_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, session_key TEXT NOT NULL,
                  is_child INTEGER NOT NULL, explicit_child INTEGER NOT NULL, own_rounds INTEGER NOT NULL, generation TEXT NOT NULL,
                  checkpoint BLOB NOT NULL, present INTEGER NOT NULL DEFAULT 1,
                  fallback_own_rounds INTEGER NOT NULL DEFAULT 0);
                """)
            let sourceColumns = Set(try c.readRows("PRAGMA table_info(retention_sources);") {
                $0.text(1)
            }.compactMap { $0 })
            if !sourceColumns.contains("present") {
                guard version < Self.schemaVersion else {
                    throw CacheRetentionError.unsupportedVersion
                }
                try c.execute("ALTER TABLE retention_sources ADD COLUMN present INTEGER NOT NULL DEFAULT 1;")
            }
            if !sourceColumns.contains("fallback_own_rounds") {
                guard version < Self.schemaVersion else {
                    throw CacheRetentionError.unsupportedVersion
                }
                try c.execute("ALTER TABLE retention_sources ADD COLUMN fallback_own_rounds INTEGER NOT NULL DEFAULT 0;")
            }
            try c.execute("""
                CREATE TABLE IF NOT EXISTS retention_pairs(
                  pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
                  stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
                  model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS retention_pair_identity ON retention_pairs(stable_key,evidence_signature,eligible,pair_key);
                CREATE INDEX IF NOT EXISTS retention_pair_time ON retention_pairs(started_us,pair_key) WHERE eligible=1;
                CREATE INDEX IF NOT EXISTS retention_pair_model ON retention_pairs(model,started_us,pair_key) WHERE eligible=1;
                CREATE TABLE IF NOT EXISTS retention_own_turns(
                  source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
                  session_key TEXT NOT NULL, turn_id TEXT NOT NULL,
                  PRIMARY KEY(source_key,session_key,turn_id));
                CREATE INDEX IF NOT EXISTS retention_own_turn_identity ON retention_own_turns(session_key,turn_id);
                CREATE TABLE IF NOT EXISTS retention_generation_history(
                  source_key TEXT NOT NULL REFERENCES retention_sources(source_key), generation TEXT NOT NULL,
                  checkpoint BLOB NOT NULL, own_rounds INTEGER NOT NULL, fallback_own_rounds INTEGER NOT NULL,
                  is_child INTEGER NOT NULL, PRIMARY KEY(source_key,generation));
                CREATE TABLE IF NOT EXISTS retention_pair_history(
                  pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL, generation TEXT NOT NULL,
                  stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
                  model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS retention_pair_history_source
                  ON retention_pair_history(source_key,generation);
                CREATE INDEX IF NOT EXISTS retention_pair_history_identity
                  ON retention_pair_history(stable_key,evidence_signature,eligible,pair_key);
                CREATE INDEX IF NOT EXISTS retention_pair_history_time
                  ON retention_pair_history(started_us,pair_key) WHERE eligible=1;
                CREATE INDEX IF NOT EXISTS retention_pair_history_model
                  ON retention_pair_history(model,started_us,pair_key) WHERE eligible=1;
                CREATE TABLE IF NOT EXISTS retention_own_turn_history(
                  source_key TEXT NOT NULL, generation TEXT NOT NULL,
                  session_key TEXT NOT NULL, turn_id TEXT NOT NULL,
                  PRIMARY KEY(source_key,generation,session_key,turn_id));
                CREATE INDEX IF NOT EXISTS retention_own_turn_history_identity
                  ON retention_own_turn_history(session_key,turn_id);
                CREATE VIEW IF NOT EXISTS retention_all_pairs AS
                  SELECT p.pair_key,p.source_key,s.generation,p.stable_key,p.evidence_signature,
                         p.eligible,p.model,p.started_us,p.point,p.reasons
                  FROM retention_pairs p
                  JOIN retention_sources s ON s.source_key=p.source_key
                  WHERE s.is_child=0
                  UNION ALL
                  SELECT h.pair_key,h.source_key,h.generation,h.stable_key,h.evidence_signature,
                         h.eligible,h.model,h.started_us,h.point,h.reasons
                  FROM retention_pair_history h
                  JOIN retention_generation_history g
                    ON g.source_key=h.source_key AND g.generation=h.generation
                  JOIN retention_sources s ON s.source_key=h.source_key
                  WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation;
                """)
            if needsProjectionBackfill {
                try backfillOwnTurnProjection(connection: c)
            }
            try c.execute("PRAGMA user_version=2;")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func summaries() throws -> [String: CacheRetentionSourceSummary] {
        let rows = try driver.readRows("SELECT source_key,fingerprint,session_key,is_child,explicit_child,present FROM retention_sources;") { s in
            CacheRetentionSourceSummary(
                key: s.text(0)!,
                fingerprint: s.int(5) == 1 ? s.text(1)! : "",
                session: s.text(2)!,
                isChild: s.int(3) == 1,
                explicitChild: s.int(4) == 1
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
    }

    func checkpoint(_ key: String) throws -> CacheRetentionCheckpoint? {
        try driver.readRows("SELECT checkpoint FROM retention_sources WHERE source_key=?;", bindings: [.text(key)]) {
            try decoder.decode(CacheRetentionCheckpoint.self, from: $0.data(0)!)
        }.first
    }

    func publish(key: String, fingerprint: String, checkpoint: CacheRetentionCheckpoint) throws {
        let parser = checkpoint.parser
        let pairs = parser.pairs(source: key, generation: checkpoint.generation)
        let encoded = try encoder.encode(checkpoint)
        let own = parser.excludedSubagent ? 0 : parser.turns.filter(parser.isOwn).count
        let ownProjection = Self.ownTurnProjection(parser: parser, fallbackCount: own)
        try driver.transaction { c in
            let previousGeneration = try c.readRows(
                "SELECT generation FROM retention_sources WHERE source_key=?;",
                bindings: [.text(key)]
            ) { $0.text(0) }.first ?? nil
            if let previousGeneration, previousGeneration != checkpoint.generation {
                // Preserve the last complete generation before replacing the
                // current checkpoint and its projections. Same-generation
                // append updates still replace only the current facts.
                try c.execute("""
                    INSERT OR IGNORE INTO retention_generation_history(
                      source_key,generation,checkpoint,own_rounds,fallback_own_rounds,is_child)
                    SELECT source_key,generation,checkpoint,own_rounds,fallback_own_rounds,is_child
                    FROM retention_sources WHERE source_key=?;
                    """, bindings: [.text(key)])
                try c.execute("""
                    INSERT OR IGNORE INTO retention_pair_history(
                      pair_key,source_key,generation,stable_key,evidence_signature,eligible,model,started_us,point,reasons)
                    SELECT p.pair_key,p.source_key,s.generation,p.stable_key,p.evidence_signature,
                           p.eligible,p.model,p.started_us,p.point,p.reasons
                    FROM retention_pairs p
                    JOIN retention_sources s ON s.source_key=p.source_key
                    WHERE p.source_key=?;
                    """, bindings: [.text(key)])
                try c.execute("""
                    INSERT OR IGNORE INTO retention_own_turn_history(source_key,generation,session_key,turn_id)
                    SELECT o.source_key,s.generation,o.session_key,o.turn_id
                    FROM retention_own_turns o
                    JOIN retention_sources s ON s.source_key=o.source_key
                    WHERE o.source_key=?;
                    """, bindings: [.text(key)])
            }
            try c.execute("""
                INSERT INTO retention_sources(source_key,fingerprint,session_key,is_child,explicit_child,own_rounds,generation,checkpoint,present,fallback_own_rounds)
                VALUES(?,?,?,?,?,?,?,?,1,?) ON CONFLICT(source_key) DO UPDATE SET fingerprint=excluded.fingerprint,
                session_key=excluded.session_key,is_child=excluded.is_child,explicit_child=excluded.explicit_child,own_rounds=excluded.own_rounds,
                generation=excluded.generation,checkpoint=excluded.checkpoint,present=1,
                fallback_own_rounds=excluded.fallback_own_rounds;
                """, bindings: [.text(key),.text(fingerprint),.text(parser.sessionKey),.int(parser.excludedSubagent ? 1 : 0),.int(parser.explicitSubagent ? 1 : 0),.int(own),.text(checkpoint.generation),.blob(encoded),.int(ownProjection.fallbackCount)])
            try c.execute("DELETE FROM retention_own_turns WHERE source_key=?;", bindings: [.text(key)])
            if let sessionKey = ownProjection.sessionKey {
                for turnID in ownProjection.stableTurnIDs {
                    try c.execute("""
                        INSERT INTO retention_own_turns(source_key,session_key,turn_id) VALUES(?,?,?);
                        """, bindings: [.text(key),.text(sessionKey),.text(turnID)])
                }
            }
            try c.execute("DELETE FROM retention_pairs WHERE source_key=?;", bindings: [.text(key)])
            let statement = try c.prepare("INSERT INTO retention_pairs(pair_key,source_key,stable_key,evidence_signature,eligible,model,started_us,point,reasons) VALUES(?,?,?,?,?,?,?,?,?);")
            for pair in pairs {
                _ = try statement.execute([.text(pair.id),.text(key),.optionalText(pair.stableKey),.text(pair.evidenceSignature),
                    .int(pair.eligible ? 1 : 0),.optionalText(pair.point?.model),pair.point.map { .int64($0.startedAtMicroseconds) } ?? .null,
                    try pair.point.map { .blob(try encoder.encode($0)) } ?? .null,.blob(try encoder.encode(pair.reasons.sorted()))])
            }
            try c.execute("UPDATE retention_meta SET revision=revision+1 WHERE id=1;")
        }
    }

    func removeMissing(_ keys: Set<String>) throws {
        let currentlyPresent = Set(try driver.readRows(
            "SELECT source_key FROM retention_sources WHERE present=1;"
        ) { $0.text(0) ?? "" })
        let missing = currentlyPresent.subtracting(keys)
        guard !missing.isEmpty else { return }
        try driver.transaction { c in
            for key in missing {
                // A missing file is a presence transition, not a history
                // deletion. Keep numeric evidence, parser state and own-round
                // counts available for snapshots and for a later restoration.
                try c.execute("UPDATE retention_sources SET present=0 WHERE source_key=? AND present=1;", bindings: [.text(key)])
            }
            try c.execute("UPDATE retention_meta SET revision=revision+1 WHERE id=1;")
        }
    }

    func snapshot(scope: CacheRetentionScope, now: Date) throws -> CacheRetentionSnapshot {
        try driver.withConnection { c in
            try c.readTransaction { c in
                var conditions = ["p.eligible=1"]
                var bindings: [SQLiteBinding] = []
                if let model = scope.model { conditions.append("p.model=?"); bindings.append(.text(model)) }
                if scope.range != .all {
                    let days = scope.range == .month ? 30.0 : 7.0
                    conditions.append("p.started_us>=?"); bindings.append(.int64(Int64((now.timeIntervalSince1970-days*86400)*1_000_000)))
                }
                // Stable UUID evidence conflicts invalidate all copies.
                // Valid identical copies have one deterministic representative.
                conditions.append("""
                    (p.stable_key IS NULL OR (
                      NOT EXISTS(SELECT 1 FROM retention_all_pairs q WHERE q.stable_key=p.stable_key AND q.evidence_signature<>p.evidence_signature)
                      AND p.pair_key=(SELECT MIN(q.pair_key) FROM retention_all_pairs q WHERE q.stable_key=p.stable_key AND q.eligible=1)))
                    """)
                let points = try c.readRows("SELECT p.point FROM retention_all_pairs p WHERE \(conditions.joined(separator: " AND ")) ORDER BY p.started_us,p.pair_key LIMIT 100001;", bindings: bindings) {
                    try decoder.decode(CacheRetentionPoint.self, from: $0.data(0)!)
                }
                let models = try c.readRows("SELECT DISTINCT model FROM retention_all_pairs WHERE eligible=1 AND model IS NOT NULL ORDER BY model;") { $0.text(0)! }
                let revision = try c.readRows("SELECT revision FROM retention_meta WHERE id=1;") { $0.int64(0)! }.first ?? 0
                let own = try c.readRows("""
                    SELECT
                      (SELECT COALESCE(SUM(s.fallback_own_rounds),0)
                       FROM retention_sources s WHERE s.is_child=0)
                      + (SELECT COALESCE(SUM(g.fallback_own_rounds),0)
                         FROM retention_generation_history g
                         JOIN retention_sources s ON s.source_key=g.source_key
                         WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation)
                      + (SELECT COUNT(*) FROM (
                           SELECT DISTINCT session_key,turn_id FROM (
                             SELECT o.session_key,o.turn_id
                             FROM retention_own_turns o
                             JOIN retention_sources s ON s.source_key=o.source_key
                             WHERE s.is_child=0
                             UNION ALL
                             SELECT h.session_key,h.turn_id
                             FROM retention_own_turn_history h
                             JOIN retention_generation_history g
                               ON g.source_key=h.source_key AND g.generation=h.generation
                             JOIN retention_sources s ON s.source_key=h.source_key
                             WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation
                           ) AS all_turns
                         ));
                    """) { $0.int(0) ?? 0 }.first ?? 0
                let analysis = CacheRetentionAnalysis.calculate(points)
                return CacheRetentionSnapshot(points: points, models: models, analysis: analysis,
                    sourceCount: Set(points.map(\.sourceKey)).count, ownRoundCount: own, updatedAt: now, revision: revision, scope: scope,
                    chartData: .init(points: analysis.p95State == .rangeTooLarge ? [] : points))
            }
        }
    }

    private struct OwnTurnProjection {
        var sessionKey: String?
        var stableTurnIDs: [String]
        var fallbackCount: Int
    }

    /// Keep only parser-proven stable identities in the cross-source
    /// projection. Unknown session identity is counted per source so a
    /// missing or ambiguous UUID cannot accidentally merge separate history.
    private static func ownTurnProjection(parser: CacheRetentionParser, fallbackCount: Int) -> OwnTurnProjection {
        guard !parser.excludedSubagent else {
            return OwnTurnProjection(sessionKey: nil, stableTurnIDs: [], fallbackCount: 0)
        }
        let turns = parser.turns.filter(parser.isOwn)
        let sessionIdentityIsUnambiguous = parser.metadataSeen
            && !parser.sessionKey.isEmpty
            && !parser.sourceFlags.contains("missing_session_identity")
            && !parser.sourceFlags.contains("multiple_session_metadata")
        guard sessionIdentityIsUnambiguous else {
            return OwnTurnProjection(sessionKey: nil, stableTurnIDs: [], fallbackCount: fallbackCount)
        }

        var stableTurnIDs: Set<String> = []
        var unstableCount = 0
        for turn in turns {
            if turn.stableID {
                stableTurnIDs.insert(turn.id)
            } else {
                unstableCount += 1
            }
        }
        return OwnTurnProjection(
            sessionKey: parser.sessionKey,
            stableTurnIDs: stableTurnIDs.sorted(),
            fallbackCount: unstableCount
        )
    }

    /// The v1 sidecar kept checkpoints and per-source counts, but did not
    /// persist stable turn identity separately. Decode each legacy checkpoint
    /// once during the atomic schema migration, then snapshots use SQL only.
    private func backfillOwnTurnProjection(connection: SQLiteDatabaseConnection) throws {
        let rows = try connection.readRows("""
            SELECT source_key,is_child,own_rounds,checkpoint
            FROM retention_sources;
            """) { statement in
                (
                    statement.text(0) ?? "",
                    statement.int(1) == 1,
                    statement.int(2) ?? 0,
                    statement.data(3)
                )
            }
        for (sourceKey, isChild, storedCount, checkpointData) in rows {
            let projection: OwnTurnProjection
            if isChild {
                projection = OwnTurnProjection(sessionKey: nil, stableTurnIDs: [], fallbackCount: 0)
            } else if let checkpointData,
                      let checkpoint = try? decoder.decode(CacheRetentionCheckpoint.self, from: checkpointData) {
                projection = Self.ownTurnProjection(parser: checkpoint.parser, fallbackCount: storedCount)
            } else {
                projection = OwnTurnProjection(sessionKey: nil, stableTurnIDs: [], fallbackCount: storedCount)
            }

            try connection.execute(
                "UPDATE retention_sources SET fallback_own_rounds=? WHERE source_key=?;",
                bindings: [.int(projection.fallbackCount),.text(sourceKey)]
            )
            if let sessionKey = projection.sessionKey {
                for turnID in projection.stableTurnIDs {
                    try connection.execute("""
                        INSERT INTO retention_own_turns(source_key,session_key,turn_id) VALUES(?,?,?);
                        """, bindings: [.text(sourceKey),.text(sessionKey),.text(turnID)])
                }
            }
        }
    }
}
