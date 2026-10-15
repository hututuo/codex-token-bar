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
    let fingerprint: String
    let session: String
    let isChild: Bool
    let explicitChild: Bool
}

/// One independent writer. Neither the exact index nor its schema is opened
/// for writing by this feature. Source facts/projection/checkpoint are atomic.
final class CacheRetentionDatabase {
    let url: URL
    private let driver: SQLiteDatabaseDriver
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: url.path) {
            let ro = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
            let version = try ro.readRows("PRAGMA user_version;") { $0.int(0) ?? 0 }.first ?? 0
            guard version <= 1 else { throw CacheRetentionError.unsupportedVersion }
        }
        driver = SQLiteDatabaseDriver(url: url, busyTimeoutMilliseconds: 150, enableWAL: true)
        try driver.transaction { c in
            try c.execute("""
                CREATE TABLE IF NOT EXISTS retention_meta(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
                INSERT INTO retention_meta(id,revision) VALUES(1,0) ON CONFLICT(id) DO NOTHING;
                CREATE TABLE IF NOT EXISTS retention_sources(
                  source_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, session_key TEXT NOT NULL,
                  is_child INTEGER NOT NULL, explicit_child INTEGER NOT NULL, own_rounds INTEGER NOT NULL, generation TEXT NOT NULL,
                  checkpoint BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS retention_pairs(
                  pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
                  stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
                  model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS retention_pair_identity ON retention_pairs(stable_key,evidence_signature,eligible,pair_key);
                CREATE INDEX IF NOT EXISTS retention_pair_time ON retention_pairs(started_us,pair_key) WHERE eligible=1;
                CREATE INDEX IF NOT EXISTS retention_pair_model ON retention_pairs(model,started_us,pair_key) WHERE eligible=1;
                PRAGMA user_version=1;
                """)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func summaries() throws -> [String: CacheRetentionSourceSummary] {
        let rows = try driver.readRows("SELECT source_key,fingerprint,session_key,is_child,explicit_child FROM retention_sources;") { s in
            CacheRetentionSourceSummary(key: s.text(0)!, fingerprint: s.text(1)!, session: s.text(2)!, isChild: s.int(3) == 1, explicitChild: s.int(4) == 1)
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
        try driver.transaction { c in
            try c.execute("""
                INSERT INTO retention_sources(source_key,fingerprint,session_key,is_child,explicit_child,own_rounds,generation,checkpoint)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(source_key) DO UPDATE SET fingerprint=excluded.fingerprint,
                session_key=excluded.session_key,is_child=excluded.is_child,explicit_child=excluded.explicit_child,own_rounds=excluded.own_rounds,
                generation=excluded.generation,checkpoint=excluded.checkpoint;
                """, bindings: [.text(key),.text(fingerprint),.text(parser.sessionKey),.int(parser.excludedSubagent ? 1 : 0),.int(parser.explicitSubagent ? 1 : 0),.int(own),.text(checkpoint.generation),.blob(encoded)])
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
        let missing = try Set(summaries().keys).subtracting(keys)
        guard !missing.isEmpty else { return }
        try driver.transaction { c in
            for key in missing {
                // Explicit delete is independent of the connection's FK mode.
                try c.execute("DELETE FROM retention_pairs WHERE source_key=?;", bindings: [.text(key)])
                try c.execute("DELETE FROM retention_sources WHERE source_key=?;", bindings: [.text(key)])
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
                      NOT EXISTS(SELECT 1 FROM retention_pairs q WHERE q.stable_key=p.stable_key AND q.evidence_signature<>p.evidence_signature)
                      AND p.source_key=(SELECT MIN(q.source_key) FROM retention_pairs q WHERE q.stable_key=p.stable_key AND q.eligible=1)))
                    """)
                let points = try c.readRows("SELECT p.point FROM retention_pairs p WHERE \(conditions.joined(separator: " AND ")) ORDER BY p.started_us,p.pair_key LIMIT 100001;", bindings: bindings) {
                    try decoder.decode(CacheRetentionPoint.self, from: $0.data(0)!)
                }
                let models = try c.readRows("SELECT DISTINCT model FROM retention_pairs WHERE eligible=1 AND model IS NOT NULL ORDER BY model;") { $0.text(0)! }
                let revision = try c.readRows("SELECT revision FROM retention_meta WHERE id=1;") { $0.int64(0)! }.first ?? 0
                let own = try c.readRows("SELECT COALESCE(SUM(own_rounds),0) FROM retention_sources WHERE is_child=0;") { $0.int(0)! }.first ?? 0
                let analysis = CacheRetentionAnalysis.calculate(points)
                return CacheRetentionSnapshot(points: points, models: models, analysis: analysis,
                    sourceCount: Set(points.map(\.sourceKey)).count, ownRoundCount: own, updatedAt: now, revision: revision, scope: scope,
                    chartData: .init(points: analysis.p95State == .rangeTooLarge ? [] : points))
            }
        }
    }
}
