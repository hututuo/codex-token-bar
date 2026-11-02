import Foundation

/// One parser/validator-facing surface for a new pooled job or an old artifact.
/// Legacy A artifacts are read through the pool's retained connection; creating
/// another per-file namespace in a running application is explicitly rejected.
final class ExactStageAccess: DatabaseAccessing {
    let url: URL
    let job: ExactStagePool.Job?
    private let pool: ExactStagePool?
    private let legacy: SQLiteDatabaseDriver?
    private let legacyStore: BusinessSQLiteStore?
    private var work: SQLiteTemporaryDatabase?

    init(pool: ExactStagePool, job: ExactStagePool.Job, creating: Bool = false) throws {
        self.pool = pool; self.job = job; url = job.url
        legacy = nil; legacyStore = nil
        work = creating ? try SQLiteTemporaryDatabase() : nil
    }
    init(legacyURL: URL, readOnly: Bool = true, pool: ExactStagePool? = nil,
         timeout: Int32 = 1_000, fileManager: FileManager = .default) throws {
        let registered = BusinessSQLiteRoutes.store(for: legacyURL)
        guard readOnly || registered == nil else { throw ExactStagePool.Failure.unavailable }
        url = legacyURL; self.pool = pool; job = nil; legacyStore = registered
        legacy = SQLiteDatabaseDriver(url: legacyURL, readOnly: readOnly,
            createsFileIfMissing: !readOnly, busyTimeoutMilliseconds: timeout,
            enableWAL: false, fileManager: fileManager)
    }

    func withConnection<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        if let work { return try body(work.connection) }
        if let pool, let job {
            let restored = try pool.restore(job); work = restored
            return try body(restored.connection)
        }
        if let pool, let legacyStore, let restored = try pool.restoreLegacy(legacyStore) {
            work = restored
            return try body(restored.connection)
        }
        guard let legacy else { throw ExactStagePool.Failure.invalid }
        return try legacy.withConnection(body)
    }
    func readRows<T>(_ sql: String, bindings: [SQLiteBinding] = [], map: (SQLiteStatement) throws -> T) throws -> [T] {
        try withConnection { try $0.readRows(sql, bindings: bindings, map: map) }
    }
    func forEachRow(_ sql: String, bindings: [SQLiteBinding] = [], _ body: (SQLiteStatement) throws -> Void) throws {
        try withConnection { try $0.forEachRow(sql, bindings: bindings, body) }
    }
    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        try withConnection { try $0.execute(sql, bindings: bindings) }
    }
    func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        try withConnection { try $0.transaction(body) }
    }
    func byteCount(connection: SQLiteDatabaseConnection? = nil) throws -> UInt64 {
        if job != nil, let connection { return try BusinessStoreFiles.footprint(connection) }
        if let job {
            guard let seal = try pool?.seal(of: job) else { throw ExactStagePool.Failure.unsealed }
            return seal.bytes
        }
        if let legacyStore, let observed = try pool?.legacyObservation(legacyStore) { return observed.size }
        return try BusinessStoreFiles.byteCount(at: url, connection: connection)
    }
    func observation() throws -> SourceFileObservation {
        if let job {
            guard let seal = try pool?.seal(of: job) else { throw ExactStagePool.Failure.unsealed }
            return SourceFileObservation(indexedLogicalSize: seal.bytes, modifiedAt: seal.timestamp, physicalStamp: seal.digest)
        }
        if let legacyStore, let value = try pool?.legacyObservation(legacyStore) { return value }
        return try SourceFileObservation.read(at: url)
    }
    func seal(connection: SQLiteDatabaseConnection) throws {
        if let pool, let job {
            try pool.persist(job, from: connection)
            try connection.execute("PRAGMA query_only=ON")
        } else { try BusinessStoreFiles.seal(at: url, connection: connection) }
    }
    func consume(generation: String, on transaction: SQLiteDatabaseConnection) throws {
        if let pool, let job { try pool.consume(job, generation: generation, on: transaction) }
        else if let pool, let legacyStore { try pool.consumeLegacy(legacyStore, generation: generation, on: transaction) }
        else if transaction.businessBinding != nil { throw ExactStagePool.Failure.unavailable }
    }
}
