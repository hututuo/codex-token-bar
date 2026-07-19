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

protocol CodexDataSourceResolving {
    func resolve() -> CodexDataSource?
    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource?
}

extension CodexDataSourceResolver: CodexDataSourceResolving {}

protocol DashboardSnapshotLoading: Sendable {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot
    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot
}

struct CodexDashboardSnapshotLoader: DashboardSnapshotLoading, Sendable {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource).loadFastSnapshot()
        }.value
    }

    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource).load()
        }.value
    }
}

protocol QuotaReading: Sendable {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error>
}

protocol LiveRateLogReading: Sendable {
    var path: String { get }

    func globalLogRows(afterID: Int) throws -> [LiveRateMonitor.LogRow]
    func globalLogBatch(afterID: Int) throws -> LiveRateLogReadBatch
    func globalLogRows(since timestamp: TimeInterval) throws -> [LiveRateMonitor.LogRow]
}

struct LiveRateLogReadBatch: Sendable {
    let rows: [LiveRateMonitor.LogRow]
    let scannedThroughID: Int
}

extension LiveRateLogReading {
    func globalLogBatch(afterID: Int) throws -> LiveRateLogReadBatch {
        let rows = try globalLogRows(afterID: afterID)
        return LiveRateLogReadBatch(
            rows: rows,
            scannedThroughID: max(afterID, rows.last?.id ?? afterID)
        )
    }
}

protocol LiveRateLogReaderMaking: Sendable {
    func makeLiveRateLogReader(path: String) -> LiveRateLogReading
}

struct DefaultLiveRateLogReaderFactory: LiveRateLogReaderMaking, Sendable {
    func makeLiveRateLogReader(path: String) -> LiveRateLogReading {
        LiveRateLogDatabaseReader(path: path)
    }
}
