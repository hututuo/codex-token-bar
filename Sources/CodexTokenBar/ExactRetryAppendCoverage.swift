import Foundation
import SQLite3

/// Compatibility boundary for an unfinished 0.9.8–0.9.11 Exact import whose
/// legacy writer continued to append or fill missing model/turn metadata. The
/// incoming ledger can retain several generations after raw files disappear.
/// caller has proved the schemas equal and every historical row outside
/// `mutableTables` preserved.
/// This verifier changes neither main database. Its TEMP witnesses are scoped
/// to the candidate's existing read transaction and disappear on close.
enum ExactRetryAppendCoverage {
    static let mutableTables: Set<String> = [
        "sources", "source_chunks", "source_observations", "source_representations",
        "event_enrichment_sources", "schema_meta", "usage_ledger_meta",
        "usage_ledger_duplicates", "attribution_source_buckets", "dashboard_source_5m",
        "dashboard_source_totals", "dashboard_5m", "dashboard_turn_candidates",
        "events", "usage_ledger_bindings", "usage_ledger_sources"
    ]

    static let eventColumns = ["source_id", "source_offset", "timestamp", "tokens", "input_tokens",
        "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model", "user_prompt_offset",
        "assistant_start_offset", "accounting_kind", "reported_total_tokens", "legacy_tokens"]
    static let witnessColumns: [String: [String]] = [
        "events": eventColumns,
        "source_fingerprints": ["source_id", "value"],
        "usage_ledger_bindings": ["source_id", "event_id", "generation", "raw_offset", "prompt_offset", "assistant_offset", "available"],
        "usage_ledger_identities": ["source_id", "identity", "event_id"],
        "usage_ledger_turns": ["source_id", "generation", "raw_offset", "turn_id"],
        "usage_ledger_sources": ["source_id", "session_id", "missing", "format", "generation"],
        "usage_ledger_unresolved": ["source_id", "generation", "raw_offset", "timestamp", "tokens", "input_tokens",
            "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "model", "accounting_kind",
            "reported_total_tokens", "legacy_tokens", "identity", "prompt_offset", "assistant_offset", "reason"],
        "usage_ledger_corrections": ["source_id", "event_id", "generation", "raw_offset", "parser_revision",
            "old_tokens", "new_tokens", "reason"]
    ]
    static let projectionTables = ["usage_ledger_duplicates", "dashboard_source_5m",
        "dashboard_source_totals", "dashboard_5m", "dashboard_turn_candidates", "attribution_source_buckets"]

    private static let contracts: [String: [String]] = witnessColumns.merging([
        "sources": ["source_id", "path", "session_id", "size_bytes", "modified_at", "content_probe", "last_seen_generation",
            "append_ready", "resume_offset", "previous_total_tokens", "fork_replay_started_at", "is_skipping_fork_replay",
            "is_explicit_subagent_fork", "last_skipped_fork_replay_token_at", "current_user_prompt_offset",
            "assistant_start_offset", "current_model", "audit_chunk_index", "accounting_state"],
        "source_chunks": ["source_id", "chunk_index", "byte_count", "sha256"],
        "source_observations": ["source_id", "size_bytes", "modified_at", "physical_stamp"],
        "source_representations": ["source_id", "physical_path", "storage_format", "physical_size", "physical_stamp", "logical_size", "modified_at", "verification"],
        "event_enrichment_sources": ["source_id", "revision", "canonical_path", "parser_revision", "imported_generation", "completed_size", "completed_probe"],
        "schema_meta": ["key", "value"], "usage_ledger_meta": ["key", "value"],
        "usage_ledger_duplicates": ["source_id", "event_id", "representative_source_id"],
        "attribution_source_buckets": ["provenance_epoch", "source_lineage", "bucket_start", "model", "input_tokens",
            "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "calls"],
        "dashboard_source_5m": ["source_id", "bucket_start", "model", "input_tokens", "cached_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens", "calls"],
        "dashboard_source_totals": ["source_id", "session_id", "input_tokens", "cached_input_tokens", "output_tokens",
            "reasoning_output_tokens", "total_tokens", "calls", "first_timestamp", "last_timestamp"],
        "dashboard_5m": ["bucket_start", "model", "input_tokens", "cached_input_tokens", "output_tokens",
            "reasoning_output_tokens", "total_tokens", "calls"],
        "dashboard_turn_candidates": ["source_id", "source_offset", "session_id", "timestamp", "total_tokens", "input_tokens",
            "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "hit_rate", "uncached_tokens", "turn_index",
            "session_calls", "request_count", "low_hit_count", "zero_hit_count"]
    ], uniquingKeysWith: { first, _ in first })

    static func verify(current: SQLiteDatabaseConnection, previous: SQLiteDatabaseConnection,
                       candidateURL: URL, provedMetadataChanges: Set<String>) throws -> Bool {
        for (table, known) in contracts {
            let columns = try current.readRows("PRAGMA main.table_xinfo(\(quote(table)))") { ($0.text(1) ?? "", $0.int(6) ?? -1) }
            guard columns.count == known.count, Set(columns.map(\.0)) == Set(known),
                  columns.allSatisfy({ $0.1 == 0 }) else {
                return false
            }
        }
        let compatibility = CodexUsageHistoryIndex.persistentSnapshotCompatibility
        for db in [previous, current] {
            guard try metadata(db, "schema_version") == "14",
                  try metadata(db, "representation_revision") == "rollout-storage-v1",
                  try metadata(db, "provenance_revision") == compatibility.provenanceRevision,
                  try metadata(db, "event_enrichment_revision") == "model-v1",
                  try metadata(db, "revision", table: "usage_ledger_meta") == UsageEventLedger.revision,
                  try metadata(db, "attribution_current_scan_unsafe_cause") == "0" else {
                return false
            }
        }
        // Canonical rows are also history: physical row preservation alone
        // would allow a fabricated duplicate marker to hide prior consumption.
        try current.execute("CREATE TEMP TABLE exact_retry_rows(encoded BLOB PRIMARY KEY, needed INTEGER NOT NULL, found INTEGER NOT NULL) WITHOUT ROWID")
        let numericHistory = eventColumns.filter { !["model", "user_prompt_offset", "assistant_start_offset"].contains($0) }
            .map(quote).joined(separator: ",")
        var covered = try checked("retry-exact-canonical-history") {
            // The complete witness below separately proves every metadata
            // field. Canonical visibility must retain the same event IDs and
            // exact numeric payload even when a NULL model becomes known.
            try rows(current, "SELECT \(numericHistory) FROM main.canonical_usage_events",
                cover: previous, "SELECT \(numericHistory) FROM main.canonical_usage_events")
        }
        var reclassifiedSources = Set<Int64>()
        let ledgerValid = try checked("retry-exact-durable-history") {
            reclassifiedSources = try ExactRetryDurableHistory.verify(current: current, previous: previous)
            return true
        }
        covered = ledgerValid && covered
        covered = try checked("retry-exact-source-continuity") {
            try CodexUsageHistoryIndex.verifyRetryDurableSources(current: current, previous: previous,
                candidateURL: candidateURL)
        } && covered
        covered = try checked("retry-exact-metadata") {
            try metadataCovers(current, previous: previous, provedChanges: provedMetadataChanges)
        } && covered
        if ledgerValid {
            covered = try checked("retry-exact-projections") {
                try CodexUsageHistoryIndex.verifyRetryAppendProjections(current: current, previous: previous,
                    candidateURL: candidateURL, reclassifiedSources: reclassifiedSources)
            } && covered
        }
        return covered
    }

    private static func checked(_ _: String,
                                _ work: () throws -> Bool) throws -> Bool {
        do {
            let result = try work()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            return false
        }
    }

    /// Full typed multiset comparison, including duplicates and NUL text. Main
    /// tables stay explicitly qualified even while production projection code
    /// works with TEMP tables of the same logical names.
    static func rows(_ current: SQLiteDatabaseConnection, _ actualSQL: String,
                     cover previous: SQLiteDatabaseConnection, _ expectedSQL: String,
                     bindings: [SQLiteBinding] = [], exactly: Bool = false) throws -> Bool {
        try current.execute("DELETE FROM temp.exact_retry_rows")
        let expected = try current.prepare("INSERT INTO temp.exact_retry_rows VALUES(?,1,0) ON CONFLICT(encoded) DO UPDATE SET needed=needed+1")
        let found = try current.prepare("INSERT INTO temp.exact_retry_rows VALUES(?,0,1) ON CONFLICT(encoded) DO UPDATE SET found=found+1")
        try previous.forEachRow(expectedSQL, bindings: bindings) { _ = try expected.execute([.blob(encoded($0))]) }
        try current.forEachRow(actualSQL, bindings: bindings) { _ = try found.execute([.blob(encoded($0))]) }
        return try current.readRows("SELECT 1 FROM temp.exact_retry_rows WHERE \(exactly ? "needed<>found" : "needed>found") LIMIT 1") { $0.int(0) }.isEmpty
    }

    static func columns(_ table: String) -> String {
        (contracts[table] ?? []).map(quote).joined(separator: ",")
    }
    static func quote(_ name: String) -> String { SQLiteStoreNamespace.quote(name) }
    static func encoded(_ row: SQLiteStatement) -> Data {
        var bytes = Data()
        for column in 0..<row.columnCount { bytes.append(row.canonicalBytes(column)) }
        return bytes
    }
    static func metadata(_ db: SQLiteDatabaseConnection, _ key: String, table: String = "schema_meta") throws -> String? {
        try db.readRows("SELECT value FROM main.\(quote(table)) WHERE key=? AND typeof(value)='text'",
            bindings: [.text(key)]) { $0.text(0) }.first ?? nil
    }
    private static func integer(_ db: SQLiteDatabaseConnection, _ key: String, table: String = "schema_meta") throws -> Int64? {
        guard let text = try metadata(db, key, table: table), let number = Int64(text), number >= 0,
              text == String(number) else { return nil }
        return number
    }

    private static func metadataCovers(_ current: SQLiteDatabaseConnection, previous: SQLiteDatabaseConnection,
                                       provedChanges: Set<String>) throws -> Bool {
        guard let oldGeneration = try integer(previous, "attribution_generation"),
              let generation = try integer(current, "attribution_generation"), generation >= oldGeneration,
              try integer(current, "dashboard_aggregate_exact_generation") == generation,
              let oldSequence = try integer(previous, "source_id_sequence"),
              let sequence = try integer(current, "source_id_sequence"), sequence >= oldSequence,
              let oldNext = try integer(previous, "next_id", table: "usage_ledger_meta"),
              let next = try integer(current, "next_id", table: "usage_ledger_meta"),
              oldNext >= 1 << 62, next >= oldNext, next < Int64.max,
              let certificate = try UsageIndexCoverageCertificate.read(on: current),
              certificate.revision == 1, certificate.generation == generation,
              try certificate.provenanceEpoch == metadata(current, "provenance_epoch"),
              UUID(uuidString: certificate.scanID) != nil,
              certificate.observedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(certificate.observedAt.timeIntervalSince1970),
              try certificate.inventoryDigest == UsageIndexCoverageCertificate.inventoryDigest(on: current) else { return false }
        let maximumSource = try current.readRows("SELECT COALESCE(MAX(source_id),0) FROM main.sources") { $0.int64(0) }.first ?? nil
        let activeSources = try current.readRows("SELECT COUNT(*) FROM main.sources s WHERE NOT EXISTS(SELECT 1 FROM main.usage_ledger_sources l WHERE l.source_id=s.source_id AND l.missing=1)") { $0.int(0) }.first ?? nil
        guard let maximumSource, maximumSource <= sequence, activeSources == certificate.sourceCount else { return false }
        for query in ["SELECT MAX(source_offset) FROM main.events", "SELECT MAX(turn_id) FROM main.usage_ledger_turns"] {
            if let maximum = try current.readRows(query, map: { $0.int64(0) }).first ?? nil, maximum >= next { return false }
        }
        if let priorCertificate = try UsageIndexCoverageCertificate.read(on: previous) {
            guard certificate.observedAt >= priorCertificate.observedAt else { return false }
        }
        let certificateKeys: Set<String> = ["revision", "provenanceEpoch", "generation", "scanID", "observedAt", "sourceCount", "inventoryDigest"]
        for db in [previous, current] {
            if let raw = try metadata(db, "usage_scan_certificate") {
                guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      Set(object.keys) == certificateKeys else { return false }
            }
        }
        var changed = Set(["attribution_generation", "dashboard_aggregate_exact_generation", "source_id_sequence", "usage_scan_certificate"])
        // Publishing an already validated dashboard changes only its bounded
        // generation/time receipt; it cannot authorize different history.
        if let published = try metadata(current, "dashboard_aggregate_published_generation") {
            guard let value = Int64(published), String(value) == published, value >= 0, value <= generation,
                  let settled = try integer(current, "dashboard_aggregate_settled_through"),
                  Double(settled) <= certificate.observedAt.timeIntervalSince1970 else { return false }
            if let old = try integer(previous, "dashboard_aggregate_published_generation"), value < old { return false }
            if let old = try integer(previous, "dashboard_aggregate_settled_through"), settled < old { return false }
            changed.formUnion(["dashboard_aggregate_published_generation", "dashboard_aggregate_settled_through"])
        }
        for key in ["storage_maintenance_last_checked_unix", "storage_maintenance_last_compacted_unix"] {
            if try metadata(current, key) != metadata(previous, key) {
                guard let after = try metadata(current, key).flatMap(Double.init), after.isFinite,
                      (0...253_402_300_799).contains(after) else { return false }
                if let before = try metadata(previous, key).flatMap(Double.init), after < before { return false }
                changed.insert(key)
            }
        }
        // UPDATE preserves row identities. Only the released certificate writer
        // uses INSERT OR REPLACE, so only that known key may acquire a new rowid.
        let stable = changed.subtracting(["usage_scan_certificate"]).sorted()
        for key in stable {
            guard try rows(current, "SELECT rowid,key,typeof(value) FROM main.schema_meta WHERE key=?",
                cover: previous, "SELECT rowid,key,typeof(value) FROM main.schema_meta WHERE key=?", bindings: [.text(key)]) else { return false }
        }
        changed.formUnion(provedChanges)
        let placeholders = changed.map { _ in "?" }.joined(separator: ",")
        let bindings = changed.sorted().map(SQLiteBinding.text)
        guard try rows(current, "SELECT rowid,key,value FROM main.schema_meta WHERE key IS NULL OR key NOT IN (\(placeholders))",
            cover: previous, "SELECT rowid,key,value FROM main.schema_meta WHERE key IS NULL OR key NOT IN (\(placeholders))", bindings: bindings),
              try rows(current, "SELECT rowid,key,typeof(value) FROM main.usage_ledger_meta WHERE key='next_id'",
                cover: previous, "SELECT rowid,key,typeof(value) FROM main.usage_ledger_meta WHERE key='next_id'", exactly: true),
              try rows(current, "SELECT rowid,key,value FROM main.usage_ledger_meta WHERE key IS NULL OR key<>'next_id'",
                cover: previous, "SELECT rowid,key,value FROM main.usage_ledger_meta WHERE key IS NULL OR key<>'next_id'") else { return false }
        return true
    }

    /// Copy the known attribution payload into TEMP without converting SQLite
    /// types. This table retains historical maxima, so a projection rebuild
    /// starts from the frozen values instead of trusting the incoming cache.
    static func seedAttribution(current: SQLiteDatabaseConnection, previous: SQLiteDatabaseConnection) throws {
        let names = contracts["attribution_source_buckets"]!
        let insert = try current.prepare("INSERT INTO temp.attribution_source_buckets(\(names.map(quote).joined(separator: ","))) VALUES (\(names.map { _ in "?" }.joined(separator: ",")))")
        try previous.forEachRow("SELECT \(names.map(quote).joined(separator: ",")) FROM main.attribution_source_buckets") { row in
            let values: [SQLiteBinding] = try (0..<row.columnCount).map { column in
                switch row.canonicalBytes(column).first {
                case UInt8(SQLITE_INTEGER): return .int64(row.int64(column)!)
                case UInt8(SQLITE_FLOAT): return .double(row.double(column)!)
                case UInt8(SQLITE_TEXT): return .text(row.text(column)!)
                case UInt8(SQLITE_BLOB): return .blob(row.data(column)!)
                case UInt8(SQLITE_NULL): return .null
                default: throw BusinessStoreError.proofMismatch
                }
            }
            _ = try insert.execute(values)
        }
        guard try rows(current, "SELECT \(columns("attribution_source_buckets")) FROM temp.attribution_source_buckets",
            cover: previous, "SELECT \(columns("attribution_source_buckets")) FROM main.attribution_source_buckets", exactly: true) else {
            throw BusinessStoreError.proofMismatch
        }
    }
}
