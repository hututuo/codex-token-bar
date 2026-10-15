import Foundation
import CryptoKit

/// A scan receipt belongs to the same SQLite commit as its numeric generation.
/// The timestamp is captured BEFORE discovery, never after lengthy parsing.
struct UsageIndexCoverageCertificate: Codable, Equatable {
    let revision: Int
    let provenanceEpoch: String
    let generation: Int64
    let scanID: String
    let observedAt: Date
    let sourceCount: Int
    let inventoryDigest: String

    static func publish(epoch: String, generation: Int64, scanID: String,
                        observedAt: Date, sourceCount: Int,
                        on db: SQLiteDatabaseConnection) throws {
        var digest = SHA256()
        // Byte-complete witness of retained source checkpoints and availability.
        try db.forEachRow("""
            SELECT s.source_id,s.path,s.session_id,s.size_bytes,s.modified_at,
                s.content_probe,s.last_seen_generation,l.missing
            FROM sources s LEFT JOIN usage_ledger_sources l USING(source_id)
            ORDER BY s.source_id
            """) { row in
            for column in Int32(0)..<row.columnCount { digest.update(data:row.canonicalBytes(column)) }
        }
        let receipt = Self(revision:1,provenanceEpoch:epoch,generation:generation,
            scanID:scanID,observedAt:observedAt,sourceCount:sourceCount,
            inventoryDigest:digest.finalize().map { String(format:"%02x",$0) }.joined())
        let text = String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try db.execute("INSERT OR REPLACE INTO schema_meta(key,value) VALUES ('usage_scan_certificate',?)",bindings:[.text(text)])
    }

    static func read(on db: SQLiteDatabaseConnection) throws -> Self? {
        let rows = try db.readRows("SELECT value FROM schema_meta WHERE key='usage_scan_certificate'") { $0.text(0) }
        guard let raw = rows.first ?? nil else { return nil }
        return try JSONDecoder().decode(Self.self,from:Data(raw.utf8))
    }
}
