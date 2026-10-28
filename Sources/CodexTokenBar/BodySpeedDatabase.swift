import CryptoKit
import Foundation

/// Routes completed-body storage either to its historical standalone file or
/// to a source-scoped namespace in the shared multi-client usage database.
/// The shared database keeps its own global schema version and unrelated rows.
final class BodySpeedDatabase: @unchecked Sendable {
    static let logicalObjects: Set<String> = [
        "speed_trend_meta", "speed_samples", "speed_samples_ended_model", "speed_samples_model_ended",
        "speed_sample_ids", "speed_sample_ids_ended", "speed_5m", "speed_migration_receipts"
    ]

    let driver: SQLiteDatabaseDriver
    let logicalURL: URL
    let sharedURL: URL?
    let prefix: String?
    private let objectNames: Set<String>

    var isShared: Bool { sharedURL != nil }

    init(logicalURL: URL, sharedURL: URL?) throws {
        self.logicalURL = logicalURL.standardizedFileURL
        self.sharedURL = sharedURL?.standardizedFileURL
        if let sharedURL = self.sharedURL {
            guard self.logicalURL != sharedURL else { throw BodySpeedMigrationError.invalidSharedLocation }
            // Opening the established ledger first validates/initializes B. Its
            // user_version remains owned exclusively by MultiClientUsageLedger.
            _ = try MultiClientUsageLedger(url: sharedURL)
            let hash = SHA256.hash(data: Data("tokenbar-store-v1\0body-speed\0\(self.logicalURL.path)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let prefix = "s\(hash)_"
            self.prefix = prefix
            objectNames = Self.logicalObjects
            driver = SQLiteDatabaseDriver(url: sharedURL, busyTimeoutMilliseconds: 3_000,
                                          enableWAL: true, bypassBusinessRoutes: true)
            try validateNamespace(requireAll: false)
        } else {
            prefix = nil
            objectNames = []
            driver = SQLiteDatabaseDriver(url: self.logicalURL, busyTimeoutMilliseconds: 3_000,
                                          enableWAL: false)
        }
    }

    func readRows<T>(_ sql: String, bindings: [SQLiteBinding] = [],
                     map: (SQLiteStatement) throws -> T) throws -> [T] {
        try driver.withConnection { connection in
            try BodySpeedDatabaseConnection(connection, prefix: prefix, objectNames: objectNames)
                .readRows(sql, bindings: bindings, map: map)
        }
    }

    func transaction<T>(_ body: (BodySpeedDatabaseConnection) throws -> T) throws -> T {
        try driver.transaction { connection in
            try body(BodySpeedDatabaseConnection(connection, prefix: prefix, objectNames: objectNames))
        }
    }

    func readTransaction<T>(_ body: (BodySpeedDatabaseConnection) throws -> T) throws -> T {
        try driver.withConnection { connection in
            try connection.readTransaction { snapshot in
                try body(BodySpeedDatabaseConnection(snapshot, prefix: prefix, objectNames: objectNames))
            }
        }
    }

    func validateNamespace(requireAll: Bool) throws {
        guard let prefix else { return }
        let physicalObjects = try driver.readRows(
            "SELECT name,type FROM main.sqlite_master WHERE name NOT LIKE 'sqlite_%' AND substr(name,1,?)=? ORDER BY name",
            bindings: [.int(prefix.count), .text(prefix)]
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        let expectedTypes = Dictionary(uniqueKeysWithValues: Self.logicalObjects.map { name in
            (prefix + name, name.hasPrefix("speed_samples_") || name == "speed_sample_ids_ended" ? "index" : "table")
        })
        let physicalNames = Set(physicalObjects.map(\.0))
        let expectedNames = Set(expectedTypes.keys)
        guard physicalNames.isSubset(of: expectedNames),
              physicalObjects.allSatisfy({ expectedTypes[$0.0] == $0.1 }),
              !requireAll || physicalNames == expectedNames,
              !physicalNames.contains(prefix + "speed_migration_receipts") || physicalNames == expectedNames else {
            throw BodySpeedMigrationError.invalidDestinationNamespace
        }
        if requireAll { try validateTableSchemas(prefix: prefix) }
    }

    private func validateTableSchemas(prefix: String) throws {
        let definitions: [(String, [String], [String], [Int])] = [
            ("speed_trend_meta", ["key", "value"], ["TEXT", "TEXT"], [1, 0]),
            ("speed_samples", ["id", "ended_at", "model", "included", "payload_json"], ["TEXT", "REAL", "TEXT", "INTEGER", "TEXT"], [1, 0, 0, 0, 0]),
            ("speed_sample_ids", ["id", "ended_at", "bucket_start", "model", "output_tokens", "duration_seconds", "trend_eligible"], ["TEXT", "REAL", "INTEGER", "TEXT", "INTEGER", "REAL", "INTEGER"], [1, 0, 0, 0, 0, 0, 0]),
            ("speed_5m", ["bucket_start", "model", "output_tokens", "duration_seconds", "sample_count"], ["INTEGER", "TEXT", "INTEGER", "REAL", "INTEGER"], [1, 2, 0, 0, 0]),
            ("speed_migration_receipts", ["source_identity", "source_digest", "rows_digest", "meta_count", "sample_count", "id_count", "aggregate_count", "backup_path", "completed_at"], ["TEXT", "TEXT", "TEXT", "INTEGER", "INTEGER", "INTEGER", "INTEGER", "TEXT", "REAL"], [1, 0, 0, 0, 0, 0, 0, 0, 0])
        ]
        for (table, expectedNames, expectedTypes, expectedPrimaryKey) in definitions {
            let columns = try driver.readRows("PRAGMA table_info(\(SQLiteStoreNamespace.quote(prefix + table)))") {
                ($0.text(1) ?? "", ($0.text(2) ?? "").uppercased(), $0.int(5) ?? 0)
            }
            guard columns.map(\.0) == expectedNames, columns.map(\.1) == expectedTypes,
                  columns.map(\.2) == expectedPrimaryKey else {
                throw BodySpeedMigrationError.invalidDestinationNamespace
            }
        }
    }
}

/// Small identifier-binding adapter. Body speed SQL continues to use its
/// original logical table names while the shared file stores prefixed names.
final class BodySpeedDatabaseConnection {
    private let connection: SQLiteDatabaseConnection
    private let prefix: String?
    private var namespace: SQLiteStoreNamespace?

    init(_ connection: SQLiteDatabaseConnection, prefix: String?, objectNames: Set<String>) {
        self.connection = connection
        self.prefix = prefix
        if let prefix {
            namespace = SQLiteStoreNamespace(prefix: prefix, objectNames: objectNames)
        }
    }

    var isShared: Bool { prefix != nil }

    func readRows<T>(_ sql: String, bindings: [SQLiteBinding] = [],
                     map: (SQLiteStatement) throws -> T) throws -> [T] {
        try connection.readRows(try bind(sql), bindings: bindings, map: map)
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        try connection.execute(try bind(sql), bindings: bindings)
    }

    func prepare(_ sql: String) throws -> SQLitePreparedStatement {
        try connection.prepare(try bind(sql))
    }

    private func bind(_ sql: String) throws -> String {
        guard prefix != nil else { return sql }
        return try namespace!.bind(sql)
    }
}
