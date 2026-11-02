import CryptoKit
import Foundation
import SQLite3

/// One durable pool in A. Jobs are rows, never new stores or MAIN tables.
/// Parsing happens in private SQLite work areas; only verified numeric rows
/// enter this pool. The Exact publisher remains the accounting authority.
final class ExactStagePool: @unchecked Sendable {
    struct Job: Sendable {
        let id: String
        let owner: String
        let source: URL
        let base: String
        let contract: String
        let url: URL
    }
    struct Seal {
        let digest: String
        let bytes: UInt64
        let rows: Int64
        let timestamp: Double
    }
    enum Failure: LocalizedError {
        case invalid, unsupported, unavailable, unsealed, alreadyConsumed
        var errorDescription: String? {
            switch self {
            case .unsupported: "补全暂存池格式不可识别，已保留原账和任务，暂停补全"
            case .unavailable: "补全暂存池暂不可用，已保留上一代统计"
            case .unsealed: "补全任务尚未封存，不能作为正式账读取"
            case .alreadyConsumed: "补全任务已在另一发布代消费，已停止重复写入"
            case .invalid: "补全暂存证明不匹配，已保留原账和任务"
            }
        }
    }

    private final class Handle {
        let raw: OpaquePointer
        let db: SQLiteDatabaseConnection
        init(_ url: URL) throws {
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close_v2(pointer) }
                throw Failure.unavailable
            }
            let connection = SQLiteDatabaseConnection(database: pointer, path: url.path)
            sqlite3_extended_result_codes(pointer, 1)
            sqlite3_busy_timeout(pointer, 30_000)
            do { try connection.execute("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL") }
            catch { sqlite3_close_v2(pointer); throw error }
            raw = pointer; db = connection
        }
        deinit { sqlite3_close_v2(raw) }
    }
    private final class WeakPool { weak var value: ExactStagePool?; init(_ value: ExactStagePool) { self.value = value } }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var pools: [URL: WeakPool] = [:]
    }
    private static let registry = Registry()
    /// Call before entering A's publication transaction. Creating a pool (and
    /// its backup) from inside another connection's writer would deadlock.
    static func existingOrNeededForLegacy(for target: BusinessSQLiteStore) throws -> ExactStagePool? {
        let db = SQLiteDatabaseDriver(url: target.containerURL, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let sourcePrefix = "staging/" + target.logicalURL.lastPathComponent + "/"
        let needed = try db.readRows("SELECT 1 FROM tb_stores WHERE module LIKE 'exact.swift.pool%' OR (module='exact.swift.stage' AND instr(source_identity,?)=1) LIMIT 1",
            bindings: [.text(sourcePrefix)], map: { $0.int(0) }).first == 1
        return needed ? try shared(for: target) : nil
    }
    static func shared(for target: BusinessSQLiteStore) throws -> ExactStagePool {
        try BusinessSQLiteRoutes.requireAccess(to: target, readOnly: false)
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.pools = registry.pools.filter { $0.value.value != nil }
        if let existing = registry.pools[target.containerURL]?.value {
            guard try BusinessSQLiteRoutes.validateActiveContainer(target.containerURL) else { throw Failure.unavailable }
            if try fileIdentity(target.containerURL) == existing.openedIdentity { return existing }
        }
        let pool = try ExactStagePool(target: target)
        registry.pools[target.containerURL] = WeakPool(pool)
        return pool
    }

    let store: BusinessSQLiteStore
    private let openedIdentity: String
    private let handle: Handle
    private let lock = NSLock()
    private static let names = ["operations", "jobs", "event_rows", "fingerprints", "chunks", "publication_receipts"]
    private static let payloadTables = ["events": "event_rows", "fingerprints": "fingerprints", "chunks": "chunks"]

    private init(target: BusinessSQLiteStore) throws {
        guard target.module == "exact.swift", try BusinessSQLiteRoutes.validateActiveContainer(target.containerURL) else {
            throw Failure.invalid
        }
        store = BusinessSQLiteStore(containerURL: target.containerURL,
            logicalURL: target.containerURL.deletingLastPathComponent().appendingPathComponent(".exact-stage-pool-v1"),
            module: "exact.swift.pool", sourceIdentity: "exact-stage-pool-v1")
        openedIdentity = try Self.fileIdentity(target.containerURL)
        handle = try Handle(target.containerURL)
        guard try Self.fileIdentity(target.containerURL) == openedIdentity else { throw Failure.unavailable }
        let found = try handle.db.readRows("SELECT user_version,module,source_identity,logical_path,namespace_prefix,state FROM tb_stores WHERE store_id=?",
            bindings: [.text(store.id)]) { ($0.int(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4), $0.text(5)) }.first
        if let found {
            guard found.0 == 1 else { throw Failure.unsupported }
            guard found.1 == store.module, found.2 == store.sourceIdentity,
                  found.3 == store.logicalURL.path, found.4 == store.prefix, found.5 == "ready" else { throw Failure.invalid }
        } else {
            guard try handle.db.readRows("SELECT 1 FROM tb_stores WHERE module LIKE 'exact.swift.pool%' LIMIT 1", map: { $0.int(0) }).isEmpty else { throw Failure.unsupported }
            // This is one additive structural change, not a whole-ledger move.
            // Obtain and verify an immutable WAL-aware snapshot before its DDL.
            try ExactStagePoolBackup.ensure(container: store.containerURL, connection: handle.db)
            guard try BusinessSQLiteRoutes.validateActiveContainer(target.containerURL),
                  try Self.fileIdentity(target.containerURL) == openedIdentity else { throw Failure.unavailable }
            try handle.db.transaction { tx in
                try tx.execute("INSERT INTO tb_stores(store_id,module,source_identity,logical_path,namespace_prefix,user_version,state) VALUES(?,?,?,?,?,1,'ready')",
                    bindings: [.text(store.id), .text(store.module), .text(store.sourceIdentity), .text(store.logicalURL.path), .text(store.prefix)])
                for (_, sql) in schema { try tx.execute(sql) }
                let namespace = SQLiteStoreNamespace(prefix: store.prefix, objectNames: Set(schema.map(\.0)))
                for (name, sql) in schema {
                    let type = name.hasPrefix("guard_") ? "trigger" : "table"
                    try tx.execute("INSERT INTO tb_store_objects VALUES(?,?,?,?)",
                        bindings: [.text(store.id), .text(name), .text(type), .text(try namespace.unbind(sql))])
                }
            }
        }
        try validateSchema()
    }

    private func table(_ name: String) -> String { SQLiteStoreNamespace.quote(store.prefix + name) }
    private static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw Failure.unavailable }
        return "\(device):\(inode)"
    }
    private var schema: [(String, String)] {
        let jobs = table("jobs"), receipts = table("publication_receipts")
        var result: [(String, String)] = [
            ("operations", "CREATE TABLE \(table("operations"))(operation_id TEXT PRIMARY KEY NOT NULL,owner TEXT NOT NULL,base_proof TEXT NOT NULL,phase TEXT NOT NULL) WITHOUT ROWID"),
            ("jobs", "CREATE TABLE \(jobs)(job_id TEXT PRIMARY KEY NOT NULL,owner TEXT NOT NULL,source_path TEXT NOT NULL,source_key TEXT NOT NULL,base_proof TEXT NOT NULL,contract_digest TEXT NOT NULL,logical_path TEXT NOT NULL UNIQUE,operation_id TEXT NOT NULL,codec INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN ('building','sealed','consumed','reclaimed')),manifest BLOB,digest TEXT,byte_count INTEGER,row_count INTEGER,sealed_at REAL) WITHOUT ROWID"),
            ("publication_receipts", "CREATE TABLE \(receipts)(owner TEXT NOT NULL,job_id TEXT PRIMARY KEY NOT NULL,payload_digest TEXT NOT NULL,generation TEXT NOT NULL) WITHOUT ROWID"),
        ]
        for name in ["event_rows", "fingerprints", "chunks"] {
            let t = table(name)
            result.append((name, "CREATE TABLE \(t)(job_id TEXT NOT NULL REFERENCES \(jobs)(job_id),ordinal INTEGER NOT NULL CHECK(ordinal>=0),payload BLOB NOT NULL CHECK(length(payload)<=\(ExactStageRowCodec.maximumRowBytes)),PRIMARY KEY(job_id,ordinal)) WITHOUT ROWID"))
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let trigger = "guard_\(name)_\(action.lowercased())"
                let row = action == "INSERT" ? "NEW" : "OLD"
                let permitted = action == "DELETE"
                    ? "state='building' OR (state='consumed' AND EXISTS(SELECT 1 FROM \(receipts) r WHERE r.job_id=\(row).job_id AND r.owner=\(jobs).owner AND r.payload_digest=\(jobs).digest))"
                    : "state='building'"
                result.append((trigger, "CREATE TRIGGER \(table(trigger)) BEFORE \(action) ON \(t) WHEN NOT EXISTS(SELECT 1 FROM \(jobs) WHERE job_id=\(row).job_id AND (\(permitted))) BEGIN SELECT RAISE(ABORT,'immutable stage payload'); END"))
            }
        }
        result.append(("guard_job_facts", "CREATE TRIGGER \(table("guard_job_facts")) BEFORE UPDATE OF owner,source_path,source_key,base_proof,contract_digest,logical_path,operation_id,codec,manifest,digest,byte_count,row_count,sealed_at ON \(jobs) WHEN OLD.state<>'building' BEGIN SELECT RAISE(ABORT,'immutable stage seal'); END"))
        result.append(("guard_job_delete", "CREATE TRIGGER \(table("guard_job_delete")) BEFORE DELETE ON \(jobs) BEGIN SELECT RAISE(ABORT,'retain stage receipt header'); END"))
        result.append(("guard_job_state", "CREATE TRIGGER \(table("guard_job_state")) BEFORE UPDATE OF state ON \(jobs) WHEN NOT (NEW.state=OLD.state OR (OLD.state='building' AND NEW.state='sealed' AND NEW.manifest IS NOT NULL AND NEW.digest IS NOT NULL AND NEW.byte_count>=0 AND NEW.row_count>0) OR (OLD.state='sealed' AND NEW.state='consumed' AND EXISTS(SELECT 1 FROM \(receipts) r WHERE r.job_id=OLD.job_id AND r.owner=OLD.owner AND r.payload_digest=OLD.digest)) OR (OLD.state='consumed' AND NEW.state='reclaimed' AND NOT EXISTS(SELECT 1 FROM \(table("event_rows")) WHERE job_id=OLD.job_id) AND NOT EXISTS(SELECT 1 FROM \(table("fingerprints")) WHERE job_id=OLD.job_id) AND NOT EXISTS(SELECT 1 FROM \(table("chunks")) WHERE job_id=OLD.job_id))) BEGIN SELECT RAISE(ABORT,'invalid stage transition'); END"))
        for action in ["UPDATE", "DELETE"] {
            let name = "guard_receipt_\(action.lowercased())"
            result.append((name, "CREATE TRIGGER \(table(name)) BEFORE \(action) ON \(receipts) BEGIN SELECT RAISE(ABORT,'immutable publication receipt'); END"))
        }
        return result
    }

    private func validateSchema() throws {
        func normalized(_ sql: String) throws -> [String] {
            try SQLiteStoreNamespace.tokens(sql).filter { $0.kind != .trivia && $0.raw != ";" }.map(\.raw)
        }
        let actual = try handle.db.readRows("SELECT name,sql FROM main.sqlite_master WHERE substr(name,1,?)=? AND name NOT LIKE 'sqlite_%'",
            bindings: [.int(store.prefix.count), .text(store.prefix)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        let dictionary = Dictionary(uniqueKeysWithValues: actual)
        guard dictionary.count == schema.count else { throw Failure.unsupported }
        for (name, sql) in schema {
            guard let stored = dictionary[store.prefix + name], try normalized(stored) == normalized(sql) else { throw Failure.unsupported }
        }
    }

    private func use<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try BusinessSQLiteRoutes.requireAccess(to: store, readOnly: false)
        guard try BusinessSQLiteRoutes.validateActiveContainer(store.containerURL),
              try Self.fileIdentity(store.containerURL) == openedIdentity,
              try handle.db.readRows("SELECT user_version FROM tb_stores WHERE store_id=? AND state='ready'", bindings: [.text(store.id)], map: { $0.int(0) }).first == 1 else {
            throw Failure.unsupported
        }
        return try body(handle.db)
    }

    private static func digest(_ fields: [String]) -> String {
        var hash = SHA256()
        for field in fields { update(&hash, Data(field.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func update(_ hash: inout SHA256, _ data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
        hash.update(data: data)
    }
    private func base(for target: BusinessSQLiteStore, on db: SQLiteDatabaseConnection) throws -> String {
        guard target.containerURL == store.containerURL, target.module == "exact.swift",
              try db.readRows("SELECT namespace_prefix FROM tb_stores WHERE store_id=? AND module='exact.swift'", bindings: [.text(target.id)], map: { $0.text(0) }).first == target.prefix else { throw Failure.invalid }
        let values = try db.readRows("SELECT key,value FROM \(SQLiteStoreNamespace.quote(target.prefix + "schema_meta")) WHERE key IN ('provenance_epoch','attribution_generation') ORDER BY key") {
            ($0.text(0) ?? "") + "=" + ($0.text(1) ?? "")
        }
        return Self.digest(values)
    }
    func job(for target: BusinessSQLiteStore, source: URL, contract: Data) throws -> Job {
        try use { db in
            let base = try base(for: target, on: db)
            let contractDigest = SHA256.hash(data: contract).map { String(format: "%02x", $0) }.joined()
            let source = source.standardizedFileURL
            let id = Self.digest(["exact-stage-job-v1", target.id, source.path, base, contractDigest])
            return Job(id: id, owner: target.id, source: source, base: base, contract: contractDigest,
                url: store.logicalURL.appendingPathComponent(target.id).appendingPathComponent(id + ".stage"))
        }
    }
    func lookup(_ url: URL, for target: BusinessSQLiteStore) throws -> Job? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == store.logicalURL.appendingPathComponent(target.id).path,
              url.pathExtension == "stage" else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        return try use { db in
            let rows = try db.readRows("SELECT owner,source_path,base_proof,contract_digest,codec,logical_path FROM \(table("jobs")) WHERE job_id=?", bindings: [.text(id)]) { row -> Job in
                guard row.int(4) == ExactStageRowCodec.version else { throw Failure.unsupported }
                guard row.text(0) == target.id, row.text(5) == url.path,
                      let source = row.text(1), let base = row.text(2), let contract = row.text(3),
                      id == Self.digest(["exact-stage-job-v1", target.id, source, base, contract]) else { throw Failure.invalid }
                return Job(id: id, owner: target.id, source: URL(fileURLWithPath: source), base: base, contract: contract, url: url)
            }
            return rows.first
        }
    }
    func candidates(for target: BusinessSQLiteStore, source: URL) throws -> [URL] {
        try use { db in
            try db.readRows("SELECT logical_path,codec FROM \(table("jobs")) WHERE owner=? AND source_path=? AND base_proof=? AND state='sealed' ORDER BY sealed_at DESC,job_id",
                bindings: [.text(target.id), .text(source.standardizedFileURL.path), .text(try base(for: target, on: db))]) {
                guard $0.int(1) == ExactStageRowCodec.version, let path = $0.text(0) else { throw Failure.unsupported }
                return URL(fileURLWithPath: path)
            }
        }
    }
    static let legacyLookupSQL = "SELECT logical_path,source_identity FROM tb_stores WHERE module='exact.swift.stage' AND (logical_path=? OR (logical_path>=? AND logical_path<?)) ORDER BY logical_path"
    func legacyURLs(for target: BusinessSQLiteStore, sourceDigest: String) throws -> [URL] {
        guard target.containerURL == store.containerURL, target.module == "exact.swift",
              sourceDigest.count == 64, sourceDigest.allSatisfy(\.isHexDigit) else { throw Failure.invalid }
        let directory = target.logicalURL.deletingLastPathComponent()
            .appendingPathComponent("staging").appendingPathComponent(target.logicalURL.lastPathComponent)
        let primary = directory.appendingPathComponent(sourceDigest + ".sqlite").path
        let lower = directory.appendingPathComponent(sourceDigest + ".candidate-").path
        let upper = directory.appendingPathComponent(sourceDigest + ".candidate.").path
        let identityPrefix = "staging/" + target.logicalURL.lastPathComponent + "/"
        return try use { db in
            // logical_path already has a UNIQUE B-tree. A bounded range uses
            // that index; enumerating every old job for every source is O(N²).
            try db.readRows(Self.legacyLookupSQL,
                bindings: [.text(primary), .text(lower), .text(upper)]) {
                guard let path = $0.text(0) else { throw Failure.invalid }
                let url = URL(fileURLWithPath: path)
                guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                      $0.text(1) == identityPrefix + url.lastPathComponent else { throw Failure.invalid }
                return url
            }
        }
    }
    func seal(of job: Job) throws -> Seal? {
        try use { db in
            try db.readRows("SELECT codec,digest,byte_count,row_count,sealed_at,state,owner,contract_digest FROM \(table("jobs")) WHERE job_id=?", bindings: [.text(job.id)]) { row -> Seal? in
                guard row.int(0) == ExactStageRowCodec.version else { throw Failure.unsupported }
                guard row.text(6) == job.owner, row.text(7) == job.contract else { throw Failure.invalid }
                guard ["sealed", "consumed"].contains(row.text(5) ?? "") else { return nil }
                guard let digest = row.text(1), let bytes = row.int64(2), bytes >= 0,
                      let count = row.int64(3), count > 0, let date = row.double(4) else { throw Failure.invalid }
                return Seal(digest: digest, bytes: UInt64(bytes), rows: count, timestamp: date)
            }.first ?? nil
        }
    }

    func persist(_ job: Job, from source: SQLiteDatabaseConnection) throws {
        let names = try source.readRows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { $0.text(0) ?? "" }
        guard names == ExactStageSchema.tables.sorted(),
              try source.readRows("SELECT COUNT(*) FROM manifest", map: { $0.int(0) }).first == 1,
              try source.readRows("SELECT COUNT(*) FROM manifest WHERE complete=1", map: { $0.int(0) }).first == 1,
              try source.readRows("SELECT canonical_path FROM manifest", map: { $0.text(0) }).first == job.source.path else { throw Failure.invalid }
        for (counter, tableName) in [("event_count", "events"), ("fingerprint_count", "fingerprints"), ("chunk_count", "chunks")] {
            guard try source.readRows("SELECT typeof(\(counter)) FROM manifest", map: { $0.text(0) }).first == "integer",
                  let declared = try source.readRows("SELECT \(counter) FROM manifest", map: { $0.int64(0) }).first ?? nil,
                  declared >= 0,
                  try source.readRows("SELECT COUNT(*) FROM \(SQLiteStoreNamespace.quote(tableName))", map: { $0.int64(0) }).first == declared else { throw Failure.invalid }
        }
        let operation = Self.digest([job.owner, job.base])
        try use { db in try db.transaction { tx in
            let state = try tx.readRows("SELECT state FROM \(table("jobs")) WHERE job_id=?", bindings: [.text(job.id)]) { $0.text(0) }.first ?? nil
            guard state == nil || state == "building" else { throw Failure.invalid }
            try tx.execute("INSERT OR IGNORE INTO \(table("operations")) VALUES(?,?,?,'staging')", bindings: [.text(operation), .text(job.owner), .text(job.base)])
            try tx.execute("INSERT OR IGNORE INTO \(table("jobs"))(job_id,owner,source_path,source_key,base_proof,contract_digest,logical_path,operation_id,codec,state) VALUES(?,?,?,?,?,?,?,?,?,'building')",
                bindings: [.text(job.id), .text(job.owner), .text(job.source.path), .text(Self.digest([job.source.path])), .text(job.base), .text(job.contract), .text(job.url.path), .text(operation), .int(ExactStageRowCodec.version)])
            for name in ["event_rows", "fingerprints", "chunks"] { try tx.execute("DELETE FROM \(table(name)) WHERE job_id=?", bindings: [.text(job.id)]) }
        } }
        var hash = SHA256(), total: Int64 = 0
        var manifest: Data?
        for name in ExactStageSchema.tables {
            Self.update(&hash, Data(name.utf8))
            var batch: [(Int64, Data)] = [], batchBytes = 0, ordinal: Int64 = 0
            func flush() throws {
                guard !batch.isEmpty, let physical = Self.payloadTables[name] else { return }
                try use { db in try db.transaction { tx in
                    let insert = try tx.prepare("INSERT INTO \(table(physical)) VALUES(?,?,?)")
                    for (position, data) in batch { try insert.execute([.text(job.id), .int64(position), .blob(data)]) }
                } }
                batch.removeAll(keepingCapacity: true); batchBytes = 0
            }
            try source.forEachRow("SELECT * FROM \(SQLiteStoreNamespace.quote(name)) ORDER BY \(ExactStageSchema.ordering[name]!)") { row in
                guard let columns = ExactStageSchema.columns[name], Int(row.columnCount) == columns else { throw Failure.unsupported }
                let payload = try ExactStageRowCodec.encode(row)
                Self.update(&hash, payload); total += 1
                if name == "manifest" { guard ordinal == 0 else { throw Failure.invalid }; manifest = payload }
                else { batch.append((ordinal, payload)); batchBytes += payload.count; if batch.count >= 512 || batchBytes >= 1_048_576 { try flush() } }
                ordinal += 1
            }
            try flush()
        }
        let bytes = try BusinessStoreFiles.footprint(source)
        guard let manifest, let count = Int64(exactly: bytes),
              try source.readRows("SELECT actual_bytes FROM manifest", map: { $0.int64(0) }).first == count else { throw Failure.invalid }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try use { db in try db.transaction { tx in
            guard try tx.executeChangedRows("UPDATE \(table("jobs")) SET manifest=?,digest=?,byte_count=?,row_count=?,sealed_at=?,state='sealed' WHERE job_id=? AND state='building' AND owner=? AND contract_digest=?",
                bindings: [.blob(manifest), .text(digest), .int64(count), .int64(total), .double(Date().timeIntervalSince1970), .text(job.id), .text(job.owner), .text(job.contract)]) == 1 else { throw Failure.invalid }
        } }
    }

    func restore(_ job: Job) throws -> SQLiteTemporaryDatabase {
        guard let seal = try seal(of: job) else { throw Failure.unsealed }
        let work = try SQLiteTemporaryDatabase()
        try work.connection.execute(ExactStageSchema.sql)
        var hash = SHA256(), rows: Int64 = 0
        try work.connection.transaction { tx in
            for name in ExactStageSchema.tables {
                Self.update(&hash, Data(name.utf8))
                let columns = ExactStageSchema.columns[name]!
                let insert = try tx.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns).joined(separator: ",")))")
                func copy(_ payload: Data) throws {
                    try insert.execute(ExactStageRowCodec.decode(payload, expectedColumns: columns))
                    Self.update(&hash, payload); rows += 1
                }
                try use { db in
                    if name == "manifest" {
                        let values = try db.readRows("SELECT manifest,length(manifest) FROM \(table("jobs")) WHERE job_id=?", bindings: [.text(job.id)]) { row -> Data in
                            guard let size = row.int(1), size <= ExactStageRowCodec.maximumRowBytes, let data = row.data(0) else { throw Failure.invalid }
                            return data
                        }
                        guard let value = values.first else { throw Failure.invalid }; try copy(value)
                    } else {
                        try db.forEachRow("SELECT payload,length(payload) FROM \(table(Self.payloadTables[name]!)) WHERE job_id=? ORDER BY ordinal", bindings: [.text(job.id)]) { row in
                            guard let size = row.int(1), size <= ExactStageRowCodec.maximumRowBytes, let value = row.data(0) else { throw Failure.invalid }
                            try copy(value)
                        }
                    }
                }
            }
        }
        guard rows == seal.rows, hash.finalize().map({ String(format: "%02x", $0) }).joined() == seal.digest,
              try BusinessStoreFiles.footprint(work.connection) == seal.bytes else { throw Failure.invalid }
        try work.connection.execute("PRAGMA query_only=ON")
        return work
    }

    /// Read a verified old namespace using the retained A handle. Preserve its
    /// row storage classes in a private work area instead of reopening A for
    /// every manifest/count query or changing the old artifact in place.
    func restoreLegacy(_ legacy: BusinessSQLiteStore) throws -> SQLiteTemporaryDatabase? {
        guard legacy.module == "exact.swift.stage", legacy.containerURL == store.containerURL else { throw Failure.invalid }
        return try use { db in
            guard let seal = try legacySeal(legacy, on: db) else { return nil }
            let namespace = SQLiteStoreNamespace(prefix: legacy.prefix, objectNames: Set(ExactStageSchema.tables))
            let proof = try CodexBusinessDatabase.proof(db, namespace: namespace)
            guard proof.rowsDigest == seal.digest, proof.rowCount == seal.rows else { throw Failure.invalid }
            let work = try SQLiteTemporaryDatabase()
            try work.connection.transaction { tx in
                for name in ExactStageSchema.tables {
                    let physical = SQLiteStoreNamespace.quote(legacy.prefix + name)
                    let columns = try db.readRows("PRAGMA table_info(\(physical))") { $0.text(1) ?? "" }
                    guard (1...64).contains(columns.count), !columns.contains("") else { throw Failure.unsupported }
                    // No affinity is intentional: exact typed values, including
                    // legacy TEXT fingerprints, must not be coerced on copy.
                    try tx.execute("CREATE TABLE \(SQLiteStoreNamespace.quote(name))(\(columns.map(SQLiteStoreNamespace.quote).joined(separator: ",")))")
                    let insert = try tx.prepare("INSERT INTO \(SQLiteStoreNamespace.quote(name)) VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ",")))")
                    try db.forEachRow("SELECT * FROM \(physical)") { row in
                        try insert.execute(ExactStageRowCodec.decode(ExactStageRowCodec.encode(row), expectedColumns: columns.count))
                    }
                }
            }
            guard try BusinessStoreFiles.footprint(work.connection) == seal.bytes else { throw Failure.invalid }
            try work.connection.execute("PRAGMA query_only=ON")
            return work
        }
    }
    private func legacySeal(_ legacy: BusinessSQLiteStore, on db: SQLiteDatabaseConnection) throws -> Seal? {
        try db.readRows("SELECT s.byte_count,s.row_count,s.rows_digest,s.sealed_at FROM tb_store_seals s JOIN tb_stores t ON t.store_id=s.store_id WHERE t.store_id=? AND t.module='exact.swift.stage' AND t.namespace_prefix=? AND t.state='sealed'",
            bindings: [.text(legacy.id), .text(legacy.prefix)]) { row in
                guard let bytes = row.int64(0), bytes >= 0, let rows = row.int64(1), rows >= 0,
                      let digest = row.text(2), let date = row.double(3) else { throw Failure.invalid }
                return Seal(digest: digest, bytes: UInt64(bytes), rows: rows, timestamp: date)
            }.first
    }
    func legacyObservation(_ legacy: BusinessSQLiteStore) throws -> SourceFileObservation? {
        guard legacy.module == "exact.swift.stage", legacy.containerURL == store.containerURL else { throw Failure.invalid }
        return try use { db in
            try legacySeal(legacy, on: db).map { SourceFileObservation(indexedLogicalSize: $0.bytes, modifiedAt: $0.timestamp, physicalStamp: $0.digest) }
        }
    }

    func consumeLegacy(_ legacy: BusinessSQLiteStore, generation: String, on tx: SQLiteDatabaseConnection) throws {
        guard legacy.module == "exact.swift.stage", legacy.containerURL == store.containerURL,
              let binding = tx.businessBinding, binding.store.module == "exact.swift",
              legacy.sourceIdentity.hasPrefix("staging/" + binding.store.logicalURL.lastPathComponent + "/"),
              binding.store.containerURL == store.containerURL, sqlite3_get_autocommit(tx.rawDatabase) == 0,
              try Self.fileIdentity(store.containerURL) == openedIdentity else { throw Failure.invalid }
        tx.businessBinding = nil; defer { tx.businessBinding = binding }
        guard let seal = try legacySeal(legacy, on: tx) else { throw Failure.unsealed }
        let key = "legacy:" + legacy.id
        let existing = try tx.readRows("SELECT owner,payload_digest,generation FROM \(table("publication_receipts")) WHERE job_id=?", bindings: [.text(key)]) { ($0.text(0), $0.text(1), $0.text(2)) }.first
        if let existing {
            guard existing.0 == binding.store.id, existing.1 == seal.digest, existing.2 == generation else { throw Failure.alreadyConsumed }
        } else {
            try tx.execute("INSERT INTO \(table("publication_receipts")) VALUES(?,?,?,?)", bindings: [.text(binding.store.id), .text(key), .text(seal.digest), .text(generation)])
        }
    }
    func mayReclaimLegacy(_ legacy: BusinessSQLiteStore, for target: BusinessSQLiteStore) throws -> Bool {
        guard legacy.module == "exact.swift.stage", legacy.containerURL == store.containerURL,
              target.module == "exact.swift", target.containerURL == store.containerURL,
              legacy.sourceIdentity.hasPrefix("staging/" + target.logicalURL.lastPathComponent + "/") else { throw Failure.invalid }
        return try use { db in
            guard let seal = try legacySeal(legacy, on: db) else { return false }
            return try db.readRows("SELECT 1 FROM \(table("publication_receipts")) WHERE job_id=? AND owner=? AND payload_digest=?",
                bindings: [.text("legacy:" + legacy.id), .text(target.id), .text(seal.digest)], map: { $0.int(0) }).first == 1
        }
    }

    /// A bounded maintenance operation, never part of the publication result.
    /// Receipts survive a restart and are the only cleanup queue. No directory
    /// scan or age/filename heuristic authorizes removing a namespace.
    func reclaimPublished(maximumJobs: Int = 4, budget: TimeInterval = 0.25) throws -> Int {
        guard (1...16).contains(maximumJobs), budget > 0 else { throw Failure.invalid }
        let started = Date()
        let candidates = try use { db in
            try db.readRows("""
            SELECT o.logical_path,o.module,o.source_identity,j.logical_path,NULL
            FROM \(table("jobs")) j JOIN tb_stores o ON o.store_id=j.owner
            WHERE j.state='consumed' AND o.module='exact.swift'
            UNION ALL
            SELECT o.logical_path,o.module,o.source_identity,l.logical_path,l.source_identity
            FROM \(table("publication_receipts")) r
            JOIN tb_stores l ON r.job_id='legacy:'||l.store_id
            JOIN tb_stores o ON o.store_id=r.owner
            WHERE l.module='exact.swift.stage' AND o.module='exact.swift'
            LIMIT ?
            """, bindings: [.int(maximumJobs)]) { row in
                (BusinessSQLiteStore(containerURL: store.containerURL, logicalURL: URL(fileURLWithPath: row.text(0)!),
                    module: row.text(1)!, sourceIdentity: row.text(2)!), URL(fileURLWithPath: row.text(3)!), row.text(4))
            }
        }
        var reclaimed = 0
        for (target, url, legacySource) in candidates {
            if Date().timeIntervalSince(started) >= budget { break }
            try BusinessSQLiteRoutes.requireAccess(to: target, readOnly: false)
            if let legacySource {
                let legacy = BusinessSQLiteStore(containerURL: store.containerURL, logicalURL: url,
                    module: "exact.swift.stage", sourceIdentity: legacySource)
                if try reclaimLegacy(legacy, for: target) { reclaimed += 1 }
            } else if let job = try lookup(url, for: target) {
                try reclaim(job); reclaimed += 1
            }
        }
        return reclaimed
    }

    @discardableResult
    func reclaimLegacy(_ legacy: BusinessSQLiteStore, for target: BusinessSQLiteStore) throws -> Bool {
        guard legacy.module == "exact.swift.stage", target.module == "exact.swift",
              legacy.containerURL == store.containerURL, target.containerURL == store.containerURL,
              legacy.sourceIdentity.hasPrefix("staging/" + target.logicalURL.lastPathComponent + "/") else { throw Failure.invalid }
        try BusinessSQLiteRoutes.requireAccess(to: target, readOnly: false)
        let removed = try use { db in
            try db.execute("PRAGMA busy_timeout=50")
            defer { try? db.execute("PRAGMA busy_timeout=30000") }
            let verified: (String, Int)? = try db.readTransaction { tx in
                guard let seal = try legacySeal(legacy, on: tx) else { return nil }
                let receipt = try tx.readRows("SELECT 1 FROM \(table("publication_receipts")) WHERE job_id=? AND owner=? AND payload_digest=?",
                    bindings: [.text("legacy:" + legacy.id), .text(target.id), .text(seal.digest)]) { $0.int(0) }.first == 1
                guard receipt else { return nil }
                let proof = try CodexBusinessDatabase.proof(tx, namespace: SQLiteStoreNamespace(prefix: legacy.prefix, objectNames: Set(ExactStageSchema.tables)))
                guard proof.rowsDigest == seal.digest, proof.rowCount == seal.rows else { throw Failure.invalid }
                let version = try tx.readRows("PRAGMA data_version") { $0.int(0) }.first ?? nil
                guard let version else { throw Failure.invalid }
                return (seal.digest, version)
            }
            guard let (digest, version) = verified else { return false }
            return try db.transaction { tx in
                guard try tx.readRows("PRAGMA data_version", map: { $0.int(0) }).first == version,
                      try legacySeal(legacy, on: tx)?.digest == digest else { throw Failure.unavailable }
                let objects = try tx.readRows("SELECT name,type FROM sqlite_master WHERE substr(name,1,?)=? ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 ELSE 3 END",
                    bindings: [.int(legacy.prefix.count), .text(legacy.prefix)]) { ($0.text(0)!, $0.text(1)!) }
                guard Set(objects.filter { $0.1 == "table" }.map { String($0.0.dropFirst(legacy.prefix.count)) }) == Set(ExactStageSchema.tables),
                      objects.allSatisfy({ ["table", "index", "view", "trigger"].contains($0.1) }) else { throw Failure.invalid }
                for (name, kind) in objects { try tx.execute("DROP \(kind.uppercased()) IF EXISTS \(SQLiteStoreNamespace.quote(name))") }
                try tx.execute("UPDATE tb_legacy_inputs SET retired=1 WHERE store_id=?", bindings: [.text(legacy.id)])
                for name in ["tb_store_seals", "tb_store_objects", "tb_store_imports", "tb_stores"] {
                    try tx.execute("DELETE FROM \(name) WHERE store_id=?", bindings: [.text(legacy.id)])
                }
                return true
            }
        }
        if removed { BusinessSQLiteRoutes.forget(legacy) }
        return removed
    }

    /// Narrow same-A bridge: only the verified Exact binding may consume its
    /// own job, within the actual publication transaction. No arbitrary prefix
    /// SQL or independent second transaction is exposed to callers.
    func consume(_ job: Job, generation: String, on tx: SQLiteDatabaseConnection) throws {
        guard let binding = tx.businessBinding, binding.store.id == job.owner,
              binding.store.module == "exact.swift", binding.store.containerURL == store.containerURL,
              try Self.fileIdentity(store.containerURL) == openedIdentity,
              sqlite3_get_autocommit(tx.rawDatabase) == 0, !generation.isEmpty else { throw Failure.invalid }
        tx.businessBinding = nil; defer { tx.businessBinding = binding }
        let proofs = try tx.readRows("SELECT digest,state,owner,contract_digest FROM \(table("jobs")) WHERE job_id=?", bindings: [.text(job.id)]) { ($0.text(0), $0.text(1), $0.text(2), $0.text(3)) }
        guard let proof = proofs.first, let digest = proof.0, ["sealed", "consumed"].contains(proof.1 ?? ""), proof.2 == job.owner, proof.3 == job.contract else { throw Failure.invalid }
        let previous = try tx.readRows("SELECT owner,payload_digest,generation FROM \(table("publication_receipts")) WHERE job_id=?", bindings: [.text(job.id)]) { ($0.text(0), $0.text(1), $0.text(2)) }.first
        if let previous {
            guard previous.0 == job.owner, previous.1 == digest, previous.2 == generation else { throw Failure.alreadyConsumed }
            return
        }
        try tx.execute("INSERT INTO \(table("publication_receipts")) VALUES(?,?,?,?)", bindings: [.text(job.owner), .text(job.id), .text(digest), .text(generation)])
        try tx.execute("UPDATE \(table("jobs")) SET state='consumed' WHERE job_id=? AND state='sealed'", bindings: [.text(job.id)])
    }

    func reclaim(_ job: Job) throws {
        try use { db in
            try db.execute("PRAGMA busy_timeout=50")
            defer { try? db.execute("PRAGMA busy_timeout=30000") }
            try db.transaction { tx in
            let permitted = try tx.readRows("SELECT j.state FROM \(table("jobs")) j JOIN \(table("publication_receipts")) r ON r.job_id=j.job_id AND r.owner=j.owner AND r.payload_digest=j.digest WHERE j.job_id=? AND j.owner=? AND j.contract_digest=?",
                bindings: [.text(job.id), .text(job.owner), .text(job.contract)]) { $0.text(0) }.first ?? nil
            if permitted == "reclaimed" { return }
            guard permitted == "consumed" else { throw Failure.unsealed }
            for name in ["event_rows", "fingerprints", "chunks"] { try tx.execute("DELETE FROM \(table(name)) WHERE job_id=?", bindings: [.text(job.id)]) }
            try tx.execute("UPDATE \(table("jobs")) SET state='reclaimed' WHERE job_id=?", bindings: [.text(job.id)])
        } }
    }
}
