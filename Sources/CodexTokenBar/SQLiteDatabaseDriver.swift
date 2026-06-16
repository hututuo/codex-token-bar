import Foundation
import SQLite3

enum SQLiteBinding {
    case null
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

struct SQLiteDatabaseError: LocalizedError {
    let operation: String
    let code: Int32
    let message: String
    let path: String?

    var errorDescription: String? {
        if let path {
            return "\(operation) failed for \(path): \(message)"
        }
        return "\(operation) failed: \(message)"
    }
}

final class SQLiteDatabaseDriver: DatabaseAccessing, @unchecked Sendable {
    let url: URL

    private let readOnly: Bool
    private let busyTimeoutMilliseconds: Int32
    private let enableWAL: Bool
    private let fileManager: FileManager

    init(
        url: URL,
        readOnly: Bool = false,
        busyTimeoutMilliseconds: Int32 = 3_000,
        enableWAL: Bool = false,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.readOnly = readOnly
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.enableWAL = enableWAL
        self.fileManager = fileManager
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
        if !readOnly {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { Self.message(from: $0) } ?? "Unable to open database"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteDatabaseError(operation: "Open SQLite database", code: status, message: message, path: url.path)
        }
        defer { sqlite3_close(database) }

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

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .null:
                status = sqlite3_bind_null(statement, index)
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
            code: code,
            message: SQLiteDatabaseDriver.message(from: database),
            path: path
        )
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
