import Foundation

/// The existing events table is the numeric ledger. Raw locations are bindings,
/// never primary keys for newly observed consumption. Ordinary queries keep a
/// single accounting source while parsers operate on current-generation input.
enum UsageEventLedger {
    static let revision = "1"
    private static let firstAllocatedID: Int64 = 1 << 62

    struct Candidate {
        let rawOffset: Int64
        let timestamp: Double
        let tokens: Int64
        let input: Int64
        let cached: Int64
        let output: Int64
        let reasoning: Int64
        let model: String?
        let promptOffset: Int64?
        let assistantOffset: Int64?
        let accountingKind: Int64
        let reported: Int64?
        let legacy: Int64?
        let fingerprint: Data?
    }

    enum Admission {
        /// Validated append, first scan, or an independently proved new call.
        case newConsumption
        /// Source text has changed; a new fingerprint alone is not sufficient.
        case reconcile
    }

    enum Outcome: Equatable { case inserted(Int64), associated(Int64), unresolved }

    static func isCompleteSnapshot(_ data: Data) throws -> Bool {
        let values = try UsageFingerprintCodec.decode(data)
        // The partial-snapshot digest reserves hasLast=false,lastTokens=1.
        return values[5] == 1 || values[6...10].allSatisfy { $0 == 0 }
    }

    static func isPaginatedFile(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount:64 * 1024) ?? Data()
        let line = prefix.prefix { $0 != 10 }
        guard let root = try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String:Any] else { return false }
        return payload["history_mode"] as? String == "paginated"
    }

    static func validate(on db: SQLiteDatabaseConnection) throws {
        let exists = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='usage_ledger_meta'") { $0.int(0) }.first != nil
        guard exists else {
            let hasMetadata = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_meta'") { $0.int(0) }.first != nil
            if hasMetadata, (try db.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first ?? nil) == "13" {
                throw CodexUsageIndexRepairRequiredError(reason: "历史账本标记与结构不一致，已保留原库")
            }
            return
        }
        let value = try db.readRows("SELECT value FROM usage_ledger_meta WHERE key='revision'") { $0.text(0) }.first ?? nil
        guard value == revision else {
            throw CodexUsageIndexUpgradeRequiredError(component: "usage ledger", stored: value ?? "missing", supported: revision)
        }
        for table in ["usage_ledger_bindings", "usage_ledger_identities", "usage_ledger_turns", "usage_ledger_unresolved", "usage_ledger_sources", "usage_ledger_corrections"] {
            let present = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", bindings: [.text(table)]) { $0.int(0) }.first != nil
            guard present else { throw CodexUsageIndexRepairRequiredError(reason: "历史账本缺少 \(table)，已保留原库") }
        }
    }

    static func install(on db: SQLiteDatabaseConnection) throws {
        try validate(on: db)
        let installed = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='usage_ledger_meta'") { $0.int(0) }.first != nil
        if installed { return }
        try db.transaction { tx in
            try tx.execute("""
                CREATE TABLE usage_ledger_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE usage_ledger_corrections(source_id INTEGER NOT NULL,event_id INTEGER NOT NULL,
                    generation TEXT NOT NULL,raw_offset INTEGER NOT NULL,parser_revision TEXT NOT NULL,
                    old_tokens INTEGER NOT NULL,new_tokens INTEGER NOT NULL,reason TEXT NOT NULL,
                    PRIMARY KEY(source_id,event_id,generation)) WITHOUT ROWID;
                CREATE TABLE usage_ledger_bindings(
                    source_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
                    generation TEXT NOT NULL, raw_offset INTEGER NOT NULL,
                    prompt_offset INTEGER, assistant_offset INTEGER,
                    available INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(source_id,event_id),
                    UNIQUE(source_id,generation,raw_offset)
                ) WITHOUT ROWID;
                CREATE TABLE usage_ledger_identities(
                    source_id INTEGER NOT NULL, identity BLOB NOT NULL, event_id INTEGER NOT NULL,
                    PRIMARY KEY(source_id,identity)
                ) WITHOUT ROWID;
                CREATE TABLE usage_ledger_turns(
                    source_id INTEGER NOT NULL, generation TEXT NOT NULL,
                    raw_offset INTEGER NOT NULL, turn_id INTEGER NOT NULL,
                    PRIMARY KEY(source_id,generation,raw_offset)
                ) WITHOUT ROWID;
                CREATE TABLE usage_ledger_unresolved(
                    source_id INTEGER NOT NULL, generation TEXT NOT NULL, raw_offset INTEGER NOT NULL,
                    timestamp REAL NOT NULL,tokens INTEGER NOT NULL,input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,model TEXT,accounting_kind INTEGER NOT NULL,
                    reported_total_tokens INTEGER,legacy_tokens INTEGER,identity BLOB,
                    prompt_offset INTEGER,assistant_offset INTEGER,reason TEXT NOT NULL,
                    PRIMARY KEY(source_id,generation,raw_offset)
                ) WITHOUT ROWID;
                CREATE INDEX usage_ledger_unresolved_identity ON usage_ledger_unresolved(source_id,identity);
                CREATE TABLE usage_ledger_sources(
                    source_id INTEGER PRIMARY KEY,session_id TEXT NOT NULL,
                    missing INTEGER NOT NULL DEFAULT 0, format TEXT NOT NULL DEFAULT 'unknown',
                    generation TEXT NOT NULL
                );
                INSERT INTO usage_ledger_sources(source_id,session_id,generation,format)
                SELECT s.source_id,s.session_id,s.last_seen_generation,
                    CASE WHEN e.parser_revision LIKE '%explicit-subagent-delayed-context-v3%'
                         THEN 'legacy' ELSE 'unknown' END
                FROM sources s LEFT JOIN event_enrichment_sources e USING(source_id);
                INSERT INTO usage_ledger_bindings(source_id,event_id,generation,raw_offset,prompt_offset,assistant_offset)
                SELECT e.source_id,e.source_offset,s.last_seen_generation,e.source_offset,e.user_prompt_offset,e.assistant_start_offset
                FROM events e JOIN sources s USING(source_id);
                INSERT INTO usage_ledger_turns(source_id,generation,raw_offset,turn_id)
                SELECT DISTINCT e.source_id,s.last_seen_generation,e.user_prompt_offset,e.user_prompt_offset
                FROM events e JOIN sources s USING(source_id) WHERE e.user_prompt_offset IS NOT NULL;
                """)
            let maxID = try tx.readRows("SELECT COALESCE(MAX(source_offset),0) FROM events") { $0.int64(0) }.first ?? 0
            guard let maxID, maxID < firstAllocatedID else {
                throw CodexUsageIndexRepairRequiredError(reason: "旧事件标识超出账本保留范围，已停止迁移")
            }
            for (key, value) in [("revision",revision),("next_id",String(firstAllocatedID))] {
                try tx.execute("INSERT INTO usage_ledger_meta VALUES (?,?)",bindings:[.text(key),.text(value)])
            }
        }
    }

    /// Runs in the caller's source publication transaction. A missing binding
    /// affects text lookup only; it does not revoke the numeric event.
    static func beginGeneration(source: Int64, session: String, generation: String, on db: SQLiteDatabaseConnection) throws {
        let owner = try db.readRows("SELECT session_id FROM usage_ledger_sources WHERE source_id=?",bindings:[.int64(source)]) { $0.text(0) }.first ?? nil
        guard owner == nil || owner?.lowercased() == session.lowercased() else {
            throw CodexUsageIndexRepairRequiredError(reason: "来源身份改变，需要分配新来源后再发布，旧账已保留")
        }
        try db.execute("INSERT INTO usage_ledger_sources(source_id,session_id,generation) VALUES (?,?,?) ON CONFLICT(source_id) DO UPDATE SET missing=0,generation=excluded.generation",bindings:[.int64(source),.text(session),.text(generation)])
        try db.execute("UPDATE usage_ledger_bindings SET available=0 WHERE source_id=? AND available<>0",bindings:[.int64(source)])
    }

    private static func allocate(on db: SQLiteDatabaseConnection) throws -> Int64 {
        let value = try db.readRows("SELECT value FROM usage_ledger_meta WHERE key='next_id'") { $0.text(0).flatMap(Int64.init) }.first ?? nil
        guard let value, value >= firstAllocatedID, value < Int64.max else {
            throw CodexUsageIndexRepairRequiredError(reason: "账本事件序列无效，已停止写入")
        }
        try db.execute("UPDATE usage_ledger_meta SET value=? WHERE key='next_id'",bindings:[.text(String(value+1))])
        return value
    }

    static func admit(_ row: Candidate, source: Int64, generation: String, admission: Admission,
                      unchangedFromGeneration: String? = nil, correctionRevision: String? = nil, on db: SQLiteDatabaseConnection) throws -> Outcome {
        // A stable request identity must be scoped to this source/counter epoch
        // by the adapter. Old source-level fingerprint membership is not a
        // per-event identity and must never be passed as a fabricated binding.
        var existing: Int64? = try row.fingerprint.flatMap { identity in
            try db.readRows("SELECT event_id FROM usage_ledger_identities WHERE source_id=? AND identity=?",bindings:[.int64(source),.blob(identity)]) { $0.int64(0) }.first ?? nil
        }
        if existing == nil, let oldGeneration = unchangedFromGeneration {
            // Caller verified every source chunk, not just size/mtime. Under
            // that proof an old raw position identifies the same observation.
            existing = try db.readRows("SELECT event_id FROM usage_ledger_bindings WHERE source_id=? AND generation=? AND raw_offset=?",bindings:[.int64(source),.text(oldGeneration),.int64(row.rawOffset)]) { $0.int64(0) }.first ?? nil
        }
        if let existing {
            let same = try db.readRows("""
                SELECT tokens=? AND input_tokens=? AND cached_input_tokens=? AND output_tokens=?
                    AND reasoning_output_tokens=? AND accounting_kind=?
                FROM events WHERE source_id=? AND source_offset=?
                """,bindings:[.int64(row.tokens),.int64(row.input),.int64(row.cached),.int64(row.output),.int64(row.reasoning),.int64(row.accountingKind),.int64(source),.int64(existing)]) { $0.int(0) }.first == 1
            let verifiedLocation: Bool
            if let oldGeneration = unchangedFromGeneration, correctionRevision != nil {
                verifiedLocation = try db.readRows("SELECT EXISTS(SELECT 1 FROM usage_ledger_bindings WHERE source_id=? AND event_id=? AND generation=? AND raw_offset=?)",bindings:[.int64(source),.int64(existing),.text(oldGeneration),.int64(row.rawOffset)]) { $0.int(0) }.first == 1
            } else { verifiedLocation = false }
            if !same && verifiedLocation {
                // Reinterpreting the same byte-proved observation is a
                // correction, not a second call. The retention trigger saves
                // every old numeric field in this same transaction.
                try db.execute("INSERT OR IGNORE INTO usage_ledger_corrections SELECT source_id,source_offset,?,?,?,tokens,?,? FROM events WHERE source_id=? AND source_offset=?",bindings:[.text(generation),.int64(row.rawOffset),.text(correctionRevision!),.int64(row.tokens),.text("verified-prefix-reparse"),.int64(source),.int64(existing)])
                try db.execute("UPDATE events SET tokens=?,input_tokens=?,cached_input_tokens=?,output_tokens=?,reasoning_output_tokens=?,accounting_kind=?,reported_total_tokens=? WHERE source_id=? AND source_offset=?",bindings:[.int64(row.tokens),.int64(row.input),.int64(row.cached),.int64(row.output),.int64(row.reasoning),.int64(row.accountingKind),optional(row.reported),.int64(source),.int64(existing)])
            }
            if same || verifiedLocation {
                if let identity = row.fingerprint {
                    try db.execute("INSERT INTO usage_ledger_identities VALUES (?,?,?) ON CONFLICT(source_id,identity) DO NOTHING",bindings:[.int64(source),.blob(identity),.int64(existing)])
                }
                if let model = row.model {
                    try db.execute("UPDATE events SET model=? WHERE source_id=? AND source_offset=? AND model IS NULL",bindings:[.text(model),.int64(source),.int64(existing)])
                }
                try bind(row, source:source, event:existing, generation:generation, on:db)
                return .associated(existing)
            }
            try hold(row,source:source,generation:generation,reason:"identity-conflict",on:db)
            return .unresolved
        }
        // A previously held observation does not become new consumption merely
        // because the rewritten file is now unchanged. Keep that ambiguity
        // durable across another full scan, movement, and restart.
        let wasHeld = try row.fingerprint.map { identity in
            try db.readRows("SELECT EXISTS(SELECT 1 FROM usage_ledger_unresolved WHERE source_id=? AND identity=?)",bindings:[.int64(source),.blob(identity)]) { $0.int(0) }.first == 1
        } ?? false
        guard admission == .newConsumption && !wasHeld else {
            try hold(row,source:source,generation:generation,reason:"unproved-rewrite-observation",on:db)
            return .unresolved
        }
        let eventID = try allocate(on:db)
        var turn: Int64?
        if let prompt = row.promptOffset {
            turn = try db.readRows("SELECT turn_id FROM usage_ledger_turns WHERE source_id=? AND generation=? AND raw_offset=?",bindings:[.int64(source),.text(generation),.int64(prompt)]) { $0.int64(0) }.first ?? nil
            if turn == nil {
                turn = try allocate(on:db)
                try db.execute("INSERT INTO usage_ledger_turns VALUES (?,?,?,?)",bindings:[.int64(source),.text(generation),.int64(prompt),.int64(turn!)])
            }
        }
        try db.execute("""
            INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,
                output_tokens,reasoning_output_tokens,model,user_prompt_offset,assistant_start_offset,
                accounting_kind,reported_total_tokens,legacy_tokens)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,bindings:[.int64(source),.int64(eventID),.double(row.timestamp),.int64(row.tokens),.int64(row.input),.int64(row.cached),.int64(row.output),.int64(row.reasoning),.optionalText(row.model),optional(turn),optional(row.assistantOffset),.int64(row.accountingKind),optional(row.reported),optional(row.legacy)])
        if let identity = row.fingerprint {
            try db.execute("INSERT INTO usage_ledger_identities VALUES (?,?,?)",bindings:[.int64(source),.blob(identity),.int64(eventID)])
        }
        try bind(row,source:source,event:eventID,generation:generation,on:db)
        return .inserted(eventID)
    }

    private static func optional(_ value: Int64?) -> SQLiteBinding { value.map(SQLiteBinding.int64) ?? .null }

    private static func bind(_ row: Candidate, source: Int64, event: Int64, generation: String, on db: SQLiteDatabaseConnection) throws {
        try db.execute("""
            INSERT INTO usage_ledger_bindings VALUES (?,?,?,?,?,?,1)
            ON CONFLICT(source_id,event_id) DO UPDATE SET generation=excluded.generation,
                raw_offset=excluded.raw_offset,prompt_offset=excluded.prompt_offset,
                assistant_offset=excluded.assistant_offset,available=1
            """,bindings:[.int64(source),.int64(event),.text(generation),.int64(row.rawOffset),optional(row.promptOffset),optional(row.assistantOffset)])
        if let prompt = row.promptOffset {
            try db.execute("""
                INSERT INTO usage_ledger_turns(source_id,generation,raw_offset,turn_id)
                SELECT source_id,?,?,user_prompt_offset FROM events
                WHERE source_id=? AND source_offset=? AND user_prompt_offset IS NOT NULL
                ON CONFLICT(source_id,generation,raw_offset) DO NOTHING
                """,bindings:[.text(generation),.int64(prompt),.int64(source),.int64(event)])
        }
        try db.execute("DELETE FROM usage_ledger_unresolved WHERE source_id=? AND generation=? AND raw_offset=?",bindings:[.int64(source),.text(generation),.int64(row.rawOffset)])
    }

    private static func hold(_ row: Candidate, source: Int64, generation: String, reason: String, on db: SQLiteDatabaseConnection) throws {
        try db.execute("""
            INSERT INTO usage_ledger_unresolved VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source_id,generation,raw_offset) DO NOTHING
            """,bindings:[.int64(source),.text(generation),.int64(row.rawOffset),.double(row.timestamp),.int64(row.tokens),.int64(row.input),.int64(row.cached),.int64(row.output),.int64(row.reasoning),.optionalText(row.model),.int64(row.accountingKind),optional(row.reported),optional(row.legacy),row.fingerprint.map(SQLiteBinding.blob) ?? .null,optional(row.promptOffset),optional(row.assistantOffset),.text(reason)])
    }
}
