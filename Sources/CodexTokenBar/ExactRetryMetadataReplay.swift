import Foundation
import SQLite3

/// A released full reparse can associate an old usage identity with a new raw
/// position and fill a missing model or logical turn. This adapter constructs
/// the exact rows that admit/enrichTurn/bind are allowed to produce; it never
/// accepts a candidate row merely because its totals happen to agree.
///
/// The owning verifier supplies a bounded production parse and complete raw
/// chunk proofs. Both main databases stay in their original read transactions.
final class ExactRetryMetadataReplay {
    private struct Row {
        let values: [SQLiteBinding]
        let fields: [Data]
        var encoded: Data { fields.reduce(into: Data()) { $0.append($1) } }
    }
    private let witness: ExactRetryAppendCoverage.AppendWitness
    private let source: Int64
    private let session: String
    private let path: String
    private let generation: String
    private let previousGeneration: String
    private let unchangedPrefix: Bool
    private let firstNewID: Int64
    private let nextID: Int64
    private var current: SQLiteDatabaseConnection { witness.current }
    private var previous: SQLiteDatabaseConnection { witness.previous }

    init(witness: ExactRetryAppendCoverage.AppendWitness, source: Int64, session: String,
         path: String, generation: String, format: String, unchangedPrefix: Bool) throws {
        self.witness = witness; self.source = source; self.session = session; self.path = path
        self.generation = generation; self.unchangedPrefix = unchangedPrefix
        guard UUID(uuidString: generation) != nil, ["legacy", "paginated"].contains(format),
              let oldNext = try ExactRetryAppendCoverage.metadata(witness.previous, "next_id", table: "usage_ledger_meta").flatMap(Int64.init),
              let next = try ExactRetryAppendCoverage.metadata(witness.current, "next_id", table: "usage_ledger_meta").flatMap(Int64.init),
              oldNext >= 1 << 62, next >= oldNext, next < Int64.max,
              let owner = try Self.row(witness.previous, table: "usage_ledger_sources", predicate: "source_id=?", bindings: [.int64(source)]),
              case .int64(let ownerID) = owner.values[0], ownerID == source,
              case .text(let ownerSession) = owner.values[1], Data(ownerSession.utf8) == Data(session.utf8),
              case .int64(0) = owner.values[2],
              case .text(let oldFormat) = owner.values[3], ["legacy", "paginated", "unknown"].contains(oldFormat),
              case .text(let oldGeneration) = owner.values[4], !oldGeneration.isEmpty else {
            throw BusinessStoreError.proofMismatch
        }
        firstNewID = oldNext; nextID = next; previousGeneration = oldGeneration
        guard generation != oldGeneration || unchangedPrefix else { throw BusinessStoreError.proofMismatch }
        // A rowid table with the same visible columns is not this contract:
        // replacing encoded rows must not discard an unexamined hidden ID.
        for table in ["events", "usage_ledger_bindings"] {
            guard try witness.current.readRows("SELECT wr FROM pragma_table_list WHERE schema='main' AND name=?",
                bindings: [.text(table)], map: { $0.int(0) }) == [1] else { throw BusinessStoreError.proofMismatch }
        }
        let sourceKey = try witness.current.readRows("PRAGMA main.table_info(usage_ledger_sources)") {
            ($0.text(1) ?? "", $0.text(2) ?? "", $0.int(5) ?? 0)
        }.filter { $0.2 > 0 }
        guard sourceKey.count == 1, sourceKey[0].0 == "source_id", sourceKey[0].1.uppercased() == "INTEGER",
              try witness.current.readRows("SELECT 1 FROM pragma_index_list('usage_ledger_sources') WHERE origin='pk'", map: { $0.int(0) }).isEmpty else {
            throw BusinessStoreError.proofMismatch
        }
        try witness.replace("usage_ledger_sources", old: owner.encoded,
            with: [.int64(source), .text(session), .int(0), .text(format), .text(generation)])
    }

    func fingerprint(_ value: CodexUsageAnalyzer.UsageSnapshotFingerprint) throws -> Bool {
        let bytes = try value.databaseValue
        try witness.remember("source_fingerprints", [.int64(source), .blob(bytes)])
        // A full parser must see its own fresh deduplication set. The frozen
        // source-level set remains preserved in the final ledger witness.
        let insert = try current.prepare("INSERT OR IGNORE INTO temp.exact_retry_replay_fingerprints VALUES(?,?)")
        return try insert.execute([.int64(source), .blob(bytes)]) == 1
    }

    func event(_ indexed: CodexUsageAnalyzer.IndexedTokenEvent) throws {
        guard indexed.sourceOffset <= UInt64(Int64.max),
              indexed.userPromptOffset.map({ $0 <= UInt64(Int64.max) }) ?? true,
              indexed.assistantStartOffset.map({ $0 <= UInt64(Int64.max) }) ?? true else { throw BusinessStoreError.proofMismatch }
        let raw = Int64(indexed.sourceOffset)
        let prompt = indexed.userPromptOffset.map(Int64.init), assistant = indexed.assistantStartOffset.map(Int64.init)
        let binding = try current.readRows("SELECT event_id FROM main.usage_ledger_bindings WHERE source_id=? AND generation=? AND raw_offset=? AND available=1",
            bindings: [.int64(source), .text(generation), .int64(raw)]) { row -> Int64? in
                guard row.canonicalBytes(0).first == UInt8(SQLITE_INTEGER) else { return nil }
                return row.int64(0)
            }
        guard binding.count == 1, let eventID = binding[0] else { throw BusinessStoreError.proofMismatch }
        let seen = try current.prepare("INSERT OR IGNORE INTO temp.exact_retry_replay_events VALUES(?,?)")
        guard try seen.execute([.int64(source), .int64(eventID)]) == 1 else { throw BusinessStoreError.proofMismatch }
        let key: [SQLiteBinding] = [.int64(source), .int64(eventID)]
        let old = try Self.row(previous, table: "events", predicate: "source_id=? AND source_offset=?", bindings: key)
        let oldBinding = try Self.row(previous, table: "usage_ledger_bindings", predicate: "source_id=? AND event_id=?", bindings: key)
        let event = indexed.event
        let parsed: [SQLiteBinding] = [.int64(source), .int64(eventID), .double(event.timestamp.timeIntervalSince1970),
            .int(event.tokens), .int(event.inputTokens), .int(event.cachedInputTokens), .int(event.outputTokens),
            .int(event.reasoningOutputTokens), .optionalText(event.model), .null, .null,
            .int(indexed.accountingKind.rawValue), .optionalInt(indexed.reportedTotalTokens), .null]
        var expected = parsed
        if let old {
            guard let oldBinding else { throw BusinessStoreError.proofMismatch }
            guard case .text(let oldRawGeneration) = oldBinding.values[2], !oldRawGeneration.isEmpty,
                  case .int64(let oldRawOffset) = oldBinding.values[3], oldRawOffset >= 0,
                  case .int64(let oldAvailable) = oldBinding.values[6], [0, 1].contains(oldAvailable) else {
                throw BusinessStoreError.proofMismatch
            }
            for position in [4, 5] { _ = try optionalInteger(oldBinding.values[position]) }
            _ = try optionalInteger(old.values[10])
            switch old.values[8] { case .null, .text: break; default: throw BusinessStoreError.proofMismatch }
            var sameIdentity = false
            if let identity = indexed.usageFingerprint {
                let oldIDs = try previous.readRows("SELECT event_id FROM main.usage_ledger_identities WHERE source_id=? AND identity=?",
                    bindings: [.int64(source), .blob(identity)]) { $0.int64(0) }
                sameIdentity = oldIDs == [eventID]
            }
            if !sameIdentity, unchangedPrefix {
                sameIdentity = try previous.readRows("SELECT event_id FROM main.usage_ledger_bindings WHERE source_id=? AND generation=? AND raw_offset=?",
                    bindings: [.int64(source), .text(previousGeneration), .int64(raw)], map: { $0.int64(0) }) == [eventID]
            }
            guard sameIdentity else { throw BusinessStoreError.proofMismatch }
            let parsedFields = try fields(parsed)
            // admit preserves timestamp and reported/legacy values for a
            // metadata association. Require the exact historical numeric fact
            // and independently match its time/components/accounting to raw.
            for position in [2, 3, 4, 5, 6, 7, 11] where old.fields[position] != parsedFields[position] {
                throw BusinessStoreError.proofMismatch
            }
            expected = old.values
            if case .null = old.values[8], let model = event.model {
                expected[8] = .text(model)
                guard try retainedModelVersion(old, binding: oldBinding) else { throw BusinessStoreError.proofMismatch }
            }
            let oldTurn = try optionalInteger(old.values[9])
            if let prompt {
                let turn = try logicalTurn(prompt: prompt, existing: oldTurn)
                if oldTurn == nil {
                    expected[9] = .int64(turn)
                    if case .null = old.values[10] { expected[10] = optional(assistant) }
                }
            }
            try witness.replace("events", old: old.encoded, with: expected)
        } else {
            guard oldBinding == nil else { throw BusinessStoreError.proofMismatch }
            try allocate(eventID, kind: "event", raw: raw)
            if let prompt { expected[9] = .int64(try logicalTurn(prompt: prompt, existing: nil)) }
            expected[10] = optional(assistant)
            try witness.remember("events", expected)
        }
        let newBinding: [SQLiteBinding] = [.int64(source), .int64(eventID), .text(generation), .int64(raw), optional(prompt), optional(assistant), .int(1)]
        if let oldBinding { try witness.replace("usage_ledger_bindings", old: oldBinding.encoded, with: newBinding) }
        else { try witness.remember("usage_ledger_bindings", newBinding) }
        if let identity = indexed.usageFingerprint {
            try witness.remember("usage_ledger_identities", [.int64(source), .blob(identity), .int64(eventID)])
        }
    }

    func finish() throws {
        // A source rewrite that omits an available old observation is outside
        // this metadata-only contract. Already unavailable historical rows
        // remain seeded unchanged and need no surviving raw file.
        var complete = true
        try previous.forEachRow("SELECT event_id FROM main.usage_ledger_bindings WHERE source_id=? AND available=1", bindings: [.int64(source)]) { row in
            guard let id = row.int64(0), try current.readRows("SELECT 1 FROM temp.exact_retry_replay_events WHERE source_id=? AND event_id=?",
                bindings: [.int64(source), .int64(id)], map: { $0.int(0) }) == [1] else { complete = false; return }
        }
        guard complete else { throw BusinessStoreError.proofMismatch }
        witness.didReplay(source: source)
    }

    private func logicalTurn(prompt: Int64, existing: Int64?) throws -> Int64 {
        let key: [SQLiteBinding] = [.int64(source), .text(generation), .int64(prompt)]
        let remembered = try current.readRows("SELECT turn_id FROM temp.exact_retry_turns WHERE source_id=? AND generation=? AND raw_offset=?",
            bindings: key) { $0.int64(0) }.first ?? nil
        let proposed: Int64
        if let existing { proposed = existing }
        else if let remembered { proposed = remembered }
        else {
            let incoming = try current.readRows("SELECT turn_id FROM main.usage_ledger_turns WHERE source_id=? AND generation=? AND raw_offset=?", bindings: key) { row -> Int64? in
                guard row.canonicalBytes(0).first == UInt8(SQLITE_INTEGER) else { return nil }
                return row.int64(0)
            }
            guard incoming.count == 1, let id = incoming[0] else { throw BusinessStoreError.proofMismatch }
            try allocate(id, kind: "turn", raw: prompt)
            proposed = id
        }
        let stored = remembered ?? proposed
        if remembered == nil {
            try current.execute("INSERT INTO temp.exact_retry_turns VALUES(?,?,?,?)", bindings: key + [.int64(stored)])
        }
        try witness.remember("usage_ledger_turns", key + [.int64(stored)])
        // enrichTurn preserves an existing logical ID even if an earlier raw
        // observation already established this generation's shared turn key.
        return proposed
    }

    private func allocate(_ id: Int64, kind: String, raw: Int64) throws {
        guard id >= firstNewID, id < nextID,
              try current.readRows("SELECT 1 FROM temp.exact_retry_reserved_ids WHERE id=?", bindings: [.int64(id)], map: { $0.int(0) }).isEmpty else { throw BusinessStoreError.proofMismatch }
        try current.execute("INSERT INTO temp.exact_retry_allocations VALUES(?,?,?,?)",
            bindings: [.int64(id), .text(kind), .int64(source), .int64(raw)])
    }

    private func retainedModelVersion(_ old: Row, binding: Row) throws -> Bool {
        let names = ["source_id", "position", "timestamp", "tokens", "input_tokens", "cached_input_tokens", "output_tokens",
            "reasoning_output_tokens", "model", "accounting_kind", "reported_total_tokens", "legacy_tokens",
            "session_id", "path", "user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end", "token_source_offset"]
        let payload = Array(old.values[0...8]) + Array(old.values[11...13])
            + [.text(session), .text(path), binding.values[4], .null, binding.values[5], .null, binding.values[3]]
        let expected = try fields(payload).reduce(into: Data()) { $0.append($1) }
        var found = false
        try current.forEachRow("SELECT \(names.map(ExactRetryAppendCoverage.quote).joined(separator: ",")) FROM main.retained_usage_revisions WHERE source_id=? AND position=?",
            bindings: [old.values[0], old.values[1]]) { if ExactRetryAppendCoverage.encoded($0) == expected { found = true } }
        return found
    }

    private func fields(_ values: [SQLiteBinding]) throws -> [Data] {
        guard let row = try current.readRows("SELECT " + values.map { _ in "?" }.joined(separator: ","), bindings: values,
            map: { statement in (0..<statement.columnCount).map(statement.canonicalBytes) }).first else { throw BusinessStoreError.proofMismatch }
        return row
    }
    private func optional(_ value: Int64?) -> SQLiteBinding { value.map(SQLiteBinding.int64) ?? .null }
    private func optionalInteger(_ value: SQLiteBinding) throws -> Int64? {
        switch value {
        case .null: return nil
        case .int64(let number) where number >= 0: return number
        default: throw BusinessStoreError.proofMismatch
        }
    }
    private static func row(_ db: SQLiteDatabaseConnection, table: String, predicate: String, bindings: [SQLiteBinding]) throws -> Row? {
        let names = ExactRetryAppendCoverage.columns(table)
        let rows = try db.readRows("SELECT \(names) FROM main.\(ExactRetryAppendCoverage.quote(table)) WHERE \(predicate)", bindings: bindings) { statement -> Row in
            let values: [SQLiteBinding] = try (0..<statement.columnCount).map { column in
                switch statement.canonicalBytes(column).first {
                case UInt8(SQLITE_INTEGER): return .int64(statement.int64(column)!)
                case UInt8(SQLITE_FLOAT): return .double(statement.double(column)!)
                case UInt8(SQLITE_TEXT): return .text(statement.text(column)!)
                case UInt8(SQLITE_BLOB): return .blob(statement.data(column)!)
                case UInt8(SQLITE_NULL): return .null
                default: throw BusinessStoreError.proofMismatch
                }
            }
            return Row(values: values, fields: (0..<statement.columnCount).map(statement.canonicalBytes))
        }
        guard rows.count <= 1 else { throw BusinessStoreError.proofMismatch }
        return rows.first
    }
}
