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
    /// Streams a single full precise refresh. The stream may yield a numeric
    /// projection before the complete attribution/detail snapshot; the
    /// default implementation preserves existing loaders by yielding only
    /// their final result.
    func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error>
    // 紧凑 surface 的轻量刷新（只跑三条 SUM SQL）；返回 nil 表示该数据源
    // 不支持轻量路径，调用方回退全量 loadSnapshot。
    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary?
    func acknowledgeAttributionSafety(
        dataSource: CodexDataSource,
        provenanceEpoch: String,
        throughGeneration: Int64
    ) async throws -> Bool
}

extension DashboardSnapshotLoading {
    func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                do {
                    let snapshot = try await self.loadSnapshot(dataSource: dataSource)
                    continuation.yield(snapshot)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        nil
    }

    func acknowledgeAttributionSafety(
        dataSource: CodexDataSource,
        provenanceEpoch: String,
        throughGeneration: Int64
    ) async throws -> Bool {
        false
    }
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

    func loadSnapshotPhases(
        dataSource: CodexDataSource
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let final = try CodexUsageAnalyzer(dataSource: dataSource).load(
                        onNumericPhase: { numeric in
                            continuation.yield(numeric)
                        }
                    )
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func loadCompactSummary(
        dataSource: CodexDataSource
    ) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource).loadCompactSummary()
        }.value
    }

    func acknowledgeAttributionSafety(
        dataSource: CodexDataSource,
        provenanceEpoch: String,
        throughGeneration: Int64
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource)
                .acknowledgeAttributionSafety(
                    provenanceEpoch: provenanceEpoch,
                    throughGeneration: throughGeneration
                )
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
