import CryptoKit
import Darwin
import Foundation
import SQLite3

struct CodexUsageHistoryIndexError: LocalizedError, SQLiteTransientReadFailureReporting {
    let operation: String
    let underlying: Error

    var errorDescription: String? {
        "精确历史索引\(operation)失败：\(underlying.localizedDescription)"
    }

    var isTransientReadFailure: Bool {
        // The per-index owner uses a cross-process file lock in addition to
        // SQLite's own busy handling.  Contention is the same short-lived
        // read boundary from the store's point of view: retain last-good and
        // use the bounded recovery cadence instead of falling through to the
        // state SQLite projection.
        CodexCrossProcessFileLock.isContention(underlying)
            || SQLiteReadRecovery.isTransientReadFailure(underlying)
    }
}

struct CodexUsageSourceChangedError: LocalizedError {
    let path: String

    var errorDescription: String? {
        "会话文件在精确索引期间发生变化，将保留上一份完整结果并重试：\(path)"
    }
}

struct CodexUsageIndexUpgradeRequiredError: LocalizedError, Equatable, Sendable {
    let component: String
    let stored: String
    let supported: String

    var errorDescription: String? {
        "精确索引的\(component)版本为 \(stored)，属于当前软件无法识别的更新或未知版本（newer or unknown；当前仅支持 \(supported)）。需要升级软件；已停止写入和自动清理，原始 JSONL 不受影响。"
    }
}

extension CodexUsageAnalyzer {
    struct IndexedTokenEvent {
        let event: TokenEvent
        let sourceOffset: UInt64
        let userPromptOffset: UInt64?
        let assistantStartOffset: UInt64?
    }

    struct IndexedSessionParseResult {
        let eventCount: Int
        let lastOffset: UInt64
        let resumeOffset: UInt64
        let endedWithNewline: Bool
        let contentHash: String
        let state: IndexedSessionParserState
        let chunkHashes: [IndexedChunkHash]
        let validationChunkHash: IndexedChunkHash?
    }

    struct IndexedSessionParserState: Equatable {
        var previousTotalTokens: Int?
        var forkReplayStartedAt: Date?
        var isSkippingForkReplay: Bool
        var isExplicitSubagentFork: Bool
        var lastSkippedForkReplayTokenAt: Date?
        var currentUserPromptOffset: UInt64?
        var assistantStartOffset: UInt64?
        var currentModel: String?

        static let empty = IndexedSessionParserState(
            previousTotalTokens: nil,
            forkReplayStartedAt: nil,
            isSkippingForkReplay: false,
            isExplicitSubagentFork: false,
            lastSkippedForkReplayTokenAt: nil,
            currentUserPromptOffset: nil,
            assistantStartOffset: nil,
            currentModel: nil
        )
    }

    struct IndexedChunkHash: Equatable {
        let index: UInt64
        let byteCount: UInt64
        let sha256: String
    }

    struct IndexedSessionParseRequest {
        let hashingStartOffset: UInt64
        let parsingStartOffset: UInt64
        let endOffset: UInt64
        let validationBoundary: UInt64?
        let initialState: IndexedSessionParserState
        /// Process-local pinned source handle. It is never persisted; the
        /// caller owns and closes it after the synchronous parser returns.
        let readHandle: FileHandle?

        static func full(
            endOffset: UInt64,
            readHandle: FileHandle? = nil
        ) -> IndexedSessionParseRequest {
            IndexedSessionParseRequest(
                hashingStartOffset: 0,
                parsingStartOffset: 0,
                endOffset: endOffset,
                validationBoundary: nil,
                initialState: .empty,
                readHandle: readHandle
            )
        }
    }
}

final class CodexUsageHistoryIndex: @unchecked Sendable {
    enum MigrationAssessment: Equatable {
        case compatible
        case knownMigrationRequired(stages: [String])
        case upgradeRequired(component: String, stored: String, supported: String)
        case corrupt(component: String, rawValue: String)
    }
    struct StoredEvent {
        let stableID: String
        let event: TokenEvent
        let sourceID: Int64
        let sourceOffset: UInt64
    }

    struct AggregatedUsageRow {
        let start: Date
        let model: String?
        let breakdown: TokenCacheBreakdown
    }

    struct AggregatedSessionRow {
        let sessionID: String
        let lastUpdated: Date?
        let breakdown: TokenCacheBreakdown
    }

    struct TurnSourceReference {
        let stableID: String
        let file: URL
        let eventOffset: UInt64
        let userPromptOffset: UInt64?
        let assistantStartOffset: UInt64?
    }

    struct SynchronizationResult {
        let changedFiles: Int
        let unchangedFiles: Int
        let indexedEvents: Int
        let incrementallyParsedFiles: Int
        let rewrittenFiles: Int
        let removedFiles: Int
        let provenanceEpoch: String
        let attributionGeneration: Int64
        let attributionUnsafeSinceGeneration: Int64?
        let lineageAmbiguityDetected: Bool
        let attributionUnsafe: Bool
        let eventEnrichmentTotal: Int
        let eventEnrichmentComplete: Bool

        var attributionSourceMutationDetected: Bool {
            attributionUnsafe
        }
    }

    struct AttributionState: Equatable {
        let provenanceEpoch: String
        let generation: Int64
        let unsafeProvenanceEpoch: String?
        /// Monotonic generation of the latest distinct unsafe episode in this
        /// sticky provenance epoch. A persistent cause keeps the same token;
        /// a later false-to-true episode advances it so old recovery baselines
        /// cannot survive an ABA sequence.
        let unsafeSinceGeneration: Int64?
        /// Whether the most recent complete source-tree synchronization still
        /// observed a rewrite or unresolved lineage ambiguity. Sticky unsafe
        /// state may outlive this flag until its durable cutover is acknowledged.
        let currentScanUnsafeCauseDetected: Bool

        var requiresSyntheticCutover: Bool {
            unsafeProvenanceEpoch == provenanceEpoch
                && unsafeSinceGeneration != nil
        }
    }

    /// Existing durable derived-aggregate metadata used to validate complete
    /// numeric cache hits. This is a read-only view; it does not add index
    /// columns or a second aggregation state machine.
    struct DashboardAggregateIdentity: Codable, Equatable, Sendable {
        let schemaVersion: String?
        let pricingRevision: String?
        let exactGeneration: Int64?
        let publishedGeneration: Int64?
        let settledThrough: Int64?
    }

    struct SessionCatalogCandidate: Equatable {
        let file: URL
        let archived: Bool
    }

    struct SessionCatalogMetadata: Equatable {
        let threadID: String
        let cwd: String
        let sessionID: String?
        let forkedFromID: String?
        let parentThreadID: String?
        let source: String
    }

    struct SessionCatalogEntry: Equatable {
        let path: String
        let archived: Bool
        let metadata: SessionCatalogMetadata
        let sizeBytes: Int64
        let modifiedAt: Date
        let createdAt: Date
        let deviceID: UInt64
        let inode: UInt64
        let statusChangedSeconds: Int64
        let statusChangedNanoseconds: Int64
        let firstLineEndOffset: Int64
        let firstLineSHA256: String
        let lastSeenGeneration: String
    }

    struct SessionCatalogSynchronizationResult {
        let entries: [SessionCatalogEntry]
        let changedFiles: Int
        let unchangedFiles: Int
        let removedFiles: Int
        let parsedFirstLines: Int
    }

    typealias SessionCatalogParser = (
        _ file: URL
    ) throws -> SessionCatalogMetadata

    typealias SessionParser = (
        _ file: URL,
        _ sessionID: String,
        _ request: CodexUsageAnalyzer.IndexedSessionParseRequest,
        _ insertFingerprint: (CodexUsageAnalyzer.UsageSnapshotFingerprint) throws -> Bool,
        _ emit: (CodexUsageAnalyzer.IndexedTokenEvent) throws -> Void
    ) throws -> CodexUsageAnalyzer.IndexedSessionParseResult

    private struct SourceSignature: Equatable {
        let size: UInt64
        let modifiedAt: TimeInterval
        let contentProbe: String
        let deviceID: UInt64
        let inode: UInt64
        let statusChangedSeconds: Int64
        let statusChangedNanoseconds: Int64
    }

    private struct IndexedSource {
        let id: Int64
        let sessionID: String
        let signature: SourceSignature
        let checkpoint: SourceCheckpoint?
    }

    private struct SourceIdentity {
        let id: Int64
        let path: String
        let sessionID: String?
    }

    private struct SourceCheckpoint {
        let resumeOffset: UInt64
        let parserState: CodexUsageAnalyzer.IndexedSessionParserState
        let auditChunkIndex: UInt64
    }

    private struct FullRebuildJob {
        enum Reason {
            case sourceChange
            case eventEnrichment
        }

        let file: URL
        let sessionID: String
        let observedSignature: SourceSignature
        let reason: Reason
    }

    private struct StagedFullRebuild {
        let job: FullRebuildJob
        let databaseURL: URL
        let committedSignature: SourceSignature
        let artifactID: String
        let actualBytes: UInt64
        let eventCount: Int
        let fingerprintCount: Int
        let chunkCount: Int
        let resumeOffset: UInt64
        let parserState: CodexUsageAnalyzer.IndexedSessionParserState
    }

    private struct AttributionLineage {
        let key: String
        let canonicalSessionID: String?
    }

    private struct LineageReplacement {
        let sourceID: Int64
    }

    private enum AppendCheckpointError: Error {
        case rejected
    }

    private struct SessionCatalogFileSignature: Equatable {
        let sizeBytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let createdSeconds: Int64
        let createdNanoseconds: Int64
        let deviceID: UInt64
        let inode: UInt64
        let statusChangedSeconds: Int64
        let statusChangedNanoseconds: Int64

        var modifiedAt: Date {
            Date(
                timeIntervalSince1970: TimeInterval(modifiedSeconds)
                    + TimeInterval(modifiedNanoseconds) / 1_000_000_000
            )
        }

        var createdAt: Date {
            Date(
                timeIntervalSince1970: TimeInterval(createdSeconds)
                    + TimeInterval(createdNanoseconds) / 1_000_000_000
            )
        }
    }

    private struct IndexedSessionCatalogEntry {
        let entry: SessionCatalogEntry
        let signature: SessionCatalogFileSignature
    }

    private struct StagedSessionCatalogEntry {
        let entry: SessionCatalogEntry
        let signature: SessionCatalogFileSignature
    }

    private enum ExplicitSubagentSessionFileProbe {
        case explicit
        case nonExplicit
        case unresolved
    }

    private static let schemaVersion = "6"
    private static let inPlaceSchemaVersions: Set<String> = ["2", "3", "4", "5", "6"]
    private static let forkReplayBoundaryRevision = "explicit-subagent-delayed-context-v3"
    /// Bump whenever event parsing or source-bucket identity semantics change.
    /// Existing attribution ledgers then fail closed instead of reconciling
    /// contributions produced by incompatible parsers.
    private static let attributionProvenanceRevision = "source-bucket-v4-fork-replay-boundary-v2"
    /// Only revisions that were actually emitted by released/known builds may
    /// be upgraded in place.  Treat every other non-empty value as a future
    /// contract and fail before touching the ledger or its revision marker.
    private static let knownLegacyAttributionProvenanceRevisions: Set<String> = [
        "legacy-ledger-v1",
        "source-bucket-v2-incremental-parser-v1",
        "source-bucket-v3-model-aware-parser-v1",
    ]
    private static let eventEnrichmentRevisionKey = "event_enrichment_revision"
    private static let eventEnrichmentRevision = "model-v1"
    // Turn candidates are grouped by the originating user message, and their
    // cache denominator uses the latest current-context snapshot. Bump the
    // disposable aggregate version whenever that ranking contract changes so
    // older event-level rows cannot remain in the projection.
    private static let dashboardAggregateSchemaVersion = "5"
    private static let dashboardAggregatePricingRevision = "raw-token-v1"
    private static let knownDashboardAggregatePricingRevisions: Set<String> = [
        "raw-token-v0",
        dashboardAggregatePricingRevision,
    ]

    struct PersistentSnapshotCompatibility: Equatable, Sendable {
        let indexSchemaVersion: String
        let parserRevision: String
        let provenanceRevision: String
    }

    /// One source of truth for deciding whether a persisted numeric snapshot
    /// can be reused after an upgrade. Keeping these identities beside the
    /// index/parser revisions prevents a future parser bump from silently
    /// leaving the fast-start compatibility gate on an older literal.
    static var persistentSnapshotCompatibility: PersistentSnapshotCompatibility {
        PersistentSnapshotCompatibility(
            indexSchemaVersion: schemaVersion,
            parserRevision: "token-event-v2-\(forkReplayBoundaryRevision)",
            provenanceRevision: attributionProvenanceRevision
        )
    }

    private static let sessionCatalogSchemaVersion = "1"
    private static let chunkSize: UInt64 = 4 * 1_024 * 1_024
    private static let stagingMaxWorkers = 4
    private static let stagingMaxReadyArtifacts = 8
    private static let stagingMaxReadyBytes: UInt64 = 512 * 1_024 * 1_024
    private static let stagingMinimumFreeReserveBytes: Int64 = 64 * 1_024 * 1_024
    /// Leave headroom for SQLite pages, indexes, and the ready manifest so a
    /// normal multi-file batch stays below the hard ready-artifact byte cap.
    private static let stagingPlannedReadyBytes: UInt64 = 448 * 1_024 * 1_024
    private static let stagingManifestSchemaVersion = 1
    private static let stagingManifestIntegrity = "sqlite-quick-check-v1"
    private static let stagingParserRevision = "token-event-v2-\(forkReplayBoundaryRevision)"
    private static let explicitSubagentFirstLineLimit = 256 * 1_024
    private static let cacheDirectoryName = "CodexTokenBarSwift"
    private static let indexNamespace = "exact-usage-history-v1"
    private static let cacheDirectoryEnvironmentKey = "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"
    private static let disabledCacheEnvironmentKey = "CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"
    private static let operationLocks = CodexUsageHistoryIndexOperationLockRegistry()
    private static let operationLockTimeoutState = CodexUsageHistoryIndexLockTimeoutState()
    private static let stagingTestState = CodexUsageHistoryStagingTestState()
    private static let sessionCatalogPublishTestState =
        CodexSessionCatalogPublishTestState()
    private static let sourceProbeTestState = CodexUsageHistorySourceProbeTestState()
    private static let ephemeralRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexTokenBarSwift-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        .appendingPathComponent(indexNamespace, isDirectory: true)

    private let driver: SQLiteDatabaseDriver
    private let fileManager: FileManager
    private let operationGate: CodexUsageHistoryIndexOperationGate

    convenience init(
        codexHome: URL,
        fileManager: FileManager = .default,
        onProgress: ((PreciseIndexProgress) -> Void)? = nil
    ) throws {
        let databaseURL = Self.databaseURL(for: codexHome)
        try self.init(databaseURL: databaseURL, fileManager: fileManager, onProgress: onProgress)
    }

    convenience init(
        sessionCatalogTestingDatabaseURL databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try self.init(databaseURL: databaseURL, fileManager: fileManager)
    }

    private init(
        databaseURL: URL,
        fileManager: FileManager,
        onProgress: ((PreciseIndexProgress) -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        operationGate = Self.operationGate(for: databaseURL)
        driver = SQLiteDatabaseDriver(
            url: databaseURL,
            busyTimeoutMilliseconds: 30_000,
            enableWAL: true,
            fileManager: fileManager
        )
        try withExclusiveAccess {
            switch try Self.assessMigration(
                databaseURL: databaseURL,
                fileManager: fileManager
            ) {
            case .compatible, .knownMigrationRequired:
                break
            case let .upgradeRequired(component, stored, supported):
                throw CodexUsageIndexUpgradeRequiredError(
                    component: component,
                    stored: stored,
                    supported: supported
                )
            case let .corrupt(component, rawValue):
                throw SQLiteDatabaseError(
                    operation: "Assess exact usage index compatibility",
                    code: SQLITE_CORRUPT,
                    message: "\(component) marker is corrupt: \(rawValue)",
                    path: databaseURL.path
                )
            }
            // Normal schema reads already make SQLite validate every page they
            // touch. Running PRAGMA quick_check over the entire hundreds-of-MiB
            // history database at every Swift process launch delayed cached data and
            // turned a transient read failure into an apparent startup outage.
            // Fail closed and preserve the database on any error; explicit
            // recovery can inspect the original bytes instead of silently
            // deleting the user's only published index.
            try prepareSchema(onProgress: onProgress)
        }
    }

    private static func assessMigration(
        databaseURL: URL,
        fileManager: FileManager
    ) throws -> MigrationAssessment {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .compatible
        }
        let readOnly = SQLiteDatabaseDriver(
            url: databaseURL,
            readOnly: true,
            busyTimeoutMilliseconds: 1_000,
            fileManager: fileManager
        )
        return try readOnly.withConnection { connection in
            let schemaMetaExists = try connection.readRows(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta');"
            ) { ($0.int(0) ?? 0) != 0 }.first ?? false
            if !schemaMetaExists {
                let hasUserTables = try connection.readRows(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%');"
                ) { ($0.int(0) ?? 0) != 0 }.first ?? false
                return hasUserTables
                    ? .corrupt(component: "schema_version", rawValue: "missing schema_meta")
                    : .compatible
            }
            func meta(_ key: String) throws -> String? {
                try connection.readRows(
                    "SELECT value FROM schema_meta WHERE key = ? LIMIT 1;",
                    bindings: [.text(key)]
                ) { $0.text(0) }.first ?? nil
            }
            let rawSchema = try meta("schema_version")
            if let rawSchema, Int(rawSchema) == nil {
                return .corrupt(component: "schema_version", rawValue: rawSchema)
            }
            if let rawSchema,
               let stored = Int(rawSchema),
               let supported = Int(schemaVersion),
               stored > supported {
                return .upgradeRequired(
                    component: "主 schema",
                    stored: rawSchema,
                    supported: schemaVersion
                )
            }
            if let replay = try meta("fork_replay_boundary_revision"),
               replay != forkReplayBoundaryRevision {
                return .upgradeRequired(
                    component: "fork replay",
                    stored: replay,
                    supported: forkReplayBoundaryRevision
                )
            }
            if let provenance = try meta("provenance_revision"),
               provenance != attributionProvenanceRevision,
               !knownLegacyAttributionProvenanceRevisions.contains(provenance) {
                return .upgradeRequired(
                    component: "归因 provenance",
                    stored: provenance,
                    supported: attributionProvenanceRevision
                )
            }
            if let enrichment = try meta(eventEnrichmentRevisionKey),
               enrichment != eventEnrichmentRevision {
                return .upgradeRequired(
                    component: "模型补全",
                    stored: enrichment,
                    supported: eventEnrichmentRevision
                )
            }
            if let aggregate = try meta("dashboard_aggregate_schema_version") {
                guard let stored = Int(aggregate) else {
                    return .corrupt(
                        component: "aggregate schema",
                        rawValue: aggregate
                    )
                }
                if stored > Int(dashboardAggregateSchemaVersion)! {
                    return .upgradeRequired(
                        component: "aggregate schema",
                        stored: aggregate,
                        supported: dashboardAggregateSchemaVersion
                    )
                }
            }
            if let pricing = try meta("dashboard_aggregate_pricing_revision"),
               !knownDashboardAggregatePricingRevisions.contains(pricing) {
                return .upgradeRequired(
                    component: "aggregate pricing",
                    stored: pricing,
                    supported: dashboardAggregatePricingRevision
                )
            }
            let sessionCatalogMetaExists = try connection.readRows(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_catalog_meta');"
            ) { ($0.int(0) ?? 0) != 0 }.first ?? false
            if sessionCatalogMetaExists {
                let catalog = try connection.readRows(
                    "SELECT value FROM session_catalog_meta WHERE key = 'schema_version' LIMIT 1;"
                ) { $0.text(0) }.first ?? nil
                if let catalog, catalog != sessionCatalogSchemaVersion {
                    return .upgradeRequired(
                        component: "session catalog schema（会话目录）",
                        stored: catalog,
                        supported: sessionCatalogSchemaVersion
                    )
                }
            }
            let enrichmentReceiptExists = try connection.readRows(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'event_enrichment_sources');"
            ) { ($0.int(0) ?? 0) != 0 }.first ?? false
            if enrichmentReceiptExists {
                let columns = Set(try connection.readRows(
                    "PRAGMA table_info(event_enrichment_sources);"
                ) { $0.text(1) ?? "" })
                if columns.contains("revision") {
                    let revisions = try connection.readRows(
                        "SELECT DISTINCT revision FROM event_enrichment_sources WHERE revision <> '';"
                    ) { $0.text(0) }.compactMap { $0 }
                    if let unknown = revisions.first(where: {
                        $0 != eventEnrichmentRevision
                    }) {
                        return .upgradeRequired(
                            component: "模型补全 receipt",
                            stored: unknown,
                            supported: eventEnrichmentRevision
                        )
                    }
                }
                if columns.contains("parser_revision") {
                    let revisions = try connection.readRows(
                        "SELECT DISTINCT parser_revision FROM event_enrichment_sources WHERE parser_revision <> '';"
                    ) { $0.text(0) }.compactMap { $0 }
                    if let unknown = revisions.first(where: {
                        $0 != stagingParserRevision
                    }) {
                        return .upgradeRequired(
                            component: "模型补全 parser receipt",
                            stored: unknown,
                            supported: stagingParserRevision
                        )
                    }
                }
            }
            var stages: [String] = []
            if rawSchema != schemaVersion { stages.append("schema") }
            if try meta("fork_replay_boundary_revision") != forkReplayBoundaryRevision {
                stages.append("forkReplay")
            }
            if try meta("provenance_revision") != attributionProvenanceRevision {
                stages.append("attributionLedger")
            }
            if try meta(eventEnrichmentRevisionKey) != eventEnrichmentRevision {
                stages.append("eventEnrichment")
            }
            if !sessionCatalogMetaExists { stages.append("sessionCatalog") }
            if try meta("dashboard_aggregate_schema_version")
                != dashboardAggregateSchemaVersion {
                stages.append("aggregate")
            }
            return stages.isEmpty
                ? .compatible
                : .knownMigrationRequired(stages: stages)
        }
    }

    static func withExclusiveAccess<T>(
        codexHome: URL,
        _ body: () throws -> T
    ) throws -> T {
        try operationGate(for: databaseURL(for: codexHome)).withLock(body)
    }

    /// Explicit user-authorized recovery for an index produced by a newer app.
    /// Only Token Bar's derived Swift index family and its staging artifacts
    /// are removed. Raw Codex JSONL, state_5.sqlite, preferences, quota history,
    /// and radar caches are outside this namespace and are never touched.
    static func rebuildDerivedIndex(
        codexHome: URL,
        fileManager: FileManager = .default
    ) throws {
        let databaseURL = databaseURL(for: codexHome)
        try operationGate(for: databaseURL).withLock {
            for url in [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
                URL(fileURLWithPath: databaseURL.path + "-shm"),
            ] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            let stagingDirectory = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent(databaseURL.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
        }
    }

    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try operationGate.withLock(body)
    }

    static func waitForExclusiveAccessWaiterForTesting(
        codexHome: URL,
        timeout: TimeInterval
    ) -> Bool {
        operationGate(for: databaseURL(for: codexHome))
            .waitForPendingAcquisition(timeout: timeout)
    }

    static func liveOperationGateCountForTesting() -> Int {
        operationLocks.liveLockCount
    }

    static func setOperationLockTimeoutForTesting(_ timeout: TimeInterval?) {
        operationLockTimeoutState.set(timeout)
    }

    fileprivate static var operationLockTimeout: TimeInterval {
        operationLockTimeoutState.value ?? 30
    }

    static func failNextImportAfterStagingForTesting() {
        stagingTestState.armFailure()
    }

    static func failNextBatchAfterFirstImportForTesting() {
        stagingTestState.armBatchImportFailure()
    }

    static func failNextSessionCatalogPublishForTesting() {
        sessionCatalogPublishTestState.armFailure()
    }

    static func resetSourceContentProbeCountForTesting() {
        sourceProbeTestState.reset()
    }

    static func resetSynchronizationInvocationCountForTesting() {
        sourceProbeTestState.resetSynchronizationCount()
    }

    static var sourceContentProbeCountForTesting: Int {
        sourceProbeTestState.count
    }

    static var synchronizationInvocationCountForTesting: Int {
        sourceProbeTestState.synchronizationCount
    }

    // 冷建 heavy 文件阈值（与 Rust PARALLEL_HEAVY_FILE_BYTES 同值）。
    // 测试可注入小阈值，用小文件驱动 heavy/light 双通道调度行为。
    var coldBuildHeavyFileThreshold: UInt64 = 512 * 1_024 * 1_024

    func synchronize(
        files: [URL],
        sessionID: (URL) -> String,
        parser: @escaping SessionParser,
        onProgress: ((Int, Int, PreciseIndexProgressPhase) -> Void)? = nil
    ) throws -> SynchronizationResult {
        Self.sourceProbeTestState.recordSynchronization()
        return try withExclusiveAccess {
            try synchronizeExclusively(
                files: files,
                sessionID: sessionID,
                parser: parser,
                onProgress: onProgress
            )
        }
    }

    func attributionState() throws -> AttributionState {
        try driver.withConnection { connection in
            try configure(connection)
            return try currentAttributionState(connection: connection)
        }
    }

    func dashboardAggregateIdentity() throws -> DashboardAggregateIdentity {
        try driver.withConnection { connection in
            try configure(connection)
            func meta(_ key: String) throws -> String? {
                try connection.readRows(
                    "SELECT value FROM schema_meta WHERE key = ? LIMIT 1;",
                    bindings: [.text(key)]
                ) { $0.text(0) }.first ?? nil
            }
            func generation(_ key: String) throws -> Int64? {
                guard let raw = try meta(key) else { return nil }
                guard let value = Int64(raw), value >= 0 else {
                    throw SQLiteDatabaseError(
                        operation: "Read dashboard aggregate lineage",
                        code: SQLITE_MISMATCH,
                        message: "Dashboard aggregate metadata \(key) is invalid: \(raw)",
                        path: driver.url.path
                    )
                }
                return value
            }
            func integer(_ key: String) throws -> Int64? {
                guard let raw = try meta(key) else { return nil }
                guard let value = Int64(raw) else {
                    throw SQLiteDatabaseError(
                        operation: "Read dashboard aggregate lineage",
                        code: SQLITE_MISMATCH,
                        message: "Dashboard aggregate metadata \(key) is invalid: \(raw)",
                        path: driver.url.path
                    )
                }
                return value
            }
            return DashboardAggregateIdentity(
                schemaVersion: try meta("dashboard_aggregate_schema_version"),
                pricingRevision: try meta("dashboard_aggregate_pricing_revision"),
                exactGeneration: try generation("dashboard_aggregate_exact_generation"),
                publishedGeneration: try generation("dashboard_aggregate_published_generation"),
                settledThrough: try integer("dashboard_aggregate_settled_through")
            )
        }
    }

    func eventEnrichmentIsComplete() throws -> Bool {
        try driver.withConnection { connection in
            try configure(connection)
            let storedRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = ? LIMIT 1;",
                bindings: [.text(Self.eventEnrichmentRevisionKey)]
            ) { $0.text(0) }.first ?? nil
            guard storedRevision == Self.eventEnrichmentRevision else {
                return false
            }
            return try eventEnrichmentPendingSourceIDs(connection: connection).isEmpty
        }
    }

    @discardableResult
    func acknowledgeAttributionSafety(
        provenanceEpoch: String,
        throughGeneration: Int64
    ) throws -> Bool {
        try withExclusiveAccess {
            try driver.withConnection { connection in
                try configure(connection)
                return try connection.transaction { transaction in
                    let state = try currentAttributionState(connection: transaction)
                    guard state.provenanceEpoch == provenanceEpoch,
                          state.requiresSyntheticCutover,
                          !state.currentScanUnsafeCauseDetected,
                          let unsafeSinceGeneration = state.unsafeSinceGeneration,
                          throughGeneration >= unsafeSinceGeneration,
                          throughGeneration >= state.generation else {
                        return false
                    }
                    try transaction.execute(
                        """
                        DELETE FROM schema_meta
                        WHERE key IN (
                            'attribution_unsafe_epoch',
                            'attribution_unsafe_generation'
                        );
                        """
                    )
                    _ = try bumpAttributionGeneration(connection: transaction)
                    return true
                }
            }
        }
    }

    func sessionCatalogEntries() throws -> [SessionCatalogEntry] {
        try readSessionCatalogEntriesExclusively()
            .map(\.entry)
            .sorted { $0.path < $1.path }
    }

    func synchronizeSessionCatalog(
        candidates: [SessionCatalogCandidate],
        parser: @escaping SessionCatalogParser
    ) throws -> SessionCatalogSynchronizationResult {
        try withExclusiveAccess {
            let generation = UUID().uuidString
            let existing = Dictionary(
                uniqueKeysWithValues: try readSessionCatalogEntriesExclusively()
                    .map { ($0.entry.path, $0) }
            )
            var candidateByPath: [String: SessionCatalogCandidate] = [:]
            for candidate in candidates {
                let path = candidate.file.standardizedFileURL.path
                candidateByPath[path] = SessionCatalogCandidate(
                    file: URL(fileURLWithPath: path),
                    archived: candidate.archived
                )
            }

            var staged: [StagedSessionCatalogEntry] = []
            var unchangedFiles = 0
            var parsedFirstLines = 0
            for path in candidateByPath.keys.sorted() {
                guard let candidate = candidateByPath[path] else { continue }
                let observed = try sessionCatalogFileSignature(for: candidate.file)
                if let current = existing[path],
                   current.signature == observed,
                   current.entry.archived == candidate.archived {
                    unchangedFiles += 1
                    continue
                }

                let metadata = try parser(candidate.file)
                parsedFirstLines += 1
                let firstLine = try sessionCatalogFirstLineFingerprint(
                    for: candidate.file
                )
                let committed = try sessionCatalogFileSignature(for: candidate.file)
                guard committed == observed else {
                    throw CodexUsageSourceChangedError(path: path)
                }
                staged.append(
                    StagedSessionCatalogEntry(
                        entry: SessionCatalogEntry(
                            path: path,
                            archived: candidate.archived,
                            metadata: metadata,
                            sizeBytes: committed.sizeBytes,
                            modifiedAt: committed.modifiedAt,
                            createdAt: committed.createdAt,
                            deviceID: committed.deviceID,
                            inode: committed.inode,
                            statusChangedSeconds:
                                committed.statusChangedSeconds,
                            statusChangedNanoseconds:
                                committed.statusChangedNanoseconds,
                            firstLineEndOffset: firstLine.endOffset,
                            firstLineSHA256: firstLine.sha256,
                            lastSeenGeneration: generation
                        ),
                        signature: committed
                    )
                )
            }

            let removedPaths = Set(existing.keys).subtracting(candidateByPath.keys)
            if staged.isEmpty, removedPaths.isEmpty {
                return SessionCatalogSynchronizationResult(
                    entries: existing.values
                        .map(\.entry)
                        .sorted { $0.path < $1.path },
                    changedFiles: 0,
                    unchangedFiles: unchangedFiles,
                    removedFiles: 0,
                    parsedFirstLines: 0
                )
            }
            try driver.withConnection { connection in
                try configure(connection)
                try connection.transaction { transaction in
                    let upsert = try transaction.prepare(
                        """
                        INSERT INTO session_catalog_entries (
                            path, archived, thread_id, cwd, session_id,
                            forked_from_id, parent_thread_id, source,
                            size_bytes, modified_seconds, modified_nanoseconds,
                            created_seconds, created_nanoseconds,
                            device_id, inode, status_changed_seconds,
                            status_changed_nanoseconds, first_line_end_offset,
                            first_line_sha256, last_seen_generation
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        )
                        ON CONFLICT(path) DO UPDATE SET
                            archived = excluded.archived,
                            thread_id = excluded.thread_id,
                            cwd = excluded.cwd,
                            session_id = excluded.session_id,
                            forked_from_id = excluded.forked_from_id,
                            parent_thread_id = excluded.parent_thread_id,
                            source = excluded.source,
                            size_bytes = excluded.size_bytes,
                            modified_seconds = excluded.modified_seconds,
                            modified_nanoseconds = excluded.modified_nanoseconds,
                            created_seconds = excluded.created_seconds,
                            created_nanoseconds = excluded.created_nanoseconds,
                            device_id = excluded.device_id,
                            inode = excluded.inode,
                            status_changed_seconds = excluded.status_changed_seconds,
                            status_changed_nanoseconds = excluded.status_changed_nanoseconds,
                            first_line_end_offset = excluded.first_line_end_offset,
                            first_line_sha256 = excluded.first_line_sha256,
                            last_seen_generation = excluded.last_seen_generation;
                        """
                    )
                    for stagedEntry in staged {
                        let entry = stagedEntry.entry
                        let signature = stagedEntry.signature
                        _ = try upsert.execute([
                            .text(entry.path),
                            .int(entry.archived ? 1 : 0),
                            .text(entry.metadata.threadID),
                            .text(entry.metadata.cwd),
                            .optionalText(entry.metadata.sessionID),
                            .optionalText(entry.metadata.forkedFromID),
                            .optionalText(entry.metadata.parentThreadID),
                            .text(entry.metadata.source),
                            .int64(signature.sizeBytes),
                            .int64(signature.modifiedSeconds),
                            .int64(signature.modifiedNanoseconds),
                            .int64(signature.createdSeconds),
                            .int64(signature.createdNanoseconds),
                            .text(String(signature.deviceID)),
                            .text(String(signature.inode)),
                            .int64(signature.statusChangedSeconds),
                            .int64(signature.statusChangedNanoseconds),
                            .int64(entry.firstLineEndOffset),
                            .text(entry.firstLineSHA256),
                            .text(generation),
                        ])
                    }
                    let remove = try transaction.prepare(
                        "DELETE FROM session_catalog_entries WHERE path = ?;"
                    )
                    for path in removedPaths.sorted() {
                        _ = try remove.execute([.text(path)])
                    }
                    if Self.sessionCatalogPublishTestState.consumeFailure() {
                        throw SQLiteDatabaseError(
                            operation:
                                "Injected session catalog publication interruption",
                            code: SQLITE_ABORT,
                            message:
                                "Testing interruption before session catalog publication",
                            path: driver.url.path
                        )
                    }
                    try transaction.execute(
                        """
                        INSERT INTO session_catalog_meta(key, value)
                        VALUES ('published_generation', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [.text(generation)]
                    )
                }
            }
            let entries = try readSessionCatalogEntriesExclusively()
                .map(\.entry)
                .sorted { $0.path < $1.path }
            return SessionCatalogSynchronizationResult(
                entries: entries,
                changedFiles: staged.count,
                unchangedFiles: unchangedFiles,
                removedFiles: removedPaths.count,
                parsedFirstLines: parsedFirstLines
            )
        }
    }

    private func readSessionCatalogEntriesExclusively() throws
        -> [IndexedSessionCatalogEntry] {
        try driver.withConnection { connection in
            try configure(connection)
            return try connection.readRows(
                """
                SELECT
                    path,
                    archived,
                    thread_id,
                    cwd,
                    session_id,
                    forked_from_id,
                    parent_thread_id,
                    source,
                    size_bytes,
                    modified_seconds,
                    modified_nanoseconds,
                    created_seconds,
                    created_nanoseconds,
                    device_id,
                    inode,
                    status_changed_seconds,
                    status_changed_nanoseconds,
                    first_line_end_offset,
                    first_line_sha256,
                    last_seen_generation
                FROM session_catalog_entries
                ORDER BY path;
                """
            ) { row -> IndexedSessionCatalogEntry in
                guard let path = row.text(0),
                      let threadID = row.text(2),
                      let cwd = row.text(3),
                      let source = row.text(7),
                      let sizeBytes = row.int64(8),
                      let modifiedSeconds = row.int64(9),
                      let modifiedNanoseconds = row.int64(10),
                      let createdSeconds = row.int64(11),
                      let createdNanoseconds = row.int64(12),
                      let deviceIDText = row.text(13),
                      let deviceID = UInt64(deviceIDText),
                      let inodeText = row.text(14),
                      let inode = UInt64(inodeText),
                      let statusChangedSeconds = row.int64(15),
                      let statusChangedNanoseconds = row.int64(16),
                      let firstLineEndOffset = row.int64(17),
                      let firstLineSHA256 = row.text(18),
                      let lastSeenGeneration = row.text(19) else {
                    throw SQLiteDatabaseError(
                        operation: "Read session catalog entry",
                        code: SQLITE_CORRUPT,
                        message: "Session catalog row is incomplete",
                        path: driver.url.path
                    )
                }
                let signature = SessionCatalogFileSignature(
                    sizeBytes: sizeBytes,
                    modifiedSeconds: modifiedSeconds,
                    modifiedNanoseconds: modifiedNanoseconds,
                    createdSeconds: createdSeconds,
                    createdNanoseconds: createdNanoseconds,
                    deviceID: deviceID,
                    inode: inode,
                    statusChangedSeconds: statusChangedSeconds,
                    statusChangedNanoseconds: statusChangedNanoseconds
                )
                return IndexedSessionCatalogEntry(
                    entry: SessionCatalogEntry(
                        path: path,
                        archived: (row.int(1) ?? 0) != 0,
                        metadata: SessionCatalogMetadata(
                            threadID: threadID,
                            cwd: cwd,
                            sessionID: row.text(4),
                            forkedFromID: row.text(5),
                            parentThreadID: row.text(6),
                            source: source
                        ),
                        sizeBytes: sizeBytes,
                        modifiedAt: signature.modifiedAt,
                        createdAt: signature.createdAt,
                        deviceID: deviceID,
                        inode: inode,
                        statusChangedSeconds: statusChangedSeconds,
                        statusChangedNanoseconds: statusChangedNanoseconds,
                        firstLineEndOffset: firstLineEndOffset,
                        firstLineSHA256: firstLineSHA256,
                        lastSeenGeneration: lastSeenGeneration
                    ),
                    signature: signature
                )
            }
        }
    }

    private func sessionCatalogFileSignature(
        for file: URL
    ) throws -> SessionCatalogFileSignature {
        var value = stat()
        guard Darwin.lstat(file.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
        return SessionCatalogFileSignature(
            sizeBytes: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            createdSeconds: Int64(value.st_birthtimespec.tv_sec),
            createdNanoseconds: Int64(value.st_birthtimespec.tv_nsec),
            deviceID: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            statusChangedSeconds: Int64(value.st_ctimespec.tv_sec),
            statusChangedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private func sessionCatalogFirstLineFingerprint(
        for file: URL
    ) throws -> (endOffset: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        var endOffset: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                let prefix = Data(chunk[..<newline])
                hasher.update(data: prefix)
                endOffset += Int64(prefix.count) + 1
                return (
                    endOffset,
                    hasher.finalize()
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            }
            hasher.update(data: chunk)
            endOffset += Int64(chunk.count)
        }
        return (
            endOffset,
            hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func synchronizeExclusively(
        files: [URL],
        sessionID: (URL) -> String,
        parser: @escaping SessionParser,
        onProgress: ((Int, Int, PreciseIndexProgressPhase) -> Void)? = nil
    ) throws -> SynchronizationResult {
        let generation = UUID().uuidString
        let canonicalFiles = files.map { $0.resolvingSymlinksInPath() }
        let observedPaths = Set(canonicalFiles.map(\.path))
        var changedFiles = 0
        var unchangedFiles = 0
        var indexedEvents = 0
        var incrementallyParsedFiles = 0
        var rewrittenFiles = 0
        var removedFiles = 0
        var fullRebuildJobs: [FullRebuildJob] = []
        let canonicalLineageCounts = Dictionary(
            grouping: canonicalFiles.compactMap { file in
                canonicalSessionID(sessionID(file))
            },
            by: { $0 }
        )
        var lineageAmbiguityDetected = canonicalLineageCounts.values.contains {
            $0.count > 1
        }
        var sourceMutationDetected = false
        var dirtyTurnCandidateSessions = Set<String>()
        var eventEnrichmentTotal = 0

        onProgress?(
            0,
            canonicalFiles.count,
            .scanning
        )

        try driver.withConnection { connection in
            try configure(connection)
            let indexedSources = try indexedSources(connection: connection)
            let enrichmentPendingSourceIDs = try eventEnrichmentPendingSourceIDs(
                connection: connection
            )
            eventEnrichmentTotal = enrichmentPendingSourceIDs.count

            for file in canonicalFiles {
                try autoreleasepool {
                    let path = file.path
                    let existing = indexedSources[path]
                    let observedMetadata = try sourceSignatureMetadata(for: file)
                    if let existing,
                       enrichmentPendingSourceIDs.contains(existing.id) {
                        let observed = try sourceSignature(
                            metadata: observedMetadata,
                            for: file
                        )
                        let isStablePublishedPrefix = observed.deviceID
                                == existing.signature.deviceID
                            && observed.inode == existing.signature.inode
                            && observed.size >= existing.signature.size
                        if !isStablePublishedPrefix || existing.checkpoint == nil {
                            rewrittenFiles += 1
                        }
                        // Replay migration intentionally clears the source
                        // checkpoint. In that state this is not a bounded
                        // enrichment pass: rebuild the source at the current
                        // formal size so bytes appended after migration are
                        // included in the same targeted recovery.
                        let canReusePublishedPrefix =
                            isStablePublishedPrefix && existing.checkpoint != nil
                        dirtyTurnCandidateSessions.insert(existing.sessionID)
                        dirtyTurnCandidateSessions.insert(sessionID(file))
                        fullRebuildJobs.append(
                            FullRebuildJob(
                                file: file,
                                sessionID: sessionID(file),
                                observedSignature: canReusePublishedPrefix
                                    ? existing.signature
                                    : observed,
                                reason: canReusePublishedPrefix
                                    ? .eventEnrichment
                                    : .sourceChange
                            )
                        )
                        return
                    }
                    if let existing,
                       isTrustedContentProbe(existing.signature.contentProbe),
                       sourceMetadataMatches(existing.signature, observedMetadata) {
                        unchangedFiles += 1
                        return
                    }
                    let observed = try sourceSignature(
                        metadata: observedMetadata,
                        for: file
                    )

                    let parsedSessionID = sessionID(file)
                    if let existing,
                       canAttemptAppend(from: existing, to: observed),
                       let appended = try appendSource(
                           file: file,
                           sessionID: parsedSessionID,
                           existing: existing,
                           generation: generation,
                           connection: connection,
                           parser: parser
                       ) {
                        dirtyTurnCandidateSessions.insert(existing.sessionID)
                        dirtyTurnCandidateSessions.insert(parsedSessionID)
                        sourceMutationDetected = true
                        changedFiles += 1
                        indexedEvents += appended.eventCount
                        incrementallyParsedFiles += 1
                    } else {
                        if existing != nil {
                            rewrittenFiles += 1
                        }
                        if let existing {
                            dirtyTurnCandidateSessions.insert(existing.sessionID)
                        }
                        dirtyTurnCandidateSessions.insert(parsedSessionID)
                        fullRebuildJobs.append(
                            FullRebuildJob(
                                file: file,
                                sessionID: parsedSessionID,
                                observedSignature: observed,
                                reason: .sourceChange
                            )
                        )
                    }
                }
                // A full-rebuild job is already a real discovered candidate;
                // count it here so a first index does not sit at 0% while the
                // staged parser is working through the files.
                let completed = unchangedFiles + incrementallyParsedFiles + fullRebuildJobs.count
                onProgress?(completed, canonicalFiles.count, .scanning)
            }
        }

        if eventEnrichmentTotal > 0 {
            onProgress?(0, eventEnrichmentTotal, .backfillingModel)
        } else {
            onProgress?(canonicalFiles.count, canonicalFiles.count, .publishing)
        }
        var lineageReplacements: [String: LineageReplacement] = [:]
        var lineagesRequiringMaximumMerge = Set<String>()
        var provenanceRotated = false
        let stagingBatches = stagingBatches(for: fullRebuildJobs)
        let finalSynchronization = try driver.withConnection { connection in
            try configure(connection)
            let preRotationAttributionState = try currentAttributionState(
                connection: connection
            )
            var completedEventEnrichmentJobs = 0

            // Never leave every source staged at once. A bounded batch is
            // parsed and validated first, then every source in that batch is
            // imported by one target-database transaction. Artifacts are
            // deleted only after that transaction commits, so a crash can
            // never expose half of one batch or lose an uncommitted artifact.
            for batch in stagingBatches {
                try ensureStagingCapacity(for: batch)
                let completedBeforeBatch = completedEventEnrichmentJobs
                let stagedRebuilds = try stageFullRebuilds(
                    batch,
                    parser: parser,
                    eventEnrichmentTotal: eventEnrichmentTotal
                ) { completed, total in
                    onProgress?(
                        min(completedBeforeBatch + completed, total),
                        total,
                        .backfillingModel
                    )
                }
                if Self.stagingTestState.consumeFailure() {
                    throw SQLiteDatabaseError(
                        operation: "Injected exact usage staging interruption",
                        code: SQLITE_ABORT,
                        message: "Testing interruption after durable staging",
                        path: driver.url.path
                    )
                }
                completedEventEnrichmentJobs += stagedRebuilds.filter {
                    $0.job.reason == .eventEnrichment
                }.count

                for staged in stagedRebuilds where staged.job.reason == .eventEnrichment {
                    guard let source = try indexedSource(
                        path: staged.job.file.path,
                        connection: connection
                    ) else {
                        rewrittenFiles += 1
                        continue
                    }
                    let matches = try stagedEventsMatchPublishedSource(
                        staged,
                        sourceID: source.id,
                        connection: connection
                    )
                    if !matches {
                        // The current parser disagrees with the old published
                        // event identity or numeric payload. Treat this as the
                        // planned single-file reconciliation, never as a reason
                        // to rebuild unrelated sources.
                        rewrittenFiles += 1
                    }
                }
                for staged in stagedRebuilds {
                    let resolution = try lineageReplacement(
                        for: staged,
                        observedPaths: observedPaths,
                        connection: connection
                    )
                    if let replacement = resolution.replacement {
                        lineageReplacements[staged.job.file.path] = replacement
                    }
                    if resolution.preserveExistingLedger {
                        lineagesRequiringMaximumMerge.insert(staged.job.file.path)
                    }
                    lineageAmbiguityDetected = lineageAmbiguityDetected
                        || resolution.ambiguous
                }

                try connection.transaction { transaction in
                    // Rotate in the same transaction as the first unsafe
                    // replacement. A reader sees either the old batch and old
                    // provenance, or the complete new batch and new epoch.
                    let currentBatchUnsafeCause = rewrittenFiles > 0
                        || lineageAmbiguityDetected
                    if currentBatchUnsafeCause {
                        let attributionState = try currentAttributionState(
                            connection: transaction
                        )
                        if !attributionState.requiresSyntheticCutover {
                            provenanceRotated = true
                            _ = try rotateAttributionProvenanceInTransaction(
                                markUnsafe: true,
                                connection: transaction
                            )
                        }
                    }

                    for (index, staged) in stagedRebuilds.enumerated() {
                        try importStagedFullRebuild(
                            staged,
                            generation: generation,
                            replacementSourceID:
                                lineageReplacements[staged.job.file.path]?.sourceID,
                            preserveExistingAttributionLedger:
                                lineagesRequiringMaximumMerge.contains(staged.job.file.path),
                            connection: transaction
                        )
                        if index == 0,
                           stagedRebuilds.count > 1,
                           Self.stagingTestState.consumeBatchImportFailure() {
                            throw SQLiteDatabaseError(
                                operation: "Injected exact usage batch import interruption",
                                code: SQLITE_ABORT,
                                message: "Testing rollback after first source import",
                                path: driver.url.path
                            )
                        }
                    }
                }
                for staged in stagedRebuilds {
                    changedFiles += 1
                    indexedEvents += staged.eventCount
                    sourceMutationDetected = true
                    removeStagingDatabase(at: staged.databaseURL)
                }
            }

            // Publish a new provenance epoch before any non-append replacement
            // or unprovable lineage replacement becomes visible. The rotation
            // transaction first copies the durable ledger, so interruption can
            // overestimate local usage but cannot silently reconcile ambiguity.
            let currentScanUnsafeCauseDetected = rewrittenFiles > 0
                || lineageAmbiguityDetected
            let unsafeEpisodeBegan = currentScanUnsafeCauseDetected
                && !preRotationAttributionState.currentScanUnsafeCauseDetected
            return try connection.transaction { transaction in
                if currentScanUnsafeCauseDetected
                    && !provenanceRotated
                    && !preRotationAttributionState.requiresSyntheticCutover {
                    provenanceRotated = true
                    _ = try rotateAttributionProvenanceInTransaction(
                        markUnsafe: true,
                        connection: transaction
                    )
                }
                let currentScanUnsafeCauseBeforePublish =
                    preRotationAttributionState.currentScanUnsafeCauseDetected
                if currentScanUnsafeCauseDetected
                    != currentScanUnsafeCauseBeforePublish {
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES ('attribution_current_scan_unsafe_cause', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [
                            .text(currentScanUnsafeCauseDetected ? "1" : "0")
                        ]
                    )
                }

                // `last_seen_generation` is a publication marker for changed
                // sources, not a heartbeat. Reading the current source paths
                // and diffing against this round's observed canonical paths
                // avoids rewriting every unchanged row and keeps deletion
                // detection independent of SQLite's host parameter limit.
                let currentSources = try indexedSourceIdentities(
                    connection: transaction
                )
                let removedSourceIDs = currentSources
                    .filter { !observedPaths.contains($0.path) }
                    .map(\.id)
                let currentSessionBySourceID = Dictionary(
                    uniqueKeysWithValues: currentSources.compactMap { source in
                        source.sessionID.map { (source.id, $0) }
                    }
                )
                removedFiles = removedSourceIDs.count
                sourceMutationDetected = sourceMutationDetected
                    || !removedSourceIDs.isEmpty
                var removedDashboardBuckets = Set<Int64>()
                for sourceID in removedSourceIDs {
                    if let removedSessionID = currentSessionBySourceID[sourceID] {
                        dirtyTurnCandidateSessions.insert(removedSessionID)
                    }
                    let sourceBuckets = try transaction.readRows(
                        "SELECT bucket_start FROM dashboard_source_5m WHERE source_id = ?;",
                        bindings: [.int64(sourceID)]
                    ) { $0.int64(0) }.compactMap { $0 }
                    removedDashboardBuckets.formUnion(sourceBuckets)
                    try transaction.execute(
                        "DELETE FROM sources WHERE source_id = ?;",
                        bindings: [.int64(sourceID)]
                    )
                }
                for bucket in removedDashboardBuckets.sorted() {
                    try refreshDashboardFiveMinuteAggregates(
                        affectedBuckets: bucket...bucket,
                        connection: transaction
                    )
                }
                if !dirtyTurnCandidateSessions.isEmpty {
                    try refreshDashboardTurnCandidates(
                        sessionIDs: dirtyTurnCandidateSessions,
                        connection: transaction
                    )
                }
                let current = try currentAttributionState(connection: transaction)
                try transaction.execute(
                    "DELETE FROM attribution_source_buckets WHERE provenance_epoch <> ?;",
                    bindings: [.text(current.provenanceEpoch)]
                )

                let unsafeCauseChanged = currentScanUnsafeCauseDetected
                    != currentScanUnsafeCauseBeforePublish
                let needsPublicationGeneration = sourceMutationDetected
                    || (unsafeCauseChanged && !provenanceRotated)
                let publishedGeneration: Int64
                if needsPublicationGeneration {
                    publishedGeneration = try bumpAttributionGeneration(
                        connection: transaction
                    )
                } else {
                    publishedGeneration = current.generation
                }
                try transaction.execute(
                    """
                    INSERT INTO schema_meta(key, value)
                    VALUES ('dashboard_aggregate_exact_generation', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """,
                    bindings: [.text(String(publishedGeneration))]
                )
                let eventEnrichmentComplete = try finalizeEventEnrichmentIfComplete(
                    connection: transaction
                )
                let eventEnrichmentPendingCount = eventEnrichmentComplete
                    ? 0
                    : try eventEnrichmentPendingSourceIDs(connection: transaction).count
                if unsafeEpisodeBegan {
                    try markAttributionUnsafe(
                        provenanceEpoch: current.provenanceEpoch,
                        sinceGeneration: publishedGeneration,
                        connection: transaction
                    )
                }
                return (
                    state: try currentAttributionState(connection: transaction),
                    eventEnrichmentComplete: eventEnrichmentComplete,
                    eventEnrichmentPendingCount: eventEnrichmentPendingCount
                )
            }
        }
        removeStagingDirectory()
        if eventEnrichmentTotal > 0 {
            if finalSynchronization.eventEnrichmentComplete {
                onProgress?(eventEnrichmentTotal, eventEnrichmentTotal, .publishing)
            } else {
                onProgress?(
                    max(0, eventEnrichmentTotal - finalSynchronization.eventEnrichmentPendingCount),
                    eventEnrichmentTotal,
                    .backfillingModel
                )
            }
        } else {
            onProgress?(1, 1, .publishing)
        }

        return SynchronizationResult(
            changedFiles: changedFiles,
            unchangedFiles: unchangedFiles,
            indexedEvents: indexedEvents,
            incrementallyParsedFiles: incrementallyParsedFiles,
            rewrittenFiles: rewrittenFiles,
            removedFiles: removedFiles,
            provenanceEpoch: finalSynchronization.state.provenanceEpoch,
            attributionGeneration: finalSynchronization.state.generation,
            attributionUnsafeSinceGeneration:
                finalSynchronization.state.unsafeSinceGeneration,
            lineageAmbiguityDetected: lineageAmbiguityDetected,
            attributionUnsafe: finalSynchronization.state.requiresSyntheticCutover,
            eventEnrichmentTotal: eventEnrichmentTotal,
            eventEnrichmentComplete: finalSynchronization.eventEnrichmentComplete
        )
    }

    struct CompactTotals: Equatable {
        let totalTokens: Int
        let todayTokens: Int
        let todayCalls: Int
        let todayModelBreakdowns: [ModelTokenBreakdown]
    }

    func attributionSourceBuckets(
        provenanceEpoch: String,
        from start: Date,
        before end: Date
    ) throws -> [TokenCacheAttributionEvent] {
        try driver.withConnection { connection in
            try configure(connection)
            let current = try currentAttributionState(connection: connection)
            guard current.provenanceEpoch == provenanceEpoch else {
                throw SQLiteDatabaseError(
                    operation: "Read exact usage attribution ledger",
                    code: SQLITE_ABORT,
                    message: "Requested provenance epoch was superseded",
                    path: driver.url.path
                )
            }
            return try connection.readRows(
                        """
                        SELECT
                            source_lineage,
                            bucket_start,
                            model,
                            input_tokens,
                            cached_input_tokens,
                            output_tokens,
                            reasoning_output_tokens,
                            total_tokens,
                            calls
                        FROM attribution_source_buckets
                        WHERE provenance_epoch = ?
                          AND bucket_start >= ?
                          AND bucket_start < ?
                        ORDER BY bucket_start, source_lineage, model;
                        """,
                        bindings: [
                            .text(provenanceEpoch),
                            .int64(Int64(start.timeIntervalSince1970.rounded())),
                            .int64(Int64(end.timeIntervalSince1970.rounded())),
                        ]
                    ) { row -> TokenCacheAttributionEvent? in
                        guard let sourceLineage = row.text(0),
                              let bucketStart = row.int64(1),
                              let inputTokens = row.int(3),
                              let cachedInputTokens = row.int(4),
                              let outputTokens = row.int(5),
                              let reasoningOutputTokens = row.int(6),
                              let totalTokens = row.int(7),
                              let calls = row.int(8) else {
                            return nil
                        }
                        let start = Date(timeIntervalSince1970: TimeInterval(bucketStart))
                        return TokenCacheAttributionEvent.sourceBucket(
                            provenanceEpoch: provenanceEpoch,
                            sourceID: sourceLineage,
                            start: start,
                            model: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                            breakdown: TokenCacheBreakdown(
                                inputTokens: inputTokens,
                                cachedInputTokens: cachedInputTokens,
                                outputTokens: outputTokens,
                                reasoningOutputTokens: reasoningOutputTokens,
                                totalTokens: totalTokens,
                                calls: calls
                            )
                        )
                    }
            .compactMap { $0 }
        }
    }

    // 决策口径：紧凑 surface 刷新只跑轻量聚合 SQL（累计 token、今日 token、
    // 今日调用数、今日逐模型用量），不得顺带构建时间序列/排行/摘录。
    func compactTotals(todayStart: Date, before tomorrowStart: Date) throws -> CompactTotals {
        try driver.withConnection { connection in
                let total = try connection.readRows(
                    "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_source_totals;"
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let start = todayStart.timeIntervalSince1970
                let end = tomorrowStart.timeIntervalSince1970
                let todayTokens = try connection.readRows(
                    "SELECT COALESCE(SUM(total_tokens), 0) FROM dashboard_5m WHERE bucket_start >= ? AND bucket_start < ?;",
                    bindings: [.int64(Int64(start)), .int64(Int64(end))]
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let todayCalls = try connection.readRows(
                    "SELECT COALESCE(SUM(calls), 0) FROM dashboard_5m WHERE bucket_start >= ? AND bucket_start < ?;",
                    bindings: [.int64(Int64(start)), .int64(Int64(end))]
                ) { row in row.int(0) ?? 0 }.first ?? 0
                let todayModelBreakdowns = try connection.readRows(
                    """
                    SELECT
                        model,
                        COALESCE(SUM(input_tokens), 0),
                        COALESCE(SUM(cached_input_tokens), 0),
                        COALESCE(SUM(output_tokens), 0),
                        COALESCE(SUM(reasoning_output_tokens), 0),
                        COALESCE(SUM(total_tokens), 0),
                        COALESCE(SUM(calls), 0)
                    FROM dashboard_5m
                    WHERE bucket_start >= ?
                      AND bucket_start < ?
                    GROUP BY model
                    ORDER BY SUM(total_tokens) DESC;
                    """,
                    bindings: [.int64(Int64(start)), .int64(Int64(end))]
                ) { row in
                    ModelTokenBreakdown(
                        model: row.text(0).flatMap { $0.isEmpty ? nil : $0 },
                        breakdown: TokenCacheBreakdown(
                            inputTokens: row.int(1) ?? 0,
                            cachedInputTokens: row.int(2) ?? 0,
                            outputTokens: row.int(3) ?? 0,
                            reasoningOutputTokens: row.int(4) ?? 0,
                            totalTokens: row.int(5) ?? 0,
                            calls: row.int(6) ?? 0
                        )
                    )
                }
                return CompactTotals(
                    totalTokens: total,
                    todayTokens: todayTokens,
                    todayCalls: todayCalls,
                    todayModelBreakdowns: todayModelBreakdowns
                )
        }
    }

    func markDashboardAggregatePublished(
        exactGeneration: Int64,
        settledThrough: Date
    ) throws {
        try withExclusiveAccess {
            try driver.withConnection { connection in
                try connection.transaction { transaction in
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES
                            ('dashboard_aggregate_published_generation', ?),
                            ('dashboard_aggregate_settled_through', ?),
                            ('dashboard_aggregate_pricing_revision', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [
                            .text(String(exactGeneration)),
                            .text(String(Int64(settledThrough.timeIntervalSince1970))),
                            .text(Self.dashboardAggregatePricingRevision),
                        ]
                    )
                }
            }
        }
    }

    func forEachStoredEvent(_ body: (StoredEvent) throws -> Void) throws {
        try forEachStoredEventExclusively(body)
    }

    func forEachAggregatedUsageRow(
        from visibleStart: Date,
        _ body: (AggregatedUsageRow) throws -> Void
    ) throws {
        try driver.forEachRow(
                """
                WITH bounded AS (
                    SELECT
                        bucket_start, model,
                        input_tokens, cached_input_tokens, output_tokens,
                        reasoning_output_tokens, total_tokens, calls
                    FROM dashboard_5m
                    WHERE bucket_start >= ?

                    UNION ALL

                    SELECT
                        MIN(bucket_start), model,
                        SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                        SUM(reasoning_output_tokens), SUM(total_tokens), SUM(calls)
                    FROM dashboard_5m
                    WHERE bucket_start < ?
                    GROUP BY model
                )
                SELECT * FROM bounded
                ORDER BY bucket_start, model;
                """,
                bindings: [
                    .int64(Int64(visibleStart.timeIntervalSince1970)),
                    .int64(Int64(visibleStart.timeIntervalSince1970)),
                ]
            ) { row in
                guard let bucketStart = row.int64(0),
                      let inputTokens = row.int(2),
                      let cachedInputTokens = row.int(3),
                      let outputTokens = row.int(4),
                      let reasoningOutputTokens = row.int(5),
                      let totalTokens = row.int(6),
                      let calls = row.int(7) else {
                    return
                }
                try body(AggregatedUsageRow(
                    start: Date(timeIntervalSince1970: TimeInterval(bucketStart)),
                    model: row.text(1).flatMap { $0.isEmpty ? nil : $0 },
                    breakdown: TokenCacheBreakdown(
                        inputTokens: inputTokens,
                        cachedInputTokens: cachedInputTokens,
                        outputTokens: outputTokens,
                        reasoningOutputTokens: reasoningOutputTokens,
                        totalTokens: totalTokens,
                        calls: calls
                    )
                ))
            }
    }

    func forEachAggregatedSessionRow(
        limit: Int = 256,
        _ body: (AggregatedSessionRow) throws -> Void
    ) throws {
        try driver.forEachRow(
                """
                WITH grouped AS (
                    SELECT
                        session_id,
                        SUM(output_tokens) AS output_tokens,
                        SUM(reasoning_output_tokens) AS reasoning_output_tokens,
                        SUM(total_tokens) AS total_tokens,
                        MAX(last_timestamp) AS last_timestamp
                    FROM dashboard_source_totals
                    GROUP BY session_id
                ), logical_turns AS (
                    SELECT
                        session_id,
                        SUM(input_tokens) AS input_tokens,
                        SUM(cached_input_tokens) AS cached_input_tokens,
                        COUNT(*) AS calls
                    FROM dashboard_turn_candidates
                    GROUP BY session_id
                ), selected AS (
                    SELECT * FROM (
                        SELECT
                            grouped.session_id,
                            COALESCE(logical_turns.input_tokens, 0) AS input_tokens,
                            COALESCE(logical_turns.cached_input_tokens, 0) AS cached_input_tokens,
                            grouped.output_tokens,
                            grouped.reasoning_output_tokens,
                            grouped.total_tokens,
                            COALESCE(logical_turns.calls, 0) AS calls,
                            grouped.last_timestamp
                        FROM grouped
                        LEFT JOIN logical_turns
                          ON logical_turns.session_id = grouped.session_id
                        ORDER BY grouped.total_tokens DESC, grouped.session_id
                        LIMIT ?
                    )
                    UNION
                    SELECT * FROM (
                        SELECT
                            grouped.session_id,
                            COALESCE(logical_turns.input_tokens, 0) AS input_tokens,
                            COALESCE(logical_turns.cached_input_tokens, 0) AS cached_input_tokens,
                            grouped.output_tokens,
                            grouped.reasoning_output_tokens,
                            grouped.total_tokens,
                            COALESCE(logical_turns.calls, 0) AS calls,
                            grouped.last_timestamp
                        FROM grouped
                        LEFT JOIN logical_turns
                          ON logical_turns.session_id = grouped.session_id
                        ORDER BY grouped.last_timestamp DESC, grouped.session_id
                        LIMIT ?
                    )
                )
                SELECT * FROM selected
                ORDER BY last_timestamp DESC, total_tokens DESC, session_id;
                """,
                bindings: [.int(limit), .int(limit)]
            ) { row in
                guard let sessionID = row.text(0),
                      let inputTokens = row.int(1),
                      let cachedInputTokens = row.int(2),
                      let outputTokens = row.int(3),
                      let reasoningOutputTokens = row.int(4),
                      let totalTokens = row.int(5),
                      let calls = row.int(6) else { return }
                try body(AggregatedSessionRow(
                    sessionID: sessionID,
                    lastUpdated: row.double(7).map {
                        Date(timeIntervalSince1970: $0)
                    },
                    breakdown: TokenCacheBreakdown(
                        inputTokens: inputTokens,
                        cachedInputTokens: cachedInputTokens,
                        outputTokens: outputTokens,
                        reasoningOutputTokens: reasoningOutputTokens,
                        totalTokens: totalTokens,
                        calls: calls
                    )
                ))
            }
    }

    func aggregatedSessionCount() throws -> Int {
        try driver.readRows(
            "SELECT COUNT(DISTINCT session_id) FROM dashboard_source_totals;"
        ) { $0.int(0) ?? 0 }.first ?? 0
    }

    func boundedTurnCandidates(limit: Int = 128) throws -> [TurnCacheUsage] {
        try driver.withConnection { connection in
                var candidates: [String: TurnCacheUsage] = [:]
                let selections = [
                    (
                        predicate: "1 = 1",
                        ordering: "timestamp DESC, source_id DESC, source_offset DESC"
                    ),
                    (
                        predicate: "input_tokens >= 1000",
                        ordering: "hit_rate ASC, uncached_tokens DESC, input_tokens DESC, timestamp DESC"
                    ),
                ]
                for selection in selections {
                    let rows = try connection.readRows(
                        """
                        SELECT
                            source_id,
                            source_offset,
                            timestamp,
                            session_id,
                            total_tokens,
                            input_tokens,
                            cached_input_tokens,
                            output_tokens,
                            reasoning_output_tokens,
                            turn_index
                        FROM dashboard_turn_candidates
                        WHERE \(selection.predicate)
                        ORDER BY \(selection.ordering)
                        LIMIT ?;
                        """,
                        bindings: [.int(limit)]
                    ) { row -> TurnCacheUsage? in
                        guard let sourceID = row.int64(0),
                              let rawOffset = row.int64(1), rawOffset >= 0,
                              let timestamp = row.double(2),
                              let sessionID = row.text(3),
                              let totalTokens = row.int(4),
                              let inputTokens = row.int(5),
                              let cachedInputTokens = row.int(6),
                              let outputTokens = row.int(7),
                              let reasoningOutputTokens = row.int(8),
                              let turnIndex = row.int(9) else {
                            return nil
                        }
                        return TurnCacheUsage(
                            id: Self.stableID(
                                sourceID: sourceID,
                                sourceOffset: UInt64(rawOffset)
                            ),
                            sessionID: sessionID,
                            sessionTitle: sessionID,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            turnIndexInSession: turnIndex,
                            userPrompt: "",
                            assistantResponse: "",
                            breakdown: TokenCacheBreakdown(
                                inputTokens: inputTokens,
                                cachedInputTokens: cachedInputTokens,
                                outputTokens: outputTokens,
                                reasoningOutputTokens: reasoningOutputTokens,
                                totalTokens: totalTokens,
                                calls: 1
                            )
                        )
                    }
                    for candidate in rows.compactMap({ $0 }) {
                        candidates[candidate.id] = candidate
                    }
                }
                return Array(candidates.values)
        }
    }

    func firstAggregatedEventAt() throws -> Date? {
        try driver.readRows(
            "SELECT MIN(first_timestamp) FROM dashboard_source_totals;"
        ) { row in
            row.double(0).map { Date(timeIntervalSince1970: $0) }
        }.first ?? nil
    }

    private func forEachStoredEventExclusively(
        _ body: (StoredEvent) throws -> Void
    ) throws {
        try driver.forEachRow(
            """
            SELECT
                events.source_id,
                events.source_offset,
                events.timestamp,
                sources.session_id,
                events.tokens,
                events.input_tokens,
                events.cached_input_tokens,
                events.output_tokens,
                events.reasoning_output_tokens,
                events.model
            FROM events
            JOIN sources ON sources.source_id = events.source_id
            ORDER BY sources.session_id, events.timestamp, events.source_id, events.source_offset;
            """
        ) { row in
            guard let sourceID = row.int64(0),
                  let rawOffset = row.int64(1),
                  rawOffset >= 0,
                  let timestamp = row.double(2),
                  let sessionID = row.text(3),
                  let tokens = row.int(4),
                  let inputTokens = row.int(5),
                  let cachedInputTokens = row.int(6),
                  let outputTokens = row.int(7),
                  let reasoningOutputTokens = row.int(8) else {
                return
            }
            let offset = UInt64(rawOffset)
            try body(
                StoredEvent(
                    stableID: Self.stableID(sourceID: sourceID, sourceOffset: offset),
                    event: TokenEvent(
                        timestamp: Date(timeIntervalSince1970: timestamp),
                        sessionID: sessionID,
                        model: row.text(9),
                        tokens: tokens,
                        inputTokens: inputTokens,
                        cachedInputTokens: cachedInputTokens,
                        outputTokens: outputTokens,
                        reasoningOutputTokens: reasoningOutputTokens,
                        userPrompt: "",
                        assistantResponse: ""
                    ),
                    sourceID: sourceID,
                    sourceOffset: offset
                )
            )
        }
    }

    func turnSourceReferences(for stableIDs: [String]) throws -> [String: TurnSourceReference] {
        try withExclusiveAccess {
            try turnSourceReferencesExclusively(for: stableIDs)
        }
    }

    private func turnSourceReferencesExclusively(
        for stableIDs: [String]
    ) throws -> [String: TurnSourceReference] {
        var references: [String: TurnSourceReference] = [:]
        try driver.withConnection { connection in
            for stableID in stableIDs {
                guard let identity = Self.parseStableID(stableID) else { continue }
                let rows = try connection.readRows(
                    """
                    SELECT
                        sources.path,
                        events.source_offset,
                        events.user_prompt_offset,
                        events.assistant_start_offset
                    FROM events
                    JOIN sources ON sources.source_id = events.source_id
                    WHERE events.source_id = ? AND events.source_offset = ?
                    LIMIT 1;
                    """,
                    bindings: [
                        .int64(identity.sourceID),
                        .int64(try sqliteInt64(identity.sourceOffset))
                    ]
                ) { row in
                    (
                        path: row.text(0),
                        eventOffset: row.int64(1),
                        userPromptOffset: row.int64(2),
                        assistantStartOffset: row.int64(3)
                    )
                }
                guard let row = rows.first,
                      let path = row.path,
                      let rawEventOffset = row.eventOffset,
                      rawEventOffset >= 0 else {
                    continue
                }
                references[stableID] = TurnSourceReference(
                    stableID: stableID,
                    file: URL(fileURLWithPath: path),
                    eventOffset: UInt64(rawEventOffset),
                    userPromptOffset: row.userPromptOffset.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    assistantStartOffset: row.assistantStartOffset.flatMap { $0 >= 0 ? UInt64($0) : nil }
                )
            }
        }
        return references
    }

    static func clearForTesting() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: ephemeralRoot)
        if let override = ProcessInfo.processInfo.environment[cacheDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
                .appendingPathComponent(indexNamespace, isDirectory: true)
            try? fileManager.removeItem(at: root)
        }
    }

    private func prepareSchema(
        onProgress: ((PreciseIndexProgress) -> Void)? = nil
    ) throws {
        try driver.withConnection { connection in
            try configure(connection)
            try connection.execute(
                "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            )
            let currentVersion = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'schema_version' LIMIT 1;"
            ) { row in
                row.text(0)
            }.first ?? nil
            let numericVersion = currentVersion.flatMap(Int.init)
            let isLegacyDiscardableSchema = numericVersion.map { $0 < 2 } ?? false
            let isKnownInPlaceSchema = currentVersion.map(Self.inPlaceSchemaVersions.contains) ?? true
            let shouldReportMigration = numericVersion.map { $0 >= 2 && $0 < Int(Self.schemaVersion)! } ?? false
            if let currentVersion,
               !isKnownInPlaceSchema,
               !isLegacyDiscardableSchema {
                throw SQLiteDatabaseError(
                    operation: "Open exact usage history index",
                    code: SQLITE_MISMATCH,
                    message: "Index schema \(currentVersion) is newer or unknown; refusing to rewrite it",
                    path: driver.url.path
                )
            }
            let destructiveRebuildRequired = isLegacyDiscardableSchema

            // Read migration markers before any DDL.  These values describe
            // the actual work this open will perform; they are also used to
            // keep the progress denominator honest instead of reporting a
            // fixed 3/3 while the ledger or catalog still needs work.
            let storedProvenanceRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'provenance_revision' LIMIT 1;"
            ) { row in row.text(0) }.first ?? nil
            if let storedProvenanceRevision,
               storedProvenanceRevision != Self.attributionProvenanceRevision,
               !Self.knownLegacyAttributionProvenanceRevisions.contains(
                   storedProvenanceRevision
               ) {
                throw SQLiteDatabaseError(
                    operation: "Open exact usage attribution ledger",
                    code: SQLITE_MISMATCH,
                    message: "Attribution provenance \(storedProvenanceRevision) is newer or unknown; refusing to rewrite it",
                    path: driver.url.path
                )
            }
            let storedReplayBoundaryRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'fork_replay_boundary_revision' LIMIT 1;"
            ) { row in row.text(0) }.first ?? nil
            let storedEventEnrichmentRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = ? LIMIT 1;",
                bindings: [.text(Self.eventEnrichmentRevisionKey)]
            ) { row in row.text(0) }.first ?? nil
            if let storedEventEnrichmentRevision,
               storedEventEnrichmentRevision != Self.eventEnrichmentRevision {
                throw SQLiteDatabaseError(
                    operation: "Open exact usage event enrichment",
                    code: SQLITE_MISMATCH,
                    message: "Event enrichment revision \(storedEventEnrichmentRevision) is newer or unknown; refusing to rewrite it",
                    path: driver.url.path
                )
            }
            let sessionCatalogMetaExists = try connection.readRows(
                """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = 'session_catalog_meta';
                """
            ) { row in (row.int(0) ?? 0) > 0 }.first ?? false
            let sessionCatalogEntriesExist = try connection.readRows(
                """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = 'session_catalog_entries';
                """
            ) { row in (row.int(0) ?? 0) > 0 }.first ?? false
            let sessionCatalogVersion = sessionCatalogMetaExists
                ? (try connection.readRows(
                    """
                    SELECT value
                    FROM session_catalog_meta
                    WHERE key = 'schema_version'
                    LIMIT 1;
                    """
                ) { row in row.text(0) }.first ?? nil)
                : nil
            if let sessionCatalogVersion,
               sessionCatalogVersion != Self.sessionCatalogSchemaVersion {
                throw SQLiteDatabaseError(
                    operation: "Open exact usage session catalog",
                    code: SQLITE_MISMATCH,
                    message: "Session catalog schema \(sessionCatalogVersion) is newer or unknown; refusing to rewrite it",
                    path: driver.url.path
                )
            }
            let storedDashboardAggregateVersion = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'dashboard_aggregate_schema_version' LIMIT 1;"
            ) { row in row.text(0) }.first ?? nil
            let storedDashboardPricingRevision = try connection.readRows(
                "SELECT value FROM schema_meta WHERE key = 'dashboard_aggregate_pricing_revision' LIMIT 1;"
            ) { row in row.text(0) }.first ?? nil
            if let storedDashboardAggregateVersion,
               storedDashboardAggregateVersion != Self.dashboardAggregateSchemaVersion {
                guard let numericAggregateVersion = Int(storedDashboardAggregateVersion),
                      numericAggregateVersion < Int(Self.dashboardAggregateSchemaVersion)! else {
                    throw SQLiteDatabaseError(
                        operation: "Open dashboard aggregate index",
                        code: SQLITE_MISMATCH,
                        message: "Dashboard aggregate schema \(storedDashboardAggregateVersion) is newer or unknown; refusing to overwrite it",
                        path: driver.url.path
                    )
                }
            }
            if let storedDashboardPricingRevision,
               !Self.knownDashboardAggregatePricingRevisions.contains(
                   storedDashboardPricingRevision
               ) {
                throw SQLiteDatabaseError(
                    operation: "Open dashboard aggregate index",
                    code: SQLITE_MISMATCH,
                    message: "Dashboard aggregate pricing contract \(storedDashboardPricingRevision) is unknown; refusing to overwrite it",
                    path: driver.url.path
                )
            }
            let migrationNeedsSchemaFields = !destructiveRebuildRequired
                && shouldReportMigration
            // A schema downgrade/legacy reopen is a migration boundary even
            // when a previous interrupted attempt left the current replay
            // marker behind. Revalidate the source rows instead of trusting
            // that marker across schema generations.
            let migrationNeedsReplayBoundary = currentVersion != nil
                && (
                    storedReplayBoundaryRevision != Self.forkReplayBoundaryRevision
                    || shouldReportMigration
                )
            if shouldReportMigration,
               storedReplayBoundaryRevision == Self.forkReplayBoundaryRevision {
                try connection.execute(
                    "DELETE FROM schema_meta WHERE key = 'fork_replay_boundary_revision';"
                )
            }
            let migrationNeedsLedger = destructiveRebuildRequired
                || storedProvenanceRevision != Self.attributionProvenanceRevision
            let migrationNeedsSessionCatalog = currentVersion != nil
                && (!sessionCatalogMetaExists
                    || !sessionCatalogEntriesExist
                    || sessionCatalogVersion != Self.sessionCatalogSchemaVersion)
            let migrationNeedsDashboardAggregate = storedDashboardAggregateVersion
                != Self.dashboardAggregateSchemaVersion
                || storedDashboardPricingRevision != Self.dashboardAggregatePricingRevision
            let migrationNeedsEventEnrichment = currentVersion != nil
                && storedEventEnrichmentRevision != Self.eventEnrichmentRevision
            let migrationTotal = [
                migrationNeedsSchemaFields,
                migrationNeedsReplayBoundary,
                migrationNeedsLedger,
                migrationNeedsSessionCatalog,
                migrationNeedsDashboardAggregate,
                migrationNeedsEventEnrichment,
            ].filter { $0 }.count
            let migrationMessagePrefix =
                "正在升级索引结构（首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失）"
            var migrationCompleted = 0

            func reportMigration(_ detail: String, completed: Int? = nil) {
                guard migrationTotal > 0 else { return }
                onProgress?(PreciseIndexProgress(
                    phase: .migrating,
                    message: "\(migrationMessagePrefix)：\(detail)",
                    completed: completed ?? migrationCompleted,
                    total: migrationTotal
                ))
            }

            if !destructiveRebuildRequired,
               currentVersion != nil {
                if migrationNeedsSchemaFields {
                    reportMigration("正在升级索引字段")
                    try connection.transaction { transaction in
                        try migrateV2SourcesForAppend(transaction)
                        try migrateKnownEventColumns(transaction)
                    }
                    migrationCompleted += 1
                    reportMigration("索引字段已提交")
                }
            }

            // Capture the replay state after any schema-field additions.  The
            // revision marker itself is deliberately deferred until the final
            // schema/catalog commit below; an unresolved probe must remain
            // retryable on the next open.
            var replayBoundaryReady = true
            var replayBoundaryStageCompleted = false
            if migrationNeedsReplayBoundary && !destructiveRebuildRequired {
                reportMigration("正在修复 replay 边界")
                replayBoundaryReady = try repairExplicitSubagentReplayBoundary(
                    connection,
                    persistRevision: false
                )
                if replayBoundaryReady {
                    migrationCompleted += 1
                    replayBoundaryStageCompleted = true
                    reportMigration("replay 边界已提交")
                } else {
                    reportMigration("replay 边界待下次打开重试")
                }
            }

            // Capture all attribution evidence before any destructive schema
            // rebuild. A future/unknown schema version and a tombstoned ledger
            // can otherwise lose their only evidence before safety is decided.
            let priorAttributionLedgerExists = try connection.readRows(
                """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = 'attribution_source_buckets';
                """
            ) { row in (row.int(0) ?? 0) > 0 }.first ?? false
            let priorAttributionLedgerRowCount: Int
            if priorAttributionLedgerExists {
                priorAttributionLedgerRowCount = try connection.readRows(
                    "SELECT COUNT(*) FROM attribution_source_buckets;"
                ) { row in row.int(0) ?? 0 }.first ?? 0
            } else {
                priorAttributionLedgerRowCount = 0
            }
            let priorSourcesExist = try connection.readRows(
                """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = 'sources';
                """
            ) { row in (row.int(0) ?? 0) > 0 }.first ?? false
            let priorSourceCount: Int
            if priorSourcesExist {
                priorSourceCount = try connection.readRows(
                    "SELECT COUNT(*) FROM sources;"
                ) { row in row.int(0) ?? 0 }.first ?? 0
            } else {
                priorSourceCount = 0
            }
            let priorAttributionUnsafe = try connection.readRows(
                """
                SELECT COUNT(*)
                FROM schema_meta
                WHERE key IN (
                    'attribution_unsafe_epoch',
                    'attribution_unsafe_generation'
                );
                """
            ) { row in (row.int(0) ?? 0) > 0 }.first ?? false

            if destructiveRebuildRequired {
                try connection.execute(
                    """
                    DROP TABLE IF EXISTS source_chunks;
                    DROP TABLE IF EXISTS source_fingerprints;
                    DROP TABLE IF EXISTS attribution_source_buckets;
                    DROP TABLE IF EXISTS dashboard_5m;
                    DROP TABLE IF EXISTS dashboard_source_5m;
                    DROP TABLE IF EXISTS dashboard_source_totals;
                    DROP TABLE IF EXISTS events;
                    DROP TABLE IF EXISTS sources;
                    DELETE FROM schema_meta;
                    """
                )
            }

            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS sources (
                    source_id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    session_id TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    content_probe TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    inode TEXT NOT NULL,
                    status_changed_seconds INTEGER NOT NULL,
                    status_changed_nanoseconds INTEGER NOT NULL,
                    last_seen_generation TEXT NOT NULL,
                    append_ready INTEGER NOT NULL DEFAULT 0,
                    resume_offset INTEGER,
                    previous_total_tokens INTEGER,
                    fork_replay_started_at REAL,
                    is_skipping_fork_replay INTEGER NOT NULL DEFAULT 0,
                    is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0,
                    last_skipped_fork_replay_token_at REAL,
                    current_user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
                    current_model TEXT,
                    audit_chunk_index INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS events (
                    source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                    source_offset INTEGER NOT NULL,
                    timestamp REAL NOT NULL,
                    tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    model TEXT,
                    user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
                    PRIMARY KEY(source_id, source_offset)
                ) WITHOUT ROWID;

                CREATE INDEX IF NOT EXISTS events_timestamp
                    ON events(timestamp, source_id, source_offset);
                CREATE INDEX IF NOT EXISTS events_source_timestamp
                    ON events(source_id, timestamp, source_offset);
                CREATE INDEX IF NOT EXISTS events_input_rank
                    ON events(input_tokens, cached_input_tokens, timestamp, source_id, source_offset);
                CREATE INDEX IF NOT EXISTS sources_session
                    ON sources(session_id, source_id);
                CREATE INDEX IF NOT EXISTS sources_session_nocase
                    ON sources(session_id COLLATE NOCASE, source_id);

                CREATE TABLE IF NOT EXISTS event_enrichment_sources (
                    source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
                    revision TEXT NOT NULL,
                    canonical_path TEXT NOT NULL,
                    parser_revision TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    inode TEXT NOT NULL,
                    imported_generation TEXT NOT NULL,
                    completed_size INTEGER NOT NULL,
                    completed_probe TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS attribution_source_buckets (
                    provenance_epoch TEXT NOT NULL,
                    source_lineage TEXT NOT NULL,
                    bucket_start INTEGER NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    calls INTEGER NOT NULL,
                    PRIMARY KEY(provenance_epoch, source_lineage, bucket_start, model)
                ) WITHOUT ROWID;

                CREATE INDEX IF NOT EXISTS attribution_source_buckets_time
                    ON attribution_source_buckets(provenance_epoch, bucket_start);

                CREATE TABLE IF NOT EXISTS dashboard_source_totals (
                    source_id INTEGER PRIMARY KEY REFERENCES sources(source_id) ON DELETE CASCADE,
                    session_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    calls INTEGER NOT NULL,
                    first_timestamp REAL,
                    last_timestamp REAL
                );

                CREATE TABLE IF NOT EXISTS dashboard_source_5m (
                    source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                    bucket_start INTEGER NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    calls INTEGER NOT NULL,
                    PRIMARY KEY(source_id, bucket_start, model)
                ) WITHOUT ROWID;

                CREATE INDEX IF NOT EXISTS dashboard_source_5m_time
                    ON dashboard_source_5m(bucket_start, source_id);

                CREATE TABLE IF NOT EXISTS dashboard_5m (
                    bucket_start INTEGER NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    calls INTEGER NOT NULL,
                    PRIMARY KEY(bucket_start, model)
                ) WITHOUT ROWID;

                CREATE TABLE IF NOT EXISTS dashboard_turn_candidates (
                    source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                    source_offset INTEGER NOT NULL,
                    session_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    hit_rate REAL NOT NULL,
                    uncached_tokens INTEGER NOT NULL,
                    turn_index INTEGER NOT NULL,
                    session_calls INTEGER NOT NULL,
                    PRIMARY KEY(source_id, source_offset)
                ) WITHOUT ROWID;

                CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_latest
                    ON dashboard_turn_candidates(timestamp DESC, source_id DESC, source_offset DESC);

                CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_cache
                    ON dashboard_turn_candidates(
                        hit_rate,
                        uncached_tokens DESC,
                        input_tokens DESC,
                        timestamp DESC
                    );

                CREATE INDEX IF NOT EXISTS dashboard_turn_candidates_session
                    ON dashboard_turn_candidates(session_id);
                """
            )
            // `CREATE TABLE IF NOT EXISTS` does not upgrade an attribution
            // ledger created by the v3/v4 index.  Repair its shape before the
            // replay probe can defer the expensive backfill; otherwise a
            // retryable replay candidate would leave the old three-column
            // primary key in place and every model-aware read would fail.
            try ensureAttributionLedgerSchema(connection: connection)
            try connection.execute(
                """
                INSERT OR IGNORE INTO schema_meta(key, value)
                VALUES ('provenance_epoch', ?);
                """,
                bindings: [.text(UUID().uuidString)]
            )
            try connection.execute(
                """
                INSERT OR IGNORE INTO schema_meta(key, value)
                SELECT 'source_id_sequence', CAST(COALESCE(MAX(source_id), 0) AS TEXT)
                FROM sources;

                INSERT OR IGNORE INTO schema_meta(key, value)
                VALUES ('attribution_generation', '0');

                INSERT OR IGNORE INTO schema_meta(key, value)
                SELECT
                    'attribution_current_scan_unsafe_cause',
                    CASE WHEN EXISTS(
                        SELECT 1 FROM schema_meta
                        WHERE key IN (
                            'attribution_unsafe_epoch',
                            'attribution_unsafe_generation'
                        )
                    ) THEN '1' ELSE '0' END;
                """
            )
            let attributionMigrationRequired = destructiveRebuildRequired
                || storedProvenanceRevision != Self.attributionProvenanceRevision
            // Do not rebuild the potentially large attribution ledger while a
            // replay-boundary probe is unresolved.  The replay marker would
            // remain pending and the next launch would repeat this O(events)
            // transaction from scratch.
            let attributionMigrationReady = !migrationNeedsReplayBoundary || replayBoundaryReady
            if attributionMigrationRequired && attributionMigrationReady {
                if migrationNeedsLedger {
                    reportMigration("正在回填归因账本")
                }
                try connection.transaction { transaction in
                    try transaction.execute(
                        "DROP TABLE IF EXISTS attribution_source_buckets;"
                    )
                    try createAttributionLedgerSchema(connection: transaction)
                    try transaction.execute(
                        """
                        DELETE FROM schema_meta
                        WHERE key IN (
                            'attribution_unsafe_epoch',
                            'attribution_unsafe_generation'
                        );
                        """
                    )
                    let migratedEpoch = UUID().uuidString
                    try transaction.execute(
                        "UPDATE schema_meta SET value = ? WHERE key = 'provenance_epoch';",
                        bindings: [.text(migratedEpoch)]
                    )
                    try backfillAttributionLedger(connection: transaction)
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES ('provenance_revision', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [.text(Self.attributionProvenanceRevision)]
                    )
                    let generation = try bumpAttributionGeneration(connection: transaction)
                    let sourceCount = try transaction.readRows(
                        "SELECT COUNT(*) FROM sources;"
                    ) { row in row.int(0) ?? 0 }.first ?? 0
                    if sourceCount > 0
                        || priorSourceCount > 0
                        || priorAttributionLedgerRowCount > 0
                        || storedProvenanceRevision != nil
                        || priorAttributionUnsafe {
                        try markAttributionUnsafe(
                            provenanceEpoch: migratedEpoch,
                            sinceGeneration: generation,
                            connection: transaction
                        )
                    }
                }
                if migrationNeedsLedger {
                    migrationCompleted += 1
                    reportMigration("归因账本已提交")
                }
            } else if attributionMigrationRequired {
                reportMigration("等待 replay 边界完成后回填归因账本")
            }
            try migrateV2SourcesForAppend(connection)
            try migrateKnownEventColumns(connection)
            try migrateEventEnrichmentReceiptColumns(connection)
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS source_fingerprints (
                    source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                    value TEXT NOT NULL,
                    PRIMARY KEY(source_id, value)
                ) WITHOUT ROWID;

                CREATE TABLE IF NOT EXISTS source_chunks (
                    source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    PRIMARY KEY(source_id, chunk_index)
                ) WITHOUT ROWID;

                """
            )
            // Run the replay probe again after the canonical tables exist.
            // This also covers fresh/legacy opens where there was no source
            // table to inspect before DDL.  The marker is still deferred.
            replayBoundaryReady = try repairExplicitSubagentReplayBoundary(
                connection,
                persistRevision: false
            )
            if migrationNeedsReplayBoundary,
               replayBoundaryReady,
               !replayBoundaryStageCompleted {
                migrationCompleted += 1
                replayBoundaryStageCompleted = true
                reportMigration("replay 边界已提交")
            }

            if migrationNeedsDashboardAggregate {
                reportMigration("正在升级统计聚合（只读取现有索引，不扫描原始会话）")
                try connection.transaction { transaction in
                    try rebuildDashboardAggregates(connection: transaction)
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES
                            ('dashboard_aggregate_schema_version', ?),
                            ('dashboard_aggregate_pricing_revision', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [
                            .text(Self.dashboardAggregateSchemaVersion),
                            .text(Self.dashboardAggregatePricingRevision),
                        ]
                    )
                }
                migrationCompleted += 1
                reportMigration("统计聚合已提交")
            }

            if migrationNeedsSessionCatalog {
                reportMigration("正在升级索引会话目录")
            }
            try connection.transaction { transaction in
                try prepareSessionCatalogSchema(transaction)
            }
            if migrationNeedsSessionCatalog {
                migrationCompleted += 1
                reportMigration("索引会话目录已提交")
            }

            let eventEnrichmentRequiresSync = migrationNeedsEventEnrichment
                && priorSourceCount > 0
            if migrationNeedsEventEnrichment {
                if eventEnrichmentRequiresSync {
                    reportMigration("等待补全历史模型信息；首次升级可能需要几分钟")
                } else {
                    migrationCompleted += 1
                    reportMigration("历史模型无需补齐")
                }
            }

            // Publish schema/replay revisions only after all migration pieces,
            // including an unresolved=false replay probe and session catalog,
            // have committed successfully.  An interrupted migration therefore
            // re-enters this path on the next open without a fake current
            // schema, provenance, or replay marker.
            guard replayBoundaryReady else { return }
            let requiresFinalMigrationCommit = currentVersion == nil
                || migrationNeedsSchemaFields
                || migrationNeedsReplayBoundary
                || migrationNeedsLedger
                || migrationNeedsSessionCatalog
                || migrationNeedsEventEnrichment
            guard requiresFinalMigrationCommit else { return }
            try connection.transaction { transaction in
                try transaction.execute(
                    """
                    INSERT INTO schema_meta(key, value)
                    VALUES ('fork_replay_boundary_revision', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """,
                    bindings: [.text(Self.forkReplayBoundaryRevision)]
                )
                if migrationNeedsLedger {
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES ('provenance_revision', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [.text(Self.attributionProvenanceRevision)]
                    )
                }
                if !eventEnrichmentRequiresSync {
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES ('schema_version', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [.text(Self.schemaVersion)]
                    )
                    try transaction.execute(
                        """
                        INSERT INTO schema_meta(key, value)
                        VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                        """,
                        bindings: [
                            .text(Self.eventEnrichmentRevisionKey),
                            .text(Self.eventEnrichmentRevision),
                        ]
                    )
                }
            }
            if migrationTotal > 0,
               migrationCompleted == migrationTotal {
                reportMigration("索引升级已提交")
            }
        }
    }

    private func createAttributionLedgerSchema(
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS attribution_source_buckets (
                provenance_epoch TEXT NOT NULL,
                source_lineage TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                model TEXT NOT NULL DEFAULT '',
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                calls INTEGER NOT NULL,
                PRIMARY KEY(provenance_epoch, source_lineage, bucket_start, model)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS attribution_source_buckets_time
                ON attribution_source_buckets(provenance_epoch, bucket_start);
            """
        )
    }

    private func ensureAttributionLedgerSchema(
        connection: SQLiteDatabaseConnection
    ) throws {
        let tableSQL = try connection.readRows(
            """
            SELECT sql
            FROM sqlite_master
            WHERE type = 'table' AND name = 'attribution_source_buckets'
            LIMIT 1;
            """
        ) { row in row.text(0) }.first ?? nil
        guard let tableSQL else {
            try createAttributionLedgerSchema(connection: connection)
            return
        }

        let requiredColumns = [
            "provenance_epoch",
            "source_lineage",
            "bucket_start",
            "model",
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "total_tokens",
            "calls",
        ]
        let columns = Set(try connection.readRows(
            "PRAGMA table_info(attribution_source_buckets);"
        ) { row in row.text(1) }.compactMap { $0 })
        let normalizedSQL = tableSQL
            .lowercased()
            .filter { !$0.isWhitespace }
        let expectedPrimaryKey =
            "primarykey(provenance_epoch,source_lineage,bucket_start,model)"
        guard requiredColumns.allSatisfy(columns.contains),
              normalizedSQL.contains(expectedPrimaryKey) else {
            let legacyName = "attribution_source_buckets_legacy_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let expressions = requiredColumns.map { column -> String in
                guard columns.contains(column) else {
                    switch column {
                    case "model": return "'' AS model"
                    default: return "0 AS \(column)"
                    }
                }
                return column
            }
            try connection.transaction { transaction in
                try transaction.execute(
                    "ALTER TABLE attribution_source_buckets RENAME TO \(legacyName);"
                )
                try createAttributionLedgerSchema(connection: transaction)
                let legacyRows = try transaction.readRows(
                    "SELECT COUNT(*) FROM \(legacyName);"
                ) { $0.int(0) ?? 0 }.first ?? 0
                try transaction.execute(
                    """
                    INSERT OR REPLACE INTO attribution_source_buckets(
                        \(requiredColumns.joined(separator: ", "))
                    )
                    SELECT \(expressions.joined(separator: ", "))
                    FROM \(legacyName);
                    """
                )
                let migratedRows = try transaction.readRows(
                    "SELECT COUNT(*) FROM attribution_source_buckets;"
                ) { $0.int(0) ?? 0 }.first ?? 0
                guard migratedRows == legacyRows else {
                    throw SQLiteDatabaseError(
                        operation: "Migrate exact usage attribution ledger shape",
                        code: SQLITE_CORRUPT,
                        message: "Attribution ledger row count changed from \(legacyRows) to \(migratedRows)",
                        path: driver.url.path
                    )
                }
                try transaction.execute("DROP TABLE \(legacyName);")
            }
            return
        }
        try connection.execute(
            """
            CREATE INDEX IF NOT EXISTS attribution_source_buckets_time
                ON attribution_source_buckets(provenance_epoch, bucket_start);
            """
        )
    }

    private func rebuildDashboardAggregates(
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            """
            DELETE FROM dashboard_source_5m;
            DELETE FROM dashboard_source_totals;
            DELETE FROM dashboard_5m;
            DELETE FROM dashboard_turn_candidates;

            INSERT INTO dashboard_source_5m(
                source_id, bucket_start, model,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls
            )
            SELECT
                source_id,
                CAST(timestamp / 300 AS INTEGER) * 300,
                COALESCE(model, ''),
                SUM(input_tokens),
                SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens),
                SUM(reasoning_output_tokens),
                SUM(tokens),
                COUNT(*)
            FROM events
            GROUP BY source_id, CAST(timestamp / 300 AS INTEGER), COALESCE(model, '');

            INSERT INTO dashboard_source_totals(
                source_id, session_id,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls,
                first_timestamp, last_timestamp
            )
            SELECT
                b.source_id,
                MAX(s.session_id),
                SUM(b.input_tokens),
                SUM(b.cached_input_tokens),
                SUM(b.output_tokens),
                SUM(b.reasoning_output_tokens),
                SUM(b.total_tokens),
                SUM(b.calls),
                MIN(e.first_timestamp),
                MAX(e.last_timestamp)
            FROM dashboard_source_5m b
            JOIN sources s ON s.source_id = b.source_id
            JOIN (
                SELECT source_id, MIN(timestamp) AS first_timestamp, MAX(timestamp) AS last_timestamp
                FROM events
                GROUP BY source_id
            ) e ON e.source_id = b.source_id
            GROUP BY b.source_id;

            INSERT INTO dashboard_5m(
                bucket_start, model,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls
            )
            SELECT
                bucket_start, model,
                SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                SUM(reasoning_output_tokens), SUM(total_tokens), SUM(calls)
            FROM dashboard_source_5m
            GROUP BY bucket_start, model;

            WITH snapshots AS (
                SELECT
                    e.*,
                    s.session_id AS session_id,
                    ROW_NUMBER() OVER (
                        PARTITION BY e.source_id, s.session_id, e.user_prompt_offset
                        ORDER BY e.timestamp DESC, e.source_offset DESC
                    ) AS snapshot_rank
                FROM events e
                JOIN sources s ON s.source_id = e.source_id
                WHERE e.user_prompt_offset IS NOT NULL
            ), grouped AS (
                SELECT
                    source_id,
                    session_id,
                    user_prompt_offset,
                    COALESCE(
                        MIN(CASE WHEN assistant_start_offset IS NOT NULL
                            THEN source_offset END),
                        MIN(source_offset)
                    ) AS source_offset,
                    MAX(timestamp) AS timestamp,
                    SUM(tokens) AS total_tokens,
                    MAX(CASE WHEN snapshot_rank = 1 THEN input_tokens ELSE 0 END) AS input_tokens,
                    MAX(CASE WHEN snapshot_rank = 1
                        THEN MIN(cached_input_tokens, input_tokens)
                        ELSE 0 END) AS cached_input_tokens,
                    SUM(output_tokens) AS output_tokens,
                    SUM(reasoning_output_tokens) AS reasoning_output_tokens
                FROM snapshots
                GROUP BY source_id, session_id, user_prompt_offset
            ),
            ranked AS (
                SELECT
                    source_id,
                    source_offset,
                    session_id,
                    timestamp,
                    total_tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    CASE WHEN input_tokens > 0
                        THEN cached_input_tokens * 1.0 / input_tokens
                        ELSE 0
                    END AS hit_rate,
                    input_tokens - cached_input_tokens AS uncached_tokens,
                    ROW_NUMBER() OVER (
                        PARTITION BY session_id
                        ORDER BY timestamp, source_id, source_offset
                    ) AS turn_index,
                    COUNT(*) OVER (PARTITION BY session_id) AS session_calls
                FROM grouped
            )
            INSERT INTO dashboard_turn_candidates(
                source_id, source_offset, session_id, timestamp,
                total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens,
                hit_rate, uncached_tokens, turn_index, session_calls
            )
            SELECT
                source_id, source_offset, session_id, timestamp,
                total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens,
                hit_rate, uncached_tokens, turn_index, session_calls
            FROM ranked;
            """
        )
    }

    private func refreshDashboardTurnCandidates(
        sessionIDs: Set<String>,
        connection: SQLiteDatabaseConnection
    ) throws {
        guard !sessionIDs.isEmpty else { return }
        try connection.execute(
            """
            CREATE TEMP TABLE IF NOT EXISTS dashboard_dirty_sessions (
                session_id TEXT PRIMARY KEY
            ) WITHOUT ROWID;
            DELETE FROM dashboard_dirty_sessions;
            """
        )
        let insertSession = try connection.prepare(
            "INSERT OR IGNORE INTO dashboard_dirty_sessions(session_id) VALUES (?);"
        )
        for sessionID in sessionIDs.sorted() {
            _ = try insertSession.execute([.text(sessionID)])
        }
        try connection.execute(
            """
            DELETE FROM dashboard_turn_candidates
            WHERE session_id IN (SELECT session_id FROM dashboard_dirty_sessions);

            WITH snapshots AS (
                SELECT
                    e.*,
                    s.session_id AS session_id,
                    ROW_NUMBER() OVER (
                        PARTITION BY e.source_id, s.session_id, e.user_prompt_offset
                        ORDER BY e.timestamp DESC, e.source_offset DESC
                    ) AS snapshot_rank
                FROM events e
                JOIN sources s ON s.source_id = e.source_id
                WHERE e.user_prompt_offset IS NOT NULL
                  AND s.session_id IN (
                    SELECT session_id FROM dashboard_dirty_sessions
                )
            ), grouped AS (
                SELECT
                    source_id,
                    session_id,
                    user_prompt_offset,
                    COALESCE(
                        MIN(CASE WHEN assistant_start_offset IS NOT NULL
                            THEN source_offset END),
                        MIN(source_offset)
                    ) AS source_offset,
                    MAX(timestamp) AS timestamp,
                    SUM(tokens) AS total_tokens,
                    MAX(CASE WHEN snapshot_rank = 1 THEN input_tokens ELSE 0 END) AS input_tokens,
                    MAX(CASE WHEN snapshot_rank = 1
                        THEN MIN(cached_input_tokens, input_tokens)
                        ELSE 0 END) AS cached_input_tokens,
                    SUM(output_tokens) AS output_tokens,
                    SUM(reasoning_output_tokens) AS reasoning_output_tokens
                FROM snapshots
                GROUP BY source_id, session_id, user_prompt_offset
            ),
            ranked AS (
                SELECT
                    source_id,
                    source_offset,
                    session_id,
                    timestamp,
                    total_tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    CASE WHEN input_tokens > 0
                        THEN cached_input_tokens * 1.0 / input_tokens
                        ELSE 0
                    END AS hit_rate,
                    input_tokens - cached_input_tokens AS uncached_tokens,
                    ROW_NUMBER() OVER (
                        PARTITION BY session_id
                        ORDER BY timestamp, source_id, source_offset
                    ) AS turn_index,
                    COUNT(*) OVER (PARTITION BY session_id) AS session_calls
                FROM grouped
            )
            INSERT INTO dashboard_turn_candidates(
                source_id, source_offset, session_id, timestamp,
                total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens,
                hit_rate, uncached_tokens, turn_index, session_calls
            )
            SELECT
                source_id, source_offset, session_id, timestamp,
                total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens,
                hit_rate, uncached_tokens, turn_index, session_calls
            FROM ranked;

            DELETE FROM dashboard_dirty_sessions;
            """
        )
    }

    private func refreshDashboardSourceAggregates(
        sourceID: Int64,
        sessionID: String,
        affectedBuckets: ClosedRange<Int64>?,
        connection: SQLiteDatabaseConnection
    ) throws {
        let previousBounds = try dashboardBucketBounds(
            sourceID: sourceID,
            connection: connection
        )
        var predicate = ""
        var bindings: [SQLiteBinding] = [.int64(sourceID)]
        if let affectedBuckets {
            predicate = "AND CAST(timestamp / 300 AS INTEGER) * 300 BETWEEN ? AND ?"
            bindings.append(.int64(affectedBuckets.lowerBound))
            bindings.append(.int64(affectedBuckets.upperBound))
            try connection.execute(
                """
                DELETE FROM dashboard_source_5m
                WHERE source_id = ? AND bucket_start BETWEEN ? AND ?;
                """,
                bindings: [
                    .int64(sourceID),
                    .int64(affectedBuckets.lowerBound),
                    .int64(affectedBuckets.upperBound),
                ]
            )
        } else {
            try connection.execute(
                "DELETE FROM dashboard_source_5m WHERE source_id = ?;",
                bindings: [.int64(sourceID)]
            )
        }
        try connection.execute(
            """
            INSERT INTO dashboard_source_5m(
                source_id, bucket_start, model,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls
            )
            SELECT
                source_id,
                CAST(timestamp / 300 AS INTEGER) * 300,
                COALESCE(model, ''),
                SUM(input_tokens),
                SUM(MIN(cached_input_tokens, input_tokens)),
                SUM(output_tokens),
                SUM(reasoning_output_tokens),
                SUM(tokens),
                COUNT(*)
            FROM events
            WHERE source_id = ? \(predicate)
            GROUP BY source_id, CAST(timestamp / 300 AS INTEGER), COALESCE(model, '');
            """,
            bindings: bindings
        )
        let currentBounds = try dashboardBucketBounds(
            sourceID: sourceID,
            connection: connection
        )
        let dirtyBounds = affectedBuckets ?? mergedDashboardBucketBounds(
            previousBounds,
            currentBounds
        )
        if let dirtyBounds {
            try refreshDashboardFiveMinuteAggregates(
                affectedBuckets: dirtyBounds,
                connection: connection
            )
        }
        try connection.execute(
            "DELETE FROM dashboard_source_totals WHERE source_id = ?;",
            bindings: [.int64(sourceID)]
        )
        try connection.execute(
            """
            INSERT INTO dashboard_source_totals(
                source_id, session_id,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls,
                first_timestamp, last_timestamp
            )
            SELECT
                ?, ?,
                SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                SUM(reasoning_output_tokens), SUM(total_tokens), SUM(calls),
                (SELECT MIN(timestamp) FROM events WHERE source_id = ?),
                (SELECT MAX(timestamp) FROM events WHERE source_id = ?)
            FROM dashboard_source_5m
            WHERE source_id = ?
            HAVING SUM(calls) > 0;
            """,
            bindings: [
                .int64(sourceID),
                .text(sessionID),
                .int64(sourceID),
                .int64(sourceID),
                .int64(sourceID),
            ]
        )
    }

    private func dashboardBucketBounds(
        sourceID: Int64,
        connection: SQLiteDatabaseConnection
    ) throws -> ClosedRange<Int64>? {
        let row = try connection.readRows(
            "SELECT MIN(bucket_start), MAX(bucket_start) FROM dashboard_source_5m WHERE source_id = ?;",
            bindings: [.int64(sourceID)]
        ) { ($0.int64(0), $0.int64(1)) }.first
        guard let lower = row?.0, let upper = row?.1 else { return nil }
        return lower...upper
    }

    private func mergedDashboardBucketBounds(
        _ left: ClosedRange<Int64>?,
        _ right: ClosedRange<Int64>?
    ) -> ClosedRange<Int64>? {
        switch (left, right) {
        case let (left?, right?):
            return min(left.lowerBound, right.lowerBound)...max(left.upperBound, right.upperBound)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private func refreshDashboardFiveMinuteAggregates(
        affectedBuckets: ClosedRange<Int64>,
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            "DELETE FROM dashboard_5m WHERE bucket_start BETWEEN ? AND ?;",
            bindings: [
                .int64(affectedBuckets.lowerBound),
                .int64(affectedBuckets.upperBound),
            ]
        )
        try connection.execute(
            """
            INSERT INTO dashboard_5m(
                bucket_start, model,
                input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, total_tokens, calls
            )
            SELECT
                bucket_start, model,
                SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                SUM(reasoning_output_tokens), SUM(total_tokens), SUM(calls)
            FROM dashboard_source_5m
            WHERE bucket_start BETWEEN ? AND ?
            GROUP BY bucket_start, model;
            """,
            bindings: [
                .int64(affectedBuckets.lowerBound),
                .int64(affectedBuckets.upperBound),
            ]
        )
    }

    private func currentAttributionState(
        connection: SQLiteDatabaseConnection
    ) throws -> AttributionState {
        let row = try connection.readRows(
            """
            SELECT
                (SELECT value FROM schema_meta WHERE key = 'provenance_epoch'),
                (SELECT value FROM schema_meta WHERE key = 'attribution_generation'),
                (SELECT value FROM schema_meta WHERE key = 'attribution_unsafe_epoch'),
                (SELECT value FROM schema_meta WHERE key = 'attribution_unsafe_generation'),
                (SELECT value FROM schema_meta
                    WHERE key = 'attribution_current_scan_unsafe_cause');
            """
        ) { statement in
            (
                epoch: statement.text(0),
                generation: statement.text(1).flatMap(Int64.init),
                unsafeEpoch: statement.text(2),
                unsafeGeneration: statement.text(3).flatMap(Int64.init),
                currentScanUnsafeCause: statement.text(4).flatMap(Int.init)
            )
        }.first
        guard let row,
              let provenanceEpoch = row.epoch,
              !provenanceEpoch.isEmpty,
              let generation = row.generation,
              generation >= 0,
              let currentScanUnsafeCause = row.currentScanUnsafeCause,
              currentScanUnsafeCause == 0 || currentScanUnsafeCause == 1,
              (row.unsafeEpoch == nil) == (row.unsafeGeneration == nil),
              row.unsafeGeneration.map({ $0 >= 0 && $0 <= generation }) ?? true else {
            throw SQLiteDatabaseError(
                operation: "Read exact usage attribution state",
                code: SQLITE_CORRUPT,
                message: "Missing or invalid attribution state",
                path: driver.url.path
            )
        }
        return AttributionState(
            provenanceEpoch: provenanceEpoch,
            generation: generation,
            unsafeProvenanceEpoch: row.unsafeEpoch,
            unsafeSinceGeneration: row.unsafeGeneration,
            currentScanUnsafeCauseDetected: currentScanUnsafeCause == 1
        )
    }

    @discardableResult
    private func bumpAttributionGeneration(
        connection: SQLiteDatabaseConnection
    ) throws -> Int64 {
        let current = try currentAttributionState(connection: connection).generation
        guard current < Int64.max else {
            throw SQLiteDatabaseError(
                operation: "Advance exact usage attribution generation",
                code: SQLITE_FULL,
                message: "Attribution generation exhausted",
                path: driver.url.path
            )
        }
        let next = current + 1
        try connection.execute(
            "UPDATE schema_meta SET value = ? WHERE key = 'attribution_generation';",
            bindings: [.text(String(next))]
        )
        return next
    }

    private func markAttributionUnsafe(
        provenanceEpoch: String,
        sinceGeneration: Int64,
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            """
            INSERT INTO schema_meta(key, value)
            VALUES
                ('attribution_unsafe_epoch', ?),
                ('attribution_unsafe_generation', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [
                .text(provenanceEpoch),
                .text(String(sinceGeneration)),
            ]
        )
    }

    private func rotateAttributionProvenance(
        markUnsafe: Bool,
        connection: SQLiteDatabaseConnection
    ) throws -> AttributionState {
        try connection.transaction { transaction in
            try rotateAttributionProvenanceInTransaction(
                markUnsafe: markUnsafe,
                connection: transaction
            )
        }
    }

    private func rotateAttributionProvenanceInTransaction(
        markUnsafe: Bool,
        connection: SQLiteDatabaseConnection
    ) throws -> AttributionState {
            let current = try currentAttributionState(connection: connection)
            let nextEpoch = UUID().uuidString
            try connection.execute(
                "UPDATE schema_meta SET value = ? WHERE key = 'provenance_epoch';",
                bindings: [.text(nextEpoch)]
            )
            try connection.execute(
                """
                INSERT INTO attribution_source_buckets(
                    provenance_epoch,
                    source_lineage,
                    bucket_start,
                    model,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    total_tokens,
                    calls
                )
                SELECT
                    ?,
                    source_lineage,
                    bucket_start,
                    model,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    total_tokens,
                    calls
                FROM attribution_source_buckets
                WHERE provenance_epoch = ?;
                """,
                bindings: [
                    .text(nextEpoch),
                    .text(current.provenanceEpoch),
                ]
            )
            let generation = try bumpAttributionGeneration(connection: connection)
            if markUnsafe {
                try markAttributionUnsafe(
                    provenanceEpoch: nextEpoch,
                    sinceGeneration: generation,
                    connection: connection
                )
            }
            return AttributionState(
                provenanceEpoch: nextEpoch,
                generation: generation,
                unsafeProvenanceEpoch: markUnsafe ? nextEpoch : nil,
                unsafeSinceGeneration: markUnsafe ? generation : nil,
                currentScanUnsafeCauseDetected:
                    current.currentScanUnsafeCauseDetected
            )
    }

    private func backfillAttributionLedger(
        connection: SQLiteDatabaseConnection
    ) throws {
        let state = try currentAttributionState(connection: connection)
        let sources = try connection.readRows(
            "SELECT source_id, session_id FROM sources ORDER BY source_id;"
        ) { row in
            (sourceID: row.int64(0), sessionID: row.text(1))
        }
        var publishedLineages = Set<String>()
        for source in sources {
            guard let sourceID = source.sourceID,
                  let sessionID = source.sessionID else {
                continue
            }
            let lineage = attributionLineage(
                sessionID: sessionID,
                sourceID: sourceID
            )
            guard publishedLineages.insert(lineage.key).inserted else {
                continue
            }
            try publishAttributionLedger(
                lineage: lineage,
                sourceID: sourceID,
                provenanceEpoch: state.provenanceEpoch,
                affectedBuckets: nil,
                replacing: true,
                connection: connection
            )
        }
    }

    private func canonicalSessionID(_ rawValue: String) -> String? {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func attributionLineage(
        sessionID: String,
        sourceID: Int64
    ) -> AttributionLineage {
        if let canonicalSessionID = canonicalSessionID(sessionID) {
            return AttributionLineage(
                key: "session:\(canonicalSessionID)",
                canonicalSessionID: canonicalSessionID
            )
        }
        return AttributionLineage(
            key: "source:\(sourceID)",
            canonicalSessionID: nil
        )
    }

    private func publishAttributionLedger(
        lineage: AttributionLineage,
        sourceID: Int64,
        provenanceEpoch: String,
        affectedBuckets: ClosedRange<Int64>?,
        replacing: Bool,
        preservingExistingMaximum: Bool = false,
        connection: SQLiteDatabaseConnection
    ) throws {
        if replacing {
            try connection.execute(
                """
                DELETE FROM attribution_source_buckets
                WHERE provenance_epoch = ? AND source_lineage = ?;
                """,
                bindings: [
                    .text(provenanceEpoch),
                    .text(lineage.key),
                ]
            )
        }

        var sourcePredicate: String
        var bindings: [SQLiteBinding] = []
        if let canonicalSessionID = lineage.canonicalSessionID {
            // Canonical UUIDs are compared case-insensitively, while keeping
            // the predicate sargable against sources_session_nocase. Applying
            // lower() to the column would force SQLite to scan events first.
            sourcePredicate = "s.session_id COLLATE NOCASE = ?"
            bindings.append(.text(canonicalSessionID))
        } else {
            sourcePredicate = "e.source_id = ?"
            bindings.append(.int64(sourceID))
        }
        var bucketPredicate = ""
        if let affectedBuckets {
            bucketPredicate = """
                AND CAST(e.timestamp / 300 AS INTEGER) * 300 BETWEEN ? AND ?
                """
            bindings.append(.int64(affectedBuckets.lowerBound))
            bindings.append(.int64(affectedBuckets.upperBound))
        }
        bindings.append(.text(provenanceEpoch))
        bindings.append(.text(lineage.key))
        let conflictUpdate = if preservingExistingMaximum {
            """
            input_tokens = MAX(attribution_source_buckets.input_tokens, excluded.input_tokens),
            cached_input_tokens = MAX(attribution_source_buckets.cached_input_tokens, excluded.cached_input_tokens),
            output_tokens = MAX(attribution_source_buckets.output_tokens, excluded.output_tokens),
            reasoning_output_tokens = MAX(attribution_source_buckets.reasoning_output_tokens, excluded.reasoning_output_tokens),
            total_tokens = MAX(attribution_source_buckets.total_tokens, excluded.total_tokens),
            calls = MAX(attribution_source_buckets.calls, excluded.calls)
            """
        } else {
            """
            input_tokens = excluded.input_tokens,
            cached_input_tokens = excluded.cached_input_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_output_tokens = excluded.reasoning_output_tokens,
            total_tokens = excluded.total_tokens,
            calls = excluded.calls
            """
        }

        try connection.execute(
            """
            WITH per_source AS (
                SELECT
                    e.source_id,
                    CAST(e.timestamp / 300 AS INTEGER) * 300 AS bucket_start,
                    COALESCE(e.model, '') AS model,
                    SUM(e.input_tokens) AS input_tokens,
                    SUM(e.cached_input_tokens) AS cached_input_tokens,
                    SUM(e.output_tokens) AS output_tokens,
                    SUM(e.reasoning_output_tokens) AS reasoning_output_tokens,
                    SUM(e.tokens) AS total_tokens,
                    COUNT(*) AS calls
                FROM events e
                JOIN sources s ON s.source_id = e.source_id
                WHERE \(sourcePredicate)
                \(bucketPredicate)
                GROUP BY e.source_id, CAST(e.timestamp / 300 AS INTEGER), COALESCE(e.model, '')
            )
            INSERT INTO attribution_source_buckets(
                provenance_epoch,
                source_lineage,
                bucket_start,
                model,
                input_tokens,
                cached_input_tokens,
                output_tokens,
                reasoning_output_tokens,
                total_tokens,
                calls
            )
            SELECT
                ?,
                ?,
                bucket_start,
                model,
                MAX(input_tokens),
                MAX(cached_input_tokens),
                MAX(output_tokens),
                MAX(reasoning_output_tokens),
                MAX(total_tokens),
                MAX(calls)
            FROM per_source
            GROUP BY bucket_start, model
            ON CONFLICT(provenance_epoch, source_lineage, bucket_start, model)
            DO UPDATE SET
                \(conflictUpdate);
            """,
            bindings: bindings
        )
    }

    private func prepareSessionCatalogSchema(
        _ connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS session_catalog_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        let currentVersion = try connection.readRows(
            """
            SELECT value
            FROM session_catalog_meta
            WHERE key = 'schema_version'
            LIMIT 1;
            """
        ) { row in
            row.text(0)
        }.first ?? nil
        if let currentVersion,
           currentVersion != Self.sessionCatalogSchemaVersion {
            throw SQLiteDatabaseError(
                operation: "Prepare exact usage session catalog",
                code: SQLITE_MISMATCH,
                message: "Session catalog schema \(currentVersion) is newer or unknown; refusing to rewrite it",
                path: driver.url.path
            )
        }
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS session_catalog_entries (
                path TEXT PRIMARY KEY,
                archived INTEGER NOT NULL,
                thread_id TEXT NOT NULL,
                cwd TEXT NOT NULL,
                session_id TEXT,
                forked_from_id TEXT,
                parent_thread_id TEXT,
                source TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                modified_seconds INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                created_seconds INTEGER NOT NULL,
                created_nanoseconds INTEGER NOT NULL,
                device_id TEXT NOT NULL,
                inode TEXT NOT NULL,
                status_changed_seconds INTEGER NOT NULL,
                status_changed_nanoseconds INTEGER NOT NULL,
                first_line_end_offset INTEGER NOT NULL,
                first_line_sha256 TEXT NOT NULL,
                last_seen_generation TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS session_catalog_thread_id
                ON session_catalog_entries(thread_id, path);

            INSERT INTO session_catalog_meta(key, value)
            VALUES ('schema_version', '\(Self.sessionCatalogSchemaVersion)')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
    }

    private func migrateV2SourcesForAppend(
        _ connection: SQLiteDatabaseConnection
    ) throws {
        let existingColumns = Set(
            try connection.readRows("PRAGMA table_info(sources);") { row in
                row.text(1) ?? ""
            }
        )
        let additions = [
            ("append_ready", "INTEGER NOT NULL DEFAULT 0"),
            ("resume_offset", "INTEGER"),
            ("previous_total_tokens", "INTEGER"),
            ("fork_replay_started_at", "REAL"),
            ("is_skipping_fork_replay", "INTEGER NOT NULL DEFAULT 0"),
            ("is_explicit_subagent_fork", "INTEGER NOT NULL DEFAULT 0"),
            ("last_skipped_fork_replay_token_at", "REAL"),
            ("current_user_prompt_offset", "INTEGER"),
            ("assistant_start_offset", "INTEGER"),
            ("current_model", "TEXT"),
            ("audit_chunk_index", "INTEGER NOT NULL DEFAULT 0")
        ]
        for (column, definition) in additions where !existingColumns.contains(column) {
            try connection.execute(
                "ALTER TABLE sources ADD COLUMN \(column) \(definition);"
            )
        }
    }

    private func migrateKnownEventColumns(
        _ connection: SQLiteDatabaseConnection
    ) throws {
        let tableExists = try connection.readRows(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'events';
            """
        ) { ($0.int(0) ?? 0) > 0 }.first ?? false
        guard tableExists else { return }
        let columns = Set(
            try connection.readRows("PRAGMA table_info(events);") { row in
                row.text(1) ?? ""
            }
        )
        if !columns.contains("model") {
            try connection.execute("ALTER TABLE events ADD COLUMN model TEXT;")
        }
    }

    private func migrateEventEnrichmentReceiptColumns(
        _ connection: SQLiteDatabaseConnection
    ) throws {
        let tableExists = try connection.readRows(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'event_enrichment_sources';
            """
        ) { ($0.int(0) ?? 0) > 0 }.first ?? false
        guard tableExists else { return }
        var columns = Set(
            try connection.readRows("PRAGMA table_info(event_enrichment_sources);") {
                $0.text(1) ?? ""
            }
        )
        for (column, definition) in [
            ("canonical_path", "TEXT NOT NULL DEFAULT ''"),
            ("parser_revision", "TEXT NOT NULL DEFAULT ''"),
            ("device_id", "TEXT NOT NULL DEFAULT ''"),
            ("inode", "TEXT NOT NULL DEFAULT ''"),
            ("imported_generation", "TEXT NOT NULL DEFAULT ''"),
        ] where !columns.contains(column) {
            try connection.execute(
                "ALTER TABLE event_enrichment_sources ADD COLUMN \(column) \(definition);"
            )
            columns.insert(column)
        }
        try connection.execute(
            """
            UPDATE event_enrichment_sources
            SET canonical_path = COALESCE((
                    SELECT sources.path FROM sources
                    WHERE sources.source_id = event_enrichment_sources.source_id
                ), canonical_path),
                parser_revision = CASE
                    WHEN revision = ? THEN ? ELSE parser_revision END,
                device_id = COALESCE((
                    SELECT sources.device_id FROM sources
                    WHERE sources.source_id = event_enrichment_sources.source_id
                ), device_id),
                inode = COALESCE((
                    SELECT sources.inode FROM sources
                    WHERE sources.source_id = event_enrichment_sources.source_id
                ), inode),
                imported_generation = COALESCE((
                    SELECT sources.last_seen_generation FROM sources
                    WHERE sources.source_id = event_enrichment_sources.source_id
                ), imported_generation)
            WHERE canonical_path = '' OR parser_revision = ''
               OR device_id = '' OR inode = '' OR imported_generation = '';
            """,
            bindings: [
                .text(Self.eventEnrichmentRevision),
                .text(Self.stagingParserRevision),
            ]
        )
    }

    /// Marks only active replay sources whose first line proves an explicit
    /// subagent fork for an atomic single-file replacement on the next normal
    /// synchronization. The currently published rows remain readable until
    /// that replacement is committed; migration never deletes token events or
    /// rescans the full JSONL corpus.
    private func repairExplicitSubagentReplayBoundary(
        _ connection: SQLiteDatabaseConnection,
        persistRevision: Bool = true
    ) throws -> Bool {
        let tableExists = try connection.readRows(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name = 'sources';
            """
        ) { ($0.int(0) ?? 0) > 0 }.first ?? false
        guard tableExists else { return false }
        let storedRevision = try connection.readRows(
            """
            SELECT value FROM schema_meta
            WHERE key = 'fork_replay_boundary_revision' LIMIT 1;
            """
        ) { $0.text(0) }.first ?? nil
        guard storedRevision != Self.forkReplayBoundaryRevision else { return true }

        let candidates = try connection.readRows(
            """
            SELECT source_id, path
            FROM sources
            WHERE is_skipping_fork_replay = 1
              AND is_explicit_subagent_fork = 0;
            """
        ) { row in
            (id: row.int64(0), path: row.text(1))
        }
        var unresolvedCandidate = false
        for candidate in candidates {
            guard let sourceID = candidate.id,
                  let path = candidate.path else {
                unresolvedCandidate = true
                continue
            }
            switch probeExplicitSubagentSessionFile(URL(fileURLWithPath: path)) {
            case .explicit:
                // A mismatched probe schedules an atomic single-file rebuild
                // while leaving the currently published rows available to
                // readers.
                try connection.execute(
                    """
                    UPDATE sources
                    SET is_explicit_subagent_fork = 1,
                        append_ready = 0,
                        resume_offset = NULL,
                        content_probe = ?
                    WHERE source_id = ?;
                    """,
                    bindings: [
                        .text("migration:\(Self.forkReplayBoundaryRevision)"),
                        .int64(sourceID)
                    ]
                )
            case .nonExplicit:
                break
            case .unresolved:
                // Do not make an unreadable or incomplete candidate look
                // migrated. A later startup must retry it without blocking
                // the dashboard from using the already-published rows.
                unresolvedCandidate = true
            }
        }

        guard !unresolvedCandidate else {
            return false
        }

        if persistRevision {
            try connection.execute(
                """
                INSERT INTO schema_meta(key, value)
                VALUES ('fork_replay_boundary_revision', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                bindings: [.text(Self.forkReplayBoundaryRevision)]
            )
        }
        return true
    }

    private func probeExplicitSubagentSessionFile(
        _ file: URL
    ) -> ExplicitSubagentSessionFileProbe {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unresolved }
        defer { try? handle.close() }
        var firstLine = Data()
        while true {
            let remaining = Self.explicitSubagentFirstLineLimit + 1 - firstLine.count
            let chunk = handle.readData(ofLength: min(64 * 1_024, remaining))
            guard !chunk.isEmpty else { return .unresolved }
            if let newline = chunk.firstIndex(of: 0x0A) {
                guard firstLine.count + chunk.distance(from: chunk.startIndex, to: newline)
                    <= Self.explicitSubagentFirstLineLimit else {
                    return .unresolved
                }
                firstLine.append(contentsOf: chunk[..<newline])
                break
            }
            firstLine.append(contentsOf: chunk)
            guard firstLine.count <= Self.explicitSubagentFirstLineLimit else {
                return .unresolved
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else {
            return .unresolved
        }
        guard object["type"] as? String == "session_meta" else {
            return .nonExplicit
        }
        guard let payload = object["payload"] as? [String: Any] else {
            return .unresolved
        }
        guard let forkedFromID = payload["forked_from_id"] as? String,
              !forkedFromID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nonExplicit
        }
        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        if subagent?["thread_spawn"] is [String: Any] { return .explicit }
        if (payload["thread_source"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "subagent" {
            return .explicit
        }
        let hasExplicitAgentIdentity = ["agent_role", "agent_path"].contains { key in
            guard let value = payload[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasExplicitAgentIdentity ? .explicit : .nonExplicit
    }

    private func configure(_ connection: SQLiteDatabaseConnection) throws {
        try connection.execute(
            """
            PRAGMA foreign_keys=ON;
            PRAGMA temp_store=FILE;
            PRAGMA cache_size=-8192;
            PRAGMA mmap_size=0;
            """
        )
    }

    private func indexedSource(
        path: String,
        connection: SQLiteDatabaseConnection
    ) throws -> IndexedSource? {
        let rows: [IndexedSource] = try connection.readRows(
            """
            SELECT
                source_id,
                size_bytes,
                modified_at,
                content_probe,
                device_id,
                inode,
                status_changed_seconds,
                status_changed_nanoseconds,
                append_ready,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_at,
                is_skipping_fork_replay,
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_at,
                current_user_prompt_offset,
                assistant_start_offset,
                current_model,
                audit_chunk_index,
                session_id
            FROM sources
            WHERE path = ?
            LIMIT 1;
            """,
            bindings: [.text(path)]
        ) { row in
            try decodeIndexedSource(row, startingAt: 0)
        }
        return rows.first
    }

    /// Loads the small source catalog once per synchronization. The previous
    /// implementation issued one SQLite query per JSONL file, which amplified
    /// cold-page I/O into thousands of random reads on every refresh.
    private func indexedSources(
        connection: SQLiteDatabaseConnection
    ) throws -> [String: IndexedSource] {
        let rows: [(String, IndexedSource)] = try connection.readRows(
            """
            SELECT
                path,
                source_id,
                size_bytes,
                modified_at,
                content_probe,
                device_id,
                inode,
                status_changed_seconds,
                status_changed_nanoseconds,
                append_ready,
                resume_offset,
                previous_total_tokens,
                fork_replay_started_at,
                is_skipping_fork_replay,
                is_explicit_subagent_fork,
                last_skipped_fork_replay_token_at,
                current_user_prompt_offset,
                assistant_start_offset,
                current_model,
                audit_chunk_index,
                session_id
            FROM sources
            ORDER BY source_id;
            """
        ) { row in
            guard let path = row.text(0), !path.isEmpty else {
                throw malformedIndexedSourceError("missing source path")
            }
            return (path, try decodeIndexedSource(row, startingAt: 1))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func decodeIndexedSource(
        _ row: SQLiteStatement,
        startingAt offset: Int32
    ) throws -> IndexedSource {
        guard let sourceID = row.int64(offset),
              let sessionID = row.text(offset + 19),
              let rawSize = row.int64(offset + 1),
              rawSize >= 0,
              let modifiedAt = row.double(offset + 2),
              let probe = row.text(offset + 3),
              let rawDeviceID = row.text(offset + 4),
              let deviceID = UInt64(rawDeviceID),
              let rawInode = row.text(offset + 5),
              let inode = UInt64(rawInode),
              let statusChangedSeconds = row.int64(offset + 6),
              let statusChangedNanoseconds = row.int64(offset + 7) else {
            throw malformedIndexedSourceError("invalid required source fields")
        }
        let checkpoint: SourceCheckpoint?
        if row.int(offset + 8) == 1,
           let rawResumeOffset = row.int64(offset + 9),
           rawResumeOffset >= 0 {
            checkpoint = SourceCheckpoint(
                resumeOffset: UInt64(rawResumeOffset),
                parserState: CodexUsageAnalyzer.IndexedSessionParserState(
                    previousTotalTokens: row.int(offset + 10),
                    forkReplayStartedAt: row.double(offset + 11).map {
                        Date(timeIntervalSince1970: $0)
                    },
                    isSkippingForkReplay: row.int(offset + 12) == 1,
                    isExplicitSubagentFork: row.int(offset + 13) == 1,
                    lastSkippedForkReplayTokenAt: row.double(offset + 14).map {
                        Date(timeIntervalSince1970: $0)
                    },
                    currentUserPromptOffset: row.int64(offset + 15).flatMap {
                        $0 >= 0 ? UInt64($0) : nil
                    },
                    assistantStartOffset: row.int64(offset + 16).flatMap {
                        $0 >= 0 ? UInt64($0) : nil
                    },
                    currentModel: row.text(offset + 17)
                ),
                auditChunkIndex: row.int64(offset + 18).flatMap {
                    $0 >= 0 ? UInt64($0) : nil
                } ?? 0
            )
        } else {
            checkpoint = nil
        }
        return IndexedSource(
            id: sourceID,
            sessionID: sessionID,
            signature: SourceSignature(
                size: UInt64(rawSize),
                modifiedAt: modifiedAt,
                contentProbe: probe,
                deviceID: deviceID,
                inode: inode,
                statusChangedSeconds: statusChangedSeconds,
                statusChangedNanoseconds: statusChangedNanoseconds
            ),
            checkpoint: checkpoint
        )
    }

    private func malformedIndexedSourceError(_ reason: String) -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: "Decode exact usage source catalog",
            code: SQLITE_CORRUPT,
            message: reason,
            path: driver.url.path
        )
    }

    private func indexedSourceIdentities(
        connection: SQLiteDatabaseConnection
    ) throws -> [SourceIdentity] {
        try connection.readRows(
            "SELECT source_id, path, session_id FROM sources ORDER BY source_id;"
        ) { row -> SourceIdentity? in
            guard let sourceID = row.int64(0),
                  let path = row.text(1) else {
                return nil
            }
            return SourceIdentity(id: sourceID, path: path, sessionID: row.text(2))
        }.compactMap { $0 }
    }

    private func eventEnrichmentPendingSourceIDs(
        connection: SQLiteDatabaseConnection
    ) throws -> Set<Int64> {
        Set(try connection.readRows(
            """
            SELECT s.source_id
            FROM sources s
            LEFT JOIN event_enrichment_sources e
              ON e.source_id = s.source_id
             AND e.revision = ?
             AND e.canonical_path = s.path
             AND e.parser_revision = ?
             AND e.device_id = s.device_id
             AND e.inode = s.inode
             AND e.imported_generation = s.last_seen_generation
             AND e.completed_size = s.size_bytes
             AND e.completed_probe = s.content_probe
            WHERE e.source_id IS NULL
            ORDER BY s.source_id;
            """,
            bindings: [
                .text(Self.eventEnrichmentRevision),
                .text(Self.stagingParserRevision),
            ]
        ) { $0.int64(0) }.compactMap { $0 })
    }

    private func markEventEnrichmentComplete(
        sourceID: Int64,
        canonicalPath: String,
        generation: String,
        signature: SourceSignature,
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            """
            INSERT INTO event_enrichment_sources(
                source_id, revision, canonical_path, parser_revision,
                device_id, inode, imported_generation,
                completed_size, completed_probe
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                revision = excluded.revision,
                canonical_path = excluded.canonical_path,
                parser_revision = excluded.parser_revision,
                device_id = excluded.device_id,
                inode = excluded.inode,
                imported_generation = excluded.imported_generation,
                completed_size = excluded.completed_size,
                completed_probe = excluded.completed_probe;
            """,
            bindings: [
                .int64(sourceID),
                .text(Self.eventEnrichmentRevision),
                .text(canonicalPath),
                .text(Self.stagingParserRevision),
                .text(String(signature.deviceID)),
                .text(String(signature.inode)),
                .text(generation),
                .int64(try sqliteInt64(signature.size)),
                .text(signature.contentProbe),
            ]
        )
    }

    @discardableResult
    private func finalizeEventEnrichmentIfComplete(
        connection: SQLiteDatabaseConnection
    ) throws -> Bool {
        guard try eventEnrichmentPendingSourceIDs(connection: connection).isEmpty else {
            return false
        }
        let replayRevision = try connection.readRows(
            "SELECT value FROM schema_meta WHERE key = 'fork_replay_boundary_revision' LIMIT 1;"
        ) { $0.text(0) }.first ?? nil
        let provenanceRevision = try connection.readRows(
            "SELECT value FROM schema_meta WHERE key = 'provenance_revision' LIMIT 1;"
        ) { $0.text(0) }.first ?? nil
        let catalogVersion = try connection.readRows(
            "SELECT value FROM session_catalog_meta WHERE key = 'schema_version' LIMIT 1;"
        ) { $0.text(0) }.first ?? nil
        guard replayRevision == Self.forkReplayBoundaryRevision,
              provenanceRevision == Self.attributionProvenanceRevision,
              catalogVersion == Self.sessionCatalogSchemaVersion else {
            return false
        }
        try connection.execute(
            """
            INSERT INTO schema_meta(key, value)
            VALUES
                (?, ?),
                ('schema_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [
                .text(Self.eventEnrichmentRevisionKey),
                .text(Self.eventEnrichmentRevision),
                .text(Self.schemaVersion),
            ]
        )
        return true
    }

    private func canAttemptAppend(
        from source: IndexedSource,
        to observed: SourceSignature
    ) -> Bool {
        guard let checkpoint = source.checkpoint else { return false }
        return observed.size > source.signature.size
            && observed.deviceID == source.signature.deviceID
            && observed.inode == source.signature.inode
            && checkpoint.resumeOffset <= source.signature.size
    }

    private func appendSource(
        file: URL,
        sessionID: String,
        existing: IndexedSource,
        generation: String,
        connection: SQLiteDatabaseConnection,
        parser: SessionParser
    ) throws -> CodexUsageAnalyzer.IndexedSessionParseResult? {
        guard let checkpoint = existing.checkpoint,
              try auditCheckpointChunk(
                  file: file,
                  source: existing,
                  checkpoint: checkpoint,
                  connection: connection
              ) else {
            return nil
        }
        let readHandle = try FileHandle(forReadingFrom: file)
        defer { try? readHandle.close() }
        let formalSignature = try sourceSignature(
            forOpenHandle: readHandle,
            file: file
        )
        guard formalSignature.deviceID == existing.signature.deviceID,
              formalSignature.inode == existing.signature.inode,
              formalSignature.size > existing.signature.size else {
            return nil
        }

        let tailChunkIndex = existing.signature.size > 0
            ? (existing.signature.size - 1) / Self.chunkSize
            : nil
        let storedTail: CodexUsageAnalyzer.IndexedChunkHash?
        if let tailChunkIndex {
            storedTail = try storedSourceChunk(
                sourceID: existing.id,
                index: tailChunkIndex,
                connection: connection
            )
            guard storedTail != nil else { return nil }
        } else {
            storedTail = nil
        }
        // The parser state is valid at resumeOffset (the start of the last
        // complete line or the unfinished tail). Hash from the containing
        // chunk boundary, then skip to resumeOffset for parsing. An open JSON
        // line may cross the old tail chunk; that is still an append and must
        // not force a full-file rebuild.
        let resumeChunkIndex = checkpoint.resumeOffset / Self.chunkSize
        // At an exact chunk boundary, the previous chunk is the last
        // committed chunk and is still needed for validationChunkHash. Treat
        // the boundary as belonging to that previous chunk for hashing while
        // keeping parsing at the persisted resume offset.
        let hashingStartChunkIndex = checkpoint.resumeOffset > 0
            && checkpoint.resumeOffset % Self.chunkSize == 0
            ? resumeChunkIndex - 1
            : resumeChunkIndex
        let hashingStartOffset = hashingStartChunkIndex * Self.chunkSize

        do {
            return try connection.transaction { transaction in
                var firstAffectedAttributionBucket: Int64?
                var lastAffectedAttributionBucket: Int64?
                let persistentFingerprintStatement = try transaction.prepare(
                    "INSERT OR IGNORE INTO source_fingerprints(source_id, value) VALUES (?, ?);"
                )
                let eventStatement = try transaction.prepare(
                    """
                    INSERT INTO events(
                        source_id,
                        source_offset,
                        timestamp,
                        tokens,
                        input_tokens,
                        cached_input_tokens,
                        output_tokens,
                        reasoning_output_tokens,
                        model,
                        user_prompt_offset,
                        assistant_start_offset
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                )

                let result = try parser(
                    file,
                    sessionID,
                    CodexUsageAnalyzer.IndexedSessionParseRequest(
                        hashingStartOffset: hashingStartOffset,
                        parsingStartOffset: checkpoint.resumeOffset,
                        endOffset: formalSignature.size,
                        validationBoundary: existing.signature.size,
                        initialState: checkpoint.parserState,
                        readHandle: readHandle
                    ),
                    { fingerprint in
                        let key = fingerprint.databaseKey
                        return try persistentFingerprintStatement.execute([
                            .int64(existing.id),
                            .text(key)
                        ]) > 0
                    },
                    { indexedEvent in
                        let event = indexedEvent.event
                        let bucketStart = try attributionBucketStart(for: event.timestamp)
                        firstAffectedAttributionBucket = min(
                            firstAffectedAttributionBucket ?? bucketStart,
                            bucketStart
                        )
                        lastAffectedAttributionBucket = max(
                            lastAffectedAttributionBucket ?? bucketStart,
                            bucketStart
                        )
                        let userPromptOffset: SQLiteBinding = if let offset = indexedEvent.userPromptOffset {
                            .int64(try sqliteInt64(offset))
                        } else {
                            .null
                        }
                        let assistantStartOffset: SQLiteBinding = if let offset = indexedEvent.assistantStartOffset {
                            .int64(try sqliteInt64(offset))
                        } else {
                            .null
                        }
                        try eventStatement.execute([
                            .int64(existing.id),
                            .int64(try sqliteInt64(indexedEvent.sourceOffset)),
                            .date(event.timestamp),
                            .int(event.tokens),
                            .int(event.inputTokens),
                            .int(min(event.cachedInputTokens, event.inputTokens)),
                            .int(event.outputTokens),
                            .int(event.reasoningOutputTokens),
                            event.model.map(SQLiteBinding.text) ?? .null,
                            userPromptOffset,
                            assistantStartOffset
                        ])
                    }
                )

                guard result.lastOffset == formalSignature.size else {
                    throw CodexUsageSourceChangedError(path: file.path)
                }
                if existing.signature.size > 0,
                   result.validationChunkHash != storedTail {
                    throw AppendCheckpointError.rejected
                }
                try validateAppendScan(
                    file: file,
                    readHandle: readHandle,
                    observedSignature: formalSignature,
                    chunkHashes: result.chunkHashes
                )
                try replaceSourceChunks(
                    sourceID: existing.id,
                    startingAt: hashingStartChunkIndex,
                    chunks: result.chunkHashes,
                    connection: transaction
                )
                let oldChunkCount = chunkCount(for: existing.signature.size)
                let nextAuditChunk = oldChunkCount == 0
                    ? 0
                    : (checkpoint.auditChunkIndex + 1) % oldChunkCount
                try saveSourceCheckpoint(
                    sourceID: existing.id,
                    sessionID: sessionID,
                    signature: formalSignature,
                    generation: generation,
                    parseResult: result,
                    auditChunkIndex: nextAuditChunk,
                    connection: transaction
                )
                try markEventEnrichmentComplete(
                    sourceID: existing.id,
                    canonicalPath: file.path,
                    generation: generation,
                    signature: formalSignature,
                    connection: transaction
                )
                if let firstAffectedAttributionBucket,
                   let lastAffectedAttributionBucket {
                    let state = try currentAttributionState(connection: transaction)
                    try publishAttributionLedger(
                        lineage: attributionLineage(
                            sessionID: sessionID,
                            sourceID: existing.id
                        ),
                        sourceID: existing.id,
                        provenanceEpoch: state.provenanceEpoch,
                        affectedBuckets:
                            firstAffectedAttributionBucket...lastAffectedAttributionBucket,
                        replacing: false,
                        connection: transaction
                    )
                    try refreshDashboardSourceAggregates(
                        sourceID: existing.id,
                        sessionID: sessionID,
                        affectedBuckets:
                            firstAffectedAttributionBucket...lastAffectedAttributionBucket,
                        connection: transaction
                    )
                }
                return result
            }
        } catch AppendCheckpointError.rejected {
            return nil
        }
    }

    private func auditCheckpointChunk(
        file: URL,
        source: IndexedSource,
        checkpoint: SourceCheckpoint,
        connection: SQLiteDatabaseConnection
    ) throws -> Bool {
        let count = chunkCount(for: source.signature.size)
        guard count > 0 else { return true }
        let tailIndex = count - 1
        let auditIndex = checkpoint.auditChunkIndex % count
        guard auditIndex != tailIndex else { return true }
        guard let stored = try storedSourceChunk(
            sourceID: source.id,
            index: auditIndex,
            connection: connection
        ) else {
            return false
        }
        return try hashSourceChunk(
            file: file,
            index: stored.index,
            byteCount: stored.byteCount
        ) == stored
    }

    private func storedSourceChunk(
        sourceID: Int64,
        index: UInt64,
        connection: SQLiteDatabaseConnection
    ) throws -> CodexUsageAnalyzer.IndexedChunkHash? {
        let rows: [CodexUsageAnalyzer.IndexedChunkHash?] = try connection.readRows(
            """
            SELECT byte_count, sha256
            FROM source_chunks
            WHERE source_id = ? AND chunk_index = ?
            LIMIT 1;
            """,
            bindings: [
                .int64(sourceID),
                .int64(try sqliteInt64(index))
            ]
        ) { row in
            guard let rawByteCount = row.int64(0),
                  rawByteCount >= 0,
                  let sha256 = row.text(1) else {
                return nil
            }
            return CodexUsageAnalyzer.IndexedChunkHash(
                index: index,
                byteCount: UInt64(rawByteCount),
                sha256: sha256
            )
        }
        return rows.compactMap { $0 }.first
    }

    private func hashSourceChunk(
        file: URL,
        index: UInt64,
        byteCount: UInt64
    ) throws -> CodexUsageAnalyzer.IndexedChunkHash {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try hashSourceChunk(
            file: file,
            readHandle: handle,
            index: index,
            byteCount: byteCount
        )
    }

    private func hashSourceChunk(
        file: URL,
        readHandle: FileHandle,
        index: UInt64,
        byteCount: UInt64
    ) throws -> CodexUsageAnalyzer.IndexedChunkHash {
        let (offset, overflow) = index.multipliedReportingOverflow(by: Self.chunkSize)
        guard !overflow else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
        try readHandle.seek(toOffset: offset)
        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            let data = readHandle.readData(ofLength: Int(min(remaining, 1_048_576)))
            guard !data.isEmpty else {
                throw CodexUsageSourceChangedError(path: file.path)
            }
            hasher.update(data: data)
            remaining -= UInt64(data.count)
        }
        return CodexUsageAnalyzer.IndexedChunkHash(
            index: index,
            byteCount: byteCount,
            sha256: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func validateAppendScan(
        file: URL,
        readHandle: FileHandle,
        observedSignature: SourceSignature,
        chunkHashes: [CodexUsageAnalyzer.IndexedChunkHash]
    ) throws {
        let handleSignature = try sourceSignature(
            forOpenHandle: readHandle,
            file: file
        )
        let pathSignature = try sourceSignature(for: file)
        guard handleSignature != observedSignature
                || pathSignature != observedSignature else { return }
        guard handleSignature.deviceID == observedSignature.deviceID,
              handleSignature.inode == observedSignature.inode,
              handleSignature.size >= observedSignature.size,
              pathSignature.deviceID == observedSignature.deviceID,
              pathSignature.inode == observedSignature.inode,
              pathSignature.size >= observedSignature.size else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
        guard observedSignature.size > 0 else { return }
        let tailIndex = (observedSignature.size - 1) / Self.chunkSize
        let byteCount = observedSignature.size - tailIndex * Self.chunkSize
        guard let scannedTail = chunkHashes.first(where: { $0.index == tailIndex }),
              try hashSourceChunk(
                  file: file,
                  readHandle: readHandle,
                  index: tailIndex,
                  byteCount: byteCount
              ) == scannedTail,
              try hashSourceChunk(
                  file: file,
                  index: tailIndex,
                  byteCount: byteCount
              ) == scannedTail,
              handleSignature.size > observedSignature.size
                || pathSignature.size > observedSignature.size else {
            throw CodexUsageSourceChangedError(path: file.path)
        }
    }

    private func chunkCount(for size: UInt64) -> UInt64 {
        size == 0 ? 0 : (size - 1) / Self.chunkSize + 1
    }

    private func replaceSourceChunks(
        sourceID: Int64,
        startingAt: UInt64,
        chunks: [CodexUsageAnalyzer.IndexedChunkHash],
        connection: SQLiteDatabaseConnection
    ) throws {
        try connection.execute(
            "DELETE FROM source_chunks WHERE source_id = ? AND chunk_index >= ?;",
            bindings: [
                .int64(sourceID),
                .int64(try sqliteInt64(startingAt))
            ]
        )
        let statement = try connection.prepare(
            """
            INSERT INTO source_chunks(source_id, chunk_index, byte_count, sha256)
            VALUES (?, ?, ?, ?);
            """
        )
        for chunk in chunks {
            _ = try statement.execute([
                .int64(sourceID),
                .int64(try sqliteInt64(chunk.index)),
                .int64(try sqliteInt64(chunk.byteCount)),
                .text(chunk.sha256)
            ])
        }
    }

    private func saveSourceCheckpoint(
        sourceID: Int64,
        sessionID: String,
        signature: SourceSignature,
        generation: String,
        parseResult: CodexUsageAnalyzer.IndexedSessionParseResult,
        auditChunkIndex: UInt64,
        connection: SQLiteDatabaseConnection
    ) throws {
        let state = parseResult.state
        try connection.execute(
            """
            UPDATE sources
            SET
                session_id = ?,
                size_bytes = ?,
                modified_at = ?,
                content_probe = ?,
                device_id = ?,
                inode = ?,
                status_changed_seconds = ?,
                status_changed_nanoseconds = ?,
                last_seen_generation = ?,
                append_ready = 1,
                resume_offset = ?,
                previous_total_tokens = ?,
                fork_replay_started_at = ?,
                is_skipping_fork_replay = ?,
                is_explicit_subagent_fork = ?,
                last_skipped_fork_replay_token_at = ?,
                current_user_prompt_offset = ?,
                assistant_start_offset = ?,
                current_model = ?,
                audit_chunk_index = ?
            WHERE source_id = ?;
            """,
            bindings: [
                .text(sessionID),
                .int64(try sqliteInt64(signature.size)),
                .double(signature.modifiedAt),
                .text(signature.contentProbe),
                .text(String(signature.deviceID)),
                .text(String(signature.inode)),
                .int64(signature.statusChangedSeconds),
                .int64(signature.statusChangedNanoseconds),
                .text(generation),
                .int64(try sqliteInt64(parseResult.resumeOffset)),
                state.previousTotalTokens.map(SQLiteBinding.int) ?? .null,
                state.forkReplayStartedAt.map(SQLiteBinding.date) ?? .null,
                .int(state.isSkippingForkReplay ? 1 : 0),
                .int(state.isExplicitSubagentFork ? 1 : 0),
                state.lastSkippedForkReplayTokenAt.map(SQLiteBinding.date) ?? .null,
                try state.currentUserPromptOffset.map {
                    .int64(try sqliteInt64($0))
                } ?? .null,
                try state.assistantStartOffset.map {
                    .int64(try sqliteInt64($0))
                } ?? .null,
                state.currentModel.map(SQLiteBinding.text) ?? .null,
                .int64(try sqliteInt64(auditChunkIndex)),
                .int64(sourceID)
            ]
        )
    }

    private final class StageCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [StagedFullRebuild] = []
        private var firstError: Error?
        private var completedEventEnrichmentJobs = 0

        func append(_ value: StagedFullRebuild) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
            guard value.job.reason == .eventEnrichment else { return nil }
            completedEventEnrichmentJobs += 1
            return completedEventEnrichmentJobs
        }

        func record(_ error: Error) {
            lock.lock()
            if firstError == nil {
                firstError = error
            }
            lock.unlock()
        }

        func result() throws -> [StagedFullRebuild] {
            lock.lock()
            defer { lock.unlock() }
            if let firstError {
                throw firstError
            }
            return values
        }
    }

    private final class SessionParserBox: @unchecked Sendable {
        let parser: SessionParser

        init(_ parser: @escaping SessionParser) {
            self.parser = parser
        }
    }

    private final class EventEnrichmentProgressBox: @unchecked Sendable {
        let callback: (Int, Int) -> Void

        init(_ callback: @escaping (Int, Int) -> Void) {
            self.callback = callback
        }
    }

    private func stagingBatches(for jobs: [FullRebuildJob]) -> [[FullRebuildJob]] {
        guard !jobs.isEmpty else { return [] }
        let sorted = jobs.sorted {
            if $0.observedSignature.size == $1.observedSignature.size {
                return $0.file.path < $1.file.path
            }
            return $0.observedSignature.size > $1.observedSignature.size
        }
        let artifactLimit = min(
            Self.stagingMaxWorkers,
            Self.stagingMaxReadyArtifacts
        )
        var heavy = sorted.filter {
            $0.observedSignature.size >= coldBuildHeavyFileThreshold
        }
        var light = sorted.filter {
            $0.observedSignature.size < coldBuildHeavyFileThreshold
        }
        var batches: [[FullRebuildJob]] = []

        func fillBatch(startingWith first: FullRebuildJob?) -> [FullRebuildJob] {
            var batch = first.map { [$0] } ?? []
            var bytes = first?.observedSignature.size ?? 0
            while batch.count < artifactLimit, let candidate = light.first {
                let candidateBytes = candidate.observedSignature.size
                let remaining = Self.stagingPlannedReadyBytes > bytes
                    ? Self.stagingPlannedReadyBytes - bytes
                    : 0
                guard batch.isEmpty || candidateBytes <= remaining else { break }
                batch.append(light.removeFirst())
                bytes &+= candidateBytes
            }
            return batch
        }

        // Heavy files get a dedicated serial lane, but a light file may share
        // the batch so the heavy worker cannot starve all light work. Files
        // above the hard ready-byte cap are always exclusive.
        while !heavy.isEmpty {
            let job = heavy.removeFirst()
            if job.observedSignature.size > Self.stagingMaxReadyBytes {
                batches.append([job])
            } else {
                batches.append(fillBatch(startingWith: job))
            }
        }
        while !light.isEmpty {
            batches.append(fillBatch(startingWith: nil))
        }
        return batches
    }

    private func ensureStagingCapacity(for jobs: [FullRebuildJob]) throws {
        guard !jobs.isEmpty else { return }
        let requestedBytes = jobs.reduce(UInt64(0)) { partial, job in
            let (sum, overflow) = partial.addingReportingOverflow(
                job.observedSignature.size
            )
            return overflow ? UInt64.max : sum
        }
        let stagingRoot = driver.url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let values = try stagingRoot.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let rawAvailable = values.volumeAvailableCapacityForImportantUsage,
              rawAvailable >= 0 else {
            return
        }
        let available = UInt64(rawAvailable)
        let reserve = UInt64(max(0, Self.stagingMinimumFreeReserveBytes))
        let (required, overflow) = requestedBytes.addingReportingOverflow(reserve)
        guard !overflow, available >= required else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteOutOfSpaceError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "精确索引 staging 磁盘空间不足；已停止派发新任务并保留上一份可用结果。",
                    NSFilePathErrorKey: stagingRoot.path,
                ]
            )
        }
    }

    private func stageFullRebuilds(
        _ jobs: [FullRebuildJob],
        parser: @escaping SessionParser,
        eventEnrichmentTotal: Int,
        onEventEnrichmentProgress: @escaping (Int, Int) -> Void
    ) throws -> [StagedFullRebuild] {
        guard !jobs.isEmpty else { return [] }
        let jobs = jobs.sorted {
            if $0.observedSignature.size == $1.observedSignature.size {
                return $0.file.path < $1.file.path
            }
            return $0.observedSignature.size > $1.observedSignature.size
        }
        // 决策口径（对齐 Rust stage_full_rebuilds 的独立通道）：heavy 文件走
        // maxConcurrent=1 的专用队列串行处理，light 走并行队列占其余额度。
        // 旧实现单队列 + 互斥锁会让 ≥2 个 heavy 时全部并发槽阻塞在锁上，
        // 冷建退化成串行、轻文件被饿死。
        let heavyThreshold = coldBuildHeavyFileThreshold
        let hasHeavyJobs = jobs.contains { $0.observedSignature.size >= heavyThreshold }
        let workerCount = coldBuildWorkerCount(jobCount: jobs.count)
        let heavyQueue = OperationQueue()
        heavyQueue.name = "CodexUsageHistoryIndex.cold-build-heavy"
        heavyQueue.qualityOfService = .userInitiated
        heavyQueue.maxConcurrentOperationCount = 1
        let lightQueue = OperationQueue()
        lightQueue.name = "CodexUsageHistoryIndex.cold-build"
        lightQueue.qualityOfService = .userInitiated
        lightQueue.maxConcurrentOperationCount = hasHeavyJobs
            ? max(1, workerCount - 1)
            : workerCount
        let collector = StageCollector()
        let parserBox = SessionParserBox(parser)
        let progressBox = EventEnrichmentProgressBox(onEventEnrichmentProgress)

        for job in jobs {
            let queue = job.observedSignature.size >= heavyThreshold ? heavyQueue : lightQueue
            queue.addOperation { [self] in
                autoreleasepool {
                    do {
                        let completed = collector.append(
                            try stageFullRebuild(
                                job,
                                parser: parserBox.parser
                            )
                        )
                        if let completed, eventEnrichmentTotal > 0 {
                            progressBox.callback(
                                min(completed, eventEnrichmentTotal),
                                eventEnrichmentTotal
                            )
                        }
                    } catch {
                        collector.record(error)
                    }
                }
            }
        }
        heavyQueue.waitUntilAllOperationsAreFinished()
        lightQueue.waitUntilAllOperationsAreFinished()
        return try collector.result().sorted {
            if $0.job.observedSignature.size == $1.job.observedSignature.size {
                return $0.job.file.path < $1.job.file.path
            }
            return $0.job.observedSignature.size > $1.job.observedSignature.size
        }
    }

    private func coldBuildWorkerCount(jobCount: Int) -> Int {
        guard jobCount > 1 else { return 1 }
        let process = ProcessInfo.processInfo
        let cores = process.activeProcessorCount
        let memory = process.physicalMemory
        let resourceCap: Int
        if cores >= 8, memory >= 16 * 1_024 * 1_024 * 1_024 {
            resourceCap = 4
        } else if cores >= 4, memory >= 8 * 1_024 * 1_024 * 1_024 {
            resourceCap = 3
        } else {
            resourceCap = 2
        }
        return min(jobCount, resourceCap)
    }

    private func stageFullRebuild(
        _ job: FullRebuildJob,
        parser: SessionParser
    ) throws -> StagedFullRebuild {
        let databaseURL = stagingDatabaseURL(for: job.file)
        if let reusable = try reusableStage(
            at: databaseURL,
            for: job
        ) {
            return reusable
        }
        removeStagingDatabase(at: databaseURL)
        let readHandle = try FileHandle(forReadingFrom: job.file)
        defer { try? readHandle.close() }
        let formalSignature = try sourceSignature(
            forOpenHandle: readHandle,
            file: job.file
        )
        guard formalSignature.deviceID == job.observedSignature.deviceID,
              formalSignature.inode == job.observedSignature.inode,
              formalSignature.size >= job.observedSignature.size else {
            throw CodexUsageSourceChangedError(path: job.file.path)
        }
        let committedSignature = job.reason == .eventEnrichment
            ? job.observedSignature
            : formalSignature
        let artifactID = UUID().uuidString
        let migrationRevision = job.reason == .eventEnrichment
            ? Self.eventEnrichmentRevision
            : "exact-source-rebuild-v1"
        let stage = SQLiteDatabaseDriver(
            url: databaseURL,
            busyTimeoutMilliseconds: 30_000,
            enableWAL: false,
            fileManager: fileManager
        )
        return try stage.withConnection { connection in
            try connection.execute(
                """
                PRAGMA synchronous=FULL;
                PRAGMA temp_store=FILE;
                PRAGMA cache_size=-4096;

                CREATE TABLE manifest (
                    complete INTEGER PRIMARY KEY CHECK(complete IN (0, 1)),
                    manifest_schema_version INTEGER NOT NULL,
                    canonical_path TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    migration_revision TEXT NOT NULL,
                    parser_revision TEXT NOT NULL,
                    artifact_id TEXT NOT NULL,
                    actual_bytes INTEGER NOT NULL,
                    integrity TEXT NOT NULL,
                    prefix_sha256 TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    content_probe TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    inode TEXT NOT NULL,
                    status_changed_seconds INTEGER NOT NULL,
                    status_changed_nanoseconds INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    resume_offset INTEGER NOT NULL,
                    previous_total_tokens INTEGER,
                    fork_replay_started_at REAL,
                    is_skipping_fork_replay INTEGER NOT NULL,
                    is_explicit_subagent_fork INTEGER NOT NULL,
                    last_skipped_fork_replay_token_at REAL,
                    current_user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER,
                    current_model TEXT,
                    fingerprint_count INTEGER NOT NULL,
                    chunk_count INTEGER NOT NULL
                );

                CREATE TABLE fingerprints (
                    value TEXT PRIMARY KEY
                ) WITHOUT ROWID;

                CREATE TABLE events (
                    source_offset INTEGER PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    tokens INTEGER NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    model TEXT,
                    user_prompt_offset INTEGER,
                    assistant_start_offset INTEGER
                ) WITHOUT ROWID;

                CREATE TABLE chunks (
                    chunk_index INTEGER PRIMARY KEY,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL
                ) WITHOUT ROWID;
                """
            )
            var staged = try connection.transaction { transaction in
                let fingerprintStatement = try transaction.prepare(
                    "INSERT OR IGNORE INTO fingerprints(value) VALUES (?);"
                )
                let eventStatement = try transaction.prepare(
                    """
                    INSERT INTO events(
                        source_offset,
                        timestamp,
                        tokens,
                        input_tokens,
                        cached_input_tokens,
                        output_tokens,
                        reasoning_output_tokens,
                        model,
                        user_prompt_offset,
                        assistant_start_offset
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                )
                let result = try parser(
                    job.file,
                    job.sessionID,
                    .full(
                        endOffset: committedSignature.size,
                        readHandle: readHandle
                    ),
                    { fingerprint in
                        try fingerprintStatement.execute([
                            .text(fingerprint.databaseKey)
                        ]) > 0
                    },
                    { indexedEvent in
                        let event = indexedEvent.event
                        let userPromptOffset: SQLiteBinding
                        if let offset = indexedEvent.userPromptOffset {
                            userPromptOffset = .int64(try sqliteInt64(offset))
                        } else {
                            userPromptOffset = .null
                        }
                        let assistantStartOffset: SQLiteBinding
                        if let offset = indexedEvent.assistantStartOffset {
                            assistantStartOffset = .int64(try sqliteInt64(offset))
                        } else {
                            assistantStartOffset = .null
                        }
                        _ = try eventStatement.execute([
                            .int64(try sqliteInt64(indexedEvent.sourceOffset)),
                            .date(event.timestamp),
                            .int(event.tokens),
                            .int(event.inputTokens),
                            .int(min(event.cachedInputTokens, event.inputTokens)),
                            .int(event.outputTokens),
                            .int(event.reasoningOutputTokens),
                            event.model.map(SQLiteBinding.text) ?? .null,
                            userPromptOffset,
                            assistantStartOffset
                        ])
                    }
                )
                guard result.lastOffset == committedSignature.size else {
                    throw CodexUsageSourceChangedError(path: job.file.path)
                }
                let handleSignature = try sourceSignature(
                    forOpenHandle: readHandle,
                    file: job.file
                )
                let pathSignature = try sourceSignature(for: job.file)
                guard handleSignature.deviceID == committedSignature.deviceID,
                      handleSignature.inode == committedSignature.inode,
                      handleSignature.size >= committedSignature.size,
                      pathSignature.deviceID == committedSignature.deviceID,
                      pathSignature.inode == committedSignature.inode,
                      pathSignature.size >= committedSignature.size,
                      try contentHash(
                          forOpenHandle: readHandle,
                          length: committedSignature.size,
                          file: job.file
                      ) == result.contentHash,
                      try contentHash(
                          for: job.file,
                          length: committedSignature.size
                      ) == result.contentHash else {
                    throw CodexUsageSourceChangedError(path: job.file.path)
                }

                let chunkStatement = try transaction.prepare(
                    """
                    INSERT INTO chunks(chunk_index, byte_count, sha256)
                    VALUES (?, ?, ?);
                    """
                )
                for chunk in result.chunkHashes {
                    _ = try chunkStatement.execute([
                        .int64(try sqliteInt64(chunk.index)),
                        .int64(try sqliteInt64(chunk.byteCount)),
                        .text(chunk.sha256)
                    ])
                }
                let state = result.state
                let fingerprintCount = try transaction.readRows(
                    "SELECT COUNT(*) FROM fingerprints;"
                ) { $0.int(0) ?? -1 }.first ?? -1
                guard fingerprintCount >= 0 else {
                    throw SQLiteDatabaseError(
                        operation: "Count exact usage staging fingerprints",
                        code: SQLITE_CORRUPT,
                        message: "Unable to count staged fingerprints",
                        path: databaseURL.path
                    )
                }
                try transaction.execute(
                    """
                    INSERT INTO manifest(
                        complete,
                        manifest_schema_version,
                        canonical_path,
                        session_id,
                        migration_revision,
                        parser_revision,
                        artifact_id,
                        actual_bytes,
                        integrity,
                        prefix_sha256,
                        size_bytes,
                        modified_at,
                        content_probe,
                        device_id,
                        inode,
                        status_changed_seconds,
                        status_changed_nanoseconds,
                        event_count,
                        resume_offset,
                        previous_total_tokens,
                        fork_replay_started_at,
                        is_skipping_fork_replay,
                        is_explicit_subagent_fork,
                        last_skipped_fork_replay_token_at,
                        current_user_prompt_offset,
                        assistant_start_offset,
                        current_model,
                        fingerprint_count,
                        chunk_count
                    ) VALUES (0, ?, ?, ?, ?, ?, ?, 0, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .int(Self.stagingManifestSchemaVersion),
                        .text(job.file.path),
                        .text(job.sessionID),
                        .text(migrationRevision),
                        .text(Self.stagingParserRevision),
                        .text(artifactID),
                        .text(result.contentHash),
                        .int64(try sqliteInt64(committedSignature.size)),
                        .double(committedSignature.modifiedAt),
                        .text(committedSignature.contentProbe),
                        .text(String(committedSignature.deviceID)),
                        .text(String(committedSignature.inode)),
                        .int64(committedSignature.statusChangedSeconds),
                        .int64(committedSignature.statusChangedNanoseconds),
                        .int(result.eventCount),
                        .int64(try sqliteInt64(result.resumeOffset)),
                        .optionalInt(state.previousTotalTokens),
                        .optionalDate(state.forkReplayStartedAt),
                        .int(state.isSkippingForkReplay ? 1 : 0),
                        .int(state.isExplicitSubagentFork ? 1 : 0),
                        .optionalDate(state.lastSkippedForkReplayTokenAt),
                        try optionalOffsetBinding(state.currentUserPromptOffset),
                        try optionalOffsetBinding(state.assistantStartOffset),
                        state.currentModel.map(SQLiteBinding.text) ?? .null,
                        .int(fingerprintCount),
                        .int(result.chunkHashes.count)
                    ]
                )
                return StagedFullRebuild(
                    job: FullRebuildJob(
                        file: job.file,
                        sessionID: job.sessionID,
                        observedSignature: committedSignature,
                        reason: job.reason
                    ),
                    databaseURL: databaseURL,
                    committedSignature: committedSignature,
                    artifactID: artifactID,
                    actualBytes: 0,
                    eventCount: result.eventCount,
                    fingerprintCount: fingerprintCount,
                    chunkCount: result.chunkHashes.count,
                    resumeOffset: result.resumeOffset,
                    parserState: result.state
                )
            }
            let quickCheck = try connection.readRows("PRAGMA quick_check;") {
                $0.text(0) ?? ""
            }
            guard quickCheck == ["ok"] else {
                throw SQLiteDatabaseError(
                    operation: "Validate exact usage staging",
                    code: SQLITE_CORRUPT,
                    message: quickCheck.joined(separator: "; "),
                    path: databaseURL.path
                )
            }
            let attributes = try fileManager.attributesOfItem(atPath: databaseURL.path)
            var actualBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            try connection.execute(
                """
                UPDATE manifest
                SET complete = 1, actual_bytes = ?, integrity = ?
                WHERE complete = 0 AND artifact_id = ?;
                """,
                bindings: [
                    .int64(try sqliteInt64(actualBytes)),
                    .text(Self.stagingManifestIntegrity),
                    .text(artifactID)
                ]
            )
            let publishedAttributes = try fileManager.attributesOfItem(atPath: databaseURL.path)
            let publishedBytes = (publishedAttributes[.size] as? NSNumber)?.uint64Value ?? 0
            if publishedBytes != actualBytes {
                actualBytes = publishedBytes
                try connection.execute(
                    "UPDATE manifest SET actual_bytes = ? WHERE complete = 1 AND artifact_id = ?;",
                    bindings: [
                        .int64(try sqliteInt64(actualBytes)),
                        .text(artifactID)
                    ]
                )
            }
            let syncHandle = try FileHandle(forReadingFrom: databaseURL)
            try syncHandle.synchronize()
            try syncHandle.close()
            staged = StagedFullRebuild(
                job: staged.job,
                databaseURL: staged.databaseURL,
                committedSignature: staged.committedSignature,
                artifactID: staged.artifactID,
                actualBytes: actualBytes,
                eventCount: staged.eventCount,
                fingerprintCount: staged.fingerprintCount,
                chunkCount: staged.chunkCount,
                resumeOffset: staged.resumeOffset,
                parserState: staged.parserState
            )
            return staged
        }
    }

    private func reusableStage(
        at databaseURL: URL,
        for job: FullRebuildJob
    ) throws -> StagedFullRebuild? {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return nil
        }
        do {
            let stage = SQLiteDatabaseDriver(
                url: databaseURL,
                readOnly: true,
                busyTimeoutMilliseconds: 1_000,
                fileManager: fileManager
            )
            // A staging database is a recovery artifact, not disposable cache
            // until its format has been classified.  Read the small manifest
            // header before quick_check or any cleanup so a future app's
            // artifact is never mistaken for an incomplete current artifact.
            let manifestExists = try stage.readRows(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'manifest');"
            ) { ($0.int(0) ?? 0) != 0 }.first ?? false
            guard manifestExists else {
                removeStagingDatabase(at: databaseURL)
                return nil
            }
            let manifestColumns = Set(try stage.readRows(
                "PRAGMA table_info(manifest);"
            ) { $0.text(1) ?? "" })
            guard manifestColumns.contains("manifest_schema_version") else {
                // This is the only known pre-versioned staging format. It was
                // never part of a public release and cannot be trusted after a
                // parser upgrade, so rebuild this one file.
                removeStagingDatabase(at: databaseURL)
                return nil
            }
            let header = try stage.readRows(
                "SELECT manifest_schema_version, migration_revision, parser_revision FROM manifest LIMIT 1;"
            ) { row in
                (
                    schema: row.int(0),
                    migration: row.text(1),
                    parser: row.text(2)
                )
            }.first
            guard let header, let manifestSchema = header.schema else {
                removeStagingDatabase(at: databaseURL)
                return nil
            }
            if manifestSchema > Self.stagingManifestSchemaVersion {
                throw CodexUsageIndexUpgradeRequiredError(
                    component: "staging manifest",
                    stored: String(manifestSchema),
                    supported: String(Self.stagingManifestSchemaVersion)
                )
            }
            guard manifestSchema == Self.stagingManifestSchemaVersion else {
                removeStagingDatabase(at: databaseURL)
                return nil
            }
            let expectedMigrationRevision = job.reason == .eventEnrichment
                ? Self.eventEnrichmentRevision
                : "exact-source-rebuild-v1"
            if let migration = header.migration,
               !migration.isEmpty,
               migration != expectedMigrationRevision {
                throw CodexUsageIndexUpgradeRequiredError(
                    component: "staging migration",
                    stored: migration,
                    supported: expectedMigrationRevision
                )
            }
            if let parser = header.parser,
               !parser.isEmpty,
               parser != Self.stagingParserRevision {
                throw CodexUsageIndexUpgradeRequiredError(
                    component: "staging parser",
                    stored: parser,
                    supported: Self.stagingParserRevision
                )
            }
            let quickCheck = try stage.readRows("PRAGMA quick_check;") {
                $0.text(0) ?? ""
            }
            guard quickCheck == ["ok"] else {
                removeStagingDatabase(at: databaseURL)
                return nil
            }
            let rows: [StagedFullRebuild?] = try stage.readRows(
                """
                SELECT
                    manifest_schema_version,
                    canonical_path,
                    session_id,
                    migration_revision,
                    parser_revision,
                    artifact_id,
                    actual_bytes,
                    integrity,
                    prefix_sha256,
                    size_bytes,
                    modified_at,
                    content_probe,
                    device_id,
                    inode,
                    status_changed_seconds,
                    status_changed_nanoseconds,
                    event_count,
                    resume_offset,
                    previous_total_tokens,
                    fork_replay_started_at,
                    is_skipping_fork_replay,
                    is_explicit_subagent_fork,
                    last_skipped_fork_replay_token_at,
                    current_user_prompt_offset,
                    assistant_start_offset,
                    current_model,
                    fingerprint_count,
                    chunk_count
                FROM manifest
                WHERE complete = 1
                LIMIT 1;
                """
            ) { row in
                guard row.int(0) == Self.stagingManifestSchemaVersion,
                      row.text(1) == job.file.path,
                      row.text(2) == job.sessionID,
                      row.text(3) == expectedMigrationRevision,
                      row.text(4) == Self.stagingParserRevision,
                      let artifactID = row.text(5),
                      !artifactID.isEmpty,
                      let rawActualBytes = row.int64(6),
                      rawActualBytes >= 0,
                      row.text(7) == Self.stagingManifestIntegrity,
                      let prefixSHA256 = row.text(8),
                      let rawSize = row.int64(9),
                      rawSize >= 0,
                      let modifiedAt = row.double(10),
                      let contentProbe = row.text(11),
                      let deviceID = row.text(12).flatMap(UInt64.init),
                      let inode = row.text(13).flatMap(UInt64.init),
                      let changedSeconds = row.int64(14),
                      let changedNanoseconds = row.int64(15),
                      let eventCount = row.int(16),
                      eventCount >= 0,
                      let rawResumeOffset = row.int64(17),
                      rawResumeOffset >= 0,
                      let fingerprintCount = row.int(26),
                      fingerprintCount >= 0,
                      let chunkCount = row.int(27),
                      chunkCount >= 0 else {
                    return nil
                }
                let signature = SourceSignature(
                    size: UInt64(rawSize),
                    modifiedAt: modifiedAt,
                    contentProbe: contentProbe,
                    deviceID: deviceID,
                    inode: inode,
                    statusChangedSeconds: changedSeconds,
                    statusChangedNanoseconds: changedNanoseconds
                )
                let actualBytes = UInt64(rawActualBytes)
                let databaseAttributes = try? self.fileManager.attributesOfItem(
                    atPath: databaseURL.path
                )
                let databaseSize = (databaseAttributes?[.size] as? NSNumber)?.uint64Value
                let storedEventCount = try? stage.readRows(
                    "SELECT COUNT(*) FROM events;"
                ) { $0.int(0) ?? -1 }.first
                let storedFingerprintCount = try? stage.readRows(
                    "SELECT COUNT(*) FROM fingerprints;"
                ) { $0.int(0) ?? -1 }.first
                let storedChunkCount = try? stage.readRows(
                    "SELECT COUNT(*) FROM chunks;"
                ) { $0.int(0) ?? -1 }.first
                guard databaseSize == actualBytes,
                      storedEventCount == eventCount,
                      storedFingerprintCount == fingerprintCount,
                      storedChunkCount == chunkCount,
                      signature.deviceID == job.observedSignature.deviceID,
                      signature.inode == job.observedSignature.inode,
                      signature.size <= job.observedSignature.size,
                      rawResumeOffset <= rawSize,
                      (try? self.contentHash(
                          for: job.file,
                          length: signature.size
                      )) == prefixSHA256 else {
                    return nil
                }
                return StagedFullRebuild(
                    job: job,
                    databaseURL: databaseURL,
                    committedSignature: signature,
                    artifactID: artifactID,
                    actualBytes: actualBytes,
                    eventCount: eventCount,
                    fingerprintCount: fingerprintCount,
                    chunkCount: chunkCount,
                    resumeOffset: UInt64(rawResumeOffset),
                    parserState: CodexUsageAnalyzer.IndexedSessionParserState(
                        previousTotalTokens: row.int(18),
                        forkReplayStartedAt: row.double(19).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        isSkippingForkReplay: row.int(20) == 1,
                        isExplicitSubagentFork: row.int(21) == 1,
                        lastSkippedForkReplayTokenAt: row.double(22).map {
                            Date(timeIntervalSince1970: $0)
                        },
                        currentUserPromptOffset: row.int64(23).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        assistantStartOffset: row.int64(24).flatMap {
                            $0 >= 0 ? UInt64($0) : nil
                        },
                        currentModel: row.text(25)
                    )
                )
            }
            if let reusable = rows.compactMap({ $0 }).first {
                return reusable
            }
        } catch let error as CodexUsageIndexUpgradeRequiredError {
            throw error
        } catch {
            removeStagingDatabase(at: databaseURL)
            return nil
        }
        removeStagingDatabase(at: databaseURL)
        return nil
    }

    private func lineageReplacement(
        for staged: StagedFullRebuild,
        observedPaths: Set<String>,
        connection: SQLiteDatabaseConnection
    ) throws -> (
        replacement: LineageReplacement?,
        ambiguous: Bool,
        preserveExistingLedger: Bool
    ) {
        guard try indexedSource(
            path: staged.job.file.path,
            connection: connection
        ) == nil,
              let canonicalSessionID = canonicalSessionID(staged.job.sessionID) else {
            return (nil, false, false)
        }
        let candidates = try connection.readRows(
            """
            SELECT source_id, path
            FROM sources
            WHERE lower(session_id) = ?
              AND path <> ?
            ORDER BY source_id;
            """,
            bindings: [
                .text(canonicalSessionID),
                .text(staged.job.file.path)
            ]
        ) { row -> SourceIdentity? in
            guard let sourceID = row.int64(0),
                  let path = row.text(1),
                  !observedPaths.contains(path) else {
                return nil
            }
            return SourceIdentity(id: sourceID, path: path, sessionID: nil)
        }.compactMap { $0 }
        let candidateIDs = candidates.map(\.id)
        if candidateIDs.count == 1, let sourceID = candidateIDs.first {
            let contentMatches = try stagedContentMatchesSource(
                staged,
                sourceID: sourceID,
                connection: connection
            )
            return (
                LineageReplacement(sourceID: sourceID),
                !contentMatches,
                false
            )
        }
        guard candidateIDs.isEmpty else {
            return (nil, true, false)
        }

        // A canonical lineage ledger can survive source cleanup by design. If
        // the UUID later reappears without the retained source chunks, exact
        // identity cannot be proved. Keep the old bucket values as a
        // conservative floor, merge the new import component-wise by MAX, and
        // force a sticky synthetic cutover instead of silently replacing the
        // tombstone with a potentially smaller history.
        let attributionState = try currentAttributionState(connection: connection)
        let liveLineageSourceCount = try connection.readRows(
            "SELECT COUNT(*) FROM sources WHERE lower(session_id) = ?;",
            bindings: [.text(canonicalSessionID)]
        ) { row in row.int(0) ?? 0 }.first ?? 0
        let lineageKey = "session:\(canonicalSessionID)"
        let retainedLedgerCount = try connection.readRows(
            """
            SELECT COUNT(*)
            FROM attribution_source_buckets
            WHERE provenance_epoch = ? AND source_lineage = ?;
            """,
            bindings: [
                .text(attributionState.provenanceEpoch),
                .text(lineageKey),
            ]
        ) { row in row.int(0) ?? 0 }.first ?? 0
        let tombstonedLineage = liveLineageSourceCount == 0
            && retainedLedgerCount > 0
        return (
            nil,
            tombstonedLineage,
            tombstonedLineage
        )
    }

    private func stagedContentMatchesSource(
        _ staged: StagedFullRebuild,
        sourceID: Int64,
        connection: SQLiteDatabaseConnection
    ) throws -> Bool {
        let storedSize = try connection.readRows(
            "SELECT size_bytes FROM sources WHERE source_id = ? LIMIT 1;",
            bindings: [.int64(sourceID)]
        ) { row in row.int64(0) }.compactMap { $0 }.first
        let stagedSize = try sqliteInt64(staged.committedSignature.size)
        guard storedSize == stagedSize else {
            return false
        }
        let storedChunks = try connection.readRows(
            """
            SELECT chunk_index, byte_count, sha256
            FROM source_chunks
            WHERE source_id = ?
            ORDER BY chunk_index;
            """,
            bindings: [.int64(sourceID)]
        ) { row -> CodexUsageAnalyzer.IndexedChunkHash? in
            guard let rawIndex = row.int64(0),
                  rawIndex >= 0,
                  let rawByteCount = row.int64(1),
                  rawByteCount >= 0,
                  let sha256 = row.text(2) else {
                return nil
            }
            return CodexUsageAnalyzer.IndexedChunkHash(
                index: UInt64(rawIndex),
                byteCount: UInt64(rawByteCount),
                sha256: sha256
            )
        }.compactMap { $0 }
        let stage = SQLiteDatabaseDriver(
            url: staged.databaseURL,
            readOnly: true,
            busyTimeoutMilliseconds: 1_000,
            fileManager: fileManager
        )
        let stagedChunks = try stage.readRows(
            "SELECT chunk_index, byte_count, sha256 FROM chunks ORDER BY chunk_index;"
        ) { row -> CodexUsageAnalyzer.IndexedChunkHash? in
            guard let rawIndex = row.int64(0),
                  rawIndex >= 0,
                  let rawByteCount = row.int64(1),
                  rawByteCount >= 0,
                  let sha256 = row.text(2) else {
                return nil
            }
            return CodexUsageAnalyzer.IndexedChunkHash(
                index: UInt64(rawIndex),
                byteCount: UInt64(rawByteCount),
                sha256: sha256
            )
        }.compactMap { $0 }
        return storedChunks == stagedChunks
    }

    private func stagedEventsMatchPublishedSource(
        _ staged: StagedFullRebuild,
        sourceID: Int64,
        connection: SQLiteDatabaseConnection
    ) throws -> Bool {
        try connection.execute(
            "ATTACH DATABASE ? AS event_enrichment_stage;",
            bindings: [.text(staged.databaseURL.path)]
        )
        defer {
            try? connection.execute("DETACH DATABASE event_enrichment_stage;")
        }
        let mismatch = try connection.readRows(
            """
            SELECT EXISTS(
                SELECT 1
                FROM events published
                LEFT JOIN event_enrichment_stage.events staged
                  ON staged.source_offset = published.source_offset
                WHERE published.source_id = ?
                  AND (
                    staged.source_offset IS NULL
                    OR published.timestamp IS NOT staged.timestamp
                    OR published.tokens IS NOT staged.tokens
                    OR published.input_tokens IS NOT staged.input_tokens
                    OR published.cached_input_tokens IS NOT staged.cached_input_tokens
                    OR published.output_tokens IS NOT staged.output_tokens
                    OR published.reasoning_output_tokens IS NOT staged.reasoning_output_tokens
                  )
                UNION ALL
                SELECT 1
                FROM event_enrichment_stage.events staged
                LEFT JOIN events published
                  ON published.source_id = ?
                 AND published.source_offset = staged.source_offset
                WHERE published.source_offset IS NULL
                LIMIT 1
            );
            """,
            bindings: [.int64(sourceID), .int64(sourceID)]
        ) { $0.int(0) ?? 1 }.first ?? 1
        return mismatch == 0
    }

    private func importStagedFullRebuild(
        _ staged: StagedFullRebuild,
        generation: String,
        replacementSourceID: Int64?,
        preserveExistingAttributionLedger: Bool,
        connection: SQLiteDatabaseConnection
    ) throws {
        guard let validated = try reusableStage(
            at: staged.databaseURL,
            for: staged.job
        ),
        validated.artifactID == staged.artifactID,
        validated.actualBytes == staged.actualBytes else {
            throw SQLiteDatabaseError(
                operation: "Validate exact usage staging before import",
                code: SQLITE_CORRUPT,
                message: "Staging manifest changed before import",
                path: staged.databaseURL.path
            )
        }
        let stage = SQLiteDatabaseDriver(
            url: staged.databaseURL,
            readOnly: true,
            busyTimeoutMilliseconds: 1_000,
            fileManager: fileManager
        )
        let transaction = connection
            if let existing = try indexedSource(
                path: staged.job.file.path,
                connection: transaction
            ) {
                try transaction.execute(
                    """
                    UPDATE sources
                    SET session_id = ?, last_seen_generation = ?
                    WHERE source_id = ?;
                    """,
                    bindings: [
                        .text(staged.job.sessionID),
                        .text(generation),
                        .int64(existing.id),
                    ]
                )
            } else if let replacementSourceID {
                try transaction.execute(
                    """
                    UPDATE sources
                    SET path = ?, session_id = ?, last_seen_generation = ?
                    WHERE source_id = ?;
                    """,
                    bindings: [
                        .text(staged.job.file.path),
                        .text(staged.job.sessionID),
                        .text(generation),
                        .int64(replacementSourceID),
                    ]
                )
            } else {
                let sourceID = try allocateSourceID(connection: transaction)
                try transaction.execute(
                    """
                    INSERT INTO sources(
                        source_id,
                        path,
                        session_id,
                        size_bytes,
                        modified_at,
                        content_probe,
                        device_id,
                        inode,
                        status_changed_seconds,
                        status_changed_nanoseconds,
                        last_seen_generation
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .int64(sourceID),
                        .text(staged.job.file.path),
                        .text(staged.job.sessionID),
                        .int64(try sqliteInt64(staged.committedSignature.size)),
                        .double(staged.committedSignature.modifiedAt),
                        .text(staged.committedSignature.contentProbe),
                        .text(String(staged.committedSignature.deviceID)),
                        .text(String(staged.committedSignature.inode)),
                        .int64(staged.committedSignature.statusChangedSeconds),
                        .int64(staged.committedSignature.statusChangedNanoseconds),
                        .text(generation)
                    ]
                )
            }
            guard let source = try indexedSource(
                path: staged.job.file.path,
                connection: transaction
            ) else {
                throw SQLiteDatabaseError(
                    operation: "Resolve staged exact usage source",
                    code: -1,
                    message: "Source row was not created",
                    path: driver.url.path
                )
            }
            try transaction.execute(
                "DELETE FROM events WHERE source_id = ?;",
                bindings: [.int64(source.id)]
            )
            try transaction.execute(
                "DELETE FROM source_fingerprints WHERE source_id = ?;",
                bindings: [.int64(source.id)]
            )
            try transaction.execute(
                "DELETE FROM source_chunks WHERE source_id = ?;",
                bindings: [.int64(source.id)]
            )

            let fingerprintStatement = try transaction.prepare(
                "INSERT INTO source_fingerprints(source_id, value) VALUES (?, ?);"
            )
            var importedFingerprintCount = 0
            try stage.forEachRow("SELECT value FROM fingerprints ORDER BY value;") { row in
                guard let value = row.text(0) else {
                    throw SQLiteDatabaseError(
                        operation: "Import exact usage staging fingerprint",
                        code: SQLITE_CORRUPT,
                        message: "Malformed fingerprint row",
                        path: staged.databaseURL.path
                    )
                }
                _ = try fingerprintStatement.execute([
                    .int64(source.id),
                    .text(value)
                ])
                importedFingerprintCount += 1
            }
            guard importedFingerprintCount == staged.fingerprintCount else {
                throw SQLiteDatabaseError(
                    operation: "Import exact usage staging fingerprints",
                    code: SQLITE_CORRUPT,
                    message: "Fingerprint count changed before import",
                    path: staged.databaseURL.path
                )
            }
            let eventStatement = try transaction.prepare(
                """
                INSERT INTO events(
                    source_id,
                    source_offset,
                    timestamp,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    model,
                    user_prompt_offset,
                    assistant_start_offset
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            var importedEventCount = 0
            try stage.forEachRow(
                """
                SELECT
                    source_offset,
                    timestamp,
                    tokens,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    model,
                    user_prompt_offset,
                    assistant_start_offset
                FROM events
                ORDER BY source_offset;
                """
            ) { row in
                guard let sourceOffset = row.int64(0),
                      let timestamp = row.double(1),
                      let tokens = row.int(2),
                      let inputTokens = row.int(3),
                      let cachedInputTokens = row.int(4),
                      let outputTokens = row.int(5),
                      let reasoningOutputTokens = row.int(6) else {
                    throw SQLiteDatabaseError(
                        operation: "Import exact usage staging event",
                        code: SQLITE_CORRUPT,
                        message: "Malformed event row",
                        path: staged.databaseURL.path
                    )
                }
                _ = try eventStatement.execute([
                    .int64(source.id),
                    .int64(sourceOffset),
                    .double(timestamp),
                    .int(tokens),
                    .int(inputTokens),
                    .int(cachedInputTokens),
                    .int(outputTokens),
                    .int(reasoningOutputTokens),
                    row.text(7).map(SQLiteBinding.text) ?? .null,
                    row.int64(8).map(SQLiteBinding.int64) ?? .null,
                    row.int64(9).map(SQLiteBinding.int64) ?? .null
                ])
                importedEventCount += 1
            }
            guard importedEventCount == staged.eventCount else {
                throw SQLiteDatabaseError(
                    operation: "Import exact usage staging events",
                    code: SQLITE_CORRUPT,
                    message: "Event count changed before import",
                    path: staged.databaseURL.path
                )
            }
            let chunkStatement = try transaction.prepare(
                """
                INSERT INTO source_chunks(source_id, chunk_index, byte_count, sha256)
                VALUES (?, ?, ?, ?);
                """
            )
            var importedChunkCount = 0
            try stage.forEachRow(
                "SELECT chunk_index, byte_count, sha256 FROM chunks ORDER BY chunk_index;"
            ) { row in
                guard let chunkIndex = row.int64(0),
                      let byteCount = row.int64(1),
                      let sha256 = row.text(2) else {
                    throw SQLiteDatabaseError(
                        operation: "Import exact usage staging chunk",
                        code: SQLITE_CORRUPT,
                        message: "Malformed chunk row",
                        path: staged.databaseURL.path
                    )
                }
                _ = try chunkStatement.execute([
                    .int64(source.id),
                    .int64(chunkIndex),
                    .int64(byteCount),
                    .text(sha256)
                ])
                importedChunkCount += 1
            }
            guard importedChunkCount == staged.chunkCount else {
                throw SQLiteDatabaseError(
                    operation: "Import exact usage staging chunks",
                    code: SQLITE_CORRUPT,
                    message: "Chunk count changed before import",
                    path: staged.databaseURL.path
                )
            }
            let parseResult = CodexUsageAnalyzer.IndexedSessionParseResult(
                eventCount: staged.eventCount,
                lastOffset: staged.committedSignature.size,
                resumeOffset: staged.resumeOffset,
                endedWithNewline: staged.resumeOffset == staged.committedSignature.size,
                contentHash: "",
                state: staged.parserState,
                chunkHashes: [],
                validationChunkHash: nil
            )
            try saveSourceCheckpoint(
                sourceID: source.id,
                sessionID: staged.job.sessionID,
                signature: staged.committedSignature,
                generation: generation,
                parseResult: parseResult,
                auditChunkIndex: 0,
                connection: transaction
            )
            let attributionState = try currentAttributionState(connection: transaction)
            try publishAttributionLedger(
                lineage: attributionLineage(
                    sessionID: staged.job.sessionID,
                    sourceID: source.id
                ),
                sourceID: source.id,
                provenanceEpoch: attributionState.provenanceEpoch,
                affectedBuckets: nil,
                replacing: !preserveExistingAttributionLedger,
                preservingExistingMaximum: preserveExistingAttributionLedger,
                connection: transaction
            )
            try refreshDashboardSourceAggregates(
                sourceID: source.id,
                sessionID: staged.job.sessionID,
                affectedBuckets: nil,
                connection: transaction
            )
            try markEventEnrichmentComplete(
                sourceID: source.id,
                canonicalPath: staged.job.file.path,
                generation: generation,
                signature: staged.committedSignature,
                connection: transaction
            )
    }

    /// SQLite may reuse the highest deleted INTEGER PRIMARY KEY. Attribution
    /// source-bucket IDs must never alias a later unrelated source inside the
    /// same provenance epoch, so allocation uses a durable monotonic sequence.
    private func allocateSourceID(
        connection: SQLiteDatabaseConnection
    ) throws -> Int64 {
        let current = try connection.readRows(
            "SELECT value FROM schema_meta WHERE key = 'source_id_sequence' LIMIT 1;"
        ) { row in row.text(0).flatMap(Int64.init) }.first ?? nil
        guard let current, current >= 0, current < Int64.max else {
            throw SQLiteDatabaseError(
                operation: "Allocate exact usage source identity",
                code: SQLITE_CORRUPT,
                message: "Invalid source identity sequence",
                path: driver.url.path
            )
        }
        let next = current + 1
        try connection.execute(
            "UPDATE schema_meta SET value = ? WHERE key = 'source_id_sequence';",
            bindings: [.text(String(next))]
        )
        return next
    }

    private func stagingDatabaseURL(for file: URL) -> URL {
        let digest = SHA256.hash(data: Data(file.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return stagingDirectoryURL
            .appendingPathComponent("\(digest).sqlite")
    }

    private func removeStagingDatabase(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(atPath: url.path + "-wal")
        try? fileManager.removeItem(atPath: url.path + "-shm")
    }

    private func removeStagingDirectory() {
        try? fileManager.removeItem(at: stagingDirectoryURL)
        _ = rmdir(stagingRootURL.path)
    }

    private var stagingRootURL: URL {
        driver.url
            .deletingLastPathComponent()
            .appendingPathComponent("staging", isDirectory: true)
    }

    private var stagingDirectoryURL: URL {
        stagingRootURL.appendingPathComponent(
            driver.url.lastPathComponent,
            isDirectory: true
        )
    }

    private func optionalOffsetBinding(_ value: UInt64?) throws -> SQLiteBinding {
        guard let value else { return .null }
        return .int64(try sqliteInt64(value))
    }

    private func sourceSignatureMetadata(for file: URL) throws -> SourceSignature {
        var fileStatus = Darwin.stat()
        guard lstat(file.path, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        // Use the same stat representation as the worker-open fstat boundary.
        // Mixing URLResourceValues' rounded timestamp with nanosecond fstat
        // makes an unchanged file look rewritten on the very next cadence.
        let size = UInt64(fileStatus.st_size)
        return SourceSignature(
            size: size,
            modifiedAt: TimeInterval(fileStatus.st_mtimespec.tv_sec)
                + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000,
            contentProbe: "",
            deviceID: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            statusChangedSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            statusChangedNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }

    private func sourceSignature(
        metadata: SourceSignature,
        for file: URL
    ) throws -> SourceSignature {
        SourceSignature(
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            contentProbe: try contentProbe(for: file, size: metadata.size),
            deviceID: metadata.deviceID,
            inode: metadata.inode,
            statusChangedSeconds: metadata.statusChangedSeconds,
            statusChangedNanoseconds: metadata.statusChangedNanoseconds
        )
    }

    private func sourceSignature(for file: URL) throws -> SourceSignature {
        try sourceSignature(metadata: sourceSignatureMetadata(for: file), for: file)
    }

    private func sourceSignature(
        forOpenHandle handle: FileHandle,
        file: URL
    ) throws -> SourceSignature {
        var status = Darwin.stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              status.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let size = UInt64(status.st_size)
        return SourceSignature(
            size: size,
            modifiedAt: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000,
            contentProbe: try contentProbe(forOpenHandle: handle, size: size),
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            statusChangedSeconds: Int64(status.st_ctimespec.tv_sec),
            statusChangedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private func sourceMetadataMatches(
        _ stored: SourceSignature,
        _ observed: SourceSignature
    ) -> Bool {
        stored.size == observed.size
            && stored.modifiedAt == observed.modifiedAt
            && stored.deviceID == observed.deviceID
            && stored.inode == observed.inode
            && stored.statusChangedSeconds == observed.statusChangedSeconds
            && stored.statusChangedNanoseconds == observed.statusChangedNanoseconds
    }

    private func isTrustedContentProbe(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private func contentHash(for file: URL, length: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        return try contentHash(forOpenHandle: handle, length: length, file: file)
    }

    private func contentHash(
        forOpenHandle handle: FileHandle,
        length: UInt64,
        file: URL
    ) throws -> String {
        try handle.seek(toOffset: 0)

        var remaining = length
        var hasher = SHA256()
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 1_048_576))
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else {
                throw CodexUsageSourceChangedError(path: file.path)
            }
            hasher.update(data: data)
            remaining -= UInt64(data.count)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func contentProbe(for file: URL, size: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        return try contentProbe(forOpenHandle: handle, size: size)
    }

    private func contentProbe(
        forOpenHandle handle: FileHandle,
        size: UInt64
    ) throws -> String {
        Self.sourceProbeTestState.record()
        try handle.seek(toOffset: 0)

        let probeLength = 4_096
        var data = Data("\(size):".utf8)
        data.append(handle.readData(ofLength: probeLength))
        if size > UInt64(probeLength) {
            try handle.seek(toOffset: size - UInt64(probeLength))
            data.append(handle.readData(ofLength: probeLength))
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func databaseURL(for codexHome: URL) -> URL {
        let root: URL
        if ProcessInfo.processInfo.environment[disabledCacheEnvironmentKey] == "1" {
            root = ephemeralRoot
        } else if let override = ProcessInfo.processInfo.environment[cacheDirectoryEnvironmentKey],
                  !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
                .appendingPathComponent(indexNamespace, isDirectory: true)
        } else {
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            root = cacheRoot
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
                .appendingPathComponent(indexNamespace, isDirectory: true)
        }
        let canonicalHome = codexHome.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonicalHome.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent("\(digest).sqlite")
    }

    private static func operationGate(
        for databaseURL: URL
    ) -> CodexUsageHistoryIndexOperationGate {
        operationLocks.lock(
            for: databaseURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private static func stableID(sourceID: Int64, sourceOffset: UInt64) -> String {
        "usage-index:\(sourceID):\(sourceOffset)"
    }

    private static func parseStableID(_ value: String) -> (sourceID: Int64, sourceOffset: UInt64)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "usage-index",
              let sourceID = Int64(parts[1]),
              let sourceOffset = UInt64(parts[2]) else {
            return nil
        }
        return (sourceID, sourceOffset)
    }
}

private final class CodexUsageHistoryIndexOperationLockRegistry: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: WeakOperationGate] = [:]

    func lock(for path: String) -> CodexUsageHistoryIndexOperationGate {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path]?.value {
            return existing
        }
        locks = locks.filter { $0.value.value != nil }
        let created = CodexUsageHistoryIndexOperationGate(
            databaseURL: URL(fileURLWithPath: path)
        )
        locks[path] = WeakOperationGate(created)
        return created
    }

    var liveLockCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        locks = locks.filter { $0.value.value != nil }
        return locks.count
    }
}

private final class CodexUsageHistoryIndexLockTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timeout: TimeInterval?

    func set(_ value: TimeInterval?) {
        lock.lock()
        timeout = value.map { max(0, $0) }
        lock.unlock()
    }

    var value: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return timeout
    }
}

private final class WeakOperationGate {
    weak var value: CodexUsageHistoryIndexOperationGate?

    init(_ value: CodexUsageHistoryIndexOperationGate) {
        self.value = value
    }
}

private final class CodexUsageHistoryStagingTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextImport = false
    private var shouldFailNextBatchAfterFirstImport = false

    func armFailure() {
        lock.lock()
        shouldFailNextImport = true
        lock.unlock()
    }

    func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = shouldFailNextImport
        shouldFailNextImport = false
        return value
    }

    func armBatchImportFailure() {
        lock.lock()
        shouldFailNextBatchAfterFirstImport = true
        lock.unlock()
    }

    func consumeBatchImportFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = shouldFailNextBatchAfterFirstImport
        shouldFailNextBatchAfterFirstImport = false
        return value
    }
}

private final class CodexUsageHistorySourceProbeTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var synchronizations = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    func recordSynchronization() {
        lock.lock()
        synchronizations += 1
        lock.unlock()
    }

    func resetSynchronizationCount() {
        lock.lock()
        synchronizations = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var synchronizationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return synchronizations
    }
}

private final class CodexSessionCatalogPublishTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextPublish = false

    func armFailure() {
        lock.lock()
        shouldFailNextPublish = true
        lock.unlock()
    }

    func consumeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = shouldFailNextPublish
        shouldFailNextPublish = false
        return value
    }
}

private final class CodexUsageHistoryIndexOperationGate: @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()
    private let state = NSCondition()
    private let crossProcessLockURL: URL
    private var pendingAcquisitions = 0
    private var recursionDepth = 0
    private var crossProcessLock: CodexCrossProcessFileLock?

    init(databaseURL: URL) {
        crossProcessLockURL = databaseURL.appendingPathExtension("operation.lock")
        recursiveLock.name = "CodexUsageHistoryIndex.\(databaseURL.path)"
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        state.lock()
        pendingAcquisitions += 1
        state.broadcast()
        state.unlock()

        recursiveLock.lock()

        state.lock()
        pendingAcquisitions -= 1
        state.broadcast()
        state.unlock()

        if recursionDepth == 0 {
            do {
                crossProcessLock = try CodexCrossProcessFileLock.acquireWaiting(
                    url: crossProcessLockURL,
                    label: "精确历史索引",
                    timeout: CodexUsageHistoryIndex.operationLockTimeout,
                    onContention: nil
                )
            } catch {
                recursiveLock.unlock()
                throw error
            }
        }
        recursionDepth += 1
        defer {
            recursionDepth -= 1
            if recursionDepth == 0 {
                crossProcessLock?.release()
                crossProcessLock = nil
            }
            recursiveLock.unlock()
        }
        return try body()
    }

    func waitForPendingAcquisition(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        state.lock()
        defer { state.unlock() }
        while pendingAcquisitions == 0 {
            guard state.wait(until: deadline) else {
                return false
            }
        }
        return true
    }
}

private extension CodexUsageAnalyzer.UsageSnapshotFingerprint {
    var databaseKey: String {
        [
            totalInputTokens,
            totalCachedInputTokens,
            totalOutputTokens,
            totalReasoningOutputTokens,
            totalTokens,
            hasLastUsage ? 1 : 0,
            lastInputTokens,
            lastCachedInputTokens,
            lastOutputTokens,
            lastReasoningOutputTokens,
            lastTokens
        ]
        .map(String.init)
        .joined(separator: ":")
    }
}

private func sqliteInt64(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
        throw SQLiteDatabaseError(
            operation: "Encode exact usage offset",
            code: SQLITE_TOOBIG,
            message: "File offset exceeds SQLite signed integer range",
            path: nil
        )
    }
    return Int64(value)
}

private func attributionBucketStart(for date: Date) throws -> Int64 {
    let rawBucket = floor(date.timeIntervalSince1970 / 300)
    guard rawBucket.isFinite,
          rawBucket >= Double(Int64.min / 300),
          rawBucket <= Double(Int64.max / 300) else {
        throw SQLiteDatabaseError(
            operation: "Encode exact usage attribution bucket",
            code: SQLITE_TOOBIG,
            message: "Event timestamp exceeds SQLite signed integer range",
            path: nil
        )
    }
    return Int64(rawBucket) * 300
}
