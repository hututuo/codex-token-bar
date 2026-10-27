import Foundation

/// File-shaped compatibility boundary for legacy jobs. A logical stage has its
/// own immutable seal; a write elsewhere in A does not invalidate that job.
/// Never substitute the entire A file's length/mtime for a per-source artifact.
enum BusinessStoreFiles {
    static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        BusinessSQLiteRoutes.exists(url, fileManager: fileManager)
    }
    static func registerInActiveContainer(_ store: BusinessSQLiteStore) throws {
        guard try BusinessSQLiteRoutes.validateActiveContainer(store.containerURL) else { throw BusinessStoreError.invalidStore }
        let raw = SQLiteDatabaseDriver(url: store.containerURL, createsFileIfMissing: false,
            busyTimeoutMilliseconds: 30_000, bypassBusinessRoutes: true)
        try raw.transaction { tx in
            guard try tx.readRows("PRAGMA user_version", map: { $0.int(0) }).first == 1,
                  try tx.readRows("SELECT value FROM tb_container_meta WHERE key='schema_version'", map: { $0.text(0) }).first == "1" else { throw BusinessStoreError.invalidContainerVersion }
            try tx.execute("INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,state) VALUES(?,?,?,?,?,?) ON CONFLICT(store_id) DO NOTHING",
                bindings: [.text(store.id), .text(store.module), .text(store.sourceIdentity), .text(store.logicalURL.path), .text(store.prefix), .text(store.module == "exact.swift.stage" ? "staging" : "ready")])
            let valid = try tx.readRows("SELECT module,source_identity,logical_path,namespace_prefix FROM tb_stores WHERE store_id=?", bindings: [.text(store.id)]) {
                $0.text(0) == store.module && $0.text(1) == store.sourceIdentity && $0.text(2) == store.logicalURL.path && $0.text(3) == store.prefix
            }.first == true
            guard valid else { throw BusinessStoreError.invalidStore }
        }
        BusinessSQLiteRoutes.didRegister(store)
    }
    static func footprint(_ connection: SQLiteDatabaseConnection) throws -> UInt64 {
        var size: UInt64 = 0
        let tables = try connection.readRows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { $0.text(0) ?? "" }
        for table in tables {
            size += UInt64(table.utf8.count + 1)
            try connection.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(table))") { row in
                for col in 0..<row.columnCount { size += UInt64(row.canonicalBytes(col).count) }
            }
        }
        return size
    }
    static func byteCount(at url: URL, connection: SQLiteDatabaseConnection? = nil,
                          fileManager: FileManager = .default) throws -> UInt64 {
        guard let store = BusinessSQLiteRoutes.store(for: url) else {
            return (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        }
        let container = SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, bypassBusinessRoutes: true)
        if let sealed = try container.readRows("SELECT byte_count FROM tb_store_seals WHERE store_id=?", bindings: [.text(store.id)], map: { $0.int64(0) }).first ?? nil {
            guard sealed >= 0 else { throw BusinessStoreError.proofMismatch }
            return UInt64(sealed)
        }
        if let connection { return try footprint(connection) }
        return try SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false).withConnection { try footprint($0) }
    }
    /// Parsing uses SQLite TEMP btrees (bounded cache, automatic spill) so
    /// scanning a large transcript does not hold A's sole write lock. Only the
    /// complete, verified numeric job is copied into durable MAIN tables.
    static func materializeTemporaryStage(_ connection: SQLiteDatabaseConnection) throws {
        guard let binding = connection.businessBinding, binding.store.module == "exact.swift.stage" else { return }
        let prefix = binding.store.prefix
        connection.businessBinding = nil
        defer { connection.businessBinding = binding }
        let tables = try connection.readRows("SELECT name,sql FROM temp.sqlite_master WHERE type='table' AND substr(name,1,?)=? ORDER BY name",
            bindings: [.int(prefix.count), .text(prefix)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        guard Set(tables.map { String($0.0.dropFirst(prefix.count)) }) == ["manifest","fingerprints","events","chunks"] else { throw BusinessStoreError.proofMismatch }
        try connection.transaction { tx in
            for (_,sql) in tables { try tx.execute(sql) }
            for (name,_) in tables {
                let quoted = SQLiteStoreNamespace.quote(name)
                try tx.execute("INSERT INTO main.\(quoted) SELECT * FROM temp.\(quoted)")
            }
        }
        for (name,_) in tables { try connection.execute("DROP TABLE temp.\(SQLiteStoreNamespace.quote(name))") }
        binding.namespace.temporaryObjectNames.subtract(["manifest","fingerprints","events","chunks"])
    }
    static func isUnmaterializedStage(_ url: URL) throws -> Bool {
        guard let store = BusinessSQLiteRoutes.store(for: url), store.module == "exact.swift.stage" else { return false }
        let db = SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        return try db.readRows("""
            SELECT 1 FROM tb_stores WHERE store_id=? AND state='staging'
            AND NOT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND substr(name,1,?)=?)
            """, bindings: [.text(store.id), .int(store.prefix.count), .text(store.prefix)], map: { $0.int(0) }).first == 1
    }
    static func seal(at url: URL, connection: SQLiteDatabaseConnection) throws {
        guard let binding = connection.businessBinding, binding.store.module == "exact.swift.stage" else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.synchronize()
            return
        }
        // Snapshot this job once. Later readers only consult its seal and
        // source witnesses, rather than scanning its rows at every refresh.
        let size = try footprint(connection)
        let namespace = binding.namespace
        connection.businessBinding = nil
        defer { connection.businessBinding = binding }
        try connection.transaction { tx in
            let proof = try CodexBusinessDatabase.proof(tx, namespace: namespace)
            try tx.execute("INSERT OR REPLACE INTO tb_store_seals VALUES(?,?,?,?,?)", bindings: [.text(binding.store.id), .int64(Int64(size)), .int64(proof.rowCount), .text(proof.rowsDigest), .double(Date().timeIntervalSince1970)])
            try tx.execute("UPDATE tb_stores SET state='sealed',revision=revision+1 WHERE store_id=?", bindings: [.text(binding.store.id)])
        }
        try connection.execute("PRAGMA synchronous=FULL")
    }
    static func observation(at url: URL) throws -> SourceFileObservation? {
        guard let store = BusinessSQLiteRoutes.store(for: url), store.module == "exact.swift.stage" else { return nil }
        let db = SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        guard let result = try db.readRows("SELECT byte_count,rows_digest,sealed_at FROM tb_store_seals WHERE store_id=?", bindings: [.text(store.id)], map: { row -> SourceFileObservation? in
            guard let size = row.int64(0), size >= 0, let digest = row.text(1), let date = row.double(2) else { return nil }
            return .init(indexedLogicalSize: UInt64(size), modifiedAt: date, physicalStamp: "sqlite-job:\(store.id):\(digest)")
        }).first ?? nil else { throw BusinessStoreError.proofMismatch }
        return result
    }
    static func isRetiredLegacyStage(_ store: BusinessSQLiteStore) throws -> Bool {
        guard store.module == "exact.swift.stage" else { return false }
        return try SQLiteDatabaseDriver(url: store.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
            .readRows("SELECT 1 FROM tb_legacy_inputs WHERE logical_path=? AND module='exact.swift.stage' AND retired=1 LIMIT 1",
                bindings: [.text(store.logicalURL.path)], map: { $0.int(0) }).first == 1
    }
    static func stageURLs(in directory: URL) -> [URL] {
        BusinessSQLiteRoutes.allStores(in: directory).filter { $0.module == "exact.swift.stage" && $0.logicalURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && BusinessSQLiteRoutes.exists($0.logicalURL) }.map(\.logicalURL)
    }
    static func quarantine(_ url: URL, into directory: URL) throws -> Bool {
        guard let store = BusinessSQLiteRoutes.store(for: url) else { return false }
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        let db = SQLiteDatabaseDriver(url: store.containerURL, bypassBusinessRoutes: true)
        try db.execute("UPDATE tb_stores SET logical_path=? WHERE store_id=? AND logical_path=?", bindings: [.text(destination.path), .text(store.id), .text(url.path)])
        try BusinessSQLiteRoutes.rename(store, to: destination)
        return true
    }
    static func removeCompletedStage(_ url: URL) throws -> Bool {
        guard let store = BusinessSQLiteRoutes.store(for: url), store.module == "exact.swift.stage" else { return false }
        let db = SQLiteDatabaseDriver(url: store.containerURL, bypassBusinessRoutes: true)
        try db.transaction { tx in
            let objects = try tx.readRows("SELECT name,type FROM sqlite_master WHERE substr(name,1,?)=? ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 ELSE 3 END", bindings: [.int(store.prefix.count), .text(store.prefix)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
            for (name,type) in objects { try tx.execute("DROP \(type.uppercased()) IF EXISTS \(SQLiteStoreNamespace.quote(name))") }
            try tx.execute("UPDATE tb_legacy_inputs SET retired=1 WHERE store_id=?", bindings: [.text(store.id)])
            try tx.execute("DELETE FROM tb_store_seals WHERE store_id=?", bindings: [.text(store.id)])
            try tx.execute("DELETE FROM tb_store_objects WHERE store_id=?", bindings: [.text(store.id)])
            try tx.execute("DELETE FROM tb_store_imports WHERE store_id=?", bindings: [.text(store.id)])
            try tx.execute("DELETE FROM tb_stores WHERE store_id=?", bindings: [.text(store.id)])
        }
        BusinessSQLiteRoutes.forget(store)
        return true
    }
}
