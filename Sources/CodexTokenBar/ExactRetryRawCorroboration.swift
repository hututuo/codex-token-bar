import Foundation

/// Optional evidence for a raw prefix that still matches the incoming image.
/// It checks current numeric observations and current bindings. Event model,
/// timestamp and assistant metadata may have been retained from an earlier
/// generation, so this class never reconstructs them from the final raw file.
final class ExactRetryRawCorroboration {
    private let current: SQLiteDatabaseConnection
    private let source: Int64
    private let generation: String

    init(current: SQLiteDatabaseConnection, source: Int64, generation: String) throws {
        self.current = current; self.source = source; self.generation = generation
        try current.execute("""
            CREATE TEMP TABLE IF NOT EXISTS exact_retry_raw_fingerprints(value BLOB PRIMARY KEY) WITHOUT ROWID;
            CREATE TEMP TABLE IF NOT EXISTS exact_retry_raw_events(event_id INTEGER PRIMARY KEY);
            DELETE FROM temp.exact_retry_raw_fingerprints;
            DELETE FROM temp.exact_retry_raw_events;
            """)
    }

    func fingerprint(_ value: CodexUsageAnalyzer.UsageSnapshotFingerprint) throws -> Bool {
        let bytes = try value.databaseValue
        guard try current.readRows("SELECT 1 FROM main.source_fingerprints WHERE source_id=? AND value=?",
            bindings: [.int64(source), .blob(bytes)], map: { $0.int(0) }) == [1] else {
            throw BusinessStoreError.proofMismatch
        }
        let insert = try current.prepare("INSERT OR IGNORE INTO temp.exact_retry_raw_fingerprints VALUES(?)")
        return try insert.execute([.blob(bytes)]) == 1
    }

    func event(_ indexed: CodexUsageAnalyzer.IndexedTokenEvent) throws {
        guard indexed.sourceOffset <= UInt64(Int64.max),
              indexed.userPromptOffset.map({ $0 <= UInt64(Int64.max) }) ?? true,
              indexed.assistantStartOffset.map({ $0 <= UInt64(Int64.max) }) ?? true else {
            throw BusinessStoreError.proofMismatch
        }
        let raw = Int64(indexed.sourceOffset)
        let rows = try current.readRows("SELECT event_id,prompt_offset,assistant_offset FROM main.usage_ledger_bindings WHERE source_id=? AND generation=? AND raw_offset=? AND available=1",
            bindings: [.int64(source), .text(generation), .int64(raw)], map: { try ExactRetryDurableHistory.Row($0) })
        guard rows.count <= 1 else { throw BusinessStoreError.proofMismatch }
        guard let binding = rows.first else {
            // Released reconcile can hold a new, unproved observation while
            // retaining all previous usage. A raw observation is not authority
            // to promote that diagnostic row to counted consumption.
            try unresolved(indexed)
            return
        }
        guard case .int64(let eventID) = binding.values[0] else { throw BusinessStoreError.proofMismatch }
        let event = indexed.event
        let numeric: [SQLiteBinding] = [.int(event.tokens), .int(event.inputTokens), .int(event.cachedInputTokens),
            .int(event.outputTokens), .int(event.reasoningOutputTokens), .int(indexed.accountingKind.rawValue)]
        let expected = try current.readRows("SELECT ?,?,?,?,?,?", bindings: numeric, map: ExactRetryAppendCoverage.encoded)
        let actual = try current.readRows("SELECT tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,accounting_kind FROM main.events WHERE source_id=? AND source_offset=?",
            bindings: [.int64(source), .int64(eventID)], map: ExactRetryAppendCoverage.encoded)
        guard actual == expected else { throw BusinessStoreError.proofMismatch }
        // A message-only pass can supply information absent from the token
        // parser. When the parser knows a current offset, it must agree.
        for (column, parsed) in [(1, indexed.userPromptOffset), (2, indexed.assistantStartOffset)] {
            if let parsed {
                guard case .int64(let stored) = binding.values[column], stored == Int64(parsed) else {
                    throw BusinessStoreError.proofMismatch
                }
            }
        }
        if let identity = indexed.usageFingerprint {
            guard try current.readRows("SELECT event_id FROM main.usage_ledger_identities WHERE source_id=? AND identity=?",
                bindings: [.int64(source), .blob(identity)], map: { $0.int64(0) }) == [eventID] else {
                throw BusinessStoreError.proofMismatch
            }
        }
        try current.execute("INSERT INTO temp.exact_retry_raw_events VALUES(?)", bindings: [.int64(eventID)])
    }

    func finish() throws {
        guard try current.readRows("""
            SELECT 1 FROM main.usage_ledger_bindings b WHERE b.source_id=? AND b.generation=? AND b.available=1
                AND NOT EXISTS(SELECT 1 FROM temp.exact_retry_raw_events e WHERE e.event_id=b.event_id) LIMIT 1
            """, bindings: [.int64(source), .text(generation)], map: { $0.int(0) }).isEmpty else {
            throw BusinessStoreError.proofMismatch
        }
    }

    private func unresolved(_ indexed: CodexUsageAnalyzer.IndexedTokenEvent) throws {
        let event = indexed.event
        let values: [SQLiteBinding] = [.double(event.timestamp.timeIntervalSince1970), .int(event.tokens),
            .int(event.inputTokens), .int(event.cachedInputTokens), .int(event.outputTokens), .int(event.reasoningOutputTokens),
            .optionalText(event.model), .int(indexed.accountingKind.rawValue), .optionalInt(indexed.reportedTotalTokens),
            .null, indexed.usageFingerprint.map(SQLiteBinding.blob) ?? .null,
            indexed.userPromptOffset.map { .int64(Int64($0)) } ?? .null,
            indexed.assistantStartOffset.map { .int64(Int64($0)) } ?? .null]
        let expected = try current.readRows("SELECT " + values.map { _ in "?" }.joined(separator: ","),
            bindings: values, map: ExactRetryAppendCoverage.encoded)
        let actual = try current.readRows("""
            SELECT timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,
                model,accounting_kind,reported_total_tokens,legacy_tokens,identity,prompt_offset,assistant_offset
            FROM main.usage_ledger_unresolved WHERE source_id=? AND generation=? AND raw_offset=?
            """, bindings: [.int64(source), .text(generation), .int64(indexed.sourceOffset)], map: ExactRetryAppendCoverage.encoded)
        guard actual == expected else { throw BusinessStoreError.proofMismatch }
    }
}
