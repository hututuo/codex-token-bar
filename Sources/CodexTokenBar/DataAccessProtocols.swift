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

enum DashboardFastSnapshotFreshness: Equatable, Sendable {
    case current
    case staleCompatible
    case unavailable
}

enum PreciseIndexProgressPhase: String, Equatable, Sendable {
    case idle
    case waiting
    case preparing
    case migrating
    case scanning
    case backfillingModel
    case publishing
    case complete
    case failed
}

struct PreciseIndexProgress: Equatable, Sendable {
    let phase: PreciseIndexProgressPhase
    let message: String
    let completed: Int
    let total: Int?
    let fraction: Double?

    static let idle = PreciseIndexProgress(
        phase: .idle,
        message: "等待精确统计",
        completed: 0,
        total: nil,
        fraction: nil
    )

    init(
        phase: PreciseIndexProgressPhase,
        message: String,
        completed: Int,
        total: Int?,
        fraction: Double? = nil
    ) {
        self.phase = phase
        self.message = message
        let normalizedTotal = total.map { max(0, $0) }
        let normalizedCompleted = min(max(0, completed), normalizedTotal ?? max(0, completed))
        self.completed = normalizedCompleted
        self.total = normalizedTotal
        let resolvedFraction = fraction ?? normalizedTotal.flatMap { total in
            total > 0 ? Double(normalizedCompleted) / Double(total) : nil
        }
        self.fraction = resolvedFraction.map { min(max($0, 0), 1) }
    }

    var isActive: Bool {
        switch phase {
        case .idle, .complete:
            return false
        case .waiting, .preparing, .migrating, .scanning, .backfillingModel, .publishing, .failed:
            return true
        }
    }
}

protocol DashboardSnapshotProgressLoading: Sendable {
    func loadSnapshotPhases(
        dataSource: CodexDataSource,
        onProgress: @escaping @Sendable (PreciseIndexProgress) -> Void
    ) -> AsyncThrowingStream<DashboardSnapshot, Error>
}

struct DashboardFastSnapshotResult: Sendable {
    let snapshot: DashboardSnapshot
    let freshness: DashboardFastSnapshotFreshness
}

protocol DashboardSnapshotLoading: Sendable {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot
    /// Returns the same fast projection together with whether its exact
    /// numeric identity is current or a safe same-Home last-good value. The
    /// legacy method remains the required seam for existing loaders/tests.
    func loadFastSnapshotResult(
        dataSource: CodexDataSource
    ) async throws -> DashboardFastSnapshotResult
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
    func loadFastSnapshotResult(
        dataSource: CodexDataSource
    ) async throws -> DashboardFastSnapshotResult {
        let snapshot = try await loadFastSnapshot(dataSource: dataSource)
        return DashboardFastSnapshotResult(
            snapshot: snapshot,
            freshness: snapshot.hasPreciseTokenUsage ? .current : .unavailable
        )
    }

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

struct CodexDashboardSnapshotLoader: DashboardSnapshotLoading, DashboardSnapshotProgressLoading, Sendable {
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource).loadFastSnapshot()
        }.value
    }

    func loadFastSnapshotResult(
        dataSource: CodexDataSource
    ) async throws -> DashboardFastSnapshotResult {
        try await Task.detached(priority: .utility) {
            try CodexUsageAnalyzer(dataSource: dataSource).loadFastSnapshotResult()
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
                    // A newer numeric owner may supersede detail hydration.
                    // In that case `load` returns the already-published numeric
                    // projection and the stream completes without duplicating it.
                    if final.cacheUsage.attributionEventsComplete {
                        continuation.yield(final)
                    }
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

    func loadSnapshotPhases(
        dataSource: CodexDataSource,
        onProgress: @escaping @Sendable (PreciseIndexProgress) -> Void
    ) -> AsyncThrowingStream<DashboardSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    onProgress(PreciseIndexProgress(
                        phase: .preparing,
                        message: "正在计算索引规模，可能需要数分钟",
                        completed: 0,
                        total: nil
                    ))
                    let final = try CodexUsageAnalyzer(dataSource: dataSource).load(
                        onNumericPhase: { numeric in
                            continuation.yield(numeric)
                        },
                        onProgress: onProgress
                    )
                    let hasCompletePreciseSnapshot =
                        final.hasPreciseTokenUsage
                        && final.cacheUsage.attributionEventsComplete
                    if hasCompletePreciseSnapshot {
                        continuation.yield(final)
                        onProgress(PreciseIndexProgress(
                            phase: .complete,
                            message: "精确统计已更新",
                            completed: 1,
                            total: 1
                        ))
                    } else {
                        // `CodexUsageAnalyzer.load()` may intentionally return
                        // a metadata-only state SQLite projection when the
                        // selected Home has no token JSONL.  That projection is
                        // useful for the header, but it is not an exact phase:
                        // never advertise it as a successful precise refresh.
                        continuation.yield(final)
                        onProgress(PreciseIndexProgress(
                            phase: .failed,
                            message: "未发现可用 token JSONL，保留本地摘要（原始数据不会丢失）",
                            completed: 0,
                            total: nil
                        ))
                    }
                    continuation.finish()
                } catch {
                    let isMigrationFailure = (error as? CodexUsageHistoryIndexError)
                        .map { $0.operation.contains("升级") || $0.operation.contains("迁移") }
                        ?? false
                    onProgress(PreciseIndexProgress(
                        phase: .failed,
                        message: isMigrationFailure
                            ? "索引升级失败，原始数据不会丢失，保留上次可信数据"
                            : "精确统计失败，保留上次可信数据",
                        completed: 0,
                        total: nil
                    ))
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
