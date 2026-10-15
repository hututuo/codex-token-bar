import Foundation

/// Physical observations are never removed by deduplication. All numeric
/// readers share this reversible projection; UUID alone is not usage identity.
enum CanonicalUsageProjection {
    private struct EventIdentity: Hashable {
        let source: Int64
        let event: Int64
    }

    static func install(on db: SQLiteDatabaseConnection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS usage_ledger_duplicates(
                source_id INTEGER NOT NULL,event_id INTEGER NOT NULL,
                representative_source_id INTEGER NOT NULL,
                PRIMARY KEY(source_id,event_id)) WITHOUT ROWID;
            CREATE VIEW IF NOT EXISTS canonical_usage_events AS
                SELECT e.* FROM events e WHERE NOT EXISTS(
                    SELECT 1 FROM usage_ledger_duplicates d
                    WHERE d.source_id=e.source_id AND d.event_id=e.source_offset);
            """)
    }

    /// Only complete, identical usage observations within the SAME valid
    /// session UUID can be copies. Different fork UUIDs never meet this test.
    @discardableResult
    static func refresh(on db: SQLiteDatabaseConnection) throws -> Bool {
        let ready = try db.readRows("SELECT 1 FROM sqlite_master WHERE name='usage_ledger_identities'") { $0.int(0) }.first != nil
        guard ready else { return false }
        let sources = try db.readRows("SELECT source_id,session_id FROM sources ORDER BY source_id") { s -> (Int64,String)? in
            guard let id=s.int64(0), let raw=s.text(1), let uuid=UUID(uuidString:raw) else { return nil }
            return (id,uuid.uuidString.lowercased())
        }.compactMap { $0 }
        let groups = Dictionary(grouping:sources,by: { $0.1 }).values.filter { $0.count > 1 }
        let old = try exclusions(on:db)
        if groups.isEmpty && old.isEmpty { return false }
        var desired: [EventIdentity:Int64] = [:]
        for group in groups {
            // The key contains the complete fingerprint AND exact timestamp,
            // model and every admitted accounting value, without lossy hashes.
            var first: [Data:Int64] = [:]
            for (source,_) in group.sorted(by: { $0.0 < $1.0 }) {
                let rows = try db.readRows("""
                    SELECT e.source_offset,i.identity,e.timestamp,e.tokens,e.input_tokens,
                        e.cached_input_tokens,e.output_tokens,e.reasoning_output_tokens,e.model,
                        e.accounting_kind,e.reported_total_tokens,e.legacy_tokens
                    FROM events e JOIN usage_ledger_identities i
                        ON i.source_id=e.source_id AND i.event_id=e.source_offset
                    WHERE e.source_id=? ORDER BY e.source_offset
                    """,bindings:[.int64(source)]) { s -> (Int64,Data)? in
                        guard let event=s.int64(0), let identity=s.data(1),
                              try UsageEventLedger.isCompleteSnapshot(identity) else { return nil }
                        var key=Data()
                        for column in Int32(1)..<s.columnCount { key.append(s.canonicalBytes(column)) }
                        return (event,key)
                    }.compactMap { $0 }
                for (event,key) in rows {
                    if let representative=first[key], representative < source {
                        desired[EventIdentity(source:source,event:event)]=representative
                    } else { first[key]=source }
                }
            }
        }
        guard old != desired else { return false }
        try db.execute("DELETE FROM usage_ledger_duplicates")
        for (key,representative) in desired {
            try db.execute("INSERT INTO usage_ledger_duplicates VALUES (?,?,?)",
                bindings:[.int64(key.source),.int64(key.event),.int64(representative)])
        }
        return true
    }

    private static func exclusions(on db: SQLiteDatabaseConnection) throws -> [EventIdentity:Int64] {
        let rows=try db.readRows("SELECT source_id,event_id,representative_source_id FROM usage_ledger_duplicates") {
            (EventIdentity(source:$0.int64(0)!,event:$0.int64(1)!),$0.int64(2)!)
        }
        return Dictionary(uniqueKeysWithValues:rows)
    }
}
