import CryptoKit
import Foundation

enum BodySpeedMigrationError: LocalizedError {
    case invalidSharedLocation
    case invalidDestinationNamespace
    case partialLegacySchema
    case unsupportedLegacySchema(String)
    case unsupportedLegacyVersion
    case invalidLegacyRow
    case destinationNotEmpty
    case receiptMismatch
    case proofMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSharedLocation: "Completed body storage cannot share the legacy database file"
        case .invalidDestinationNamespace: "The completed body namespace in the shared database has an unexpected schema"
        case .partialLegacySchema: "The legacy completed body store has only part of its required schema"
        case .unsupportedLegacySchema(let table): "The legacy completed body table has an unsupported schema: \(table)"
        case .unsupportedLegacyVersion: "The legacy completed body store has an unsupported schema version"
        case .invalidLegacyRow: "The legacy completed body store contains a row that cannot be copied safely"
        case .destinationNotEmpty: "The shared completed body destination already has data without a migration receipt"
        case .receiptMismatch: "The completed body migration receipt does not match its source partition"
        case .proofMismatch: "The completed body migration did not preserve every legacy row"
        }
    }
}

/// Imports the four existing numeric/history tables as a unit. The retained
/// aggregate and dedup-ID tables are copied directly; they are never rebuilt
/// from the lossy raw sample window.
enum BodySpeedMigration {
    private static let tableColumns: [(name: String, columns: [String], order: String)] = [
        ("speed_trend_meta", ["key", "value"], "key"),
        ("speed_samples", ["id", "ended_at", "model", "included", "payload_json"], "id"),
        ("speed_sample_ids", ["id", "ended_at", "bucket_start", "model", "output_tokens", "duration_seconds", "trend_eligible"], "id"),
        ("speed_5m", ["bucket_start", "model", "output_tokens", "duration_seconds", "sample_count"], "bucket_start, model")
    ]

    private struct Counts: Equatable {
        var meta: Int64
        var samples: Int64
        var sampleIDs: Int64
        var aggregates: Int64
    }

    private struct Proof: Equatable {
        var rowsDigest: String
        var counts: Counts
    }

    private struct SnapshotRows {
        var tables: [String: [[SQLiteBinding]]]
        var proof: Proof
    }

    private struct Receipt {
        let sourceIdentity: String
        let sourceDigest: String
        let rowsDigest: String
        let counts: Counts
        let backupPath: String
        let completedAt: Double
    }

    static func migrate(logicalURL: URL, database: BodySpeedDatabase) throws {
        guard let sharedURL = database.sharedURL else { return }
        let sourceIdentity = logicalURL.standardizedFileURL.path

        if let receipt = try readReceipt(sourceIdentity: sourceIdentity, database: database) {
            try validate(receipt, sourceIdentity: sourceIdentity)
            try validateBackup(receipt)
            // Future process starts do not reread the old source. The receipt
            // and its successful import commit establish the source boundary.
            return
        }

        guard let snapshotURL = try makeSnapshot(logicalURL: logicalURL, sharedURL: sharedURL) else {
            // A missing legacy file has no rows to migrate. Do not write a
            // completion receipt for an empty destination.
            return
        }
        let snapshot = try loadSnapshot(snapshotURL)
        guard let snapshot else {
            try? FileManager.default.removeItem(at: snapshotURL)
            return
        }
        let rowsDigest = snapshot.proof.rowsDigest
        let sourceDigest = sourceDigest(sourceIdentity: sourceIdentity, rowsDigest: rowsDigest)

        try database.transaction { connection in
            // Another process may have completed the same import while this
            // process took its immutable source snapshot.
            if let receipt = try readReceipt(sourceIdentity: sourceIdentity, connection: connection) {
                try validate(receipt, sourceIdentity: sourceIdentity)
                return
            }
            let otherSources = try connection.readRows("SELECT source_identity FROM speed_migration_receipts") {
                $0.text(0) ?? ""
            }
            guard otherSources.isEmpty else { throw BodySpeedMigrationError.receiptMismatch }

            try requirePristineDestination(connection)
            try connection.execute("DELETE FROM speed_trend_meta")
            for table in tableColumns {
                let rows = snapshot.tables[table.name] ?? []
                guard Int64(rows.count) == proofCount(snapshot.proof, table: table.name) else {
                    throw BodySpeedMigrationError.proofMismatch
                }
                let columns = table.columns.map(SQLiteStoreNamespace.quote).joined(separator: ",")
                let values = Array(repeating: "?", count: table.columns.count).joined(separator: ",")
                let statement = try connection.prepare("INSERT INTO \(table.name)(\(columns)) VALUES(\(values))")
                for row in rows { _ = try statement.execute(row) }
            }

            let destinationProof = try proof { sql, map in
                try connection.readRows(sql, map: map)
            }
            guard destinationProof == snapshot.proof else { throw BodySpeedMigrationError.proofMismatch }
            try connection.execute(
                "INSERT INTO speed_migration_receipts(source_identity,source_digest,rows_digest,meta_count,sample_count,id_count,aggregate_count,backup_path,completed_at) VALUES(?,?,?,?,?,?,?,?,?)",
                bindings: [
                    .text(sourceIdentity), .text(sourceDigest), .text(rowsDigest),
                    .int64(snapshot.proof.counts.meta), .int64(snapshot.proof.counts.samples),
                    .int64(snapshot.proof.counts.sampleIDs), .int64(snapshot.proof.counts.aggregates),
                    .text(snapshotURL.path), .double(Date().timeIntervalSince1970)
                ]
            )
        }
        guard let receipt = try readReceipt(sourceIdentity: sourceIdentity, database: database) else {
            throw BodySpeedMigrationError.receiptMismatch
        }
        try validate(receipt, sourceIdentity: sourceIdentity)
        try validateBackup(receipt)
    }

    private static func makeSnapshot(logicalURL: URL, sharedURL: URL) throws -> URL? {
        let sourceURL = logicalURL.standardizedFileURL
        let backups = sharedURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let pathHash = SHA256.hash(data: Data(sourceURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let snapshotURL = backups.appendingPathComponent("body-speed-\(pathHash)-\(UUID().uuidString).sqlite")

        if let routedStore = BusinessSQLiteRoutes.store(for: sourceURL) {
            try CodexBusinessDatabase.export(routedStore, to: snapshotURL)
        } else {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
            // sqlite3_backup creates a consistent snapshot including committed
            // WAL contents without holding a destination transaction open.
            let target = SQLiteDatabaseDriver(url: snapshotURL, enableWAL: false, bypassBusinessRoutes: true)
            try target.withConnection { try $0.restoreDatabase(from: sourceURL) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        return snapshotURL
    }

    private static func loadSnapshot(_ url: URL, includeRows: Bool = true) throws -> SnapshotRows? {
        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false,
                                            bypassBusinessRoutes: true)
        return try database.withConnection { connection in
            try connection.readTransaction { snapshot in
                let existing = try snapshot.readRows(
                    "SELECT name FROM main.sqlite_master WHERE type='table' AND name IN ('speed_trend_meta','speed_samples','speed_sample_ids','speed_5m') ORDER BY name"
                ) { $0.text(0) ?? "" }
                guard !existing.isEmpty else { return nil }
                guard Set(existing) == Set(tableColumns.map(\.name)) else {
                    throw BodySpeedMigrationError.partialLegacySchema
                }
                try validateSourceSchema(snapshot)
                try validateSourceMetadata(snapshot)
                let proof = try proof { sql, map in try snapshot.readRows(sql, map: map) }
                var tables: [String: [[SQLiteBinding]]] = [:]
                if includeRows {
                    for table in tableColumns {
                        let projection = table.columns.map { column in
                            let quoted = SQLiteStoreNamespace.quote(column)
                            return "\(quoted),typeof(\(quoted))"
                        }.joined(separator: ",")
                        let sql = "SELECT \(projection) FROM \(SQLiteStoreNamespace.quote(table.name)) ORDER BY \(table.order)"
                        tables[table.name] = try snapshot.readRows(sql) { row in
                            try table.columns.indices.map { index in
                                try binding(row, valueColumn: Int32(index * 2), typeColumn: Int32(index * 2 + 1))
                            }
                        }
                    }
                }
                return SnapshotRows(tables: tables, proof: proof)
            }
        }
    }

    private static func validateSourceSchema(_ db: SQLiteDatabaseConnection) throws {
        let types: [String: [String]] = [
            "speed_trend_meta": ["TEXT", "TEXT"],
            "speed_samples": ["TEXT", "REAL", "TEXT", "INTEGER", "TEXT"],
            "speed_sample_ids": ["TEXT", "REAL", "INTEGER", "TEXT", "INTEGER", "REAL", "INTEGER"],
            "speed_5m": ["INTEGER", "TEXT", "INTEGER", "REAL", "INTEGER"]
        ]
        for table in tableColumns {
            let rows = try db.readRows("PRAGMA table_info(\(SQLiteStoreNamespace.quote(table.name)))") {
                ($0.text(1) ?? "", ($0.text(2) ?? "").uppercased())
            }
            guard rows.map(\.0) == table.columns,
                  rows.map(\.1) == types[table.name] else {
                throw BodySpeedMigrationError.unsupportedLegacySchema(table.name)
            }
        }
    }

    private static func validateSourceMetadata(_ db: SQLiteDatabaseConnection) throws {
        let values = try db.readRows("SELECT key,value FROM speed_trend_meta WHERE key IN ('schema_version','body_retention_days')") {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }
        let metadata = Dictionary(values, uniquingKeysWith: { first, _ in first })
        guard metadata["schema_version"] == "1",
              ["15", "30"].contains(metadata["body_retention_days"] ?? "") else {
            throw BodySpeedMigrationError.unsupportedLegacyVersion
        }
    }

    private static func binding(_ row: SQLiteStatement, valueColumn: Int32, typeColumn: Int32) throws -> SQLiteBinding {
        guard let type = row.text(typeColumn) else { throw BodySpeedMigrationError.invalidLegacyRow }
        switch type {
        case "null": return .null
        case "integer":
            guard let value = row.int64(valueColumn) else { throw BodySpeedMigrationError.invalidLegacyRow }
            return .int64(value)
        case "real":
            guard let value = row.double(valueColumn) else { throw BodySpeedMigrationError.invalidLegacyRow }
            return .double(value)
        case "text":
            guard let value = row.text(valueColumn) else { throw BodySpeedMigrationError.invalidLegacyRow }
            return .text(value)
        case "blob":
            guard let value = row.data(valueColumn) else { throw BodySpeedMigrationError.invalidLegacyRow }
            return .blob(value)
        default: throw BodySpeedMigrationError.invalidLegacyRow
        }
    }

    private static func proof(
        readRows: (_ sql: String, _ map: (SQLiteStatement) throws -> [Data]) throws -> [[Data]]
    ) throws -> Proof {
        var hasher = SHA256()
        var counts = Counts(meta: 0, samples: 0, sampleIDs: 0, aggregates: 0)
        for table in tableColumns {
            updateFramed(Data(table.name.utf8), hasher: &hasher)
            let projection = table.columns.flatMap { column -> [String] in
                let quoted = SQLiteStoreNamespace.quote(column)
                return [quoted, "typeof(\(quoted))"]
            }.joined(separator: ",")
            let sql = "SELECT \(projection) FROM \(SQLiteStoreNamespace.quote(table.name)) ORDER BY \(table.order)"
            var count: Int64 = 0
            let rows = try readRows(sql) { statement in
                var encoded = Data()
                append(UInt64(table.columns.count), to: &encoded)
                for column in table.columns.indices {
                    let value = statement.canonicalBytes(Int32(column * 2))
                    append(UInt64(value.count), to: &encoded)
                    encoded.append(value)
                }
                count += 1
                return [encoded]
            }
            for row in rows {
                guard let encoded = row.first else { throw BodySpeedMigrationError.invalidLegacyRow }
                hasher.update(data: encoded)
            }
            if table.name == "speed_trend_meta" { counts.meta = count }
            else if table.name == "speed_samples" { counts.samples = count }
            else if table.name == "speed_sample_ids" { counts.sampleIDs = count }
            else { counts.aggregates = count }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Proof(rowsDigest: digest, counts: counts)
    }

    private static func readReceipt(sourceIdentity: String, database: BodySpeedDatabase) throws -> Receipt? {
        try database.readRows(
            "SELECT source_identity,source_digest,rows_digest,meta_count,sample_count,id_count,aggregate_count,backup_path,completed_at FROM speed_migration_receipts WHERE source_identity=?",
            bindings: [.text(sourceIdentity)], map: receipt
        ).first ?? nil
    }

    private static func readReceipt(sourceIdentity: String, connection: BodySpeedDatabaseConnection) throws -> Receipt? {
        try connection.readRows(
            "SELECT source_identity,source_digest,rows_digest,meta_count,sample_count,id_count,aggregate_count,backup_path,completed_at FROM speed_migration_receipts WHERE source_identity=?",
            bindings: [.text(sourceIdentity)], map: receipt
        ).first ?? nil
    }

    private static func receipt(_ row: SQLiteStatement) throws -> Receipt {
        guard let sourceIdentity = row.text(0), let sourceDigest = row.text(1),
              let rowsDigest = row.text(2), let metaCount = row.int64(3),
              let sampleCount = row.int64(4), let idCount = row.int64(5),
              let aggregateCount = row.int64(6), let backupPath = row.text(7),
              let completedAt = row.double(8), completedAt.isFinite else {
            throw BodySpeedMigrationError.receiptMismatch
        }
        return Receipt(sourceIdentity: sourceIdentity, sourceDigest: sourceDigest, rowsDigest: rowsDigest,
                       counts: Counts(meta: metaCount, samples: sampleCount, sampleIDs: idCount,
                                      aggregates: aggregateCount), backupPath: backupPath, completedAt: completedAt)
    }

    private static func validate(_ receipt: Receipt, sourceIdentity: String) throws {
        guard receipt.sourceIdentity == sourceIdentity,
              receipt.sourceDigest == sourceDigest(sourceIdentity: sourceIdentity, rowsDigest: receipt.rowsDigest),
              receipt.rowsDigest.count == 64, receipt.rowsDigest.allSatisfy(\.isHexDigit),
              receipt.counts.meta >= 0, receipt.counts.samples >= 0,
              receipt.counts.sampleIDs >= 0, receipt.counts.aggregates >= 0,
              receipt.backupPath.hasPrefix("/"), receipt.completedAt >= 0 else {
            throw BodySpeedMigrationError.receiptMismatch
        }
    }

    private static func validateBackup(_ receipt: Receipt) throws {
        let backupURL = URL(fileURLWithPath: receipt.backupPath)
        guard FileManager.default.fileExists(atPath: backupURL.path),
              let backup = try loadSnapshot(backupURL, includeRows: false),
              backup.proof.rowsDigest == receipt.rowsDigest,
              backup.proof.counts == receipt.counts else {
            throw BodySpeedMigrationError.receiptMismatch
        }
    }

    private static func requirePristineDestination(_ connection: BodySpeedDatabaseConnection) throws {
        for table in ["speed_samples", "speed_sample_ids", "speed_5m"] {
            let count = try connection.readRows("SELECT count(*) FROM \(table)") { $0.int64(0) }.first ?? 0
            guard count == 0 else { throw BodySpeedMigrationError.destinationNotEmpty }
        }
        let metadata = try connection.readRows("SELECT key,value FROM speed_trend_meta ORDER BY key") {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }
        let actual = Dictionary(metadata, uniquingKeysWith: { first, _ in first })
        guard actual == ["body_retention_days": "30", "schema_version": "1"] else {
            throw BodySpeedMigrationError.destinationNotEmpty
        }
    }

    private static func sourceDigest(sourceIdentity: String, rowsDigest: String) -> String {
        let source = Data("body-speed-source-v1\0\(sourceIdentity)\0\(rowsDigest)".utf8)
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }

    private static func updateFramed(_ value: Data, hasher: inout SHA256) {
        var length = UInt64(value.count).bigEndian
        var framed = Data()
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(value)
        hasher.update(data: framed)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func proofCount(_ proof: Proof, table: String) -> Int64 {
        switch table {
        case "speed_trend_meta": proof.counts.meta
        case "speed_samples": proof.counts.samples
        case "speed_sample_ids": proof.counts.sampleIDs
        default: proof.counts.aggregates
        }
    }
}

