import CryptoKit
import Darwin
import Foundation
import SQLite3

/// One A file, independently versioned legacy store partitions. Physical table
/// namespaces retain every old key/row without guessing UUID equivalence. B
/// remains multi-client-usage.sqlite. No user store is migrated by this type
/// until the caller explicitly provides an isolated/production migration plan.
struct BusinessSQLiteStore: Equatable, Sendable {
    let containerURL: URL
    let logicalURL: URL
    let module: String
    let sourceIdentity: String
    let id: String
    var prefix: String { "s" + id + "_" }
    init(containerURL: URL, logicalURL: URL, module: String, sourceIdentity: String) {
        self.containerURL = containerURL.standardizedFileURL
        self.logicalURL = logicalURL.standardizedFileURL
        self.module = module; self.sourceIdentity = sourceIdentity
        id = SHA256.hash(data: Data("tokenbar-store-v1\0\(module)\0\(sourceIdentity)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum BusinessSQLiteRoutes {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var routes: [String: BusinessSQLiteStore] = [:]
        var resolvedPaths = Set<String>()
        var registeredIDs = Set<String>()
        var configuration: BusinessDatabaseMigration.Configuration?
        var activeFileIdentity: String?
    }
    private static let state = State()
    static func store(for url: URL) -> BusinessSQLiteStore? {
        let path = url.standardizedFileURL.path
        state.lock.lock(); defer { state.lock.unlock() }
        if state.resolvedPaths.contains(path) { return state.routes[path] }
        guard let configuration = state.configuration,
              let specification = configuration.specification(for: url) else { return nil }
        let resolved = {
            guard specification.module == "exact.swift.stage" else { return specification }
            return BusinessSQLiteStore(
                containerURL: specification.containerURL,
                logicalURL: specification.logicalURL,
                module: specification.module,
                sourceIdentity: specification.sourceIdentity + "\0job:" + UUID().uuidString
            )
        }()
        state.resolvedPaths.insert(path)
        state.routes[path] = resolved
        return resolved
    }
    static func install(_ stores: [BusinessSQLiteStore]) {
        state.lock.lock(); defer { state.lock.unlock() }
        for store in stores {
            state.routes[store.logicalURL.path] = store
            state.resolvedPaths.insert(store.logicalURL.path)
            state.registeredIDs.insert(store.id)
        }
    }
    static func remove(_ stores: [BusinessSQLiteStore]) {
        state.lock.lock(); defer { state.lock.unlock() }
        for store in stores {
            if state.routes[store.logicalURL.path] == store { state.routes.removeValue(forKey: store.logicalURL.path) }
            state.resolvedPaths.insert(store.logicalURL.path)
            state.registeredIDs.remove(store.id)
        }
    }
    static func activate(_ configuration: BusinessDatabaseMigration.Configuration, stores: [BusinessSQLiteStore]) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.configuration = configuration
        state.activeFileIdentity = physicalIdentity(configuration.container)
        state.routes = [:]
        for store in stores { state.routes[store.logicalURL.path] = store }
        state.resolvedPaths = Set(stores.map(\.logicalURL.path))
        state.registeredIDs = Set(stores.map(\.id))
    }
    static func deactivate() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.configuration = nil
        state.activeFileIdentity = nil
        state.routes.removeAll()
        state.resolvedPaths.removeAll()
        state.registeredIDs.removeAll()
    }
    static func allStores(in directory: URL) -> [BusinessSQLiteStore] {
        let root = directory.standardizedFileURL.path
        state.lock.lock()
        let candidates = Array(state.routes.values)
        state.lock.unlock()
        let containers = Set(candidates.map(\.containerURL))
        var registeredPaths = Set<String>()
        for container in containers {
            let db = SQLiteDatabaseDriver(url: container, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
            let paths = (try? db.readRows("SELECT logical_path FROM tb_stores WHERE state IN ('ready','sealed','staging')") { $0.text(0) ?? "" }) ?? []
            registeredPaths.formUnion(paths)
        }
        return candidates.filter { store in
            let path = store.logicalURL.path
            return registeredPaths.contains(path)
                && (path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/"))
        }.sorted { $0.logicalURL.path < $1.logicalURL.path }
    }
    @discardableResult static func rename(_ oldStore: BusinessSQLiteStore, to newLogicalURL: URL) throws -> BusinessSQLiteStore {
        let newStore = BusinessSQLiteStore(
            containerURL: oldStore.containerURL,
            logicalURL: newLogicalURL,
            module: oldStore.module,
            sourceIdentity: oldStore.sourceIdentity
        )
        let db = SQLiteDatabaseDriver(url: oldStore.containerURL, enableWAL: false, bypassBusinessRoutes: true)
        let oldPath = oldStore.logicalURL.standardizedFileURL.path
        let newPath = newStore.logicalURL.path
        let current = try db.readRows("SELECT logical_path FROM tb_stores WHERE store_id=?", bindings: [.text(oldStore.id)]) { $0.text(0) }.first ?? nil
        if current != newPath {
            guard current == oldPath else { throw BusinessStoreError.invalidStore }
            let changed = try db.executeChangedRows(
                "UPDATE tb_stores SET logical_path=? WHERE store_id=? AND logical_path=?",
                bindings: [.text(newPath), .text(oldStore.id), .text(oldPath)]
            )
            guard changed == 1 else { throw BusinessStoreError.invalidStore }
        }
        state.lock.lock(); defer { state.lock.unlock() }
        if state.routes[oldPath] == oldStore { state.routes.removeValue(forKey: oldPath) }
        state.routes[newPath] = newStore
        state.registeredIDs.insert(newStore.id)
        // The old primary path is eligible for a fresh stage identity after a
        // quarantine move; a normal deletion uses `forget` and stays absent.
        state.resolvedPaths.remove(oldPath)
        state.resolvedPaths.insert(newPath)
        return newStore
    }
    static func forget(_ store: BusinessSQLiteStore) {
        let path = store.logicalURL.standardizedFileURL.path
        state.lock.lock(); defer { state.lock.unlock() }
        if state.routes[path] == store { state.routes.removeValue(forKey: path) }
        state.registeredIDs.remove(store.id)
        if state.configuration == nil { state.resolvedPaths.insert(path) }
        else { state.resolvedPaths.remove(path) }
    }
    private static func physicalIdentity(_ url: URL) -> String? {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(value.st_dev):\(value.st_ino)"
    }
    static func validateActiveContainer(_ url: URL) throws -> Bool {
        state.lock.lock()
        let configured = state.configuration?.container.standardizedFileURL
        let expected = state.activeFileIdentity
        state.lock.unlock()
        guard configured == url.standardizedFileURL else { return false }
        guard let expected, physicalIdentity(url) == expected else { throw BusinessStoreError.sourceChanged }
        return true
    }
    static func isRegistered(_ store: BusinessSQLiteStore) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.registeredIDs.contains(store.id)
    }
    static func didRegister(_ store: BusinessSQLiteStore) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.registeredIDs.insert(store.id)
    }
    static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let store = store(for: url) else { return fileManager.fileExists(atPath: url.path) }
        guard fileManager.fileExists(atPath: store.containerURL.path) else { return false }
        if isRegistered(store) { return true }
        let db = SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let exists = (try? db.readRows("SELECT 1 FROM tb_stores WHERE store_id=? AND state IN ('ready','sealed','staging')", bindings: [.text(store.id)]) { $0.int(0) }.first) == 1
        if exists { didRegister(store) }
        return exists
    }
}

struct BusinessStoreProof: Equatable, Codable, Sendable {
    let rowCount: Int64
    let rowsDigest: String
    let schemaDigest: String
    let tableCounts: [String: Int64]
    let moduleUserVersion: Int
}

enum BusinessStoreError: Error {
    case invalidContainerVersion, invalidStore, unsupportedSchema(String), proofMismatch, sourceChanged, destinationExists
}

final class CodexBusinessDatabase {
    let url: URL
    let driver: SQLiteDatabaseDriver
    private static let bundledSchemaSQL: String? = {
        guard let resource = Bundle.module.url(forResource: "codex-ledger-schema", withExtension: "sql") else { return nil }
        return try? String(contentsOf: resource, encoding: .utf8)
    }()
    private static let expectedSchemaEntries: [SchemaEntry]? = {
        guard let schema = bundledSchemaSQL else { return nil }
        return try? expectedContainerSchema(schema)
    }()
    init(url: URL) throws {
        self.url = url
        driver = SQLiteDatabaseDriver(url: url, busyTimeoutMilliseconds: 30_000, enableWAL: false, bypassBusinessRoutes: true)
        guard let schema = Self.bundledSchemaSQL, let expected = Self.expectedSchemaEntries else {
            throw BusinessStoreError.invalidContainerVersion
        }
        try driver.withConnection { db in
            // Read both physical version and catalog before the first DDL. A
            // foreign or future-version file must remain byte-for-byte intact.
            let physicalVersion = try Self.physicalUserVersion(db)
            let rootNames = Set(expected.map(\.name))
            let existing = try Self.containerSchema(db, canonicalNames: rootNames)
            let isNewContainer = physicalVersion == 0
            if isNewContainer {
                let hasAnyCatalogObject = try db.readRows("SELECT 1 FROM main.sqlite_master LIMIT 1") { $0.int(0) }.first != nil
                guard existing.isEmpty, !hasAnyCatalogObject else { throw BusinessStoreError.invalidContainerVersion }
                // Set this before any schema DDL. Incremental vacuum can reclaim
                // pages without rewriting hidden rowids in sealed namespaces.
                try db.execute("PRAGMA auto_vacuum=INCREMENTAL")
                let autoVacuum = try db.readRows("PRAGMA auto_vacuum") { $0.int(0) }.first ?? nil
                guard autoVacuum == 2 else {
                    throw BusinessStoreError.invalidContainerVersion
                }
                try db.transaction { tx in
                    try tx.execute(schema)
                    try tx.execute("PRAGMA user_version=1")
                }
                let created = try Self.containerSchema(db, canonicalNames: rootNames)
                try Self.validateContainerCatalog(created, db: db, expected: expected)
            } else {
                guard physicalVersion == 1 else {
                    throw BusinessStoreError.invalidContainerVersion
                }
                try Self.validateContainerCatalog(existing, db: db, expected: expected)
            }
            let metadataVersion = try db.readRows("SELECT value FROM main.tb_container_meta WHERE key='schema_version'") { $0.text(0) }.first ?? nil
            guard try Self.physicalUserVersion(db) == 1,
                  metadataVersion == "1" else {
                throw BusinessStoreError.invalidContainerVersion
            }
            let activation = try db.readRows("SELECT value FROM main.tb_container_meta WHERE key='activation_state'") { $0.text(0) }.first ?? nil
            guard activation == nil || activation == "importing" || activation == "ready" else {
                throw BusinessStoreError.invalidContainerVersion
            }
            if isNewContainer {
                let check = try db.readRows("PRAGMA quick_check") { $0.text(0) }.compactMap { $0 }
                guard check == ["ok"] else { throw BusinessStoreError.proofMismatch }
                try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            }
            try db.execute("PRAGMA foreign_keys=ON;")
        }
    }

    private struct SchemaEntry: Equatable {
        let type: String
        let name: String
        let table: String
        let sql: String
    }

    private static func physicalUserVersion(_ db: SQLiteDatabaseConnection) throws -> Int {
        let values = try db.readRows("PRAGMA main.user_version") { $0.int(0) }
        guard let value = values.first ?? nil else {
            throw BusinessStoreError.invalidContainerVersion
        }
        return value
    }

    private static func containerSchema(_ db: SQLiteDatabaseConnection, canonicalNames: Set<String>? = nil) throws -> [SchemaEntry] {
        try db.readRows("""
        SELECT type,name,tbl_name,sql FROM main.sqlite_master
        WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name
        """) { row in
            let rawSQL = row.text(3) ?? ""
            let name = row.text(1) ?? ""
            return SchemaEntry(
                type: row.text(0) ?? "",
                name: name,
                table: row.text(2) ?? "",
                // Only container-owned DDL is compared here. Module DDL is
                // verified by each import proof/reader, not by this catalog
                // ownership fence. Avoid retokenizing thousands of unrelated
                // module definitions on every container open.
                sql: canonicalNames.map { !$0.contains(name) } == true
                    ? "" : try SQLiteStoreNamespace.canonicalSQL(rawSQL)
            )
        }
    }

    private static func validateContainerCatalog(_ actual: [SchemaEntry], db: SQLiteDatabaseConnection, expected: [SchemaEntry]) throws {
        let requiredNames = Set(expected.map(\.name))
        let required = actual.filter { requiredNames.contains($0.name) }
        guard required == expected else { throw BusinessStoreError.invalidContainerVersion }

        let registered = try db.readRows("""
            SELECT store_id,module,source_identity,logical_path,namespace_prefix
            FROM main.tb_stores ORDER BY store_id
            """) { row -> String in
                let storeID = row.text(0) ?? ""
                let module = row.text(1) ?? ""
                let identity = row.text(2) ?? ""
                let logicalPath = row.text(3) ?? ""
                let prefix = row.text(4) ?? ""
                let expectedID = SHA256.hash(data: Data("tokenbar-store-v1\0\(module)\0\(identity)".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                guard storeID.count == 64, storeID.allSatisfy({ $0.isHexDigit }),
                      URL(fileURLWithPath: logicalPath).standardizedFileURL.path == logicalPath,
                      prefix == "s\(storeID)_",
                      expectedID == storeID else {
                    throw BusinessStoreError.invalidContainerVersion
                }
                return prefix
            }
        let registeredCount = try db.readRows("SELECT count(*) FROM main.tb_stores") { $0.int(0) }.first ?? 0
        guard registered.count == registeredCount, Set(registered).count == registered.count else {
            throw BusinessStoreError.invalidContainerVersion
        }
        let prefixes = Set(registered)
        let extra = actual.filter { !requiredNames.contains($0.name) }
        guard extra.allSatisfy({ object in
            // Registered prefixes are exactly s + 64 hex digits + underscore.
            // Checking the fixed prefix avoids objects × stores comparisons.
            let prefix = String(object.name.prefix(66))
            return prefixes.contains(prefix) && object.table.hasPrefix(prefix)
        }) else { throw BusinessStoreError.invalidContainerVersion }
    }

    private static func expectedContainerSchema(_ sql: String) throws -> [SchemaEntry] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw BusinessStoreError.invalidContainerVersion }
        defer { sqlite3_close_v2(database) }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let execution = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard execution == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK else {
            throw BusinessStoreError.invalidContainerVersion
        }
        var statement: OpaquePointer?
        let query = "SELECT type,name,tbl_name,sql FROM main.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BusinessStoreError.invalidContainerVersion
        }
        defer { sqlite3_finalize(statement) }
        var result: [SchemaEntry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw BusinessStoreError.invalidContainerVersion }
            func string(_ column: Int32) -> String {
                guard let pointer = sqlite3_column_text(statement, column) else { return "" }
                let count = Int(sqlite3_column_bytes(statement, column))
                return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
            }
            result.append(.init(
                type: string(0),
                name: string(1),
                table: string(2),
                sql: try SQLiteStoreNamespace.canonicalSQL(string(3))
            ))
        }
    }

    /// Path, device/inode, size and timestamp identity for the main database
    /// and WAL data file. The shm file contains mutable lock/read-mark bytes,
    /// so opening a read-only snapshot must not count its changes as usage
    /// data changes. Content is never read or retained here.
    private static func sourceFileSignature(_ url: URL) throws -> String {
        var parts: [String] = []
        for suffix in ["", "-wal"] {
            let path = url.path + suffix
            var status = Darwin.stat()
            if lstat(path, &status) != 0 {
                if errno == ENOENT && suffix != "" { parts.append("\(suffix):missing"); continue }
                throw BusinessStoreError.invalidStore
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else { throw BusinessStoreError.invalidStore }
            parts.append([
                suffix,
                String(status.st_dev), String(status.st_ino), String(status.st_size),
                String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec),
                String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec)
            ].joined(separator: ":"))
        }
        return parts.joined(separator: "|")
    }
    func register(_ store: BusinessSQLiteStore, state: String = "ready") throws {
        guard store.containerURL == url.standardizedFileURL, ["ready","staging","sealed"].contains(state) else { throw BusinessStoreError.invalidStore }
        try driver.execute("""
        INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,state)
        VALUES (?,?,?,?,?,?) ON CONFLICT(store_id) DO NOTHING;
        """, bindings: [.text(store.id),.text(store.module),.text(store.sourceIdentity),.text(store.logicalURL.path),.text(store.prefix),.text(state)])
        let matching = try driver.readRows("SELECT logical_path,module,source_identity FROM tb_stores WHERE store_id=?", bindings:[.text(store.id)]) {
            $0.text(0) == store.logicalURL.path && $0.text(1) == store.module && $0.text(2) == store.sourceIdentity
        }.first ?? false
        guard matching else { throw BusinessStoreError.invalidStore }
        BusinessSQLiteRoutes.didRegister(store)
    }

    /// Snapshot is supplied by the migration coordinator via SQLite backup, not
    /// by copying a live main file without its WAL. Only this namespace changes.
    /// The original snapshot, schema, all typed row values and old integer IDs
    /// remain available for proof/rollback. Re-importing the same image is a no-op.
    @discardableResult func importSnapshot(_ source: URL, into store: BusinessSQLiteStore, backupURL: URL, now: Date = Date(), replaceExisting: Bool = false) throws -> BusinessStoreProof {
        guard store.containerURL == url.standardizedFileURL else { throw BusinessStoreError.invalidStore }
        let sourceSignature = try Self.sourceFileSignature(source)
        let sourceDB = SQLiteDatabaseDriver(url: source, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let proof = try sourceDB.withConnection { db in
            try db.readTransaction { try Self.proof($0) }
        }
        guard try Self.sourceFileSignature(source) == sourceSignature else { throw BusinessStoreError.sourceChanged }
        let sourceDigest = proof.schemaDigest + ":" + proof.rowsDigest + ":v" + String(proof.moduleUserVersion)
        let existing = try driver.readRows("SELECT rows_digest FROM tb_store_imports WHERE store_id=? AND source_digest=?",bindings:[.text(store.id),.text(sourceDigest)]) { $0.text(0) }.first ?? nil
        if let existing, !replaceExisting {
            guard existing == proof.rowsDigest else { throw BusinessStoreError.proofMismatch }
            guard try Self.sourceFileSignature(source) == sourceSignature else { throw BusinessStoreError.sourceChanged }
            BusinessSQLiteRoutes.didRegister(store)
            return proof
        }
        try driver.withConnection { db in
            let uri = source.standardizedFileURL.absoluteString + "?mode=ro"
            try db.execute("ATTACH DATABASE ? AS tb_import_source", bindings: [.text(uri)])
            defer { try? db.execute("DETACH DATABASE tb_import_source") }
            try db.execute("PRAGMA foreign_keys=OFF")
            defer { try? db.execute("PRAGMA foreign_keys=ON") }
            try db.transaction { tx in
                guard try Self.sourceFileSignature(source) == sourceSignature else { throw BusinessStoreError.sourceChanged }
                try tx.execute("""
                    INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,state)
                    VALUES (?,?,?,?,?,'ready') ON CONFLICT(store_id) DO NOTHING
                    """, bindings: [.text(store.id), .text(store.module), .text(store.sourceIdentity), .text(store.logicalURL.path), .text(store.prefix)])
                let registered = try tx.readRows("SELECT logical_path,module,source_identity,namespace_prefix FROM tb_stores WHERE store_id=?", bindings: [.text(store.id)]) {
                    $0.text(0) == store.logicalURL.path && $0.text(1) == store.module
                        && $0.text(2) == store.sourceIdentity && $0.text(3) == store.prefix
                }.first ?? false
                guard registered else { throw BusinessStoreError.invalidStore }
                let attachedProof = try Self.proof(tx, namespace: nil, schemaName: "tb_import_source")
                guard attachedProof == proof else { throw BusinessStoreError.sourceChanged }
                let names = try tx.readRows("SELECT name,type,sql FROM tb_import_source.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END,name") { ($0.text(0) ?? "",$0.text(1) ?? "",$0.text(2)) }
                guard names.allSatisfy({ ["table","index","view","trigger"].contains($0.1) }) else { throw BusinessStoreError.unsupportedSchema("object type") }
                var namespace = SQLiteStoreNamespace(prefix: store.prefix, objectNames: Set(names.map { $0.0.lowercased() }))
                // Modules have disjoint object and column identifiers. Fail
                // closed rather than rewriting a data column as a table name.
                for (name, type, _) in names where type == "table" {
                    let columns = try tx.readRows("PRAGMA tb_import_source.table_xinfo(\(SQLiteStoreNamespace.quote(name)))") { $0.text(1) ?? "" }
                    guard Set(columns.map { $0.lowercased() }).isDisjoint(with: namespace.objectNames) else { throw BusinessStoreError.unsupportedSchema("object/column name collision") }
                }
                let old = try tx.readRows("SELECT name,type FROM main.sqlite_master WHERE substr(name,1,?)=? ORDER BY CASE type WHEN 'view' THEN 0 WHEN 'trigger' THEN 1 WHEN 'index' THEN 2 ELSE 3 END", bindings:[.int(store.prefix.count),.text(store.prefix)]) { ($0.text(0) ?? "",$0.text(1) ?? "") }
                for (name,type) in old { try tx.execute("DROP \(type.uppercased()) IF EXISTS \(SQLiteStoreNamespace.quote(name))") }
                try tx.execute("DELETE FROM tb_store_objects WHERE store_id=?",bindings:[.text(store.id)])
                let hasStoreSeals = try tx.readRows("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='tb_store_seals'") { $0.int(0) }.first == 1
                if hasStoreSeals { try tx.execute("DELETE FROM tb_store_seals WHERE store_id=?", bindings: [.text(store.id)]) }
                for (name,type,sql) in names where type == "table" {
                    guard let sql, !sql.uppercased().contains("CREATE VIRTUAL TABLE") else { throw BusinessStoreError.unsupportedSchema(name) }
                    let columnInfo = try tx.readRows("PRAGMA tb_import_source.table_xinfo(\(SQLiteStoreNamespace.quote(name)))") {
                        ($0.text(1) ?? "", $0.int(6) ?? 0)
                    }
                    let rowIDAlias = try Self.rowIDAlias(sql: sql, columns: columnInfo.map(\.0))
                    try tx.execute(namespace.bind(sql))
                    let columns = columnInfo.filter { $0.1 == 0 }.map { SQLiteStoreNamespace.quote($0.0) }
                    let copyColumns = (rowIDAlias.map { [SQLiteStoreNamespace.quote($0)] } ?? []) + columns
                    let projection = copyColumns.joined(separator: ",")
                    try tx.execute("INSERT INTO main.\(SQLiteStoreNamespace.quote(store.prefix + name))(\(projection)) SELECT \(projection) FROM tb_import_source.\(SQLiteStoreNamespace.quote(name))")
                }
                let hasSequences = try tx.readRows("SELECT 1 FROM tb_import_source.sqlite_master WHERE name='sqlite_sequence'") { $0.int(0) }.first == 1
                let targetHasSequences = try tx.readRows("SELECT 1 FROM main.sqlite_master WHERE name='sqlite_sequence'") { $0.int(0) }.first == 1
                if targetHasSequences {
                    // Empty AUTOINCREMENT tables can acquire a sequence row
                    // during INSERT ... SELECT. Remove all rows for this
                    // namespace before copying the source's exact sequence
                    // state, leaving every other module untouched.
                    try tx.execute("DELETE FROM main.sqlite_sequence WHERE substr(name,1,?)=?",
                        bindings: [.int(store.prefix.count), .text(store.prefix)])
                }
                if hasSequences {
                    let sequences = try tx.readRows("SELECT name,seq FROM tb_import_source.sqlite_sequence") { ($0.text(0) ?? "",$0.int64(1) ?? 0) }
                    for (name,seq) in sequences {
                        let physical = store.prefix + name
                        try tx.execute("INSERT INTO main.sqlite_sequence(name,seq) VALUES (?,?)",bindings:[.text(physical),.int64(seq)])
                    }
                }
                for (_,type,sql) in names where type != "table" { if let sql { try tx.execute(namespace.bind(sql)) } }
                for (name,type,sql) in names {
                    try tx.execute("INSERT INTO tb_store_objects VALUES (?,?,?,?)",bindings:[.text(store.id),.text(name),.text(type),sql.map(SQLiteBinding.text) ?? .null])
                }
                try tx.execute("UPDATE tb_stores SET user_version=?,revision=revision+1 WHERE store_id=?",bindings:[.int(proof.moduleUserVersion),.text(store.id)])
                // Compare through the exact same logical adapter the old engine
                // will use; originals are not re-parsed or recomputed.
                let actual = try Self.proof(tx, namespace: namespace)
                guard actual == proof else { throw BusinessStoreError.proofMismatch }
                let check = try tx.readRows("PRAGMA foreign_key_check") { ($0.text(0) ?? "", $0.text(2) ?? "") }
                guard !check.contains(where: { $0.0.hasPrefix(store.prefix) || $0.1.hasPrefix(store.prefix) }) else { throw BusinessStoreError.proofMismatch }
                guard try Self.sourceFileSignature(source) == sourceSignature else { throw BusinessStoreError.sourceChanged }
                try tx.execute("INSERT OR REPLACE INTO tb_store_imports VALUES (?,?,?,?,?,?,?)",bindings:[.text(store.id),.text(sourceDigest),.text(proof.schemaDigest),.int64(proof.rowCount),.text(proof.rowsDigest),.text(backupURL.path),.double(now.timeIntervalSince1970)])
            }
        }
        BusinessSQLiteRoutes.didRegister(store)
        return proof
    }

    static func proof(_ db: SQLiteDatabaseConnection, namespace: SQLiteStoreNamespace? = nil) throws -> BusinessStoreProof {
        try proof(db, namespace: namespace, schemaName: "main")
    }

    private static func proof(_ db: SQLiteDatabaseConnection, namespace: SQLiteStoreNamespace?, schemaName: String) throws -> BusinessStoreProof {
        guard schemaName == "main" || schemaName == "tb_import_source" else { throw BusinessStoreError.invalidStore }
        let schemaPrefix = SQLiteStoreNamespace.quote(schemaName)
        let prefix = namespace?.prefix ?? ""
        if namespace == nil {
            let check = try db.readRows("PRAGMA \(schemaPrefix).quick_check") { $0.text(0) }.compactMap { $0 }
            guard check == ["ok"] else { throw BusinessStoreError.proofMismatch }
        }

        let physicalObjects: [(String, String, String, String)]
        if namespace == nil {
            physicalObjects = try db.readRows("""
                SELECT type,name,tbl_name,sql FROM \(schemaPrefix).sqlite_master
                WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name
                """) { ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "", $0.text(3) ?? "") }
        } else {
            physicalObjects = try db.readRows("""
                SELECT type,name,tbl_name,sql FROM \(schemaPrefix).sqlite_master
                WHERE name NOT LIKE 'sqlite_%'
                  AND (substr(name,1,?)=? OR substr(tbl_name,1,?)=?) ORDER BY type,name
                """, bindings: [.int(prefix.count), .text(prefix), .int(prefix.count), .text(prefix)]) {
                    ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "", $0.text(3) ?? "")
                }
        }
        let objectNames: Set<String>
        if namespace != nil {
            objectNames = Set(physicalObjects.compactMap { object in
                guard object.1.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
                return String(object.1.dropFirst(prefix.count)).lowercased()
            })
        } else {
            objectNames = Set(physicalObjects.map { $0.1.lowercased() })
        }
        let logicalNamespace = SQLiteStoreNamespace(prefix: prefix, objectNames: objectNames)
        var objects: [(String, String, String, String)] = []
        for (type, physicalName, physicalTable, rawSQL) in physicalObjects {
            let name: String
            let table: String
            if prefix.isEmpty {
                name = physicalName
                table = physicalTable
            } else {
                guard let logical = logicalNamespace.logicalName(forPhysical: physicalName) else { throw BusinessStoreError.proofMismatch }
                name = logical
                if physicalTable.lowercased().hasPrefix(prefix.lowercased()) {
                    table = String(physicalTable.dropFirst(prefix.count))
                } else {
                    table = physicalTable
                }
            }
            let logicalSQL: String
            if prefix.isEmpty {
                logicalSQL = rawSQL
            } else {
                logicalSQL = try logicalNamespace.unbind(rawSQL)
            }
            objects.append((type, name, table, logicalSQL))
        }
        objects.sort { ($0.0, $0.1.lowercased()) < ($1.0, $1.1.lowercased()) }

        let moduleUserVersion: Int
        if let namespace {
            moduleUserVersion = try db.readRows(
                "SELECT user_version FROM main.tb_stores WHERE namespace_prefix=?",
                bindings: [.text(namespace.prefix)]
            ) { $0.int(0) ?? 0 }.first ?? 0
        } else {
            moduleUserVersion = try db.readRows("PRAGMA \(schemaPrefix).user_version") { $0.int(0) ?? 0 }.first ?? 0
        }

        var rowsHash = SHA256(), schemaHash = SHA256()
        var counts: [String: Int64] = [:]
        var total: Int64 = 0
        Self.update(&schemaHash, fields: ["tokenbar-schema-proof-v1", "module-user-version", String(moduleUserVersion)])

        for (type, name, table, sql) in objects {
            Self.update(&schemaHash, fields: ["object", type.lowercased(), name.lowercased(), table.lowercased()])
            Self.update(&schemaHash, fields: [try SQLiteStoreNamespace.canonicalSQL(sql)])
        }

        for (type, name, _, sql) in objects where type == "table" {
            let physicalTable = prefix + name
            let quotedTable = SQLiteStoreNamespace.quote(physicalTable)
            let tableXInfo = try db.readRows("PRAGMA \(schemaPrefix).table_xinfo(\(quotedTable))") { row in
                (0..<row.columnCount).map { row.canonicalBytes($0) }
            }
            Self.update(&schemaHash, fields: ["table-xinfo", name.lowercased()])
            for fields in tableXInfo { Self.update(&schemaHash, binaryFields: fields) }

            let foreignKeys = try db.readRows("PRAGMA \(schemaPrefix).foreign_key_list(\(quotedTable))") { row -> [String] in
                let target = row.text(2) ?? ""
                let logicalTarget = prefix.isEmpty || !target.lowercased().hasPrefix(prefix.lowercased())
                    ? target : String(target.dropFirst(prefix.count))
                return [String(row.int(0) ?? 0), String(row.int(1) ?? 0), logicalTarget.lowercased(),
                    row.text(3) ?? "", row.text(4) ?? "", row.text(5) ?? "", row.text(6) ?? "", row.text(7) ?? ""]
            }
            Self.update(&schemaHash, fields: ["foreign-key-list", name.lowercased()])
            for fields in foreignKeys { Self.update(&schemaHash, fields: fields) }

            let indexes = try db.readRows("PRAGMA \(schemaPrefix).index_list(\(quotedTable))") { row in
                (row.text(1) ?? "", row.int(2) ?? 0, row.text(3) ?? "", row.int(4) ?? 0)
            }.map { index in
                (index.0, logicalNamespace.logicalName(forPhysical: index.0) ?? index.0,
                 index.1, index.2, index.3)
            }.sorted { $0.1.lowercased() < $1.1.lowercased() }
            Self.update(&schemaHash, fields: ["index-list", name.lowercased()])
            for (physicalIndex, logicalIndex, unique, origin, partial) in indexes {
                Self.update(&schemaHash, fields: [logicalIndex.lowercased(), String(unique), origin, String(partial)])
                let indexInfo = try db.readRows("PRAGMA \(schemaPrefix).index_xinfo(\(SQLiteStoreNamespace.quote(physicalIndex)))") { row in
                    (0..<row.columnCount).map { row.canonicalBytes($0) }
                }
                for fields in indexInfo { Self.update(&schemaHash, binaryFields: fields) }
            }

            let columns = try db.readRows("PRAGMA \(schemaPrefix).table_xinfo(\(quotedTable))") {
                ($0.text(1) ?? "", $0.int(6) ?? 0)
            }.filter { $0.1 != 1 }.map { $0.0 }
            guard !columns.isEmpty else { throw BusinessStoreError.unsupportedSchema(name) }
            let rowIDAlias = try Self.rowIDAlias(sql: sql, columns: columns)
            let selectedColumns = (rowIDAlias.map { [SQLiteStoreNamespace.quote($0)] } ?? []) + columns.map(SQLiteStoreNamespace.quote)
            let projection = selectedColumns.joined(separator: ",")
            let orderColumns = (rowIDAlias.map { [SQLiteStoreNamespace.quote($0)] } ?? []) + columns.map(SQLiteStoreNamespace.quote)
            let order = orderColumns.map { "\($0) COLLATE BINARY" }.joined(separator: ",")
            var count: Int64 = 0
            Self.update(&rowsHash, fields: ["table", name.lowercased()])
            try db.forEachRow("SELECT \(projection) FROM \(schemaPrefix).\(quotedTable) ORDER BY \(order)") { row in
                Self.update(&rowsHash, binaryFields: (0..<row.columnCount).map { row.canonicalBytes($0) })
                count += 1
            }
            counts[name] = count
            total += count
        }

        let hasSequences = try db.readRows("SELECT 1 FROM \(schemaPrefix).sqlite_master WHERE name='sqlite_sequence'") { $0.int(0) }.first == 1
        // Section presence must not depend on another partition creating the
        // physical sqlite_sequence table in this shared container.
        Self.update(&rowsHash, fields: ["sqlite-sequence"])
        if hasSequences {
            let sequenceRows = try db.readRows("SELECT name,seq FROM \(schemaPrefix).sqlite_sequence ORDER BY name") { ($0.text(0) ?? "", $0.int64(1) ?? 0) }
            let ownSequences = sequenceRows.compactMap { physicalName, sequence -> (String, Int64)? in
                guard prefix.isEmpty || physicalName.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
                return (prefix.isEmpty ? physicalName : String(physicalName.dropFirst(prefix.count)), sequence)
            }
            for (name, sequence) in ownSequences {
                Self.update(&rowsHash, fields: [name.lowercased(), String(sequence)])
            }
            if !ownSequences.isEmpty {
                counts["sqlite_sequence"] = Int64(ownSequences.count)
                total += Int64(ownSequences.count)
            }
        }
        return .init(
            rowCount: total,
            rowsDigest: rowsHash.finalize().map { String(format: "%02x", $0) }.joined(),
            schemaDigest: schemaHash.finalize().map { String(format: "%02x", $0) }.joined(),
            tableCounts: counts,
            moduleUserVersion: moduleUserVersion
        )
    }

    private static func update(_ hash: inout SHA256, fields: [String]) {
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
    }

    private static func update(_ hash: inout SHA256, binaryFields: [Data]) {
        for field in binaryFields {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: field)
        }
    }

    /// Return an unshadowed SQLite rowid alias for ordinary rowid tables.
    /// WITHOUT ROWID tables have no hidden key to preserve. If a rowid table
    /// shadows every alias, callers fail closed rather than silently
    /// renumbering deleted-key gaps during import/export.
    private static func rowIDAlias(sql: String, columns: [String]) throws -> String? {
        let tokens = try SQLiteStoreNamespace.tokens(sql).filter { $0.kind != .trivia }
        if tokens.indices.contains(where: { index in
            index + 1 < tokens.count
                && tokens[index].kind == .identifier
                && tokens[index].raw == tokens[index].value
                && tokens[index].value.uppercased() == "WITHOUT"
                && tokens[index + 1].kind == .identifier
                && tokens[index + 1].raw == tokens[index + 1].value
                && tokens[index + 1].value.uppercased() == "ROWID"
        }) { return nil }
        let shadowed = Set(columns.map { $0.lowercased() })
        guard let alias = ["rowid", "_rowid_", "oid"].first(where: { !shadowed.contains($0) }) else {
            throw BusinessStoreError.unsupportedSchema("rowid is shadowed")
        }
        return alias
    }
}

extension CodexBusinessDatabase {
    static func export(_ store: BusinessSQLiteStore, to targetURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: targetURL.path) else { throw BusinessStoreError.destinationExists }
        let target = SQLiteDatabaseDriver(url: targetURL, bypassBusinessRoutes: true)
        do {
            try target.withConnection { try export(store, to: $0) }
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw error
        }
    }
    static func export(_ store: BusinessSQLiteStore, to target: SQLiteDatabaseConnection) throws {
        let source = SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let expected = try source.withConnection {
            try proof($0, namespace: SQLiteStoreNamespace(prefix: store.prefix, objectNames: []))
        }
        try target.execute("ATTACH DATABASE ? AS tb_export_source",bindings:[.text(store.containerURL.absoluteString + "?mode=ro")])
        defer { try? target.execute("DETACH DATABASE tb_export_source") }
        try target.execute("PRAGMA foreign_keys=OFF")
        defer { try? target.execute("PRAGMA foreign_keys=ON") }
        try target.transaction { tx in
            let previous = try tx.readRows("SELECT name,type FROM main.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'view' THEN 0 WHEN 'trigger' THEN 1 WHEN 'index' THEN 2 ELSE 3 END,name") { ($0.text(0) ?? "",$0.text(1) ?? "") }
            for (name,type) in previous { try tx.execute("DROP \(type.uppercased()) IF EXISTS \(SQLiteStoreNamespace.quote(name))") }
            let objects = try tx.readRows("SELECT name,type,sql FROM tb_export_source.sqlite_master WHERE substr(name,1,?)=? ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END,name", bindings:[.int(store.prefix.count),.text(store.prefix)]) { ($0.text(0) ?? "",$0.text(1) ?? "",$0.text(2)) }
            let namespace = SQLiteStoreNamespace(
                prefix: store.prefix,
                objectNames: Set(objects.map { String($0.0.dropFirst(store.prefix.count)).lowercased() })
            )
            for (physical,type,sql) in objects where type == "table" {
                guard let sql else { throw BusinessStoreError.invalidStore }
                let logicalSQL = try namespace.unbind(sql)
                try tx.execute(logicalSQL)
                let logical = String(physical.dropFirst(store.prefix.count))
                let columnInfo = try tx.readRows("PRAGMA tb_export_source.table_xinfo(\(SQLiteStoreNamespace.quote(physical)))") {
                    ($0.text(1) ?? "", $0.int(6) ?? 0)
                }
                let rowIDAlias = try Self.rowIDAlias(sql: logicalSQL, columns: columnInfo.map(\.0))
                let columns = columnInfo.filter { $0.1 == 0 }.map { SQLiteStoreNamespace.quote($0.0) }
                let copyColumns = (rowIDAlias.map { [SQLiteStoreNamespace.quote($0)] } ?? []) + columns
                let projection = copyColumns.joined(separator: ",")
                try tx.execute("INSERT INTO main.\(SQLiteStoreNamespace.quote(logical))(\(projection)) SELECT \(projection) FROM tb_export_source.\(SQLiteStoreNamespace.quote(physical))")
            }
            for (_,type,sql) in objects where type != "table" { if let sql { try tx.execute(namespace.unbind(sql)) } }
            let hasSequences = try tx.readRows("SELECT 1 FROM tb_export_source.sqlite_master WHERE name='sqlite_sequence'") { $0.int(0) }.first == 1
            let targetHasSequences = try tx.readRows("SELECT 1 FROM main.sqlite_master WHERE name='sqlite_sequence'") { $0.int(0) }.first == 1
            if targetHasSequences { try tx.execute("DELETE FROM main.sqlite_sequence") }
            if hasSequences {
                let rows = try tx.readRows("SELECT name,seq FROM tb_export_source.sqlite_sequence WHERE substr(name,1,?)=?",bindings:[.int(store.prefix.count),.text(store.prefix)]) { ($0.text(0) ?? "",$0.int64(1) ?? 0) }
                for (physical,seq) in rows {
                    let logical = String(physical.dropFirst(store.prefix.count))
                    try tx.execute("INSERT INTO main.sqlite_sequence(name,seq) VALUES (?,?)",bindings:[.text(logical),.int64(seq)])
                }
            }
            let version = try tx.readRows("SELECT user_version FROM tb_export_source.tb_stores WHERE store_id=?",bindings:[.text(store.id)]) { $0.int(0) ?? 0 }.first ?? 0
            try tx.execute("PRAGMA user_version=\(version)")
            guard try proof(tx) == expected else { throw BusinessStoreError.proofMismatch }
        }
    }
}
