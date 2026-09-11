import Foundation

/// Displaced observations are evidence, not a second numeric aggregate.
/// Triggers run in the writer's transaction, including source cascades. There
/// is deliberately no FK to live sources: losing a file must not erase proof.
enum UsageHistoryRetention {
    static let revision = "2"
    static let writerRevision = "4"

    static func validate(on db: SQLiteDatabaseConnection) throws {
        let exists = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='retained_usage_meta';") { $0.int(0) }.first != nil
        guard exists else { return }
        let stored = try db.readRows("SELECT value FROM retained_usage_meta WHERE key='schema_version';") { $0.text(0) }.first ?? nil
        guard stored == "1" || stored == revision else {
            throw CodexUsageIndexUpgradeRequiredError(component: "history retention", stored: stored ?? "missing", supported: revision)
        }
        let writer = try db.readRows("SELECT value FROM retained_usage_meta WHERE key='writer_revision';") { $0.text(0) }.first ?? nil
        guard writer == nil || writer == "2" || writer == "3" || writer == writerRevision else {
            throw CodexUsageIndexUpgradeRequiredError(component: "history retention writer", stored: writer ?? "missing", supported: writerRevision)
        }
    }

    static func install(on db: SQLiteDatabaseConnection) throws {
        try validate(on: db)
        let columns = Set(try db.readRows("PRAGMA table_info(events);") { $0.text(1) }.compactMap { $0 })
        let sourceColumns = Set(try db.readRows("PRAGMA table_info(sources);") { $0.text(1) }.compactMap { $0 })
        let hasBindings = try db.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='usage_ledger_bindings'") { $0.int(0) }.first != nil
        let flavor = ["accounting_kind", "reported_total_tokens", "legacy_tokens"].filter { columns.contains($0) }.joined(separator: ",")
            + "|accounting_state=" + String(sourceColumns.contains("accounting_state")) + "|writer=" + writerRevision + "|bindings=" + String(hasBindings)
        let triggerCount = try db.readRows("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('retain_usage_before_event_delete','retain_usage_before_source_delete','retain_usage_before_identity_update','retain_usage_before_fingerprint_delete','retain_usage_before_event_update');") { $0.int(0) }.first ?? 0
        if triggerCount == 5 {
            let stored = try db.readRows("SELECT value FROM retained_usage_meta WHERE key='event_columns';") { $0.text(0) }.first ?? nil
            if stored == flavor { return }
        }
        try db.transaction { tx in
            try tx.execute("""
                CREATE TABLE IF NOT EXISTS retained_usage_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS retained_usage_sources(
                    snapshot_id INTEGER PRIMARY KEY,
                    source_id INTEGER NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
                    signature TEXT NOT NULL, parser_revision TEXT NOT NULL, reason TEXT NOT NULL,
                    UNIQUE(source_id, session_id, path, signature, parser_revision)
                );
                CREATE TABLE IF NOT EXISTS retained_usage_events(
                    snapshot_id INTEGER NOT NULL REFERENCES retained_usage_sources(snapshot_id),
                    position INTEGER NOT NULL, timestamp REAL NOT NULL, tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL,
                    model TEXT, accounting_kind INTEGER, reported_total_tokens INTEGER, legacy_tokens INTEGER,
                    PRIMARY KEY(snapshot_id, position)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS retained_usage_fingerprints(
                    snapshot_id INTEGER NOT NULL REFERENCES retained_usage_sources(snapshot_id),
                    value BLOB NOT NULL, PRIMARY KEY(snapshot_id,value)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS retained_usage_checkpoints(
                    snapshot_id INTEGER PRIMARY KEY REFERENCES retained_usage_sources(snapshot_id),
                    append_ready INTEGER NOT NULL, resume_offset INTEGER, previous_total_tokens INTEGER,
                    is_explicit_subagent_fork INTEGER NOT NULL, accounting_state TEXT
                );
                CREATE TABLE IF NOT EXISTS retained_usage_revisions(
                    revision_id INTEGER PRIMARY KEY,
                    source_id INTEGER NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
                    signature TEXT NOT NULL, parser_revision TEXT NOT NULL,
                    position INTEGER NOT NULL, timestamp REAL NOT NULL, tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, reasoning_output_tokens INTEGER NOT NULL,
                    model TEXT, accounting_kind INTEGER, reported_total_tokens INTEGER, legacy_tokens INTEGER
                );
                CREATE INDEX IF NOT EXISTS retained_usage_revisions_source ON retained_usage_revisions(source_id,position);
                DROP TRIGGER IF EXISTS retain_usage_before_event_update;
                DROP TRIGGER IF EXISTS retain_usage_before_event_delete;
                DROP TRIGGER IF EXISTS retain_usage_before_source_delete;
                DROP TRIGGER IF EXISTS retain_usage_before_identity_update;
                DROP TRIGGER IF EXISTS retain_usage_before_fingerprint_delete;
                """)
            // Additive upgrade: old retained rows keep NULL locations. Never
            // invent a raw-file reference for an observation imported earlier.
            let locationColumns = ["user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end", "token_source_offset"]
            for table in ["retained_usage_events", "retained_usage_revisions"] {
                let existing = Set(try tx.readRows("PRAGMA table_info(\(table));") { $0.text(1) }.compactMap { $0 })
                for column in locationColumns where !existing.contains(column) {
                    try tx.execute("ALTER TABLE \(table) ADD COLUMN \(column) INTEGER;")
                }
            }
            let locationFields = ["user_prompt_offset", nil, "assistant_start_offset", nil, "source_offset"] as [String?]
            func locationExpressions(_ prefix: String) -> [String] {
                let bindingFields: [String?] = ["prompt_offset",nil,"assistant_offset",nil,"raw_offset"]
                return zip(locationFields,bindingFields).map { field,binding in
                    if hasBindings, let binding {
                        return "(SELECT b.\(binding) FROM usage_ledger_bindings b WHERE b.source_id=\(prefix).source_id AND b.event_id=\(prefix).source_offset)"
                    }
                    return field.flatMap { columns.contains($0) ? "\(prefix).\($0)" : nil } ?? "NULL"
                }
            }
            func locationValues(_ prefix: String) -> String { locationExpressions(prefix).joined(separator:",") }
            let signature = "CAST(s.size_bytes AS TEXT)||':'||CAST(s.modified_at AS TEXT)||':'||s.content_probe||':'||s.last_seen_generation"
            let parser = "COALESCE((SELECT parser_revision FROM event_enrichment_sources WHERE source_id=s.source_id),(SELECT value FROM schema_meta WHERE key='fork_replay_boundary_revision'),'legacy')"
            func snapshot(_ filter: String, reason: String) -> String {
                """
                INSERT OR IGNORE INTO retained_usage_sources(source_id,session_id,path,signature,parser_revision,reason)
                SELECT s.source_id,s.session_id,s.path,\(signature),\(parser),'\(reason)' FROM sources s WHERE \(filter);
                INSERT OR IGNORE INTO retained_usage_checkpoints
                SELECT h.snapshot_id,s.append_ready,s.resume_offset,s.previous_total_tokens,s.is_explicit_subagent_fork,
                    \(sourceColumns.contains("accounting_state") ? "s.accounting_state" : "NULL")
                FROM sources s JOIN retained_usage_sources h ON h.source_id=s.source_id AND h.session_id=s.session_id
                    AND h.path=s.path AND h.signature=(\(signature)) AND h.parser_revision=(\(parser))
                WHERE \(filter);
                """
            }
            func records(_ filter: String) -> String {
                let optional = ["accounting_kind", "reported_total_tokens", "legacy_tokens"].map { columns.contains($0) ? "e.\($0)" : "NULL" }.joined(separator: ",")
                let compared = ["timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model"]
                    + ["accounting_kind", "reported_total_tokens", "legacy_tokens"].filter { columns.contains($0) }
                let locationDifferences = zip(locationColumns,locationExpressions("e")).map { target, expression in
                    "prior.\(target) IS NOT \(expression)"
                }
                let differs = (compared.map { "prior.\($0) IS NOT e.\($0)" } + locationDifferences).joined(separator: " OR ")
                return """
                INSERT INTO retained_usage_revisions(
                    source_id,session_id,path,signature,parser_revision,position,timestamp,tokens,
                    input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,
                    model,accounting_kind,reported_total_tokens,legacy_tokens,
                    user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,token_source_offset
                ) SELECT s.source_id,s.session_id,s.path,\(signature),\(parser),
                    e.source_offset,e.timestamp,e.tokens,e.input_tokens,e.cached_input_tokens,
                    e.output_tokens,e.reasoning_output_tokens,e.model,\(optional),\(locationValues("e"))
                FROM events e JOIN sources s ON s.source_id=e.source_id
                JOIN retained_usage_sources h ON h.source_id=s.source_id AND h.session_id=s.session_id
                    AND h.path=s.path AND h.signature=(\(signature)) AND h.parser_revision=(\(parser))
                JOIN retained_usage_events prior ON prior.snapshot_id=h.snapshot_id AND prior.position=e.source_offset
                WHERE (\(filter)) AND (\(differs));
                INSERT OR IGNORE INTO retained_usage_events
                SELECT h.snapshot_id,e.source_offset,e.timestamp,e.tokens,e.input_tokens,e.cached_input_tokens,
                    e.output_tokens,e.reasoning_output_tokens,e.model,\(optional),\(locationValues("e"))
                FROM events e JOIN sources s ON s.source_id=e.source_id
                JOIN retained_usage_sources h ON h.source_id=s.source_id AND h.session_id=s.session_id
                    AND h.path=s.path AND h.signature=(\(signature)) AND h.parser_revision=(\(parser))
                WHERE \(filter);
                """
            }
            func fingerprints(_ filter: String) -> String {
                """
                INSERT OR IGNORE INTO retained_usage_fingerprints
                SELECT h.snapshot_id,f.value FROM source_fingerprints f JOIN sources s ON s.source_id=f.source_id
                JOIN retained_usage_sources h ON h.source_id=s.source_id AND h.session_id=s.session_id
                    AND h.path=s.path AND h.signature=(\(signature)) AND h.parser_revision=(\(parser))
                WHERE \(filter);
                """
            }
            let valueColumns = ["user_prompt_offset", "assistant_start_offset", "source_id", "source_offset", "timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model"]
                + ["accounting_kind", "reported_total_tokens", "legacy_tokens"].filter { columns.contains($0) }
            let changed = valueColumns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            let oldOptional = ["accounting_kind", "reported_total_tokens", "legacy_tokens"].map { columns.contains($0) ? "OLD.\($0)" : "NULL" }.joined(separator: ",")
            try tx.execute("""
                CREATE TRIGGER retain_usage_before_event_update BEFORE UPDATE ON events
                WHEN \(changed) BEGIN
                    INSERT INTO retained_usage_revisions(
                        source_id,session_id,path,signature,parser_revision,position,timestamp,tokens,
                        input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,
                        model,accounting_kind,reported_total_tokens,legacy_tokens,
                        user_prompt_start,user_prompt_end,assistant_response_start,assistant_response_end,token_source_offset
                    ) SELECT OLD.source_id,s.session_id,s.path,\(signature),\(parser),
                        OLD.source_offset,OLD.timestamp,OLD.tokens,OLD.input_tokens,OLD.cached_input_tokens,
                        OLD.output_tokens,OLD.reasoning_output_tokens,OLD.model,\(oldOptional),\(locationValues("OLD"))
                      FROM sources s WHERE s.source_id=OLD.source_id;
                END;
                CREATE TRIGGER retain_usage_before_event_delete BEFORE DELETE ON events BEGIN
                    \(snapshot("s.source_id=OLD.source_id", reason: "event-replaced"))
                    \(records("e.source_id=OLD.source_id AND e.source_offset=OLD.source_offset"))
                END;
                CREATE TRIGGER retain_usage_before_source_delete BEFORE DELETE ON sources BEGIN
                    \(snapshot("s.source_id=OLD.source_id", reason: "source-unavailable"))
                    \(records("e.source_id=OLD.source_id"))
                    \(fingerprints("f.source_id=OLD.source_id"))
                END;
                CREATE TRIGGER retain_usage_before_identity_update BEFORE UPDATE OF path,session_id ON sources
                WHEN OLD.path IS NOT NEW.path OR OLD.session_id IS NOT NEW.session_id BEGIN
                    \(snapshot("s.source_id=OLD.source_id", reason: "source-identity-changed"))
                    \(records("e.source_id=OLD.source_id"))
                    \(fingerprints("f.source_id=OLD.source_id"))
                END;
                CREATE TRIGGER retain_usage_before_fingerprint_delete BEFORE DELETE ON source_fingerprints BEGIN
                    \(snapshot("s.source_id=OLD.source_id", reason: "event-replaced"))
                    \(fingerprints("f.source_id=OLD.source_id AND f.value=OLD.value"))
                END;
                """)
            for (key, value) in [("schema_version", revision), ("writer_revision", writerRevision), ("event_columns", flavor)] {
                try tx.execute("INSERT INTO retained_usage_meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", bindings: [.text(key), .text(value)])
            }
        }
    }
}
