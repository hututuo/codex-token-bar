import Foundation
import SQLite3

/// An unfinished released import can outlive both several writer generations
/// and the raw files. The incoming database is durable history in its own
/// right. This proof protects every frozen fact and verifies the new ledger's
/// internal ownership; it does not claim external authentication of consumption
/// first recorded after the frozen import. The caller retains both images and
/// binds their complete typed proofs again in the publication transaction.
///
/// Only the recognized schema-14 / ledger-2 contract enters this adapter.
/// Unknown tables, old identities, fingerprints, turns and retained revisions
/// have already passed the caller's complete typed multiset coverage.
enum ExactRetryDurableHistory {
    private static let firstAllocatedID: Int64 = 1 << 62
    private static func quote(_ name: String) -> String { ExactRetryAppendCoverage.quote(name) }

    struct Row {
        let values: [SQLiteBinding]
        let fields: [Data]
        var encoded: Data { fields.reduce(into: Data()) { $0.append($1) } }

        init(_ statement: SQLiteStatement, offset: Int32 = 0, count: Int32? = nil) throws {
            let end = offset + (count ?? (statement.columnCount - offset))
            values = try (offset..<end).map { column in
                switch statement.canonicalBytes(column).first {
                case UInt8(SQLITE_INTEGER): return .int64(statement.int64(column)!)
                case UInt8(SQLITE_FLOAT): return .double(statement.double(column)!)
                case UInt8(SQLITE_TEXT): return .text(statement.text(column)!)
                case UInt8(SQLITE_BLOB): return .blob(statement.data(column)!)
                case UInt8(SQLITE_NULL): return .null
                default: throw BusinessStoreError.proofMismatch
                }
            }
            fields = (offset..<end).map(statement.canonicalBytes)
        }
    }

    /// Returns only sources whose model classification acquired information.
    /// Rebinding text or adding another turn generation cannot authorize an
    /// attribution floor reset.
    static func verify(current: SQLiteDatabaseConnection, previous: SQLiteDatabaseConnection) throws -> Set<Int64> {
        guard let oldNext = try ExactRetryAppendCoverage.metadata(previous, "next_id", table: "usage_ledger_meta").flatMap(Int64.init),
              let next = try ExactRetryAppendCoverage.metadata(current, "next_id", table: "usage_ledger_meta").flatMap(Int64.init),
              oldNext >= firstAllocatedID, next >= oldNext, next < Int64.max else {
            throw BusinessStoreError.proofMismatch
        }
        // These tables have no unexamined hidden row ID. The outer proof has
        // already bound their entire schema, including indexes and triggers.
        for table in ["events", "usage_ledger_bindings", "usage_ledger_turns", "usage_ledger_identities", "source_fingerprints",
                      "source_chunks", "usage_ledger_duplicates", "attribution_source_buckets", "dashboard_source_5m",
                      "dashboard_5m", "dashboard_turn_candidates", "usage_ledger_unresolved", "usage_ledger_corrections"] {
            guard try current.readRows("SELECT wr FROM pragma_table_list WHERE schema='main' AND name=?",
                bindings: [.text(table)], map: { $0.int(0) }) == [1] else { throw BusinessStoreError.proofMismatch }
        }
        for table in ["sources", "usage_ledger_sources", "source_observations", "source_representations",
                      "event_enrichment_sources", "dashboard_source_totals"] {
            let key = try current.readRows("PRAGMA main.table_info(\(quote(table)))") {
                ($0.text(1) ?? "", $0.text(2) ?? "", $0.int(5) ?? 0)
            }.filter { $0.2 > 0 }
            guard key.count == 1, key[0].0 == "source_id", key[0].1.uppercased() == "INTEGER",
                  try current.readRows("SELECT 1 FROM pragma_index_list(?) WHERE origin='pk'",
                    bindings: [.text(table)], map: { $0.int(0) }).isEmpty else { throw BusinessStoreError.proofMismatch }
        }
        for table in ["events", "usage_ledger_bindings", "usage_ledger_sources", "usage_ledger_turns"] {
            try copyFrozen(table, current: current, previous: previous)
        }
        try current.execute("""
            CREATE UNIQUE INDEX temp.exact_retry_old_event_key ON exact_retry_old_events(source_id,source_offset);
            CREATE UNIQUE INDEX temp.exact_retry_old_binding_key ON exact_retry_old_usage_ledger_bindings(source_id,event_id);
            CREATE INDEX temp.exact_retry_old_turn_id ON exact_retry_old_usage_ledger_turns(source_id,turn_id);
            CREATE UNIQUE INDEX temp.exact_retry_old_turn_key ON exact_retry_old_usage_ledger_turns(source_id,generation,raw_offset);
            """)
        try validateReferences(current, oldNext: oldNext, next: next)

        let bindingNames = ExactRetryAppendCoverage.witnessColumns["usage_ledger_bindings"]!
        let oldBindings = bindingNames.map { "o." + quote($0) }.joined(separator: ",")
        let newBindings = bindingNames.map { "n." + quote($0) }.joined(separator: ",")
        try current.forEachRow("""
            SELECT \(oldBindings),\(newBindings) FROM temp.exact_retry_old_usage_ledger_bindings o
            LEFT JOIN main.usage_ledger_bindings n ON n.source_id=o.source_id AND n.event_id=o.event_id
            """) { statement in
            let old = try Row(statement, count: Int32(bindingNames.count))
            let incoming = try Row(statement, offset: Int32(bindingNames.count))
            guard old.fields[0] == incoming.fields[0], old.fields[1] == incoming.fields[1] else {
                throw BusinessStoreError.proofMismatch
            }
            if old.fields[2] == incoming.fields[2] {
                // Append/missing detection keep raw positions in the same
                // generation. A message pass may only fill a missing link.
                guard old.fields[3] == incoming.fields[3] else { throw BusinessStoreError.proofMismatch }
                for column in [4, 5] {
                    if case .null = old.values[column] { continue }
                    guard old.fields[column] == incoming.fields[column] else { throw BusinessStoreError.proofMismatch }
                }
            } else {
                guard case .text(let generation) = incoming.values[2], UUID(uuidString: generation) != nil else {
                    throw BusinessStoreError.proofMismatch
                }
            }
        }

        let names = ExactRetryAppendCoverage.eventColumns
        let oldColumns = names.map { "o." + quote($0) }.joined(separator: ",")
        let newColumns = names.map { "n." + quote($0) }.joined(separator: ",")
        var reclassified = Set<Int64>()
        try current.forEachRow("""
            SELECT \(oldColumns),\(newColumns) FROM temp.exact_retry_old_events o
            LEFT JOIN main.events n ON n.source_id=o.source_id AND n.source_offset=o.source_offset
            """) { statement in
            if Task.isCancelled { throw CancellationError() }
            let old = try Row(statement, count: Int32(names.count))
            let incoming = try Row(statement, offset: Int32(names.count))
            // No row may disappear, be reassigned, or change a historical
            // numeric/time/accounting value. SQLite types are part of a fact.
            for column in names.indices where ![8, 9, 10].contains(column) {
                guard old.fields[column] == incoming.fields[column] else { throw BusinessStoreError.proofMismatch }
            }
            for column in [8, 9, 10] {
                if case .null = old.values[column] { continue }
                guard old.fields[column] == incoming.fields[column] else { throw BusinessStoreError.proofMismatch }
            }
            if case .null = old.values[8], case .text = incoming.values[8] {
                guard try retainedModelVersion(old, current: current, previous: previous),
                      case .int64(let source) = old.values[0] else { throw BusinessStoreError.proofMismatch }
                reclassified.insert(source)
            }
            // enrichTurn can fill the assistant only with the first missing
            // logical turn. Subsequent rebinds keep that historical offset;
            // its generation need not be the latest raw file's generation.
            if case .null = old.values[10], case .int64 = incoming.values[10] {
                guard case .null = old.values[9], case .int64 = incoming.values[9] else {
                    throw BusinessStoreError.proofMismatch
                }
            }
        }
        return reclassified
    }

    private static func copyFrozen(_ table: String, current: SQLiteDatabaseConnection,
                                   previous: SQLiteDatabaseConnection) throws {
        let columns = ExactRetryAppendCoverage.columns(table)
        let target = quote("exact_retry_old_" + table)
        try current.execute("CREATE TEMP TABLE \(target) AS SELECT \(columns) FROM main.\(quote(table)) WHERE 0")
        let count = ExactRetryAppendCoverage.witnessColumns[table]!.count
        let insert = try current.prepare("INSERT INTO temp.\(target) VALUES(\(Array(repeating: "?", count: count).joined(separator: ",")))")
        try previous.forEachRow("SELECT \(columns) FROM main.\(quote(table))") {
            _ = try insert.execute(Row($0).values)
        }
        guard try ExactRetryAppendCoverage.rows(current, "SELECT \(columns) FROM temp.\(target)",
            cover: previous, "SELECT \(columns) FROM main.\(quote(table))", exactly: true) else {
            throw BusinessStoreError.proofMismatch
        }
    }

    private static func rejectRows(_ db: SQLiteDatabaseConnection, _ sql: String,
                                   bindings: [SQLiteBinding] = []) throws {
        guard try db.readRows(sql + " LIMIT 1", bindings: bindings, map: { $0.int(0) }).isEmpty else {
            throw BusinessStoreError.proofMismatch
        }
    }

    private static func validateReferences(_ db: SQLiteDatabaseConnection, oldNext: Int64, next: Int64) throws {
        try rejectRows(db, "SELECT 1 FROM pragma_foreign_key_check")
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_sources l LEFT JOIN main.sources s USING(source_id)
            WHERE (typeof(l.source_id)='integer' AND l.source_id>0 AND s.source_id IS NOT NULL
                AND typeof(l.session_id)='text' AND CAST(l.session_id AS BLOB)=CAST(s.session_id AS BLOB)
                AND typeof(l.missing)='integer' AND l.missing IN (0,1)
                AND typeof(l.format)='text' AND l.format IN ('unknown','legacy','paginated')
                AND typeof(l.generation)='text' AND length(l.generation)>0) IS NOT 1
            """)
        try rejectRows(db, "SELECT 1 FROM main.sources s WHERE NOT EXISTS(SELECT 1 FROM main.usage_ledger_sources l WHERE l.source_id=s.source_id)")
        // A source cannot silently acquire another account/session owner.
        try rejectRows(db, """
            SELECT 1 FROM temp.exact_retry_old_usage_ledger_sources o
            LEFT JOIN main.usage_ledger_sources n USING(source_id)
            WHERE n.source_id IS NULL OR typeof(n.session_id)<>typeof(o.session_id)
                OR CAST(n.session_id AS BLOB)<>CAST(o.session_id AS BLOB)
            """)
        try rejectRows(db, """
            SELECT 1 FROM main.events e WHERE (
                typeof(source_id)='integer' AND source_id>0 AND typeof(source_offset)='integer' AND source_offset>=0 AND source_offset<?
                AND EXISTS(SELECT 1 FROM main.sources s WHERE s.source_id=e.source_id)
                AND typeof(timestamp)='real' AND typeof(tokens)='integer' AND tokens>=0
                AND typeof(input_tokens)='integer' AND typeof(cached_input_tokens)='integer'
                AND typeof(output_tokens)='integer' AND typeof(reasoning_output_tokens)='integer'
                AND (model IS NULL OR typeof(model)='text')
                AND (user_prompt_offset IS NULL OR (typeof(user_prompt_offset)='integer' AND user_prompt_offset>=0
                    AND EXISTS(SELECT 1 FROM main.usage_ledger_turns t WHERE t.source_id=e.source_id AND t.turn_id=e.user_prompt_offset)))
                AND (assistant_start_offset IS NULL OR (typeof(assistant_start_offset)='integer' AND assistant_start_offset>=0))
                AND typeof(accounting_kind)='integer' AND accounting_kind BETWEEN 0 AND 4
                AND (reported_total_tokens IS NULL OR typeof(reported_total_tokens)='integer')
                AND (legacy_tokens IS NULL OR typeof(legacy_tokens)='integer')
                AND (accounting_kind<>0 OR (input_tokens>=0 AND output_tokens>=0
                    AND cached_input_tokens BETWEEN 0 AND input_tokens AND reasoning_output_tokens BETWEEN 0 AND output_tokens
                    AND input_tokens<=9223372036854775807-output_tokens AND tokens=input_tokens+output_tokens))) IS NOT 1
            """, bindings: [.int64(next)])
        try db.forEachRow("SELECT timestamp FROM main.events") {
            guard let timestamp = $0.double(0), timestamp.isFinite else { throw BusinessStoreError.proofMismatch }
        }
        try rejectRows(db, """
            SELECT 1 FROM main.events e LEFT JOIN temp.exact_retry_old_events o
                ON o.source_id=e.source_id AND o.source_offset=e.source_offset
            WHERE o.source_id IS NULL AND e.source_offset<?
            """, bindings: [.int64(oldNext)])
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_bindings b LEFT JOIN main.sources s USING(source_id)
            LEFT JOIN main.usage_ledger_sources l USING(source_id)
            WHERE (typeof(b.source_id)='integer' AND typeof(b.event_id)='integer'
                AND EXISTS(SELECT 1 FROM main.events e WHERE e.source_id=b.source_id AND e.source_offset=b.event_id)
                AND typeof(b.generation)='text' AND length(b.generation)>0
                AND typeof(b.raw_offset)='integer' AND b.raw_offset>=0
                AND (b.prompt_offset IS NULL OR (typeof(b.prompt_offset)='integer' AND b.prompt_offset>=0))
                AND (b.assistant_offset IS NULL OR (typeof(b.assistant_offset)='integer' AND b.assistant_offset>=0))
                AND typeof(b.available)='integer' AND b.available IN (0,1)
                AND (b.available=0 OR (l.missing=0 AND CAST(b.generation AS BLOB)=CAST(l.generation AS BLOB)
                    AND b.raw_offset<s.size_bytes AND (b.prompt_offset IS NULL OR b.prompt_offset<s.size_bytes)
                    AND (b.assistant_offset IS NULL OR b.assistant_offset<s.size_bytes)))
                AND (b.prompt_offset IS NULL OR EXISTS(SELECT 1 FROM main.usage_ledger_turns t
                    WHERE t.source_id=b.source_id AND t.generation=b.generation AND t.raw_offset=b.prompt_offset))) IS NOT 1
            """)
        try rejectRows(db, "SELECT 1 FROM main.events e WHERE (SELECT COUNT(*) FROM main.usage_ledger_bindings b WHERE b.source_id=e.source_id AND b.event_id=e.source_offset)<>1")
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_turns t WHERE (
                typeof(source_id)='integer' AND EXISTS(SELECT 1 FROM main.sources s WHERE s.source_id=t.source_id)
                AND typeof(generation)='text' AND length(generation)>0
                AND typeof(raw_offset)='integer' AND raw_offset>=0
                AND typeof(turn_id)='integer' AND turn_id>=0 AND turn_id<?) IS NOT 1
            """, bindings: [.int64(next)])
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_turns t WHERE t.turn_id<? AND NOT EXISTS(
                SELECT 1 FROM temp.exact_retry_old_usage_ledger_turns o WHERE o.source_id=t.source_id AND o.turn_id=t.turn_id)
            """, bindings: [.int64(oldNext)])
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_turns t WHERE NOT EXISTS(
                SELECT 1 FROM temp.exact_retry_old_usage_ledger_turns o
                WHERE o.source_id=t.source_id AND o.generation=t.generation AND o.raw_offset=t.raw_offset)
                AND NOT EXISTS(SELECT 1 FROM main.events e WHERE e.source_id=t.source_id AND e.user_prompt_offset=t.turn_id)
            """)
        // Allocated event/turn IDs share one sequence. The same logical turn
        // may have many generation mappings, but never another source owner
        // or an event identity. Legacy raw offsets remain source scoped.
        try rejectRows(db, """
            SELECT 1 FROM (
                SELECT source_offset AS id,source_id,'event' AS kind FROM main.events WHERE source_offset>=?
                UNION ALL SELECT DISTINCT turn_id,source_id,'turn' FROM main.usage_ledger_turns WHERE turn_id>=?
            ) GROUP BY id HAVING COUNT(*)<>1
            """, bindings: [.int64(firstAllocatedID), .int64(firstAllocatedID)])
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_identities i WHERE (
                typeof(source_id)='integer' AND typeof(event_id)='integer' AND typeof(identity)='blob'
                AND EXISTS(SELECT 1 FROM main.events e WHERE e.source_id=i.source_id AND e.source_offset=i.event_id)) IS NOT 1
            """)
        for (table, field) in [("usage_ledger_identities", "identity"), ("source_fingerprints", "value")] {
            try rejectRows(db, "SELECT 1 FROM main.\(table) f WHERE typeof(source_id)<>'integer' OR typeof(\(field))<>'blob' OR NOT EXISTS(SELECT 1 FROM main.sources s WHERE s.source_id=f.source_id)")
            try db.forEachRow("SELECT \(field) FROM main.\(table)") {
                guard let bytes = $0.data(0), try UsageFingerprintCodec.encode(UsageFingerprintCodec.decode(bytes)) == bytes else {
                    throw BusinessStoreError.proofMismatch
                }
            }
        }
        for table in ["source_chunks", "source_observations", "source_representations", "event_enrichment_sources"] {
            try rejectRows(db, "SELECT 1 FROM main.\(table) r WHERE NOT EXISTS(SELECT 1 FROM main.sources s WHERE s.source_id=r.source_id)")
        }
        try validateDiagnostics(db)
    }

    private static func validateDiagnostics(_ db: SQLiteDatabaseConnection) throws {
        // An unresolved observation is deliberately outside counted usage.
        // Intermediate generations may survive several rewrites; only a row
        // claiming the *current* generation is bounded by the current prefix.
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_unresolved u LEFT JOIN main.sources s USING(source_id)
            LEFT JOIN main.usage_ledger_sources l USING(source_id) WHERE (
                typeof(u.source_id)='integer' AND s.source_id IS NOT NULL AND l.source_id IS NOT NULL
                AND typeof(u.generation)='text' AND length(u.generation)>0
                AND typeof(u.raw_offset)='integer' AND u.raw_offset>=0
                AND typeof(u.timestamp)='real' AND typeof(u.tokens)='integer' AND u.tokens>=0
                AND typeof(u.input_tokens)='integer' AND typeof(u.cached_input_tokens)='integer'
                AND typeof(u.output_tokens)='integer' AND typeof(u.reasoning_output_tokens)='integer'
                AND (u.model IS NULL OR typeof(u.model)='text')
                AND typeof(u.accounting_kind)='integer' AND u.accounting_kind BETWEEN 0 AND 4
                AND (u.accounting_kind<>0 OR (u.input_tokens>=0 AND u.output_tokens>=0
                    AND u.cached_input_tokens BETWEEN 0 AND u.input_tokens AND u.reasoning_output_tokens BETWEEN 0 AND u.output_tokens
                    AND u.input_tokens<=9223372036854775807-u.output_tokens AND u.tokens=u.input_tokens+u.output_tokens))
                AND (u.reported_total_tokens IS NULL OR typeof(u.reported_total_tokens)='integer')
                AND (u.legacy_tokens IS NULL OR typeof(u.legacy_tokens)='integer')
                AND (u.identity IS NULL OR typeof(u.identity)='blob')
                AND (u.prompt_offset IS NULL OR (typeof(u.prompt_offset)='integer' AND u.prompt_offset>=0))
                AND (u.assistant_offset IS NULL OR (typeof(u.assistant_offset)='integer' AND u.assistant_offset>=0))
                AND typeof(u.reason)='text' AND u.reason IN ('identity-conflict','unproved-rewrite-observation')
                AND (u.generation<>l.generation OR (u.raw_offset<s.size_bytes
                    AND (u.prompt_offset IS NULL OR u.prompt_offset<s.size_bytes)
                    AND (u.assistant_offset IS NULL OR u.assistant_offset<s.size_bytes)))
                AND NOT EXISTS(SELECT 1 FROM main.usage_ledger_bindings b WHERE b.source_id=u.source_id
                    AND b.generation=u.generation AND b.raw_offset=u.raw_offset AND b.available=1)) IS NOT 1
            """)
        try db.forEachRow("SELECT generation,timestamp,identity FROM main.usage_ledger_unresolved") {
            guard let generation = $0.text(0), UUID(uuidString: generation) != nil,
                  let timestamp = $0.double(1), timestamp.isFinite else { throw BusinessStoreError.proofMismatch }
            if let identity = $0.data(2) {
                guard try UsageFingerprintCodec.encode(UsageFingerprintCodec.decode(identity)) == identity else {
                    throw BusinessStoreError.proofMismatch
                }
            }
        }
        try rejectRows(db, """
            SELECT 1 FROM main.usage_ledger_corrections c WHERE (
                typeof(source_id)='integer' AND typeof(event_id)='integer'
                AND EXISTS(SELECT 1 FROM main.events e WHERE e.source_id=c.source_id AND e.source_offset=c.event_id)
                AND typeof(generation)='text' AND length(generation)>0
                AND typeof(raw_offset)='integer' AND raw_offset>=0
                AND typeof(parser_revision)='text' AND length(parser_revision)>0
                AND typeof(old_tokens)='integer' AND typeof(new_tokens)='integer'
                AND typeof(reason)='text' AND length(reason)>0) IS NOT 1
            """)
    }

    private static func retainedModelVersion(_ old: Row, current: SQLiteDatabaseConnection,
                                             previous: SQLiteDatabaseConnection) throws -> Bool {
        let key = Array(old.values[0...1])
        guard let binding = try previous.readRows("SELECT \(ExactRetryAppendCoverage.columns("usage_ledger_bindings")) FROM main.usage_ledger_bindings WHERE source_id=? AND event_id=?",
            bindings: key, map: { try Row($0) }).first,
              let owner = try previous.readRows("SELECT session_id,path FROM main.sources WHERE source_id=?",
                bindings: [old.values[0]], map: { try Row($0) }).first else { return false }
        let names = ["source_id", "position", "timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens",
            "reasoning_output_tokens", "model", "accounting_kind", "reported_total_tokens", "legacy_tokens",
            "session_id", "path", "user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end", "token_source_offset"]
        let expected = Array(old.fields[0...8]) + Array(old.fields[11...13]) + owner.fields
            + [binding.fields[4], nullBytes, binding.fields[5], nullBytes, binding.fields[3]]
        let encoded = expected.reduce(into: Data()) { $0.append($1) }
        var found = false
        try current.forEachRow("SELECT \(names.map(quote).joined(separator: ",")) FROM main.retained_usage_revisions WHERE source_id=? AND position=?",
            bindings: key) { if ExactRetryAppendCoverage.encoded($0) == encoded { found = true } }
        return found
    }

    private static var nullBytes: Data { Data([UInt8(SQLITE_NULL)] + Array(repeating: UInt8(0), count: 8)) }
}
