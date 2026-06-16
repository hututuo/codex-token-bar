import Foundation

protocol DatabaseAccessing {
    func readRows<T>(
        _ sql: String,
        bindings: [SQLiteBinding],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T]

    func execute(_ sql: String, bindings: [SQLiteBinding]) throws

    func transaction<T>(_ body: (SQLiteDatabaseConnection) throws -> T) throws -> T
}

extension DatabaseAccessing {
    func readRows<T>(
        _ sql: String,
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        try readRows(sql, bindings: [], map: map)
    }

    func execute(_ sql: String) throws {
        try execute(sql, bindings: [])
    }
}

protocol UsageDataSource {
    var codexHome: URL { get }
    var sessionsRoot: URL { get }
    var stateDatabase: URL { get }
}

extension CodexDataSource: UsageDataSource {}

protocol QuotaReading {
    func readQuota() async -> Result<AccountQuotaSnapshot, Error>
}
