import Foundation
import Darwin
import SQLite3

enum SQLiteBinding {
    case null
    case blob(Data)
    case text(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case date(Date)

    static func optionalText(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.text) ?? .null
    }

    static func optionalInt(_ value: Int?) -> SQLiteBinding {
        value.map(SQLiteBinding.int) ?? .null
    }

    static func optionalDate(_ value: Date?) -> SQLiteBinding {
        value.map(SQLiteBinding.date) ?? .null
    }
}

struct SQLiteStatement {
    fileprivate let raw: OpaquePointer?

    var columnCount: Int32 {
        sqlite3_column_count(raw)
    }

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL,
              let value = sqlite3_column_text(raw, column) else {
            return nil
        }
        return String(cString: value)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(raw, column))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(raw, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    func int(_ column: Int32) -> Int? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(raw, column))
    }

    func int64(_ column: Int32) -> Int64? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(raw, column)
    }

    func double(_ column: Int32) -> Double? {
        guard sqlite3_column_type(raw, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(raw, column)
    }

    func date(_ column: Int32) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }
}

protocol SQLiteTransientReadFailureReporting {
    var isTransientReadFailure: Bool { get }
}

struct SQLiteDatabaseError: LocalizedError, SQLiteTransientReadFailureReporting {
    let operation: String
    let code: Int32
    let message: String
    let path: String?
    let systemErrno: Int32?

    init(
        operation: String,
        code: Int32,
        message: String,
        path: String?,
        systemErrno: Int32? = nil
    ) {
        self.operation = operation
        self.code = code
        self.message = message
        self.path = path
        self.systemErrno = systemErrno
    }

    var primaryCode: Int32 {
        code & 0xFF
    }

    var isTransientReadFailure: Bool {
        switch primaryCode {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_PROTOCOL, SQLITE_SCHEMA:
            return true
        case SQLITE_IOERR:
            return code != Self.ioErrorData && code != Self.ioErrorCorruptFileSystem
        case SQLITE_CANTOPEN:
            return code == Self.cantOpenDirtyWAL
                || systemErrno == POSIXErrorCode.ENOENT.rawValue
                || systemErrno == POSIXErrorCode.ESTALE.rawValue
        default:
            return code == Self.errorSnapshot
                || code == Self.readOnlyDatabaseMoved
                || code == Self.readOnlyCannotInitialize
        }
    }

    // Some extended-result-code macros are not imported by every Swift SDK.
    // Keep the values local instead of weakening recovery back to primary codes.
    private static let errorSnapshot = SQLITE_ERROR | (3 << 8)
    private static let ioErrorData = SQLITE_IOERR | (32 << 8)
    private static let ioErrorCorruptFileSystem = SQLITE_IOERR | (33 << 8)
    private static let cantOpenDirtyWAL = SQLITE_CANTOPEN | (5 << 8)
    private static let readOnlyDatabaseMoved = SQLITE_READONLY | (4 << 8)
    private static let readOnlyCannotInitialize = SQLITE_READONLY | (5 << 8)

    var errorDescription: String? {
        if let path {
            return "\(operation) failed for \(path): \(message)"
        }
        return "\(operation) failed: \(message)"
    }
}

enum SQLiteReadRecovery {
    static let defaultRetryDelays: [TimeInterval] = [0.05, 0.20, 0.75]

    static func run<T>(
        retryDelays: [TimeInterval] = defaultRetryDelays,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        operation: () throws -> T
    ) throws -> T {
        var retryIndex = 0
        while true {
            do {
                return try operation()
            } catch let error as SQLiteDatabaseError {
                guard error.isTransientReadFailure,
                      retryIndex < retryDelays.count else {
                    throw error
                }
                sleep(retryDelays[retryIndex])
                retryIndex += 1
            }
        }
    }

    static func isTransientReadFailure(_ error: Error) -> Bool {
        if let reported = error as? any SQLiteTransientReadFailureReporting {
            return reported.isTransientReadFailure
        }
        let cocoaError = error as NSError
        if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error,
           underlying as NSError !== cocoaError {
            return isTransientReadFailure(underlying)
        }
        return false
    }
}

enum SQLiteConnectionConsistency: Equatable {
    case ordinary
    case externallyOwnedWAL
}

/// SQLite opens the path passed to `sqlite3_open_v2` as the database's `main`
/// file. A `-wal` or `-shm` file is not a second database: it is a sidecar
/// selected by SQLite after the main path has been opened. Keep sidecars out of
/// every main-path/pinned-path decision before handing a URL to SQLite.
enum SQLiteDatabasePath {
    private static let sidecarSuffixes = ["-wal", "-shm"]

    static func mainURL(for url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard let suffix = sidecarSuffixes.first(where: { name.hasSuffix($0) }) else {
            return standardized
        }

        let mainName = String(name.dropLast(suffix.count))
        guard mainName.hasSuffix(".sqlite") else {
            // Do not reinterpret an unrelated file whose name merely happens
            // to end in `-wal`/`-shm` as a database family member.
            return standardized
        }
        return standardized
            .deletingLastPathComponent()
            .appendingPathComponent(mainName, isDirectory: false)
    }
}

/// A peer WAL may be left in a checkpointed state with its `-wal`/`-shm`
/// files already removed. Apple SQLite still tries to open the missing WAL
/// sidecar for an ordinary read-only connection and reports `SQLITE_CANTOPEN`
/// while preparing even though the main file is a complete snapshot. The
/// immutable URI mode is safe only for that narrow state: it intentionally
/// ignores WAL, so it must never be used while either sidecar exists.
private struct SQLitePeerPathSignature: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let sizeBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        fileID = UInt64(status.st_ino)
        sizeBytes = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

private struct SQLitePeerImmutableSnapshot: Equatable {
    let main: SQLitePeerPathSignature
    let wal: SQLitePeerPathSignature?
    let shm: SQLitePeerPathSignature?
    let parentDirectory: SQLitePeerPathSignature
    let isWALFormat: Bool

    static func capture(mainURL: URL) throws -> SQLitePeerImmutableSnapshot {
        let mainStatus = try metadata(at: mainURL, missingMessage: "database file is temporarily unavailable")
        guard (mainStatus.st_mode & S_IFMT) == S_IFREG else {
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: SQLITE_CANTOPEN,
                message: "database path is not a regular file",
                path: mainURL.path
            )
        }

        let parentURL = mainURL.deletingLastPathComponent()
        let parentStatus = try metadata(at: parentURL, missingMessage: "database directory is temporarily unavailable")
        guard (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: SQLITE_CANTOPEN,
                message: "database parent is not a directory",
                path: parentURL.path
            )
        }

        let wal = try optionalMetadata(at: URL(fileURLWithPath: mainURL.path + "-wal"))
        let shm = try optionalMetadata(at: URL(fileURLWithPath: mainURL.path + "-shm"))
        let isWALFormat = try Self.readsWALFormat(mainURL: mainURL)
        return SQLitePeerImmutableSnapshot(
            main: SQLitePeerPathSignature(mainStatus),
            wal: wal.map(SQLitePeerPathSignature.init),
            shm: shm.map(SQLitePeerPathSignature.init),
            parentDirectory: SQLitePeerPathSignature(parentStatus),
            isWALFormat: isWALFormat
        )
    }

    func validateReadyForImmutableRead(path: String) throws {
        guard isWALFormat else {
            throw SQLiteDatabaseError(
                operation: "Open immutable SQLite peer",
                code: SQLITE_NOTADB,
                message: "database is not in WAL format",
                path: path
            )
        }
        guard wal == nil, shm == nil else {
            throw transientChange(path: path, message: "WAL sidecar appeared before immutable read")
        }
    }

    func validateUnchanged(to next: SQLitePeerImmutableSnapshot, path: String) throws {
        guard isWALFormat, next.isWALFormat else {
            throw SQLiteDatabaseError(
                operation: "Read immutable SQLite peer",
                code: SQLITE_NOTADB,
                message: "database WAL format changed while the read was in progress",
                path: path
            )
        }
        guard main == next.main,
              wal == nil, next.wal == nil,
              shm == nil, next.shm == nil,
              parentDirectory == next.parentDirectory else {
            throw transientChange(path: path, message: "database or WAL sidecar changed while the read was in progress")
        }
    }

    private func transientChange(path: String, message: String) -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: "Read immutable SQLite peer",
            code: SQLITE_PROTOCOL,
            message: message,
            path: path
        )
    }

    private static func metadata(at url: URL, missingMessage: String) throws -> stat {
        var value = stat()
        let status = url.path.withCString { Darwin.lstat($0, &value) }
        guard status == 0 else {
            let errorCode = errno
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: errorCode == ENOENT ? SQLITE_CANTOPEN : SQLITE_IOERR,
                message: errorCode == ENOENT ? missingMessage : String(cString: strerror(errorCode)),
                path: url.path,
                systemErrno: Int32(errorCode)
            )
        }
        return value
    }

    private static func optionalMetadata(at url: URL) throws -> stat? {
        var value = stat()
        let status = url.path.withCString { Darwin.lstat($0, &value) }
        guard status == 0 else {
            let errorCode = errno
            if errorCode == ENOENT { return nil }
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: SQLITE_IOERR,
                message: String(cString: strerror(errorCode)),
                path: url.path,
                systemErrno: Int32(errorCode)
            )
        }
        return value
    }

    private static func readsWALFormat(mainURL: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: mainURL)
        } catch {
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: SQLITE_IOERR,
                message: error.localizedDescription,
                path: mainURL.path
            )
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: 18)
            let header = try handle.read(upToCount: 2) ?? Data()
            return header.count == 2 && header[0] == 2 && header[1] == 2
        } catch {
            throw SQLiteDatabaseError(
                operation: "Inspect immutable SQLite peer",
                code: SQLITE_IOERR,
                message: error.localizedDescription,
                path: mainURL.path
            )
        }
    }
}

/// A read-only peer wrapper. It first uses the normal SQLite WAL snapshot.
/// Only the precise missing-sidecar failure can enter the immutable fallback;
/// writes and transactions are rejected even if a caller accidentally passes
/// this reader to a write path.
final class SQLitePeerDatabaseReader: DatabaseAccessing, @unchecked Sendable {
    let url: URL

    private let busyTimeoutMilliseconds: Int32
    private let fileManager: FileManager
    private let beforeImmutableOpen: (@Sendable () -> Void)?
    private let afterImmutableOpen: (@Sendable () -> Void)?

    init(
        url: URL,
        busyTimeoutMilliseconds: Int32 = 250,
        fileManager: FileManager = .default,
        beforeImmutableOpen: (@Sendable () -> Void)? = nil,
        afterImmutableOpen: (@Sendable () -> Void)? = nil
    ) {
        self.url = SQLiteDatabasePath.mainURL(for: url)
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.fileManager = fileManager
        self.beforeImmutableOpen = beforeImmutableOpen
        self.afterImmutableOpen = afterImmutableOpen
    }

    func readRows<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let ordinary = SQLiteDatabaseDriver(
            url: url,
            readOnly: true,
            createsFileIfMissing: false,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            enableWAL: false,
            fileManager: fileManager
        )
        do {
            return try ordinary.readRows(sql, bindings: bindings, map: map)
        } catch let error as SQLiteDatabaseError where Self.shouldAttemptImmutableFallback(error, path: url.path) {
            return try readImmutable(sql, bindings: bindings, map: map)
        }
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        throw readOnlyError()
    }

    func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        throw readOnlyError()
    }

    private func readImmutable<T>(
        _ sql: String,
        bindings: [SQLiteBinding],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let initial = try SQLitePeerImmutableSnapshot.capture(mainURL: url)
        try initial.validateReadyForImmutableRead(path: url.path)
        beforeImmutableOpen?()

        let beforeOpen = try SQLitePeerImmutableSnapshot.capture(mainURL: url)
        try initial.validateUnchanged(to: beforeOpen, path: url.path)

        var database: OpaquePointer?
        let uri = url.absoluteString + "?immutable=1"
        let status = sqlite3_open_v2(
            uri,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            let message = database.map { SQLiteDatabaseDriver.message(from: $0) } ?? "Unable to open immutable database"
            let errorCode = database.map {
                SQLiteDatabaseDriver.extendedErrorCode(from: $0, fallback: status)
            } ?? status
            let systemErrno = database.flatMap(SQLiteDatabaseDriver.systemErrno(from:))
            if let database { sqlite3_close(database) }
            throw SQLiteDatabaseError(
                operation: "Open immutable SQLite peer",
                code: errorCode,
                message: message,
                path: url.path,
                systemErrno: systemErrno
            )
        }
        defer { sqlite3_close_v2(database) }

        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        afterImmutableOpen?()

        let connection = SQLiteDatabaseConnection(database: database, path: url.path)
        let rows = try connection.readRows(sql, bindings: bindings, map: map)
        let final = try SQLitePeerImmutableSnapshot.capture(mainURL: url)
        try initial.validateUnchanged(to: final, path: url.path)
        return rows
    }

    private func readOnlyError() -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: "Write SQLite peer",
            code: SQLITE_READONLY,
            message: "peer database reader is read-only",
            path: url.path
        )
    }

    private static func shouldAttemptImmutableFallback(_ error: SQLiteDatabaseError, path: String) -> Bool {
        guard error.path == path,
              error.operation == "Prepare SQLite query" || error.operation == "Step SQLite query",
              error.primaryCode == SQLITE_CANTOPEN || error.primaryCode == SQLITE_READONLY else {
            return false
        }
        if error.primaryCode == SQLITE_CANTOPEN {
            return error.systemErrno == POSIXErrorCode.ENOENT.rawValue
        }
        let readOnlyDirectory = SQLITE_READONLY | (2 << 8)
        let readOnlyCannotInitialize = SQLITE_READONLY | (5 << 8)
        return error.systemErrno == POSIXErrorCode.ENOENT.rawValue
            || error.code == readOnlyDirectory
            || error.code == readOnlyCannotInitialize
    }
}

/// Only the Codex-owned state database opts into this gate. A single global
/// non-recursive lock avoids path-alias holes and multi-database lock ordering:
/// every opted-in connection fully closes before another one opens.
private final class SQLiteExternalWALConnectionCoordinator: @unchecked Sendable {
    static let shared = SQLiteExternalWALConnectionCoordinator()
    private let lock = NSLock()
    private let recursionKey = "CodexTokenBar.SQLiteExternalWALConnectionCoordinator.active"

    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        let threadState = Thread.current.threadDictionary
        guard threadState[recursionKey] == nil else {
            throw SQLiteDatabaseError(
                operation: "Coordinate external SQLite database",
                code: SQLITE_MISUSE,
                message: "nested externally-owned WAL connection is not allowed",
                path: nil
            )
        }
        lock.lock()
        threadState[recursionKey] = true
        defer {
            threadState.removeObject(forKey: recursionKey)
            lock.unlock()
        }
        return try body()
    }
}

private struct SQLiteDatabaseFamilySnapshot {
    private struct Member {
        let url: URL
        let deviceID: UInt64
        let fileID: UInt64

        func identifiesSameFile(as other: Member) -> Bool {
            deviceID == other.deviceID && fileID == other.fileID
        }
    }

    private let databaseURL: URL
    private let main: Member?
    private let wal: Member?
    private let shm: Member?

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        main = try Self.member(at: databaseURL)
        wal = try Self.member(at: Self.sidecarURL(for: databaseURL, suffix: "-wal"))
        shm = try Self.member(at: Self.sidecarURL(for: databaseURL, suffix: "-shm"))
    }

    func validateSafeToOpen() throws {
        guard main != nil else {
            throw transientIdentityError("database file is temporarily unavailable", path: databaseURL.path)
        }
    }

    func validateTransition(to next: SQLiteDatabaseFamilySnapshot) throws {
        try next.validateSafeToOpen()
        guard let main, let nextMain = next.main, main.identifiesSameFile(as: nextMain) else {
            throw transientIdentityError(
                "database file identity changed while the read was in progress",
                path: databaseURL.path
            )
        }
        try validateRetainedSidecar(wal, next.wal, label: "WAL")
        try validateRetainedSidecar(shm, next.shm, label: "SHM")
    }

    private func validateRetainedSidecar(_ previous: Member?, _ next: Member?, label: String) throws {
        guard let previous else { return }
        guard let next, previous.identifiesSameFile(as: next) else {
            throw transientIdentityError(
                "\(label) identity changed while the read was in progress",
                path: previous.url.path
            )
        }
    }

    private func transientIdentityError(_ message: String, path: String) -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: "Read stable SQLite database family",
            code: SQLITE_PROTOCOL,
            message: message,
            path: path
        )
    }

    private static func member(at url: URL) throws -> Member? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            throw SQLiteDatabaseError(
                operation: "Inspect SQLite database family",
                code: SQLITE_IOERR,
                message: error.localizedDescription,
                path: url.path
            )
        }
        guard let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw SQLiteDatabaseError(
                operation: "Inspect SQLite database family",
                code: SQLITE_IOERR,
                message: "physical file identity is unavailable",
                path: url.path
            )
        }
        return Member(url: url, deviceID: deviceID, fileID: fileID)
    }

    private static func sidecarURL(for url: URL, suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }
}

final class SQLiteDatabaseDriver: DatabaseAccessing, @unchecked Sendable {
    let url: URL

    private let readOnly: Bool
    private let createsFileIfMissing: Bool
    private let busyTimeoutMilliseconds: Int32
    private let enableWAL: Bool
    private let fileManager: FileManager
    private let consistency: SQLiteConnectionConsistency

    init(
        url: URL,
        readOnly: Bool = false,
        createsFileIfMissing: Bool = true,
        busyTimeoutMilliseconds: Int32 = 3_000,
        enableWAL: Bool = false,
        fileManager: FileManager = .default,
        consistency: SQLiteConnectionConsistency = .ordinary
    ) {
        self.url = SQLiteDatabasePath.mainURL(for: url)
        self.readOnly = readOnly
        self.createsFileIfMissing = createsFileIfMissing
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.enableWAL = enableWAL
        self.fileManager = fileManager
        self.consistency = consistency
    }

    func readRows<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        try withConnection { connection in
            try connection.readRows(sql, bindings: bindings, map: map)
        }
    }

    func forEachRow(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        _ body: (SQLiteStatement) throws -> Void
    ) throws {
        try withConnection { connection in
            try connection.forEachRow(sql, bindings: bindings, body)
        }
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        try withConnection { connection in
            try connection.execute(sql, bindings: bindings)
        }
    }

    func executeChangedRows(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int {
        try withConnection { connection in
            try connection.executeChangedRows(sql, bindings: bindings)
        }
    }

    func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        try withConnection { connection in
            try connection.transaction(body)
        }
    }

    func withConnection<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        if consistency == .externallyOwnedWAL {
            guard readOnly else {
                throw SQLiteDatabaseError(
                    operation: "Coordinate external SQLite database",
                    code: SQLITE_MISUSE,
                    message: "externally-owned WAL consistency is read-only",
                    path: url.path
                )
            }
            return try SQLiteExternalWALConnectionCoordinator.shared.withExclusiveAccess {
                let beforeOpen = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                try beforeOpen.validateSafeToOpen()
                return try withUncoordinatedConnection { connection in
                    let afterOpen = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                    try beforeOpen.validateTransition(to: afterOpen)
                    let result = try body(connection)
                    let afterBody = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                    try afterOpen.validateTransition(to: afterBody)
                    return result
                }
            }
        }
        return try withUncoordinatedConnection(body)
    }

    private func withUncoordinatedConnection<T>(
        _ body: (SQLiteDatabaseConnection) throws -> T
    ) throws -> T {
        if !readOnly, createsFileIfMissing {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if !createsFileIfMissing {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue else {
                throw SQLiteDatabaseError(
                    operation: "Open SQLite database",
                    code: SQLITE_CANTOPEN,
                    message: "Database file does not exist; refusing to create it implicitly",
                    path: url.path
                )
            }
        }

        let flags: Int32
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        } else if createsFileIfMissing {
            flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        }

        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { Self.message(from: $0) } ?? "Unable to open database"
            let errorCode = database.map { Self.extendedErrorCode(from: $0, fallback: status) } ?? status
            let systemErrno = database.flatMap(Self.systemErrno(from:))
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteDatabaseError(
                operation: "Open SQLite database",
                code: errorCode,
                message: message,
                path: url.path,
                systemErrno: systemErrno
            )
        }
        defer { sqlite3_close_v2(database) }

        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)

        let connection = SQLiteDatabaseConnection(database: database, path: url.path)
        if enableWAL, !readOnly {
            try connection.execute("PRAGMA journal_mode=WAL;")
            try connection.execute("PRAGMA synchronous=NORMAL;")
        }
        return try body(connection)
    }

    fileprivate static func message(from database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "SQLite error"
        }
        return String(cString: message)
    }

    fileprivate static func extendedErrorCode(
        from database: OpaquePointer?,
        fallback: Int32
    ) -> Int32 {
        guard let database else { return fallback }
        let code = sqlite3_extended_errcode(database)
        return code == SQLITE_OK ? fallback : code
    }

    fileprivate static func systemErrno(from database: OpaquePointer?) -> Int32? {
        guard let database else { return nil }
        let value = sqlite3_system_errno(database)
        return value == 0 ? nil : value
    }
}

final class SQLitePersistentDatabaseReader: @unchecked Sendable {
    let url: URL

    private let busyTimeoutMilliseconds: Int32
    private let consistency: SQLiteConnectionConsistency
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(
        url: URL,
        busyTimeoutMilliseconds: Int32 = 100,
        consistency: SQLiteConnectionConsistency = .ordinary
    ) {
        self.url = SQLiteDatabasePath.mainURL(for: url)
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.consistency = consistency
    }

    deinit {
        lock.lock()
        if let database {
            sqlite3_close_v2(database)
        }
        database = nil
        lock.unlock()
    }

    func readRows<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        try withConnection { connection in
            try connection.readRows(sql, bindings: bindings, map: map)
        }
    }

    func withConnection<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        if consistency == .externallyOwnedWAL {
            return try SQLiteExternalWALConnectionCoordinator.shared.withExclusiveAccess {
                try withLockedConnection(releaseWhenFinished: true, body)
            }
        }
        return try withLockedConnection(releaseWhenFinished: false, body)
    }

    private func withLockedConnection<T>(
        releaseWhenFinished: Bool,
        _ body: (SQLiteDatabaseConnection) throws -> T
    ) throws -> T {
        lock.lock()
        defer {
            if releaseWhenFinished { closeDatabase() }
            lock.unlock()
        }

        return try SQLiteReadRecovery.run {
            do {
                let beforeRead = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                try beforeRead.validateSafeToOpen()
                let connection = SQLiteDatabaseConnection(database: try databaseHandle(), path: url.path)
                let afterOpen = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                try beforeRead.validateTransition(to: afterOpen)
                let result = try body(connection)
                let afterRead = try SQLiteDatabaseFamilySnapshot(databaseURL: url)
                try afterOpen.validateTransition(to: afterRead)
                return result
            } catch let error as SQLiteDatabaseError where error.isTransientReadFailure {
                closeDatabase()
                throw error
            }
        }
    }

    private func databaseHandle() throws -> OpaquePointer {
        if let database {
            return database
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { SQLiteDatabaseDriver.message(from: $0) } ?? "Unable to open database"
            let errorCode = opened.map {
                SQLiteDatabaseDriver.extendedErrorCode(from: $0, fallback: status)
            } ?? status
            let systemErrno = opened.flatMap(SQLiteDatabaseDriver.systemErrno(from:))
            if let opened {
                sqlite3_close(opened)
            }
            throw SQLiteDatabaseError(
                operation: "Open SQLite database",
                code: errorCode,
                message: message,
                path: url.path,
                systemErrno: systemErrno
            )
        }

        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        database = opened
        return opened
    }

    private func closeDatabase() {
        if let database {
            sqlite3_close_v2(database)
        }
        database = nil
    }
}

final class SQLiteDatabaseConnection: DatabaseAccessing {
    private let database: OpaquePointer?
    private let path: String?

    fileprivate init(database: OpaquePointer?, path: String?) {
        self.database = database
        self.path = path
    }

    func readRows<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw error(operation: "Prepare SQLite query", code: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [T] = []
        while true {
            let stepStatus = sqlite3_step(statement)
            if stepStatus == SQLITE_ROW {
                rows.append(try map(SQLiteStatement(raw: statement)))
            } else if stepStatus == SQLITE_DONE {
                return rows
            } else {
                throw error(operation: "Step SQLite query", code: stepStatus)
            }
        }
    }

    func forEachRow(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        _ body: (SQLiteStatement) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw error(operation: "Prepare SQLite query", code: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        // Long-running readers can bridge dates and strings for hundreds of thousands of rows.
        // Drain temporary Foundation objects in bounded batches without materializing the result set.
        let autoreleaseBatchSize = 512
        var isComplete = false
        while !isComplete {
            try autoreleasepool {
                for _ in 0..<autoreleaseBatchSize {
                    let stepStatus = sqlite3_step(statement)
                    if stepStatus == SQLITE_ROW {
                        try body(SQLiteStatement(raw: statement))
                    } else if stepStatus == SQLITE_DONE {
                        isComplete = true
                        break
                    } else {
                        throw error(operation: "Step SQLite query", code: stepStatus)
                    }
                }
            }
        }
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        if bindings.isEmpty {
            var rawError: UnsafeMutablePointer<Int8>?
            let status = sqlite3_exec(database, sql, nil, nil, &rawError)
            guard status == SQLITE_OK else {
                let message = rawError.map { String(cString: $0) } ?? SQLiteDatabaseDriver.message(from: database)
                sqlite3_free(rawError)
                throw SQLiteDatabaseError(operation: "Execute SQLite statement", code: status, message: message, path: path)
            }
            return
        }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw error(operation: "Prepare SQLite statement", code: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_DONE else {
            throw error(operation: "Execute SQLite statement", code: stepStatus)
        }
    }

    func executeChangedRows(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int {
        if bindings.isEmpty {
            let before = sqlite3_total_changes(database)
            try execute(sql)
            return Int(sqlite3_total_changes(database) - before)
        }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw error(operation: "Prepare SQLite statement", code: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        let before = sqlite3_total_changes(database)
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_DONE else {
            throw error(operation: "Execute SQLite statement", code: stepStatus)
        }
        return Int(sqlite3_total_changes(database) - before)
    }

    func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body(self)
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func readTransaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        try execute("BEGIN;")
        do {
            let result = try body(self)
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> SQLitePreparedStatement {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw error(operation: "Prepare SQLite statement", code: status)
        }
        return SQLitePreparedStatement(database: database, path: path, statement: statement)
    }

    func restoreDatabase(from sourceURL: URL) throws {
        var source: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let source else {
            if let source {
                sqlite3_close(source)
            }
            throw SQLiteDatabaseError(
                operation: "Open SQLite restore source",
                code: openStatus,
                message: SQLiteDatabaseDriver.message(from: source),
                path: sourceURL.path
            )
        }
        defer { sqlite3_close(source) }

        guard let backup = sqlite3_backup_init(database, "main", source, "main") else {
            throw error(
                operation: "Initialize SQLite restore",
                code: sqlite3_errcode(database)
            )
        }
        let stepStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw error(
                operation: "Restore SQLite database",
                code: stepStatus == SQLITE_DONE ? finishStatus : stepStatus
            )
        }
    }

    fileprivate func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .blob(let value):
                if value.isEmpty {
                    status = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    status = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement,
                            index,
                            bytes.baseAddress,
                            Int32(bytes.count),
                            sqliteTransient
                        )
                    }
                }
            case .text(let value):
                status = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .int(let value):
                status = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .int64(let value):
                status = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .double(let value):
                status = sqlite3_bind_double(statement, index, value)
            case .date(let value):
                status = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            }

            guard status == SQLITE_OK else {
                throw error(operation: "Bind SQLite value", code: status)
            }
        }
    }

    private func error(operation: String, code: Int32) -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: operation,
            code: SQLiteDatabaseDriver.extendedErrorCode(from: database, fallback: code),
            message: SQLiteDatabaseDriver.message(from: database),
            path: path,
            systemErrno: SQLiteDatabaseDriver.systemErrno(from: database)
        )
    }
}

final class SQLitePreparedStatement {
    private let database: OpaquePointer?
    private let path: String?
    private var statement: OpaquePointer?

    fileprivate init(database: OpaquePointer?, path: String?, statement: OpaquePointer?) {
        self.database = database
        self.path = path
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
        statement = nil
    }

    @discardableResult
    func execute(_ bindings: [SQLiteBinding] = []) throws -> Int {
        guard let statement else {
            throw SQLiteDatabaseError(
                operation: "Execute prepared SQLite statement",
                code: SQLITE_MISUSE,
                message: "Prepared statement is no longer available",
                path: path
            )
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let connection = SQLiteDatabaseConnection(database: database, path: path)
        try connection.bind(bindings, to: statement)

        let before = sqlite3_total_changes(database)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw SQLiteDatabaseError(
                operation: "Execute prepared SQLite statement",
                code: status,
                message: SQLiteDatabaseDriver.message(from: database),
                path: path
            )
        }
        return Int(sqlite3_total_changes(database) - before)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
